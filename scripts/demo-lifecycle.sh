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
# Usage: demo-lifecycle.sh <registry-up|build-variants|install|multidisk-guard|all|verify-static|clean>
#
# Env: FIRMWARE=uefi|bios  EXTRA_DISK=<qcow2>  QEMU_SERIAL=<qemu -serial spec>

set -o errexit -o nounset -o pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR="$REPO_ROOT/build"
REGISTRY="${REGISTRY:-localhost:5000}"
ENGINE=${ENGINE:-$(command -v podman || command -v docker)}
DISK="$BUILD_DIR/lukenasos-test.qcow2"
DISK_SIZE="${DISK_SIZE:-20G}"
SSH_PORT="${SSH_PORT:-2222}"
# LogLevel=ERROR: without it ssh prints "Warning: Permanently added …" to
# stderr on every call. Harmless until something folds stderr into stdout and
# feeds the result to jq — then the JSON has a sentence in front of it and the
# parse fails for a reason that has nothing to do with the machine.
SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5 -i "$BUILD_DIR/test-key")
# Which netinst this project installs from is build-iso.sh's decision, not a
# second copy of it here. The path carries the version, so bumping Fedora can
# never silently reuse the previous release's ISO (it nearly did: an F42 image
# sat at the old unversioned path while FEDORA_VERSION already said 44).
NETINST_ISO="${NETINST_ISO:-$BUILD_DIR/fedora-netinst-$("$REPO_ROOT/scripts/build-iso.sh" --print-netinst-key).iso}"
QEMU_RAM="${QEMU_RAM:-4096}"
# uefi | bios. The BIOS path is not a variant nobody uses: half the machines a
# self-hoster resurrects boot that way, and the missing biosboot partition
# stalled the installer there for the whole life of the project without a
# single test noticing (observed on a real boot, 2026-07-16).
FIRMWARE="${FIRMWARE:-uefi}"
# A second empty disk, to prove the installer picks ONE target instead of
# erasing everything it can see.
EXTRA_DISK="${EXTRA_DISK:-}"
QEMU_SERIAL="${QEMU_SERIAL:-mon:stdio}"

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
    # -f Containerfile: podman finds it by convention, docker does not.
    "$ENGINE" build -f Containerfile --build-arg VERSION=v1 -t "$REGISTRY/lukenasos:v1" .

    "$ENGINE" build -f Containerfile --build-arg VERSION=v2 -t "$REGISTRY/lukenasos:v2" .

    local ctx
    ctx=$(mktemp -d)
    cat > "$ctx/Containerfile" <<EOF
FROM $REGISTRY/lukenasos:v2
LABEL org.opencontainers.image.version="v2-broken"
RUN printf '#!/usr/bin/env bash\necho "FAIL: deliberate M1 demo failure" >&2\nexit 1\n' \
        > /etc/greenboot/check/required.d/99-deliberately-broken.sh \
    && chmod 0755 /etc/greenboot/check/required.d/99-deliberately-broken.sh
EOF
    "$ENGINE" build -f "$ctx/Containerfile" -t "$REGISTRY/lukenasos:v2-broken" "$ctx"
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

%pre
# The installer environment must accept the plain-HTTP CI registry before
# ostreecontainer pulls from it.
cat >> /etc/containers/registries.conf <<'RCEOF'
[[registry]]
location = "10.0.2.2:5000"
insecure = true
RCEOF
%end

