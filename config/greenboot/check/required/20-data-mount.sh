#!/usr/bin/env bash
# greenboot required check: the data volume must be mounted and writable.
# An update that boots but cannot see /data is a failed update for a NAS,
# even if every service is technically running.
set -o nounset

DATA=/var/mnt/data

# Wait for convergence rather than probing a racing boot (see
# 10-core-services.sh for why).
# shellcheck disable=SC2016  # $1 expands in the inner bash, by design
if ! timeout 120 bash -c 'until mountpoint -q "$1"; do sleep 3; done' _ "$DATA"; then
    echo "FAIL: $DATA did not mount within 120s" >&2
    exit 1
fi

probe="$DATA/.greenboot-write-probe"
if ! touch "$probe" 2>/dev/null; then
    echo "FAIL: $DATA is not writable" >&2
    exit 1
fi
rm -f "$probe"

exit 0
