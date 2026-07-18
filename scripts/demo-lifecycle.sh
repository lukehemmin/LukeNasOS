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
# What the setup phase makes. The password is the one a real owner would choose
# at the forced change; the phase sets it deliberately so that "the password
# follows you to your account" is something this test can check rather than
# assume.
SETUP_USER="${SETUP_USER:-sangho}"
SETUP_PASSWORD="${SETUP_PASSWORD:-correct-horse-battery-staple}"
SETUP_SHARE="${SETUP_SHARE:-family}"
SETUP_HOSTNAME="${SETUP_HOSTNAME:-luke-nas}"
# SMB, forwarded off the guest. The share has to be reachable from OUTSIDE the
# machine to mean anything: a client on the box itself matches `iif lo accept`
# and never touches the rule that opening 445 is about.
SMB_PORT="${SMB_PORT:-4450}"
# Cockpit, forwarded off the guest for the same reason as SMB above: the
# firewall's 9090 rule only means something to a client that is not on the box.
COCKPIT_PORT="${COCKPIT_PORT:-9990}"

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
    args="$args -netdev user,id=n0,hostfwd=tcp::$SSH_PORT-:22,hostfwd=tcp::$SMB_PORT-:445,hostfwd=tcp::$COCKPIT_PORT-:9090 -device virtio-net-pci,netdev=n0"
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

# Which account drives the machine. It starts as the installer's and CHANGES
# mid-run: `luke setup account` retires 'luke', so from phase 1c on, the harness
# reaches the box exactly the way its owner would — as themselves, with the key
# the installer left behind. If that migration ever breaks, this script loses the
# machine, which is precisely what happens to a user who runs setup over ssh.
SSH_USER="${SSH_USER:-luke}"
vm() { ssh "${SSH_OPTS[@]}" "$SSH_USER@localhost" -- "$@"; }
vm_root() { ssh "${SSH_OPTS[@]}" "$SSH_USER@localhost" -- sudo "$@"; }

# One command as root using a PASSWORD rather than the harness's passwordless
# sudo. That is the point of it: it makes PAM check the credential, so a
# transferred password is proven to work rather than proven to match a string in
# a file. Used before the harness grants itself NOPASSWD for the new account —
# and again after a factory reset, which takes that grant away with the rest of
# /etc.
vm_sudo_pw() {
    printf '%s\n' "$SETUP_PASSWORD" \
        | ssh "${SSH_OPTS[@]}" "$SSH_USER@localhost" -- "sudo -S -p '' $1"
}

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

assert_ne() {
    # For the assertions whose whole content is that something STOPPED working —
    # a retired account, a shut port. "Anything but 0" is the real claim; naming
    # an exact failure code here would only assert which way ssh gave up.
    local what="$1" unwanted="$2" got="$3"
    if [ "$unwanted" = "$got" ]; then
        echo "ASSERT FAIL: $what — got '$got', which is exactly what must not happen" >&2
        exit 1
    fi
    echo "   ok: $what (got '$got', not '$unwanted')"
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

# smbclient, run from the QEMU host through the forwarded port, so the packets
# arrive on the guest's eth0 and meet the input chain. Echoes open/closed/<data>.
smb_get() {
    # smb_get SHARE FILE — the file's contents, or "closed: <what smbclient
    # said>".
    #
    # The reason is part of the answer, deliberately. Every way this can fail —
    # the port dropped, the password refused, the share absent, smbd not
    # listening yet — looks identical from out here, and the first version
    # reported all of them as the bare word "closed", which is how an assertion
    # tells you it failed while refusing to say why.
    #
    # Fetched to a file rather than `get FILE -`: smbclient narrates to stdout
    # ("getting file ... as - (12.3 kb/s)"), so reading the download off stdout
    # would compare the file's contents plus a sentence about them.
    local tmp err out
    tmp=$(mktemp); rm -f "$tmp"
    err=$(mktemp)
    if smbclient "//localhost/$1" -p "$SMB_PORT" -U "$SETUP_USER%$SETUP_PASSWORD" \
            -c "get $2 $tmp" >"$err" 2>&1 && [ -f "$tmp" ]; then
        out=$(cat "$tmp"); rm -f "$tmp" "$err"
        printf '%s' "$out"; return
    fi
    out=$(grep -vE '^\s*$' "$err" | tail -2 | tr '\n' ' ' | sed 's/  */ /g; s/ $//') || true
    rm -f "$tmp" "$err"
    printf 'closed: %s' "${out:-smbclient said nothing at all}"
}

# open | closed — for the assertion that only cares which, not why.
smb_state() {
    case "$(smb_get "$1" "$2")" in closed*) echo closed ;; *) echo open ;; esac
}

