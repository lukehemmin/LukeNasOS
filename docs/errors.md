# LukeNasOS error codes

Every `luke` error prints a stable code. Search this page for yours; each
entry says what failed, why it usually happens, and the command that fixes
it. Exit codes: `0` ok · `1` error · `2` usage · `77` nothing to do.

---

## LUKE-E001 — this command needs root

The verb modifies system state. Run it with `sudo`.

## LUKE-E002 — unknown option

The verb prints what it accepts. `luke <verb> --help` shows usage.

## LUKE-E010 — no pinned rollback target on this machine

`luke update` refuses to stage anything unless the pinned install
deployment (the factory-reset target) exists. Updating without a safety net
is how a NAS dies.

**Usual cause:** the deployment was unpinned manually, or the install path
skipped `ostree admin pin 0`.

**Fix:** `ostree admin status` to find the known-good deployment, then
`sudo ostree admin pin <index>`, then re-run `luke update`.

## LUKE-E020 — could not reach the update registry

`skopeo inspect` against your `IMAGE_REF` (in `/etc/lukenasos/luke.conf`)
failed.

**Usual cause:** no network, DNS failure, or the registry is down. A clock
far in the past also breaks TLS — `luke doctor` checks this.

**Fix:** `luke doctor`, then `luke update --check`.

## LUKE-E021 — staging the update failed

The pull ran inside the `lukenasos-update` systemd unit and did not finish.

**Fix:** the error's own `Cause:` line carries what the stage command actually
said — read that first; it is the answer in most cases. Common ones: disk
pressure (`luke doctor` → disk space), a half-reachable registry, or a
signature rejection.

`journalctl -u lukenasos-update` has the unit's full output if you want more
than the one line. That was not true for most of this project's life: the unit
ran under `systemd-run --pipe`, which routed its output through the pipe
instead of the journal, so the journal held nothing but systemd's own "Failed
to start" line while this page sent people there. Dropping `--pipe` (it also
broke staging over ssh entirely — SELinux refuses to let `dbus-broker` read an
ssh session's fifo) fixed the advice and the bug at once.

## LUKE-E023 — this version was rolled back on this machine

The digest you are trying to install failed its health checks here before,
was automatically rolled back, and is blocked from retry. Installing it
again would fail the same way.

**Fix:** wait for the next release. If you know why it failed and have fixed
the cause (for example a full disk): `luke update --force`.

## LUKE-E030 — no previous version to undo to

The machine has only one deployment (fresh install, or after a cleanup).

## LUKE-E031 — undo would re-activate a version that failed here

`bootc rollback` is a boot-order swap: undoing twice boots the exact image
you just escaped. The target digest is on the block list.

**Fix:** `luke status --events` to see the history. If you are sure:
`luke undo --force`.

## LUKE-E032 — an update is staged; undo would be ambiguous

A staged update and a rollback both claim the next boot.

**Fix:** reboot to apply the update first, or discard the staged deployment,
then `luke undo`.

## LUKE-E033 — bootc rollback failed

**Fix:** `journalctl -b` around the timestamp; `luke doctor`; file an issue
with both outputs if it persists.

## LUKE-E040 — no pinned install deployment found

