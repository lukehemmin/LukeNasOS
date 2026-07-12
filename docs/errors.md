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

**Fix:** `journalctl -u lukenasos-update -b` shows why. Common causes: disk
pressure (`luke doctor` → disk space), a half-reachable registry, or a
signature rejection.

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

## LUKE-E050 — grubenv is not usable

greenboot's automatic rollback decrements a boot counter in
`/boot/grub2/grubenv`. If `/boot` is not ext4 (or is mounted read-only),
that write fails silently and the headline safety feature does not exist.

**Usual cause:** a hand-rolled install that put `/boot` on btrfs.

**Fix:** verify with `findmnt /boot`. The partition contract (SPEC.md §2)
requires ext4 there; reinstalling with `installer/luke.ks` is the honest
fix.