%post --erroronfail
mkdir -p /home/luke/.ssh
echo '$(cat "$BUILD_DIR/test-key.pub")' > /home/luke/.ssh/authorized_keys
chown -R luke:luke /home/luke/.ssh && chmod 700 /home/luke/.ssh && chmod 600 /home/luke/.ssh/authorized_keys
# TEST ONLY — the production kickstart expires the password so first login
# forces a change; that PAM gate also blocks key-based automation, and sudo
# would prompt for the expired password. Un-expire and grant NOPASSWD so
# the harness can drive the machine. (Verified live: without this, ssh -i
# gets "Password change required but no TTY available".)
chage -d "\$(date +%Y-%m-%d)" luke
echo 'luke ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/luke-test
chmod 0440 /etc/sudoers.d/luke-test
# TCG-emulated test hosts start containers an order of magnitude slower
# than any real machine; stretch the Samba health-check grace accordingly.
mkdir -p /etc/lukenasos
printf 'SAMBA_GRACE_SECONDS=900\nCORE_GRACE_SECONDS=900\n' > /etc/lukenasos/health.conf
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
    local args="-machine q35 -cpu max -m $QEMU_RAM -smp 2"
    if [ "$FIRMWARE" = uefi ]; then
        # shellcheck disable=SC2012
        args="$args -drive if=pflash,format=raw,readonly=on,file=$(ls /usr/share/OVMF/OVMF_CODE*.fd /usr/share/edk2/ovmf/OVMF_CODE*.fd 2>/dev/null | head -1)"
    fi
    args="$args -drive file=$DISK,format=qcow2,if=virtio"
    [ -n "$EXTRA_DISK" ] && args="$args -drive file=$EXTRA_DISK,format=qcow2,if=virtio"
    args="$args -netdev user,id=n0,hostfwd=tcp::$SSH_PORT-:22 -device virtio-net-pci,netdev=n0"
    args="$args -display none -serial $QEMU_SERIAL"
    echo "$args"
    if [ -e /dev/kvm ]; then echo "-enable-kvm"; fi
}

install_vm() {
    say "unattended install (netinst + OEMDRV kickstart)"
    [ -f "$NETINST_ISO" ] || {
        echo "Missing $NETINST_ISO" >&2
        echo "Fetch it with: scripts/build-iso.sh --fetch-only" >&2
        echo "(or set NETINST_ISO=/path/to/iso)" >&2
        exit 1
    }
    mkdir -p "$BUILD_DIR"
    rm -f "$DISK"
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null

    # Direct kernel boot: forces a serial text install (visible in CI logs
    # and on TCG-only hosts) and passes inst.ks explicitly — no ISO
    # remastering. -no-reboot matters: the kickstart ends in `reboot`, and
    # with -kernel args a reboot would start the installer again.
    local kdir="$BUILD_DIR/isoboot"
    mkdir -p "$kdir"
    [ -f "$kdir/vmlinuz" ] || xorriso -osirrox on -indev "$NETINST_ISO" \
        -extract /images/pxeboot/vmlinuz "$kdir/vmlinuz" \
        -extract /images/pxeboot/initrd.img "$kdir/initrd.img"
    local isolabel
    isolabel=$(blkid -o value -s LABEL "$NETINST_ISO" 2>/dev/null \
        || xorriso -indev "$NETINST_ISO" -pvd_info 2>/dev/null \
           | awk -F': *' '/Volume Id/ {print $2}')

    # shellcheck disable=SC2046
    timeout "${INSTALL_TIMEOUT:-90m}" qemu-system-x86_64 $(qemu_common_args) \
        -kernel "$kdir/vmlinuz" -initrd "$kdir/initrd.img" \
        -append "inst.stage2=hd:LABEL=$isolabel inst.ks=hd:LABEL=OEMDRV:/ks.cfg inst.text console=ttyS0" \
        -drive file="$NETINST_ISO",media=cdrom \
        -drive file="$BUILD_DIR/oemdrv.img",format=raw,if=virtio \
        -no-reboot
    # QEMU exits at the kickstart's `reboot`. The disk now contains v1.
}

VM_PID=""
boot_vm() {
    say "booting VM"
    # -no-reboot: QEMU exits when the guest completes a clean shutdown or
    # reboot. That exit is the proof the shutdown finished — which is when
    # ostree finalizes a staged deployment. Never SIGTERM a VM you expect
    # to finalize an update; that is a power cut.
    # shellcheck disable=SC2046
    qemu-system-x86_64 $(qemu_common_args) -boot c -no-reboot &
    VM_PID=$!
}

reboot_vm() {
    # Clean reboot: ask the guest, then wait for QEMU to exit on its own.
    vm_root systemctl reboot || true
    wait "$VM_PID" 2>/dev/null || true
    VM_PID=""
    boot_vm
}

