# Liquid Glass HUD spike — the question

**Throwaway prototype** for wayfinder tickets #41 ("Prototype the Liquid Glass
HUD capsule") and #44 ("Prototype the glass-native show/hide and
recording→processing transitions"), map #39. Delete or graduate once look and
motion are decided.

## Question

What should the Liquid Glass HUD actually look like? The destination drops the
custom red/green for the Tahoe design language:

- The **glass capsule**: geometry, corner radius, glass style/tint around the
  proven 420×60 waveform footprint (#25's HITL winner).
- **Bar treatment** over glass: scrolling bars in system accent (vs neutral
  label color, vs the old white) instead of red tint.
- The **processing state**: accent dots / neutral dots / a glass-native
  successor where the *material itself* breathes toward accent.
- **Whisper check**: a whisper must still visibly move the bars against the
  glass — the −60/−10 dBFS mapping may need retuning for contrast (map fog).

## Design

- **`glass.zig`** — the capsule. The #20 focus-avoidance panel recipe verbatim
  (it is, by luck, exactly the non-opaque/clear-background setup glass needs),
  plus one `NSGlassEffectView` filling the panel, driven purely via
  `objc_msgSend` per the #40 crib sheet (`docs/research/liquid-glass-api.md`).
  The proven CALayer-per-bar waveform rides a plain layer-backed NSView set as
  the glass `contentView` (the sanctioned placement). Raw CALayers get no
  vibrancy treatment, so bar/dot colors are derived from `controlAccentColor` /
  semantic NSColors, re-resolved on every recolor pass.
- **`main.zig`** — the harness, cloned from `prototypes/waveform-hud`:
  synthetic voice / live mic producers at Capture's 50 ms cadence, a 20 Hz
  CFRunLoopTimer render pump (the daemon's rate, proven in #25), stdin
  commands. Implicit CA animations stay off (#25's verdict).

## How to run

    cd prototypes/liquid-glass-hud
    zig build run --sysroot /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # inside `nix develop`

The `--sysroot` matters: AppKit gates new-design behavior on the binary's
`LC_BUILD_VERSION` sdk stamp (#40 §6.4), and this Zig only takes a sysroot from
the CLI (`b.sysroot` is gone; the devshell's `SDKROOT` is ignored by the nix
xcrun shim). The linker prefixes `-L` paths with the sysroot but searches `-F`
paths literally — hence the odd split in `build.zig`. Verify a build with
`otool -l zig-out/bin/liquid-glass-hud | grep -A5 LC_BUILD_VERSION`.

`zig build -Dlegacy_sdk=true` (no `--sysroot`) builds against the nix 14.4 SDK
instead — the "does glass render from a legacy binary" experiment.

Commands (letter + Enter in the terminal):

    r  recording (scrolling waveform)      p  processing (post-release hold)
    h  hide the pill                       t/w/s  synthetic voice: talk/whisper/silence
    m  toggle LIVE microphone input        g  glass style: Regular <-> Clear
    n  cycle glass tint (none / accent     c  cycle bar color (accent / label / white)
       soft / accent strong)               k  cycle corner radius (capsule / 16 / 8)
    d  cycle processing animation          x  toggle window shadow
       (accent dots / neutral dots /       1/2/3  bars: fine / thin / medium
       glass pulse)                        z  cycle size 420x60 / 340x52 / 300x44 / 300x22
    q  quit

React to: whisper visibility on glass (`w`, then `m` for the real thing) over
light AND dark backdrops, Regular vs Clear (`g`) over a busy desktop, tint
(`n` — remember the never-key gotcha: this panel is never main, so judge the
tint as-is), radius (`k`), shadow (`x`), and which processing look wins (`d`).
Flip macOS Reduce Transparency once and check the opaque-plate fallback. Eyeball
CPU in Activity Monitor vs `prototypes/waveform-hud` (glass re-samples what's
behind the window continuously).

## Smoke-test findings (2026-07-17, scripted run — pre-HITL)

- Builds clean against the 26.5 CLT SDK; `LC_BUILD_VERSION` stamps `sdk 26.5`.
- The glass capsule **renders inside the #20 panel recipe**: visible material
  + rim highlight over a dark backdrop, accent bars scrolling, accent dots in
  processing. Never-key, borderless, status-level, ignores-mouse — no conflict.
- Frame-only wiring works: glass + content frames set in tandem, no Auto
  Layout constraints needed at fixed size (resize via `z` still to be eyeballed).
- **An sdk-14.4-stamped binary (`-Dlegacy_sdk=true`) renders the capsule too**,
  visually identical over the same backdrop — explicitly-instantiated
  `NSGlassEffectView` is apparently not linked-SDK-gated. The deployed daemon
  likely needs no SDK switch for glass alone; worth one closer side-by-side
  during HITL before the graduation spec relies on it.

## Verdict (2026-07-17, HITL)

**Look locked.** The winner, in harness terms:

    [glass=regular tint=accent_strong bars=accent radius=capsule shadow=true
     pill=420x60 bar=3w/2g(76) processing=dots_accent]

Regular glass with a strong accent tint (accent @ 0.45 alpha), accent bars,
capsule corner radius (pill_h/2), window shadow ON, the proven 420×60 pill
with fine bars (3 pt wide / 2 pt gap → 76 bars), and accent bouncing dots for
processing.

- **Whisper check: PASSED** — a whisper still visibly moves the bars against
  the glass; the −60/−10 dBFS mapping needs no retune (map #39 fog dissolved).
- The old custom red/green is fully replaced by system accent — recording is
  signalled by the scrolling bars themselves, processing by the dots.
- Show/hide and recording→processing **transitions** in the glass language are
  the follow-on ticket (#44); this prototype is the base to extend.

## The motion question (#44)

The look above is locked and is now the default the harness boots into. #44
asks how it **moves**: how the capsule appears/disappears around the Utterance
lifecycle, and how recording hands over to processing. The lifecycle mapping
itself is fixed (map Notes) — only the rendered transitions change.

Candidates, live-switchable:

- **Show/hide** (`a`): `pop` (today's hard cut) / `fade` (window alpha) /
  `materialize` (alpha fade + the capsule condenses from ~90% scale —
  glass + content frames animate in tandem).
- **Recording→processing** (`f`): `cut` (today's hard swap) / `crossfade`
  (bars fade out while dots fade in, 0.22 s) / `morph` (bars gather onto the
  three dot positions while fading, 0.30 s) / `swell` (crossfade + a one-shot
  accent tint swell that decays over 0.45 s).
- **Speed** (`u`): 1.0 / 2.5 slow-mo (to see what a transition actually does)
  / 0.7 snappy. Durations: show 0.20 s, hide 0.16 s — all × speed.
- **Lifecycle demo** (`j`): one full synthetic Utterance — show, record
  ~2.5 s, processing ~1.5 s, hide — so a candidate reads as a whole, the way
  the daemon would play it.

Mechanics worth keeping for graduation: transitions ride explicit
`NSAnimationContext` groupings (window `alphaValue`, view frames via
`animator`) and nested actions-enabled `CATransaction`s (bar/dot layer
opacity/frame), so CA interpolates in the render server — the 20 Hz pump only
*starts* transitions and finishes deferred hides (`orderOut` after the fade).
The pump's per-tick `setDisableActions:` stays as #25 decreed. `glass_pulse`
keeps its bars, so `f` doesn't apply to it; a hide that starts from
processing freezes the dots and fades the capsule out around them.

## Motion smoke-test findings (2026-07-17, scripted run — pre-HITL)

- Every path exercised end-to-end (fade/materialize show+hide, crossfade,
  morph, swell, `j` demo, quick re-press mid-hide): no crash, clean quit.
- Screencaptures confirm real interpolation, not hard cuts: a mid-hide frame
  catches the capsule at partial alpha; a mid-crossfade frame catches dots at
  partial opacity over fading bars; a mid-morph frame catches the bars
  gathered onto the dot positions.
- Animator-driven window/view animations run fine inside the pump's
  disabled-actions transaction (they're explicit animations, unaffected by
  `setDisableActions:`).

## Verdict (#44 — motion)

_Pending HITL — pick `a`/`f` candidates, `u` for slow-mo, then `j` to watch
the whole lifecycle; record the winner here._
