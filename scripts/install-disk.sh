#!/usr/bin/env bash
# install-disk.sh — the `bootc install to-filesystem` path, for layouts
# Anaconda cannot express.
#
# bootc install to-filesystem is NOT a partitioner. Everything below —
# partitioning, mkfs, subvolumes, kernel args, ESP, SELinux labelling —
# is on us. Prefer installer/luke.ks unless you need a custom layout.
#
# Usage: install-disk.sh <block-device> <image-ref>
#   e.g. install-disk.sh /dev/vdb localhost:5000/lukenasos:v1
#
# DESTROYS everything on <block-device>.

set -o errexit -o nounset -o pipefail

DEV="${1:?usage: install-disk.sh <block-device> <image-ref>}"
IMAGE="${2:?usage: install-disk.sh <block-device> <image-ref>}"

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
[ -b "$DEV" ] || { echo "$DEV is not a block device" >&2; exit 1; }

echo "About to WIPE $DEV and install $IMAGE."
echo "Partition contract: ESP 512M (FAT32) + /boot 1G (ext4, grubenv lives here) + btrfs"
read -r -p "Type the device name ($DEV) to confirm: " answer
[ "$answer" = "$DEV" ] || { echo "Mismatch. Nothing was changed."; exit 1; }

# ── partition ─────────────────────────────────────────────────────────────
sgdisk --zap-all "$DEV"
sgdisk -n1:0:+512M -t1:ef00 -c1:ESP \
       -n2:0:+1G   -t2:8300 -c2:boot \
       -n3:0:0     -t3:8300 -c3:root "$DEV"
partprobe "$DEV"; sleep 1

p() { # partition path: /dev/sda1 vs /dev/nvme0n1p1
    case "$DEV" in *[0-9]) echo "${DEV}p$1" ;; *) echo "${DEV}$1" ;; esac
}

# ── filesystems ───────────────────────────────────────────────────────────
mkfs.vfat -F32 -n EFI "$(p 1)"
# ext4 /boot is the non-negotiable partition: GRUB cannot write grubenv on
# btrfs, and greenboot's boot counter lives in grubenv.
mkfs.ext4 -F -L lukenasos-boot "$(p 2)"
mkfs.btrfs -f -L lukenasos-root "$(p 3)"

# ── subvolumes ────────────────────────────────────────────────────────────
mnt=$(mktemp -d)
mount "$(p 3)" "$mnt"
btrfs subvolume create "$mnt/root"     # the ostree sysroot
btrfs subvolume create "$mnt/@data"    # user data — survives factory reset
btrfs subvolume create "$mnt/@seed"    # recovery seed archive
umount "$mnt"

# ── mount the target the way the running system will see it ──────────────
mount -o subvol=root,compress=zstd:1,noatime "$(p 3)" "$mnt"
mkdir -p "$mnt/boot"
mount "$(p 2)" "$mnt/boot"
mkdir -p "$mnt/boot/efi"
mount "$(p 1)" "$mnt/boot/efi"

# ── install ───────────────────────────────────────────────────────────────
bootc install to-filesystem \
    --source-imgref "docker://$IMAGE" \
    --karg "rootflags=subvol=root,compress=zstd:1" \
    --karg "rw" \
    "$mnt"

# ── the safety rig (what %post does on the kickstart path) ────────────────
# Pin the install deployment: the factory-reset target must never be
# garbage-collected. ostree admin needs the deployment's sysroot.
ostree admin --sysroot="$mnt" pin 0 || \
    echo "WARN: could not pin the install deployment — run 'ostree admin pin 0' on first boot" >&2

sync
umount -R "$mnt"
echo "Done. $DEV boots LukeNasOS. First boot captures the @seed archive."
