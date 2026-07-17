# LukeNasOS kickstart — the primary install path.
#
# Anaconda owns partitioning, mkfs, SELinux labelling, and the bootloader;
# `ostreecontainer` deploys our bootc image straight from a registry. This
# is the lowest-risk installer: everything custom about LukeNasOS is the
# btrfs subvolume layout and the post-install safety rig (pin + seed).
#
# Interactive by contract (design review, 2026-07-16): the install asks about
# things that cannot break recovery — which disk to erase, and (with the
# --interactive ISO) account, network, and locale. It never asks about the
# partition layout, the filesystems, the subvolumes, the bootloader, or the
# update source: those ARE the recovery contract.
#
# Disk contract (SPEC.md §2 — the ext4 /boot is NOT negotiable: GRUB cannot
# write grubenv on btrfs, and greenboot's automatic rollback depends on the
# boot counter living there):
#
#   BIOSBOOT 1 MiB          (BIOS/GPT only; unused on UEFI, harmless there)
#   ESP    512 MiB  FAT32   /boot/efi
#   BOOT     1 GiB  ext4    /boot        (grubenv, boot_counter)
#   ROOT     rest   btrfs   subvolumes: root (@sysroot), @data, @seed

text
lang en_US.UTF-8
keyboard us
timezone Etc/UTC --utc
network --bootproto=dhcp --device=link --activate

# First login must exist: a machine you can boot but not enter is a failed
# install. The account is created here without a password; %post sets a
# random per-install SETUP TOKEN and expires it, so the first login forces a
# change. There is no well-known password on the network — see %post.
rootpw --lock
user --name=luke --groups=wheel

# The update source. The environment-provided REGISTRY makes the same
# kickstart serve CI (localhost registry) and real installs (GHCR).
ostreecontainer --url=ghcr.io/lukehemmin/lukenasos:stable --no-signature-verification

# Which disk gets erased is decided by %pre and lands here. Without it,
# `clearpart --all` means EVERY attached disk — data loss on the multi-disk
# machines that are this product's core audience.
%include /tmp/luke-disk.ks

zerombr
clearpart --all --initlabel --disklabel=gpt

# biosboot: 1 MiB, no filesystem, GRUB's stage-2 home on BIOS+GPT. Without it
# a BIOS machine stalls forever at "Installation Destination (Kickstart
# insufficient)" and the unattended install silently becomes an interactive
# one with nobody watching (observed on a real boot, 2026-07-16).
part biosboot  --fstype=biosboot --size=1
part /boot/efi --fstype=efi   --size=512
part /boot     --fstype=ext4  --size=1024 --label=lukenasos-boot
part btrfs.01  --fstype=btrfs --grow      --label=lukenasos-root

btrfs none --label=lukenasos-root btrfs.01
btrfs /             --subvol --name=root  LABEL=lukenasos-root
btrfs /var/mnt/data --subvol --name=@data LABEL=lukenasos-root
btrfs /var/mnt/seed --subvol --name=@seed LABEL=lukenasos-root

# quiet + loglevel=4: kernel chatter reads as brokenness on an appliance that
# sells trust. The boot banner (SPEC §7) is the home screen, not dmesg. No
# plymouth splash: it would fight the serial console (SPEC §3) and the banner.
bootloader --append="quiet loglevel=4"

reboot

%pre --erroronfail --log=/tmp/luke-pre.log
# ── which disk becomes the NAS ────────────────────────────────────────────
# This script decides exactly ONE thing: which disk gets erased. Everything
# else about the layout is fixed above by SPEC §2.
#
#   1 candidate  → auto-select it
#   N candidates → inst.luke.disk=<path> wins; otherwise a console menu with a
#                  typed ERASE confirmation
#   0 candidates → halt with an English error
#
# A failure here MUST halt the install (--erroronfail). Falling through would
# hand an unrestricted `clearpart --all` to a machine full of the user's data.
set -o errexit -o nounset -o pipefail

INCLUDE="${LUKE_INCLUDE:-/tmp/luke-disk.ks}"
CANDIDATES="${LUKE_CANDIDATES:-/tmp/luke-candidates}"
# /dev/console follows the console= kernel argument, so one path serves both a
# monitor and a serial line. The three overrides above and below exist so the
# disk-choosing logic can be tested off a real installer (tests/pre-disk.sh);
# under anaconda none of them are set and the defaults are the real thing.
CONSOLE="${LUKE_CONSOLE:-/dev/console}"
CONSOLE_IN="${LUKE_CONSOLE_IN:-$CONSOLE}"
CMDLINE="${LUKE_CMDLINE:-/proc/cmdline}"
BYID_DIR="${LUKE_BYID_DIR:-/dev/disk/by-id}"
# ESP 512M + /boot 1G + a root worth having. Also the reason the installer's
# own 4 MiB OEMDRV kickstart carrier never shows up as a target.
MIN_BYTES=$((8 * 1024 * 1024 * 1024))

say() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" > "$CONSOLE" 2>/dev/null || true
}

ask() {
    printf '%s' "$*" > "$CONSOLE" 2>/dev/null || true
}

