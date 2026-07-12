#!/usr/bin/env bash
# greenboot required check: the data volume must be mounted and writable.
# An update that boots but cannot see /data is a failed update for a NAS,
# even if every service is technically running.
set -o nounset

DATA=/var/mnt/data

if ! mountpoint -q "$DATA"; then
    echo "FAIL: $DATA is not mounted" >&2
    exit 1
fi

probe="$DATA/.greenboot-write-probe"
if ! touch "$probe" 2>/dev/null; then
    echo "FAIL: $DATA is not writable" >&2
    exit 1
fi
rm -f "$probe"

exit 0