# Poll until the share actually serves, then hand back to the assertion that
# says what it served. Dumps the machine's side once if it never does — a
# timeout that only says "closed" costs another twenty-minute run to learn
# nothing.
wait_smb() {
    local _
    for _ in $(seq 1 "${SMB_WAIT_TRIES:-36}"); do
        [ "$(smb_state "$1" "$2")" = open ] && return 0
        sleep 5
    done
    smb_debug
    return 0   # let the assertion below report the failure, with its reason
}

# Everything the machine knows about why its share will not open. Printed once,
# on failure, because the alternative is another twenty-minute run that says
# "closed" again.
smb_debug() {
    echo "── the share did not open; asking the machine why ──" >&2
    echo "· is 445 open in the ruleset?" >&2
    vm_root nft list ruleset 2>&1 | grep -E "dport (445|22|9090)" >&2 || echo "  (no 445 rule)" >&2
    echo "· the rule file luke setup share wrote:" >&2
    vm_root cat /etc/lukenasos/nftables.d/10-shares.nft >&2 2>&1 || echo "  (absent)" >&2
    echo "· is anything listening on 445?" >&2
    vm_root ss -ltnp >&2 2>&1 | grep -E ":445|:139" || echo "  (nothing on 445)" >&2
    echo "· the container:" >&2
    vm_root podman ps -a --format '{{.Names}} {{.Status}} {{.Image}}' >&2 2>&1 || true
    echo "· what the capsule told Samba (hashes redacted):" >&2
    vm_root cat /var/mnt/data/.lukenasos/samba.env 2>&1 \
        | sed -E 's/^(ACCOUNT_[a-z0-9_-]+)=.*/\1=<redacted>/' >&2 || true
    echo "· the share directory:" >&2
    vm_root ls -la "/var/mnt/data/share/$SETUP_SHARE" >&2 2>&1 || true
    echo "· samba's own account of itself:" >&2
    vm_root podman logs lukenasos-samba >&2 2>&1 | tail -25 || true
    echo "──────────────────────────────────────────────────" >&2
}

# The wizard's front door, from OUTSIDE the machine — an in-VM curl would
# pass with 9090 filtered. Socket-activated: the first request starts
# cockpit-ws, which also mints its self-signed certificate on that request,
# and on a TCG host neither is quick. So this waits rather than probes, and
# asks the machine why on a timeout instead of spending another run to learn
# nothing.
wait_cockpit() {
    local _
    for _ in $(seq 1 "${COCKPIT_WAIT_TRIES:-24}"); do
        curl -ksf -o /dev/null --max-time 15 "https://localhost:$COCKPIT_PORT/" \
            && return 0
        sleep 5
    done
    echo "── cockpit did not answer on https://localhost:$COCKPIT_PORT/; asking why ──" >&2
    echo "· the socket:" >&2
    vm_root systemctl status --no-pager cockpit.socket >&2 2>&1 || true
    echo "· the service it activates:" >&2
    vm_root systemctl status --no-pager cockpit.service >&2 2>&1 || true
    echo "· is anything listening on 9090?" >&2
    vm_root ss -ltnp 2>&1 | grep ":9090" >&2 || echo "  (nothing on 9090)" >&2
    echo "· is 9090 open in the ruleset?" >&2
    vm_root nft list ruleset 2>&1 | grep "dport 9090" >&2 || echo "  (no 9090 rule)" >&2
    return 1
}

