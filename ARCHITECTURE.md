# LukeNasOS Architecture

> **Revised 2026-07-12.** The build pipeline and factory-reset mechanism described in
> earlier revisions (hand-rolled `rpm-ostree compose`, a bootable `@restore` copy, a
> two-partition ESP+btrfs layout) do not work against how bootc/ostree actually manages
> the filesystem. This revision replaces them. See `SPEC.md` for normative details and
> `BUILD.md` for the build track.

## What LukeNasOS is

A **recovery-first personal NAS**. The immutable OS is the means, not the end.

The product promise is one sentence a user can feel:

> **Updating is not scary, and if you break it, resetting keeps your data.**

Three mechanisms deliver that promise:

1. **Atomic updates** — an update either fully applies or does not apply at all.
2. **Hands-off automatic rollback** — a bad update that boots but fails its health
   checks is reverted without the user doing anything (greenboot).
3. **Data-preserving factory reset** — the OS returns to a known-good deployment while
   `/data` survives by design.

### Where this sits in the landscape

| | Atomic update | Automatic rollback | Data-preserving reset | ARM64 |
|---|---|---|---|---|
| TrueNAS SCALE | yes (ZFS boot environments) | no — manual boot-env selection | partial | no |
| Unraid / OMV | no | no | no | partial |
| uBlue uCore | yes | yes | not a NAS product | yes |
| **LukeNasOS** | **yes** | **yes** | **yes** | **yes (separate targets)** |

Rollback alone is not new. Selling **hands-off recovery as the core experience of a
NAS** is.

## Foundation: bootc

LukeNasOS is a **bootable OCI container image** (bootc), derived from Fedora bootc /
uCore. We do not rebuild the image pipeline, the signing chain, or the update transport
— those are inherited. Our work is the part nobody else has built:

- the storage contract for a NAS appliance,
- the factory-reset mechanism,
- automatic rollback wired to health checks,
- the `luke` CLI and the recovery UX.

Updates are pulled as signed OCI images from a container registry (GHCR). There is no
custom update server.

## Disk Layout

### Partitions (GPT)

| # | Partition | FS | Size | Mount | Why |
|---|-----------|----|------|-------|-----|
| 1 | `ESP` | FAT32 | 512 MB | `/boot/efi` | UEFI firmware requirement |
| 2 | `BOOT` | ext4 | 1 GB | `/boot` | kernels, BLS entries, **`grubenv`** |
| 3 | `ROOT` | btrfs | remainder | `/sysroot` | OS deployments, system state, user data |

**Why `/boot` is its own ext4 partition.** GRUB's `save_env` cannot write to btrfs.
greenboot's automatic rollback works by having GRUB decrement a `boot_counter` variable
in `grubenv` on each boot attempt. If `grubenv` lives on btrfs, that write fails
silently — the boot counter never decrements, and automatic rollback, the headline
feature, quietly does not exist. A small ext4 `/boot` is the layout Fedora bootc
already uses, and it is the one that makes the promise real.

### btrfs subvolumes

```
/dev/sda3  (btrfs)
├── @sysroot     ← mounted at /sysroot; holds /ostree (repo + deployments + stateroot var)
├── @data        ← mounted at /var/mnt/data; user data. /data is a symlink to it.
└── @seed        ← factory-reset seed (a signed OCI archive, not a bootable copy)
```

- **`@sysroot`** contains `/ostree/repo` (the content-addressed object store) and
  `/ostree/deploy/<stateroot>/`, which holds both the deployments and the persistent
  `/var`. This is ostree's own layout; we mount it, we do not reinvent it. Whether a
  dedicated subvolume can be mounted over the stateroot `/var` is an open spike — the
  default is to use ostree's own var rather than fight it.
- **`@data`** is the NAS pool, mounted at `/var/mnt/data`, with `/data` as a symlink.
  On a bootc system the root filesystem is owned by the image, so a new top-level
  `/data` directory sits outside the supported contract; `/var/mnt` is the conventional
  place for machine-local mounts.
- **`@seed`** is a disaster-recovery artifact, not a bootable OS copy (see below).

`compress=zstd:1` and `noatime` for all subvolumes.

### Protecting the OS from a full data pool

All subvolumes share one btrfs pool, so a full `/data` can make `/var` unwritable —
which kills a NAS that promises never to die. The defense is layered, not a single knob:

- a qgroup limit on `@data` = pool size minus an OS reserve (15–20 GB),
- an unallocated-space watchdog (`btrfs fi usage`, warn under ~2 GiB),
- a periodic `balance` timer to reclaim fragmented chunks,
- a pre-flight free-space check in `luke update` that reads `btrfs fi usage`, not
  `statvfs` (which lies about btrfs).

qgroups alone are not enough: they cap data usage but do not prevent metadata
exhaustion, which forces the filesystem read-only.

## Update Mechanism

```
luke update
  └─→ bootc pulls the signed image from GHCR
      └─→ signature verified against the pinned policy (reject → hard stop, no partial state)
          └─→ previous deployment pinned and verified, THEN the new one is staged
              └─→ nothing reboots automatically
                  └─→ luke update --reboot (or the next reboot) activates it
                      └─→ greenboot runs health checks
                          ├─ pass → boot_counter cleared, done
                          └─ fail → GRUB boots the previous deployment,
                                    the failed version is blocked from retry,
                                    the banner reports RECOVERED
```

**No automatic reboot.** A NAS may be streaming a file. Rebooting out from under the
user to apply an update betrays the trust this product sells.

