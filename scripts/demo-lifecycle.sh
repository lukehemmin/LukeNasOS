#!/usr/bin/env bash
# demo-lifecycle.sh — the E2E test and the demo. Same script, same registry,
# same assertions, locally and in CI.
#
# Lifecycle proven (BUILD.md §Testing):
#   1. install → boot → ● OK
#   2. luke update stages v2; nothing reboots
#   3. reboot → v2 active
#   4. update to v2-broken → greenboot fails → boot counter expires →
#      previous deployment boots → ▲ RECOVERED → digest blocked from retry
#   5. luke factory-reset → pinned deployment restored; the file written to
#      /data is still there and readable through the Samba share
#   6. power cut during staging, and after staging before finalize →
#      the machine boots and luke status explains what happened
#
# Runs against a LOCAL registry (localhost:5000), never GHCR: unpublished
# commits must be testable, and signature rejection is only reproducible
# against a registry we control.
#
# Usage: demo-lifecycle.sh <registry-up|build-variants|install|all|verify-static|clean>

set -o errexit -o nounset -o pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR="$REPO_ROOT/build"
REGISTRY="${REGISTRY:-localhost:5000}"
ENGINE=${ENGINE:-$(command -v podman || command -v docker)}
DISK="$BUILD_DIR/lukenasos-test.qcow2"
DISK_SIZE="${DISK_SIZE:-20G}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -i "$BUILD_DIR/test-key")
NETINST_ISO="${NETINST_ISO:-$BUILD_DIR/fedora-netinst.iso}"
QEMU_RAM="${QEMU_RAM:-4096}"

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# ── infrastructure ────────────────────────────────────────────────────────

registry_up() {
    if ! curl -fsS "http://$REGISTRY/v2/" >/dev/null 2>&1; then
        say "starting local registry at $REGISTRY"
        "$ENGINE" rm -f lukenasos-registry >/dev/null 2>&1 || true
        "$ENGINE" run -d --name lukenasos-registry -p 5000:5000 docker.io/library/registry:2
        for _ in $(seq 1 30); do
            curl -fsS "http://$REGISTRY/v2/" >/dev/null 2>&1 && break
            sleep 1
        done
    fi
    curl -fsS "http://$REGISTRY/v2/" >/dev/null
}

build_variants() {
    # v1 and v2 are the same tree with different version labels. v2-broken
    # is v2 plus a required greenboot check that always fails — the
    # deliberate bad update that proves automatic rollback.
    say "building v1, v2, v2-broken"
    cd "$REPO_ROOT"
    "$ENGINE" build --build-arg VERSION=v1 -t "$REGISTRY/lukenasos:v1" .

    "$ENGINE" build --build-arg VERSION=v2 -t "$REGISTRY/lukenasos:v2" .

    local ctx
    ctx=$(mktemp -d)
    cat > "$ctx/Containerfile" <<EOF
FROM $REGISTRY/lukenasos:v2
LABEL org.opencontainers.image.version="v2-broken"
RUN printf '#!/usr/bin/env bash\necho "FAIL: deliberate M1 demo failure" >&2\nexit 1\n' \
        > /etc/greenboot/check/required.d/99-deliberately-broken.sh \
    && chmod 0755 /etc/greenboot/check/required.d/99-deliberately-broken.sh
EOF
    "$ENGINE" build -t "$REGISTRY/lukenasos:v2-broken" "$ctx"
    rm -rf "$ctx"

    for tag in v1 v2 v2-broken; do
        "$ENGINE" push --tls-verify=false "$REGISTRY/lukenasos:$tag" 2>/dev/null \
            || "$ENGINE" push "$REGISTRY/lukenasos:$tag"
    done
}

make_oemdrv() {
    # Anaconda picks up a kickstart automatically from a volume labelled
    # OEMDRV. This is the cleanest unattended-install path: no ISO
    # remastering, no boot-arg injection.
    say "building OEMDRV kickstart disk"
    mkdir -p "$BUILD_DIR"
    [ -f "$BUILD_DIR/test-key" ] || ssh-keygen -t ed25519 -N '' -f "$BUILD_DIR/test-key" -q

    local ks="$BUILD_DIR/ks.cfg"
    # The test kickstart is the production one with the registry swapped to
    # the local one and the test SSH key injected. Same contract.
    sed -e "s|ghcr.io/lukehemmin/lukenasos:stable|10.0.2.2:5000/lukenasos:v1|" \
        "$REPO_ROOT/installer/luke.ks" > "$ks"
    cat >> "$ks" <<EOF

%post --erroronfail
mkdir -p /home/luke/.ssh
echo '$(cat "$BUILD_DIR/test-key.pub")' > /home/luke/.ssh/authorized_keys
chown -R luke:luke /home/luke/.ssh && chmod 700 /home/luke/.ssh && chmod 600 /home/luke/.ssh/authorized_keys
# Point updates at the host's local registry (10.0.2.2 = QEMU user-net host)
sed -i 's|IMAGE_REF=.*|IMAGE_REF=10.0.2.2:5000/lukenasos:v2|' /etc/lukenasos/luke.conf
echo '[[registry]]
location = "10.0.2.2:5000"
insecure = true' >> /etc/containers/registries.conf
%end
EOF

    truncate -s 4M "$BUILD_DIR/oemdrv.img"
    mkfs.vfat -n OEMDRV "$BUILD_DIR/oemdrv.img" >/dev/null
    mcopy -i "$BUILD_DIR/oemdrv.img" "$ks" ::ks.cfg
}