phase_1c_setup() {
    say "phase 1c: luke setup — the wizard's API, on a real machine"

    # Checked up front, not at the assertion that needs it: without smbclient the
    # "SMB is shut" check below would pass for the wrong reason and the phase
    # would look like it was testing the firewall while testing nothing.
    command -v smbclient >/dev/null || {
        echo "smbclient is required for this phase: the share has to be opened from" >&2
        echo "OUTSIDE the machine, which is the only place the 445 rule means" >&2
        echo "anything (a client on the box matches 'iif lo accept')." >&2
        echo "  Fedora: dnf install -y samba-client   Debian/Ubuntu: apt-get install -y smbclient" >&2
        return 1
    }
    # Same reasoning for sshpass: §9 now promises password auth over ssh works,
    # and the only way a script can type at a password prompt is sshpass. Without
    # it the check would be skipped, and a skipped check that stays green is the
    # exact shape of bug this file exists to prevent.
    command -v sshpass >/dev/null || {
        echo "sshpass is required for this phase: it is the only way to test that" >&2
        echo "sshd actually takes a password — the banner's whole first-login flow." >&2
        echo "  Fedora: dnf install -y sshpass   Debian/Ubuntu: apt-get install -y sshpass" >&2
        return 1
    }

    # The installer leaves the setup token as luke's password and expires it, so
    # the owner must replace it at first login. The test kickstart un-expires the
    # account so the harness can drive it, which skips that change — so do it
    # here, with a password we know. Otherwise "the password you chose follows
    # you" would be checked against a token nobody chose.
    vm_root sh -c "'echo luke:$SETUP_PASSWORD | chpasswd'"
    local before_hash
    before_hash=$(vm_root sh -c "'getent shadow luke | cut -d: -f2'")

    assert_json "hostname result" .result set -- \
        luke setup hostname --name "$SETUP_HOSTNAME" --json
    assert_json "account result" .result created -- \
        luke setup account --name "$SETUP_USER" --json

    # NOTHING may use `luke` past this line. That account was retired by the verb
    # above, and every vm/vm_root still points at it — the first draft of this
    # phase read the new account's hash here and got an empty string back,
    # because ssh had already, correctly, slammed the door. The retirement
    # working and the harness breaking are the same event.

    # The installer's account is retired, and this is where the harness feels it:
    # the account it has used for every other phase stops opening the door.
    local luke_rc=0
    ssh "${SSH_OPTS[@]}" luke@localhost -- true 2>/dev/null || luke_rc=$?
    assert_ne "the installer account no longer opens the machine" "0" "$luke_rc"

    # And the new one does, with the key the installer left for luke. Nothing
    # else in this phase would survive this being wrong: the machine would simply
    # be gone.
    SSH_USER="$SETUP_USER"
    wait_ssh
    assert_eq "the new account answers on ssh" "$SETUP_USER" "$(vm whoami)"

    # §9's amended promise, tested the only way that means anything: a connection
    # forbidden to use the key. This is the path a brand-new owner takes — the
    # banner says `ssh luke@<ip>` and the only credential they have is a
    # password. Pubkey is switched off for this one connection so nothing but
    # the password can be what worked.
    assert_eq "ssh takes a password (the banner's first-login path)" "$SETUP_USER" \
        "$(sshpass -p "$SETUP_PASSWORD" ssh "${SSH_OPTS[@]}" \
            -o PubkeyAuthentication=no -o PreferredAuthentications=password \
            "$SETUP_USER@localhost" -- whoami)"

    # And root stays outside, key or not: the image ships PermitRootLogin no
    # because the inherited default (prohibit-password) would still have
    # admitted root with a key.
    assert_eq "sshd refuses root outright" "permitrootlogin no" \
        "$(vm_root sh -c "'sshd -T 2>/dev/null | grep -i ^permitrootlogin'")"

    # ── the wizard's front door ──
    # The firewall opened 9090 and the banner probed cockpit.socket before
    # Cockpit existed in the image; this is the assertion that they stopped
    # describing a machine that does not exist.
    wait_cockpit
    echo "   ok: the wizard's door answers on https://:9090, from off the machine"

    # Product mode (SPEC §6): every stock page ships hidden. Counted against
    # the shipped list, so the two can only disagree by an actual bug.
    assert_eq "every stock page ships hidden" \
        "$(vm_root sh -c "'wc -l < /usr/share/lukenasos/cockpit-hidden-pages'")" \
        "$(vm_root sh -c "'ls /etc/cockpit/*.override.json | wc -l'")"

    # The wizard itself is served to a signed-in user. This is the no-browser
    # version of "the plugin exists": cockpit's own login endpoint takes the
    # owner's PAM credentials, and the session cookie fetches the plugin the
    # way the shell would. A browser E2E owns the rest (form, interstitial).
    local jar
    jar=$(mktemp)
    curl -ksf -c "$jar" -u "$SETUP_USER:$SETUP_PASSWORD" \
        "https://localhost:$COCKPIT_PORT/cockpit/login" >/dev/null \
        || { echo "ASSERT FAIL: cockpit login refused the owner's credentials" >&2
             rm -f "$jar"; exit 1; }
    assert_eq "the wizard is served to a signed-in owner" "1" \
        "$(curl -ksf -b "$jar" \
            "https://localhost:$COCKPIT_PORT/cockpit/@localhost/lukenasos-setup/index.html" \
            | grep -c "Name your NAS" || true)"
    rm -f "$jar"

    # The wizard's bookmark round-trips: what stamp writes, status hands back.
    assert_json "stamp result" .result stamped -- luke setup stamp --step 2 --json
    assert_json "status carries the bookmark" .wizard.step 2 -- luke setup status --json

    # The escape hatch, on the record: unlock reveals, the event says so, and
    # a second unlock is nothing-to-do. Phase 5 then asserts the factory reset
    # takes the unlock back — locked is the factory state.
    assert_json "unlock-console result" .result unlocked -- luke unlock-console --json
    assert_eq "the overrides are gone" "0" \
        "$(vm_root sh -c "'ls /etc/cockpit/*.override.json 2>/dev/null | wc -l'")"
    local unlock_rc=0
    vm_root luke unlock-console --json >/dev/null 2>&1 || unlock_rc=$?
    assert_eq "second unlock is nothing-to-do" "77" "$unlock_rc"
    assert_eq "the unlock is on the record" "1" \
        "$(vm_root sh -c "'grep -c console_unlocked /var/lib/lukenasos/events.jsonl'")"

    # PAM checking the transferred credential for real, rather than two strings
    # being compared in /etc/shadow. This is the assertion the unit tests cannot
    # make: their chpasswd is a stub, and a stub always agrees with me.
    assert_eq "the transferred password authenticates" "root" "$(vm_sudo_pw whoami)"

    # The harness needs its usual passwordless root back, the way the test
    # kickstart grants it to luke. Test-only, and only after the line above has
    # proven the password works without it.
    grant_test_sudo

    # Copied, not re-derived: the same hash the owner's password already had.
    # Weaker than the sudo above — that one proves the credential WORKS — but it
    # is what says the verb transferred the password rather than inventing a way
    # to set a new one.
    assert_eq "the chosen password moved across, byte for byte" "$before_hash" \
        "$(vm_root sh -c "'getent shadow $SETUP_USER | cut -d: -f2'")"

    # ── the share ──
    # Shut before a share exists — the promise SPEC §9 makes and the reason
    # `luke setup share` has to open it.
    assert_eq "SMB is shut before the first share" "closed" "$(smb_state "$SETUP_SHARE" x)"

    # Real podman, real create-hash.sh, real image pull. On a fresh machine this
    # is the first time the Samba image is fetched, because the quadlet has had
    # nothing to serve until now.
    printf '%s' "$SETUP_PASSWORD" \
        | vm_root luke setup share --name "$SETUP_SHARE" --user "$SETUP_USER" --password-stdin \
        || { echo "luke setup share failed" >&2; return 1; }
    assert_eq "samba is up once a share exists" "active" \
        "$(vm_root systemctl is-active samba.service)"

    vm_root sh -c "'echo precious > /var/mnt/data/share/$SETUP_SHARE/family-photos.txt'"
    vm_root chown "$SETUP_USER:$SETUP_USER" "/var/mnt/data/share/$SETUP_SHARE/family-photos.txt"

    # `systemctl is-active` says the container started, not that smbd inside it
    # has bound 445 — and on a TCG-emulated host the gap between those is not
    # small. Wait for the service the user would wait for.
    wait_smb "$SETUP_SHARE" family-photos.txt

    # The whole claim in one line: the firewall opened, Samba is serving, the NT
    # hash the container computed matches the password the owner typed, and the
    # share points where it should — checked from off the machine.
    assert_eq "the share opens from the LAN, with that password" "precious" \
        "$(smb_get "$SETUP_SHARE" family-photos.txt)"

    assert_json "setup reports complete" .complete true -- luke setup status --json
}

