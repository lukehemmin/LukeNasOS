# TODOS

Started as deferred scope from the /autoplan review (2026-07-12, branch `260709_test`);
it now also carries debts found while building. Format: What / Why / Context /
Effort (human → CC) / Priority / Depends on.

Checked against the tree, not from memory, on 2026-07-17. That check is the point: this
list had been describing `luke unlock-console` and a Cockpit plugin surface as though they
existed, on a machine with no Cockpit in it at all.

> **Shipped 2026-07-17** (PR #3, #4), removed from this list: the install-UX repair
> wave (one-disk erase, biosboot, setup token, quiet boot, ISO branding, SPEC sweep,
> BIOS + multi-disk CI), the nftables policy — required by SPEC §9 since the
> beginning and absent for just as long — and the Fedora 44 / greenboot 0.16
> migration with its EOL watch. The lifecycle E2E is green on F44, automatic
> rollback included.
>
> **Also 2026-07-17**: the `luke setup` verbs and the identity capsule. Same pattern as
> the nftables entry above — SPEC §5.2 had promised since the beginning that users and
> share definitions survive a factory reset, and nothing had ever written them anywhere
> that does.

## Now: debts, in the order they will bite

- [ ] **`luke setup` has never run on a real machine** — shipped 2026-07-17:
  `status | hostname | account | share`, all `--json`, plus the identity capsule and
  `lukenasos-identity.service`. 29 tests pass, and every one of them runs against **stubs**
  — `useradd`, `podman`, `nft`, `systemctl` are all fakes written from reading the docs.
  That proves the logic, not that it works. The `podman run --entrypoint create-hash.sh`
  call in particular was built by reading the script and has never been executed; the stub
  encodes the same understanding, so if that understanding is wrong both agree and the
  suite stays green. The lifecycle E2E does not touch these verbs at all.
  Fix: a lifecycle phase — spend the token, `setup account`, reconnect over ssh as the new
  user (does the credential transfer actually work?), `setup share`, mount it from a second
  VM through the firewall, then factory-reset and check the account and share come back.
  That last step is the capsule's whole reason to exist and only a stub currently says it
  works. (M → S, P1) **← in progress**

- [ ] **The digest pin does not pin anything** — the Containerfile pins the base by
  digest because "an OS that promises safe updates cannot itself update from a mutable
  tag". quay.io/fedora/fedora-bootc deletes a manifest the moment the tag moves off it —
  no time-machine window at all. Measured 2026-07-17: Fedora moved `44` at 11:30:32, our
  digest (green in CI the day before) was unreachable by 11:57, and every build since fails
  with `manifest unknown`. Two consequences, both against the policy's own purpose: the
  build breaks roughly daily while `scheduled-rebuild` proposes bumps **weekly**, and no
  past release can ever be rebuilt from its recorded digest — which is what
  `docs/exit-plan.md` assumes. The fix is to mirror the base into a registry we control
  (GHCR) and pin to the mirror; that is a supply-chain decision for the maintainer, and it
  rides along with the still-pending GHCR publish. Until then, every red `build` job with
  `manifest unknown` is this, not the commit under it. (M → S, P1)

- [ ] **SPEC §9 says ssh refuses passwords; it almost certainly does not** — §9: "password
  authentication over ssh stays refused". But the console banner tells a new owner to
  `ssh luke@<ip>` and type the setup token, which only works if it is allowed. One of the
  two is wrong, and nothing in this repo configures sshd, so the base image decides.
  Evidence so far (2026-07-17), from the base image's own recipe at
  `gitlab.com/fedora/bootc/base-images`: `standard/manifest.yaml` and its includes are
  package lists — there is no `sshd_config` drop-in and no postprocess touching ssh
  anywhere in the tree. So Fedora's `openssh-server` default applies, and that default is
  **yes**. Which would make §9 wrong and the banner right — the same shape as the §9/§10
  corrections in PR #3, where the document described a machine that never existed.
  Not yet confirmed against the built image, only against its recipe. Settle it with
  `podman run --rm --entrypoint sh <base> -c 'sshd -T | grep -i passwordauth'` (the dev
  LXC has no podman), then fix whichever side is lying — and if it is §9, decide
  deliberately whether we *want* password auth on, rather than inheriting it. (S → S, P1)

## Next: the first-boot wizard

Design: `~/.gstack/projects/lukehemmin-LukeNasOS/lukehemmin-260709_test-design-20260716-193011.md`
(eng + design reviewed, decisions recorded there). The repair wave was Phase 1 of it;
this is the rest, and it is the first work that puts a screen in front of a user.
`luke setup` gave it a privileged API to call. It still has nowhere to run:

- [ ] **Cockpit is not installed** — nothing in `Containerfile`, `config/`, or the
  kickstart mentions it. Every item below is a Cockpit plugin, so this blocks all of them,
  and it was missing from this list entirely while the list described the plugins in
  detail. Meanwhile the firewall already opens 9090 "for the setup wizard and dashboard"
  and `luke/banner` already tests for `cockpit.socket` before printing the URL — both
  written to be true the day this lands, and both currently describing a port and a unit
  that do not exist. Includes: the packages, `cockpit.socket` enabled, the TLS story for a
  device with no domain (the banner already promises users the browser warning is
  expected), and decision 5.3A — hiding the stock pages, since cockpit-storaged can
  repartition the contract disk and the systemd page can disable greenboot, i.e. one click
  can void the guarantee SPEC §6 exists to protect. (M → S, P1, blocks: everything below)

- [ ] **`luke unlock-console`** — decision 5.3A's escape hatch: an explicit, event-logged
  verb that reveals full Cockpit for advanced users. Does not exist; this list referred to
  it as though it did. Only meaningful once the stock pages are actually hidden, so it
  ships with the item above. (S → S, P2, depends: Cockpit)

- [ ] **First-boot wizard, step 1** — "Name your NAS and your account". No password
  fields: the PAM forced-change at login already set one, and `luke setup account` now
  transfers it. Then render the sign-out interstitial and only then `loginctl
  terminate-user` — a silent disconnect reads as a crash on the user's first action.
  (The verb retires `luke` itself; the wizard must not, and must not assume locking ends
  the session — it does not.) Resumes at step 2 from a stamp file: `luke setup status`
  derives what is *done*, but not where the user was.
  (L → M, P1, depends: luke setup verbs ✅)

- [ ] **Wizard steps 2–4** — network view (read-only: SPEC §9 keeps NetworkManager but
  the wizard mutating it is not designed yet), first share, and a Done screen that
  coaches the last mile (`\<ip>\<share>`, `smb://<ip>/<share>`, which credentials).
  The arc ends in Finder, not in the browser.
  Step 3 gained a password field the design did not have — "confirm your password to turn
  on file sharing" — because SMB stores NT hashes and nothing can derive one from the Unix
  password (decided with the maintainer, 2026-07-17). It needs a show-password toggle: the
  verb cannot check the password against the Unix one (no crypt(3) from shell on F44 —
  Python dropped the module), so a typo there silently means a share that rejects the
  password the Done screen tells them to use. Step 3 also pulls the Samba image on a fresh
  machine, so its loading state is minutes, not a spinner. (L → M, P2)

- [ ] **Health strip** — the product's thesis as a component: truthful first-boot states
  (`recovery seed: capturing…`, not `factory reset ready`), live poll of
  `luke status --json`, a state table per segment (pending/ok/failed/degraded), stacked
  under 480px, designed in both themes. (M → S, P2)

- [ ] **Post-wizard landing page** — Phase 1 hides the stock Cockpit pages, so without
  this `:9090` after setup is an empty shell. Health strip + share list + `luke status`
  facts. The seed of the timeline UI. (M → S, P2, depends: Cockpit)

- [ ] **Playwright E2E for the wizard** — `cockpit.spawn` runs over websockets, so curl
  cannot exercise a Cockpit plugin. This scaffolding is why the wizard is ~1.5 weeks and
  not a half-day. Runs at a phone viewport and a desktop one, light and dark. Covers the
  browser half only: the machine half (does the account transfer work, does the share
  mount, does it all survive a factory reset) belongs to the lifecycle phase in the first
  debt above, which does not need a browser and should not wait for one.
  (M → S, P1, with the wizard)

- [ ] **Interactive ISO variant** — `--interactive` drops `user`/`network`/`timezone`/
  `keyboard` from the kickstart so anaconda asks, and must also strip the `chage -d 0`
  line (it hard-fails once `user` is gone) and the banner's token reminder. Second
  artifact: nightly stays the unattended one. (S → S, P3)

## Deferred past M1

- [ ] **mDNS `luke.local` discovery** — so a headless NAS is findable without hunting for
  its IP. Rescheduled by the install-UX design (eng review 2026-07-16): a new network
  service must not precede the firewall, and now it does not — **the nftables dependency is
  met** (shipped 2026-07-17), so this is unblocked and needs its own port opened
  deliberately (5353/udp) rather than by habit. Phase 1 findability is the console banner
  printing the wizard URL. (S → S, P2)

- [ ] **Disk portability test** — pull the boot drive, put it in another machine, confirm
  the NAS identity comes back from `/data`. No longer only a marketing claim: as of
  2026-07-17 there is a mechanism, and `lukenasos-identity.service` restores the account,
  uid, hostname and shares from the capsule on every boot precisely so a moved disk works.
  So this stopped being "write a test for a claim" and became "test the code that makes the
  claim true" — and QEMU can do most of it (boot the installed disk on a VM with different
  virtual hardware) without waiting for M2 hardware. (M → S, P2)

