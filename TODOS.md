# TODOS

Started as deferred scope from the /autoplan review (2026-07-12, branch `260709_test`);
it now also carries debts found while building. Format: What / Why / Context /
Effort (human → CC) / Priority / Depends on.

Checked against the tree, not from memory, on 2026-07-17; re-reconciled 2026-07-18 after
the Cockpit/wizard wave shipped. That check is the point: this list had been describing
`luke unlock-console` and a Cockpit plugin surface as though they existed, on a machine
with no Cockpit in it at all — both are real now, and the entries moved to the shipped
notes the day they were proven, not the day they were written.

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
>
> **2026-07-17, proven on a real machine**: the "`luke setup` has never run on a real
> machine" debt is paid. Lifecycle phases 1c and 5 (CI run 29584444236, all green) now
> spend the token, create the account, reconnect over ssh as the new user, verify the
> transferred hash byte-for-byte, create a share, mount it from off-machine through the
> firewall, factory-reset, and check that the account (same uid), hostname, ssh host
> keys, and share all come back from the capsule. Getting there surfaced three real bugs
> the stubs had agreed with: every share answered ACCESS_DENIED (0770 root:root parent),
> `create-hash.sh` output parsing, and ssh host keys were captured but never restored.
>
> **Shipped 2026-07-18**, removed from this list:
> - **The §9 ssh contradiction, settled**: the banner was right and §9 was wrong — first
>   login IS password auth. The image now declares it deliberately
>   (`sshd_config.d/40-lukenasos.conf`: `PasswordAuthentication yes`,
>   `PermitRootLogin no` — stricter than the inherited default, which admitted root with
>   a key). Proven by sshpass with pubkey forbidden, in phase 1c and again after the
>   reset.
> - **Cockpit installed** (ws/bridge/system, socket enabled, greenboot-required), every
>   stock page shipped hidden (decision 5.3A), `luke unlock-console` as the event-logged
>   escape hatch, and the login page told what to type via the Banner hook — with the
>   text rewritten by `setup account` and identity-apply the moment "sign in as luke"
>   stops being true.
> - **The wizard, steps 1–4** (`web/lukenasos-setup`): account (no password fields,
>   interstitial before terminate-user), read-only network, first share (the one extra
>   password, with its reason on screen), and the last-mile Done screen. Plus the health
>   strip — which deliberately has NO "recovery seed" segment, because no seed mechanism
>   exists yet and a UI state for it would be the spec's favorite bug as an API. New
>   `luke setup stamp` records where the user was; a reset clears it.
> - **Factory reset never actually cleared /etc** — the third
>   normative-but-unimplemented find: SPEC §5 said "no 3-way merge" and the deploy did
>   one anyway, so accounts, lock states, and even deletions rode across every reset
>   (and flattered some phase-5 assertions). Fixed as a trilogy, each caught by the
>   machine or the source: `--no-merge`; `--karg-proc-cmdline` beside it (alone it
>   ships no root= — a reset that bricks the boot, read from the ostree source before
>   any machine ran it, confirmed by the control run's 20-minute silence); and fstab
>   carried across like the kargs (the image has none — anaconda wrote it — and without
>   it /boot never mounts, bootc errors, and the banner dies of pipefail), via an
>   ostree-style rw-remount of the read-only /sysroot.

## Now: debts, in the order they will bite

- [x] **The digest pin does not pin anything — shipped 2026-07-18** (maintainer
  approved the supply-chain decision): `mirror-base.yml` copies
  quay.io/fedora/fedora-bootc into `ghcr.io/lukehemmin/fedora-bootc-mirror`
  digest-preservingly (`--all --preserve-digests` — the mirrored digest is
  byte-identical to upstream's, verified fetchable by digest and anonymously
  pullable), gives every mirrored digest a dated tag so it can never be
  garbage-collected out from under the pin, and runs weekly an hour before
  scheduled-rebuild. The Containerfile pins the mirror now: the pin is a
  guarantee, the build stops breaking on quay's tag moves, and past releases
  become rebuildable — which is what docs/exit-plan.md always assumed. (M → S, P1)

## Next: the first-boot wizard

Design: `~/.gstack/projects/lukehemmin-LukeNasOS/lukehemmin-260709_test-design-20260716-193011.md`
(eng + design reviewed, decisions recorded there). As of 2026-07-18 the wizard EXISTS —
steps 1–4 and the health strip shipped (see the note above) — and what remains is the
browser-side proof and the polish around it:

- [x] **Playwright E2E for the wizard — shipped 2026-07-18** (wizard-browser CI job,
  green in run 29643582156): a real Chromium drives the owner's literal path on a fresh
  VM — token login off the machine, step 1, the interstitial before terminate-user, the
  re-login page whose hint stopped saying "token", escalation as a returning admin,
  steps 2–4 with the real share creation, and the landing page. Its four debug cycles
  each caught a real bug, two of them user-facing product bugs the no-browser serving
  check could never see: the sign-out overlay covering the page from first paint
  (author display defeating [hidden]) and the superuser flow freezing on the loading
  screen. Screenshots at every step ride as artifacts. Remaining polish, deliberately
  deferred: phone viewport + dark-mode projects (the flow mutates the machine, so extra
  projects need read-only scope), and driving the shell's own escalation dialog for the
  true first-visit path. (M → S, P1)
  Update 2026-07-19: a second suite (`undo.spec.js`) now drives the armed hold-to-run
  undo too (PR #8) — see the Timeline / undo item below. Phone/dark projects still
  deferred.

- [x] **Post-wizard landing page — shipped 2026-07-18**: the completed view renders
  what the design specified for the minimal landing — health strip, machine facts
  (name, administrator, booted version), and every share with the smb:// address that
  opens it. The M3 dashboard grows from here (see Timeline / undo web UI below). (M → S, P2)

- [ ] **Publish a try-qcow2 with releases** — `scripts/try-lukenasos.sh` and the README's
  15-minute pitch assume a downloadable N-1 qcow2 release asset; release.yml publishes
  only the ISO, so the script correctly reports "no qcow2 asset" today. Shipping it has
  a real design question inside: a downloadable image is the SAME image for everyone,
  and SPEC §10 exists precisely to forbid a credential every install shares — so the
  try image needs its own story (first-boot token generation on the try image's first
  boot, or an explicitly-labeled insecure demo mode). Decide, then add the asset to
  release.yml (an install run in CI produces the qcow2). (M → S, P3)

- [ ] **Interactive ISO variant** — `--interactive` drops `user`/`network`/`timezone`/
  `keyboard` from the kickstart so anaconda asks, and must also strip the `chage -d 0`
  line (it hard-fails once `user` is gone) and the banner's token reminder. Second
  artifact: nightly stays the unattended one. (S → S, P3)

## Deferred past M1

- [x] **mDNS `luke.local` discovery — shipped 2026-07-18** (lifecycle green in run
  29643237656): avahi answers `<hostname>.local`, 5353/udp opened by name in the policy
  with its reason (SPEC §9 table), deliberately after the firewall it was required to
  follow. The lifecycle asserts what a user-net guest can honestly assert — responder
  active, port open in the LOADED ruleset; real .local resolution from a second device
  is an M2 hardware-bench check, said so rather than faked. (S → S, P2)

- [x] **Disk portability test — shipped 2026-07-18** as lifecycle phase 7 (green, run
  29642071363): the same disk that lived through install/setup/update/rollback/reset/
  power-cuts boots on hardware it has never seen (i440fx + e1000 instead of q35 + virtio
  — new NIC name, fresh DHCP lease, no NetworkManager profile in the post-reset /etc)
  and is still the same NAS: name, administrator with the same uid, data, and the share
  served through the firewall. The disk bus stays virtio on purpose — swapping it would
  test the initramfs's driver inventory, which is Fedora's promise, not ours. What
  remains for M2 is only the literal-hardware version of the same move. (M → S, P2)

- [~] **Timeline / undo web UI** — the heart of the product vision. Stack DECIDED (eng
  review 2026-07-16, install-UX design): Cockpit plugin, with `luke` verbs (`--json`) as
  the only privileged API. **First slices shipped 2026-07-19**:
  - **The landing IS the timeline** (PR #7): `luke status --events --json` serves the
    journal (events array, cap 200); the verdict renders as a Fraunces sentence, entries
    as plain-language sentences (unknown types verbatim), hold-to-run undo with honest
    disabled states, and the `/etc/lukenasos/theme.css` loader rider.
  - **The armed undo, browser-proven** (PR #8): the wizard-browser job now stages+applies
    an update so v1 becomes a rollback target, a real finger holds the undo control, and
    the harness reboots to prove the box booted v1 — the button moves the OS, not just its
    label. Caught a real test bug (the control sits below the fold; hand-rolled page.mouse
    missed it — fixed with Playwright's click({delay})) and a product bug (undo re-armed
    itself after success, inviting the double-undo the verb warns against).
  Remaining for a fuller dashboard: browser undo also exercised against a broken-update
  auto-rollback (RECOVERED verdict on screen), storage/capacity panel, per-event detail
  views, live refresh without a reload. (L → M, P2, depends: first-boot wizard ✓, event
  model ✓, DESIGN.md ✓)

- [x] **Visual system (DESIGN.md) — shipped 2026-07-19** (PR #6, branch
  `m2-design-system`): /design-consultation produced DESIGN.md with two layers held in
  different grips — the bones (verdict-first sentences, status color owned by the health
  surface, timeline over dashboard, hold-to-run undo, calm motion) settled and
  theme-independent; the skin a user-themable `--ln-*` token contract with "Ranger
  Station" (warm paper, spruce, Fraunces / Atkinson Hyperlegible Next / Commit Mono,
  bundled woff2, no runtime CDN) as only the shipped default theme. The wizard wears it
  already, and the wizard-browser CI screenshots answered the in-shell question the same
  day. Status colors carry documented safety constraints — a theme that paints DEGRADED
  reassuring is a safety bug, not a preference. (M → S, P2)

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
