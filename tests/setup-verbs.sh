#!/usr/bin/env bash
# tests/setup-verbs.sh — the wizard's privileged API.
#
# These verbs are the only thing standing between a browser form and useradd,
# and they run once, on a machine whose owner is watching. The failures worth
# catching here are the ones that cannot be undone from the couch:
#   - carrying the SETUP TOKEN over as the new administrator's password
#   - retiring the installer account before the new one can log in
#   - recording nothing on /data, so the next factory reset erases the owner
#   - opening 445 for a share that was never made
#
# Runs the real luke/setup and luke/identity-apply against stub system tools.
# No VM, no image, one second.

set -o errexit -o nounset -o pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"
        printf '%s\n' "$OUT" | sed 's/^/       | /'; }

# A fake yescrypt hash: what matters to the code under test is only that it
# starts with '$', the way a real one does and the way '!' and '*' do not.
# shellcheck disable=SC2016  # a hash is literal '$y$…', not a variable
REAL_HASH='$y$j9T$abcdefghijklmnop$0123456789abcdefghijklmnopqrstuvwxyzABCDEF'

# machine [luke-lastchg] [luke-hash] — stand up a fresh fake machine in $WORK.
machine() {
    local lastchg="${1:-20651}" hash="${2:-$REAL_HASH}"
    rm -rf "$WORK/m"; mkdir -p "$WORK/m/bin" "$WORK/m/state" "$WORK/m/capsule" \
        "$WORK/m/nft" "$WORK/m/share" "$WORK/m/home/luke/.ssh" "$WORK/m/etc" "$WORK/m/ssh" \
        "$WORK/m/cockpit"
    # The Cockpit login hint, as the image ships it (fresh-install text).
    printf "Sign in as 'luke'. The password is the setup token.\n" \
        > "$WORK/m/cockpit/issue.cockpit"
    # The machine's ssh identity, as first-boot generated it.
    printf 'ORIGINAL-HOST-KEY\n' > "$WORK/m/ssh/ssh_host_ed25519_key"
    printf 'ORIGINAL-HOST-KEY-PUB\n' > "$WORK/m/ssh/ssh_host_ed25519_key.pub"

    printf 'luke:%s:%s:0:99999:7:::\n' "$hash" "$lastchg" > "$WORK/m/shadow"
    printf 'root:x:0:0::/root:/bin/bash\nluke:x:1000:1000::%s/home/luke:/bin/bash\n' \
        "$WORK/m" > "$WORK/m/passwd"
    printf 'Image=ghcr.io/servercontainers/samba:latest\n' > "$WORK/m/samba.container"
    : > "$WORK/m/groups-of-luke"   # luke is in wheel; see the id stub

    # ── stub system tools ────────────────────────────────────────────────
    # Each records what it was asked to do, so a test can assert on the ORDER
    # of real-world effects, not just on the exit code.
    cat > "$WORK/m/bin/getent" <<EOF
#!/bin/bash
case "\$1" in
  passwd)
    if [ -n "\${2:-}" ]; then grep -q "^\$2:" "$WORK/m/passwd" && grep "^\$2:" "$WORK/m/passwd"; exit \$?; fi
    cat "$WORK/m/passwd" ;;
  group) grep -q ":\${2}:" "$WORK/m/group" 2>/dev/null ;;
esac
EOF
    cat > "$WORK/m/bin/useradd" <<EOF
