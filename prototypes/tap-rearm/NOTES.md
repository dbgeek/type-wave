# Tap re-arm spike — the question

**Throwaway prototype** for wayfinder ticket [#129](https://github.com/dbgeek/type-wave/issues/129),
part of map [#126](https://github.com/dbgeek/type-wave/issues/126) ("All macOS grants approved in
one pass — zero restarts"). Delete or graduate once #129 is answered.

## Question

[docs/research/macos-tcc-live-grant-pickup.md](../../docs/research/macos-tcc-live-grant-pickup.md)
(#127, on branch `research/tcc-live-grant-pickup`) predicts the answers from primary sources but
flags three things as **unverified in our own code** (its §8 "Open / unverified"). This spike
empirically settles them on real hardware:

1. **Input Monitoring re-arm** — after granting Input Monitoring to an already-running process,
   does `CGEventTapEnable` on the existing (created-while-denied) port ever bring the tap live
   (**path A** — today's `daemon.zig:680` mechanism), or does it require tearing the tap down and
   calling `CGEventTapCreate` fresh (**path B**)? Research verdict: A is provably inert, B works.
2. **PostEvent live landing** — the load-bearing unknown. Does a synthesized `CGEventPost` actually
   deliver to the Focused Target after Accessibility is granted live, given there is **no uncached
   probe** to lean on (`CGPreflightPostEventAccess` may stay stale-`false` forever)?
3. **Headless Sequoia+ trap** — does setting **Accessory activation policy** before the first grant
   probe clear the `CGPreflightPostEventAccess()==false`-despite-grant bug that a pure background
   process (no `NSApplication`) hits on macOS 15+? (`daemon.zig`'s headless path, `menu_up == false`,
   never brings up `NSApplication` today.)

## Design

Single self-contained Zig binary, deliberately **not** reusing `src/tap.zig` / `src/insert.zig` —
same "portable spike, frozen snapshot" posture as `prototypes/insertion-spike`. Two threads:

- **Main thread** owns the run loop (`CFRunLoopRunInMode` in a tight 0.1s-slice loop) and performs
  every tap mutation and event post itself — `CGEventTapCreate`/recreate must run on the thread whose
  run loop services the tap (the same constraint `tap.zig`'s own doc comments state); keeping the
  synthetic post there too avoids a cross-thread confound.
- **Director thread** drives the interactive protocol (prompts, timing, stdin) and hands the main
  thread one of three `Action`s (`try_a`, `try_b`, `quit`) via atomics, blocking for the result.

**Self-detection trick for PostEvent:** the tap's mask includes `keyDown`/`keyUp` (not just
`flagsChanged`), and every synthetic post is tagged via `CGEventSourceSetUserData` (matching
`tap.zig`'s `self_event_tag = -27469`). If the tap observes its own tagged `keyDown`, that's an
**objective, in-process signal** that the post reached the HID event stream at all — independent of
whether it visibly landed in a focused text field, which still needs a human to eyeball. Both
signals are recorded per attempt.

**Phase 2's trigger is a real key press, not Enter-in-Terminal.** The first version of this spike
prompted "press Enter in Terminal to fire the post" — which is wrong: pressing Enter in Terminal
re-focuses Terminal, so the synthetic keystroke lands there instead of wherever the human actually
wanted to watch. Fixed: the director *arms* the attempt, then the human presses+releases
**Right-Option** (the real Talk Key) while their target app stays focused; the tap's own callback —
already running on the correct thread — fires `postSyntheticKeystroke()` directly on that release
edge. This also doubles as a second, more forgiving liveness check on the tap itself (a 20s window
per attempt, vs. Phase 1's tighter confirmation).

**Headless-bug comparison:** `--accessory` sets `NSApplicationActivationPolicyAccessory` (same call
`appkit.zig`'s `app()` makes) before the first grant probe; without the flag, the binary behaves like
today's headless daemon path (no `NSApplication` at all). Run both ways to compare.

## Build

```sh
cd prototypes/tap-rearm
zig build
```

Confirmed building clean once (2026-07-19) in this sandboxed session: `zig build` produced
`zig-out/bin/tap-rearm`, a valid arm64 Mach-O executable. Every other attempt in this same
session's shell hit `xcrun --show-sdk-path -> error: unable to find sdk: 'macosx'` at the
**configure** step — even though the SDKs exist on disk under
`/Library/Developer/CommandLineTools/SDKs/`, and the same failure reproduces on the sibling
`prototypes/insertion-spike`. That looks like an `xcrun` SDK-cache quirk specific to this
background job's shell, not the code — semantic correctness of every change here was cross-checked
with `zig build-obj src/main.zig -target aarch64-macos` (full type-check + codegen, no
linking/SDK lookup needed), which has compiled clean on every revision. **Run `zig build` in your
own interactive terminal**, where it has built and run successfully already.

**Compat note for whoever touches this next:** this Zig nightly (`0.17.0-dev.1267+300116b02`)
has dropped `std.process.args()`/`ArgIterator` entirely — there's no argv-reading API left in
`std` at all. `--accessory` was originally a CLI flag; it's now the `ACCESSORY` env var instead
(`std.c.getenv`, same pattern `cli-dictation`'s `OPENAI_API_KEY` lookup already uses).

## Run protocol

**Grants persist across runs of the same binary.** If you've run `tap-rearm` before (e.g. while
debugging the build), Input Monitoring and/or Accessibility may already be granted to it — the
preflight lines at startup will read `true` from the very first tick. That's not a bug, but it
means Phase 1 won't exercise the interesting path-A-vs-path-B question, and Phase 2's "baseline"
won't be a clean pre-grant case. **Revoke both** in System Settings > Privacy & Security >
Input Monitoring / Accessibility before a run if you want a clean test of either.

**Protocol 1 — Input Monitoring re-arm (path A vs B).** With Input Monitoring **denied**:

```sh
./zig-out/bin/tap-rearm
```

Follow Phase 1's prompts: grant Input Monitoring while the loop polls, then press an Option key
within the 15s confirmation window when asked (it retries once more if you miss it). Record which
path (A or B) reported `CGEventTapIsEnabled==true`, and whether the real-event confirmation
succeeded (`[LIVE]` vs `[WARN]`).

**Protocol 2 — PostEvent live landing.** Continues automatically into Phase 2 in the same run, with
Accessibility **denied** for a clean baseline. Each attempt is triggered by a real key press, not by
switching back to Terminal: click into a scratch text field (TextEdit/Notes) and leave it focused,
press Enter in Terminal only to *arm* the attempt, then go press+release **Right-Option** (the real
Talk Key) without touching Terminal again — that's what fires the synthetic post, so your target
app never loses focus at the moment it matters. Run the baseline attempt, then grant Accessibility
and run the post-grant attempt(s). Record, per attempt: `self-tap-saw` (objective, from the spike's
own tap) and `human-confirmed-landed` (what you actually saw in the text field), plus the preflight
value before/after.

**Protocol 3 — Headless Sequoia+ trap.** Run the binary twice, comparing the printed
`PostEvent preflight` line and Phase 2's post-grant `self-tap-saw` outcome:

```sh
./zig-out/bin/tap-rearm          # headless default — reproduces the bug if present
ACCESSORY=1 ./zig-out/bin/tap-rearm # sets Accessory policy before the first probe — the proposed fix
```

If the unset run shows `preflight after=false` (or `self-tap-saw=false`) post-grant while the
`ACCESSORY=1` run shows `true`/`true`, that confirms §5 of the research doc and the fix daemon.zig's
headless path needs.

## Answer

_(record path A/B result + timing, PostEvent landing outcome, and whether `--accessory` clears the
headless trap — then close #129 and update map #126's Decisions so far)_
