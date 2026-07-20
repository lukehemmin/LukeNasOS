#!/usr/bin/env bash
# lib.sh — shared plumbing for every luke verb.
#
# Contract (see docs/errors.md and the CLI spec):
#   exit 0   success
#   exit 1   error (every error names what failed, the likely cause, the next
#            command to run, and a stable doc anchor docs/errors.md#LUKE-Exxx)
#   exit 2   usage error
#   exit 77  nothing to do (automation must distinguish "updated" from
#            "already current")
#
# Every verb accepts --json. Human output uses symbol plus color, never color
# alone. Text progress, never spinners.

set -o errexit -o nounset -o pipefail

LUKE_STATE_DIR="${LUKE_STATE_DIR:-/var/lib/lukenasos}"
LUKE_CONF="${LUKE_CONF:-/etc/lukenasos/luke.conf}"
LUKE_EVENTS="$LUKE_STATE_DIR/events.jsonl"
LUKE_BLOCKLIST="$LUKE_STATE_DIR/blocked-digests"
# The per-install setup token (installer/luke.ks %post writes it). Printed on
# the console banner until the forced password change spends it; console
# access is what proves ownership of a fresh machine.
# shellcheck disable=SC2034
LUKE_SETUP_TOKEN="$LUKE_STATE_DIR/setup-token"
# Consumed by the sourcing verbs.
# shellcheck disable=SC2034
LUKE_EXPECTED="$LUKE_STATE_DIR/expected-digest"
LUKE_ROLLBACK_CAUSE="$LUKE_STATE_DIR/last-rollback.json"

# The identity capsule (SPEC §5.2). Everything the user tells this machine
# about who they are — the administrator account, the NAS's name, the shares —
# is recorded here and only then applied to /etc.
#
# The order matters and is the whole point. /etc does not survive a factory
# reset; /data does, and it moves with the disk. SPEC §5.2 promises that users,
# UID/GID and share definitions survive a reset that clears /etc, and those two
# sentences only fit together if something writes them back afterwards.
# lukenasos-identity.service is that something; this directory is what it reads.
# Without it, "your data survives" would mean the bytes are still on the disk
# and nobody can reach them — the broken promise SPEC §5.2 names by name.
#
# It holds password hashes, so it is 0700 and stays that way.
# shellcheck disable=SC2034
LUKE_CAPSULE="${LUKE_CAPSULE:-/var/mnt/data/.lukenasos}"
# The account the installer creates. Retired by `luke setup account` once a
# real one exists; never removed, because a machine with no way in is worse
# than a machine with a locked door.
# shellcheck disable=SC2034
LUKE_DEFAULT_USER="${LUKE_DEFAULT_USER:-luke}"

# Consumed by the sourcing verbs, not here.
# shellcheck disable=SC2034
EXIT_OK=0
EXIT_ERROR=1
# shellcheck disable=SC2034
EXIT_USAGE=2
# shellcheck disable=SC2034
EXIT_NOTHING=77

JSON=0

# Symbols carry meaning; color is reinforcement only (symbol+color, never
# color alone). Honor NO_COLOR and non-tty.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_BAD=""; C_OFF=""
fi
SYM_OK="●"; SYM_RECOVERED="▲"; SYM_DEGRADED="✕"

parse_common_flags() {
    # Strips --json from the argument list, setting JSON=1. Must run in the
    # caller's shell (NOT a subshell/process substitution) or the JSON flag
    # is lost. Remaining args land in PARSED_ARGS.
    PARSED_ARGS=()
    local a
    for a in "$@"; do
        case "$a" in
            --json) JSON=1 ;;
            *) PARSED_ARGS+=("$a") ;;
        esac
    done
}

json_escape() {
    printf '%s' "$1" | jq -Rs '.'
}

# die CODE ANCHOR WHAT CAUSE NEXT
# Every error states what failed, the likely cause, a copy-pasteable next
# command, and a doc anchor a user can photograph and search.
die() {
    local code="$1" anchor="$2" what="$3" cause="$4" next="$5"
    if [ "$JSON" = 1 ]; then
        jq -n --arg anchor "$anchor" --arg what "$what" \
              --arg cause "$cause" --arg next "$next" \
              '{error: {code: $anchor, what: $what, cause: $cause, next: $next}}'
    else
        {
            echo "${C_BAD}${SYM_DEGRADED}${C_OFF} $what"
            echo "   Cause: $cause"
            [ -n "$next" ] && echo "   Next:  $next"
            echo "   Docs:  docs/errors.md#$anchor"
        } >&2
    fi
    exit "$code"
}

