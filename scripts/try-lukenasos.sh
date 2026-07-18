#!/usr/bin/env bash
# try-lukenasos.sh — for adopters: download the latest release qcow2 and
# boot it in QEMU. One command, under 15 minutes, ending in "I saw it
# update and undo" (the published image is N-1, so `luke update` finds one).

set -o errexit -o nounset -o pipefail

REPO="${REPO:-lukehemmin/LukeNasOS}"
WORKDIR="${WORKDIR:-$HOME/.cache/lukenasos-try}"
SSH_PORT="${SSH_PORT:-2222}"

# ── dependency check, with the exact install command ─────────────────────
missing=()
for bin in qemu-system-x86_64 qemu-img curl jq; do
    command -v "$bin" >/dev/null || missing+=("$bin")
done
# shellcheck disable=SC2012
ovmf=$(ls /usr/share/OVMF/OVMF_CODE*.fd /usr/share/edk2/ovmf/OVMF_CODE*.fd 2>/dev/null | head -1 || true)
[ -n "$ovmf" ] || missing+=(edk2-ovmf)
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing: ${missing[*]}" >&2
    echo "  Fedora:        sudo dnf install qemu-system-x86 edk2-ovmf curl jq" >&2
    echo "  Debian/Ubuntu: sudo apt install qemu-system-x86 ovmf curl jq" >&2
    exit 1
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ── download the N-1 qcow2 from the latest release ────────────────────────
echo "Finding the latest release of $REPO..."
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | jq -r '.assets[] | select(.name | test("x86_64.*-1\\.qcow2$|x86_64\\.qcow2$")) | .browser_download_url' \
    | head -1)
[ -n "$url" ] || { echo "No qcow2 asset found in the latest release of $REPO" >&2; exit 1; }

img="${url##*/}"
if [ ! -f "$img" ]; then
    echo "Downloading $img..."
    curl -fL --progress-bar -o "$img" "$url"
fi

# Work on a snapshot so the download stays pristine for the next try.
qemu-img create -f qcow2 -b "$img" -F qcow2 try.qcow2 >/dev/null

kvm_args=()
[ -e /dev/kvm ] && kvm_args+=(-enable-kvm)

echo
echo "Booting LukeNasOS. Login: luke / lukenasos (you will be asked to change it)."
echo "SSH from another terminal:  ssh -p $SSH_PORT luke@localhost"
echo "Then try:                   luke status → luke update → reboot → luke undo"
echo
exec qemu-system-x86_64 \
    "${kvm_args[@]}" \
    -machine q35 -cpu max -m 4096 -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf" \
    -drive file=try.qcow2,format=qcow2,if=virtio \
    -netdev user,id=n0,hostfwd=tcp::"$SSH_PORT"-:22 -device virtio-net-pci,netdev=n0 \
    -display none -serial mon:stdio