ensure_vm() {
    # The greenboot dance reboots the guest repeatedly; with -no-reboot
    # each reboot exits QEMU. Restart it so the dance can continue.
    if [ -z "$VM_PID" ] || ! kill -0 "$VM_PID" 2>/dev/null; then
        boot_vm
    fi
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
    # Default 10 min. TCG-only hosts need more: a first boot of a new
    # deployment stacks emulation overhead, the greenboot chain, and the
    # Samba grace wait. Override with WAIT_SSH_TRIES (x5s).
    for _ in $(seq 1 "${WAIT_SSH_TRIES:-120}"); do
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

# assert_json WHAT FIELD WANT -- COMMAND...
#
# `assert_eq "x" staged "$(vm_root luke update --json | jq -r .result)"` reports
# `got 'null'` and throws the reason away — and null is exactly what a luke
# ERROR looks like through that filter, since errors are {error:{…}} and carry
# no .result. That cost two ten-minute reinstalls today to recover a message
# the machine had already printed. A failing test that cannot say why is half
# a test.
assert_json() {
    local what="$1" field="$2" want="$3"; shift 3
    [ "${1:-}" = "--" ] && shift

    # stdout is the answer; stderr is commentary. Parsing them together is how a
    # passing update got called '<not json>' — ssh's warning was sitting in front
    # of a perfectly good {"result":"staged"}.
    local out got err
    err=$(mktemp)
    out=$(vm_root "$@" 2>"$err") || true
    got=$(printf '%s' "$out" | jq -r "$field" 2>/dev/null) || got="<not json>"

    if [ "$want" != "$got" ]; then
        {
            echo "ASSERT FAIL: $what — want '$want', got '$got'"
            echo "   ran: $*"
            echo "   stdout:"
            printf '%s\n' "$out" | sed 's/^/     /'
            if [ -s "$err" ]; then
                echo "   stderr:"
                sed 's/^/     /' "$err"
            fi
            # The luke error names its own cause now, but these two say what the
            # machine underneath was doing when it happened.
            echo "   --- journalctl -u lukenasos-update ---"
            vm_root journalctl -u lukenasos-update --no-pager -n 25 2>/dev/null | sed 's/^/     /' || true
            echo "   --- bootc, which every luke verb stands on ---"
            vm_root bootc --version 2>/dev/null | sed 's/^/     /' || true
        } >&2
        rm -f "$err"
        exit 1
    fi
    rm -f "$err"
    echo "   ok: $what = $got"
}

# ── lifecycle phases ──────────────────────────────────────────────────────

phase_1_fresh_boot() {
    say "phase 1: fresh install boots ● OK"
    boot_vm; wait_ssh
    assert_eq "verdict" "OK" "$(vm_root luke status --json | jq -r .verdict)"
    assert_eq "booted" "v1" "$(vm_root luke status --json | jq -r .booted)"

    # `luke status` answers the moment ssh does, which is BEFORE greenboot has
    # reached a verdict — so the two asserts above passed on a machine that
    # rebooted itself 67 seconds later, on the strength of a banner unit stuck
    # in a restart storm. A fresh install that cannot survive its own health
    # check is not a fresh install that booted OK.
    say "phase 1b: the boot survives its own health check"
    # greenboot has not reached a verdict when ssh first answers, and on a first
    # boot it legitimately takes minutes: 10-core-services waits for units to
    # converge, and the Samba quadlet may still be pulling its image. Asking too
    # early gets 'activating', which is neither a pass nor a failure — so wait
    # for a terminal state and then judge.
    #
    # (`is-active` exits non-zero for 'activating', so `|| echo failed` used to
    # append a SECOND line and the assert reported the nonsense 'activating
    # failed'. `|| true` keeps the word without inventing one.)
    local gb=""
    for _ in $(seq 1 "${GREENBOOT_SETTLE_TRIES:-180}"); do
        gb=$(vm_root systemctl is-active greenboot-healthcheck.service 2>/dev/null || true)
        case "$gb" in active|failed) break ;; esac
        sleep 5
    done
    assert_eq "greenboot verdict" "active" "$gb"
    # Nothing in the rig may be sitting in `failed`: the core-services check
    # fails the instant it sees one, and a red boot on a fresh install means a
    # reboot loop with no rollback target to escape to.
    local failed
    failed=$(vm_root systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    assert_eq "failed units on a fresh boot" "" "${failed% }"
    # Write the file that must survive everything, through the data path.
    vm_root sh -c "'mkdir -p /var/mnt/data/share && echo precious > /var/mnt/data/share/family-photos.txt'"
}

phase_2_stage_update() {
    say "phase 2: update stages v2, nothing reboots"
    assert_json "update result" .result staged -- luke update --json
    assert_eq "still booted" "v1" "$(vm_root luke status --json | jq -r .booted)"
    # 77 when already staged/current
    local rc=0; vm_root luke update --json >/dev/null 2>&1 || rc=$?
    assert_eq "second update exit code" "77" "$rc"
}

phase_3_apply() {
    say "phase 3: reboot applies v2"
    reboot_vm; wait_ssh
    assert_eq "booted" "v2" "$(vm_root luke status --json | jq -r .booted)"
    assert_eq "verdict" "OK" "$(vm_root luke status --json | jq -r .verdict)"
}

phase_4_auto_rollback() {
    say "phase 4: broken update rolls back hands-off"
    # Embedded single quotes: ssh joins the argv with spaces and the remote
    # shell re-parses it, so an unquoted | becomes a pipeline over there.
    vm_root sed -i "'s|lukenasos:v2|lukenasos:v2-broken|'" /etc/lukenasos/luke.conf
    vm_root luke update --json >/dev/null
    # Clean reboot so the broken deployment finalizes, then ride the dance:
    # greenboot fails v2-broken, the guest reboots (QEMU exits each time
    # under -no-reboot — restart it), GRUB's counter runs out, the previous
    # deployment boots. sshd may answer briefly during the doomed
    # intermediate boots, so poll until the verdict settles on RECOVERED.
    reboot_vm
    local deadline=$(( SECONDS + ${ROLLBACK_DANCE_TIMEOUT:-3600} ))
    local verdict=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        ensure_vm
        verdict=$(vm_root luke status --json 2>/dev/null | jq -r .verdict 2>/dev/null || echo "")
        [ "$verdict" = "RECOVERED" ] && break
        sleep 20
    done
    assert_eq "verdict" "RECOVERED" "$verdict"
    assert_eq "booted after recovery" "v2" "$(vm_root luke status --json | jq -r .booted)"
    # The failed digest is blocked from retry:
    local rc=0; vm_root luke update --json >/dev/null 2>&1 || rc=$?
    assert_eq "blocked retry exit code" "1" "$rc"
    # Data still there (read as root: the samba container may have narrowed
    # the share directory's permissions):
    assert_eq "data file" "precious" "$(vm_root cat /data/share/family-photos.txt)"
}

phase_5_factory_reset() {
    say "phase 5: factory reset preserves /data"
    vm_root luke factory-reset --yes-i-typed-the-hostname
    reboot_vm; wait_ssh
    assert_eq "booted after reset" "v1" "$(vm_root luke status --json | jq -r .booted)"
    assert_eq "data survived reset" "precious" "$(vm_root cat /data/share/family-photos.txt)"
    # And through the share (the NAS still works, not just the bytes):
    if vm command -v smbclient >/dev/null 2>&1; then
        vm smbclient //localhost/share -U luke%lukenasos -c "'get family-photos.txt /tmp/via-share.txt'"
        assert_eq "data via samba" "precious" "$(vm cat /tmp/via-share.txt)"
    fi
}

phase_6_power_loss() {
    say "phase 6: power cuts during and after staging"
    # 6a: cut DURING staging — machine must boot the old version cleanly.
    vm_root sed -i "'s|lukenasos:v2-broken|lukenasos:v2|'" /etc/lukenasos/luke.conf
    vm_root systemd-run --unit=luke-bg-update luke update --json || true
    sleep 3
    kill_vm   # yank the cord mid-pull
    boot_vm; wait_ssh
    assert_eq "boots after mid-staging cut" "OK" "$(vm_root luke status --json | jq -r .verdict)"
    # 6b: cut AFTER staging, before the clean reboot — the staged
    # deployment lives in /run and is DISCARDED by an unclean shutdown;
    # status must explain the loss and tell the user to re-run the update.
    echo "   [6b] pre-update bookkeeping:"
    vm_root sh -c "'cat /var/lib/lukenasos/expected-digest 2>/dev/null || echo NO-EXPECTED; bootc status --json | jq -c .status.staged.image.version'" | sed 's/^/   [6b] /'
    echo "   [6b] update output:"
    vm_root luke update --json | sed 's/^/   [6b] /' || echo "   [6b] update rc=$?"
    echo "   [6b] post-update bookkeeping:"
    vm_root sh -c "'cat /var/lib/lukenasos/expected-digest 2>/dev/null || echo NO-EXPECTED; cat /proc/sys/kernel/random/boot_id'" | sed 's/^/   [6b] /'
    kill_vm   # power cut, not a clean reboot
    boot_vm; wait_ssh
    echo "   [6b] after power cut:"
    vm_root sh -c "'cat /var/lib/lukenasos/expected-digest 2>/dev/null || echo NO-EXPECTED; cat /proc/sys/kernel/random/boot_id; bootc status --json | jq -c .status.staged'" | sed 's/^/   [6b] /'
    if vm_root luke status --json | jq -e '.staged_lost == true' >/dev/null; then
        echo "   ok: status explains the update lost to the power cut"
    else
        echo "ASSERT FAIL: 6b — status does not report the staged update as lost" >&2
        vm_root luke status --json >&2 || true
        exit 1
    fi
}

# ── entry points ──────────────────────────────────────────────────────────

verify_static() {
    say "static verification (no VM)"
    bash -n "$REPO_ROOT"/luke/* "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/tests/*.sh
    # The kickstart's %pre and %post are shell too, and %pre is the code that
    # decides which disk gets erased. A syntax error there is discovered at
    # install time, on someone's hardware.
    for section in pre post; do
        awk -v s="%$section " '$0 ~ "^"s {f=1;next} /^%end/{f=0} f' \
            "$REPO_ROOT/installer/luke.ks" | bash -n \
            || { echo "installer/luke.ks: %$section has a syntax error" >&2; return 1; }
    done
    if command -v shellcheck >/dev/null; then
        shellcheck -x -P "$REPO_ROOT/luke" \
            "$REPO_ROOT"/luke/luke "$REPO_ROOT"/luke/status \
            "$REPO_ROOT"/luke/update "$REPO_ROOT"/luke/undo "$REPO_ROOT"/luke/factory-reset \
            "$REPO_ROOT"/luke/doctor "$REPO_ROOT"/luke/banner "$REPO_ROOT"/luke/boot-check \
            "$REPO_ROOT"/luke/lib.sh \
            "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/config/greenboot/check/required/*.sh \
            "$REPO_ROOT"/config/greenboot/red.d/*.sh \
            "$REPO_ROOT"/config/network/50-lukenasos-banner
    fi

    # The two decisions that ruin someone's day if they are wrong: which disk
    # gets erased, and what the first screen tells them. Both run in a second
    # here; the alternative is finding out during a 10-minute QEMU install.
    "$REPO_ROOT/tests/pre-disk.sh"
    "$REPO_ROOT/tests/banner-setup.sh"

    # The firewall policy is loaded by nftables.service at boot; a typo means
    # a machine that boots with no filter at all, which is exactly the hole
    # this policy exists to close.
    #
    # `nft -c` is not a pure parser: it talks to the kernel, so without
    # CAP_NET_ADMIN every rule comes back "Operation not permitted" and the
    # check fails for a reason that has nothing to do with the file. That is
    # a CI runner, and it is this container. Only run it where it can mean
    # something; the image build and the lifecycle boot are where a broken
    # policy actually surfaces.
    if command -v nft >/dev/null && nft list ruleset >/dev/null 2>&1; then
        nft -c -f "$REPO_ROOT/config/network/lukenasos.nft" \
            || { echo "config/network/lukenasos.nft does not parse" >&2; return 1; }
    else
        echo "skipping the nft check: no CAP_NET_ADMIN here (it needs the kernel, not a parser)"
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

resume_from_2() {
    # Debug helper: reuse an installed disk that already proved phase 1
    # (fresh boot OK); re-runs the data write, then phases 2-6.
    trap kill_vm EXIT
    registry_up
    boot_vm; wait_ssh
    assert_eq "verdict" "OK" "$(vm_root luke status --json | jq -r .verdict)"
    vm_root sh -c "'mkdir -p /var/mnt/data/share && echo precious > /var/mnt/data/share/family-photos.txt'"
    phase_2_stage_update
    phase_3_apply
    phase_4_auto_rollback
    phase_5_factory_reset
    phase_6_power_loss
    kill_vm
    say "RESUME COMPLETE — phases 2-6 green"
}

resume_from_4() {
    # Debug helper: continue on an existing disk that already passed
    # phases 1-3 (booted v2, data file written). Saves a reinstall while
    # iterating on the later phases.
    trap kill_vm EXIT
    registry_up
    boot_vm; wait_ssh
    phase_4_auto_rollback
    phase_5_factory_reset
    phase_6_power_loss
    kill_vm
    say "RESUME COMPLETE — phases 4-6 green"
}

multidisk_guard() {
    # Two disks, no inst.luke.disk. Before this wave, `clearpart --all` took
    # both. Now the installer must ASK — and while it asks, it must not have
    # touched anything.
    #
    # The unit tests (tests/pre-disk.sh) prove the decision tree against a stub
    # lsblk in a second. This proves the other half: that real lsblk, in the
    # real anaconda environment, produces what those stubs claim.
    say "multi-disk guard: the installer must ask, not erase"
    local log="$BUILD_DIR/multidisk-serial.log"
    EXTRA_DISK="$BUILD_DIR/lukenasos-extra.qcow2"
    rm -f "$EXTRA_DISK" "$log"
    qemu-img create -f qcow2 "$EXTRA_DISK" "$DISK_SIZE" >/dev/null

    # The menu blocks on console input that never comes, so the timeout IS the
    # pass condition: an installer that finishes here erased something.
    QEMU_SERIAL="file:$log" EXTRA_DISK="$EXTRA_DISK" INSTALL_TIMEOUT="${GUARD_TIMEOUT:-8m}" \
        install_vm || true

    grep -q "which disk should become this NAS" "$log" || {
        echo "FAIL: the installer never presented the disk menu." >&2
        echo "Last 40 lines of serial:" >&2; tail -40 "$log" >&2
        return 1
    }
    say "the menu appeared; now: did it touch either disk?"
    local d
    for d in "$DISK" "$EXTRA_DISK"; do
        # A GPT disk label starts with 'EFI PART' at LBA 1. Neither disk should
        # have one: nothing was confirmed, so nothing may have been written.
        if qemu-io -f qcow2 -c "read -v 512 16" "$d" 2>/dev/null | grep -qi "EFI PART"; then
            echo "FAIL: $d was partitioned while the installer was still asking" >&2
            return 1
        fi
    done
    say "MULTI-DISK GUARD PASSED — asked first, wrote nothing"
}

case "${1:-all}" in
    registry-up)    registry_up ;;
    build-variants) registry_up; build_variants ;;
    install)        make_oemdrv; install_vm ;;
    multidisk-guard) registry_up; make_oemdrv; multidisk_guard ;;
    verify-static)  verify_static ;;
    clean)          clean ;;
    all)            all ;;
    resume-from-2)  resume_from_2 ;;
    resume-from-4)  resume_from_4 ;;
    *) echo "usage: $0 <registry-up|build-variants|install|multidisk-guard|all|verify-static|clean|resume-from-4>" >&2; exit 2 ;;
esac
