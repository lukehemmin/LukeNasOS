# Building LukeNasOS

> **Revised 2026-07-12.** The pipeline described in earlier revisions (hand-rolled
> `rpm-ostree compose tree`, dracut, xorriso, a self-hosted ostree remote, `make kernel-*`)
> has been replaced. LukeNasOS is now a **bootc image**: we write a `Containerfile`, build
> an OCI image, and let the bootc toolchain turn it into disk images.

## The idea in one paragraph

LukeNasOS is a bootable container. You build it the way you build any container image,
then convert that image into an installable disk image. Fedora bootc gives us the update
transport, the signing chain, and the bootloader integration for free. What we build on
top is the storage layout, the factory-reset mechanism, greenboot health checks, and the
`luke` CLI.

## Prerequisites

- Linux host (Fedora 44+ recommended; any host with podman and KVM works)
- `podman`, `git`, `make`, `qemu-system-x86_64`, `edk2-ovmf` (UEFI firmware for QEMU)
- ~20 GB free disk, KVM available (`/dev/kvm`)
- `jq`, `skopeo`, `cosign` for the release path

Fedora:

```bash
sudo dnf install podman git make jq skopeo cosign \
  qemu-system-x86 qemu-system-aarch64 edk2-ovmf edk2-aarch64
```

Debian/Ubuntu:

```bash
sudo apt install podman git make jq skopeo \
  qemu-system-x86 qemu-system-arm ovmf qemu-efi-aarch64
```

## Quickstart: see it work

The whole point of this project is one demo. Run it locally:

```bash
make demo
```

That builds the image, publishes v1 and v2 (plus a deliberately broken v2) to a local
registry, boots a VM, and drives the full lifecycle: install → update → break → automatic
rollback → factory reset with the data intact. It is the same script CI runs, so if it
passes for you it passes for us.

If you only want to try the OS rather than build it:

```bash
./scripts/try-lukenasos.sh
```

That downloads the latest image and boots it in QEMU. To experience the update and undo
path on a fresh install, use the `-1` image published alongside each release: it is one
version behind, so `luke update` has something to find.

## Repository layout

```
LukeNasOS/
├── Containerfile              # the OS, as a container image
├── Makefile                   # demo, build, test entry points
├── luke/                      # the luke CLI (update, undo, factory-reset, doctor, status)
├── installer/
│   └── luke.ks                # kickstart: partitions, subvolumes, bootc install
├── scripts/
│   ├── demo-lifecycle.sh      # the E2E test; also the demo
│   ├── try-lukenasos.sh       # download + boot in QEMU (adopters)
│   └── install-disk.sh        # partition/mkfs/subvolume + bootc install to-filesystem
├── config/
│   ├── greenboot/             # health checks and the red script
│   └── systemd/               # units and timers
├── docs/
│   ├── errors.md              # every error code, its cause, and its fix
│   └── exit-plan.md           # how to rebase away from this project
└── .github/workflows/         # build matrix, sign, QEMU smoke test, release
```

## Building the image

```bash
podman build -t lukenasos:dev .
```

The `Containerfile` starts from a pinned Fedora bootc (or uCore) digest and adds:

- the `luke` CLI and its systemd units
- greenboot health checks
- podman/quadlet defaults for the NAS container layer
- the container signature policy (`/etc/containers/policy.json`), pinned to our release
  workflow identity
- SELinux policy for the custom paths

Never bake credentials into the `Containerfile`. CI greps for them, because a dev SSH key
that ships to a public registry is the classic way this kind of project embarrasses
itself.

## Turning the image into a disk

Two paths. We use both, for different reasons.

### 1. Kickstart install (primary)

Anaconda already knows how to partition disks, label SELinux contexts, and install a
bootloader. `installer/luke.ks` uses the `ostreecontainer` directive to deploy our image
straight from a registry, and defines the disk contract:

```
biosboot (1M) + ESP (512M, FAT32) + /boot (1G, ext4) + btrfs root
  └── subvolumes: root, @data, @seed
```

`/boot` must be ext4. GRUB cannot write `grubenv` on btrfs, and greenboot's automatic
rollback depends on GRUB decrementing a boot counter there. Put it on btrfs and the
headline feature fails silently. This is the one partition decision that is not
negotiable.

The 1 MiB `biosboot` partition is unused on UEFI and costs nothing there. Without it, a
BIOS machine stalls forever at "Installation Destination (Kickstart insufficient)" and
the unattended install quietly becomes an interactive one nobody is watching.

### How automatic rollback is actually wired (read before bumping the base)

The counter that makes rollback happen is not ours, and it does not live where you would
guess:

```
greenboot RPM
  └── /usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg    ← the snippet
        │   (decrement boot_counter; at 0 → set default=1)
        ▼
      bootupd assembles configs.d/* at install time
        ▼
      /boot/grub2/grub.cfg on the installed machine   ← "Generated by bootupd"
```

Nothing reads `/etc/grub.d/` on this path, whatever a stray `greenboot.cfg` there might
suggest. If that snippet stops reaching `configs.d/`, GRUB never decrements the counter,
a broken update boots forever, and the banner stays green. Silently. This is the failure
mode with no error message, which is why CI asserts the mechanism
(`rollback-mechanism-contract`) as well as the behaviour (`lifecycle`).

