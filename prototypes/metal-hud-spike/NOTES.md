# metal-hud-spike — the question

**Throwaway spike** for wayfinder ticket
[Spike: transparent CAMetalLayer SDF pass on the HUD panel from pure Zig](https://github.com/dbgeek/type-wave/issues/356)
(map [#355](https://github.com/dbgeek/type-wave/issues/355)). Delete it once the MetalChrome ticket lands.

Can the HUD panel host a transparent `CAMetalLayer` and draw the locked track-B shader
(`prototypes/hud-micro-motion`: goo Always 5 pt, glow 0.75) at display rate, from pure Zig
through the ObjC runtime, without breaking the focus-avoidance recipe?

## How to run

    cd prototypes/metal-hud-spike
    PATH=/usr/bin:$PATH zig build          # inside `nix develop`
    ./zig-out/bin/metal-hud-spike          # interactive: letters + Enter
    HUD_SPIKE_BENCH=1 ./zig-out/bin/metal-hud-spike   # scripted pacing/cost run (~20 s)

Interactive commands: `s` show, `h` hide, `b` bars, `d` dots (gather), `l` CADisplayLink
pacing, `t` 120 Hz timer pacing, `w`/`n` whisper/normal voice, `g` glow, `r` stats, `q` quit.

## Design

- `src/hud.metal`: the prototype's WebGL fragment shader ported to MSL. It draws one
  full-screen triangle, and the uniforms (1760 bytes) go in via `setFragmentBytes`, so there
  are no buffers.
- `src/main.zig`: the daemon's panel recipe verbatim, sized to a 340×50 drawing region
  (the pill plus room for glow and the unfurl spring), with the pill centre where the daemon
  puts it. The scene is a subset of the prototype's engine: glide, organic newest bar,
  loudness opacity, edge dissolve, ripple, unfurl, gather, squash & stretch.
- Everything runs on the main thread under `CFRunLoopRun`, as in the daemon. Stdin arrives
  through a `CFFileDescriptor` run-loop source, so there are no threads.

## Verdict (2026-09-25, M1 · 1680×1050 @ 60 Hz, not ProMotion)

Bench output (`late` counts gaps > 1.5 × 8.3 ms, so at 60 Hz it counts every frame; ignore it):

    link · bars    fps 59.4  max gap 45.8 ms  cpu 8.76%  build+encode  513 µs/frame
    link · dots    fps 60.2  max gap 27.0 ms  cpu 6.66%  build+encode  328 µs/frame
    timer · bars   fps 59.8  max gap 34.9 ms  cpu 6.35%  build+encode 7919 µs/frame
    timer · dots   fps 59.3  max gap 34.5 ms  cpu 5.99%  build+encode 8679 µs/frame
    hidden         fps  0.0                   cpu 0.42%

- **Metal from pure Zig: PROVEN.** `MTLCreateSystemDefaultDevice`, the runtime MSL compile
  (`newLibraryWithSource:options:error:`), the pipeline, and per-frame encode + present all
  work through typed `objc_msgSend` casts, including the struct-by-value `MTLClearColor`,
  `CGSize` and `CAFrameRateRange` arguments. The runtime compile costs **~640 ms** once at
  startup. Do it at Chrome init, not on the first press. (A precompiled `.metallib` via
  `newLibraryWithData:` is the fix if that ever matters.)
- **Transparent compositing: PROVEN.** On a nonactivating borderless panel, the layer's
  premultiplied output composites cleanly over the live desktop: glow halo, edge dissolve and
  loudness opacity all read as in the prototype, with no ghost outline and no window shadow.
  Semantic colours resolved per frame (`labelColor` / `secondaryLabelColor` → sRGB) work.
- **Pacing: CADisplayLink wins, and the timer is disqualified.** `NSScreen
  displayLinkWithTarget:selector:` works from a runtime target class (the `menu.zig` recipe)
  under plain `CFRunLoopRun`, holds display rate, and pauses and resumes with the pill.
  The 120 Hz `CFRunLoopTimer` over-asks a 60 Hz display: `nextDrawable` **blocks the main
  thread ~8 ms per frame** waiting for a drawable. In the daemon that thread services the
  Talk Key event tap, so the timer is out.
- **Cost:** ~0.3–0.5 ms of main-thread CPU per frame to build + encode. The process runs at
  **~6.5–9 % of one core while visible** and ~0 when hidden (0.42 % is the bench script's own
  20 Hz timer). Acceptable for a pill shown only while dictating. The obvious trim for
  MetalChrome is to resolve the semantic colours on appearance change or show, not every
  frame. GPU cost was not measured (`powermetrics` needs sudo; that goes in the acceptance
  pass).

### Still open (HITL, needs a human at the Mac)

- [ ] **Focus:** with the spike running, type into a terminal and an Electron app. Key focus
      must never move.
- [ ] **Light backdrop and full-screen apps:** only a dark terminal backdrop was captured.
- [ ] **ProMotion:** this Mac is 60 Hz, so a 120 Hz judder check needs a ProMotion display.
      The display link is set to 60–120 preferred 120, so it should follow.