persist() {
    # Flush a just-written bookkeeping file to disk. The recovery ledger
    # exists precisely for power-cut scenarios; a record that lives only
    # in the page cache dies with the power (verified: the expected-digest
    # written 15s before a cut was gone on the next boot).
    sync "$@" 2>/dev/null || sync
}

event_log() {
    # event_log TYPE JSON_DETAIL — append to the machine-local event journal.
    # /var/lib is shared across deployments in the stateroot, so events
    # survive updates and rollbacks (that is the point).
    local type="$1" detail="${2:-{\}}"
    mkdir -p "$LUKE_STATE_DIR"
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg type "$type" \
        --argjson detail "$detail" '{ts:$ts, type:$type, detail:$detail}' \
        >> "$LUKE_EVENTS"
}

booted_digest() {
    bootc status --json 2>/dev/null | jq -r '.status.booted.image.imageDigest // empty'
}

booted_version() {
    bootc status --json 2>/dev/null | jq -r '.status.booted.image.version // .status.booted.image.image.image // "unknown"'
}

staged_digest() {
    bootc status --json 2>/dev/null | jq -r '.status.staged.image.imageDigest // empty'
}

rollback_digest() {
    bootc status --json 2>/dev/null | jq -r '.status.rollback.image.imageDigest // empty'
}

image_ref() {
    # The image this machine follows. Set at install; user-changeable.
    # shellcheck disable=SC1090
    [ -f "$LUKE_CONF" ] && source "$LUKE_CONF"
    echo "${IMAGE_REF:-ghcr.io/lukehemmin/lukenasos:stable}"
}

digest_blocked() {
    [ -f "$LUKE_BLOCKLIST" ] && grep -qxF "$1" "$LUKE_BLOCKLIST"
}

block_digest() {
    mkdir -p "$LUKE_STATE_DIR"
    digest_blocked "$1" || echo "$1" >> "$LUKE_BLOCKLIST"
    persist "$LUKE_BLOCKLIST"
}

pinned_deployment_exists() {
    # The factory-reset target: deployment 0 of the install, pinned so ostree
    # cleanup can never garbage-collect it. No pin, no reset, no safety story.
    ostree admin status 2>/dev/null | grep -q "Pinned: yes"
}

require_root() {
    [ "$(id -u)" = 0 ] || die "$EXIT_ERROR" LUKE-E001 \
        "this command needs root" \
        "luke ${1:-} modifies system state" \
        "sudo luke ${1:-}"
}

# The verdict is the first thing a user must learn, in half a second.
# OK        — booted deployment is the one we expected.
# RECOVERED — greenboot rolled us back; cause is persisted.
# DEGRADED  — a health check is failing. Two sources, because greenboot only
#             runs at boot: its boot-time verdict (is-failed), AND the live
#             re-check's marker (lukenasos-health.timer), so a fault that
#             develops AFTER boot surfaces instead of the verdict staying OK.
current_verdict() {
    if [ -f "$LUKE_ROLLBACK_CAUSE" ] && [ ! -f "$LUKE_STATE_DIR/recovered-acked" ]; then
        echo RECOVERED; return
    fi
    if [ -f "$LUKE_STATE_DIR/health-degraded" ] \
        || systemctl is-failed --quiet greenboot-healthcheck.service 2>/dev/null; then
        echo DEGRADED; return
    fi
    echo OK
}

verdict_line() {
    # First line of the banner and of `luke status` — verbatim the same.
    case "$(current_verdict)" in
        OK)        echo "${C_OK}${SYM_OK}${C_OFF} OK" ;;
        DEGRADED)  echo "${C_BAD}${SYM_DEGRADED}${C_OFF} DEGRADED — a required health check is failing (luke doctor)" ;;
        RECOVERED)
            local why when from to
            why=$(jq -r '.cause // "health checks failed"' "$LUKE_ROLLBACK_CAUSE")
            when=$(jq -r '.ts // ""' "$LUKE_ROLLBACK_CAUSE")
            from=$(jq -r '.from_version // "?"' "$LUKE_ROLLBACK_CAUSE")
            to=$(jq -r '.to_version // "?"' "$LUKE_ROLLBACK_CAUSE")
            echo "${C_WARN}${SYM_RECOVERED}${C_OFF} RECOVERED — $from failed its health check; reverted to $to ($when)"
            echo "   Cause: $why"
            ;;
    esac
}