#!/bin/bash
echo "useradd \$*" >> "$WORK/m/calls"
name="\${@: -1}"
uid=1001
while [ \$# -gt 0 ]; do case "\$1" in --uid) uid="\$2" ;; esac; shift; done
printf '%s:x:%s:%s::%s/home/%s:/bin/bash\n' "\$name" "\$uid" "\$uid" "$WORK/m" "\$name" >> "$WORK/m/passwd"
mkdir -p "$WORK/m/home/\$name"
EOF
    cat > "$WORK/m/bin/userdel" <<EOF
#!/bin/bash
echo "userdel \$*" >> "$WORK/m/calls"
name="\${@: -1}"
grep -v "^\$name:" "$WORK/m/passwd" > "$WORK/m/passwd.tmp" && mv "$WORK/m/passwd.tmp" "$WORK/m/passwd"
EOF
    cat > "$WORK/m/bin/chpasswd" <<EOF
#!/bin/bash
read -r line
echo "chpasswd \$* \$line" >> "$WORK/m/calls"
[ -f "$WORK/m/chpasswd-fails" ] && exit 1
printf '%s\n' "\$line" >> "$WORK/m/passwords-set"
exit 0
EOF
    # Locking has to stick, or "does nothing on a converged boot" cannot be
    # told apart from "relocks a locked account every boot".
    cat > "$WORK/m/bin/usermod" <<EOF
#!/bin/bash
echo "usermod \$*" >> "$WORK/m/calls"
case "\$*" in *--lock*luke*) touch "$WORK/m/luke-locked" ;; esac
exit 0
EOF
    # install(1) consults the real /etc/passwd for -o, which knows nothing of
    # this machine's fake users. Emulate the effect and log the intent.
    #
    # -m is APPLIED, not just parsed away. The first version dropped it and fell
    # back to mkdir's umask, so a test asserting on permissions was reading this
    # stub's mind instead of the product's — the exact failure these stubs keep
    # having, and the reason the ACCESS_DENIED below reached a real machine.
    cat > "$WORK/m/bin/install" <<EOF
#!/bin/bash
echo "install \$*" >> "$WORK/m/calls"
dirmode=0; mode=""; paths=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -d) dirmode=1 ;;
    -m) mode="\$2"; shift ;;
    -o|-g) shift ;;
    *) paths+=("\$1") ;;
  esac
  shift
done
if [ "\$dirmode" = 1 ]; then
  mkdir -p "\${paths[@]}"
  [ -n "\$mode" ] && chmod "\$mode" "\${paths[@]}"
else
  cp "\${paths[0]}" "\${paths[1]}"
  [ -n "\$mode" ] && chmod "\$mode" "\${paths[1]}"
fi
exit 0
EOF
    cat > "$WORK/m/bin/passwd" <<EOF
#!/bin/bash
# -S NAME: 'P' when a usable password was set on this fake machine.
name="\${2:-}"
if [ "\$name" = luke ] && [ -f "$WORK/m/luke-locked" ]; then echo "luke L"; exit 0; fi
if [ "\$name" = luke ]; then echo "luke P"; exit 0; fi
if grep -q "^\$name:" "$WORK/m/passwords-set" 2>/dev/null; then echo "\$name P"; else echo "\$name L"; fi
EOF
    # Bare `id -u` answers 0 so these tests say the same thing whoever runs
    # them: the point is what the verb does once it is root, not whether the
    # person running the suite happens to be.
    cat > "$WORK/m/bin/id" <<EOF
#!/bin/bash
case "\$1" in
  -u) [ -z "\${2:-}" ] && echo 0 || grep "^\$2:" "$WORK/m/passwd" | cut -d: -f3 ;;
  -g) grep "^\$2:" "$WORK/m/passwd" | cut -d: -f4 ;;
  -nG) [ "\$2" = luke ] && echo "luke wheel" || echo "\$2 wheel" ;;
esac
EOF
    # hostnamectl really does write /etc/hostname, and identity-apply reads it
    # back to decide whether there is anything to restore. A stub that only
    # logged would make every boot look like a boot after a factory reset.
    cat > "$WORK/m/bin/hostnamectl" <<EOF
#!/bin/bash
echo "hostnamectl \$*" >> "$WORK/m/calls"
[ "\${1:-}" = set-hostname ] && printf '%s\n' "\$2" > "$WORK/m/etc-hostname"
exit 0
EOF
    printf 'localhost\n' > "$WORK/m/etc-hostname"
    for noop in chage systemctl groupadd nft; do
        cat > "$WORK/m/bin/$noop" <<EOF
#!/bin/bash
echo "$noop \$*" >> "$WORK/m/calls"
exit 0
EOF
    done
    # The Samba image's create-hash.sh, as invoked through podman. Modelled on
    # the real script (ServerContainers/samba, scripts/create-hash.sh), including
    # the part that broke the first attempt: it writes its prompts to stderr, but
    # each silent read is followed by a bare `echo` that lands on STDOUT. So the
    # hash is NOT the whole output — it is preceded by two blank lines. A stub
    # that emitted only the hash agreed with my reading of the script instead of
    # with the script, and both were green while the real thing failed.
    cat > "$WORK/m/bin/podman" <<EOF