# The harness's own root access, granted the way the test kickstart grants it to
# luke. Re-run after a factory reset, which clears /etc and takes it away.
grant_test_sudo() {
    vm_sudo_pw "sh -c 'echo \"$SETUP_USER ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/90-lukenasos-test && chmod 0440 /etc/sudoers.d/90-lukenasos-test'"
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

# The machine's ssh identity as a client on the LAN sees it. Not read out of
# /etc: what a returning client compares against known_hosts is what the network
# answers with.
#
# This must never kill the run, and it did. It was two silenced pipelines under
# errexit+pipefail, and `ssh-keygen -lf -` answers empty input with 255 — so when
# ssh-keyscan came back empty, phase 5 died on its second line, printing nothing,
# with an exit code identical to an ssh failure. Now it retries, keeps its
# stderr, and reports its own failure as a value the caller must look at.
#
# -T 20 because ssh-keyscan's default is 5s and this box is emulated and has just
# been through the rollback dance.
hostkey_fp() {
    # Asked through a real ssh connection, not ssh-keyscan. The connection this
    # harness makes a hundred times a run is known to work; ssh-keyscan is a
    # second, differently-behaved client, and it came back empty against a
    # machine that ssh was talking to seconds earlier — ten times, over four
    # minutes, for reasons it was never given a chance to state.
    #
    # What lands in a fresh known_hosts is exactly what the server presented,
    # which is the thing a returning client compares. Reading
    # /etc/ssh/*.pub instead would miss the failure that matters most: keys
    # restored on disk but sshd still serving the ones it generated, where the
    # file says "fixed" and every client still sees the warning.
    local kh fp err
    kh=$(mktemp); rm -f "$kh"
    err=$(mktemp)
    ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$kh" \
        -o LogLevel=ERROR -o ConnectTimeout=15 -i "$BUILD_DIR/test-key" \
        "$SSH_USER@localhost" true >/dev/null 2>"$err" || true
    fp=""
    [ -s "$kh" ] && fp=$(ssh-keygen -lf "$kh" 2>>"$err" | awk '{print $2}' | head -1)
    case "$fp" in
        SHA256:*) rm -f "$kh" "$err"; printf '%s' "$fp" ;;
        *)  # Say why, here, once. Every earlier version of this function hid
            # its reason behind a redirect and cost a run to re-ask.
            echo "  hostkey_fp: no key from $SSH_USER@localhost:$SSH_PORT —" >&2
            sed 's/^/    /' "$err" >&2 2>/dev/null || true
            rm -f "$kh" "$err"
            printf 'no-host-key-presented' ;;
    esac
}

