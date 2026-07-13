#!/usr/bin/env bash
# greenboot required check: the units that make this machine a NAS must
# converge to active. If one lands in "failed" or never arrives inside its
# grace window, this boot is bad and gets rolled back.
#
# Semantics matter here: greenboot runs these checks CONCURRENTLY with the
# tail of startup, so a point-in-time `is-active` probe races the very
# units it is judging (measured: a 35-second-old boot was declared red
# because sshd had not finished starting yet — and a healthy deployment
# was rolled back for it). A check must wait for convergence and fail only
# on a real failure or a timeout.
set -o nounset

# Grace windows are machine-tunable: container/unit start times vary by an
# order of magnitude between real hardware and emulated test hosts.
CORE_GRACE_SECONDS=300
SAMBA_GRACE_SECONDS=300
# shellcheck disable=SC1091
[ -f /etc/lukenasos/health.conf ] && . /etc/lukenasos/health.conf

wait_active() {
    # wait_active UNIT GRACE — 0 when the unit becomes active within GRACE;
    # 1 immediately if it enters "failed"; 1 on timeout.
    local unit="$1" grace="$2"
    # shellcheck disable=SC2016  # $1 expands in the inner bash, by design
    timeout "$grace" bash -c '
        while ! systemctl is-active --quiet "$1"; do
            if systemctl is-failed --quiet "$1"; then exit 1; fi
            sleep 5
        done' _ "$unit"
}

rc=0

for unit in sshd.service lukenasos-banner.service; do
    if ! wait_active "$unit" "$CORE_GRACE_SECONDS"; then
        echo "FAIL: $unit did not come up within ${CORE_GRACE_SECONDS}s" >&2
        systemctl status --no-pager "$unit" >&2 || true
        rc=1
    fi
done

# Samba additionally gets first-boot forgiveness: the quadlet may still be
# pulling the container image over the network on the very first boot, and
# failing a healthy install for that could start a rollback storm. Only
# treat "never arrived" as fatal once Samba has been seen alive on this
# machine — then it is a regression worth rolling back for.
SAMBA_MARKER=/var/lib/lukenasos/.samba-has-run
if systemctl list-unit-files samba.service 2>/dev/null | grep -q '^samba\.service'; then
    if wait_active samba.service "$SAMBA_GRACE_SECONDS"; then
        mkdir -p "$(dirname "$SAMBA_MARKER")"
        touch "$SAMBA_MARKER"
    elif [ -f "$SAMBA_MARKER" ]; then
        echo "FAIL: samba.service was healthy on a previous boot and did not come up in ${SAMBA_GRACE_SECONDS}s" >&2
        systemctl status --no-pager samba.service >&2 || true
        rc=1
    else
        echo "WARN: samba.service not up yet on first boot (image pull pending); not failing" >&2
    fi
fi

exit $rc
