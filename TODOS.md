# TODOS

Deferred scope from the /autoplan review (2026-07-12, branch `260709_test`).
Format: What / Why / Context / Effort (human → CC) / Priority / Depends on.

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

- [ ] **nftables firewall** — currently "future" in the spec. It is a hard requirement
  before any network-facing service ships — and the requirement is already breached:
  `Containerfile:70` enables sshd while SPEC §9 says disabled-by-default. Pulled into the
  install-UX design's repair wave (eng review 2026-07-16): minimal policy (22 + 9090,
  default drop inbound) + resolve the sshd/SPEC contradiction. (M → S, P1, blocks:
  first-boot wizard)

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
