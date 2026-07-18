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

- [ ] **Playwright E2E for the wizard** — `cockpit.spawn` runs over websockets, so curl
  cannot exercise a Cockpit plugin. Runs at a phone viewport and a desktop one, light and
  dark. Covers the browser half only: the machine half is already proven by lifecycle
  phase 1c/5 (verbs, credential transfer, capsule restore, and a no-browser serving check
  that logs into Cockpit's own login endpoint and fetches the plugin with the session
  cookie). What has never been executed is the JS itself: the form flow, the interstitial
  before terminate-user, the resume-from-stamp routing, the strip states. Until this
  exists, the wizard's browser half has the same status the setup verbs had before
  phase 1c — logic reviewed, never run. (M → S, P1)

- [ ] **Post-wizard landing page** — the wizard's completed-state card (facts + mount
  string) is the placeholder today; the real landing is the health strip + share list +
  `luke status` facts, the seed of the timeline UI. (M → S, P2)

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

- [x] **Disk portability test — shipped 2026-07-18** as lifecycle phase 7 (green, run
  29642071363): the same disk that lived through install/setup/update/rollback/reset/
  power-cuts boots on hardware it has never seen (i440fx + e1000 instead of q35 + virtio
  — new NIC name, fresh DHCP lease, no NetworkManager profile in the post-reset /etc)
  and is still the same NAS: name, administrator with the same uid, data, and the share
  served through the firewall. The disk bus stays virtio on purpose — swapping it would
  test the initramfs's driver inventory, which is Fedora's promise, not ours. What
  remains for M2 is only the literal-hardware version of the same move. (M → S, P2)

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
