# Waveform HUD spike — the question

**Throwaway prototype** for wayfinder ticket #25 ("Prototype the waveform pill
(scrolling bars + processing animation via ObjC runtime)", map #24). Delete or
graduate once the questions below are answered.

## Question

The map's destination is a **silent** pill: no text ever, a scrolling bar
waveform of live mic volume while recording, a green processing animation held
over the Insertion after Talk Key release.

- **Q1 — mechanism.** Is **CALayer-per-bar** (a fixed row of plain CALayers
  whose frames the render pump pokes each tick — no view subclass, no
  `drawRect:`, no `objc_allocateClassPair`) enough for both the scroll and the
  processing animation, purely via the ObjC runtime from Zig? (Fallbacks if
  not: CAShapeLayer path, then an NSView subclass.)
- **Q1b — pump rate.** Is the daemon's existing **20 Hz** render pump smooth
  enough, or does the rate need to rise (or CA's implicit animations need to
  stay on as free interpolation)? Both are live-toggleable to compare.
- **Look (HITL).** Bar count/width/gap, pill size, colour scheme, which green
  processing animation (wave / dots / breathe), and scroll feel — react to the
  running artifact.

## Design

- **`wave.zig`** — the pill. Same panel + focus-avoidance recipe as
  `src/hud.zig` (proven by #20), minus the NSTextField. `max_bars` CALayers are
  created once; a Look preset uses a prefix of them and hides the rest. The
  scroll is a shifting height array — bars never move, heights march left.
  Colour/visibility changes are cached per (mode, scheme, variant) so a tick is
  only height pokes, wrapped in a `CATransaction` with implicit actions
  disabled (toggleable).
- **`main.zig`** — the harness. Producers push one level per **50 ms** (the
  real Capture buffer cadence) into a lock-guarded queue: either a synthetic
  speech envelope (talk / whisper / silence, in linear RMS) or a **live
  AudioQueue mic tap** trimmed from `src/capture.zig`. The render pump (a
  CFRunLoopTimer on the main thread, 20/30/60 Hz switchable by re-creating the
  timer) drains the queue and pokes the layers. Main thread runs
  `CFRunLoopRun` — same as the daemon.
- **Level → bar mapping** (the knob ticket #26 owns): dBFS with a floor,
  −60 dB → flat, −10 dB → full bar, in `levelToNorm`. Whispers (~−48..−34 dBFS)
  land at roughly a quarter to half pill height — the "whisper visibly moves
  the bars" product goal, testable with `w` (synthetic) or `m` (real mic).

## How to run

    cd prototypes/waveform-hud
    zig build run          # inside `nix develop`

A small transparent waveform appears bottom-centre (250x38, fine bars, no pill
background — the first-reaction defaults), scrolling a synthetic "talking"
voice. Commands (letter + Enter in the terminal):

    r  recording (scrolling waveform)      p  processing (green, post-release)
    h  hide the pill                       t/w/s  synthetic voice: talk/whisper/silence
    m  toggle LIVE microphone input        1/2/3  bars: fine / thin / medium
    c  cycle scheme (transparent /         z  cycle size 250x38 / 300x48 / 420x60
       red pill / dark pill)               f  cycle render pump 20 -> 30 -> 60 Hz
    d  cycle processing animation          a  toggle CA implicit animations
       (wave / dots / breathe)             q  quit

`m` performs real input IO on first use → macOS Microphone prompt, attributed
to the terminal (same TCC behaviour as the cli-dictation spike).

React to: whisper visibility (`w`/`m`), scroll feel at 20 vs 60 Hz (`f`) and
with implicit animations (`a`), bar preset (`1/2/3`), scheme (`c`), size (`z`),
and which processing animation wins (`d`).

## Verdict

_Pending the HITL run._

- **Q1 — mechanism:** builds + links clean against the pinned toolchain
  (AppKit / QuartzCore / AudioToolbox via the ObjC runtime, zero shims); the
  live run is the proof. _(fill in)_
- **Q1b — pump rate:** _(fill in: 20 Hz enough? implicit anims on or off?)_
- **Look:** _(fill in: bar preset, scheme, size, processing variant, history
  depth / scroll feel)_
