# hud-micro-motion — HUD micro-animation prototype

Throwaway reaction artifact: can the HUD pill feel polished through micro-animation
without breaking the bare-marks look ([ADR-0002](../../docs/adr/0002-hud-v3-is-bare-marks-no-glass.md))?
Delete or graduate once the questions below are answered. No wayfinder ticket yet.

`index.html` is self-contained. Open it directly, or serve it for the live mic:

    cd prototypes/hud-micro-motion
    python3 -m http.server 8000     # then http://localhost:8000

Hold **Space** (or the button) as you would hold fn. Auto demo loops press → talk → release →
processing → insert.

## Why this exists

Today's pill steps at **20 fps**. The render pump pokes bar heights (`hud.zig` `paint`) and the
dot bounce (`sin(now*5 + j*0.8)` in `render`) at 20 Hz with CATransaction actions disabled, so
on a 120 Hz display the scroll jumps one 10 pt slot at a time and the dots stutter. Only the
window fade and the bars→dots crossfade are interpolated by Core Animation.

## The three stages

All three share one simulated clock, voice, and 20 Hz pump. The engine is a port of
`Hud.render` + `Sequencer.step`, so every pill sees exactly the same events.

- **Today (reference).** The candidate engine with every option off, which reproduces
  `src/hud.zig`: 20 Hz snapped heights, crossfade, 112 ms fade-out, and the amber pulse sampled
  per tick.
- **A — Core Animation track (recommended).** Twelve toggles, each labelled with the stock CA
  mechanism it would ship as. There is no new rendering stack; the pump stays at 20 Hz.
  - *Smoothness:* interpolate between ticks, glide the scroll, dots at display rate, show on
    the press.
  - *Waveform:* organic envelope, dissolve history at the edge, loudness-weighted opacity,
    listening ripple in silence.
  - *Moments:* unfurl from centre, gather bars into dots, squash & stretch, converge & drop
    on insert.
- **B — Shader track (Metal stand-in).** A's geometry drawn as signed-distance shapes in one
  WebGL fragment shader, which makes a smooth-union "goo" possible (bars melt into dots,
  dots melt together on insert). There is also an optional soft glow, flagged because it
  reopens ADR-0002. The SDF shader ports to MSL almost line for line; a Core Image
  blur+threshold on the layers is the cheaper native route to the same goo.

Controls: voice (talk / whisper / silence / live mic), outcome (inserted / degraded, to check
that the ADR-0004 amber pulse survives converge), slow-mo down to ⅒×, 1× true size vs 2.4×,
dark / light / wallpaper backdrops, and a Reduce Motion simulation. Toggle state persists per
browser.

## What to lock

1. **Smoothness:** ship the four smoothness toggles as a first low-risk PR? They add no
   new choreography.
2. **Choreography:** which waveform and moment toggles ship. Gather and converge add
   `MarksFx` / `WindowFx` cases (testable with `FakeChrome`); the rest are Chrome-only.
3. **Shader track:** is goo worth a rendering pipeline (CIFilter first, Metal only if that
   falls short)? Glow would need an ADR-0002 amendment.
4. **Reduce Motion:** is it right that unfurl, gather, converge, squash and ripple fall back
   to today's fades and crossfade?

## Verdict (2026-09-25, HITL)

- **Track: B, the shader track** (a Metal SDF pass), not the Core Animation-only track.
- **Geometry: every A toggle on.** Smoothness (interpolate, glide, display-rate dots, show on
  press), waveform (organic envelope, edge dissolve, loudness opacity, silence ripple) and
  moments (unfurl, gather, squash & stretch, converge & drop).
- **Goo: Always**, blend radius **5 pt**.
- **Soft glow: on**, strength **0.75**. This amends ADR-0002 and needs a new ADR.
- The amber degraded pulse (ADR-0004) and the Undo green/red cue (ADR-0007) carry over into
  the shader path.