#!/bin/bash
echo "podman \$*" >> "$WORK/m/calls"
[ -f "$WORK/m/podman-fails" ] && { echo "Error: initializing source: manifest unknown" >&2; exit 125; }
printf '>> Enter username: ' >&2
read -r u
printf '>> New password: ' >&2
read -r p1
echo
printf '>> Retype password: ' >&2
read -r _p2
echo
printf '%s:1000:XXXXXXXX:%s:[U          ]:LCT-5FE1F7DF:\n' "\$u" "\$(printf '%s' "\$p1" | md5sum | cut -c1-32 | tr 'a-f' 'A-F')"
EOF
    chmod +x "$WORK/m/bin"/*
}

# run <args…> — the real verb against the fake machine. stdin passes through.
run() {
    set +o errexit
    OUT=$(PATH="$WORK/m/bin:$PATH" \
        LUKE_STATE_DIR="$WORK/m/state" \
        LUKE_CAPSULE="$WORK/m/capsule" \
        LUKE_CAPSULE_UNSAFE=1 \
        LUKE_SHADOW="$WORK/m/shadow" \
        LUKE_QUADLET="$WORK/m/samba.container" \
        LUKE_NFT_DIR="$WORK/m/nft" \
        LUKE_SHARE_ROOT="$WORK/m/share" \
        LUKE_COCKPIT_CONF_DIR="$WORK/m/cockpit" \
        bash "$REPO_ROOT/luke/setup" "$@" 2>&1)
    RC=$?
    set -o errexit
}

called() { grep -q "$1" "$WORK/m/calls" 2>/dev/null; }

echo "== luke setup: the wizard's privileged API =="

# ── the token guard ───────────────────────────────────────────────────────
# Step 1 asks for no password because the one chosen at the forced change comes
# along. Before that change, the hash on disk IS the setup token — a secret
# printed on a screen in the room, and the design's "your password follows you"
# would quietly mean "the token follows you".
machine 0
run account --name sangho
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "setup password has not been changed" \
   && ! called useradd; then
    ok "unspent token: refuses to carry it over as a real password"
else bad "unspent token: refuses to carry it over as a real password"; fi

# A locked/absent password is not a hash. Copying '!' would create an
# administrator with no way in, and then retire the account that had one.
machine 20651 '!!'
run account --name sangho
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "no password to carry over" \
   && ! called useradd; then
    ok "no usable password on the installer account: refuses rather than locks the box"
else bad "no usable password on the installer account: refuses rather than locks the box"; fi

# ── the happy path ────────────────────────────────────────────────────────
machine
run account --name sangho --json
if [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.result == "created" and .user == "sangho"' >/dev/null 2>&1; then
    ok "creates the administrator and says so in JSON the wizard can read"
else bad "creates the administrator and says so in JSON the wizard can read"; fi

if grep -q "sangho:$(printf '%s' "$REAL_HASH")" "$WORK/m/passwords-set" 2>/dev/null; then
    ok "the password chosen at the PAM prompt is what the new account gets"
else bad "the password chosen at the PAM prompt is what the new account gets"; fi

# The login page said "sign in as luke, the token is the password" — true
# until the line that retired luke, and a lie every day after.
if ! grep -qi "token" "$WORK/m/cockpit/issue.cockpit"; then
    ok "the login page stops telling people to sign in with the token"
else bad "the login page stops telling people to sign in with the token"; fi

# The capsule is the whole reason a factory reset does not erase the owner.
if [ -f "$WORK/m/capsule/accounts/sangho.json" ] \
   && jq -e '.uid == 1001 and .groups == ["wheel"] and (.hash | startswith("$y$"))' \
        "$WORK/m/capsule/accounts/sangho.json" >/dev/null; then
    ok "records the account on /data, uid and hash included"
else bad "records the account on /data, uid and hash included"; fi

if [ "$(stat -c %a "$WORK/m/capsule/accounts/sangho.json")" = 600 ] \
   && [ "$(stat -c %a "$WORK/m/capsule")" = 700 ]; then
    ok "the capsule holds password hashes, and is 0700/0600 accordingly"
else bad "the capsule holds password hashes, and is 0700/0600 accordingly"; fi

# Order is the safety property: retiring 'luke' before the new account is
# proven usable is how a first-boot wizard bricks a machine remotely.
lock_line=$(grep -n "usermod --lock" "$WORK/m/calls" | cut -d: -f1)
pw_line=$(grep -n "chpasswd -e sangho:" "$WORK/m/calls" | cut -d: -f1)
if [ -n "$lock_line" ] && [ -n "$pw_line" ] && [ "$pw_line" -lt "$lock_line" ]; then
    ok "retires 'luke' only after the new account has a working password"
else bad "retires 'luke' only after the new account has a working password"; fi

# ── the rollback ──────────────────────────────────────────────────────────
# If the password cannot be carried over, the half-made user must go with it —
# and 'luke' must still be the way in.
machine
touch "$WORK/m/chpasswd-fails"
run account --name sangho
if [ "$RC" != 0 ] && called "userdel --remove sangho" && ! called "usermod --lock"; then
    ok "a failed transfer removes the half-made account and leaves 'luke' alone"
else bad "a failed transfer removes the half-made account and leaves 'luke' alone"; fi

# ── names ─────────────────────────────────────────────────────────────────
machine
run account --name Sangho
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "cannot be a user name"; then
    ok "rejects a name Samba would lowercase behind the user's back"
else bad "rejects a name Samba would lowercase behind the user's back"; fi

machine
run account --name luke
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "installer's own account"; then
    ok "refuses to name the new administrator after the one being retired"
else bad "refuses to name the new administrator after the one being retired"; fi

# ── already set up ────────────────────────────────────────────────────────
# An interactive install made an administrator already: the wizard skips step 1
# rather than making a second one.
machine
printf 'sangho:x:1001:1001::%s/home/sangho:/bin/bash\n' "$WORK/m" >> "$WORK/m/passwd"
run account --name other --json
if [ "$RC" = 77 ] && printf '%s' "$OUT" | jq -e '.result == "current" and .user == "sangho"' >/dev/null 2>&1; then
    ok "an administrator already exists: exit 77, and names who it is"
else bad "an administrator already exists: exit 77, and names who it is"; fi

# ── hostname ──────────────────────────────────────────────────────────────
machine
run hostname --name My_NAS
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "cannot be a NAS name"; then
    ok "rejects a hostname the LAN could not resolve"
else bad "rejects a hostname the LAN could not resolve"; fi

machine
run hostname --name luke-nas --json
if [ "$RC" = 0 ] && [ "$(cat "$WORK/m/capsule/hostname")" = "luke-nas" ] \
   && called "hostnamectl set-hostname luke-nas"; then
    ok "records the NAS name on /data, then applies it"
else bad "records the NAS name on /data, then applies it"; fi

run hostname --name luke-nas
if [ "$RC" = 77 ]; then
    ok "the same name twice: exit 77, like every other verb"
else bad "the same name twice: exit 77, like every other verb"; fi

# ── share ─────────────────────────────────────────────────────────────────
machine
run account --name sangho
run share --name family --user sangho --password-stdin <<< "hunter2"
if [ "$RC" = 0 ] && [ -f "$WORK/m/capsule/shares/family.json" ]; then
    ok "creates the first share"
else bad "creates the first share"; fi

# The credential Samba needs cannot come from the Unix hash — an NT hash is not
# derivable from yescrypt. What lands on disk must be the hash the container
# made, never the plaintext of an account that also opens ssh and Cockpit.
if grep -q '^ACCOUNT_sangho=sangho:1000:' "$WORK/m/capsule/samba.env" \
   && ! grep -q "hunter2" "$WORK/m/capsule/samba.env" \
   && ! grep -rq "hunter2" "$WORK/m/capsule/accounts/"; then
    ok "stores the Samba hash, never the plaintext password"
else bad "stores the Samba hash, never the plaintext password"; fi

if grep -q 'SAMBA_VOLUME_CONFIG_family=\[family\]; path=/share/family; valid users = sangho' \
        "$WORK/m/capsule/samba.env"; then
    ok "the share definition names its owner, and only its owner"
else bad "the share definition names its owner, and only its owner"; fi

# Samba serves a file AS the account that authenticated, so the directory the
# shares hang under has to be traversable by someone who is not root. It shipped
# 0770 root:root, and the result on a real machine was every file in every share
# answering NT_STATUS_ACCESS_DENIED — with the port open, the password accepted
# and the share listed. The share itself stays 0770: its contents are the
# secret, its name is not.
share_root_mode=$(stat -c %a "$WORK/m/share")
share_mode=$(stat -c %a "$WORK/m/share/family")
if [ "$(( 8#$share_root_mode & 8#0005 ))" = "$(( 8#0005 ))" ] && [ "$share_mode" = 770 ]; then
    ok "the shares directory can be walked through; the share itself cannot"
else
    OUT="shares dir=$share_root_mode (needs o+rx to traverse), share=$share_mode (wants 770)"
    bad "the shares directory can be walked through; the share itself cannot"
fi

# 445 opens because a share exists — that is the promise in SPEC §9 and in the
# policy's own comment.
if grep -q "tcp dport 445 accept" "$WORK/m/nft/10-shares.nft" \
   && called "systemctl reload-or-restart nftables"; then
    ok "opens 445 for the share, through the policy rather than around it"
else bad "opens 445 for the share, through the policy rather than around it"; fi

# A password flag would land in shell history, in ps, and in the journal.
machine
run account --name sangho
run share --name family --user sangho
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "password-stdin"; then
    ok "no --password flag: the only way in is stdin"
else bad "no --password flag: the only way in is stdin"; fi

# A share for a user the capsule never made would not survive a factory reset:
# the share comes back, the account does not, and the bytes are unreachable.
machine
run share --name family --user luke --password-stdin <<< "hunter2"
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "not an account this NAS set up"; then
    ok "refuses a share owned by an account the capsule does not carry"
else bad "refuses a share owned by an account the capsule does not carry"; fi

# The image is where the hash comes from; if it cannot be pulled, nothing must
# be half-made — no share file, no open port.
machine
run account --name sangho
touch "$WORK/m/podman-fails"
run share --name family --user sangho --password-stdin <<< "hunter2"
if [ "$RC" != 0 ] && [ ! -f "$WORK/m/capsule/shares/family.json" ] \
   && [ ! -f "$WORK/m/nft/10-shares.nft" ]; then
    ok "no Samba image, no share: nothing half-made, 445 stays shut"
else bad "no Samba image, no share: nothing half-made, 445 stays shut"; fi

# ── status ────────────────────────────────────────────────────────────────
machine
run status --json
if [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e \
    '.account.done == false and .hostname.done == false and .share.done == false and .complete == false' \
    >/dev/null 2>&1; then
    ok "a fresh machine: nothing done, and the wizard can tell"
else bad "a fresh machine: nothing done, and the wizard can tell"; fi

run account --name sangho
run hostname --name luke-nas
run share --name family --user sangho --password-stdin <<< "hunter2"
run status --json
if printf '%s' "$OUT" | jq -e \
    '.complete == true and .account.user == "sangho" and .share.shares == ["family"]' \
    >/dev/null 2>&1; then
    ok "after all three: complete, and every answer is derived from the machine"
else bad "after all three: complete, and every answer is derived from the machine"; fi

# ── identity-apply: the reason the capsule exists ─────────────────────────
# The factory reset. /etc is gone: no sangho, no hostname, and 'luke' is back
# with the password from the setup token. The capsule on /data is untouched.
echo
echo "== identity-apply: /etc is fresh, /data remembers =="

# Everything /etc held is gone: no sangho, no name, and 'luke' unlocked again
# with the password the setup token set. This is exactly what deployment 0
# carries, because that is what a factory reset boots into.
reset_etc() {
    printf 'root:x:0:0::/root:/bin/bash\nluke:x:1000:1000::%s/home/luke:/bin/bash\n' \
        "$WORK/m" > "$WORK/m/passwd"
    rm -f "$WORK/m/calls" "$WORK/m/passwords-set" "$WORK/m/nft/10-shares.nft" \
          "$WORK/m/luke-locked"
    rm -rf "$WORK/m/home/sangho"
    printf 'localhost\n' > "$WORK/m/etc-hostname"
    # sshd-keygen makes new host keys into the blank /etc. This is the whole
    # reason clients get REMOTE HOST IDENTIFICATION HAS CHANGED after a reset.
    printf 'REGENERATED-AFTER-RESET\n' > "$WORK/m/ssh/ssh_host_ed25519_key"
    printf 'REGENERATED-PUB\n' > "$WORK/m/ssh/ssh_host_ed25519_key.pub"
    # The fresh /etc holds the image's fresh-install login hint again.
    printf "Sign in as 'luke'. The password is the setup token.\n" \
        > "$WORK/m/cockpit/issue.cockpit"
}

apply() {
    set +o errexit
    OUT=$(PATH="$WORK/m/bin:$PATH" \
        LUKE_STATE_DIR="$WORK/m/state" \
        LUKE_CAPSULE="$WORK/m/capsule" \
        LUKE_NFT_DIR="$WORK/m/nft" \
        LUKE_HOSTNAME_FILE="$WORK/m/etc-hostname" \
        LUKE_SSH_DIR="$WORK/m/ssh" \
        LUKE_COCKPIT_CONF_DIR="$WORK/m/cockpit" \
        bash "$REPO_ROOT/luke/identity-apply" 2>&1)
    RC=$?
    set -o errexit
}

# Before the reset, a normal boot: the machine's ssh identity is taken into the
# capsule, because after the reset there is nowhere else it could come from.
apply
if [ "$(cat "$WORK/m/capsule/ssh_host_ed25519_key")" = "ORIGINAL-HOST-KEY" ]; then
    ok "captures the ssh host identity while there is still one to capture"
else bad "captures the ssh host identity while there is still one to capture"; fi

reset_etc
apply
if [ "$RC" = 0 ] && called "useradd --uid 1001"; then
    ok "recreates the administrator a reset erased"
else bad "recreates the administrator a reset erased"; fi

# The scariest message in ssh, produced by the recovery feature, on a product
# that sells recovery. SPEC §5.2 lists the host keys as surviving; factory-reset
# has always copied them to /data and nothing ever copied them back.
if [ "$(cat "$WORK/m/ssh/ssh_host_ed25519_key")" = "ORIGINAL-HOST-KEY" ] \
   && [ "$(cat "$WORK/m/ssh/ssh_host_ed25519_key.pub")" = "ORIGINAL-HOST-KEY-PUB" ] \
   && called "systemctl restart sshd"; then
    ok "restores the ssh host identity: no REMOTE HOST IDENTIFICATION HAS CHANGED"
else bad "restores the ssh host identity: no REMOTE HOST IDENTIFICATION HAS CHANGED"; fi

# The uid is the whole point: every file on /data is owned by a number, and a
# user recreated with a different one is a stranger to their own photos.
if grep -q "useradd --uid 1001 --gid 1001" "$WORK/m/calls" \
   && grep -q "^sangho:$(printf '%s' "$REAL_HASH")" "$WORK/m/passwords-set"; then
    ok "restores the same uid and the same password, not a new account"
else bad "restores the same uid and the same password, not a new account"; fi

if called "hostnamectl set-hostname luke-nas"; then
    ok "the NAS remembers its name through a reset"
else bad "the NAS remembers its name through a reset"; fi

# A reset brings 'luke' back unlocked, holding the token password from months
# ago. Nothing else will ever retire it again.
if called "usermod --lock --expiredate 1 luke"; then
    ok "retires the installer account again, every time /etc comes back fresh"
else bad "retires the installer account again, every time /etc comes back fresh"; fi

# Same story, told to the login page: the fresh /etc says "sign in with the
# token" again, about an account the line above just re-retired.
if ! grep -qi "token" "$WORK/m/cockpit/issue.cockpit"; then
    ok "the reset does not resurrect the token hint on the login page"
else bad "the reset does not resurrect the token hint on the login page"; fi

if grep -q "tcp dport 445 accept" "$WORK/m/nft/10-shares.nft" \
   && grep -q '^ACCOUNT_sangho=' "$WORK/m/capsule/samba.env"; then
    ok "the shares come back, and so does their open port"
else bad "the shares come back, and so does their open port"; fi

# Second boot: nothing changed, so nothing should be touched.
rm -f "$WORK/m/calls"
apply
if [ "$RC" = 0 ] && ! called useradd && ! called hostnamectl; then
    ok "a normal boot: converged already, so it does nothing"
else bad "a normal boot: converged already, so it does nothing"; fi

echo
echo "== setup stamp: the wizard's bookmark =="

# Step 1 ends by signing the browser out; the stamp is how the re-login lands
# on step 2 instead of a form that was already submitted.
machine
run stamp --step 2 --json
if [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.result == "stamped"' >/dev/null 2>&1 \
   && [ "$(cat "$WORK/m/state/wizard-step")" = 2 ]; then
    ok "stamps where the user was, in machine-local state"
else bad "stamps where the user was, in machine-local state"; fi

run status --json
if [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.wizard.step == "2"' >/dev/null 2>&1; then
    ok "status hands the bookmark back to the resuming wizard"
else bad "status hands the bookmark back to the resuming wizard"; fi

# A stamp is a bookmark, not identity: it lives in /var/lib (erased by a
# factory reset, correctly — a reset machine re-runs the wizard), never in
# the capsule.
if [ ! -e "$WORK/m/capsule/wizard-step" ]; then
    ok "the bookmark stays out of the identity capsule"
else bad "the bookmark stays out of the identity capsule"; fi

run stamp --step 9 --json
if [ "$RC" = 2 ] && printf '%s' "$OUT" | jq -e '.error.code == "LUKE-E002"' >/dev/null 2>&1; then
    ok "a step that does not exist is refused as usage, with the accepted values named"
else bad "a step that does not exist is refused as usage, with the accepted values named"; fi

echo
echo "== unlock-console: the machine room's door, on the record =="

# A locked machine, the way the image ships one: the page list plus one
# override per page — and one override the OWNER wrote, which is not ours to
# delete.
lock_console() {
    mkdir -p "$WORK/m/cockpit"
    printf 'systemd\nusers\nstoraged\n' > "$WORK/m/hidden-pages"
    for p in systemd users storaged; do
        printf '{"menu": null}\n' > "$WORK/m/cockpit/$p.override.json"
    done
    printf '{"menu": {"custom": {}}}\n' > "$WORK/m/cockpit/owners-own.override.json"
}

run_unlock() {
    set +o errexit
    OUT=$(PATH="$WORK/m/bin:$PATH" \
        LUKE_STATE_DIR="$WORK/m/state" \
        LUKE_COCKPIT_CONF_DIR="$WORK/m/cockpit" \
        LUKE_HIDDEN_PAGES="$WORK/m/hidden-pages" \
        bash "$REPO_ROOT/luke/unlock-console" "$@" 2>&1)
    RC=$?
    set -o errexit
}

lock_console
run_unlock --json
if [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.result == "unlocked" and (.pages | length) == 3' >/dev/null 2>&1 \
   && [ ! -f "$WORK/m/cockpit/systemd.override.json" ]; then
    ok "unlock removes every shipped override and names the pages it revealed"
else bad "unlock removes every shipped override and names the pages it revealed"; fi

if [ -f "$WORK/m/cockpit/owners-own.override.json" ]; then
    ok "an override the owner wrote themselves is not ours to delete"
else bad "an override the owner wrote themselves is not ours to delete"; fi

# The verb's whole reason to exist over `rm`: the machine's history says who
# opened the machine room, and when.
if jq -e 'select(.type == "console_unlocked") | .detail.pages == ["systemd","users","storaged"]' \
        "$WORK/m/state/events.jsonl" >/dev/null 2>&1; then
    ok "the unlock is an event, with the revealed pages in it"
else bad "the unlock is an event, with the revealed pages in it"; fi

run_unlock --json
if [ "$RC" = 77 ] && printf '%s' "$OUT" | jq -e '.result == "already-unlocked"' >/dev/null 2>&1; then
    ok "a second unlock is nothing-to-do (77), not a fresh success"
else bad "a second unlock is nothing-to-do (77), not a fresh success"; fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
