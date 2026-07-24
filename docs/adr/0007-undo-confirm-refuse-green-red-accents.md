# ADR 0007 — Green/red confirm-refuse accents for the Undo cue

- Status: accepted (2026-07-24; wayfinder map [#209](https://github.com/dbgeek/type-wave/issues/209),
  treatment locked in ticket [#216](https://github.com/dbgeek/type-wave/issues/216),
  recorded in [#218](https://github.com/dbgeek/type-wave/issues/218))
- Amends: [ADR-0004](0004-backtrack-degraded-insertion-amber-accent.md) — "A single
  amber accent for Backtrack degraded insertion", specifically its "**This is the
  *only* sanctioned accent**" clause — and, transitively, [ADR-0002](0002-hud-v3-is-bare-marks-no-glass.md)'s
  "**no accent color anywhere**" clause that ADR-0004 first narrowed.

## Context

ADR-0002 locked HUD v3 as bare marks on a transparent panel with **no accent color
anywhere**. ADR-0004 then permitted **one** semantic accent — a single ~300 ms
`systemOrangeColor` pulse of the processing dots — scoped strictly to the
degraded-insertion signal, and declared it "the *only* sanctioned accent."

The Undo-last-Insertion effort ([map #209](https://github.com/dbgeek/type-wave/issues/209))
adds a recovery hotkey (`⌃⌘⌫`) that deletes the most recent Insertion, gated
app-level on the frontmost app being unchanged. That gate has **two outcomes the HUD
must distinguish** ([#213](https://github.com/dbgeek/type-wave/issues/213)): the
backspaces were posted (**confirmed**), or the gate refused (**refused** — app
changed, focus null, no target, or the newest record already undone, all collapsed to
one cue with the specific reason logged only). Both surface via the HUD, never the
Status Item.

The concrete treatment was prototyped and locked HITL against a reaction artifact
(`prototypes/undo-bloom/index.html`, draft PR [#217](https://github.com/dbgeek/type-wave/pull/217);
[interactive viewer](https://claude.ai/code/artifact/3bc29822-da29-4a0c-895a-c3d8395181f3))
in [#216](https://github.com/dbgeek/type-wave/issues/216) — Treatment A (single mark
+ shake) over a reused-dots variant (B) and a monochrome motion-only variant (C, which
would have kept ADR-0002 pristine but read too weak for a deliberate user action).

A confirm/refuse color is therefore the **second** sanctioned accent exception, which
ADR-0004's "only sanctioned accent" wording forbids. Rather than bury the accent
policy inside the Undo feature spec, this ADR records the exception where the policy
already lives.

## Decision

Permit **two semantic accent colors for the Undo confirm/refuse cue**, scoped strictly
to that cue, and carried by **motion as well as hue** so the outcome survives
colorblindness:

- The Undo cue is a **net-new single centred mark** — a ~`6×14` pt rounded bar — **not**
  the 26 `labelColor` recording bars and **not** the 3 `secondaryLabelColor` processing
  dots. At Undo time nothing is recording or processing (the pill is `hidden`), so the
  distinct single-mark shape guarantees the cue never reads as "recording" or
  "thinking." It is a new layer family in `hud.zig` (today only `bars[26]` and `dots[3]`
  exist).
- **Confirmed** — the mark blooms **`systemGreenColor`**, **one bloom**: green ramps in
  over ~300 ms easeOut (reusing the ADR-0004 pulse-envelope shape), holds briefly, then
  the ordinary hide fade carries it out.
- **Refused** — the mark blooms **`systemRedColor`** + a **horizontal shake** (the
  "denied" gesture, ~±6 px scaled to the pill, ~3 oscillations over ~300 ms), then hide
  fade. All refuse reasons collapse to this one red-shake cue; the specific reason is
  **logged only** (per [#213](https://github.com/dbgeek/type-wave/issues/213)).
- **Motion carries the outcome** — green-still-bloom vs red-shake differ in *motion*,
  not hue alone — so the cue reads at a glance and does not depend on distinguishing
  green from red.
- `systemGreenColor` / `systemRedColor` are **semantic system colors**, light/dark
  adaptive, resolved at paint time like every other mark. Neither collides with
  `systemOrangeColor` (the ADR-0004 degraded pulse), verified against the reference
  bloom in the prototype.

The recording bars, the normal-path processing dots, the success hide, and the amber
degraded pulse are all unchanged.

## Consequences

- **ADR-0004's "only sanctioned accent" now reads "the degraded-insertion amber pulse
  and the Undo confirm/refuse green/red cue are the sanctioned accents."** ADR-0002's
  bare-marks aesthetic is otherwise intact: these are narrow exceptions for two specific
  transient signals, not a reopening of the glass/accent question. Any *third* accent
  should be recorded the same way, not slipped in.
- **No accent-refresh machinery is reintroduced.** Both cues resolve their semantic
  colors at paint time like every other mark — no `controlAccentColor`, no
  `NSSystemColorsDidChangeNotification` wiring — preserving the property ADR-0002 and
  ADR-0004 both protect.
- **The Undo cue is driven from `hidden`, so it is a new HUD path, not a reuse of the
  amber one.** `pulseDegraded` requires `pending_state == .processing` and tints marks
  already on screen; the Undo cue instead brings the pill up showing the single mark and
  self-hides (show-fade ~140 ms → hold → hide-fade ~112 ms). It needs its own transient
  HUD verb/state alongside the amber pulse. Exact `Sequencer` wiring is spec /
  downstream-build territory, not decided here.
- A future restyle must not silently drop either accent when re-touching the HUD: each
  is the *only* channel that distinguishes its event, and (for the refuse cue) the shake
  is half the signal — dropping the motion in favour of hue alone would break the
  colorblind-safe reading.

Full feature context: [`docs/undo-spec.md`](../undo-spec.md) (assembled in
[#215](https://github.com/dbgeek/type-wave/issues/215)).
