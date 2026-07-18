# LukeNasOS Technical Specification

> **Revised 2026-07-12.** Earlier revisions specified a hand-rolled ostree pipeline, a
> `@restore` subvolume holding a bootable OS copy, a two-partition layout, systemd-boot,
> and kernel options that do not exist (`CONFIG_OSTREE`). None of that survives contact
> with how bootc/ostree actually works. This is the normative contract; `ARCHITECTURE.md`
> explains why.
>
> **Amended 2026-07-17** (install-UX repair wave). Several lines here described a machine
> that never existed, which is worse than saying nothing: the network stack (§9) was
> NetworkManager all along, `sshd` (§9) always shipped enabled, `nftables` (§9) was
> required-but-absent, the subvolume and `@seed` paths (§2.2, §2.4) were not what the
> installer creates, and §10 claimed there was no default password while the installer
> shipped a well-known one. Each was checked against the image and the installer, then
> written down as it is. Added in the same pass: the BIOS boot partition (§2.1), the
> one-disk erase rule (§2.1), the quiet cmdline (§3), the wizard as a second sanctioned
> surface (§6), the SETUP block (§7), the setup token (§10), and BIOS as a tested target
> (§11).

## 1. System Overview

| Field | Value |
|-------|-------|
| Name | LukeNasOS |
| Kind | Bootable OCI container image (bootc) |
| Base | Fedora bootc / uCore (pinned digest) |
| Init | systemd |
| Update model | bootc — signed OCI image pull, staged deployment, atomic switch |
| Rollback | greenboot (health-check driven, automatic) + `bootc rollback` |
| Factory reset | pinned ostree deployment + signed OCI seed archive |
| Bootloader | GRUB (required by greenboot's `boot_counter`) |
| Filesystem | btrfs (root), ext4 (`/boot`), FAT32 (ESP) |
| Architecture | x86_64 (primary), ARM64 generic, Raspberry Pi 4/5 (separate targets) |
| SELinux | targeted policy, **enforcing from M1** |
| Secure Boot | Fedora signing chain |

## 2. Disk Contract

### 2.1 Partitions (GPT)

```
Partition 0: BIOS boot            ← BIOS+GPT only; unused (and harmless) on UEFI
  Type: 21686148-6449-6E6F-744E-656564454649
  FS:   none
  Size: 1 MiB
  Mount: —

Partition 1: EFI System Partition
  Type: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  FS:   FAT32
  Size: 512 MB
  Mount: /boot/efi

Partition 2: Boot
  Type: Linux filesystem
  FS:   ext4                     ← REQUIRED: GRUB cannot write grubenv on btrfs
  Size: 1 GB
  Mount: /boot
  Contents: kernels, initramfs, BLS entries, grubenv (boot_counter)

Partition 3: Root
  Type: Linux filesystem
  FS:   btrfs
  Size: remainder
  Mount: /sysroot
  Options: compress=zstd:1,noatime
```

**Normative:** `grubenv` MUST live on partition 2. greenboot's automatic rollback depends
on GRUB decrementing `boot_counter` there; on btrfs that write fails silently and
automatic rollback does not happen. This is the single most important line in this
document.

**Normative:** the BIOS boot partition is not optional on a GPT disk, even though nothing
mounts it. Without it, a BIOS machine stalls forever at "Installation Destination
(Kickstart insufficient)" and the unattended install silently becomes an interactive one
with nobody watching (observed on a real boot, 2026-07-16). It costs 1 MiB on UEFI
machines, which is the cheapest insurance in this document.

**Normative:** exactly one disk is erased — the one `%pre` selects (single disk auto,
otherwise a console menu with a typed confirmation, or `inst.luke.disk=`). `clearpart
--all` without `ignoredisk --only-use` means every attached disk, which on the multi-disk
machines this product is for is data loss, not a UX defect.

### 2.2 Subvolumes

```
btrfs subvolume create root       → /sysroot           (holds /ostree: repo, deployments, stateroot var)
btrfs subvolume create @data      → /var/mnt/data      (user data; /data is a symlink)
btrfs subvolume create @seed      → /var/mnt/seed      (OCI archive, not a bootable copy)
```

`/var` is ostree's stateroot var under `/ostree/deploy/<stateroot>/var`. Mounting a
dedicated subvolume over it is an open spike, not an assumption — the default is to use
ostree's own var rather than fight it. Image `/var` content is seeded once on first
deployment via `tmpfiles.d` and is **not** refreshed by later updates; anything that must
survive an update belongs in the image or on `@data`.

### 2.3 Space protection (normative)

| Control | Value |
|---------|-------|
| `@data` qgroup limit | pool size − OS reserve (15–20 GB) |
| Unallocated warning | `btrfs fi usage` unallocated < 2 GiB → `DEGRADED` |
| Balance timer | periodic `balance -dusage=10` |
| `luke update` pre-flight | reads `btrfs fi usage` (never `statvfs`) |

qgroups cap data usage but do not prevent metadata exhaustion, which forces the
filesystem read-only. The controls above are layered for that reason.

### 2.4 Mounts

| Path | Source | Options |
|------|--------|---------|
| `/sysroot` | `root` | `subvol=root,compress=zstd:1,noatime` |
| `/boot` | partition 2 | `defaults` |
| `/boot/efi` | ESP | `fmask=0077,dmask=0077` |
| `/var/mnt/data` | `@data` | `subvol=@data,compress=zstd:1,noatime` |
| `/data` | symlink → `/var/mnt/data` | baked into the image |

## 3. Kernel

The kernel is Fedora's. We do not build one. The features we need are already enabled
there: btrfs, EFI stub, efivarfs, virtio, NVMe, SELinux, module signing.

There is **no `CONFIG_OSTREE`** — ostree is userspace. Earlier revisions listed it; it
does not exist.

### Default kernel cmdline

```
ostree=...                       (managed by ostree; never hand-edited)
root=UUID=<btrfs-part-uuid>
rootflags=subvol=root
console=tty0
console=ttyS0,115200n8
selinux=1 enforcing=1
quiet loglevel=4                 (the banner is the home screen, not dmesg)
```

No plymouth splash: it would fight the serial console above and the boot banner (§7),
which is the screen this appliance actually has.

## 4. Update Contract

### 4.1 Source

```
Registry:  ghcr.io/lukehemmin/lukenasos
Channels:  :stable  :beta  :dev        (tags)
Transport: bootc pull (OCI)
```

The signature verification policy is baked into the image at `/etc/containers/policy.json`
and pinned to the release workflow identity. An image that fails verification is rejected
before any state changes.

### 4.2 State machine

```
                 ┌──────────┐
                 │  BOOTED  │◄──────────────────────────┐
                 └────┬─────┘                           │
        luke update   │                                 │ greenboot red:
                      ▼                                 │ GRUB boots previous,
                 ┌──────────┐                           │ failed digest blocked
                 │  STAGED  │  (nothing rebooted yet)   │
                 └────┬─────┘                           │
        reboot        │                                 │
                      ▼                                 │
                 ┌───────────┐  greenboot green   ┌─────┴────────┐
                 │ ACTIVATED ├───────────────────►│  RECOVERED   │
                 └───────────┘                    │  (or BOOTED) │
                                                  └──────────────┘
```

An unclean shutdown while STAGED loses the staged deployment: ostree finalizes it on
clean shutdown only. `luke status` MUST detect and report this. It is not a silent no-op.

### 4.3 Rules (normative)

- An update MUST verify a rollback target exists and is pinned **before** staging. No
  target, no update.
- No automatic reboot. Ever. The default is to wait.
- A version that triggered an automatic rollback is blocked by **digest** (not tag) and
  is not retried without `--force`.
- `luke undo` MUST refuse to re-activate a blocked digest (undo-of-undo would restore the
  broken version you just escaped).

## 5. Factory Reset (`luke factory-reset`)

### 5.1 Mechanism

```
Install time:  ostree admin pin <install deployment>   # survives GC forever, boots from GRUB
               write signed OCI archive → @seed

Promotion:     a deployment may become the new pinned target after it passes health
               checks and soaks. Both the install seed and the last-known-good seed
               are retained.

Reset:         1. verify the pinned commit (or @seed archive if the repo is damaged)
               2. discard any staged deployment
               3. redeploy the pinned commit
               4. reset /etc from image defaults (no 3-way merge)
               5. clear OS state (user's choice)
               6. NEVER touch @data
               7. reboot
```

The reset is performed against a new deployment and only becomes the default once
complete, so power loss mid-reset leaves the system bootable.

### 5.2 What survives (normative)

| Survives | Cleared |
|----------|---------|
| `/data` — all user files | OS configuration (`/etc`) |
| `/data/.lukenasos/` — identity capsule: users, UID/GID, share definitions, SSH host keys, machine-id | installed apps' OS-level state |
| container volumes (they live on `@data`) | logs, caches |

"Data preserved" that leaves the shares inaccessible is a broken promise. The identity
capsule is what makes the preserved bytes usable after a reset.

**How (normative).** The two columns above only both hold if something writes the left one
back into the cleared right one. That something is `lukenasos-identity.service`, and the
capsule is its input:

| `/data/.lukenasos/` | holds |
|---|---|
| `accounts/<name>.json` | name, **uid/gid**, password hash, shell, groups, authorized_keys, Samba hash |
| `shares/<name>.json` | share name, path, who may open it |
| `hostname` | what this NAS is called |
| `ssh_host_*_key*` | the machine's ssh identity |
| `samba.env` | generated from the two above; the Samba container's `EnvironmentFile` |

`luke setup` writes the capsule **before** it touches `/etc`, never the other way round: a
change applied but not recorded is one the next factory reset silently forgets. The unit
converges on every boot rather than detecting resets, because "the `/etc` under me is not
the one I configured" also happens when the boot disk is moved to another machine.

The uid is restored, not reassigned. Every file on `/data` is owned by a number, and an
account recreated with a different one is a stranger to its own files — the reset would
preserve the bytes and hand them to nobody, which is this section's failure mode wearing a
different hat. Retiring the installer's `luke` account is re-asserted on every boot for the
same reason: a fresh `/etc` brings it back unlocked, holding the setup token's password.

The ssh host keys are restored for a reason worth stating plainly: without it, a reset
makes every client that ever trusted this machine print `REMOTE HOST IDENTIFICATION HAS
CHANGED — someone could be eavesdropping on you right now`. A recovery feature that makes
the recovered machine look like an attacker is not a recovery feature. This was a real gap
until 2026-07-17: `luke factory-reset` had copied the keys into the capsule from the
beginning, and nothing had ever copied them back.

### 5.3 Confirmation

Before any destructive action the user sees what survives and what does not, with real
numbers, and confirms by **typing the hostname** (not `y/n`). Scripts use `--yes`. After
the reset, the first boot banner reports that the data survived, with its size.

## 6. `luke` CLI

`luke` is the only *command* a user types, and the only thing that changes system state.
The setup wizard and dashboard (a Cockpit plugin) are a second sanctioned surface, with a
rule: they render `luke` output and call `luke` verbs, never `useradd`/`smbpasswd`/`nft`
directly. One audited privileged surface, three front ends (browser, console, ssh).
Cockpit's own storage/systemd/terminal pages are hidden in product mode — one click there
can repartition the contract disk or disable greenboot, which is exactly the guarantee
this document exists to protect — and `luke unlock-console` reveals them deliberately,
with an event logged.

`luke` never makes the user type `bootc` or `ostree`,
but it does not hide them either — it reconciles against their real state on every run.
bootc/ostree are the source of truth; `luke`'s own state file is a cache and an
annotation.

| Verb | Meaning |
|------|---------|
| `luke status` | current state; `--events` for history; `--json` for machines |
| `luke update` | check, verify, stage. `--reboot` to activate. `--check` to look only |
| `luke undo` | the one user-facing "take it back" — reverts the last change |
| `luke rollback` | alias for `luke undo --os` |
| `luke factory-reset` | reset the OS, keep the data. Long name on purpose |
| `luke doctor` | active checks → a verdict and the exact command that fixes it |

### 6.1 Output contract (normative)

- **Exit codes:** `0` success, `1` warning, `2` error, `77` nothing to do (already up to
  date). Automation must be able to tell "updated" from "already current".
- **`--json`** on every verb: `{ok, code, message, safe_state, fix, events, logs}`.
- **Every error states four things:** what failed, the likely cause, a copy-pasteable
  next command, and a stable doc anchor (`docs/errors.md#LUKE-Exxx`). Users photograph the
  screen and search that code.
- **Never color alone:** `● OK` / `▲ RECOVERED` / `✕ DEGRADED` — symbol plus color, for
  serial consoles and color-blind users.
- Progress is text, never a spinner (serial-console and log safe), and is suppressed when
  stdout is not a TTY.
- English is the language of the CLI, the README, and all error messages.

### 6.2 Long operations

`luke update` runs as a systemd unit and the CLI attaches to it, so closing SSH does not
kill the update. A second `luke update` attaches to the running one instead of erroring.

## 7. Boot Banner

The banner is the appliance's only home screen. Its hierarchy is fixed:

```
1. VERDICT     ● OK   ▲ RECOVERED   ✕ DEGRADED
2. LAST EVENT  (when RECOVERED) what happened, why, when
3. SETUP       (until setup is done) the setup token, and where to finish
4. VERSION     booted version; staged version if one is waiting
5. NEXT        luke status · luke doctor
```

What a user must learn in half a second is whether they are fine — not which version they
are running. The verdict stays first even on the very first boot, when the setup block is
the thing they came to read: a DEGRADED first boot must not hide behind setup excitement.

The SETUP block exists only while setup is unfinished — the token file is present and the
administrator's password is still expired — and never claims more than is true:

- **No wizard installed yet:** point at this console and `ssh`. Never print a URL to a
  port nothing listens on.
- **No address yet:** say so ("check the cable"), and mean the promise that the screen
  updates itself — a NetworkManager dispatcher hook re-renders the banner when the
  address arrives.
- **Several addresses:** offer all of them. A NAS with two NICs is normal, and guessing
  sends the user to one their laptop may not reach.
- **TLS:** the self-signed certificate warning is part of first contact, and the first
  contact is usually a phone, where the bypass hides behind a full-screen interstitial.
  Name the gesture ("choose Advanced, then Proceed"), not just the fact.

## 8. Health Checks and Rollback

- greenboot runs the checks; `bootc rollback` performs the revert.
- GRUB's one-shot fallback (boot_counter exhausted) MUST be made permanent by the red
  script, or the next boot returns to the broken deployment.
- A flapping check (fails once, passes the next time) MUST NOT trigger a rollback loop.
- Health-check timeouts MUST allow for spinning disks. An HDD spin-up delay must never be
  mistaken for a failed update.
- Automatic rollback can be turned off (`luke config auto-rollback off`) for people who
  are deliberately experimenting. When it is off, the banner says so, permanently.

## 9. Networking

**NetworkManager**, DHCP by default. It is what the bootc base ships and enables, and
what anaconda writes connection profiles for; the earlier `systemd-networkd` line in this
spec described a machine that never existed. Amended 2026-07-17 after checking the image
rather than the document.

`sshd` is **enabled by default, deliberately**. This is a headless appliance: when the
browser cannot help you, ssh is the recovery path, and the lifecycle test drives the
machine the same way.

Password authentication over ssh is **on, deliberately**. Amended 2026-07-18: the
earlier "stays refused" line contradicted §10 and the console banner, which tell a new
owner to `ssh luke@<ip>` and type the setup token — first login *is* password auth, and
nothing in the image had ever configured sshd to refuse it; the document described a
machine that never existed, the same shape as the NetworkManager correction above. What
defends port 22 is what defends the token: the firewall keeps it LAN-local, no shipped
password exists (§10), and the token is force-changed at first use. Root login is
refused outright — stricter than the inherited `prohibit-password`, which would still
have let root in with a key; the administrator is a normal `wheel` account. Both lines
live in `/etc/ssh/sshd_config.d/40-lukenasos.conf` rather than being inherited from the
base image: an appliance's front-door policy should be its own decision, written where a
reader can find it. The lifecycle asserts both against the running machine.

`nftables` (normative, and now real): the policy in `/usr/share/lukenasos/lukenasos.nft`
is loaded by `nftables.service` on every boot. Default drop inbound; open ports are named
one at a time with the reason:

| Port | Why |
|------|-----|
| 22 | ssh — the recovery path above |
| 9090 | the setup wizard / dashboard |

SMB (445/139) is **not** open by installing the OS. `luke setup share` opens it when the
first share is created and closes it with the last: a file-sharing port that exists
because the OS booted, rather than because a share does, is a port nobody asked for.

Mechanically, the rule is a file — `luke setup share` writes
`/etc/lukenasos/nftables.d/10-shares.nft` and `nftables.conf` globs that directory in, so
the open port is part of the policy that gets loaded rather than a live rule sitting
outside it. `lukenasos-identity.service` rewrites the file from the capsule, which is what
reopens SMB after a factory reset clears `/etc`.

## 10. Users

First boot creates the administrator (`luke`, in `wheel`). There is no shipped default
password and no well-known one: a password every install shares is not a secret, and it
makes ownership a race — the first stranger on the LAN to reach the setup page wins.

Instead the installer generates a **per-install setup token**, sets it as the
administrator's password, and expires it (`chage -d 0`) so the first login must replace
it. The token is printed **only on the console banner**, which makes console or physical
access the proof of ownership.

The token's format is a usability decision as much as a security one: it is read off a
screen across a room and typed into a phone. Crockford-style base32 minus `0` and `1`
(no character can be confused with another), 12 characters grouped `xxxx-xxxx-xxxx`,
~59 bits — ample for a LAN-local secret that is force-changed at first login.

The banner stops printing the token, and the machine deletes it, the moment the forced
change happens. Automated installs override the account with their own `--kickstart`,
as before. An appliance you cannot log into is not an appliance; an appliance anyone can
log into is not yours.

`luke` is the installer's account, not the user's. `luke setup account --name <you>`
creates the real administrator and **carries the password over** — the one already chosen
at the forced change, copied as a hash — so nobody types a third password on a phone. It
is refused while the token is unspent (normative): the hash on disk would still be the
token, and an administrator whose password was printed on a screen is not an
administrator. Only once the new account is proven to have a usable password is `luke`
locked and expired — never deleted, because its uid appears in the machine's own history,
and a machine with no way in is worse than one with a locked door.

Samba is the exception to "one password", and unavoidably so: SMB stores NT hashes, and
no NT hash can be derived from a Unix one. `luke setup share` therefore asks for the same
password once more (`--password-stdin` only — a flag would land in shell history, `ps`,
and the journal) and stores the **hash** the Samba container computes, never the plaintext
of an account that also opens ssh and Cockpit. The image itself defines no Samba account;
`verify-static` fails if one appears.

## 11. Build and Distribution

| Artifact | Target | Gate |
|----------|--------|------|
| `lukenasos-x86_64.iso` / `.qcow2` | x86_64 UEFI | **primary — gates all milestones** |
| the same ISO, on x86_64 BIOS/CSM | x86_64 BIOS | install check (the biosboot partition, §2.1) |
| `lukenasos-arm64-generic.raw` | ARM64 UEFI / QEMU virt | boot check |
| `lukenasos-rpi4.raw`, `lukenasos-rpi5.raw` | Raspberry Pi | spike; never blocks the primary |

Images ship on GitHub Releases; OS images ship on GHCR. CI is a GitHub Actions matrix
(build → sign → QEMU smoke test → publish), plus a scheduled rebuild against the upstream
base so the image does not rot if the maintainer goes quiet.

## 12. Branding

```ini
NAME="LukeNasOS"
ID=lukenasos
PRETTY_NAME="LukeNasOS"
VARIANT="NAS"
VARIANT_ID=nas
```

Default hostname: `luke`.