- [ ] **Timeline / undo web UI** — the heart of the product vision. The M1 event model is
  its foundation. Stack DECIDED (eng review 2026-07-16, install-UX design): Cockpit
  plugin, with `luke` verbs (`--json`) as the only privileged API. The first-boot wizard
  from that design is the first slice; this item is the dashboard it grows into. Run
  `/design-consultation` for the visual system before the dashboard slice. (L → M, P2,
  depends: first-boot wizard, event model)

- [ ] **Visual system (DESIGN.md) for the web surface** — run `/design-consultation` to
  produce DESIGN.md (palette, typography, spacing, motion) before the dashboard slice.
  Design review 2026-07-16 deliberately capped Phase 1 at stock PatternFly + wordmark +
  the health strip as the only custom component, because there was no system to build
  against and hand-rolled CSS fights Cockpit's theming (and breaks dark mode). The
  dashboard is the product's face; it should not ship as "another Cockpit page". Do this
  when there are real screens to design against, not before. (M → S, P2, depends:
  first-boot wizard)

- [ ] **Data-plane undo** — `@data` snapshot timeline, btrfs scrub timer, send/receive
  backups. This extends "undo" from the OS to the whole NAS, which is what users actually
  fear losing. (L → M, P2)

- [ ] **Appliance layer as a platform** — the btrfs contract plus the `luke` CLI,
  generalized so other self-hosted appliances could reuse it. Recorded, not planned. (XL →
  L, P3)

