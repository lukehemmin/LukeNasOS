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
        "$WORK/m/nft" "$WORK/m/share" "$WORK/m/home/luke/.ssh" "$WORK/m/etc" "$WORK/m/ssh"
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
    cat > "$WORK/m/bin/install" <<EOF
#!/bin/bash
echo "install \$*" >> "$WORK/m/calls"
dirmode=0; paths=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -d) dirmode=1 ;;
    -m|-o|-g) shift ;;
    *) paths+=("\$1") ;;
  esac
  shift
done
if [ "\$dirmode" = 1 ]; then mkdir -p "\${paths[@]}"; else cp "\${paths[0]}" "\${paths[1]}"; fi
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
    # The Samba image's create-hash.sh, as invoked through podman: reads
    # username + password twice on stdin, prints the smbpasswd line.
    cat > "$WORK/m/bin/podman" <<EOF
#!/bin/bash
echo "podman \$*" >> "$WORK/m/calls"
[ -f "$WORK/m/podman-fails" ] && exit 1
read -r u; read -r p1; read -r _p2
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
}

apply() {
    set +o errexit
    OUT=$(PATH="$WORK/m/bin:$PATH" \
        LUKE_STATE_DIR="$WORK/m/state" \
        LUKE_CAPSULE="$WORK/m/capsule" \
        LUKE_NFT_DIR="$WORK/m/nft" \
        LUKE_HOSTNAME_FILE="$WORK/m/etc-hostname" \
        LUKE_SSH_DIR="$WORK/m/ssh" \
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
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