# A fingerprint, or stop. Comparing "could not read it" before a reset with
# "could not read it" after would pass, and would mean nothing.
require_hostkey_fp() {
    local fp; fp=$(hostkey_fp)
    case "$fp" in
        SHA256:*) printf '%s' "$fp" ;;
        *) echo "ASSERT FAIL: cannot read this machine's ssh host key ($fp) — the" >&2
           echo "  comparison across the reset would be two failures agreeing." >&2
           exit 1 ;;
    esac
}

phase_5_factory_reset() {
    say "phase 5: factory reset preserves /data — and the NAS that serves it"
    local uid_before fp_before
    uid_before=$(vm_root id -u "$SETUP_USER")
    fp_before=$(require_hostkey_fp)
    vm_root luke factory-reset --yes-i-typed-the-hostname
    reboot_vm

    # ssh is reachable as the new user only if the capsule restored the account
    # AND its authorized_keys into a /etc that no longer had either. This wait is
    # the first assertion of the phase, and it fails by timing out.
    wait_ssh

    # This comes first, before anything that needs root: /etc is fresh, so the
    # harness's own NOPASSWD rule went with it, and every vm_root below would sit
    # at a password prompt with no tty. Getting root back with the OWNER's
    # password is also the proof that the capsule carried the credential and not
    # just the account name — so the repair and the assertion are the same act.
    assert_eq "the password came back with the account" "root" "$(vm_sudo_pw whoami)"
    grant_test_sudo

    # The whole front door after a reset, in one line: sshd's fresh /etc got the
    # image's drop-in back (password auth on) AND the capsule restored a hash for
    # it to check. The key is forbidden here so nothing else can be what worked.
    assert_eq "the front door still takes the password after reset" "$SETUP_USER" \
        "$(sshpass -p "$SETUP_PASSWORD" ssh "${SSH_OPTS[@]}" \
            -o PubkeyAuthentication=no -o PreferredAuthentications=password \
            "$SETUP_USER@localhost" -- whoami)"

    # Phase 1c unlocked the console; the fresh /etc must take that back.
    # Unlocking is a live decision, not a surviving one (SPEC §6) — and this
    # assertion is what makes that sentence a behavior instead of a hope.
    assert_eq "the reset re-locked the console" \
        "$(vm_root sh -c "'wc -l < /usr/share/lukenasos/cockpit-hidden-pages'")" \
        "$(vm_root sh -c "'ls /etc/cockpit/*.override.json | wc -l'")"
    wait_cockpit
    echo "   ok: the wizard's door still answers after the reset"

    assert_eq "booted after reset" "v1" "$(vm_root luke status --json | jq -r .booted)"

    # The uid is the one thing that cannot be re-derived. Every file on /data is
    # owned by a number; an account restored with a different one would leave the
    # owner locked out of their own photos, with the reset still reporting
    # success — SPEC §5.2's broken promise in its most literal form.
    assert_eq "the administrator survived, with the same uid" "$uid_before" \
        "$(vm_root id -u "$SETUP_USER")"
    assert_eq "the installer account is retired again" "L" \
        "$(vm_root passwd -S luke | awk '{print $2}')"
    assert_eq "the NAS remembers its name" "$SETUP_HOSTNAME" "$(vm_root cat /etc/hostname)"

    # The reset must not make ssh accuse the machine of being an impostor. This
    # harness would never notice on its own — it runs with
    # StrictHostKeyChecking=no and throws known_hosts at /dev/null — so ask the
    # network directly, the way a returning client does.
    assert_eq "the machine comes back as itself, not as an impostor" \
        "$fp_before" "$(require_hostkey_fp)"

    assert_eq "data survived reset" "precious" "$(vm_root cat /data/share/family-photos.txt)"

    # Bytes surviving is not the promise; the NAS coming back is. The share
    # definition, the Samba credential and the open port all had to be rebuilt
    # from /data into a blank /etc for this to answer.
    #
    # The wait is longer here than after setup: factory-reset clears
    # /var/lib/containers/storage, so Samba is pulling its image again from
    # nothing, on an emulated machine.
    SMB_WAIT_TRIES="${SMB_WAIT_TRIES_AFTER_RESET:-90}" wait_smb "$SETUP_SHARE" family-photos.txt
    assert_eq "the share came back, and still opens from the LAN" "precious" \
        "$(smb_get "$SETUP_SHARE" family-photos.txt)"
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
            "$REPO_ROOT"/luke/setup "$REPO_ROOT"/luke/identity-apply \
            "$REPO_ROOT"/luke/unlock-console \
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

    # The wizard's privileged API: the code between a browser form and useradd.
    # It runs once, on someone's only machine, and its worst failures — handing
    # the new administrator the setup token as a password, retiring the account
    # that still works — are not ones they can undo from the couch.
    "$REPO_ROOT/tests/setup-verbs.sh"

    # The wizard plugin. A broken manifest is a Cockpit page that silently
    # never appears; jq is the parser CI already has. The grep is SPEC §6's
    # privilege model as a tripwire: the plugin renders luke output and spawns
    # luke verbs (plus the one loginctl the design names) — the day useradd or
    # smbpasswd appears in the browser's half, the "one audited privileged
    # surface" sentence has quietly stopped being true.
    jq empty "$REPO_ROOT"/web/lukenasos-setup/manifest.json \
        || { echo "web/lukenasos-setup/manifest.json does not parse" >&2; return 1; }
    # Quoted, because that is the shape of a spawn argument — and because the
    # plugin's own comments state the rule in prose, which must not trip it.
    if grep -rnE '"(useradd|smbpasswd|chpasswd|usermod|nft)"' "$REPO_ROOT/web/"; then
        echo "the wizard must call luke verbs, never system tools (SPEC §6)" >&2
        return 1
    fi

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
    # The above greps for key material and misses the shape that actually got
    # shipped: samba.container carried ACCOUNT_luke=changeme-on-first-login for
    # the whole life of the project — one password, identical on every install,
    # for an account the wizard retires. It was harmless only because SPEC §9
    # keeps 445 shut, and `luke setup share` now opens it.
    #
    # So the rule is a property, not a pattern: Samba accounts come from the
    # identity capsule on /data, and the image defines none.
    if grep -rEn '^(ACCOUNT|UID)_[a-z]' "$REPO_ROOT/config/containers"; then
        echo "A SAMBA ACCOUNT IS DEFINED IN THE IMAGE — accounts belong to the" >&2
        echo "identity capsule (SPEC §5.2), which is per-machine and survives a" >&2
        echo "factory reset. An account baked here is the same password on every" >&2
        echo "LukeNasOS install." >&2
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
    phase_1c_setup
    phase_2_stage_update
    phase_3_apply
    phase_4_auto_rollback
    phase_5_factory_reset
    phase_6_power_loss
    kill_vm
    say "LIFECYCLE COMPLETE — install, set up, update, break, auto-rollback, reset: all green"
}

resume_from_2() {
    # Debug helper: reuse an installed disk that already proved phase 1
    # (fresh boot OK); re-runs the data write, then phases 2-6.
    trap kill_vm EXIT
    registry_up
    boot_vm; wait_ssh
    assert_eq "verdict" "OK" "$(vm_root luke status --json | jq -r .verdict)"
    vm_root sh -c "'mkdir -p /var/mnt/data/share && echo precious > /var/mnt/data/share/family-photos.txt'"
    phase_1c_setup
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
    #
    # That disk has been through setup, so 'luke' is retired on it: drive it as
    # the account that replaced them, or ssh will not open. (Not ${SSH_USER:-…} —
    # SSH_USER already defaulted to luke at the top and is never empty. Override
    # with SETUP_USER.)
    SSH_USER="$SETUP_USER"
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