halt_install() {
    say ""
    say "  LukeNasOS install stopped."
    say "  $1"
    say ""
    say "  $2"
    say ""
    say "  Log: /tmp/luke-pre.log   Shell: Ctrl+Alt+F2 (or the serial console)"
    say ""
    exit 1
}

disk_byid() {
    # The stable name for a disk. Kernel names are boot-order dependent: plug
    # in a USB stick and yesterday's sdb is today's sdc. Empty when a disk has
    # no by-id link at all (virtio without serial=, common in VMs).
    kname="$1"; best=""
    for link in "$BYID_DIR"/*; do
        [ -L "$link" ] || continue
        case "${link##*/}" in *-part[0-9]*) continue ;; esac
        [ "$(readlink -f "$link" 2>/dev/null || true)" = "/dev/$kname" ] || continue
        case "${link##*/}" in
            wwn-*|nvme-eui.*) printf '%s' "$link"; return 0 ;;
        esac
        [ -n "$best" ] || best="$link"
    done
    printf '%s' "$best"
}

collect_candidates() {
    : > "$CANDIDATES"
    for kname in $(lsblk -dno KNAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}'); do
        dev="/dev/$kname"
        # Read-only devices are not install targets.
        [ "$(lsblk -dno RO "$dev" 2>/dev/null | tr -d ' ')" = "0" ] || continue
        # The install medium (CD or USB) carries iso9660 somewhere.
        lsblk -no FSTYPE "$dev" 2>/dev/null | grep -qx iso9660 && continue
        # OEMDRV is anaconda's kickstart carrier, not a disk anyone means to erase.
        lsblk -no LABEL "$dev" 2>/dev/null | grep -qx OEMDRV && continue
        bytes=$(lsblk -dnbo SIZE "$dev" 2>/dev/null | tr -d ' ')
        [ -n "$bytes" ] && [ "$bytes" -ge "$MIN_BYTES" ] 2>/dev/null || continue
        size=$(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' ')
        model=$(lsblk -dno MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]*$//')
        [ -n "$model" ] || model="$(lsblk -dno TRAN "$dev" 2>/dev/null | tr -d ' ') disk"
        printf '%s\t%s\t%s\t%s\n' "$(disk_byid "$kname")" "$kname" "$size" "$model" >> "$CANDIDATES"
    done
}

karg_value() {
    for a in $(cat "$CMDLINE"); do
        case "$a" in "$1"=*) printf '%s' "${a#*=}"; return 0 ;; esac
    done
}

# ignoredisk --only-use is what makes `clearpart --all` safe: it scopes "all"
# to this one disk. The kernel name is correct here — it cannot change between
# this script and partitioning in the same boot, and anaconda parses it
# without by-id resolution quirks. The by-id path is what humans are shown.
write_include() {
    printf 'ignoredisk --only-use=%s\n' "$1" > "$INCLUDE"
    say "  Install target: /dev/$1  (${2:-no stable by-id link})"
}

choose_from_menu() {
    total=$(wc -l < "$CANDIDATES")
    say ""
    say "  LukeNasOS — which disk should become this NAS?"
    say "  The disk you choose will be ERASED. Every other disk is left untouched."
    say ""
    n=1
    while IFS="$(printf '\t')" read -r byid kname size model; do
        say "    $n) /dev/$kname   $size   $model"
        [ -n "$byid" ] && say "       $byid"
        n=$((n + 1))
    done < "$CANDIDATES"
    say ""
    say "  To skip this prompt on a headless machine, boot the installer with:"
    say "    inst.luke.disk=/dev/disk/by-id/<name>"
    say ""

    exec 3< "$CONSOLE_IN" || halt_install \
        "No console is available, and this machine has $total disks." \
        "Pick the target explicitly: inst.luke.disk=/dev/disk/by-id/<name>"

    while :; do
        ask "  Disk number [1-$total]: "
        read -r choice <&3 || halt_install \
            "No console input is available, and this machine has $total disks." \
            "Pick the target explicitly: inst.luke.disk=/dev/disk/by-id/<name>"
        case "$choice" in
            ''|*[!0-9]*) say "  '$choice' is not a number." ; continue ;;
        esac
        if [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
            say "  Pick a number between 1 and $total."
            continue
        fi
        break
    done

    line=$(sed -n "${choice}p" "$CANDIDATES")
    byid=$(printf '%s' "$line" | cut -f1)
    kname=$(printf '%s' "$line" | cut -f2)
    size=$(printf '%s' "$line" | cut -f3)
    model=$(printf '%s' "$line" | cut -f4)

    say ""
    say "  Selected: /dev/$kname   $size   $model"
    say "  EVERYTHING ON THIS DISK WILL BE DESTROYED. This cannot be undone."
    ask "  Type ERASE to confirm: "
    read -r confirm <&3 || confirm=""
    exec 3<&-
    [ "$confirm" = "ERASE" ] || halt_install \
        "Not confirmed — nothing has been changed on any disk." \
        "Reboot the installer to try again."
    write_include "$kname" "$byid"
}