**A base release bump is therefore never just a digest.** 42 → 44 rewrote greenboot in
Rust (0.15 → 0.16), consolidated nine systemd units into three, and moved that snippet's
name and owner. The three units to enable today are `greenboot-healthcheck.service`,
`greenboot-set-rollback-trigger.service`, and `greenboot-success.target`; expect that list
to change again. Budget a migration with the lifecycle E2E as the gate, and let the weekly
rebuild's EOL watch tell you when it is coming.

### 2. `bootc install to-filesystem` (custom layouts)

`scripts/install-disk.sh` partitions the disk, creates the filesystems and subvolumes,
mounts the target, and runs `bootc install to-filesystem`. Use this when you need a layout
Anaconda cannot express.

`bootc install to-filesystem` is not a partitioner. It installs into a filesystem you have
already prepared: partitioning, `mkfs`, subvolume creation, kernel arguments
(`rootflags=subvol=@sysroot`), ESP handling, and SELinux labelling are all on us. Budget
accordingly — this is the largest schedule risk in the project.

### Installer ISO

```bash
make iso                    # → build/lukenasos-x86_64.iso
```

`scripts/build-iso.sh` remasters the Fedora netinst ISO with `installer/luke.ks`
using xorriso + mtools only — no loop devices, no privileges, no container — so it
works the same on a laptop, inside an unprivileged LXC, and on a CI runner. The
netinst's UEFI boot config lives inside the hidden El Torito FAT image; mtools edits
it in place, which is why mkksiso (whose mkefiboot step needs loop devices) is not
used. The script verifies the output: kickstart present, `inst.ks` wired into both
the BIOS and UEFI boot paths.

The result is an **online installer**: at install time it pulls the OS image named
by `--image` (default `ghcr.io/lukehemmin/lukenasos:stable`), which therefore must
be published and reachable. `--serial` adds `inst.text console=ttyS0` for headless
installs; `--offline` builds the self-contained anaconda ISO via osbuild
image-builder instead (needs loop devices — CI or a real host, not an unprivileged
LXC). The release workflow runs the same script and attaches the ISO to the GitHub
release.

### Image conversion

`bootc-image-builder` was archived in June 2026 and folded into osbuild's `image-builder`.
Verify what the current tool actually supports (btrfs subvolume customization, ESP sizing,
kernel arguments, ARM64 raw output) before relying on it. Where it falls short, the
kickstart path above is the fallback.

## Architecture targets

Each target is a separate artifact from a CI matrix, with its own maturity timeline:

| Target | Artifact | Status |
|--------|----------|--------|
| x86_64 UEFI | `lukenasos-x86_64.iso`, `.qcow2` | **primary — gates every milestone** |
| ARM64 generic (UEFI/QEMU virt) | `lukenasos-arm64-generic.raw` | boot-verified |
| Raspberry Pi 4 | `lukenasos-rpi4.raw` | spike; ships when it works |
| Raspberry Pi 5 | `lukenasos-rpi5.raw` | spike; Fedora does not officially support the Pi 5 |

x86_64 gates the demo, the CI end-to-end test, and the documented hello-world path. Pi
images ship when they are ready and never block the primary target. Raspberry Pi bootc
support exists at community-patch level (bootupd needs patching for the Pi firmware
layout), and SD cards are the most failure-prone storage in a home NAS, which is in
tension with what this OS promises. The Pi images say so on the tin.

## Testing

`scripts/demo-lifecycle.sh` is both the demo and the end-to-end test. It runs against a
**local registry**, not GHCR:

- CI must be able to test an image that has not been published yet.
- Tags are mutable and registry propagation races; a core test cannot depend on that.
- The "reject an unsigned or tampered image" test is only reproducible with a registry we
  control.

The lifecycle test asserts, at minimum:

1. install → boot → `● OK`
2. `luke update` stages v2; nothing reboots
3. reboot → v2 active
4. update to the deliberately broken image → greenboot fails → the GRUB boot counter
   decrements → the previous deployment boots → the banner shows `▲ RECOVERED` → the failed
   digest is blocked from retry
5. `luke factory-reset` → the OS returns to the pinned deployment, and the file written to
   `/data` is still there and still readable through the Samba share
6. power cut during staging, and again after staging but before finalize → the system boots
   and `luke status` explains what happened

Machine assertions run against `--json` output and exit codes. Human-readable output is
compared as normalized snapshots (timestamps and sizes stripped) so that a progress bar
does not break CI.

What QEMU cannot test — real Pi boot chains, SD card power-loss behaviour, HDD spin-up
delays that can make greenboot mistake a slow disk for a failed update, vendor UEFI quirks
— moves to the hardware milestone and is documented as such.

## Release

```
git tag v0.1.0 && git push --tags
  └─→ GitHub Actions matrix
      ├── build each target
      ├── sign (cosign, pinned to the release workflow identity)
      ├── QEMU smoke test (x86_64 gates the release)
      ├── publish images to GHCR
      └── publish disk images + the N-1 qcow2 to GitHub Releases
```

A scheduled workflow rebuilds against the upstream base image so the OS keeps receiving
security updates even during a quiet period. If this project ever stops, users can
`bootc switch` to the upstream base and keep their data — see `docs/exit-plan.md`.
