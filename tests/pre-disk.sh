#!/usr/bin/env bash
# tests/pre-disk.sh — the kickstart's disk-targeting %pre, tested off a real
# installer.
#
# Why this file exists: that %pre decides which disk gets ERASED. Before it,
# `clearpart --all` meant every attached disk — on a multi-disk NAS that is
# data loss, not a UX defect. A bug here destroys the user's data, and the
# only other place it runs is a 10-minute QEMU install, so the decision tree
# gets tested here in a second.
#
# It runs the REAL %pre extracted from installer/luke.ks, against a stub
# lsblk and a fixture describing the machine's disks. The seams
# (LUKE_CONSOLE / LUKE_CMDLINE / LUKE_BYID_DIR / LUKE_INCLUDE /
# LUKE_CANDIDATES) are unset under anaconda, where the defaults are the real
# console, the real cmdline, and the real /dev.
#
# Usage: tests/pre-disk.sh          (also runs in demo-lifecycle.sh verify-static)

set -o errexit -o nounset -o pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KS="$REPO_ROOT/installer/luke.ks"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PRE="$WORK/pre.sh"
awk '/^%pre /{f=1;next} /^%end/{f=0} f' "$KS" > "$PRE"
[ -s "$PRE" ] || { echo "could not extract %pre from $KS" >&2; exit 1; }

PASS=0; FAIL=0

