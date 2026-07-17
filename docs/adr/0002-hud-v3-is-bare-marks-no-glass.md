# ADR 0002 — HUD v3 is bare marks, no glass

- Status: accepted (2026-07-17; wayfinder map #39, tickets #41/#44/#45)
- Supersedes: the Regular-glass accent capsule locked in ticket #41, and map #39's
  original destination framing ("a glass capsule holding the waveform")

## Context

Map #39 set out to restyle the HUD in macOS 26's **Liquid Glass** design language:
an `NSGlassEffectView` capsule around the waveform, custom red/green dropped for
system accent + vibrancy. The API research (#40) proved the glass classes fully
drivable from the pure-Zig `objc_msgSend` pattern, and the first prototype round
(#41) locked a Regular-glass capsule with strong accent tint, accent bars, and
accent processing dots at the proven 420×60 footprint.

The motion round (#44) then put that capsule through show/hide and
recording→processing transitions — and the reaction rounds walked the look
steadily *away* from chrome: smaller pill, neutral colors, and finally glass
style `none`. With the material gone, the accent tint had no target and the
neutral marks read better than accent ones. The dictation pill is a transient,
sub-second-to-seconds overlay; the glass capsule made it read as a *thing*,
where the bare marks read as a *signal*.

## Decision

HUD v3 renders **bare marks on the transparent panel — no `NSGlassEffectView`,
no capsule, no accent color anywhere**:

- Recording: `labelColor` scrolling bars, 6 pt wide / 4 pt gap (26 bars), in a
  **300×22** sliver.
- Processing: `secondaryLabelColor` bouncing dots.
- Window shadow **off** (macOS would outline the raw bar layers).
- Motion: show/hide is a window-alpha **fade**, recording→processing is a
  **crossfade**, both at 0.7× (≈0.14 s show / 0.11 s hide / 0.15 s crossfade).

The Status Item icon decision (#42 — `waveform.badge.mic`, 17 pt / regular /
medium, template image, alpha-0.35 dim) is unaffected: template images are
already the Tahoe-native treatment for menu-bar icons.

## Consequences

- **The daemon never touches the glass API**, so the linked-SDK question
  dissolves: no `--sysroot` / SDK switch is needed for the deployed build
  (doubly moot — #41 also proved explicit glass renders even from an
  sdk-14.4-stamped binary).
- **No accent-refresh machinery.** Nothing in the final design uses
  `controlAccentColor`; `NSSystemColorsDidChangeNotification` wiring is
  unnecessary. Bars/dots re-resolve semantic label colors on repaint, which
  tracks light/dark appearance.
- **Reduce Transparency fallback is moot** — there is no glass material to
  fall back from.
- **Whisper contrast was re-proven for this look** (2026-07-17, live mic,
  light and dark backdrops): the 22 pt bars still visibly move at a whisper
  with the −60/−10 dBFS mapping unchanged, despite a third of the 60 pt
  pill's bar excursion and no material behind the bars.
- The glass API research (`docs/research/liquid-glass-api.md`, branch
  `research/liquid-glass-api`) stays on file: if glass ever returns, the
  selector map and panel-compatibility findings hold.

A future restyle should not "restore" the glass capsule without re-reading
this record: glass was prototyped end-to-end, judged against the bare marks
in live reaction rounds, and traded away on purpose.

Graduation into the deployed daemon is specified in
[`docs/hud-v3-graduation.md`](../hud-v3-graduation.md).
