#!/usr/bin/env bash
# build-iso.sh — build the LukeNasOS installer ISO, locally or in CI.
#
# One script, capability-detected (local vs CI is not the real distinction;
# the container engine and loop-device support are):
#
#   default        Remaster the Fedora netinst ISO with installer/luke.ks
#                  using xorriso + mtools only — no loop devices, no
#                  privileges, no container — so it works on laptops,
#                  unprivileged LXC containers, and CI runners alike.
#                  (mkksiso was rejected: its mkefiboot step needs loop
#                  devices, and the netinst's UEFI boot config lives INSIDE
#                  the hidden efiboot.img, which mtools can edit directly.)
#                  The result is an ONLINE installer: it pulls the OS image
#                  from the registry baked into the kickstart.
#
#   --offline      Build the self-contained anaconda ISO with osbuild
#                  image-builder (OS image embedded, no network needed at
#                  install time). Requires a privileged container runtime
#                  with loop devices — CI runners and real hosts yes,
#                  unprivileged LXC no. The script checks and says so.
#
# Usage:
#   scripts/build-iso.sh [--image REF] [--netinst PATH] [--out PATH]
#                        [--serial] [--offline]
#
#   --image REF    OS image the installer deploys
#                  (default: ghcr.io/lukehemmin/lukenasos:stable)
#   --netinst P    Fedora netinst ISO to remaster (default:
#                  build/fedora-netinst.iso, downloaded if missing)
#   --out P        Output path (default: build/lukenasos-x86_64.iso)
#   --serial       Add inst.text console=ttyS0 kernel args (headless/QEMU)
#   --offline      image-builder path (see above)
#
#   --fetch-only   Download the netinst ISO and stop. This script owns which
#                  Fedora the project builds against; CI asks rather than
#                  keeping its own copy of the URL (it kept four, and the
#                  compose suffix moves every respin).
#   --print-netinst-key
#                  Print the version+compose string, for CI cache keys.

set -o errexit -o nounset -o pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

FEDORA_VERSION=44
# The compose suffix is not derivable from the version: F42 shipped -1.1, F44
# ships -1.7. It changes per respin, so it lives here as its own knob rather
# than as a string someone has to notice inside a URL.
NETINST_COMPOSE="1.7"
NETINST_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Everything/x86_64/iso/Fedora-Everything-netinst-x86_64-${FEDORA_VERSION}-${NETINST_COMPOSE}.iso"

IMAGE_REF="ghcr.io/lukehemmin/lukenasos:stable"
NETINST="build/fedora-netinst.iso"
OUT="build/lukenasos-x86_64.iso"
SERIAL=0
OFFLINE=0
FETCH_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --image)   IMAGE_REF="$2"; shift 2 ;;
        --netinst) NETINST="$2"; shift 2 ;;
        --out)     OUT="$2"; shift 2 ;;
        --serial)  SERIAL=1; shift ;;
        --offline) OFFLINE=1; shift ;;
        --fetch-only) FETCH_ONLY=1; shift ;;
        --print-netinst-key)
            printf '%s-%s\n' "$FEDORA_VERSION" "$NETINST_COMPOSE"; exit 0 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

mkdir -p build

# ── offline: self-contained ISO via image-builder (loop devices needed) ──
if [ "$OFFLINE" = 1 ]; then
    ENGINE=$(command -v podman || command -v docker) \
        || { echo "--offline needs podman or docker" >&2; exit 1; }
    if ! losetup -f >/dev/null 2>&1; then
        echo "ERROR: --offline needs loop devices, and this host has none" >&2
        echo "(unprivileged LXC?). Run it in CI or on a bare-metal/VM host," >&2
        echo "or build the online installer instead (default mode)." >&2
        exit 1
    fi
    echo "== offline ISO: image-builder (anaconda-iso) embedding $IMAGE_REF =="
    sudo "$ENGINE" run --rm --privileged \
        -v "$REPO_ROOT/build/ib-output:/output" \
        ghcr.io/osbuild/image-builder-cli:latest \
        build --type anaconda-iso "$IMAGE_REF"
    mv "$REPO_ROOT"/build/ib-output/bootiso/install.iso "$OUT"
    echo "ISO: $OUT ($(du -h "$OUT" | cut -f1))"
    exit 0