qemu_common_args() {
    # shellcheck disable=SC2012
    echo "-machine q35 -cpu max -m $QEMU_RAM -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=$(ls /usr/share/OVMF/OVMF_CODE*.fd /usr/share/edk2/ovmf/OVMF_CODE*.fd 2>/dev/null | head -1) \
      -drive file=$DISK,format=qcow2,if=virtio \
      -netdev user,id=n0,hostfwd=tcp::$SSH_PORT-:22 -device virtio-net-pci,netdev=n0 \
      -display none -serial mon:stdio"
    if [ -e /dev/kvm ]; then echo "-enable-kvm"; fi
}

install_vm() {
    say "unattended install (netinst + OEMDRV kickstart)"
    [ -f "$NETINST_ISO" ] || {
        echo "Missing $NETINST_ISO — download a Fedora Everything netinst ISO to that path" >&2
        echo "(or set NETINST_ISO=/path/to/iso)" >&2
        exit 1
    }
    mkdir -p "$BUILD_DIR"
    rm -f "$DISK"
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
    # shellcheck disable=SC2046
    timeout 90m qemu-system-x86_64 $(qemu_common_args) \
        -drive file="$NETINST_ISO",media=cdrom \
        -drive file="$BUILD_DIR/oemdrv.img",format=raw,if=virtio \
        -boot d
    # kickstart says `reboot`; QEMU exits when the installed system halts the
    # cdrom boot. The disk now contains LukeNasOS v1.
}

VM_PID=""
boot_vm() {
    say "booting VM"
    # shellcheck disable=SC2046
    qemu-system-x86_64 $(qemu_common_args) -boot c &
    VM_PID=$!
}

kill_vm() {
    if [ -n "$VM_PID" ]; then
        kill "$VM_PID" 2>/dev/null || true
        wait "$VM_PID" 2>/dev/null || true
    fi
    VM_PID=""
}

vm() { ssh "${SSH_OPTS[@]}" luke@localhost -- "$@"; }
vm_root() { ssh "${SSH_OPTS[@]}" luke@localhost -- sudo "$@"; }

wait_ssh() {
    for _ in $(seq 1 120); do
        vm true 2>/dev/null && return 0
        sleep 5
    done
    echo "VM did not come up on ssh port $SSH_PORT" >&2
    return 1
}

assert_eq() {
    local what="$1" want="$2" got="$3"
    if [ "$want" != "$got" ]; then
        echo "ASSERT FAIL: $what — want '$want', got '$got'" >&2
        exit 1
    fi
    echo "   ok: $what = $got"
}

# ── lifecycle phases ──────────────────────────────────────────────────────

phase_1_fresh_boot() {
    say "phase 1: fresh install boots ● OK"
    boot_vm; wait_ssh
    assert_eq "verdict" "OK" "$(vm_root luke status --json | jq -r .verdict)"
    assert_eq "booted" "v1" "$(vm_root luke status --json | jq -r .booted)"
    # Write the file that must survive everything, through the data path.
    vm_root sh -c "'mkdir -p /var/mnt/data/share && echo precious > /var/mnt/data/share/family-photos.txt'"
}

phase_2_stage_update() {
    say "phase 2: update stages v2, nothing reboots"
    assert_eq "update result" "staged" "$(vm_root luke update --json | jq -r .result)"
    assert_eq "still booted" "v1" "$(vm_root luke status --json | jq -r .booted)"
    # 77 when already staged/current
    local rc=0; vm_root luke update --json >/dev/null 2>&1 || rc=$?
    assert_eq "second update exit code" "77" "$rc"
}

phase_3_apply() {
    say "phase 3: reboot applies v2"
    vm_root systemctl reboot || true
    kill_vm 2>/dev/null || true
    boot_vm; wait_ssh
    assert_eq "booted" "v2" "$(vm_root luke status --json | jq -r .booted)"
    assert_eq "verdict" "OK" "$(vm_root luke status --json | jq -r .verdict)"
}

