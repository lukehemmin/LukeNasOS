#!/usr/bin/env bash
# tests/banner-setup.sh — the console banner's SETUP block.
#
# The banner is the appliance's home screen (SPEC §7) and, on a fresh
# machine, the ONLY place the setup token appears. Three ways it can lie, all
# caught here:
#   - print a wizard URL before the wizard exists (Phase 1 has no Cockpit)
#   - print a URL when there is no address to print
#   - keep printing a token after the forced password change spent it
#
# Runs the real luke/banner against stub machine facts. No VM, no image.

set -o errexit -o nounset -o pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"
        printf '%s\n' "$OUT" | sed 's/^/       | /'; }

# render <addresses…> — runs the banner with stubbed facts, fills $OUT
render() {
    rm -rf "$WORK/run"; mkdir -p "$WORK/run/bin" "$WORK/run/state" "$WORK/run/issue.d"

    cat > "$WORK/run/bin/bootc" <<'EOF'
#!/bin/sh
echo '{"status":{"booted":{"image":{"version":"1.0.0"}}}}'
EOF
    { echo '#!/bin/sh'
      for a in "$@"; do
          printf "echo '2: eth0    inet %s/24 brd 1 scope global dynamic eth0'\n" "$a"
      done
    } > "$WORK/run/bin/ip"
    # shadow: field 3 = last password change day. 0 means "must change at
    # next login", which is exactly what `chage -d 0` leaves behind.
    printf 'luke:!!:%s:0:99999:7:::\n' "$LASTCHG" > "$WORK/run/shadow"
    chmod +x "$WORK/run/bin/bootc" "$WORK/run/bin/ip"

    [ "$TOKEN" = "none" ] || printf '%s\n' "$TOKEN" > "$WORK/run/state/setup-token"
    [ "${WIZARD:-0}" = 1 ] && touch "$WORK/run/cockpit.socket"

    OUT=$(PATH="$WORK/run/bin:$PATH" \
        LUKE_STATE_DIR="$WORK/run/state" \
        LUKE_ISSUE_DIR="$WORK/run/issue.d" \
        LUKE_SHADOW="$WORK/run/shadow" \
        LUKE_COCKPIT_UNIT="$WORK/run/cockpit.socket" \
        bash "$REPO_ROOT/luke/banner" >/dev/null 2>&1; cat "$WORK/run/issue.d/40-lukenasos.issue")
}

echo "== banner: the SETUP block =="

# Phase 1: the wizard does not exist yet. A URL here would send every new
# user to a port nothing listens on.
TOKEN="abcd-efgh-jkmn"; LASTCHG=0
render 192.168.0.42
if printf '%s' "$OUT" | grep -q "abcd-efgh-jkmn" \
   && printf '%s' "$OUT" | grep -q "ssh luke@192.168.0.42" \
   && ! printf '%s' "$OUT" | grep -q "9090"; then
    ok "no wizard installed: token + ssh, never a URL to a dead port"
else bad "no wizard installed: token + ssh, never a URL to a dead port"; fi

# No lease: the dead-on-arrival screen. This is the one state where the
# product is unreachable, so it must say so rather than print nothing.
render
if printf '%s' "$OUT" | grep -q "No network address yet" \
   && printf '%s' "$OUT" | grep -q "updates itself"; then
    ok "no address: says so, and promises the refresh the dispatcher delivers"
else bad "no address: says so, and promises the refresh the dispatcher delivers"; fi

# The same code, once the wizard lands: the banner keys off the Cockpit unit
# actually being in the image, so this file appearing is the whole change.
TOKEN="abcd-efgh-jkmn"; LASTCHG=0
WIZARD=1 render 192.168.0.42
if printf '%s' "$OUT" | grep -q "https://192.168.0.42:9090" \
   && printf '%s' "$OUT" | grep -q "Advanced, then Proceed"; then
    ok "wizard installed: URL + the mobile TLS gesture, not just the fact"
else bad "wizard installed: URL + the mobile TLS gesture, not just the fact"; fi

WIZARD=1 render 192.168.0.42 10.0.5.7
if [ "$(printf '%s' "$OUT" | grep -c '9090')" = 2 ]; then
    ok "two NICs: every address offered, none guessed"
else bad "two NICs: every address offered, none guessed"; fi

# The token is spent the moment the forced change happens. Printing it after
# that is a lie, and keeping it on disk is a stale secret.
TOKEN="abcd-efgh-jkmn"; LASTCHG=20651
render 192.168.0.42
if ! printf '%s' "$OUT" | grep -q "abcd-efgh-jkmn" \
   && ! printf '%s' "$OUT" | grep -q "Setup:" \
   && [ ! -f "$WORK/run/state/setup-token" ]; then
    ok "after the password change: no token printed, file removed"
else bad "after the password change: no token printed, file removed"; fi

# An install that never had a token (a custom --kickstart with its own admin)
# must not grow a setup block.
TOKEN="none"; LASTCHG=0
render 192.168.0.42
if ! printf '%s' "$OUT" | grep -q "Setup:"; then
    ok "no token file: no setup block invented"
else bad "no token file: no setup block invented"; fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
