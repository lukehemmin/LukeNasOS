#!/usr/bin/env bash
# greenboot required check: the units that make this machine a NAS must be
# running. If any required unit failed, this boot is bad and the update that
# produced it gets rolled back.
set -o nounset

REQUIRED_UNITS=(
    sshd.service
    lukenasos-banner.service
)
# The Samba container unit exists from M1 on; tolerate its absence only if
# the unit file is not installed at all (pre-NAS bring-up images).
if systemctl list-unit-files samba.service >/dev/null 2>&1 \
    && systemctl list-unit-files samba.service 2>/dev/null | grep -q '^samba\.service'; then
    REQUIRED_UNITS+=(samba.service)
fi

rc=0
for unit in "${REQUIRED_UNITS[@]}"; do
    if ! systemctl is-active --quiet "$unit"; then
        echo "FAIL: $unit is not active" >&2
        systemctl status --no-pager "$unit" >&2 || true
        rc=1
    fi
done

exit $rc
