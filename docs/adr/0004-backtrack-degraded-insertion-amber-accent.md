# ADR 0004 — A single amber accent for Backtrack degraded insertion

- Status: accepted (2026-07-20; wayfinder map #136, ticket #140, assembled in #142)
- Amends: [ADR-0002](0002-hud-v3-is-bare-marks-no-glass.md) — "HUD v3 is bare marks,
  no glass", specifically its "**no accent color anywhere**" clause

## Context

ADR-0002 locked HUD v3 as bare marks on a transparent panel with **no accent color
anywhere** — `labelColor` recording bars, `secondaryLabelColor` processing dots, and
a silent hide on success. That decision was made for the HUD's normal
recording→processing→done cycle, where success is the common case and needs no
signal.

Backtrack ([map #136](https://github.com/dbgeek/type-wave/issues/136)) adds a new
outcome that HUD v3 never had to represent: a **degraded insertion**. When the cloud
rewrite times out (~3 s) or errors, the pipeline inserts the *raw* Final Transcript
instead of the rewritten one (per [ticket #138](https://github.com/dbgeek/type-wave/issues/138)).
The user still gets their dictation, so it is **not** an error — the error cue sound
is deliberately not played. But it is a silent downgrade the user should be able to
notice, and the prototype (#141) measured it landing on roughly **1 in 10–20
utterances** given the latency tail.

The normal degraded-path visual under ADR-0002 would be the plain silent hide —
indistinguishable from success. A monochrome motion-only alternative (e.g. a gray
blink) was considered and rejected: against the normal ~0.11 s fade-out it is too
easily missed for a rare, soundless event that must register.

## Decision

Permit **a single semantic accent color for exceptional transient feedback**,
scoped strictly to the degraded-insertion signal:

- On a failed rewrite (raw transcript inserted, no error sound), the processing dots
  pulse **`systemOrangeColor` once, ~300 ms**, then fade out — played *instead of*
  the plain hide on the degraded path.
- `systemOrangeColor` is a **semantic system color**, so it stays light/dark
  adaptive — the property ADR-0002 actually cares about (bars/dots re-resolve
  semantic colors on repaint).

This is the *only* sanctioned accent. The recording bars, processing dots on the
normal path, and the success hide are unchanged and remain accent-free per ADR-0002.

## Consequences

- **ADR-0002's "no accent color anywhere" now reads "no accent color except the
  degraded-insertion pulse."** The bare-marks aesthetic and the reasoning behind it
  (transient signal, not a thing) are otherwise intact — this is a narrow exception
  for one rare event, not a reopening of the glass/accent question.
- **No accent-refresh machinery is reintroduced.** The pulse resolves
  `systemOrangeColor` at paint time like every other semantic color; no
  `controlAccentColor` and no `NSSystemColorsDidChangeNotification` wiring.
- Implementation hooks (for the follow-on Backtrack effort): a one-shot pulse
  primitive in the HUD Sequencer/render split (`hud.zig`), reached via a new
  `surface.Surface` verb from `onInserted` (`coordinator.zig:227`), driven by a
  `.degraded` variant on `coord.InsertResult` (`coordinator.zig:39`, produced in
  `insertion_adapter.zig`).
- A future restyle must not silently drop this pulse when re-touching the HUD: it is
  the *only* channel that distinguishes a degraded insertion from a normal one, and
  the error sound is intentionally withheld on this path.

Full feature context: [`docs/backtrack-spec.md`](../backtrack-spec.md).
