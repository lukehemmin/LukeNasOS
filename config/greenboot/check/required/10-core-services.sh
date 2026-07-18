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

# cockpit.socket is in this list because the banner's whole promise — "open
# this address to set up your NAS" — is a dead link without it, and a first
# boot whose one instruction leads nowhere is a bad boot. Socket-activated,
# so "active" means listening, which is exactly the claim the banner makes.
for unit in sshd.service lukenasos-banner.service cockpit.socket; do
    if ! wait_active "$unit" "$CORE_GRACE_SECONDS"; then
        echo "FAIL: $unit did not come up within ${CORE_GRACE_SECONDS}s" >&2
        systemctl status --no-pager "$unit" >&2 || true
        rc=1
    fi
done

# The identity capsule is what puts the administrator back into a fresh /etc
# after a factory reset (SPEC §5.2). If it fails, the machine still boots, still
# says OK, and the owner cannot log in — the reset's headline delivered to a
# door with no key. Loud beats subtle: fail the boot and let the verdict say so.
#
# Only when there is a capsule. Both this and Samba below are gated on real
# files rather than on the unit existing, because a unit whose
# ConditionPathExists is false reports "inactive" forever, and waiting on that
# would spend the whole grace window on every boot of a machine that has simply
# not been set up yet.
if [ -d /var/mnt/data/.lukenasos ]; then
    if ! wait_active lukenasos-identity.service "$CORE_GRACE_SECONDS"; then
        echo "FAIL: lukenasos-identity.service did not restore the identity capsule" >&2
        systemctl status --no-pager lukenasos-identity.service >&2 || true
        rc=1
    fi
fi

# Samba additionally gets first-boot forgiveness: the quadlet may still be
# pulling the container image over the network on the very first boot, and
# failing a healthy install for that could start a rollback storm. Only
# treat "never arrived" as fatal once Samba has been seen alive on this
# machine — then it is a regression worth rolling back for.
#
# And only once a share exists: before that, Samba is deliberately not running
# (there is nothing to serve and 445 is shut), so its absence is the design
# rather than a fault.
SAMBA_MARKER=/var/lib/lukenasos/.samba-has-run
if [ -f /var/mnt/data/.lukenasos/samba.env ] \
    && systemctl list-unit-files samba.service 2>/dev/null | grep -q '^samba\.service'; then
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
