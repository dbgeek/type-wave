# undo-bloom — confirm/refuse HUD treatment prototype

Throwaway reaction artifact for wayfinder ticket
[#216 — Concrete HUD treatment for the Undo confirm/refuse bloom](https://github.com/dbgeek/type-wave/issues/216)
(map [#209](https://github.com/dbgeek/type-wave/issues/209)).

`index.html` is self-contained — open it in a browser, no build. It animates the real
`300×22` HUD pill (shown at 2.4×) on the real `0.7×` motion timings from `src/hud.zig`,
so the candidate blooms can be reacted to for hue + motion.

## Why this exists

The feedback *model* is already locked in
[#213](https://github.com/dbgeek/type-wave/issues/213): both Undo outcomes surface via
the HUD (never the Status Item), reusing the ADR-0004 one-shot pulse, as **two distinct
blooms** — one confirmed, one refused — with the specific refuse reason logged, not
rendered. This ticket locks the *look*.

Key constraint that makes Undo different from the amber pulse: at Undo time nothing is
recording/processing, so the pill is `hidden`. The cue must **bloom up from nothing** and
fade, rather than tint marks that are already on screen (as the amber pulse tints the
held processing dots).

## The three candidates + reference

- **A — Single mark, shake-refuse (recommended).** One centred `6×14` mark (distinct from
  the 26 recording bars and the 3 processing dots). Confirm = `systemGreen`, one bloom.
  Refuse = `systemRed` + horizontal shake. Motion carries the outcome, so it survives
  colorblindness and doesn't lean on hue alone.
- **B — Reused dots, double-blink refuse.** Reuses the existing three processing-dot layers
  verbatim (cheapest to build). Confirm = green bloom; refuse = red double-blink. Trades
  semantic clarity (dots also mean "thinking") for reuse.
- **C — Monochrome, motion-only (purist).** Single `labelColor` mark, outcome carried
  purely by motion (settle vs shake). **No accent** → ADR-0002 stays pristine, no second
  accent exception, no ADR amendment.
- **R — Degraded amber pulse (reference, shipped).** The existing ADR-0004 pulse, shown
  only so the new hues can be checked for collision. Orange is off-limits for the new cue.

## What the ticket must lock (feeds assembly #215)

1. **Hue / motion** — which treatment; exact confirm vs refuse look.
2. **Pill content** — single mark (A/C) vs reused dots (B).
3. **ADR-0002 implication** — an accent pick (A/B) is the *second* sanctioned exception →
   warrants an ADR amendment (extend ADR-0004 or a fresh ADR). Pick C → ADR-0002 unchanged.

This is HITL — the treatment is locked *with* the human reacting to the artifact, not
decided here.