collect_candidates
count=$(wc -l < "$CANDIDATES")

if [ "$count" -eq 0 ]; then
    halt_install \
        "No disk big enough to install on (need at least 8 GiB)." \
        "Attach a disk and reboot the installer. Disks seen: $(lsblk -dno KNAME,SIZE,TYPE 2>/dev/null | tr '\n' ';')"
fi

want=$(karg_value inst.luke.disk || true)

if [ -n "${want:-}" ]; then
    case "$want" in
        /dev/disk/by-id/*)
            link="$BYID_DIR/${want##*/}"
            [ -L "$link" ] || halt_install \
                "inst.luke.disk=$want does not exist on this machine." \
                "Stable names here: $(ls "$BYID_DIR" 2>/dev/null | grep -v -e '-part' | tr '\n' ' ')"
            kname=$(readlink -f "$link"); kname="${kname#/dev/}"
            ;;
        /dev/*)
            # A kernel name is accepted only when the disk has no stable name
            # at all (virtio without serial=). If a by-id exists, refuse the
            # unstable one and print the stable path — the whole point is to
            # erase the disk they meant.
            kname="${want#/dev/}"
            stable=$(disk_byid "$kname")
            [ -z "$stable" ] || halt_install \
                "inst.luke.disk=$want is a kernel name, and this disk has a stable one." \
                "Use inst.luke.disk=$stable instead — kernel names can point at a different disk on the next boot."
            ;;
        *)
            halt_install \
                "inst.luke.disk=$want is not a device path." \
                "Use inst.luke.disk=/dev/disk/by-id/<name>."
            ;;
    esac
    cut -f2 "$CANDIDATES" | grep -qx "$kname" || halt_install \
        "inst.luke.disk=$want resolves to /dev/$kname, which is not an install candidate." \
        "It is missing, too small (<8 GiB), read-only, or the install medium. Candidates: $(cut -f2 "$CANDIDATES" | tr '\n' ' ')"
    write_include "$kname" "$(disk_byid "$kname")"
elif [ "$count" -eq 1 ]; then
    byid=$(cut -f1 "$CANDIDATES")
    kname=$(cut -f2 "$CANDIDATES")
    write_include "$kname" "$byid"
else
    choose_from_menu
fi
%end

%post --erroronfail
set -euo pipefail

# 1. Pin the install deployment. This is the factory-reset target; pinning
#    means ostree cleanup can never garbage-collect it. No pin, no reset.
ostree admin pin 0

# 2. The setup token — this machine's first-login secret.
#    A well-known password (the old luke/lukenasos) is not a secret: it makes
#    ownership a race, and the first stranger on the LAN to reach the setup
#    page wins. A per-install token printed ONLY on the console makes physical
#    or console access the proof of ownership.
#    Format is a UX decision, not just an entropy one: this gets read off a TV
#    across a room and typed into a phone. Crockford-style base32, minus 0/1
#    (30 chars, ~59 bits over 12 chars), grouped for the eye. Automated
#    installs override the account with their own --kickstart, as before.
ALPHABET='23456789abcdefghjkmnpqrstvwxyz'
raw=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc "$ALPHABET")
[ "${#raw}" -ge 12 ] || { echo "setup token generation failed" >&2; exit 1; }
token="${raw:0:4}-${raw:4:4}-${raw:8:4}"
printf 'luke:%s\n' "$token" | chpasswd
chage -d 0 luke                      # first login must change it

mkdir -p /var/lib/lukenasos
printf '%s\n' "$token" > /var/lib/lukenasos/setup-token
chmod 0600 /var/lib/lukenasos/setup-token
unset token raw

# 3. @seed: the disaster-recovery fallback — an OCI archive of the exact
#    installed image on its own subvolume, for when even the ostree repo is
#    damaged. Captured on first boot with network (the installer environment
#    may be offline); the unit disarms itself when done.
cat > /etc/systemd/system/lukenasos-seed.service <<'EOF'
[Unit]
Description=LukeNasOS: capture the install image as the @seed recovery archive
After=network-online.target var-mnt-seed.mount
Wants=network-online.target
ConditionPathExists=!/var/lib/lukenasos/seed-captured

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'ref=$(. /etc/lukenasos/luke.conf && echo $IMAGE_REF); \
  skopeo copy docker://$ref oci-archive:/var/mnt/seed/seed.oci-archive && \
  mkdir -p /var/lib/lukenasos && touch /var/lib/lukenasos/seed-captured'
[Install]
WantedBy=multi-user.target
EOF
systemctl enable lukenasos-seed.service

# 4. Event zero.
printf '{"ts":"%s","type":"installed","detail":{}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /var/lib/lukenasos/events.jsonl

# 5. Close the longest silence in the journey. The install has been scrolling
#    anaconda text for ~10 minutes and is about to reboot without a word.
{
    echo ""
    echo "  LukeNasOS is installed."
    echo "  Rebooting — first boot takes about a minute and then prints your"
    echo "  setup address and token on this screen."
    echo ""
} > /dev/console 2>/dev/null || true
%end
