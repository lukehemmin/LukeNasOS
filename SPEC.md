# LukeNasOS Technical Specification

> **Revised 2026-07-12.** Earlier revisions specified a hand-rolled ostree pipeline, a
> `@restore` subvolume holding a bootable OS copy, a two-partition layout, systemd-boot,
> and kernel options that do not exist (`CONFIG_OSTREE`). None of that survives contact
> with how bootc/ostree actually works. This is the normative contract; `ARCHITECTURE.md`
> explains why.

## 1. System Overview

| Field | Value |
|-------|-------|
| Name | LukeNasOS |
| Kind | Bootable OCI container image (bootc) |
| Base | Fedora bootc / uCore (pinned digest) |
| Init | systemd |
| Update model | bootc — signed OCI image pull, staged deployment, atomic switch |
| Rollback | greenboot (health-check driven, automatic) + `bootc rollback` |
| Factory reset | pinned ostree deployment + signed OCI seed archive |
| Bootloader | GRUB (required by greenboot's `boot_counter`) |
| Filesystem | btrfs (root), ext4 (`/boot`), FAT32 (ESP) |
| Architecture | x86_64 (primary), ARM64 generic, Raspberry Pi 4/5 (separate targets) |
| SELinux | targeted policy, **enforcing from M1** |
| Secure Boot | Fedora signing chain |

## 2. Disk Contract

### 2.1 Partitions (GPT)

```
Partition 1: EFI System Partition
  Type: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  FS:   FAT32
  Size: 512 MB
  Mount: /boot/efi

Partition 2: Boot
  Type: Linux filesystem
  FS:   ext4                     ← REQUIRED: GRUB cannot write grubenv on btrfs
  Size: 1 GB
  Mount: /boot
  Contents: kernels, initramfs, BLS entries, grubenv (boot_counter)

Partition 3: Root
  Type: Linux filesystem
  FS:   btrfs
  Size: remainder
  Mount: /sysroot
  Options: compress=zstd:1,noatime
```

**Normative:** `grubenv` MUST live on partition 2. greenboot's automatic rollback depends
on GRUB decrementing `boot_counter` there; on btrfs that write fails silently and
automatic rollback does not happen. This is the single most important line in this
document.

### 2.2 Subvolumes

```
btrfs subvolume create @sysroot   → /sysroot           (holds /ostree: repo, deployments, stateroot var)
btrfs subvolume create @data      → /var/mnt/data      (user data; /data is a symlink)
btrfs subvolume create @seed      → /var/lib/luke/seed (OCI archive, not a bootable copy)
```

`/var` is ostree's stateroot var under `/ostree/deploy/<stateroot>/var`. Mounting a
dedicated subvolume over it is an open spike, not an assumption — the default is to use
ostree's own var rather than fight it. Image `/var` content is seeded once on first
deployment via `tmpfiles.d` and is **not** refreshed by later updates; anything that must
survive an update belongs in the image or on `@data`.

### 2.3 Space protection (normative)

| Control | Value |
|---------|-------|
| `@data` qgroup limit | pool size − OS reserve (15–20 GB) |
| Unallocated warning | `btrfs fi usage` unallocated < 2 GiB → `DEGRADED` |
| Balance timer | periodic `balance -dusage=10` |
| `luke update` pre-flight | reads `btrfs fi usage` (never `statvfs`) |

qgroups cap data usage but do not prevent metadata exhaustion, which forces the
filesystem read-only. The controls above are layered for that reason.

### 2.4 Mounts

| Path | Source | Options |
|------|--------|---------|
| `/sysroot` | `@sysroot` | `subvol=@sysroot,compress=zstd:1,noatime` |
| `/boot` | partition 2 | `defaults` |
| `/boot/efi` | ESP | `fmask=0077,dmask=0077` |
| `/var/mnt/data` | `@data` | `subvol=@data,compress=zstd:1,noatime` |
| `/data` | symlink → `/var/mnt/data` | baked into the image |

## 3. Kernel

The kernel is Fedora's. We do not build one. The features we need are already enabled
there: btrfs, EFI stub, efivarfs, virtio, NVMe, SELinux, module signing.

There is **no `CONFIG_OSTREE`** — ostree is userspace. Earlier revisions listed it; it
does not exist.

### Default kernel cmdline

```
ostree=...                       (managed by ostree; never hand-edited)
root=UUID=<btrfs-part-uuid>
rootflags=subvol=@sysroot
console=tty0
console=ttyS0,115200n8
selinux=1 enforcing=1
```

## 4. Update Contract

### 4.1 Source

```
Registry:  ghcr.io/lukehemmin/lukenasos
Channels:  :stable  :beta  :dev        (tags)
Transport: bootc pull (OCI)
```

The signature verification policy is baked into the image at `/etc/containers/policy.json`
and pinned to the release workflow identity. An image that fails verification is rejected
before any state changes.

### 4.2 State machine

```
                 ┌──────────┐
                 │  BOOTED  │◄──────────────────────────┐
                 └────┬─────┘                           │
        luke update   │                                 │ greenboot red:
                      ▼                                 │ GRUB boots previous,
                 ┌──────────┐                           │ failed digest blocked
                 │  STAGED  │  (nothing rebooted yet)   │
                 └────┬─────┘                           │
        reboot        │                                 │
                      ▼                                 │
                 ┌───────────┐  greenboot green   ┌─────┴────────┐
                 │ ACTIVATED ├───────────────────►│  RECOVERED   │
                 └───────────┘                    │  (or BOOTED) │
                                                  └──────────────┘
```

An unclean shutdown while STAGED loses the staged deployment: ostree finalizes it on
clean shutdown only. `luke status` MUST detect and report this. It is not a silent no-op.

### 4.3 Rules (normative)

- An update MUST verify a rollback target exists and is pinned **before** staging. No
  target, no update.
- No automatic reboot. Ever. The default is to wait.
- A version that triggered an automatic rollback is blocked by **digest** (not tag) and
  is not retried without `--force`.
- `luke undo` MUST refuse to re-activate a blocked digest (undo-of-undo would restore the
  broken version you just escaped).

## 5. Factory Reset (`luke factory-reset`)

### 5.1 Mechanism

```
Install time:  ostree admin pin <install deployment>   # survives GC forever, boots from GRUB
               write signed OCI archive → @seed

Promotion:     a deployment may become the new pinned target after it passes health
               checks and soaks. Both the install seed and the last-known-good seed
               are retained.

Reset:         1. verify the pinned commit (or @seed archive if the repo is damaged)
               2. discard any staged deployment
               3. redeploy the pinned commit
               4. reset /etc from image defaults (no 3-way merge)
               5. clear OS state (user's choice)
               6. NEVER touch @data
               7. reboot
```

The reset is performed against a new deployment and only becomes the default once
complete, so power loss mid-reset leaves the system bootable.

### 5.2 What survives (normative)

| Survives | Cleared |
|----------|---------|
| `/data` — all user files | OS configuration (`/etc`) |
| `/data/.lukenasos/` — identity capsule: users, UID/GID, share definitions, SSH host keys, machine-id | installed apps' OS-level state |
| container volumes (they live on `@data`) | logs, caches |

"Data preserved" that leaves the shares inaccessible is a broken promise. The identity
capsule is what makes the preserved bytes usable after a reset.

### 5.3 Confirmation

Before any destructive action the user sees what survives and what does not, with real
numbers, and confirms by **typing the hostname** (not `y/n`). Scripts use `--yes`. After
the reset, the first boot banner reports that the data survived, with its size.

## 6. `luke` CLI

`luke` is the only user-facing surface. It never makes the user type `bootc` or `ostree`,
but it does not hide them either — it reconciles against their real state on every run.
bootc/ostree are the source of truth; `luke`'s own state file is a cache and an
annotation.

| Verb | Meaning |
|------|---------|
| `luke status` | current state; `--events` for history; `--json` for machines |
| `luke update` | check, verify, stage. `--reboot` to activate. `--check` to look only |
| `luke undo` | the one user-facing "take it back" — reverts the last change |
| `luke rollback` | alias for `luke undo --os` |
| `luke factory-reset` | reset the OS, keep the data. Long name on purpose |
| `luke doctor` | active checks → a verdict and the exact command that fixes it |

### 6.1 Output contract (normative)

- **Exit codes:** `0` success, `1` warning, `2` error, `77` nothing to do (already up to
  date). Automation must be able to tell "updated" from "already current".
- **`--json`** on every verb: `{ok, code, message, safe_state, fix, events, logs}`.
- **Every error states four things:** what failed, the likely cause, a copy-pasteable
  next command, and a stable doc anchor (`docs/errors.md#LUKE-Exxx`). Users photograph the
  screen and search that code.
- **Never color alone:** `● OK` / `▲ RECOVERED` / `✕ DEGRADED` — symbol plus color, for
  serial consoles and color-blind users.
- Progress is text, never a spinner (serial-console and log safe), and is suppressed when
  stdout is not a TTY.
- English is the language of the CLI, the README, and all error messages.

### 6.2 Long operations

`luke update` runs as a systemd unit and the CLI attaches to it, so closing SSH does not
kill the update. A second `luke update` attaches to the running one instead of erroring.

## 7. Boot Banner

The banner is the appliance's only home screen. Its hierarchy is fixed:

```
1. VERDICT     ● OK   ▲ RECOVERED   ✕ DEGRADED
2. LAST EVENT  (when RECOVERED) what happened, why, when
3. VERSION     booted version; staged version if one is waiting
4. NEXT        luke status · luke doctor
```

What a user must learn in half a second is whether they are fine — not which version they
are running.

## 8. Health Checks and Rollback

- greenboot runs the checks; `bootc rollback` performs the revert.
- GRUB's one-shot fallback (boot_counter exhausted) MUST be made permanent by the red
  script, or the next boot returns to the broken deployment.
- A flapping check (fails once, passes the next time) MUST NOT trigger a rollback loop.
- Health-check timeouts MUST allow for spinning disks. An HDD spin-up delay must never be
  mistaken for a failed update.
- Automatic rollback can be turned off (`luke config auto-rollback off`) for people who
  are deliberately experimenting. When it is off, the banner says so, permanently.

## 9. Networking

`systemd-networkd`, DHCP by default. `sshd` disabled by default; enabling it is an
explicit, documented action. `nftables` is required before any network-facing service
ships.

## 10. Users

First boot creates the administrator. There is no shipped default password: QEMU images
document a first-login credential that must be changed on first use, and the installer
creates the user via kickstart. An appliance you cannot log into is not an appliance.

## 11. Build and Distribution

| Artifact | Target | Gate |
|----------|--------|------|
| `lukenasos-x86_64.iso` / `.qcow2` | x86_64 UEFI | **primary — gates all milestones** |
| `lukenasos-arm64-generic.raw` | ARM64 UEFI / QEMU virt | boot check |
| `lukenasos-rpi4.raw`, `lukenasos-rpi5.raw` | Raspberry Pi | spike; never blocks the primary |

Images ship on GitHub Releases; OS images ship on GHCR. CI is a GitHub Actions matrix
(build → sign → QEMU smoke test → publish), plus a scheduled rebuild against the upstream
base so the image does not rot if the maintainer goes quiet.

## 12. Branding

```ini
NAME="LukeNasOS"
ID=lukenasos
PRETTY_NAME="LukeNasOS"
VARIANT="NAS"
VARIANT_ID=nas
```

Default hostname: `luke`.