# ── the stub machine ──────────────────────────────────────────────────────
# fixture line: kname|type|ro|size|bytes|model|tran|fstype|label
mk_lsblk() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/lsblk" <<'STUB'
#!/usr/bin/env bash
# Minimal lsblk stand-in: understands the flag/column/device shapes the %pre
# actually uses, driven by $DISKS.
bytes=0; cols=""; dev=""
for a in "$@"; do
    case "$a" in
        -*)     case "$a" in *b*) bytes=1 ;; esac ;;
        /dev/*) dev="${a#/dev/}" ;;
        *)      [ -n "$cols" ] || cols="$a" ;;
    esac
done
while IFS='|' read -r kname type ro size sizeb model tran fstype label; do
    [ -n "$kname" ] || continue
    [ -z "$dev" ] || [ "$dev" = "$kname" ] || continue
    out=""
    IFS=','
    for c in $cols; do
        case "$c" in
            KNAME)  v="$kname" ;;
            TYPE)   v="$type" ;;
            RO)     v="$ro" ;;
            SIZE)   [ "$bytes" = 1 ] && v="$sizeb" || v="$size" ;;
            MODEL)  v="$model" ;;
            TRAN)   v="$tran" ;;
            FSTYPE) v="$fstype" ;;
            LABEL)  v="$label" ;;
            *)      v="" ;;
        esac
        out="${out:+$out }$v"
    done
    unset IFS
    printf '%s\n' "$out"
done <<< "$DISKS"
STUB
    chmod +x "$WORK/bin/lsblk"
}

# run_pre <name> <cmdline> <console-input> — prints nothing; sets RC/OUT/INCLUDE
run_pre() {
    local cmdline="$1" console_input="$2"
    rm -rf "$WORK/run"; mkdir -p "$WORK/run/byid"
    printf '%s\n' "$cmdline" > "$WORK/run/cmdline"
    printf '%s' "$console_input" > "$WORK/run/console"
    # by-id symlinks for whichever fixture disks declare one
    while IFS='|' read -r kname _ _ _ _ _ _ _ _; do
        [ -n "$kname" ] || continue
        case " $WITH_BYID " in
            *" $kname "*) ln -sf "/dev/$kname" "$WORK/run/byid/wwn-0x$kname" ;;
        esac
    done <<< "$DISKS"

    set +e
    OUT=$(PATH="$WORK/bin:$PATH" DISKS="$DISKS" \
        LUKE_INCLUDE="$WORK/run/include.ks" \
        LUKE_CANDIDATES="$WORK/run/candidates" \
        LUKE_CONSOLE="$WORK/run/console-out" \
        LUKE_CONSOLE_IN="$WORK/run/console" \
        LUKE_CMDLINE="$WORK/run/cmdline" \
        LUKE_BYID_DIR="$WORK/run/byid" \
        bash "$PRE" 2>&1)
    RC=$?
    set -e
    INCLUDE=""
    [ -f "$WORK/run/include.ks" ] && INCLUDE=$(cat "$WORK/run/include.ks")
    return 0
}

ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"
        printf '       rc=%s include=%q\n' "$RC" "$INCLUDE"
        printf '%s\n' "$OUT" | sed 's/^/       | /' | head -12; }

expect_target() { # <name> <kname>
    if [ "$RC" = 0 ] && [ "$INCLUDE" = "ignoredisk --only-use=$2" ]; then ok "$1"; else bad "$1"; fi
}
expect_halt() { # <name> <substring the message must contain>
    if [ "$RC" != 0 ] && [ -z "$INCLUDE" ] && printf '%s' "$OUT" | grep -qF "$2"; then ok "$1"
    else bad "$1"; fi
}

mk_lsblk
echo "== disk targeting (%pre) =="

# The CI installer's own machine: target + the 4 MiB OEMDRV kickstart carrier
# + the netinst CD. Exactly one of those is an install target, and nobody is
# watching — this MUST stay unattended.
DISKS='vda|disk|0|20G|21474836480||virtio||
vdb|disk|0|4M|4194304||virtio|vfat|OEMDRV
sr0|rom|1|700M|734003200|QEMU DVD-ROM|sata|iso9660|'
WITH_BYID=""
run_pre "BOOT_IMAGE=/vmlinuz inst.text console=ttyS0" ""
expect_target "single real disk auto-selects, ignoring OEMDRV and the CD" "vda"

# A USB-stick install: the medium is TYPE=disk and big enough, but it carries
# iso9660. Erasing the thing you booted from is not a valid install.
DISKS='sda|disk|0|500G|536870912000|Samsung SSD|sata||
sdb|disk|0|32G|34359738368|SanDisk Cruzer|usb|iso9660|Fedora-E-dvd-x86_64'
WITH_BYID="sda sdb"
run_pre "BOOT_IMAGE=/vmlinuz" ""
expect_target "install medium (iso9660 on a USB disk) is never a target" "sda"

# The multi-disk NAS: the case that used to wipe everything.
DISKS='sda|disk|0|500G|536870912000|Samsung SSD|sata||
sdb|disk|0|4T|4398046511104|WD Red|sata|btrfs|tank'
WITH_BYID="sda sdb"
run_pre "BOOT_IMAGE=/vmlinuz" "1
ERASE
"
expect_target "multi-disk: menu selection + typed ERASE installs to the pick" "sda"

run_pre "BOOT_IMAGE=/vmlinuz" "2
ERASE
"
expect_target "multi-disk: the other pick is honored too" "sdb"

run_pre "BOOT_IMAGE=/vmlinuz" "1
yes
"
expect_halt "multi-disk: anything but ERASE stops, disks untouched" "Not confirmed"

run_pre "BOOT_IMAGE=/vmlinuz" "9
1
ERASE
"
expect_target "multi-disk: out-of-range input re-prompts instead of guessing" "sda"

run_pre "BOOT_IMAGE=/vmlinuz" ""
expect_halt "multi-disk headless (no console input) stops, names the escape" "inst.luke.disk"

# The escape hatch.
run_pre "BOOT_IMAGE=/vmlinuz inst.luke.disk=/dev/disk/by-id/wwn-0xsdb" ""
expect_target "inst.luke.disk by-id skips the prompt" "sdb"

run_pre "BOOT_IMAGE=/vmlinuz inst.luke.disk=/dev/sdb" ""
expect_halt "kernel name refused when the disk has a stable one" "wwn-0xsdb"

run_pre "BOOT_IMAGE=/vmlinuz inst.luke.disk=/dev/nope" ""
expect_halt "inst.luke.disk pointing at nothing stops, and lists what is there" "not an install candidate"

run_pre "BOOT_IMAGE=/vmlinuz inst.luke.disk=/dev/disk/by-id/wwn-0xtypo" ""
expect_halt "a typo'd by-id path stops and prints the real stable names" "does not exist"

run_pre "BOOT_IMAGE=/vmlinuz inst.luke.disk=sdb" ""
expect_halt "a bare name is not a device path" "is not a device path"

# virtio without serial= has no by-id link at all; refusing kernel names there
# would leave no way to pick a disk on the most common VM setup.
DISKS='vda|disk|0|20G|21474836480||virtio||
vdb|disk|0|40G|42949672960||virtio||'
WITH_BYID=""
run_pre "BOOT_IMAGE=/vmlinuz inst.luke.disk=/dev/vdb" ""
expect_target "kernel name accepted when the disk has no by-id link" "vdb"

# Nothing installable.
DISKS='vdb|disk|0|4M|4194304||virtio|vfat|OEMDRV
sr0|rom|1|700M|734003200|QEMU DVD-ROM|sata|iso9660|'
WITH_BYID=""
run_pre "BOOT_IMAGE=/vmlinuz" ""
expect_halt "no disk big enough stops with an English error" "No disk big enough"

# A target that is real but too small: caught, not silently skipped into
# "no candidates".
DISKS='vda|disk|0|20G|21474836480||virtio||
vdb|disk|0|4M|4194304||virtio|vfat|OEMDRV'
WITH_BYID=""
run_pre "BOOT_IMAGE=/vmlinuz inst.luke.disk=/dev/vdb" ""
expect_halt "inst.luke.disk at a non-candidate stops and says why" "not an install candidate"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