- [ ] **Multi-disk topologies** — btrfs RAID1, and the separate boot-disk + data-pool
  layout that most DIY NAS builds actually use. M1 assumes a single disk; the contract
  reserves room for this. (L → M, P2)

- [ ] **ISO volume-label rebrand** — the installer ISO keeps Fedora's volume label; only
  menuentry text is branded. Deliberately deferred (eng review 2026-07-16): the label is
  load-bearing in `build-iso.sh` — read via `blkid`, referenced by `inst.stage2=`/
  `inst.ks=` cmdlines in three grub.cfg copies including the mtools-edited efiboot.img —
  so renaming means changing the remaster pipeline contract everywhere at once, for a
  string users never see. Do it only as part of a deliberate pipeline change, never as a
  drive-by. (S → S, P3)

- [ ] **Web-based installer ("the installer IS the NAS")** — the ISO boots a small web
  server; the user drives disk/account/network from a phone/laptop browser and the page
  runs the install. Parked as an ocean by the install-UX design (office-hours Approach C,
  2026-07-16): bypassing anaconda makes partitioning/SELinux/bootloader our
  responsibility, and Anaconda's own remote WebUI may cover this. Re-evaluate at Fedora
  45 GA — the same trigger as the design's Cockpit-bet exit criteria (design doc OQ6).
  (XL → L, P3, depends: Anaconda remote WebUI maturity)

- [ ] **Raspberry Pi spike** — time-boxed to two weekends. RPi4 has community bootc
  precedent (bootupd needs patching for the Pi firmware layout); the Pi 5 is not officially
  supported by Fedora. If the spike fails, ship generic ARM64 (UEFI/QEMU virt) only. Never
  blocks the x86_64 milestones. (M → S, P3)
