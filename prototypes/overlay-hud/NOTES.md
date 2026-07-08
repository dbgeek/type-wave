# Overlay HUD spike — the question

**Throwaway prototype** for wayfinder ticket #20 ("Prototype the live-partials
overlay HUD (AppKit via ObjC runtime)"). Delete or graduate once the questions
below are answered.

## Question

Open the map's deferred **"AppKit via the ObjC runtime's C interface"** front —
the Wispr-Flow-style floating pill that shows live **Partial Transcripts**.

- **Q1 — mechanism.** Can we drive a borderless, always-on-top `NSPanel` + text,
  purely through the ObjC runtime C API (`objc_getClass` / `sel_registerName` /
  `objc_msgSend`) from Zig — **no Swift, no ObjC `.m` shims** — reusing the exact
  msgSend-cast pattern already proven for NSPasteboard in
  `prototypes/insertion-spike/src/insert.zig`?
- **Q2 — focus.** Does an always-on-top panel coexist with the **Focused Target
  without stealing focus**? Stealing focus (or key/main status) would break
  Insertion, so the panel must float and update while another app stays focused.

## Design

- **`hud.zig`** — the panel, built entirely via the ObjC runtime. Extends the
  insertion-spike msgSend shims from NSString/NSPasteboard to NSPanel /
  NSTextField / NSColor / NSScreen / CALayer. The pill is the content view's
  `CALayer` (rounded, translucent), recoloured by state (charcoal idle → red
  recording → green final); a centred `NSTextField` label carries the text.
- **`main.zig`** — an **accessory-policy** `NSApplication` (no Dock icon, no
  forced activation) + `finishLaunching`, then **`CFRunLoopRun()`** — the same
  call `src/tap.zig` makes, confirming the HUD lives on the daemon's existing
  main-thread run loop rather than needing `[NSApp run]`. A background thread
  simulates the read-loop thread's streaming partials into a mutex-guarded
  buffer; a **`CFRunLoopTimer`** on the main thread reads it and pokes the HUD —
  the exact producer(read-loop-thread) → render(main-thread) handoff the real
  daemon needs.

**The focus-avoidance recipe (the Q2 answer, encoded in the flags):**
1. `NSApplicationActivationPolicyAccessory` — the app never force-activates.
2. `NSWindowStyleMaskNonactivatingPanel` in the style mask.
3. Show with **`orderFrontRegardless`**, never `makeKeyAndOrderFront:`; never
   call `activateIgnoringOtherApps:`.
4. `setBecomesKeyOnlyIfNeeded:YES` + `setFloatingPanel:YES` (NSPanel).
5. `setIgnoresMouseEvents:YES` — clicks pass straight through to the app below.
6. `setLevel:NSStatusWindowLevel` + all-Spaces / full-screen-auxiliary
   collection behavior — floats above, and over full-screen apps.

## Verdict

**Q1 — YES, proven.** Builds + links clean against the pinned toolchain
(`nix develop -c zig build`) — AppKit / QuartzCore / CoreFoundation /
CoreGraphics through the ObjC runtime, zero Swift/ObjC shims. And it **runs**:
a 3 s smoke run executed the *entire* runtime path without crashing —
`sharedApplication` + accessory policy + `finishLaunching`, the `[[NSScreen
mainScreen] frame]` **NSRect struct return over the arm64 ABI**, `NSPanel`
construction with the borderless+nonactivating masks, the `CALayer` rounding,
the `NSTextField` label, `orderFrontRegardless`, and the `CFRunLoopTimer` pump
spinning on `CFRunLoopRun`. The msgSend-cast pattern scales from NSPasteboard
to the whole AppKit surface a HUD needs. (arm64 only — the only target that
matters; NSRect is an HFA-of-4-f64, so plain `objc_msgSend` passes/returns it in
v0–v3 with no `_stret`.)

**Q2 — the recipe is in place; the visual confirmation is a human live-test.**
The six flags above are the documented, conventional way to keep a HUD panel off
the focus/key path; the daemon can `orderFrontRegardless` and animate the pill
while another app stays focused. Not yet confirmed **visually** from here
(rendering + "keep typing in another app while the pill animates, keystrokes
must keep landing there" needs eyes on the display) — same status as the
daemon's other interactive paths (#18/#19), left for a human pass:

    cd prototypes/overlay-hud && nix develop .. -c zig build run
    # pill appears bottom-centre, cycling idle→recording→final;
    # click into a terminal/browser/Cursor and keep typing — focus must not jump.

## Graduation

Fold `hud.zig` into `src/` and swap the simulated producer for `session.zig`'s
real Partial Transcript stream (read-loop thread → main-thread render pump),
deciding how it supersedes/augments the #18 sound cues and how it shows/hides on
Utterance boundaries. Tracked as its own wayfinder ticket. `NSStatusItem`
menu-bar presence and the `.app` bundle now ride a **proven** AppKit-from-Zig
path (was the risk behind the distribution-packaging fog). Then delete this
prototype.
