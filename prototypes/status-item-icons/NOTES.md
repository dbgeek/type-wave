# Status Item icon spike — the question

**Throwaway prototype** for wayfinder ticket
[#42](https://github.com/dbgeek/type-wave/issues/42) ("Pick the Tahoe-native
Status Item icon", map [#39](https://github.com/dbgeek/type-wave/issues/39)).
Delete or graduate once the icon is decided.

## Question

Which menu-bar icon makes type-wave's Status Item sit naturally among Tahoe's
system icons? Three axes:

- **The glyph** — the incumbent `waveform`/`waveform.slash` (#31) vs.
  mic-family and combined candidates.
- **Weight / size / scale** — does the default SF Symbol rendering (what the
  daemon ships today, no `NSImageSymbolConfiguration`) match the weight of
  Tahoe's own menu-bar icons, or does it want an explicit point size + weight?
- **The dimmed tier** — today a slash-symbol swap + `alphaValue 0.35`
  (src/menu.zig). Tahoe candidates: the same, alpha alone, the system-native
  `NSStatusBarButton.appearsDisabled`, or the slash variant at full alpha.

## Design

One `NSStatusItem` **per candidate**, all in the live menu bar at once — the
real system icons are the only honest backdrop (the menu-bar analogue of
prototyping inside the real page). Terminal commands flip every candidate
together between healthy/dimmed, cycle the four dim styles, and cycle
weight/size/scale; candidates toggle off one by one down to a finalist.
Clicking an icon pops a small identifying menu (name + rationale) — hence
`[NSApp run]`, per the #31 finding that bare `CFRunLoopRun` never routes
status-item clicks. All AppKit via `objc_msgSend` (the src/menu.zig recipe);
stdin commands land on the main thread via a 10 Hz `CFRunLoopTimer`.

Candidates (startup probe reports any name unknown to this macOS):

1. `waveform` — the incumbent: pure audio, matches the HUD's bars
2. `mic` — the classic dictation glyph, what the OS uses for speech
3. `mic.fill` — heavier presence, like Control Center's indicators
4. `waveform.badge.mic` — says *dictation*, not just audio (no slash variant)
5. `mic.and.signal.meter` — mic + live level meter (no slash variant)
6. `waveform.circle` — enclosed, rounder footprint (no slash variant)

## How to run

    cd prototypes/status-item-icons
    zig build run --sysroot /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # inside `nix develop`

(Same SDK split as `prototypes/liquid-glass-hud`: the 26.5 sysroot stamps the
binary current-SDK; `zig build run -Dlegacy_sdk=true` builds against the nix
14.4 SDK instead — also the check that the stamp doesn't matter for template
images.)

Commands (letter + Enter in the terminal):

    1..6  toggle a candidate            a  show all
    d     toggle dimmed tier            y  cycle dim style (slash+alpha /
    w     cycle weight (regular/medium     alpha / appearsDisabled / slash)
          /semibold/bold)               s  cycle size (default/13/15/17 pt)
    e     cycle scale (small/medium/large)
    q     quit

React to: which glyph reads "dictation" at a glance among the real system
icons; the weight/size that matches its neighbours (check light AND dark menu
bar, and a desktop where the Tahoe bar goes transparent); which dim style
reads "needs attention" without looking broken (`appearsDisabled` is what the
system's own items use). Toggle down to one finalist and live with it a bit.

## Smoke-test findings (2026-07-17, scripted run — pre-HITL)

- Builds clean against the 26.5 CLT SDK; `LC_BUILD_VERSION` stamps `sdk 26.5`.
- **All six candidate symbols exist on this macOS**, and all three slash
  variants (`waveform.slash`, `mic.slash`, `mic.slash.fill`) resolve. The
  no-slash candidates (4–6) fall back to alpha-dimming in the slash styles,
  called out in the status print.
- Every command applies live (dim toggle, all four dim styles,
  weight/size/scale, per-candidate toggling); clean exit via `terminate:`.
- Visual reaction — glyph choice, weight match against the system icons, and
  the winning dim style — is the HITL round.

## Verdict (2026-07-17, HITL)

**Winner:** `waveform.badge.mic`. In harness terms:

    [dim_style=slash_alpha weight=regular size=17pt scale=medium]
    visible: 4:waveform.badge.mic

- **Glyph:** `waveform.badge.mic` — says *dictation* (waveform + mic badge),
  beating the incumbent plain `waveform` and the whole mic family.
- **Rendering:** explicit `NSImageSymbolConfiguration` at **17 pt, regular
  weight, medium scale**, template image (the incumbent's no-config default
  rendering lost — too small next to Tahoe's system icons).
- **Dimmed tier:** the slash+alpha style — which for this glyph (no slash
  variant exists in SF Symbols) degrades to **the same glyph at
  `alphaValue 0.35`**. That alpha-dimmed rendering is what was judged and
  picked, so the daemon's slash-swap logic becomes moot: dimming is alpha
  alone.

What graduates (in the later graduation effort, not this map):
`src/menu.zig` swaps `waveform`/`waveform.slash` for `waveform.badge.mic`
with a 17pt/regular/medium symbol configuration, keeps `setTemplate:` and the
`alphaValue 0.35` dim, and drops the slash-symbol swap.