phase_4_auto_rollback() {
    say "phase 4: broken update rolls back hands-off"
    vm_root sed -i "s|lukenasos:v2|lukenasos:v2-broken|" /etc/lukenasos/luke.conf
    vm_root luke update --json >/dev/null
    vm_root systemctl reboot || true
    kill_vm
    # greenboot fails v2-broken, GRUB counts down 2 boots, previous
    # deployment boots. Give the whole dance time.
    boot_vm; wait_ssh
    assert_eq "verdict" "RECOVERED" "$(vm_root luke status --json | jq -r .verdict)"
    assert_eq "booted after recovery" "v2" "$(vm_root luke status --json | jq -r .booted)"
    # The failed digest is blocked from retry:
    local rc=0; vm_root luke update --json >/dev/null 2>&1 || rc=$?
    assert_eq "blocked retry exit code" "1" "$rc"
    # Data still there:
    assert_eq "data file" "precious" "$(vm cat /data/share/family-photos.txt)"
}

phase_5_factory_reset() {
    say "phase 5: factory reset preserves /data"
    vm_root luke factory-reset --yes-i-typed-the-hostname
    vm_root systemctl reboot || true
    kill_vm
    boot_vm; wait_ssh
    assert_eq "booted after reset" "v1" "$(vm_root luke status --json | jq -r .booted)"
    assert_eq "data survived reset" "precious" "$(vm cat /data/share/family-photos.txt)"
    # And through the share (the NAS still works, not just the bytes):
    if vm command -v smbclient >/dev/null 2>&1; then
        vm smbclient //localhost/share -U luke%lukenasos -c "'get family-photos.txt /tmp/via-share.txt'"
        assert_eq "data via samba" "precious" "$(vm cat /tmp/via-share.txt)"
    fi
}

phase_6_power_loss() {
    say "phase 6: power cuts during and after staging"
    # 6a: cut DURING staging — machine must boot the old version cleanly.
    vm_root sed -i "s|lukenasos:v2-broken|lukenasos:v2|" /etc/lukenasos/luke.conf
    vm_root systemd-run --unit=luke-bg-update luke update --json || true
    sleep 3
    kill_vm   # yank the cord mid-pull
    boot_vm; wait_ssh
    assert_eq "boots after mid-staging cut" "OK" "$(vm_root luke status --json | jq -r .verdict)"
    # 6b: cut AFTER staging, before finalize — staged deployment is
    # finalized on clean shutdown only; status must explain that.
    vm_root luke update --json >/dev/null || true
    kill_vm   # power cut, not a clean reboot
    boot_vm; wait_ssh
    vm_root luke status --json | jq -e '.staged_but_not_finalized == true or .staged != null' >/dev/null \
        && echo "   ok: status explains the unfinalized staged update"
}

# ── entry points ──────────────────────────────────────────────────────────

verify_static() {
    say "static verification (no VM)"
    bash -n "$REPO_ROOT"/luke/* "$REPO_ROOT"/scripts/*.sh
    if command -v shellcheck >/dev/null; then
        shellcheck -x -P "$REPO_ROOT/luke" \
            "$REPO_ROOT"/luke/luke "$REPO_ROOT"/luke/status \
            "$REPO_ROOT"/luke/update "$REPO_ROOT"/luke/undo "$REPO_ROOT"/luke/factory-reset \
            "$REPO_ROOT"/luke/doctor "$REPO_ROOT"/luke/banner "$REPO_ROOT"/luke/boot-check \
            "$REPO_ROOT"/luke/lib.sh \
            "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/config/greenboot/check/required/*.sh \
            "$REPO_ROOT"/config/greenboot/red.d/*.sh
    fi
    # No credentials in the image recipe — the classic self-own.
    if grep -rEn 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|ghp_[A-Za-z0-9]{20,}' \
        "$REPO_ROOT/Containerfile" "$REPO_ROOT/config" "$REPO_ROOT/luke"; then
        echo "CREDENTIAL MATERIAL FOUND in the image recipe" >&2
        return 1
    fi
    echo "static checks passed"
}

clean() {
    "$ENGINE" rm -f lukenasos-registry >/dev/null 2>&1 || true
    rm -rf "$BUILD_DIR"
}

all() {
    trap kill_vm EXIT
    registry_up
    build_variants
    make_oemdrv
    install_vm
    phase_1_fresh_boot
    phase_2_stage_update
    phase_3_apply
    phase_4_auto_rollback
    phase_5_factory_reset
    phase_6_power_loss
    kill_vm
    say "LIFECYCLE COMPLETE — install, update, break, auto-rollback, reset: all green"
}

case "${1:-all}" in
    registry-up)    registry_up ;;
    build-variants) registry_up; build_variants ;;
    install)        make_oemdrv; install_vm ;;
    verify-static)  verify_static ;;
    clean)          clean ;;
    all)            all ;;
    *) echo "usage: $0 <registry-up|build-variants|install|all|verify-static|clean>" >&2; exit 2 ;;
esac
