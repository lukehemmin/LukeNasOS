# Design System — LukeNasOS

The visual source of truth for every LukeNasOS web surface (the Cockpit plugin:
first-boot wizard, health strip, landing page, and the timeline/undo dashboard).
Read this before making any visual or UI decision.

Two layers, held with different grips:

- **The bones** (verdict-first composition, semantic-only color, timeline over
  dashboard, calm motion) are derived from product truth, not taste. They are
  settled and theme-independent.
- **The skin** (the Ranger Station default theme below) is the shipped default
  of a user-themable token system. It is good; it is also the layer we hold
  loosest — see § Theming and § Open validations.

## Product context

- **What this is:** a recovery-first personal NAS OS; the web surface is a
  Cockpit plugin whose heart is a timeline with an undo button.
- **Who it's for:** self-hosters — from first-time NAS builders to homelab
  veterans. The first-contact device is a phone standing next to the machine.
- **Space:** TrueNAS (enterprise blue, dense), Unraid (dark + hacker orange),
  HexOS (consumer purple gradients), Umbrel (Apple-dark gadget). Green and
  warm-paper are unclaimed in this category.
- **Memorable thing** (the one sentence every decision serves): *calm
  reassurance that you can always recover — real infrastructure, not a toy —
  yet approachable enough that an ordinary person building their first NAS is
  drawn in.*

## The bones (theme-independent, settled)

1. **The verdict is a sentence, first.** The top of every screen answers "is
   my data safe right now?" in one plain-language sentence set in the display
   face — "Recovered itself at 03:12. Nothing was lost." Badge soup is
   forbidden as the primary read. Detail (hashes, timestamps) lives below in
   the mono face. This mirrors the `luke status` contract: verdict first,
   evidence after.
2. **Color is spent on state, not brand excitement.** Only the health surface
   may use the three status colors. Chrome stays neutral. The accent doubles
   as the OK color on purpose: the brand color IS the color of
   everything-is-fine.
3. **Status is never color alone.** Symbol + word + color, always
   (`● OK / ▲ RECOVERED / ✕ DEGRADED`) — color-blind safe, consistent with
   SPEC's banner rules.
4. **The timeline outranks the dashboard.** What changed and where you can
   return to is the center; capacity charts are supporting evidence.
5. **Undo is promoted, not buried.** The undo control is the largest control
   on the timeline screen and uses hold-to-run instead of a confirmation
   modal (see § Motion). Rollback is the tagline, not the failure path.
6. **Single dominant reading column,** strong left edge, mobile-first.
   No centered-everything composition.
7. **Nothing ever startles you.** No infinite pulsing, no flashing, no
   celebratory confetti. A recovery OS that flashes is lying about its own
   temperament.

## Aesthetic direction (default theme: "Ranger Station")

- **Direction:** a national-park trailhead sign brought to software — warm,
  weatherproof, calmly authoritative, maintained by someone who clearly walks
  this path every day.
- **Decoration level:** minimal. Typography and spacing do the work; no
  texture, no gradients, no decorative blobs.
- **Mood:** an exhale. First reaction "…oh, this is nice", followed by "and it
  clearly knows what it's doing." Calm is the flex — HexOS does "wow".
- **Dark mode:** lamplight on a workbench, not blue-black server room. The
  same physical appliance in different room light, never a second brand.

## Typography

All faces are open-license (SIL OFL) and self-hosted as woff2 from the image.
**No runtime CDN, ever** (the machine must work on a LAN with no internet).

- **Display/verdicts:** Fraunces (variable; weights 500–600,
  `font-variation-settings: "opsz" 40, "SOFT" 60`) — verdict sentences, wizard
  step titles, section headings ONLY. The serif is the product's voice — a
  person leaving you a note, not a daemon emitting status. Scoping it to
  verdicts keeps it from turning decorative.
- **Body/UI:** Atkinson Hyperlegible Next (400/500/700) — all body text,
  controls, labels. Designed by the Braille Institute for maximum legibility:
  a phone at arm's length in a garage is the design case, and the
  accessibility story is functional, not a badge.
- **Data/evidence:** Commit Mono (400) — timestamps, deploy hashes, image
  refs, paths, log excerpts. Never decorative; its job is to make system
  evidence legible. (`font-variant-numeric: tabular-nums` where digits align.)
- **Hangul/CJK fallback:** the three faces cover Latin. Non-Latin text falls
  back to the system stack (`"Atkinson Hyperlegible Next", "Pretendard",
  "Noto Sans KR", sans-serif` ordering when localization arrives). Product
  output is English today; this line exists so localization never blocks on
  fonts.
- **Scale** (rem, base 16px): display 2.6 / verdict 1.75 / h2 1.35 /
  h3 1.1 / body 1.0 / small 0.9 / meta-mono 0.78. Line-height 1.55 body,
  1.15–1.2 display. Headings get `text-wrap: balance`.

## Color

- **Approach:** restrained. Neutrals carry the room; one accent; two more
  status hues that appear nowhere else.

Default theme token values:

| Token | Light | Dark | Role |
|---|---|---|---|
| `--ln-bg` | `#F6F1E7` | `#181510` | page — aged paper / warm charcoal |
| `--ln-surface` | `#FFFCF4` | `#221E17` | cards, screens |
| `--ln-text` | `#221E17` | `#EDE5D6` | iron-gall ink |
| `--ln-muted` | `#6E6557` | `#9C9284` | secondary text |
| `--ln-line` | `#DDD5C4` | `#3A342A` | borders, dividers |
| `--ln-accent` | `#1B6E53` | `#4CC38A` | spruce / lichen — actions, links |
| `--ln-on-accent` | `#FFFCF4` | `#12241C` | text on accent |
| `--ln-ok` | `#1B6E53` | `#4CC38A` | ● OK (= accent, by design) |
| `--ln-recovered` | `#996A13` | `#E0A83E` | ▲ RECOVERED — dry amber, not orange |
| `--ln-degraded` | `#A6402E` | `#E06B54` | ✕ DEGRADED — brick, not klaxon red |

- **Dark mode strategy:** token-level redefinition only. Components never
  branch on theme; they read tokens. The Cockpit shell's explicit toggle
  (`html[class*="theme-dark"]`) must win over `prefers-color-scheme` in both
  directions (already proven in `web/lukenasos-setup/setup.css`).
- **DEGRADED is a red you can look at while you think.** A degraded NAS with
  family photos on it needs composure, not a klaxon.

## Spacing

- **Base unit:** 8px. **Density:** comfortable overall; operational rows
  (timeline events, share lists) compact. Infrastructure needs room to
  breathe without becoming sparse.
- **Scale:** 2xs(2) xs(4) sm(8) md(16) lg(24) xl(32) 2xl(48) 3xl(64).

## Layout

- **Approach:** grid-disciplined, single dominant reading column.
- **Max content width:** 660–680px reading column; a narrow right rail may
  appear on desktop for secondary detail, folding beneath on mobile.
- **Border radius:** modest and hierarchical — 4px (inputs, buttons),
  6px (cards, screens). Nothing bubbly; the UI reads as infrastructure,
  not SaaS.
- **Breakpoint:** ≤480px is the primary design target (phone next to the
  NAS), not an afterthought.

## Motion

- **Approach:** minimal-functional with a few intentional moments. Motion
  explains causality; it never decorates.
- **Verdict changes:** a stamp settling — cross-fade through the neutral text
  color, scale 1.02 → 1.00, ~300ms, single-fire. DEGRADED may take exactly
  two slow breaths (4s opacity swell on the ✕ glyph), then stillness.
- **Undo (hold-to-run):** press and hold ~900ms while a fill sweeps leftward
  — against reading direction, literally rewinding. Release early and it
  drains back with no penalty: "you can always let go" is the whole product
  in one micro-interaction. On completion, the timeline physically slides
  down one entry (~350ms ease-out) so history is seen to move. **No "are you
  sure?" modal for undo, ever** — confidence in the mechanism, expressed as
  interaction design. A first-use hint line covers discoverability.
- **Easing/duration:** enter ease-out, exit ease-in, move ease-in-out;
  micro 50–100ms, short 150–250ms, medium 250–400ms.
- **`prefers-reduced-motion`:** everything collapses to instant state
  changes; hold-to-run keeps its duration but drops the fill animation.

## Theming

Themes are a **token contract**, not a plugin system.

- **The contract:** the `--ln-*` custom properties in the Color table (plus
  the three font-family stacks) are the entire themable surface. A theme is
  one CSS file that redefines token values for light and/or dark. Ranger
  Station is simply the default theme shipped in the image.
- **Themes may not** change layout, typography scale, motion, or the bones.
  If a change needs a selector other than `:root` (and the theme-class
  variants), it is not a theme — it is a fork.
- **Semantic constraints (documented, reviewed for bundled themes):** the
  three status colors must remain mutually distinguishable and meet WCAG AA
  contrast against `--ln-surface`; OK may equal accent; RECOVERED/DEGRADED
  must not read as green. A theme that paints DEGRADED reassuring is a
  safety bug, not a preference.
- **Mechanism (implementation detail for the dashboard slice):** the plugin
  loads its default tokens, then a single well-known override file if present
  (e.g. `/etc/lukenasos/theme.css`). Whether a chosen theme rides the
  identity capsule across factory reset is an open implementation question —
  decide it in the reset's spirit: the layout is the machine, the theme is
  the person.

## Open validations (honest edges, checked at the dashboard slice)

1. **Inside the real Cockpit shell:** the preview rendered standalone. Warm
   paper inside Cockpit's cool grey chrome is unvalidated — screenshot the
   themed wizard in the actual shell before building the dashboard on it.
2. **Warm-serif fashion risk:** warm background + serif display is a look AI
   tools currently converge on. Spruce (not terracotta) and the trailhead
   metaphor pull away from that cluster, but if the skin ages badly, the
   token system means the default theme can be swapped without touching a
   single component. That is the point of § Theming.

## Decisions log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-07-19 | Initial system created by /design-consultation | Three voices (research + Codex + Claude subagent) independently converged on warm-light surfaces, green accent, verdict-first, timeline-first; maintainer picked the Fraunces voice over Instrument Sans restraint |
| 2026-07-19 | Theming = token contract; Ranger Station is the default theme | Maintainer's call: users can develop their own themes; the skin is the loosest-held layer, and a token contract makes swapping it free. Constraints on status colors documented above |
