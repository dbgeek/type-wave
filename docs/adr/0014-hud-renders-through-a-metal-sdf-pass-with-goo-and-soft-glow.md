# ADR 0014 — The HUD renders through a Metal SDF pass with goo and soft glow

- Status: accepted (2026-09-25; wayfinder map [#355](https://github.com/dbgeek/type-wave/issues/355),
  look locked HITL in `prototypes/hud-micro-motion`, feasibility proven by spike
  [#356](https://github.com/dbgeek/type-wave/issues/356), recorded in
  [#357](https://github.com/dbgeek/type-wave/issues/357))
- Amends: [ADR-0002](0002-hud-v3-is-bare-marks-no-glass.md) — "HUD v3 is bare marks, no
  glass", specifically **how the marks are drawn** (one CALayer per mark), their **motion**
  (fade + crossfade), and the unglowing bare look. Its glass, capsule, text and accent
  verdicts stand, as narrowed by [ADR-0004](0004-backtrack-degraded-insertion-amber-accent.md)
  and [ADR-0007](0007-undo-confirm-refuse-green-red-accents.md).

## Context

The shipped pill **steps at 20 fps**. `AppKitChrome` holds one CALayer per mark, and a
`CFRunLoopTimer` render pump (`render_interval_s = 0.05` in `src/hud.zig`) sets bar heights and
the dot bounce 20 times a second with `CATransaction` actions disabled. On a 120 Hz display the
scroll jumps one 10 pt slot at a time and the dots stutter. Core Animation interpolates only
the window fade and the bars→dots crossfade. #25 judged 20 Hz smooth enough for the scroll. The
micro-motion work asked whether the pill could look *polished* without breaking ADR-0002's
bare-marks look.

`prototypes/hud-micro-motion` put the same engine (a port of `Hud.render` + `Sequencer.step`)
behind three pills:

- **Today**, which reproduces the shipped pill.
- **Track A**: twelve Core Animation-only options with the pump kept at 20 Hz. *Smoothness*
  interpolates between ticks, glides the scroll, runs the dots at display rate and shows on the
  press. *Waveform* adds an organic envelope, edge dissolve, loudness-weighted opacity and a
  silence ripple. *Moments* adds unfurl, gathering the bars into dots, squash & stretch, and
  converge & drop on insert.
- **Track B**: A's geometry drawn as signed-distance shapes in one fragment shader. That makes
  a smooth-union **goo** possible: bars melt into dots on gather, and dots melt together on
  converge. B also offers an optional **soft glow**, flagged at the time as reopening ADR-0002.

The HITL verdict (2026-09-25) chose **track B over track A**, with every A geometry option on,
goo **Always** at a **5 pt** blend radius, and soft glow at **0.75**. Raw CALayers cannot draw
the goo. A Core Image blur+threshold was noted as a cheaper route to it but was not chosen.
Spike #356 (`prototypes/metal-hud-spike`) then proved that the daemon's panel can host the
pass from pure Zig.

## Decision

The HUD's marks are drawn by **one Metal SDF fragment pass** on a transparent `CAMetalLayer`
hosted by the existing panel. They are no longer raw CALayers.

- **Every mark is a rounded-box SDF**: the 26 recording bars, the 3 processing dots, and the
  Undo mark (ADR-0007). All of them go through one full-screen pass, with the shape list sent
  as fragment bytes.
- **Goo: Always, 5 pt.** The marks are unioned with a polynomial smooth-min, so neighbouring
  marks melt into each other. There is no backing shape for them to melt into.
- **Soft glow: 0.75.** An exponential halo falls off each mark in **that mark's own blended
  colour**. The glow never introduces a hue: it is `labelColor` around the bars,
  `secondaryLabelColor` around the dots, amber only while the ADR-0004 pulse tints the dots,
  and green or red only around the ADR-0007 mark.
- **Display rate while visible.** The pass is paced by a display link and draws nothing while
  the pill is hidden. The Capture cadence (20 level samples/s) and the level queue are
  unchanged. The Scene interpolates between samples.
- **Motion** is the full locked set: interpolate, glide, display-rate dots, show on press,
  organic envelope, edge dissolve, loudness opacity, silence ripple, unfurl, gather, squash &
  stretch, and converge & drop. **Reduce Motion** falls back to ADR-0002's fades and crossfade.

### What changes in ADR-0002

- **Glow.** "Bare marks" now reads "bare marks with a soft glow in their own colour." The glow
  is a falloff of the mark, not a material behind it.
- **Marks are drawn by a shader, not raw CALayers.** ADR-0002's "`labelColor` scrolling bars,
  6 pt wide / 4 pt gap (26 bars), in a 300×22 sliver" keeps its geometry. The Chrome draws the
  bars as SDF shapes instead of sizing one layer per bar.
- **Motion.** ADR-0002's window fade and bars→dots crossfade are now the Reduce Motion
  fallback. The default motion is the micro-motion set above.
- **Footprint.** The marks keep the 300×22 layout, but the panel's drawing region grows past it
  to hold the glow halo and the unfurl spring's overshoot. The spike used 340×50. The exact
  size is left to the MetalChrome ticket ([#359](https://github.com/dbgeek/type-wave/issues/359)).

### What stands

- **No glass, no capsule.** There is no `NSGlassEffectView` and nothing behind the marks. Glow
  is not glass, and ADR-0002's warning against "restoring" the glass capsule still applies.
- **No text, ever.**
- **No accent beyond ADR-0004 and ADR-0007.** The only accents remain the amber degraded pulse
  and the Undo green/red cue. Because the glow inherits the mark's colour, it cannot add an
  accent of its own. Both cues carry over into the shader path, and ADR-0007's shake survives
  as motion.
- **Semantic colours are re-resolved on the draw path.** `labelColor`, `secondaryLabelColor`,
  `systemOrangeColor`, `systemGreenColor` and `systemRedColor` resolve to sRGB when drawing, so
  the pill tracks light/dark appearance with no accent-refresh machinery. The spike's
  suggested trim, resolving once per show instead of every frame, fits within this. An
  `NSSystemColorsDidChangeNotification` observer does not: that is the machinery ADR-0002
  declined.
- **Window shadow off**, the focus-avoidance recipe (#20), and the −60/−10 dBFS level mapping
  are all unchanged.

## Consequences

- **Metal is linked into the daemon.** Metal joins the shared `linkFrameworks` in `build.zig`.
  Every call goes through typed `objc_msgSend` casts, including the struct-by-value
  `MTLClearColor`, `CGSize` and `CAFrameRateRange` arguments. There is no Swift/ObjC shim. The
  MSL source is compiled at runtime (`newLibraryWithSource:options:error:`), which costs **~640
  ms once**. That compile happens at Chrome init, never on the first press. A precompiled
  `.metallib` via `newLibraryWithData:` is the fix if the startup cost ever matters.
- **The cadence becomes a display link.** The Chrome paces the pass with `NSScreen
  displayLinkWithTarget:selector:` from a runtime target class (the `menu.zig` recipe). It runs
  under plain `CFRunLoopRun`, preferring 120 within a 60–120 range, and pauses and resumes with
  the pill. A 120 Hz `CFRunLoopTimer` was **ruled out**: `nextDrawable` blocked the main thread
  ~8 ms per frame, and that thread services the Talk Key event tap. As before, the cadence
  stays with the adapter. The HUD's 20 Hz `CFRunLoopTimer` pump is retired along with
  `AppKitChrome`.
- **Cost.** On an M1 at 60 Hz, each frame takes ~0.3–0.5 ms of main-thread CPU to build and
  encode, which comes to **~6.5–9 % of one core while visible** and ~0 while hidden. That is
  acceptable for a pill shown only during dictation. GPU cost (`powermetrics`) and ProMotion
  judder were not measured. Both are acceptance criteria in
  [#360](https://github.com/dbgeek/type-wave/issues/360), along with the focus check and the
  light and full-screen backdrops.
- **No Metal means sound-only.** If there is no default device, or the shader compile or the
  pipeline fails, the Chrome is not built, exactly as when headless. The pump stays disabled,
  `isOn` reports false, and the Feedback Surface falls back to the chimes. There is **no Core
  Animation fallback renderer**, because Metal is present on every supported Mac, so a second
  drawing path would be untested weight.
- **The HUD Chrome seam keeps its shape.** It still has one `paint(Frame)` method with no
  policy: the Sequencer decides, the pump composes, and the Chrome only draws. The Frame grows
  into the Scene's fixed-size, `std.meta.eql`-comparable shape list
  ([#358](https://github.com/dbgeek/type-wave/issues/358)), so `FakeChrome` still asserts
  composition as values. The goo, glow and pacing live in the Chrome. The geometry, including
  every locked option and the Reduce Motion fallback, is pure and testable.
- A future restyle should not drop the goo or glow by going back to per-mark CALayers without
  re-reading this record. Both were chosen HITL against a CALayer-only track that offered the
  same geometry.
