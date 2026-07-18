# The exit plan

A single-maintainer OS that promises safety needs a documented exit. If
this project stops shipping updates — or you simply want out — you do not
lose your machine or your data.

## Rebase to upstream uCore

LukeNasOS is a thin layer over [uBlue uCore](https://github.com/ublue-os/ucore).
One command moves you to the upstream base:

```bash
sudo bootc switch ghcr.io/ublue-os/ucore:stable
sudo systemctl reboot
```

What you keep:

- **`/data`, untouched** — it lives on its own btrfs subvolume that no OS
  deployment owns.
- Your containers and their quadlet units (they are files under `/etc` and
  state under `/var`), including the Samba share.
- SSH access, users, network config.

What you lose:

- The `luke` CLI. Use `bootc upgrade`, `bootc rollback`, and
  `ostree admin` directly — luke was always porcelain over exactly those
  tools.
- The factory-reset mechanism and the recovery banner.
- The LukeNasOS greenboot checks (uCore has its own health-check story).

## Verify before you need it

The E2E suite runs this rebase in CI, and you can rehearse it in a VM:
`scripts/try-lukenasos.sh`, then run the switch inside the VM.

## If even the OS will not boot

The `@seed` subvolume holds an OCI archive of the exact image that was
installed on this machine, captured on first boot. From any live USB with
`skopeo` and `ostree`:

```bash
mount -o subvol=@seed LABEL=lukenasos-root /mnt
skopeo copy oci-archive:/mnt/seed.oci-archive containers-storage:lukenasos:seed
# then reinstall from that local image with scripts/install-disk.sh
```

Your data subvolume (`@data`) is never part of a reinstall's write path.

## Staying alive without the maintainer

CI rebuilds the published image against the upstream base on a weekly
schedule, so security updates keep flowing even during a quiet period. If
the rebuilds stop too, the rebase above is the way out — and it works
offline against the `@seed` archive.
