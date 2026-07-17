# Liquid Glass HUD spike — the question

**Throwaway prototype** for wayfinder ticket #41 ("Prototype the Liquid Glass
HUD capsule", map #39). Delete or graduate once the look is decided.

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
       glass pulse)                        z  cycle size 420x60 / 340x52 / 300x44
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

## Verdict

_Pending HITL rounds — react to the running artifact and record the winning
(style, tint, bar color, radius, shadow, processing animation) here._
