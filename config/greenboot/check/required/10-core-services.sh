#!/usr/bin/env bash
# greenboot required check: the units that make this machine a NAS must be
# running. If a required unit failed, this boot is bad and the update that
# produced it gets rolled back.
set -o nounset

rc=0

for unit in sshd.service lukenasos-banner.service; do
    if ! systemctl is-active --quiet "$unit"; then
        echo "FAIL: $unit is not active" >&2
        systemctl status --no-pager "$unit" >&2 || true
        rc=1
    fi
done

# Samba needs special handling. On the FIRST boot the quadlet has to pull
# the container image over the network, which can outlast this check —
# failing the very first boot for that would mark a healthy install red
# (and on slow disks/networks could start a rollback storm, the exact
# failure mode BUILD.md warns about). So: give it a grace window, and only
# treat "not active" as fatal once Samba has been seen alive on this
# machine — then it is a regression worth rolling back for.
SAMBA_MARKER=/var/lib/lukenasos/.samba-has-run
# Container start time varies wildly with hardware (measured >180s under
# emulation with the image already local). Machine-tunable, sane default.
SAMBA_GRACE_SECONDS=300
# shellcheck disable=SC1091
[ -f /etc/lukenasos/health.conf ] && . /etc/lukenasos/health.conf
if systemctl list-unit-files samba.service 2>/dev/null | grep -q '^samba\.service'; then
    if timeout "$SAMBA_GRACE_SECONDS" bash -c 'until systemctl is-active --quiet samba.service; do sleep 5; done'; then
        mkdir -p "$(dirname "$SAMBA_MARKER")"
        touch "$SAMBA_MARKER"
    elif [ -f "$SAMBA_MARKER" ]; then
        echo "FAIL: samba.service was healthy on a previous boot and is not now" >&2
        systemctl status --no-pager samba.service >&2 || true
        rc=1
    else
        echo "WARN: samba.service not active yet on first boot (image pull pending); not failing" >&2
    fi
fi

exit $rc
