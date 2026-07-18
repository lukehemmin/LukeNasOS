# LukeNasOS

**A NAS with an undo button.**

Updating is not scary, and if you break it, resetting keeps your data.

- **Atomic updates** — an update either fully applies or does not apply at
  all. Staged in the background; takes effect on a reboot you choose.
- **Hands-off rollback** — a bad update that boots but fails its health
  checks reverts itself. Nobody has to be awake for it. The next boot tells
  you what happened and why.
- **Data-preserving factory reset** — the OS returns to its install state;
  `/data` survives by design, and the machine says so on screen.
- **Boot-drive portability** — pull the boot drive, put it in another
  machine, the NAS personality comes back from `/data`.
- Runs where TrueNAS cannot: **ARM64**, as separate per-target images.

Built as a [bootc](https://bootc-dev.github.io/bootc/) image derived from
Fedora bootc / uCore. NAS features run as podman containers on top; the OS
underneath stays immutable.

## Install it

Download the installer ISO from the
[latest release](https://github.com/lukehemmin/LukeNasOS/releases/latest)
(or the [nightly build](https://github.com/lukehemmin/LukeNasOS/releases/tag/nightly)),
write it to a USB stick, and boot. The install is unattended; when it is
done, the console shows the address to open and a one-time setup token —
that token is the only credential a fresh machine has, printed on its own
screen and nowhere else. Sign in with it (browser or ssh), and the setup
wizard walks you from naming the machine to opening your first share.

Prefer kickstart? `installer/luke.ks` works with any Fedora netinst and any
kickstart delivery (a USB stick labelled `OEMDRV` containing it as `ks.cfg`
is the simplest). The disk contract either path applies:

```
ESP 512M (FAT32) · /boot 1G (ext4 — grubenv lives here) · btrfs (root, @data, @seed)
```

`/data` is yours. Everything else belongs to the OS and is disposable —
that is what makes the reset safe.

## The commands that matter

| Command | What it does |
|---|---|
| `luke status` | Verdict first: `● OK`, `▲ RECOVERED` (with cause), or `✕ DEGRADED` |
| `luke update` | Check + stage an update; applies on reboot; `--json` for automation |
| `luke undo` | Previous version on next boot |
| `luke factory-reset` | OS back to install state, `/data` untouched; confirms by hostname |
| `luke doctor` | Active health checks, each failure with the exact fix command |

Exit codes are a contract: `0` ok, `1` error, `2` usage, `77` nothing to
do. Every error carries a stable anchor into
[docs/errors.md](docs/errors.md).

## Build and test it yourself

```bash
make build   # the OS image, from Containerfile
make demo    # full lifecycle in a VM: install → update → break →
             # auto-rollback → factory reset, with a Samba share's file
             # surviving all of it. Same script CI runs.
```

See [BUILD.md](BUILD.md) for details, [ARCHITECTURE.md](ARCHITECTURE.md)
for why it is built this way, and [SPEC.md](SPEC.md) for the normative
contracts.

## If this project disappears

You are never trapped: `sudo bootc switch ghcr.io/ublue-os/ucore:stable`
moves you to the upstream base and keeps your data and containers. The
runbook, including recovery from the on-disk `@seed` archive with no
network at all, is [docs/exit-plan.md](docs/exit-plan.md).

## Status

M1. Everything above is not a roadmap — it is what CI proves on every
change, on a real (virtual) machine: a ten-job pipeline installs the OS,
runs first-boot setup through the browser wizard, stages and applies an
update, breaks one on purpose and watches it roll itself back, factory-
resets while a Samba share's file survives, cuts power twice, and moves
the disk to hardware it has never seen. Real hardware (M2) and the
container app layer (M3) are next. See [TODOS.md](TODOS.md).

## License

MIT (see LICENSE).
