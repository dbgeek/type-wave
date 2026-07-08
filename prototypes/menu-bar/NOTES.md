# Menu-bar status-item spike — the question

**Throwaway prototype** for wayfinder ticket
[#31](https://github.com/dbgeek/type-wave/issues/31) ("Prototype the status
item + menu (NSStatusItem beside CFRunLoopRun)", map
[#29](https://github.com/dbgeek/type-wave/issues/29)). Delete or graduate once
the questions below are answered.

## Question

Map #29's destination grows an `NSStatusItem` in the *existing* daemon process
— no separate settings app. So:

- **Q1 — coexistence.** Does an `NSStatusItem` work beside the daemon's bare
  `CFRunLoopRun` main loop (src/tap.zig) with only `finishLaunching` +
  accessory activation policy — the exact bring-up `src/hud.zig` already proves
  — or does it need `[NSApp run]` / a different activation policy? And does that
  sit happily next to the HUD + LaunchAgent setup?
- **Q2 — action dispatch.** Menu items dispatch to a *target object*. We own no
  ObjC classes, so one must be minted at runtime
  (`objc_allocateClassPair` + `class_addMethod`, C-ABI Zig fns as methods) —
  the one runtime facility the waveform spike (#25) explicitly did **not** need.
  Does it work from Zig?
- **Q3 — the modal.** Does an `NSAlert` + `NSSecureTextField` accessory
  (Set API Key…) — which spins its own nested modal loop — coexist with the
  status item, and can it take focus from an accessory (LSUIElement-style) app?
- **Look (HITL).** Checkmark radio submenus for the enums, curated-preset
  submenus for `model`/`language`/`delay`, the two-tier (healthy / dimmed
  needs-attention) icon, the disabled status line, menu wording/order. React to
  the running artifact.

## Design

- **`src/main.zig`** — the whole spike. Mirrors `src/hud.zig`'s ObjC-runtime
  bring-up: `sharedApplication` → `setActivationPolicy(Accessory)` →
  `finishLaunching`, then `CFRunLoopRun` (never `[NSApp run]`). Builds a
  `[[NSStatusBar systemStatusBar] statusItemWithLength:]`, a two-tier SF-Symbol
  icon (`waveform` / `waveform.slash` + alpha dim), and the full menu from
  map #29's "Menu contents": disabled status line, six checkmark radio
  submenus (Talk Key / Model / Language / Delay / Noise reduction / Insertion),
  an Overlay-HUD checkbox, Set API Key…, Pause dictation, Open config file, a
  DEBUG status-cycler, and Quit.
- **Action dispatch** — `TWMenuTarget : NSObject` is minted at runtime; each
  handler is a `callconv(.c)` Zig fn added with `class_addMethod(…, "v@:@")`.
  Radio items carry `setTag:(group*100 + option)`; `onRadio:` decodes it,
  re-syncs the group's checkmarks, and prints the settings snapshot.
- **State is in-memory only** — no `config.zon` read/write (that's the graduation
  ticket + the live-apply design #32). Every action prints the full settings
  snapshot to the terminal (prototype rule: surface the state).

## How to run

    cd prototypes/menu-bar
    nix develop ../.. --command zig build run   # (or plain `zig build run` in the dev shell)

A waveform icon appears in the menu bar near the clock. Click it to open the
menu; every action prints a settings snapshot to the terminal. **DEBUG: cycle
status** walks Ready → Reconnecting… → No API key → Input Monitoring needed,
dimming the icon on the needs-attention states. Quit from the menu (or Ctrl-C).

React to: does the icon read at a glance and do the two tiers differ clearly?
the menu wording + order; which curated presets `model`/`language`/`delay`
should offer; the checkmark submenu feel; and the Set API Key… dialog (does it
take focus, is the secure field right?).

## Verdict (2026-07-08, one HITL round)

- **Q1 — coexistence: PROVEN, with one load-bearing catch.** Builds + links
  against the pinned toolchain (AppKit / CoreFoundation via the ObjC runtime,
  zero shims) and the status item lives happily in the same process. BUT: a
  bare `CFRunLoopRun()` — what the daemon blocks on today (src/tap.zig) — spins
  the run loop yet never runs AppKit's `nextEvent → sendEvent:` dispatch, so
  status-item **clicks are never routed and the menu never pops**. The HUD
  escapes this only because it never receives events. **Fix: block on
  `[NSApp run]` instead.** It runs the same main run loop (so the CGEventTap
  source + the HUD's `CFRunLoopTimer` still fire under it) *plus* the AppKit
  event dispatch the status item needs. Confirmed: the menu pops and tracks
  under `[NSApp run]`. This is a graduation constraint for #34 — a swap in
  `daemon.zig`/`tap.zig`, not an addition.
- **Q2 — action dispatch: PROVEN.** `objc_allocateClassPair` / `class_addMethod`
  / `objc_registerClassPair` work from Zig; `TWMenuTarget`'s `callconv(.c)`
  handlers fire on click — checkmarks move, snapshots print. The runtime-minted
  target class is the graduation crib for wiring real menu actions.
- **Q3 — the modal: PROVEN.** `NSAlert` + `NSSecureTextField` accessory opens
  and takes focus/keystrokes — the app calls `activateIgnoringOtherApps:` first
  (an accessory app is otherwise inactive, so the modal would open unfocused).

- **Look (decided in the HITL round):**
  - **Two-tier icon accepted** — SF Symbol `waveform` (healthy) vs.
    `waveform.slash` + alpha 0.35 (needs-attention: paused / no key / permission
    missing). Reads at a glance.
  - **Menu order/wording accepted** as built (status line → radio submenus →
    Overlay HUD → Set API Key… / Pause / Open config → Quit).
  - **Curated presets decided:** Model = `gpt-realtime-whisper` only (others
    hand-edited); Language = `en` / `sv` / `auto-detect`; Delay =
    `low` / `medium` / `high`. Talk Key / Noise reduction / Insertion are the
    closed enums (tap.TalkKey / Settings.NoiseReduction / insert.Method).

**Disposition:** code stays in `prototypes/menu-bar/`. Graduation crib for #34 —
what graduates: the `[NSApp run]` swap, the status-item + two-tier-icon recipe,
the runtime `TWMenuTarget` action-dispatch pattern, the checkmark radio-submenu
builder, and the `NSAlert` secure-field dialog. The in-memory settings become
the mutable `Settings` + `config.zon` rewrite of the live-apply design (#32).
