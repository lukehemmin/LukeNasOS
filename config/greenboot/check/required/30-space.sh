#!/usr/bin/env bash
# greenboot required check: ENOSPC defense. One btrfs pool means a full
# /data can make /var unwritable, which kills logging, updates, and
# rollback bookkeeping — the "never dies" promise dies quietly first.
# qgroups do not stop metadata exhaustion, so check unallocated space.
set -o nounset

MIN_UNALLOCATED=$((1 * 1024 * 1024 * 1024))   # 1 GiB hard floor for a boot to be "healthy"

if command -v btrfs >/dev/null 2>&1 && btrfs filesystem usage -b / >/dev/null 2>&1; then
    unalloc=$(btrfs filesystem usage -b / 2>/dev/null | awk '/unallocated:/ {print $3; exit}')
    if [ -n "${unalloc:-}" ] && [ "$unalloc" -lt "$MIN_UNALLOCATED" ]; then
        echo "FAIL: btrfs unallocated space ${unalloc}B is below the 1 GiB floor" >&2
        exit 1
    fi
fi

exit 0
