#!/usr/bin/env bash
# greenboot red script: runs when required health checks have failed and the
# boot is about to be declared bad. Record WHY, so that after GRUB's boot
# counter expires and the previous deployment boots, the user sees
# "▲ RECOVERED — <version> failed its health check: <cause>" instead of a
# silently downgraded machine they will misread as "the update didn't take".
#
# The record lands in /var/lib/lukenasos, which is shared across deployments
# in the stateroot — it survives the rollback by construction.
# luke boot-check consumes it on the next boot (see luke/boot-check).
set -o nounset

STATE_DIR=/var/lib/lukenasos
mkdir -p "$STATE_DIR"

from_digest=$(bootc status --json 2>/dev/null | jq -r '.status.booted.image.imageDigest // ""')
from_version=$(bootc status --json 2>/dev/null | jq -r '.status.booted.image.version // "unknown"')

# Name the actual failing units; "health checks failed" alone is not a cause.
failing=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd ', ' -)
[ -n "$failing" ] || failing="required greenboot checks failed"

jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg from_digest "$from_digest" \
    --arg from_version "$from_version" \
    --arg cause "$failing" \
    '{ts: $ts, from_digest: $from_digest, from_version: $from_version, cause: $cause}' \
    > "$STATE_DIR/pending-rollback.json"

exit 0