**Retention is a precondition, not a nicety.** An update refuses to proceed if there is
no verified rollback target. A rollback you cannot perform is not a feature.

## Factory Reset

The earlier design copied a deployment into a `@restore` subvolume and redeployed from
it. That cannot work: an ostree deployment is a hardlink checkout backed by the repo
object store, so a copied directory tree is a dead file tree, not a bootable OS. With
composefs the root is an EROFS+overlay assembled from repo objects, so "a copy of the
deployment" is not even a meaningful object.

The mechanism is instead:

1. **`ostree admin pin`** the install-time deployment. It is protected from garbage
   collection, bootable from the GRUB menu, and costs almost no disk space because the
   repo deduplicates it against every other deployment.
2. **Factory reset** = redeploy the pinned commit, reset `/etc` from the image defaults
   (no 3-way merge), optionally clear OS state, and leave `@data` alone.
3. **`@seed`** holds a signed OCI archive of the same image, verified on a timer. It is
   the fallback for a damaged repo — an independent copy, not a btrfs snapshot (a
   snapshot shares extents, so media damage takes both).

The pinned deployment can be promoted to a newer known-good version after it has passed
health checks and soaked, so a reset does not strand the user on an ancient build. Both
the install seed and the last-known-good seed are kept.

**"Data preserved" must mean the NAS still works.** Preserving bytes under `/data` while
wiping the user database, share definitions, UID/GID mappings, and SSH host keys leaves
the data present but inaccessible. Identity and share config live in a capsule under
`/data/.lukenasos/`, and container volumes live on `@data` — not in OS state that a
reset clears.

Before a reset runs, the user sees exactly what survives and what does not, and confirms
by typing the hostname. After it runs, the first boot banner states that the data
survived, with the actual size. That screen is the product.

## Boot Process

```
UEFI firmware
  └─→ GRUB (ESP)  ── reads/decrements boot_counter in grubenv on /boot (ext4)
      └─→ BLS entry → kernel + initramfs (ostree= karg selects the deployment)
          └─→ initramfs mounts @sysroot, assembles the deployment root
              └─→ systemd (PID 1), SELinux enforcing
                  └─→ greenboot health checks
                      ├─ green → boot marked successful
                      └─ red   → rollback to the previous deployment
```

GRUB, not systemd-boot. Earlier revisions specified systemd-boot; greenboot's rollback
path depends on GRUB's `grubenv` boot counter, and following the Fedora bootc default
buys a working recovery path instead of a bespoke bootloader integration. systemd-boot
has its own boot-assessment counter, but wiring greenboot to it is an innovation token
this project should not spend.

## Applications

NAS features (file shares, apps) run as **podman containers**, not baked into the OS.
This is the pattern uCore proved. The OS updates on its own cadence, the apps update on
theirs, and neither can brick the other.

Container storage lives on `@data`, so an OS reset does not delete the user's apps and
their data.

## Multi-Architecture

Each target is its own image artifact, built by a CI matrix, with its own maturity
timeline:

| Target | Artifact | Status |
|--------|----------|--------|
| x86_64 UEFI | `lukenasos-x86_64.iso`, `.qcow2` | **primary — gates every milestone** |
| ARM64 generic (UEFI / QEMU virt) | `lukenasos-arm64-generic.raw` | boot-verified alongside x86_64 |
| Raspberry Pi 4 | `lukenasos-rpi4.raw` | spike; ships when it works |
| Raspberry Pi 5 | `lukenasos-rpi5.raw` | spike; Fedora does not officially support the Pi 5 |

x86_64 QEMU gates the lifecycle demo, the CI end-to-end tests, and the hello-world path.
Pi targets ship as separate images when they are ready and never block the primary
target. Their READMEs carry the honest warning: SD cards are the most failure-prone
storage in a home NAS, which is in tension with the promise this OS makes.

## Security Model

| Property | Mechanism |
|----------|-----------|
| Read-only root | ostree/composefs deployments |
| Update integrity | signed OCI images; the verification policy is pinned in the image and to a specific CI workflow identity |
| Rollback target | pinned deployment, verified before every update |
| SELinux | targeted policy, enforcing from the first milestone |
| Secure Boot | signed kernels via the Fedora chain |
| Network exposure | sshd off by default; nftables required before any network service ships |
| Data isolation | `/data` on its own subvolume, untouched by OS operations |

**The threat model must name the one-way door.** Keyless signing moves the trust anchor
from a key to a GitHub workflow identity — it does not remove it. If the repository is
compromised, an attacker can produce a validly signed malicious image, and because the
verification policy ships *inside* the image, one malicious update can disable
verification for every update after it. Branch protection, a release approval gate, and
the independently verified reset seed are what stand behind that door.

## Escape Hatch

This is a single-maintainer project. An OS that promises safety and then stops shipping
security updates is a liability, so the exit is documented and tested, not implied:

```
sudo bootc switch ghcr.io/ublue-os/ucore:stable
```

You keep `/data` and your containers; you lose the `luke` CLI and the reset mechanism.
CI rebuilds against the upstream base on a schedule so the image does not rot, and
`docs/exit-plan.md` carries the runbook.

`luke` is porcelain. bootc, ostree, and btrfs are all present and you may use them
directly; `luke` reconciles against their real state on every run rather than trusting
its own cache.

## Future

- Data-plane undo: `@data` snapshot timeline, scrub timers, send/receive backups —
  extending "undo" from the OS to the whole NAS.
- Timeline / undo web UI (the M1 event model is its foundation).
- Multi-disk topologies (btrfs RAID1; separate boot and data pools).
- Full-disk encryption (LUKS2 + TPM).
