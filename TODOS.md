# TODOS

Deferred scope from the /autoplan review (2026-07-12, branch `260709_test`).
Format: What / Why / Context / Effort (human → CC) / Priority / Depends on.

> **Shipped 2026-07-17** (PR #3, #4), removed from this list: the install-UX repair
> wave (one-disk erase, biosboot, setup token, quiet boot, ISO branding, SPEC sweep,
> BIOS + multi-disk CI), the nftables policy — required by SPEC §9 since the
> beginning and absent for just as long — and the Fedora 44 / greenboot 0.16
> migration with its EOL watch. The lifecycle E2E is green on F44, automatic
> rollback included.

## Next: the first-boot wizard

Design: `~/.gstack/projects/lukehemmin-LukeNasOS/lukehemmin-260709_test-design-20260716-193011.md`
(eng + design reviewed, decisions recorded there). The repair wave was Phase 1 of it;
this is the rest, and it is the first work that puts a screen in front of a user.

- [ ] **`luke setup` verbs** — `account | share | hostname`, `--json` like every other
  verb. The wizard is a Cockpit plugin and calls these via `cockpit.spawn(superuser)`;
  it never runs `useradd`/`smbpasswd`/`nft` itself. One audited privileged surface,
  three front ends (browser, console, ssh). `luke setup share` also opens port 445 and
  creates the Samba credential — the firewall shipped closed on purpose.
  (M → S, P1, blocks: everything below)

- [ ] **First-boot wizard, step 1** — "Name your NAS and your account". No password
  fields: the PAM forced-change at login already set one, and it transfers to the new
  account. Then lock the installer default, render the sign-out interstitial, and only
  then `loginctl terminate-user` — a silent disconnect reads as a crash on the user's
  first action. Resumes at step 2 from a stamp file.
  (L → M, P1, depends: luke setup verbs)

- [ ] **Wizard steps 2–4** — network view (read-only: SPEC §9 keeps NetworkManager but
  the wizard mutating it is not designed yet), first share, and a Done screen that
  coaches the last mile (`\<ip>\<share>`, `smb://<ip>/<share>`, which credentials).
  The arc ends in Finder, not in the browser. (L → M, P2)

- [ ] **Health strip** — the product's thesis as a component: truthful first-boot states
  (`recovery seed: capturing…`, not `factory reset ready`), live poll of
  `luke status --json`, a state table per segment (pending/ok/failed/degraded), stacked
  under 480px, designed in both themes. (M → S, P2)

- [ ] **Post-wizard landing page** — Phase 1 hides stock Cockpit pages (`luke
  unlock-console` is the escape hatch), so without this `:9090` after setup is an empty
  shell. Health strip + share list + `luke status` facts. The seed of the timeline UI.
  (M → S, P2)

- [ ] **Playwright E2E for the wizard** — `cockpit.spawn` runs over websockets, so curl
  cannot exercise a Cockpit plugin. This scaffolding is why the wizard is ~1.5 weeks and
  not a half-day. Runs at a phone viewport and a desktop one, light and dark, and mounts
  the share from a second VM through the firewall. (M → S, P1, with the wizard)

- [ ] **Interactive ISO variant** — `--interactive` drops `user`/`network`/`timezone`/
  `keyboard` from the kickstart so anaconda asks, and must also strip the `chage -d 0`
  line (it hard-fails once `user` is gone) and the banner's token reminder. Second
  artifact: nightly stays the unattended one. (S → S, P3)

## Deferred past M1

- [ ] **mDNS `luke.local` discovery** — so a headless NAS is findable without hunting for
  its IP. Rescheduled by the install-UX design (eng review 2026-07-16): ships in that
  design's Phase 2 together with the nftables policy (a new network service must not
  precede the firewall); Phase 1 findability is the console banner printing the wizard
  URL. (S → S, P2, depends: nftables)

- [ ] **Disk portability test** — pull the boot drive, put it in another machine, confirm
  the NAS identity comes back from `/data`. This is a marketing claim today; it should be a
  test. Needs real hardware (M2). (M → S, P3)

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