fi

# ── default: online installer via netinst remaster (no privileges) ──────
[ -f "$NETINST" ] || {
    echo "== downloading Fedora netinst (F${FEDORA_VERSION}-${NETINST_COMPOSE}) =="
    curl -fL --retry 3 -o "$NETINST" "$NETINST_URL"
}
[ "$FETCH_ONLY" = 1 ] && { echo "netinst ready: $NETINST"; exit 0; }

# The kickstart the ISO carries: the production contract with the target
# image ref substituted in.
KS=build/iso-ks.cfg
sed "s|ostreecontainer --url=[^ ]*|ostreecontainer --url=$IMAGE_REF|" \
    installer/luke.ks > "$KS"
grep -q "ostreecontainer --url=$IMAGE_REF" "$KS" \
    || { echo "kickstart substitution failed" >&2; exit 1; }

case "$IMAGE_REF" in
    localhost*|10.*|192.168.*) cat >&2 <<'EOF'
WARN: the image ref points at a private/plain-HTTP registry. The installed
ISO will only work on networks that can reach it, and anaconda must trust
it (see the %pre block the test harness uses). Fine for lab use; do not
ship this ISO.
EOF
        ;;
esac

for tool in xorriso mcopy blkid dd; do
    command -v "$tool" >/dev/null || {
        echo "missing: $tool" >&2
        echo "  Debian/Ubuntu: sudo apt install xorriso mtools util-linux" >&2
        echo "  Fedora:        sudo dnf install xorriso mtools util-linux" >&2
        exit 1
    }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

label=$(blkid -o value -s LABEL "$NETINST")
[ -n "$label" ] || { echo "could not read the ISO volume label" >&2; exit 1; }

extra=""
[ "$SERIAL" = 1 ] && extra=" inst.text console=ttyS0,115200"