Factory reset needs its target. Same cause and fix as
[LUKE-E010](#luke-e010--no-pinned-rollback-target-on-this-machine).

## LUKE-E041 — factory reset needs interactive confirmation

`--json` implies automation, and automation must never reset a machine
implicitly. Run it interactively and type the hostname when asked. Test
harnesses may pass `--yes-i-typed-the-hostname`.

## LUKE-E042 — could not identify the pinned deployment

`ostree admin status` output did not parse. File an issue with that output.

## LUKE-E043 — deploying the pinned install image failed

**Fix:** `journalctl -b`; if the ostree repo itself is damaged, the `@seed`
recovery archive is the fallback: see `docs/exit-plan.md`.

## LUKE-E044 — could not carry /etc/fstab into the reset deployment

Factory reset gives the new deployment a genuinely fresh `/etc` — but the
mount table (`fstab`) describes the disk, not the configuration, and rides
across (like the kernel arguments). This error means that copy failed, most
often because `/sysroot` could not be remounted writable. The reset
deployment is staged but incomplete: booting it would leave `/boot` unmounted
and half the OS tooling failing.

**Fix:** re-run `luke factory-reset` (it stages a fresh deployment), then
`luke doctor` if it repeats.

## LUKE-E050 — grubenv is not usable

greenboot's automatic rollback decrements a boot counter in
`/boot/grub2/grubenv`. If `/boot` is not ext4 (or is mounted read-only),
that write fails silently and the headline safety feature does not exist.

**Usual cause:** a hand-rolled install that put `/boot` on btrfs.

**Fix:** verify with `findmnt /boot`. The partition contract (SPEC.md §2)
requires ext4 there; reinstalling with `installer/luke.ks` is the honest
fix.

## LUKE-E060 — the data filesystem is not mounted

`luke setup` records what you decide — your account, this NAS's name, your
shares — into the identity capsule on `/data`, and only then applies it. That
is what makes a factory reset give you your NAS back rather than just your
bytes (SPEC §5.2). With `/var/mnt/data` unmounted, the capsule would be written
to the root filesystem instead, where the next factory reset erases it — the
promise would look kept until the day it mattered.

**Fix:** `findmnt /var/mnt/data`, then `luke doctor`.

## LUKE-E061 — the setup password has not been changed yet

`luke setup account` carries the password you chose at first login over to your
new account, so you never type a third one. Before that forced change, the
password on the machine is still the **setup token** — the code printed on the
console banner. Copying it would make your administrator account's password a
string that was displayed on a screen in a room.

**Fix:** sign in as `luke` once (console, ssh, or the wizard), choose a
password, then run setup again.

## LUKE-E062 — the installer account has no password to carry over

`luke`'s shadow entry holds `!`, `*`, or nothing rather than a hash, so there
is nothing to transfer. Creating the account anyway would give it no way in,
and then retire the account that had one.

**Fix:** `sudo passwd luke`, then re-run.

## LUKE-E063 — that cannot be a NAS name

One DNS label: 1–63 characters, lowercase letters, digits and hyphens, starting
and ending with a letter or digit. Not a full domain name.

## LUKE-E064 — could not set the hostname

`hostnamectl` refused. The name is already recorded in the capsule, so it is
applied on the next boot by `lukenasos-identity.service` either way.

**Fix:** `luke doctor`; `systemctl status systemd-hostnamed`.

## LUKE-E065 — that cannot be a user name

1–32 characters, starting with a lowercase letter, then lowercase letters,
digits, hyphen or underscore. Lowercase only, deliberately: Samba lowercases
user names, and a mixed-case account would surface as a share rejecting the
password you just typed. `luke` itself is refused — that account is being
retired.

## LUKE-E066 — that user name is taken

**Fix:** `luke setup account --name <another name>`.

## LUKE-E067 — there is no installer account to carry a password over from

`luke` does not exist, so this machine was not installed by
`installer/luke.ks` and there is no password to transfer.

**Fix:** create the account directly: `useradd -m -G wheel <name>`.

## LUKE-E068 — could not create the account

`useradd` or `chpasswd` failed. The half-made account was removed and `luke`
was left alone: this machine is still reachable the way it was a moment ago.

**Fix:** `luke doctor`, then re-run.

## LUKE-E069 — that cannot be a share name

1–32 characters, letters, digits, hyphen or underscore. `global`, `homes`,
`printers` and `print$` mean something else inside a Samba configuration.

## LUKE-E070 — no such user for this share

A share names who may open it, and that account must exist **and** be one this
NAS set up — only accounts in the identity capsule survive a factory reset, and
a share whose owner does not come back is a share nobody can open.

**Fix:** `luke setup account --name <user>` first.

## LUKE-E071 — no password arrived on stdin

`--password-stdin` was given and nothing was piped in. There is no `--password`
flag on purpose: it would land in your shell history, in `ps`, and in the
journal.

**Fix:** `printf '%s' "$password" | luke setup share --name <share> --user <user> --password-stdin`

## LUKE-E072 — could not create the Samba credential

Samba passwords are NT hashes and Unix passwords are not; neither can be
derived from the other, so the Samba container image turns your password into
the hash Samba stores. This error means that image could not run — most often
because it has not been pulled yet and this machine has no network.

**Fix:** the error's own `Cause:` line carries what the container actually said;
read that first. Then `luke doctor` (network), then re-run. Nothing was
half-made: no share was recorded and port 445 is still shut.

## LUKE-E073 — the share was created but Samba did not start

The share is recorded in the capsule; the container did not come up.

**Fix:** `systemctl status samba.service`, then `luke doctor`.