# The menu title is the product's first contact with a human, and it was
# saying "Install Fedora 42". It is also the last gate before an installer
# that erases a disk: someone who boots this by accident gets ten seconds and
# one line of text to realise it, so that line says what is about to happen.
#
# The ISO *volume label* is deliberately NOT rebranded: it is load-bearing
# (blkid reads it here, and three grub.cfg copies — including the one inside
# the hidden efiboot.img — reference it in inst.stage2=/inst.ks=). Renaming it
# means changing the remaster contract everywhere at once, for a string no
# user ever sees. See TODOS.md.
PRODUCT_TITLE="Install LukeNasOS (erases the disk)"
MEDIA_TITLE="Test this media & install LukeNasOS"
# '&' means "the whole match" in a sed replacement, so a title containing one
# swallows itself. Escape at the point of use and keep the titles readable.
PRODUCT_TITLE_SED=${PRODUCT_TITLE//&/\\&}
MEDIA_TITLE_SED=${MEDIA_TITLE//&/\\&}

# Append inst.ks to every install cmdline, brand the titles, make the first
# entry the default, and shorten the menu timeout: this ISO has one job.
patch_grub() {
    sed -E -e "s|(inst.stage2=hd:LABEL=${label}[^ ]*)|\1 inst.ks=hd:LABEL=${label}:/ks.cfg${extra}|" \
        -e "s|^(menuentry ')Install Fedora [0-9]+'|\1${PRODUCT_TITLE_SED}'|" \
        -e "s|^(menuentry ')Test this media & install Fedora [0-9]+'|\1${MEDIA_TITLE_SED}'|" \
        -e 's/^set default="1"/set default="0"/' \
        -e 's/^set timeout=60/set timeout=10/' "$1" > "$2"
    grep -q "inst.ks=" "$2" || { echo "cmdline patch failed for $1" >&2; exit 1; }
    grep -q "Install LukeNasOS" "$2" || {
        echo "menu branding failed for $1 — upstream titles changed?" >&2
        grep -n "^menuentry" "$1" >&2
        exit 1
    }
}

echo "== remastering $NETINST -> $OUT (xorriso + mtools, no privileges) =="

# 1. The UEFI boot config lives inside the hidden El Torito FAT image.
#    Locate it from the El Torito report, pull it out, patch its grub.cfg
#    with mtools (no mount needed), and it becomes the new appended
#    partition below.
read -r efi_lba efi_size < <(xorriso -indev "$NETINST" -report_el_torito plain 2>/dev/null \
    | awk '/El Torito boot img/ && /UEFI/ {print $(NF), $(NF-1)}')
[ -n "${efi_lba:-}" ] || { echo "no UEFI El Torito image found in $NETINST" >&2; exit 1; }
dd if="$NETINST" of="$WORK/efiboot.img" bs=2048 skip="$efi_lba" \
    count=$(( (efi_size * 512 + 2047) / 2048 )) status=none
mcopy -n -i "$WORK/efiboot.img" ::EFI/BOOT/grub.cfg "$WORK/efi-grub.orig"
patch_grub "$WORK/efi-grub.orig" "$WORK/efi-grub.cfg"
mcopy -o -i "$WORK/efiboot.img" "$WORK/efi-grub.cfg" ::EFI/BOOT/grub.cfg

# 2. The BIOS config and the on-filesystem EFI config are plain files in
#    the ISO; patch copies for grafting.
xorriso -osirrox on -indev "$NETINST" \
    -extract /boot/grub2/grub.cfg "$WORK/bios-grub.orig" \
    -extract /EFI/BOOT/grub.cfg "$WORK/fs-efi-grub.orig" >/dev/null 2>&1
patch_grub "$WORK/bios-grub.orig" "$WORK/bios-grub.cfg"
patch_grub "$WORK/fs-efi-grub.orig" "$WORK/fs-efi-grub.cfg"

# 3. Rebuild: replay the original boot provisions, swap in the patched
#    EFI image as appended partition 2, graft the kickstart and configs.
rm -f "$OUT.tmp"
xorriso -indev "$NETINST" -outdev "$OUT.tmp" \
    -boot_image any replay \
    -append_partition 2 0xef "$WORK/efiboot.img" \
    -map "$KS" /ks.cfg \
    -map "$WORK/bios-grub.cfg" /boot/grub2/grub.cfg \
    -map "$WORK/fs-efi-grub.cfg" /EFI/BOOT/grub.cfg \
    >/dev/null 2>&1
mv "$OUT.tmp" "$OUT"

# 4. Trust, but verify: the shipped ISO must carry the kickstart and the
#    patched cmdlines in BOTH firmware paths.
xorriso -osirrox on -indev "$OUT" -extract /ks.cfg "$WORK/verify-ks" \
    -extract /boot/grub2/grub.cfg "$WORK/verify-bios" >/dev/null 2>&1
grep -q "ostreecontainer --url=$IMAGE_REF" "$WORK/verify-ks"
grep -q "inst.ks=" "$WORK/verify-bios"
grep -q "Install LukeNasOS" "$WORK/verify-bios"
# The BIOS stall was invisible until someone booted it on a BIOS machine:
# without a biosboot partition the unattended install silently becomes an
# interactive one that nobody is watching. It is one line, and it is the
# difference between "installs" and "hangs forever" on half the world's
# hardware — so the shipped ISO gets asked whether it carries it.
grep -q "part biosboot" "$WORK/verify-ks"
read -r v_lba v_size < <(xorriso -indev "$OUT" -report_el_torito plain 2>/dev/null \
    | awk '/El Torito boot img/ && /UEFI/ {print $(NF), $(NF-1)}')
dd if="$OUT" of="$WORK/verify-efi.img" bs=2048 skip="$v_lba" \
    count=$(( (v_size * 512 + 2047) / 2048 )) status=none
mcopy -n -i "$WORK/verify-efi.img" ::EFI/BOOT/grub.cfg "$WORK/verify-efi-grub"
grep -q "inst.ks=" "$WORK/verify-efi-grub"
echo "verified: kickstart present; inst.ks wired into BIOS and UEFI boot paths"

echo
echo "ISO: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Boot it; the install is unattended and deploys: $IMAGE_REF"
echo "Reminder: this is an ONLINE installer — that image ref must exist and"
echo "be reachable from the machine you are installing."
