//! hud.zig — the silent waveform pill, driven PURELY through the ObjC runtime
//! C API (objc_getClass / sel_registerName / objc_msgSend) from Zig. No Swift, no
//! ObjC shim .m files. The panel + focus-avoidance recipe graduated from
//! prototypes/overlay-hud (wayfinder #20/#22); the bare-marks look — labelColor bars /
//! secondaryLabelColor dots in a 300×22 sliver, no glass, no accent design — from ADR 0002
//! (#41/#44); and the micro-motion from prototypes/hud-micro-motion (ADR-0014, map #355):
//! every mark drawn by one Metal SDF pass at display rate, melting together through a
//! smooth-union goo and carrying a soft glow in its own colour. The HUD shows **no text,
//! ever**: while recording it scrolls live mic volume as bars; after the Talk Key release
//! the bars gather into three neutral dots that bounce until the Insertion resolves.
//!
//! The msgSend pattern (cast &objc_msgSend to a typed fn-pointer per call site) is
//! the exact one proven for NSPasteboard in src/insert.zig, extended to NSPanel /
//! NSColor / NSScreen / CAMetalLayer / CADisplayLink / the Metal pipeline (spike #356).
//!
//! # How it composes with the daemon
//!
//!   - **The module is split at the HUD Chrome seam.** `Hud(Chrome)` is the pump: the
//!     mutex-guarded state producers publish into, the pure `Sequencer`, and the per-tick
//!     composition rules — it holds no AppKit handle, takes `now` as a parameter, and
//!     hands the Chrome exactly one comparable `Frame`. `MetalChrome` is the production
//!     adapter and the only place ObjC is spoken; `FakeChrome` (below, in the tests)
//!     records frames. The rules that decide what the user actually sees — the cue arming
//!     guard, the recording/processing preemption, the degraded-pulse downgrade, the
//!     pulse-to-hide handoff — therefore all run under `zig build test`.
//!   - **Every Frame is a window op plus a Scene** (ADR-0014, #358): the locked micro-motion
//!     as a pure list of shapes. The pump stamps the Sequencer's decisions into a
//!     `SceneState` as timestamps, and `SceneState.scene(now, reduce_motion)` turns them into
//!     geometry for any `now`, so the display-rate Chrome draws without deciding anything.
//!   - **All AppKit calls stay on the main thread.** The daemon's main thread runs
//!     `CFRunLoopRun` (src/tap.zig) servicing the Talk Key tap (no `[NSApp run]` — proven by
//!     #20). The Chrome adds two things to that same loop: `NSScreen`'s display link, which
//!     runs the pump once per display frame while the pill is on screen and is paused
//!     otherwise, and a run-loop source the pump's `wake` signals from any thread, so a hidden
//!     pill renders on the publishing edge. `MetalChrome.init` + `startPump` + every `paint`
//!     run there; the cadence reads the clock and trampolines into `Hud.render(now)`.
//!   - **Producers publish from any thread.** `publish(state)` sets the lifecycle
//!     state; `pushLevel(rms)` queues one raw linear RMS sample per 50 ms Capture
//!     buffer from the audio queue's thread. Both are mutex-guarded, no AppKit.
//!     The pump drains the queue into the Scene's scroll — a queue, not a latest-value
//!     slot, so the scroll advances exactly one bar per buffer regardless of frame
//!     jitter (#26) — and the Scene glides between samples at display rate.
//!   - **Headless and Metal-less degrade cleanly.** `MetalChrome.init` fails when there is
//!     no display (`[NSScreen mainScreen]` is nil — e.g. a bare-SSH run), no Metal device,
//!     or a shader that will not build; the daemon then never starts the pump and leaves it
//!     disabled, so `isOn` reports the truth and the Feedback Surface falls back to
//!     sound-only (#18) without failing startup. That fact lives in the adapter, where it
//!     belongs — it is a fact about AppKit and Metal handles, not about the pump.
//!
//! ABI note: Apple Silicon (arm64) only. NSRect is a homogeneous aggregate of four
//! CGFloat(=f64), so it rides in v0–v3 and plain objc_msgSend handles both passing and
//! returning it (arm64 has no objc_msgSend_stret). type-wave is macOS-only on this Mac.

const std = @import("std");
const appkit = @import("appkit.zig");

// ---- ObjC runtime primitives (same as insert.zig) ---------------------------
const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
// The display link's runtime-minted target class (the menu.zig recipe).
extern "c" fn objc_allocateClassPair(superclass: id, name: [*:0]const u8, extra: usize) id;
extern "c" fn objc_registerClassPair(c: id) void;
extern "c" fn class_addMethod(c: id, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;

inline fn cls(name: [*:0]const u8) id {
    return objc_getClass(name);
}

// os_unfair_lock: zero-initializable macOS spinlock (libSystem). Self-contained — no
// std.Io handle needed on the render/publish path (std.Thread.Mutex is gone on this
// Zig nightly and std.Io.Mutex needs an Io instance). Same guard the prototype used.
const os_unfair_lock = extern struct { _opaque: u32 = 0 };
extern "c" fn os_unfair_lock_lock(lock: *os_unfair_lock) void;
extern "c" fn os_unfair_lock_unlock(lock: *os_unfair_lock) void;

// ---- typed objc_msgSend shims, one per argument shape we need ----------------
// [self op]  -> id
inline fn msg(self: id, op: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}
// [self op]  -> void
inline fn msgv(self: id, op: [*:0]const u8) void {
    const f: *const fn (id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op));
}
// [self op]  -> double
inline fn msgF64(self: id, op: [*:0]const u8) f64 {
    const f: *const fn (id, SEL) callconv(.c) f64 = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}
// [self op:a]  (id arg) -> void
inline fn msg1v(self: id, op: [*:0]const u8, a: id) void {
    const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), a);
}
// [self op:a]  (id arg) -> id
inline fn msg1(self: id, op: [*:0]const u8, a: id) id {
    const f: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op), a);
}
// [self op:flag]  (BOOL) -> void
inline fn msgBool(self: id, op: [*:0]const u8, b: bool) void {
    const f: *const fn (id, SEL, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), b);
}
// [self op:n]  (NSInteger) -> void
inline fn msgLong(self: id, op: [*:0]const u8, n: c_long) void {
    const f: *const fn (id, SEL, c_long) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), n);
}
// [self op:n]  (NSUInteger) -> void
inline fn msgULong(self: id, op: [*:0]const u8, n: c_ulong) void {
    const f: *const fn (id, SEL, c_ulong) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), n);
}
// [self op:n]  (NSUInteger) -> id — objectAtIndexedSubscript:
inline fn msgIdx(self: id, op: [*:0]const u8, n: c_ulong) id {
    const f: *const fn (id, SEL, c_ulong) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op), n);
}
// [self op:x]  (CGFloat) -> void
inline fn msgDouble(self: id, op: [*:0]const u8, x: f64) void {
    const f: *const fn (id, SEL, f64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), x);
}
// [self op:rect]  (NSRect/CGRect) -> void
inline fn msgRect(self: id, op: [*:0]const u8, r: NSRect) void {
    const f: *const fn (id, SEL, NSRect) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), r);
}
// [self respondsToSelector:@selector(op)]
inline fn respondsTo(self: id, op: [*:0]const u8) bool {
    const f: *const fn (id, SEL, SEL) callconv(.c) bool = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName("respondsToSelector:"), sel_registerName(op));
}
// [NSString stringWithUTF8String:s] — autoreleased.
inline fn nsString(s: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSString"), sel_registerName("stringWithUTF8String:"), s);
}

// ---- Cocoa geometry ---------------------------------------------------------
/// NSRect == {origin{x,y}, size{w,h}}; flat here, identical layout. Four f64 = an HFA,
/// so it is passed/returned in SIMD regs by the arm64 C ABI (Zig lowers this for us).
const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
/// CGSize, MTLClearColor and CAFrameRateRange ride by value the same way (HFAs).
const CGSize = extern struct { w: f64, h: f64 };
const MTLClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
const CAFrameRateRange = extern struct { minimum: f32, maximum: f32, preferred: f32 };

/// [[NSPanel alloc] initWithContentRect:styleMask:backing:defer:]
inline fn makePanel(rect: NSRect, style: c_ulong, backing: c_ulong) id {
    const allocd = msg(cls("NSPanel"), "alloc");
    const f: *const fn (id, SEL, NSRect, c_ulong, c_ulong, bool) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(allocd, sel_registerName("initWithContentRect:styleMask:backing:defer:"), rect, style, backing, false);
}
/// [NSScreen mainScreen] — nil when there is no display (the headless signal).
inline fn mainScreen() id {
    return msg(cls("NSScreen"), "mainScreen");
}
/// [screen frame] — NSRect returned by value (HFA, v0–v3).
inline fn screenFrame(screen: id) NSRect {
    const f: *const fn (id, SEL) callconv(.c) NSRect = @ptrCast(&objc_msgSend);
    return f(screen, sel_registerName("frame"));
}

// ---- window/style constants (AppKit headers) --------------------------------
const NSWindowStyleMaskBorderless: c_ulong = 0;
const NSWindowStyleMaskNonactivatingPanel: c_ulong = 1 << 7; // the key flag: never becomes active
const NSBackingStoreBuffered: c_ulong = 2;
const NSStatusWindowLevel: c_long = 25; // floats above ordinary windows
// Collection behavior: show on every Space, over full-screen apps, and don't move it.
const NSWindowCollectionBehaviorCanJoinAllSpaces: c_ulong = 1 << 0;
const NSWindowCollectionBehaviorStationary: c_ulong = 1 << 4;
const NSWindowCollectionBehaviorFullScreenAuxiliary: c_ulong = 1 << 8;

// ---- Metal / QuartzCore (ADR-0014) -------------------------------------------
extern "c" fn MTLCreateSystemDefaultDevice() id;
extern "c" fn CACurrentMediaTime() f64; // the display link's clock
const MTLPixelFormatBGRA8Unorm: c_ulong = 80;
const MTLLoadActionClear: c_ulong = 2;
const MTLStoreActionStore: c_ulong = 1;
const MTLPrimitiveTypeTriangle: c_ulong = 3;

// ---- the wake source (CFRunLoopSource, version 0) -----------------------------
// Signalled from any thread, performed on the main run loop — how a publish reaches a
// hidden pill whose display link is paused.
const CFRunLoopRef = ?*anyopaque;
const CFRunLoopSourceContext = extern struct {
    version: c_long = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copyDescription: ?*const anyopaque = null,
    equal: ?*const anyopaque = null,
    hash: ?*const anyopaque = null,
    schedule: ?*const anyopaque = null,
    cancel: ?*const anyopaque = null,
    perform: ?*const fn (?*anyopaque) callconv(.c) void = null,
};
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopSourceCreate(alloc: ?*anyopaque, order: c_long, context: *CFRunLoopSourceContext) ?*anyopaque;
extern "c" fn CFRunLoopAddSource(rl: CFRunLoopRef, source: ?*anyopaque, mode: ?*anyopaque) void;
extern "c" fn CFRunLoopSourceSignal(source: ?*anyopaque) void;
extern "c" fn CFRunLoopWakeUp(rl: CFRunLoopRef) void;
extern var kCFRunLoopCommonModes: ?*anyopaque;

// ---- the look (HUD v3 bare marks — ADR 0002, HITL-locked in #41/#44; fixed, no
// config knob). Constants recorded in docs/hud-v3-graduation.md. ------------------
const pill_w: f64 = 300;
const pill_h: f64 = 22;
const bar_w: f64 = 6;
const bar_gap: f64 = 4;
const pad_x: f64 = 20; // inner margin before the first / after the last bar
const min_bar_h: f64 = 3; // silence reads as a flat dotted line, not nothing
const max_bar_h: f64 = pill_h * 0.72; // headroom so a full bar never kisses the edge

// Dots scale with the pill so the 22 pt sliver doesn't clip them: full 12 pt dots
// with the 11 pt bounce would need ~34 pt of height. Same formulas the prototype
// proved; the −1 keeps a 1 pt margin under the bounce peak.
const dot_size: f64 = @min(12.0, pill_h * 0.4);
const dot_gap: f64 = dot_size * (10.0 / 12.0);
const dot_bounce: f64 = @min(11.0, (pill_h - dot_size) / 2.0 - 1.0);
const dots_row_w: f64 = 3 * dot_size + 2 * dot_gap; // the three-dot row, centred in the pill

// The Undo confirm/refuse cue's single centred mark (ADR-0007, #216/#226): a ~6×14 pt
// rounded bar, deliberately unlike the 26 recording bars and the 3 processing dots so an
// Undo outcome never reads as recording/thinking. Its own net-new layer family — the pill
// is `hidden` when it plays, so the distinct single-mark shape is what makes the cue
// unmistakable. Green still-bloom = confirmed, red bloom + horizontal shake = refused.
const mark_w: f64 = 6;
const mark_h: f64 = 14;

/// How many bars fit the pill. Also how much history it shows: at one level per
/// 50 ms Capture buffer, n_bars/20 seconds scroll across it (26 bars ≈ 1.3 s).
const n_bars: usize = @intFromFloat(@floor((pill_w - 2 * pad_x + bar_gap) / (bar_w + bar_gap)));

/// What the pill is doing — drives which layer family is visible. The daemon maps its
/// Utterance lifecycle onto these: `recording` on Talk Key press (scrolling waveform),
/// `processing` on release (bouncing dots, held over the whole Insertion), `hidden`
/// once the Utterance resolves (inserted, abandoned, empty, or timed out).
pub const State = enum { hidden, recording, processing };

// ---- native motion (#44/#47, graduated): the locked 0.7× timings ------------
// Show ≈0.14 s fade-in on press, bars→dots crossfade ≈0.15 s on release,
// hide ≈0.11 s fade-out on every resolution.
const motion_speed: f64 = 0.7; // the HITL-locked speed dial (#44), baked in
const show_dur: f64 = 0.20 * motion_speed;
const hide_dur: f64 = 0.16 * motion_speed;
const cross_dur: f64 = 0.22 * motion_speed;

/// The degraded-insertion amber pulse (docs/backtrack-spec.md §UX 4, ADR-0004): the
/// processing dots flash systemOrangeColor once over ~300 ms, then the normal hide fade
/// carries it out. Deliberately NOT scaled by motion_speed — the spec fixes the
/// wall-clock duration so a rare, soundless downgrade reliably registers.
const pulse_dur: f64 = 0.30;

/// A front-loaded easeOut ramp of a 0..1 fraction (the pulse/cue bloom shape): `1−(1−f)²`,
/// clamped. Shared by the degraded pulse and the Undo cue bloom so both blooms read the
/// same. Pure, unit-tested below.
fn easeOut01(fraction: f64) f32 {
    const f = std.math.clamp(fraction, 0.0, 1.0);
    return @floatCast(1.0 - (1.0 - f) * (1.0 - f));
}

/// Amber intensity (0..1) of the degraded pulse `elapsed` seconds in: an easeOut ramp
/// to full systemOrangeColor, which the following hide fade then removes, so the whole
/// event reads as one amber bloom. Pure — the one place pulse-time becomes color weight,
/// unit-tested below.
fn pulseEnvelope(elapsed: f64) f32 {
    return easeOut01(elapsed / pulse_dur);
}

// ---- the Undo confirm/refuse cue envelopes (ADR-0007, #226) ------------------
// The cue is driven from `hidden` and owns its own show→bloom→hold→hide window (unlike the
// amber pulse, which piggybacks an in-flight processing pill). These pure functions turn
// cue-time into the mark's bloom weight and horizontal shake offset; the Sequencer below
// orchestrates the window and the Scene draws the mark. Unit-tested below.

/// How long the mark blooms in / the shake plays — reuses the ~300 ms pulse feel.
const cue_bloom_dur: f64 = 0.30;
/// From cue start until the hide fade begins: the ~300 ms bloom plus a brief hold so a
/// deliberate user action reliably registers before it fades. Deliberately wall-clock
/// (not motion_speed-scaled), like the amber pulse.
const cue_shown_dur: f64 = 0.52;
/// Peak horizontal shake amplitude (± pt) of the refuse cue — the "denied" gesture.
const cue_shake_amp: f64 = 6.0;
/// Oscillations of the refuse shake over `cue_bloom_dur` (~3 over ~300 ms).
const cue_shake_osc: f64 = 3.0;

/// Bloom weight (0 none .. 1 full systemGreen/systemRed) of the cue mark `elapsed` seconds
/// in — the same easeOut ramp the amber pulse uses, so confirm and refuse both bloom once.
fn cueBloom(elapsed: f64) f32 {
    return easeOut01(elapsed / cue_bloom_dur);
}

/// Horizontal offset (pt) of the refuse shake `elapsed` seconds in: a decaying sine — ~3
/// oscillations that settle to 0 by `cue_bloom_dur`, so the refuse reads as motion (the
/// colorblind-safe half of the signal, ADR-0007), not hue alone. Zero outside the window.
fn cueShake(elapsed: f64) f64 {
    if (elapsed <= 0.0 or elapsed >= cue_bloom_dur) return 0.0;
    const p = elapsed / cue_bloom_dur; // 0..1 across the shake
    const decay = 1.0 - p; // linear settle to rest
    return cue_shake_amp * decay * @sin(2.0 * std.math.pi * cue_shake_osc * p);
}

/// The PURE decision half of the pill's motion (the #47 prototype shape,
/// graduated): fed (published state, now) once per pump tick, it decides which
/// transition starts this tick; `render` stamps it into the Scene and the Chrome
/// orders the window. It owns the window lifecycle (shown / hide deadline), so
/// neither carries lifecycle state of its own. Unit-tested below by feeding
/// (state, clock) sequences and asserting decisions.
pub const Sequencer = struct {
    /// Edge detection: published state != prev_mode starts a transition.
    prev_mode: State = .hidden,
    /// Panel ordered in — true from the show-fade start until the deferred order-out.
    shown: bool = false,
    /// Hide-fade deadline; the pump orders out once now >= deadline.
    hide_at: ?f64 = null,
    /// Degraded-insertion pulse deadline (ADR-0004): the amber tint plays until here, set
    /// by `startPulse` and stepped by `pulseStep`. Orthogonal to the window lifecycle —
    /// the pump resolves the pill to `.hidden` when it elapses and the normal fade takes over.
    pulse_at: ?f64 = null,

    /// The Undo cue's own window lifecycle (ADR-0007, #226), kept separate from `shown` /
    /// `hide_at` because the cue is driven from `hidden` and owns the pill end-to-end: it
    /// brings the pill up (show-fade), blooms + holds the mark, then hides it. While a cue
    /// is in progress the pump takes the `cueStep` path and skips `step` entirely.
    /// `cue_at` is the cue's start time (null = no cue armed); `cue_kind` its outcome;
    /// `cue_shown` guards the one-shot show fade; `cue_hide_at` the deferred order-out.
    cue_at: ?f64 = null,
    cue_kind: CueKind = .confirm,
    cue_shown: bool = false,
    cue_hide_at: ?f64 = null,

    /// Reduce Motion (ADR-0014). Off, a resolution plays converge & drop for `converge_dur`
    /// before the order-out; on, it falls back to ADR-0002's `hide_dur` fade. Set by the pump.
    reduce_motion: bool = false,

    /// What happens to the panel window this tick.
    pub const WindowFx = enum {
        none,
        show_fade, // alpha 0 → order front → fade to 1 (≈0.14 s)
        hide_fade, // converge & drop (0.30 s), or under Reduce Motion a fade to 0 (≈0.11 s); the order-out waits for the deadline
        order_out, // the hide fade has played — take the panel out, exactly once
        cancel_hide, // re-shown mid-hide-fade: snap alpha back to 1, panel never left
    };
    /// Which layer-family flip this tick performs.
    pub const MarksFx = enum {
        keep, // steady state — no visibility pokes
        bars, // cut to the waveform (a fresh Utterance)
        dots, // cut to the dots (no recording bars to fade from)
        crossfade, // release handover: bars fade out while dots fade in (≈0.15 s)
    };
    pub const Decision = struct {
        window: WindowFx = .none,
        marks: MarksFx = .keep,
    };

    pub fn step(self: *Sequencer, published: State, now: f64) Decision {
        const from = self.prev_mode;
        self.prev_mode = published;

        if (published == .hidden) {
            if (self.shown and self.hide_at == null) {
                self.hide_at = now + (if (self.reduce_motion) hide_dur else converge_dur);
                return .{ .window = .hide_fade };
            }
            if (self.hide_at) |deadline| {
                if (now >= deadline) {
                    self.hide_at = null;
                    self.shown = false;
                    return .{ .window = .order_out };
                }
            }
            return .{};
        }

        var window: WindowFx = .none;
        if (self.hide_at != null) {
            // A press landed while the hide fade was playing: cancel it — the
            // panel never left, so a snap-back, not a new show fade.
            self.hide_at = null;
            window = .cancel_hide;
        } else if (!self.shown) {
            self.shown = true;
            window = .show_fade;
        }
        const marks: MarksFx = if (published == from) .keep else switch (published) {
            .hidden => unreachable,
            .recording => .bars,
            .processing => if (from == .recording) .crossfade else .dots,
        };
        return .{ .window = window, .marks = marks };
    }

    /// Arm the one-shot amber pulse: it plays for `pulse_dur` from `now`.
    pub fn startPulse(self: *Sequencer, now: f64) void {
        self.pulse_at = now + pulse_dur;
    }

    /// One tick of the degraded-insertion pulse (ADR-0004). Independent of `step`: the
    /// Scene tints the dots while the pill is still `.processing`; this returns true on the
    /// single tick the pulse elapses, and the pump then resolves the pill to `.hidden` so
    /// `step` plays the ordinary hide around the amber dots. False when none is armed.
    /// Clears the deadline on the ending tick so it fires exactly once.
    pub fn pulseStep(self: *Sequencer, now: f64) bool {
        const until = self.pulse_at orelse return false;
        if (now < until) return false;
        self.pulse_at = null;
        return true;
    }

    // ---- the Undo confirm/refuse cue (ADR-0007, #226) -----------------------

    /// The two Undo outcomes the cue distinguishes. Both bloom the single mark once; only
    /// the refuse also shakes (motion carries the outcome, so it survives colorblindness —
    /// ADR-0007). All refuse reasons (app-changed, focus null, no-target, already-undone)
    /// collapse to `.refuse`; the specific reason is logged only (#213).
    pub const CueKind = enum { confirm, refuse };

    /// One tick of the Undo cue. `owns` is true whenever a cue is in progress — the pump
    /// takes this path and skips `step` — through the trailing order-out. `window` is the
    /// cue's own show / hide / order-out; the bloom and the refuse shake are the Scene's,
    /// computed from when the mark showed.
    pub const Cue = struct {
        owns: bool = false,
        kind: CueKind = .confirm,
        window: WindowFx = .none,
    };

    /// Arm the one-shot Undo cue of `kind`, played from `now`. The caller (the pump) only
    /// arms it while the pill is `.hidden` and no cue is already in progress; `cueStep` then
    /// owns the window until it orders out.
    pub fn startCue(self: *Sequencer, now: f64, kind: CueKind) void {
        self.cue_at = now;
        self.cue_kind = kind;
        self.cue_shown = false;
        self.cue_hide_at = null;
    }

    /// Abandon an in-flight cue without ordering out. The pump calls this when a real
    /// recording/processing pill preempts a playing cue (a Talk Key press right after the
    /// recovery chord): the normal `step` path takes over the pill this same tick, so the
    /// cue must not resume on a later hidden tick. Idempotent.
    pub fn cancelCue(self: *Sequencer) void {
        self.cue_at = null;
        self.cue_hide_at = null;
        self.cue_shown = false;
    }

    /// Drive the armed cue for `now`. Idle (`.{}`, `owns == false`) when none is armed. The
    /// lifecycle: show-fade in around the first bloom tick → bloom the mark over
    /// `cue_bloom_dur` (+ shake if refuse) → hold to `cue_shown_dur` → hide-fade → order out
    /// once past the deadline, clearing itself so it fires exactly once.
    pub fn cueStep(self: *Sequencer, now: f64) Cue {
        const start = self.cue_at orelse return .{};
        var out = Cue{ .owns = true, .kind = self.cue_kind };

        // Hiding phase: the hold has ended, the mark is fading out. Order out once past the
        // deadline (clearing the cue), else an owned tick with nothing to decide.
        if (self.cue_hide_at) |deadline| {
            if (now >= deadline) {
                self.cue_at = null;
                self.cue_hide_at = null;
                self.cue_shown = false;
                out.window = .order_out;
            }
            return out;
        }

        // Visible phase: bring the pill up on the first tick, then bloom + hold.
        if (!self.cue_shown) {
            self.cue_shown = true;
            out.window = .show_fade;
        }
        if (now - start >= cue_shown_dur) {
            // Hold done → start the hide fade: the mark, at full bloom by now, fades where it
            // is (ADR-0007's "the ordinary hide fade carries it out").
            self.cue_hide_at = now + hide_dur;
            out.window = .hide_fade;
        }
        return out;
    }
};

// ---- level → bar mapping (the seam carries raw linear RMS; mapping is render-side) ----
// dBFS with a floor: −60 dB → flat, −10 dB → full bar, linear in dB. Linear amplitude
// would make whispers invisible; in dB a whisper (~−48..−34 dBFS) lands at 0.25–0.5 of
// the pill — visibly alive (#25/#26). These two constants are the dogfood-retune knob.
const floor_db: f32 = -60.0;
const ceil_db: f32 = -10.0;

/// Raw linear RMS (0..1 of full scale) → bar height fraction (0..1). Pure — the one
/// place loudness becomes pixels, unit-tested below.
fn levelToNorm(rms: f32) f32 {
    const db = 20.0 * @log10(@max(rms, 0.00001));
    return std.math.clamp((db - floor_db) / (ceil_db - floor_db), 0.0, 1.0);
}

/// Capacity of the producer→render level queue. The pump drains 20×/s and Capture
/// produces 20/s, so this only buffers pump jitter; overflow drops the newest sample.
const level_queue_cap = 64;

// ============================================================================
// The Scene — the micro-motion geometry (ADR-0014, #358). Pure.
// ============================================================================
// A port of `prototypes/hud-micro-motion`'s `Engine.barGeom` / `Engine.frame` with every
// locked option on, at the prototype's constants. The Sequencer keeps the lifecycle; the pump
// stamps each of its decisions into a `SceneState` as timestamps; `SceneState.scene` turns
// those timestamps into shapes for any `now`, so the Chrome can draw at display rate while
// the pump's decisions stay where they are. Locked options that need no code of their own:
// "interpolate" is carried by the glide (with the scroll gliding, the prototype never lerps
// heights), "display-rate dots" is the bounce computed from `now` below, and "show on the
// press" is cadence — the pump wakes the Chrome, which renders on the publishing edge.

/// The panel region the Scene draws in, and the panel's own size: the 300×22 pill plus room
/// for the glow halo and the unfurl spring — the prototype's 340×50 region, confirmed against
/// the glow by MetalChrome (#359), and pinned by "nothing draws outside the panel region".
/// Scene coordinates are region points, origin bottom-left, y up (the panel's convention).
pub const region_w: f64 = 340;
pub const region_h: f64 = 50;
const region_ox: f64 = (region_w - pill_w) / 2.0; // the pill's origin inside the region
const region_oy: f64 = (region_h - pill_h) / 2.0;

const pill_cx: f64 = pill_w / 2.0;
const pill_cy: f64 = pill_h / 2.0;
const slot: f64 = bar_w + bar_gap; // one bar's pitch — how far the scroll glides per sample
const bar_row_w: f64 = @as(f64, @floatFromInt(n_bars)) * slot - bar_gap;
const bar_row_x0: f64 = (pill_w - bar_row_w) / 2.0;

/// One level sample per Capture buffer: the glide crosses one slot in this long.
const capture_interval_s: f64 = 0.05;
/// Converge & drop on insert: the dots merge, swell and drop, then the panel orders out.
/// Replaces the hide fade's `hide_dur` unless Reduce Motion is on.
const converge_dur: f64 = 0.30;
/// Silence ripple amplitude (pt): a quiet bar breathes up to `min_bar_h + ripple_amp`, and
/// never higher — a whisper has to clear that ceiling to read as voice.
const ripple_amp: f64 = 1.6;
/// Shapes this faint or thin never reach the Chrome (the prototype renderer's cull).
const cull_alpha: f64 = 0.003;
const cull_size: f64 = 0.02;
/// "Not yet" for a SceneState timestamp — far enough back that every envelope has settled.
const never: f64 = -1e9;

/// The pill's ease-out, cubic-bezier(0.17, 0.7, 0.3, 1.0) — the curve the Core Animation
/// pill's fades used (#44/#47), kept so the Scene's fades ease alike.
const ease_ctl = [4]f32{ 0.17, 0.7, 0.3, 1.0 };

/// The ease-out bezier solved for y at x (Newton on x(t), as the prototype does). Clamped.
fn easeCurve(x: f64) f64 {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    const x1: f64 = ease_ctl[0];
    const y1: f64 = ease_ctl[1];
    const x2: f64 = ease_ctl[2];
    const y2: f64 = ease_ctl[3];
    const cx = 3.0 * x1;
    const bx = 3.0 * (x2 - x1) - cx;
    const ax = 1.0 - cx - bx;
    const cy = 3.0 * y1;
    const by = 3.0 * (y2 - y1) - cy;
    const ay = 1.0 - cy - by;
    var t = x;
    for (0..8) |_| {
        const e = ((ax * t + bx) * t + cx) * t - x;
        const d = (3.0 * ax * t + 2.0 * bx) * t + cx;
        if (@abs(e) < 1e-6 or @abs(d) < 1e-6) break;
        t -= e / d;
    }
    t = clamp01(t);
    return ((ay * t + by) * t + cy) * t;
}

fn clamp01(x: f64) f64 {
    return std.math.clamp(x, 0.0, 1.0);
}
fn lerp(a: f64, b: f64, f: f64) f64 {
    return a + (b - a) * f;
}
fn smoothstep(e0: f64, e1: f64, x: f64) f64 {
    const t = clamp01((x - e0) / (e1 - e0));
    return t * t * (3.0 - 2.0 * t);
}
/// A damped spring from 0 to 1 that overshoots once (~12 %) and settles — the unfurl.
fn springOut(p: f64) f64 {
    if (p <= 0.0) return 0.0;
    if (p >= 1.0) return 1.0;
    return 1.0 - @exp(-6.0 * p) * @cos(9.0 * p);
}
/// Back-out ease (overshoot 1.7): the newest bar springs in, the dots pop in on gather.
fn backOut(x: f64) f64 {
    const s = 1.7;
    const p = clamp01(x) - 1.0;
    return 1.0 + (s + 1.0) * p * p * p + s * p * p;
}

/// One mark of the Scene: a rounded rect (corner radius `min(w, h) / 2`, the Chrome's
/// business) centred at (cx, cy) in region points. `role` names the semantic colour the
/// Chrome resolves per frame; `amber` blends systemOrange into it (ADR-0004); `alpha` already
/// carries the window fade.
pub const Shape = struct {
    cx: f32 = 0,
    cy: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    role: Role = .label,
    alpha: f32 = 0,
    amber: f32 = 0,

    pub const Role = enum {
        label, // the recording bars — labelColor
        secondary, // the processing dots — secondaryLabelColor
        confirm, // the Undo confirm mark — systemGreen (ADR-0007)
        refuse, // the Undo refuse mark — systemRed (ADR-0007)
    };
};

/// The most shapes one Scene carries: the bar row plus the bar gliding off, frozen at release
/// while the three dots come in. The Undo mark only ever shows alone.
const scene_cap = (n_bars + 1) + 3;

/// Everything the pill shows at one instant: fixed-size and `std.meta.eql`-comparable, like
/// the Frame that carries it. Unused slots stay default, so equal Scenes compare equal.
pub const Scene = struct {
    shapes: [scene_cap]Shape = @splat(.{}),
    len: usize = 0,
    /// The prototype's transitions-only goo envelope (0..1): up through the unfurl, the
    /// release gather and the converge. The locked setting is goo **Always** (ADR-0014), so
    /// the Chrome may ignore it; it is here so the envelope stays with the geometry.
    goo: f32 = 0,

    pub fn items(self: *const Scene) []const Shape {
        return self.shapes[0..self.len];
    }
};

/// A mark before the pill-level transform: pill points, y up.
const Prim = struct {
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
    a: f64,
    role: Shape.Role,
    amber: f64 = 0,
};

/// One waveform bar's geometry before the pill-level transform. `i` is the slot, −1 for the
/// bar gliding off the left edge.
const Bar = struct { i: i32 = 0, cx: f64 = 0, w: f64 = 0, h: f64 = 0, a: f64 = 0 };

/// An eased window-alpha tween. The default holds at 1.
const Tween = struct {
    from: f64 = 1,
    to: f64 = 1,
    t0: f64 = 0,
    dur: f64 = 1,

    fn at(self: Tween, t: f64) f64 {
        return lerp(self.from, self.to, easeCurve((t - self.t0) / self.dur));
    }
};

/// The timestamps the Scene is computed from — the prototype engine's "chrome-ish" state.
/// The pump writes it as the Sequencer decides (one call per decision, below); `scene` only
/// reads it. Pump-thread-only.
pub const SceneState = struct {
    family: Family = .none,
    /// Normalized heights after the organic envelope: `hist[n_bars]` is the newest bar,
    /// `hist[0]` the one gliding off the left edge.
    hist: [n_bars + 1]f32 = @splat(0),
    /// The organic envelope: fast attack, eased release.
    env: f32 = 0,
    /// When the last batch of samples scrolled in, and how many — the glide's origin.
    shift_at: f64 = never,
    shift_n: usize = 0,
    show_at: f64 = never,
    /// The release handover: the bars frozen where they were, and when.
    release_at: f64 = never,
    snap: [n_bars + 1]Bar = @splat(.{}),
    dots_since: f64 = never,
    /// The hide: when it started, and whether it converges (else the window alpha fades).
    hide_start: f64 = never,
    hide_converge: bool = false,
    win: Tween = .{},
    /// The degraded pulse's start (ADR-0004). Kept until the order-out, so the amber rides
    /// the converge out.
    amber_since: ?f64 = null,
    mark_kind: Sequencer.CueKind = .confirm,
    mark_at: f64 = never,

    pub const Family = enum { none, bars, dots, mark };

    // ---- the pump's writes, one per Sequencer decision ----

    fn show(self: *SceneState, now: f64) void {
        self.show_at = now;
        self.win = .{ .from = 0, .to = 1, .t0 = now, .dur = show_dur };
        self.hide_start = never;
    }
    fn cancelHide(self: *SceneState) void {
        self.win = .{};
        self.hide_start = never;
    }
    fn cutToBars(self: *SceneState) void {
        self.family = .bars;
        self.hist = @splat(0);
        self.env = 0;
        self.shift_at = never;
        self.shift_n = 0;
        self.release_at = never;
        self.amber_since = null;
    }
    fn cutToDots(self: *SceneState, now: f64) void {
        self.family = .dots;
        self.release_at = never;
        self.dots_since = now;
    }
    fn release(self: *SceneState, now: f64, reduce_motion: bool) void {
        self.snap = self.barGeom(now, reduce_motion);
        self.family = .dots;
        self.release_at = now;
        self.dots_since = now;
    }
    /// Scroll one batch of drained samples in. The organic envelope rides here, on the
    /// samples, so the scroll buffer already holds what the bars show.
    fn scroll(self: *SceneState, now: f64, rms: []const f32) void {
        for (rms) |r| {
            const n = levelToNorm(r);
            self.env = if (n >= self.env) n else self.env + (n - self.env) * 0.5;
            std.mem.copyForwards(f32, self.hist[0..n_bars], self.hist[1..]);
            self.hist[n_bars] = self.env;
        }
        self.shift_at = now;
        self.shift_n = rms.len;
    }
    fn startAmber(self: *SceneState, now: f64) void {
        self.amber_since = now;
    }
    fn startHide(self: *SceneState, now: f64, converge: bool) void {
        self.hide_start = now;
        self.hide_converge = converge;
        if (!converge) self.win = .{ .from = self.win.at(now), .to = 0, .t0 = now, .dur = hide_dur };
    }
    fn showMark(self: *SceneState, now: f64, kind: Sequencer.CueKind) void {
        self.* = .{ .family = .mark, .mark_kind = kind, .mark_at = now };
        self.win = .{ .from = 0, .to = 1, .t0 = now, .dur = show_dur };
    }
    fn orderOut(self: *SceneState) void {
        self.* = .{};
    }

    // ---- the pure read ----

    /// The waveform's bars at `t`: content only, no window alpha or pill-level transform.
    fn barGeom(self: *const SceneState, t: f64, reduce_motion: bool) [n_bars + 1]Bar {
        var out: [n_bars + 1]Bar = undefined;
        const p = clamp01((t - self.shift_at) / capture_interval_s);
        const glide_off = @as(f64, @floatFromInt(self.shift_n)) * slot * (1.0 - p);
        for (&out, self.hist, 0..) |*bar, level, k| {
            const i: i32 = @as(i32, @intCast(k)) - 1;
            const fi: f64 = @floatFromInt(i);
            var norm: f64 = level;
            // Organic envelope: the newest bar springs in from the floor.
            if (k == n_bars) norm *= backOut((t - self.shift_at) / 0.09);
            var h = min_bar_h + @max(0.0, norm) * (max_bar_h - min_bar_h);
            var w: f64 = bar_w;
            var a: f64 = 1;
            const cx = bar_row_x0 + fi * slot + bar_w / 2.0 + glide_off;
            if (!reduce_motion) {
                // Silence ripple: quiet bars breathe, phase-offset along the row.
                const quiet = 1.0 - smoothstep(0.02, 0.10, norm);
                const fade_in = smoothstep(0.15, 0.5, t - self.show_at);
                h += ripple_amp * quiet * fade_in * (0.5 + 0.5 * @sin(2.0 * std.math.pi * 1.2 * t - fi * 0.55));
            }
            if (k == 0) a *= 1.0 - p; // the bar gliding off fades as it goes
            a *= 0.42 + 0.58 * std.math.pow(f64, clamp01(norm), 0.6); // loudness opacity
            // Edge dissolve: history thins out to the left, the newest bar fades in on the right.
            a *= smoothstep(bar_row_x0 - 4.0, bar_row_x0 + 64.0, cx) *
                (1.0 - smoothstep(bar_row_x0 + bar_row_w - bar_w / 2.0, bar_row_x0 + bar_row_w + slot, cx));
            if (!reduce_motion) {
                // Unfurl: springs out from the centre, staggered by distance.
                const d = @abs(fi - @as(f64, n_bars - 1) / 2.0) * 0.009;
                const q = clamp01((t - self.show_at - d) / 0.26);
                const s = springOut(q);
                w *= s;
                h *= s;
                a *= clamp01(q * 3.0);
            }
            bar.* = .{ .i = i, .cx = cx, .w = w, .h = h, .a = a };
        }
        return out;
    }

    /// Everything the pill shows at `now`. Pure: the same state and `now` give the same
    /// Scene. `reduce_motion` turns off unfurl, gather, converge, squash and ripple; their
    /// moments fall back to ADR-0002's fades and crossfade.
    pub fn scene(self: *const SceneState, now: f64, reduce_motion: bool) Scene {
        const t = now;
        var prims: [scene_cap]Prim = undefined;
        var n: usize = 0;

        const hiding = self.hide_start > never and self.hide_converge;
        const hc = if (hiding) clamp01((t - self.hide_start) / converge_dur) else 0.0;

        switch (self.family) {
            .none => return .{},
            .bars => {
                // Converge from recording: the row pulls in to the centre and flattens.
                const p = if (hiding) easeCurve(hc / 0.85) else 0.0;
                for (self.barGeom(t, reduce_motion)) |b| {
                    prims[n] = .{
                        .cx = pill_cx + (b.cx - pill_cx) * (1.0 - 0.85 * p),
                        .cy = pill_cy,
                        .w = b.w,
                        .h = lerp(b.h, min_bar_h, p),
                        .a = b.a * (1.0 - p),
                        .role = .label,
                    };
                    n += 1;
                }
            },
            .dots => {
                // The release handover: the frozen bars gather into the dots, or crossfade out.
                if (self.release_at > never) {
                    const tr = t - self.release_at;
                    for (self.snap) |b| {
                        if (!reduce_motion) {
                            if (tr > 0.5) continue;
                            const j = std.math.clamp(@divFloor(b.i * 3, @as(i32, n_bars)), 0, 2);
                            const target = dotCX(@floatFromInt(j));
                            const dist = @abs(b.cx - target);
                            const p = easeCurve(tr / (0.15 + 0.15 * @min(1.0, dist / 100.0)));
                            prims[n] = .{
                                .cx = lerp(b.cx, target, p),
                                .cy = pill_cy,
                                .w = lerp(b.w, dot_size * 0.7, p),
                                .h = lerp(b.h, dot_size * 0.7, p),
                                .a = b.a * (1.0 - smoothstep(0.5, 1.0, p)),
                                .role = .label,
                            };
                        } else {
                            if (tr > cross_dur + 0.02) continue;
                            prims[n] = .{ .cx = b.cx, .cy = pill_cy, .w = b.w, .h = b.h, .a = b.a * (1.0 - easeCurve(tr / cross_dur)), .role = .label };
                        }
                        n += 1;
                    }
                }

                const tr = t - self.dots_since;
                var appear_a: f64 = 1;
                var appear_s: f64 = 1;
                var amp: f64 = dot_bounce;
                if (self.release_at > never) {
                    if (!reduce_motion) {
                        // Gather: the dots pop in as the bars arrive, the bounce eases up.
                        const q = clamp01((tr - 0.10) / 0.22);
                        appear_s = @max(0.0, backOut(q));
                        appear_a = clamp01(q * 2.5);
                        amp = dot_bounce * smoothstep(0.18, 0.55, tr);
                    } else appear_a = easeCurve(tr / cross_dur);
                }
                const amber: f64 = if (self.amber_since) |since| pulseEnvelope(t - since) else 0.0;
                for (0..3) |j| {
                    const fj: f64 = @floatFromInt(j);
                    const ph = dotPhase(t, fj);
                    var off = amp * @sin(ph);
                    var w: f64 = dot_size;
                    var h: f64 = dot_size;
                    var cx = dotCX(fj);
                    var a = appear_a;
                    if (!reduce_motion) {
                        // Squash & stretch, in step with the bounce.
                        const k = amp / dot_bounce;
                        const s = @abs(@sin(ph));
                        const c = @abs(@cos(ph));
                        h *= 1.0 + k * (0.14 * c - 0.08 * s);
                        w *= 1.0 - k * (0.07 * c - 0.08 * s);
                    }
                    w *= appear_s;
                    h *= appear_s;
                    if (hiding) {
                        // Converge & drop: merge on the middle dot, swell, drop 4 pt, vanish.
                        const p1 = easeCurve(hc / 0.5);
                        cx = lerp(cx, dotCX(1), p1);
                        off *= 1.0 - p1;
                        if (j != 1) a *= 1.0 - smoothstep(0.6, 1.0, p1);
                        const p2 = clamp01((hc - 0.4) / 0.6);
                        const sc = if (p2 < 0.3) 1.0 + 0.18 * (p2 / 0.3) else 1.18 * (1.0 - easeCurve((p2 - 0.3) / 0.7));
                        w *= sc;
                        h *= sc;
                        off -= 4.0 * easeCurve(p2);
                        a *= 1.0 - smoothstep(0.55, 1.0, p2);
                    }
                    prims[n] = .{ .cx = cx, .cy = pill_cy + off, .w = w, .h = h, .a = a, .role = .secondary, .amber = amber };
                    n += 1;
                }
            },
            .mark => {
                // The Undo cue (ADR-0007): one mark blooms in; a refuse also shakes.
                const e = t - self.mark_at;
                prims[n] = .{
                    .cx = pill_cx + (if (self.mark_kind == .refuse) cueShake(e) else 0.0),
                    .cy = pill_cy,
                    .w = mark_w,
                    .h = mark_h,
                    .a = cueBloom(e),
                    .role = if (self.mark_kind == .confirm) .confirm else .refuse,
                };
                n += 1;
            },
        }

        // The pill-level transform: the unfurl's whole-pill spring, and the window alpha.
        const gs = if (!reduce_motion and self.family != .mark)
            0.93 + 0.07 * springOut(clamp01((t - self.show_at) / 0.4))
        else
            1.0;
        const wa = self.win.at(t);
        var out: Scene = .{};
        for (prims[0..n]) |p| {
            const w = p.w * gs;
            const h = p.h * gs;
            const a = p.a * wa;
            if (a <= cull_alpha or w <= cull_size or h <= cull_size) continue;
            out.shapes[out.len] = .{
                .cx = @floatCast(region_ox + pill_cx + (p.cx - pill_cx) * gs),
                .cy = @floatCast(region_oy + pill_cy + (p.cy - pill_cy) * gs),
                .w = @floatCast(w),
                .h = @floatCast(h),
                .role = p.role,
                .alpha = @floatCast(a),
                .amber = @floatCast(p.amber),
            };
            out.len += 1;
        }

        var goo: f64 = 0;
        if (self.family == .dots and self.release_at > never) {
            const tr = t - self.release_at;
            goo = smoothstep(0.0, 0.06, tr) * (1.0 - smoothstep(0.35, 0.7, tr));
        }
        if (hiding) goo = 1;
        if (!reduce_motion) goo = @max(goo, 1.0 - smoothstep(0.2, 0.45, t - self.show_at));
        out.goo = @floatCast(goo);
        return out;
    }
};

/// Dot `j`'s bounce phase at `now` (radians): ~0.8 Hz, each dot 0.8 rad behind the last.
fn dotPhase(now: f64, j: f64) f64 {
    return now * 5.0 + j * 0.8;
}

/// Dot `j`'s centre x in pill points.
fn dotCX(j: f64) f64 {
    return (pill_w - dots_row_w) / 2.0 + j * (dot_size + dot_gap) + dot_size / 2.0;
}


// ============================================================================
// The HUD Chrome seam — `paint(Frame)`, plus the `wake()` nudge for its cadence.
// ============================================================================

/// One tick's complete, comparable description of what the pill shows. The pump computes
/// it; the Chrome draws it and decides nothing. Fixed-size and `std.meta.eql`-comparable
/// by construction, so a test asserts on emitted values rather than on a log of calls.
pub const Frame = struct {
    /// What the panel window does this tick: order it in on `show_fade`, out on `order_out`.
    /// Every fade is already folded into the Scene's alphas, so nothing else is the window's.
    window: Sequencer.WindowFx = .none,
    /// The micro-motion geometry at this tick's `now` (ADR-0014, #358): every shape the pill
    /// shows, with the window fade folded into each shape's alpha.
    scene: Scene = .{},
};

/// The Chrome seam's contract. Invoked by `Hud(Chrome)` itself below — unlike
/// `local_backend.assertHelper` and `session.assertTransport`, which are never called by
/// the generic types they protect, so a production adapter can slip through unasserted.
///
/// `paint(Frame)` draws one tick. `wake()` is the pump telling the Chrome's cadence that
/// published input changed: it is called from any thread, after the pump's lock is
/// released, and must be cheap and thread-safe. The cadence is the adapter's (ADR-0014): it
/// idles while the pill is hidden, and a wake makes it render on the publishing edge.
pub fn assertChrome(comptime Chrome: type) void {
    inline for (.{ "paint", "wake" }) |method| {
        if (!@hasDecl(Chrome, method))
            @compileError("type '" ++ @typeName(Chrome) ++ "' is not a Chrome: missing method '" ++ method ++ "'");
    }
}

/// The floating waveform pill's **pump**: the mutex-guarded state producers publish into,
/// the pure `Sequencer`, and the per-tick composition rules that turn both into a `Frame`.
/// It holds no AppKit handle and takes `now` as a parameter, so every rule below — the cue
/// arming guard, the recording/processing preemption, the degraded-pulse downgrade, the
/// pulse-to-hide handoff — runs under `zig build test` against a `FakeChrome`.
///
/// A single instance lives for the daemon's process lifetime.
pub fn Hud(comptime Chrome: type) type {
    assertChrome(Chrome);
    return struct {
        const Self = @This();

        /// Where frames go. Whether anything is actually drawn — a real panel, nothing at
        /// all on a headless box — is the adapter's business, never the pump's.
        chrome: *Chrome,

        // ---- producer → render handoff (any thread writes, the pump reads) ----
        mu: os_unfair_lock = .{},
        /// The live Overlay toggle (wayfinder #32/#34): a built HUD switched off from the
        /// menu keeps all its machinery — no teardown path is ever exercised — but ignores
        /// lifecycle publishes, so it never shows; re-enable is instant. The daemon also
        /// holds this false when the Chrome could not be built (headless), which is what
        /// makes `isOn` report honestly and the Feedback Surface fall back to sound.
        enabled: bool = true,
        pending_state: State = .hidden,
        /// One-shot degraded-insertion pulse request (ADR-0004).
        pulse_pending: bool = false,
        /// One-shot Undo confirm/refuse cue request (ADR-0007, #226). `null` = none pending.
        cue_pending: ?Sequencer.CueKind = null,
        q: [level_queue_cap]f32 = @splat(0), // raw linear RMS, one sample per Capture buffer
        qlen: usize = 0,

        // ---- pump-thread-only ----
        /// The motion's decision half (#51): edge detection, window lifecycle, hide-fade
        /// deadline, the pulse and cue envelopes.
        seq: Sequencer = .{},
        /// The timestamps the Scene is computed from, stamped as the Sequencer decides.
        scene_state: SceneState = .{},

        pub fn init(chrome: *Chrome) Self {
            return .{ .chrome = chrome };
        }

        /// Reduce Motion (ADR-0014), read from the system by the Chrome and handed in on the
        /// pump's thread before `render`. On, unfurl, gather, converge, squash and the silence
        /// ripple fall back to fades and the crossfade.
        pub fn setReduceMotion(self: *Self, on: bool) void {
            self.seq.reduce_motion = on;
        }

        /// Publish a lifecycle state. Thread-safe, no AppKit — called from the run-loop
        /// thread (Talk Key press/release) and wherever the Utterance resolves. A state
        /// change clears the level queue so a stale sample never bleeds into the next
        /// Utterance. An accepted publish wakes the Chrome, so a press shows the pill on
        /// the publishing edge rather than on some later tick.
        pub fn publish(self: *Self, state: State) void {
            {
                os_unfair_lock_lock(&self.mu);
                defer os_unfair_lock_unlock(&self.mu);
                if (!self.enabled and state != .hidden) return; // switched off from the menu
                if (state != self.pending_state) self.qlen = 0;
                self.pending_state = state;
            }
            self.chrome.wake(); // after the unlock: never call out under the spinlock
        }

        /// The menu's live Overlay toggle. Disable hides the pill immediately (a shown pill
        /// is being drawn every frame, so the next one takes it down); enable lets the next
        /// Utterance show it again.
        pub fn setEnabled(self: *Self, on: bool) void {
            os_unfair_lock_lock(&self.mu);
            defer os_unfair_lock_unlock(&self.mu);
            self.enabled = on;
            if (!on) {
                self.pending_state = .hidden;
                self.qlen = 0;
            }
        }

        /// Whether the pill is carrying feedback right now. The Feedback Surface consults
        /// this per verb, so a disabled overlay falls back to sound cues exactly like an
        /// `overlay=false` start — and so does a headless run, where the daemon leaves this
        /// false because the Chrome never built.
        pub fn isOn(self: *Self) bool {
            os_unfair_lock_lock(&self.mu);
            defer os_unfair_lock_unlock(&self.mu);
            return self.enabled;
        }

        /// Take the pill down. Called at the end of an Utterance (inserted, abandoned,
        /// empty, timed out). Since the Utterance lifecycle is fully serialized (ADR-0001)
        /// — no new `.recording` pill can exist until the current Insertion resolves —
        /// this is an unconditional hide.
        pub fn hide(self: *Self) void {
            self.publish(.hidden);
        }

        /// Fire the one-shot degraded-insertion pulse (docs/backtrack-spec.md §UX 4,
        /// ADR-0004): the processing dots flash systemOrangeColor once (~300 ms), then the
        /// pill fades out. Called on the degraded path *instead of* `hide`. If there is no
        /// processing pill to pulse (overlay off, or nothing in flight) it degrades to a
        /// plain hide so the pill never stays up.
        pub fn pulseDegraded(self: *Self) void {
            {
                os_unfair_lock_lock(&self.mu);
                defer os_unfair_lock_unlock(&self.mu);
                if (!self.enabled or self.pending_state != .processing) {
                    self.pending_state = .hidden; // nothing to pulse — just take the pill down
                    self.qlen = 0;
                } else self.pulse_pending = true;
            }
            self.chrome.wake();
        }

        /// Fire the Undo **confirm** cue (ADR-0007, #226): the single mark blooms
        /// systemGreen once, holds, then self-hides. Called from the insert worker after a
        /// gated Undo posted its backspaces (ADR-0008).
        pub fn undoConfirm(self: *Self) void {
            self.requestCue(.confirm);
        }

        /// Fire the Undo **refuse** cue (ADR-0007, #226): the single mark blooms systemRed
        /// and shakes horizontally once, then self-hides. Every refuse reason collapses to
        /// this one cue; the reason is logged only (#213).
        pub fn undoRefuse(self: *Self) void {
            self.requestCue(.refuse);
        }

        fn requestCue(self: *Self, kind: Sequencer.CueKind) void {
            {
                os_unfair_lock_lock(&self.mu);
                defer os_unfair_lock_unlock(&self.mu);
                if (!self.enabled) return; // overlay off — no visual surface for the cue
                self.cue_pending = kind;
            }
            self.chrome.wake(); // a cue arms from a hidden pill, whose cadence is idle
        }

        /// Queue one raw linear RMS sample (0..1 of full scale) — one Capture buffer's
        /// loudness, i.e. one new bar. Called from the audio queue's thread; no AppKit.
        /// Dropped unless the published state is `.recording`, so a straggler buffer
        /// flushed by `capture.stop` can't repaint a processing/hidden pill.
        pub fn pushLevel(self: *Self, rms: f32) void {
            os_unfair_lock_lock(&self.mu);
            defer os_unfair_lock_unlock(&self.mu);
            if (self.pending_state != .recording) return;
            if (self.qlen < self.q.len) {
                self.q[self.qlen] = rms;
                self.qlen += 1;
            }
        }

        /// One pump tick: drain the published state, decide what this tick shows, and hand
        /// the Chrome exactly one `Frame`. `now` comes in from the caller (the Chrome's
        /// timer in production, a fed value in tests) — the pump reads no clock of its own.
        pub fn render(self: *Self, now: f64) void {
            // Snapshot + drain under the lock, then release it before handing anything to
            // the Chrome — never message ObjC while holding the spinlock (it would stall
            // the audio producer).
            var drained: [level_queue_cap]f32 = undefined;
            os_unfair_lock_lock(&self.mu);
            var st = self.pending_state;
            const pulse_req = self.pulse_pending;
            self.pulse_pending = false;
            const cue_req = self.cue_pending;
            // Cleared unconditionally, and that is a decision, not a leftover: a cue is
            // glanceable and tied to the action that caused it (ADR-0007), so one that
            // cannot be shown *this tick* is dropped rather than queued. A bloom arriving
            // seconds later, after whatever pill was up has gone, attaches to nothing.
            self.cue_pending = null;
            const n = self.qlen;
            @memcpy(drained[0..n], self.q[0..n]);
            self.qlen = 0;
            os_unfair_lock_unlock(&self.mu);

            // Undo cue (ADR-0007, #226): armed only from a `.hidden` pill (an Undo fires
            // between Utterances) and only when no cue is already in progress, so it never
            // fights a live recording/processing pill and an overlapping request cannot
            // restart a playing one. While it owns the pill the cue is a self-contained
            // path — no step/marks work at all.
            const rm = self.seq.reduce_motion;
            const ss = &self.scene_state;
            if (st == .hidden) {
                if (cue_req) |kind| {
                    if (self.seq.cue_at == null) self.seq.startCue(now, kind);
                }
                const cue = self.seq.cueStep(now);
                if (cue.owns) {
                    switch (cue.window) {
                        .show_fade => ss.showMark(now, cue.kind),
                        .hide_fade => ss.startHide(now, false), // a cue fades; converge is the Insertion's
                        .order_out => ss.orderOut(),
                        .none, .cancel_hide => {},
                    }
                    self.chrome.paint(.{ .window = cue.window, .scene = ss.scene(now, rm) });
                    return;
                }
            } else if (self.seq.cue_at != null) {
                // A recording/processing pill preempts an in-flight cue: drop it and fall
                // through so the new pill shows this tick. The `.marks` flip below hides
                // the mark as it goes, so the abandoned mark never lingers under the bars.
                self.seq.cancelCue();
            }

            // Degraded-insertion pulse (ADR-0004): arm on request while a processing pill
            // is up, tint the dots amber over ~300 ms, then resolve to `.hidden` so the
            // ordinary hide fade carries the frozen amber dots out.
            if (pulse_req and st == .processing) {
                self.seq.startPulse(now);
                ss.startAmber(now);
            }
            if (self.seq.pulseStep(now) and st == .processing) {
                os_unfair_lock_lock(&self.mu);
                if (self.pending_state == .processing) self.pending_state = .hidden;
                os_unfair_lock_unlock(&self.mu);
                st = .hidden;
            }

            const decision = self.seq.step(st, now);

            if (st == .hidden) {
                // Only window motion happens while hidden: no family cut, no scroll. The Scene
                // plays the converge (or, under Reduce Motion, the fade) around what was shown.
                switch (decision.window) {
                    .hide_fade => ss.startHide(now, !rm),
                    .order_out => ss.orderOut(),
                    .none, .show_fade, .cancel_hide => {},
                }
                self.chrome.paint(.{ .window = decision.window, .scene = ss.scene(now, rm) });
                return;
            }

            // A fresh Utterance starts from a flat line — zeroed before this tick's samples
            // scroll in, exactly as the family cut lands.
            switch (decision.marks) {
                .keep => {},
                .bars => ss.cutToBars(),
                .dots => ss.cutToDots(now),
                .crossfade => ss.release(now, rm),
            }
            // One drained sample = the scroll advances one bar. The dB mapping is applied
            // here, as levels come off the queue (#26).
            if (st == .recording and n > 0) ss.scroll(now, drained[0..n]);
            switch (decision.window) {
                .show_fade => ss.show(now),
                .cancel_hide => ss.cancelHide(),
                .none, .hide_fade, .order_out => {},
            }

            self.chrome.paint(.{ .window = decision.window, .scene = ss.scene(now, rm) });
        }
    };
}

// ============================================================================
// The shader's input — MetalChrome's pure half (ADR-0014, #359).
// ============================================================================

/// The locked track-B look (ADR-0014): goo **Always** at a 5 pt blend radius, soft glow 0.75.
/// Fixed, no config knob, like the rest of the pill.
const goo_k: f32 = 5.0;
const glow_strength: f32 = 0.75;

/// The semantic colours one frame resolves, as straight sRGB + alpha. The Chrome re-resolves
/// them every frame against the current appearance (ADR-0002's property, at display rate).
pub const Palette = struct {
    label: [4]f32, // labelColor — the recording bars
    secondary: [4]f32, // secondaryLabelColor — the processing dots
    orange: [4]f32, // systemOrangeColor — the degraded pulse (ADR-0004)
    green: [4]f32, // systemGreenColor — the Undo confirm (ADR-0007)
    red: [4]f32, // systemRedColor — the Undo refuse (ADR-0007)

    fn of(self: Palette, s: Shape) [4]f32 {
        const base = switch (s.role) {
            .label => self.label,
            .secondary => self.secondary,
            .confirm => self.green,
            .refuse => self.red,
        };
        if (s.amber <= 0) return base;
        var c: [4]f32 = undefined;
        for (&c, base, self.orange) |*out, b, o| out.* = b * (1 - s.amber) + o * s.amber; // exact at both ends
        return c;
    }
};

/// The shader's shape capacity: `MAXP` in hud.metal. Checked against the source below.
const max_shapes = 32;

/// One frame's uniforms, handed to the fragment function by `setFragmentBytes` (well under
/// its 4 KB limit). Byte for byte the `U` struct in hud.metal.
const Uniforms = extern struct {
    res: [2]f32 = .{ 0, 0 },
    px: f32 = 1,
    count: i32 = 0,
    k: f32 = goo_k,
    glow: f32 = glow_strength,
    _pad: [2]f32 = .{ 0, 0 },
    geo: [max_shapes][4]f32 = @splat(@splat(0)),
    col: [max_shapes][4]f32 = @splat(@splat(0)),
    fade: [max_shapes]f32 = @splat(0),
};

const msl_source = @embedFile("hud.metal");

comptime {
    std.debug.assert(@sizeOf(Uniforms) == 1184);
    std.debug.assert(@offsetOf(Uniforms, "geo") == 32);
    std.debug.assert(scene_cap <= max_shapes);
    std.debug.assert(std.mem.indexOf(u8, msl_source, std.fmt.comptimePrint("#define MAXP {d}\n", .{max_shapes})) != null);
}

/// Turn one Scene into the shader's input: flip it y-down for Metal's top-left fragment
/// origin, colour each shape from its role (blending in its amber), and fold the shape's
/// alpha into the colour. Pure — the one place a Scene becomes GPU bytes, unit-tested below.
fn packUniforms(scene: *const Scene, palette: Palette, scale: f64) Uniforms {
    var u: Uniforms = .{
        .res = .{ @floatCast(region_w * scale), @floatCast(region_h * scale) },
        .px = @floatCast(scale),
        .count = @intCast(scene.len),
    };
    for (scene.items(), 0..) |s, i| {
        const c = palette.of(s);
        u.geo[i] = .{ s.cx, @as(f32, @floatCast(region_h)) - s.cy, s.w, s.h };
        u.col[i] = .{ c[0], c[1], c[2], c[3] * s.alpha };
        u.fade[i] = std.math.clamp(s.alpha, 0, 1);
    }
    return u;
}

// ============================================================================
// MetalChrome — the production adapter (ADR-0014, #359). Every ObjC call in the HUD lives here.
// ============================================================================

/// What the Chrome does with one Frame, given whether its display link is running — that
/// is, whether the pill is on screen. Pure and keyed only on the frame's window op, so the
/// adapter decides nothing; unit-tested below, which is where "a hidden pill costs nothing"
/// is pinned.
const ChromePlan = struct {
    /// Encode and present the frame's Scene.
    draw: bool = false,
    order_front: bool = false,
    order_out: bool = false,
    /// Whether the display link runs after this frame.
    running: bool = false,

    fn of(running: bool, fx: Sequencer.WindowFx) ChromePlan {
        return switch (fx) {
            // Draw before ordering in, so the panel never shows a stale drawable.
            .show_fade => .{ .draw = true, .order_front = true, .running = true },
            // The order-out frame's Scene is empty: drawing it leaves the layer clear.
            .order_out => .{ .draw = true, .order_out = true },
            .none, .hide_fade, .cancel_hide => .{ .draw = running, .running = running },
        };
    }
};

/// The pump's entry point, bound by the daemon: `now` on the display link's clock
/// (`CACurrentMediaTime`) and the system's Reduce Motion setting, both read by the Chrome
/// so the pump reads neither.
pub const Tick = *const fn (ctx: *anyopaque, now: f64, reduce_motion: bool) void;

/// The panel, the transparent `CAMetalLayer` and its SDF pipeline, the display-link cadence,
/// the wake source, and the headless / Metal-less bail. AppKit and Metal objects live for the
/// process once built. Main thread only, except `wake`.
///
/// `init` / `isBuilt` / `startPump` are the daemon's construction surface, not the Chrome
/// seam: the pump only ever calls `paint` and `wake`.
///
/// The cadence (ADR-0014): while the pill is on screen, `NSScreen`'s display link calls the
/// pump once per display frame. While it is hidden the link is paused and nothing runs at all
/// until the pump `wake`s the Chrome — a run-loop source signalled from whichever thread
/// published — and the Chrome renders once, right then. If that frame shows the pill, the
/// link starts. The 20 Hz Capture cadence and the level queue are the pump's, and unchanged.
pub const MetalChrome = struct {
    panel: id = null,
    layer: id = null, // the CAMetalLayer the pass presents into
    queue: id = null,
    pipeline: id = null,
    link: id = null, // NSScreen's CADisplayLink — unpaused only while the pill is on screen
    scale: f64 = 2, // the screen's backing scale: drawable px per pt

    /// False until `init` succeeds; false forever on a headless or Metal-less start.
    /// `paint` no-ops while false, so nothing downstream special-cases either.
    active: bool = false,
    /// The display link is unpaused. Main thread only.
    running: bool = false,

    ctx: ?*anyopaque = null,
    tick: ?Tick = null,
    /// The wake source. `wake` loads it from any thread, and the lazy Overlay-toggle build
    /// may store it while an Utterance's `hide` is already publishing — hence atomic.
    source: std.atomic.Value(?*anyopaque) = .init(null),
    run_loop: CFRunLoopRef = null,

    /// Why the Chrome could not be built. Every one of them means sound-only, like headless.
    pub const InitError = error{
        /// No display: `[NSScreen mainScreen]` is nil (e.g. a bare-SSH run).
        Headless,
        /// No default Metal device, or the shader or its pipeline failed to build.
        NoMetal,
        /// `NSScreen` has no display link (before macOS 14).
        NoDisplayLink,
    };

    /// Build the Metal pipeline, the display link and the panel (hidden), and bring AppKit up
    /// as an accessory app. The MSL compile (~640 ms, spike #356) happens here, never on the
    /// first press. MUST run on the main thread, before the run loop starts. A second call
    /// is a no-op.
    pub fn init(self: *MetalChrome) InitError!void {
        if (self.active) return;
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // Shared, accessory-policy app (appkit.zig — also used by the menu-bar status item,
        // #34). The policy is set before finishLaunching so no Dock icon ever flashes.
        _ = appkit.app();

        // No display => no HUD. Bail before finishLaunching, and before the shader compile.
        const screen = mainScreen();
        if (screen == null) return error.Headless;
        if (!respondsTo(screen, "displayLinkWithTarget:selector:")) return error.NoDisplayLink;

        // finishLaunching wires up AppKit enough to draw whether the loop is the headless
        // CFRunLoopRun (proven by #20) or [NSApp run] under the status item (#31/#34).
        appkit.ensureLaunched();

        self.scale = msgF64(screen, "backingScaleFactor");
        try self.buildPipeline();
        try self.buildLink(screen);
        self.buildPanel(screen);
        self.active = true;
    }

    /// Whether the Chrome built. The daemon reads this to decide whether the Overlay toggle
    /// can honestly be turned on: an unbuilt Chrome keeps the pump's `enabled` false, so
    /// `isOn` reports the truth and the Feedback Surface falls back to sound.
    pub fn isBuilt(self: *MetalChrome) bool {
        return self.active;
    }

    /// Bind the pump and add the wake source to the CURRENT run loop (the daemon's main
    /// thread, before its CFRunLoopRun). No-op if the Chrome isn't built.
    pub fn startPump(self: *MetalChrome, ctx: *anyopaque, tick: Tick) void {
        if (!self.active) return;
        self.ctx = ctx;
        self.tick = tick;
        self.run_loop = CFRunLoopGetCurrent();
        var sctx = CFRunLoopSourceContext{ .info = self, .perform = wakePerform };
        const src = CFRunLoopSourceCreate(null, 0, &sctx); // copies the context
        CFRunLoopAddSource(self.run_loop, src, kCFRunLoopCommonModes);
        self.source.store(src, .release);
    }

    /// **The Chrome seam**, cadence half: published input changed. Any thread. Signals the
    /// wake source so the main thread renders on the publishing edge; a no-op before
    /// `startPump` (headless, Metal-less, or not yet built).
    pub fn wake(self: *MetalChrome) void {
        const src = self.source.load(.acquire) orelse return;
        CFRunLoopSourceSignal(src);
        CFRunLoopWakeUp(self.run_loop);
    }

    /// **The Chrome seam**, drawing half. Decides nothing: `ChromePlan` keys every step on
    /// the frame's window op. Hidden frames return before any ObjC or GPU work.
    pub fn paint(self: *MetalChrome, frame: Frame) void {
        if (!self.active) return;
        const plan = ChromePlan.of(self.running, frame.window);
        if (plan.draw) self.draw(&frame.scene);
        if (plan.order_front) msgv(self.panel, "orderFrontRegardless"); // never makeKey — #20's recipe
        if (plan.order_out) msg1v(self.panel, "orderOut:", null);
        if (plan.running != self.running) {
            msgBool(self.link, "setPaused:", !plan.running);
            self.running = plan.running;
        }
    }

    /// Run the pump for one frame at `now`. The autorelease pool covers the whole frame —
    /// plain CFRunLoopRun drains none of its own — so the per-frame Metal churn never piles up.
    fn runFrame(self: *MetalChrome, now: f64) void {
        const tick = self.tick orelse return;
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        tick(self.ctx.?, now, reduceMotion());
    }

    /// The wake source's perform callback, on the main thread. While the link runs it picks
    /// the change up on its next frame, so only a hidden pill renders here.
    fn wakePerform(info: ?*anyopaque) callconv(.c) void {
        const self: *MetalChrome = @ptrCast(@alignCast(info.?));
        if (!self.running) self.runFrame(CACurrentMediaTime());
    }

    /// The display link's callback, once per display frame while the pill is on screen.
    fn linkFired(_: id, _: SEL, link: id) callconv(.c) void {
        const self = g_metal_chrome orelse return;
        self.runFrame(msgF64(link, "targetTimestamp"));
    }

    /// Encode and present one Scene: one full-screen triangle through the SDF pass, the
    /// shapes as fragment bytes. The semantic colours re-resolve every frame, so the pill
    /// tracks light/dark with no notification wiring (ADR-0002, ADR-0014).
    fn draw(self: *MetalChrome, scene: *const Scene) void {
        const u = packUniforms(scene, resolvePalette(), self.scale);
        // Nil only when no drawable frees up within a second — skip it, the next frame catches up.
        const drawable = msg(self.layer, "nextDrawable");
        if (drawable == null) return;

        const rpd = msg(cls("MTLRenderPassDescriptor"), "renderPassDescriptor");
        const att = msgIdx(msg(rpd, "colorAttachments"), "objectAtIndexedSubscript:", 0);
        msg1v(att, "setTexture:", msg(drawable, "texture"));
        msgULong(att, "setLoadAction:", MTLLoadActionClear);
        msgULong(att, "setStoreAction:", MTLStoreActionStore);
        const setClear: *const fn (id, SEL, MTLClearColor) callconv(.c) void = @ptrCast(&objc_msgSend);
        setClear(att, sel_registerName("setClearColor:"), .{ .r = 0, .g = 0, .b = 0, .a = 0 });

        const cb = msg(self.queue, "commandBuffer");
        const enc = msg1(cb, "renderCommandEncoderWithDescriptor:", rpd);
        msg1v(enc, "setRenderPipelineState:", self.pipeline);
        const setBytes: *const fn (id, SEL, *const anyopaque, c_ulong, c_ulong) callconv(.c) void = @ptrCast(&objc_msgSend);
        setBytes(enc, sel_registerName("setFragmentBytes:length:atIndex:"), &u, @sizeOf(Uniforms), 0);
        const drawPrims: *const fn (id, SEL, c_ulong, c_ulong, c_ulong) callconv(.c) void = @ptrCast(&objc_msgSend);
        drawPrims(enc, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), MTLPrimitiveTypeTriangle, 0, 3);
        msgv(enc, "endEncoding");
        msg1v(cb, "presentDrawable:", drawable);
        msgv(cb, "commit");
    }

    /// The device, the runtime-compiled SDF pass, its pipeline and command queue, and the
    /// transparent layer it presents into. Any failure is `NoMetal`: sound-only, no fallback
    /// Chrome (ADR-0014).
    fn buildPipeline(self: *MetalChrome) error{NoMetal}!void {
        const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetal;
        var err: id = null;
        const newLibrary: *const fn (id, SEL, id, id, *id) callconv(.c) id = @ptrCast(&objc_msgSend);
        const lib = newLibrary(device, sel_registerName("newLibraryWithSource:options:error:"), nsString(msl_source), null, &err) orelse
            return error.NoMetal;
        defer msgv(lib, "release");
        const vs = msg1(lib, "newFunctionWithName:", nsString("vs"));
        defer msgv(vs, "release");
        const fs = msg1(lib, "newFunctionWithName:", nsString("fs"));
        defer msgv(fs, "release");

        const desc = msg(msg(cls("MTLRenderPipelineDescriptor"), "alloc"), "init");
        defer msgv(desc, "release");
        msg1v(desc, "setVertexFunction:", vs);
        msg1v(desc, "setFragmentFunction:", fs);
        msgULong(msgIdx(msg(desc, "colorAttachments"), "objectAtIndexedSubscript:", 0), "setPixelFormat:", MTLPixelFormatBGRA8Unorm);
        const newPipeline: *const fn (id, SEL, id, *id) callconv(.c) id = @ptrCast(&objc_msgSend);
        self.pipeline = newPipeline(device, sel_registerName("newRenderPipelineStateWithDescriptor:error:"), desc, &err) orelse
            return error.NoMetal;
        self.queue = msg(device, "newCommandQueue");

        // Premultiplied BGRA over whatever is behind the panel — proven clean by spike #356.
        const layer = msg(cls("CAMetalLayer"), "layer");
        msg1v(layer, "setDevice:", device);
        msgULong(layer, "setPixelFormat:", MTLPixelFormatBGRA8Unorm);
        msgBool(layer, "setOpaque:", false);
        msgBool(layer, "setFramebufferOnly:", true);
        msgDouble(layer, "setContentsScale:", self.scale);
        msgRect(layer, "setFrame:", .{ .x = 0, .y = 0, .w = region_w, .h = region_h });
        const setSize: *const fn (id, SEL, CGSize) callconv(.c) void = @ptrCast(&objc_msgSend);
        setSize(layer, sel_registerName("setDrawableSize:"), .{ .w = region_w * self.scale, .h = region_h * self.scale });
        self.layer = msg(layer, "retain"); // the panel's layer tree retains it too, once built
    }

    /// `NSScreen`'s display link, targeting a runtime-minted class (the `menu.zig` recipe),
    /// added paused to the main run loop. A 120 Hz timer is ruled out: `nextDrawable` blocks
    /// the main thread — the Talk Key tap's thread — while it waits (spike #356).
    fn buildLink(self: *MetalChrome, screen: id) error{NoDisplayLink}!void {
        g_metal_chrome = self;
        const target = msg(msg(linkTargetClass(), "alloc"), "init");
        const mk: *const fn (id, SEL, id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
        const link = mk(screen, sel_registerName("displayLinkWithTarget:selector:"), target, sel_registerName("onFrame:")) orelse
            return error.NoDisplayLink;
        self.link = msg(link, "retain");
        const setRange: *const fn (id, SEL, CAFrameRateRange) callconv(.c) void = @ptrCast(&objc_msgSend);
        setRange(link, sel_registerName("setPreferredFrameRateRange:"), .{ .minimum = 60, .maximum = 120, .preferred = 120 });
        msgBool(link, "setPaused:", true);
        const add: *const fn (id, SEL, id, ?*anyopaque) callconv(.c) void = @ptrCast(&objc_msgSend);
        add(link, sel_registerName("addToRunLoop:forMode:"), msg(cls("NSRunLoop"), "currentRunLoop"), kCFRunLoopCommonModes);
    }

    /// The panel: the Scene's region, placed so the pill sits where it always has
    /// (bottom-centre of the main screen, 140 pt up), with the focus-avoidance recipe.
    fn buildPanel(self: *MetalChrome, screen: id) void {
        const sf = screenFrame(screen);
        const rect = NSRect{ .x = sf.x + (sf.w - region_w) / 2.0, .y = sf.y + 140 - region_oy, .w = region_w, .h = region_h };
        const panel = makePanel(
            rect,
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            NSBackingStoreBuffered,
        );
        self.panel = panel;

        // --- the properties that keep it off the Focused Target (Q2, proven by #20) ---
        msgLong(panel, "setLevel:", NSStatusWindowLevel); // always on top
        msgBool(panel, "setIgnoresMouseEvents:", true); // clicks pass straight through
        msgBool(panel, "setFloatingPanel:", true); // NSPanel: don't hide on deactivate
        msgBool(panel, "setBecomesKeyOnlyIfNeeded:", true); // NSPanel: never steal key unasked
        msgULong(
            panel,
            "setCollectionBehavior:",
            NSWindowCollectionBehaviorCanJoinAllSpaces |
                NSWindowCollectionBehaviorStationary |
                NSWindowCollectionBehaviorFullScreenAuxiliary,
        );

        // Fully transparent window — nothing behind the marks, and no shadow: a window shadow
        // around an invisible pill draws a ghost outline (#25). Only the shader's output shows.
        msgBool(panel, "setOpaque:", false);
        msg1v(panel, "setBackgroundColor:", msg(cls("NSColor"), "clearColor"));
        msgBool(panel, "setHasShadow:", false);

        const content = msg(panel, "contentView");
        msgBool(content, "setWantsLayer:", true);
        msg1v(msg(content, "layer"), "addSublayer:", self.layer);
        // Built hidden — the first frame that shows the pill orders it in.
    }
};

/// The one MetalChrome, for the display link's target to find. The daemon owns a single
/// Chrome for the process lifetime, as `menu.zig` does its `g_menu`.
var g_metal_chrome: ?*MetalChrome = null;

/// `TWHudLinkTarget : NSObject`, whose `onFrame:` is `MetalChrome.linkFired`. Minted once.
fn linkTargetClass() id {
    if (cls("TWHudLinkTarget")) |c| return c;
    const c = objc_allocateClassPair(cls("NSObject"), "TWHudLinkTarget", 0);
    _ = class_addMethod(c, sel_registerName("onFrame:"), @ptrCast(&MetalChrome.linkFired), "v@:@");
    objc_registerClassPair(c);
    return c;
}

/// The five semantic colours, resolved against the current appearance. Per frame (ADR-0014).
fn resolvePalette() Palette {
    return .{
        .label = srgb("labelColor"),
        .secondary = srgb("secondaryLabelColor"),
        .orange = srgb("systemOrangeColor"),
        .green = srgb("systemGreenColor"),
        .red = srgb("systemRedColor"),
    };
}

/// A semantic NSColor pinned to sRGB, as straight components. Dynamic system colours must be
/// converted to a component colour space before their components can be read, and the
/// conversion resolves against the *current* appearance.
fn srgb(name: [*:0]const u8) [4]f32 {
    const c = msg1(msg(cls("NSColor"), name), "colorUsingColorSpace:", msg(cls("NSColorSpace"), "sRGBColorSpace"));
    var rgba: [4]f64 = .{ 0, 0, 0, 0 };
    const f: *const fn (id, SEL, *f64, *f64, *f64, *f64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(c, sel_registerName("getRed:green:blue:alpha:"), &rgba[0], &rgba[1], &rgba[2], &rgba[3]);
    return .{ @floatCast(rgba[0]), @floatCast(rgba[1]), @floatCast(rgba[2]), @floatCast(rgba[3]) };
}

/// The system's Reduce Motion setting (ADR-0014). Read per frame, so flipping it mid-dictation
/// takes effect on the next one.
fn reduceMotion() bool {
    const f: *const fn (id, SEL) callconv(.c) bool = @ptrCast(&objc_msgSend);
    return f(msg(cls("NSWorkspace"), "sharedWorkspace"), sel_registerName("accessibilityDisplayShouldReduceMotion"));
}

test "bare-marks geometry: 26 bars derive from the 300 pt pill" {
    // 6 pt bars / 4 pt gaps in 300−2×20 usable points → exactly 26 bars (ADR 0002).
    try std.testing.expectEqual(@as(usize, 26), n_bars);
}

test "bare-marks geometry: dots never clip the 22 pt pill" {
    // A dot's lowest bottom edge and highest top edge over a full bounce cycle
    // both stay inside the pill.
    const bottom = (pill_h - dot_size) / 2.0 - dot_bounce;
    const top = (pill_h - dot_size) / 2.0 + dot_bounce + dot_size;
    try std.testing.expect(bottom >= 0.0);
    try std.testing.expect(top <= pill_h);
    // The three-dot row fits the pill width.
    try std.testing.expect(dots_row_w <= pill_w);
}

test "Undo cue mark: fits the pill and clears the shake without escaping it" {
    // The 6×14 pt mark is centred and never clips the 22 pt pill vertically…
    try std.testing.expect(mark_h <= pill_h);
    try std.testing.expect((pill_h - mark_h) / 2.0 >= 0.0);
    // …and even at peak shake amplitude the mark stays inside the pill horizontally.
    const left = (pill_w - mark_w) / 2.0 - cue_shake_amp;
    const right = (pill_w - mark_w) / 2.0 + cue_shake_amp + mark_w;
    try std.testing.expect(left >= 0.0);
    try std.testing.expect(right <= pill_w);
}

test "levelToNorm: floor and below read flat" {
    // −60 dBFS is rms 10^(−60/20) = 0.001; at and below it the bar is flat.
    try std.testing.expectEqual(@as(f32, 0.0), levelToNorm(0.001));
    try std.testing.expectEqual(@as(f32, 0.0), levelToNorm(0.0001));
    try std.testing.expectEqual(@as(f32, 0.0), levelToNorm(0.0)); // log10 guard: no NaN/-inf
}

test "levelToNorm: ceiling and above read full" {
    // −10 dBFS is rms 10^(−10/20) ≈ 0.3162; at and above it the bar is full.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), levelToNorm(0.3163), 0.001);
    try std.testing.expectEqual(@as(f32, 1.0), levelToNorm(1.0));
}

test "levelToNorm: linear in dB between floor and ceiling" {
    // −35 dBFS (rms ≈ 0.01778) is the midpoint of −60..−10 → half height.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), levelToNorm(0.017783), 0.001);
    // A whisper around −44 dBFS lands visibly off the floor (~0.32) — the product goal.
    try std.testing.expectApproxEqAbs(@as(f32, 0.32), levelToNorm(0.00631), 0.01);
}

// ---- the transition sequencer's decision matrix (issue #51) -----------------
// Prior art: the Coordinator's numbered lifecycle matrix. Each test feeds a
// (published state, clock) sequence into a fresh Sequencer and asserts the
// decisions — the AppKit executor is not involved.

test "motion 1: press from idle starts the show fade with bars" {
    var seq = Sequencer{};
    // Idle hidden ticks decide nothing — the panel was never shown.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.hidden, 100.0));
    // Talk Key press → the pill fades in around a fresh waveform.
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .show_fade, .marks = .bars },
        seq.step(.recording, 100.05),
    );
}

test "motion 2: release crossfades the bars into the dots" {
    var seq = Sequencer{};
    _ = seq.step(.recording, 100.0);
    // Steady recording ticks decide nothing — the scroll is just height pokes.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.recording, 100.05));
    // Talk Key release → the handover animates; the window is untouched.
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .none, .marks = .crossfade },
        seq.step(.processing, 100.10),
    );
    // Held over the Insertion: nothing more to decide.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.processing, 100.15));
}

test "motion 3: resolution starts the hide fade, order-out deferred to its deadline" {
    var seq = Sequencer{};
    _ = seq.step(.recording, 100.0);
    _ = seq.step(.processing, 100.05);
    // The Utterance resolves → the hide starts; the marks stay untouched, so a
    // hide from processing freezes the dots and fades out around them. The
    // order-out waits for converge & drop (ADR-0014) to play.
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .hide_fade, .marks = .keep },
        seq.step(.hidden, 100.10),
    );
    try std.testing.expectEqual(@as(?f64, 100.10 + converge_dur), seq.hide_at);
}

test "motion 4: order-out fires exactly once, only past the deadline" {
    var seq = Sequencer{};
    _ = seq.step(.recording, 100.0);
    _ = seq.step(.processing, 100.05);
    _ = seq.step(.hidden, 100.10); // hide starts; deadline 100.10 + converge_dur
    // Mid-fade ticks decide nothing — the pill never disappears before the
    // fade completes.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.hidden, 100.15));
    // First tick at/past the deadline orders out…
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .order_out, .marks = .keep },
        seq.step(.hidden, 100.10 + converge_dur),
    );
    // …and only that tick: hidden is idle again from here on.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.hidden, 100.45));
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.hidden, 200.0));
}

test "motion 5: a press during the hide fade cancels it and records normally" {
    var seq = Sequencer{};
    _ = seq.step(.recording, 100.0);
    _ = seq.step(.processing, 100.05);
    _ = seq.step(.hidden, 100.10); // hide fade starts
    // A quick re-press mid-fade: the panel never left, so no show fade — the
    // pill snaps back and the new Utterance's waveform cuts in.
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .cancel_hide, .marks = .bars },
        seq.step(.recording, 100.14),
    );
    try std.testing.expectEqual(@as(?f64, null), seq.hide_at);
    // The stale deadline must not fire into the new Utterance.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.recording, 100.30));
    // And the cancelled hide leaves a full cycle intact: the next resolution
    // fades out and orders out as usual.
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .hide_fade, .marks = .keep },
        seq.step(.hidden, 100.40),
    );
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .order_out, .marks = .keep },
        seq.step(.hidden, 100.40 + converge_dur),
    );
}

test "motion 6: under Reduce Motion the hide is the plain fade, ordered out on its deadline" {
    var seq = Sequencer{ .reduce_motion = true };
    _ = seq.step(.processing, 100.0);
    _ = seq.step(.hidden, 100.05);
    try std.testing.expectEqual(@as(?f64, 100.05 + hide_dur), seq.hide_at);
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .order_out, .marks = .keep },
        seq.step(.hidden, 100.05 + hide_dur),
    );
}

// ---- the degraded-insertion amber pulse (ADR-0004) --------------------------

test "pulseEnvelope: ramps from 0 to full amber and clamps at both ends" {
    try std.testing.expectEqual(@as(f32, 0.0), pulseEnvelope(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), pulseEnvelope(pulse_dur));
    try std.testing.expectEqual(@as(f32, 1.0), pulseEnvelope(pulse_dur * 2.0)); // clamped
    try std.testing.expectEqual(@as(f32, 0.0), pulseEnvelope(-1.0)); // clamped
    // Monotonic non-decreasing across the ramp (easeOut is front-loaded, never dips).
    var prev: f32 = -1.0;
    var i: usize = 0;
    while (i <= 10) : (i += 1) {
        const v = pulseEnvelope(pulse_dur * @as(f64, @floatFromInt(i)) / 10.0);
        try std.testing.expect(v >= prev);
        prev = v;
    }
}

test "pulse 1: an armed pulse ends exactly once, on its deadline, then goes idle" {
    var seq = Sequencer{};
    // No pulse armed → idle.
    try std.testing.expect(!seq.pulseStep(50.0));

    seq.startPulse(100.0);
    // Mid-pulse ticks never end it (the Scene is tinting the dots meanwhile).
    try std.testing.expect(!seq.pulseStep(100.0));
    try std.testing.expect(!seq.pulseStep(100.15));
    // The first tick at/after the deadline ends the pulse…
    try std.testing.expect(seq.pulseStep(100.0 + pulse_dur));
    // …and only once: the deadline is cleared, so subsequent ticks are idle again.
    try std.testing.expect(!seq.pulseStep(100.0 + pulse_dur + 0.05));
}


// ---- the Undo confirm/refuse cue (ADR-0007, #226) ---------------------------

test "cueBloom: ramps 0 → full and clamps at both ends" {
    try std.testing.expectEqual(@as(f32, 0.0), cueBloom(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), cueBloom(cue_bloom_dur));
    try std.testing.expectEqual(@as(f32, 1.0), cueBloom(cue_bloom_dur * 2.0)); // clamped
    try std.testing.expectEqual(@as(f32, 0.0), cueBloom(-1.0)); // clamped
    // Monotonic non-decreasing across the ramp (easeOut is front-loaded, never dips).
    var prev: f32 = -1.0;
    var i: usize = 0;
    while (i <= 10) : (i += 1) {
        const v = cueBloom(cue_bloom_dur * @as(f64, @floatFromInt(i)) / 10.0);
        try std.testing.expect(v >= prev);
        prev = v;
    }
}

test "cueShake: bounded, ~3 oscillations, and settled to rest by the bloom's end" {
    // At rest at both ends: no offset before the shake starts or once it has settled.
    try std.testing.expectEqual(@as(f64, 0.0), cueShake(0.0));
    try std.testing.expectEqual(@as(f64, 0.0), cueShake(cue_bloom_dur));
    try std.testing.expectEqual(@as(f64, 0.0), cueShake(cue_bloom_dur + 0.1));
    // Bounded by the amplitude the whole way through, and it actually moves off centre.
    var moved = false;
    var crossings: usize = 0;
    var prev: f64 = 0.0;
    var i: usize = 1;
    while (i < 60) : (i += 1) {
        const t = cue_bloom_dur * @as(f64, @floatFromInt(i)) / 60.0;
        const x = cueShake(t);
        try std.testing.expect(@abs(x) <= cue_shake_amp + 0.0001);
        if (@abs(x) > 0.5) moved = true;
        if ((x > 0.0) != (prev > 0.0) and prev != 0.0) crossings += 1;
        prev = x;
    }
    try std.testing.expect(moved);
    // ~3 oscillations ⇒ several zero-crossings (a pure ±swing back and forth) — the motion
    // half of the refuse signal, so it reads without depending on the red hue (ADR-0007).
    try std.testing.expect(crossings >= 4);
}

test "cue 1: a confirm cue shows, blooms, holds, then self-hides exactly once" {
    var seq = Sequencer{};
    // Nothing armed → idle, the pump takes the normal path.
    try std.testing.expectEqual(Sequencer.Cue{}, seq.cueStep(100.0));

    seq.startCue(100.0, .confirm);
    // First tick brings the pill up around the mark.
    const a = seq.cueStep(100.0);
    try std.testing.expect(a.owns and a.window == .show_fade);
    try std.testing.expectEqual(Sequencer.CueKind.confirm, a.kind);

    // Mid-bloom and held after it: owned, and the show fade is not re-issued.
    try std.testing.expectEqual(Sequencer.Cue{ .owns = true }, seq.cueStep(100.0 + cue_bloom_dur / 2.0));
    try std.testing.expectEqual(Sequencer.Cue{ .owns = true }, seq.cueStep(100.0 + cue_bloom_dur + 0.05));

    // The hold elapses → the hide fade starts and arms the order-out. A tick safely past the
    // hold boundary (the clock crosses it within a frame or two).
    const hide_start = 100.0 + cue_shown_dur + 0.01;
    const d = seq.cueStep(hide_start);
    try std.testing.expect(d.owns and d.window == .hide_fade);
    try std.testing.expectEqual(@as(?f64, hide_start + hide_dur), seq.cue_hide_at);

    // Mid hide-fade: still owned, nothing to decide.
    try std.testing.expectEqual(Sequencer.Cue{ .owns = true }, seq.cueStep(hide_start + hide_dur / 2.0));

    // Past the deadline: order out exactly once, clearing the cue…
    const f = seq.cueStep(hide_start + hide_dur);
    try std.testing.expect(f.owns and f.window == .order_out);
    try std.testing.expectEqual(@as(?f64, null), seq.cue_at);
    // …and from here the pump is back on the normal path.
    try std.testing.expectEqual(Sequencer.Cue{}, seq.cueStep(hide_start + hide_dur + 0.05));
}

test "cue 2: a refuse mark shakes where a confirm mark holds still" {
    const centre: f32 = @floatCast(region_ox + pill_cx);
    var refuse: SceneState = .{};
    refuse.showMark(200.0, .refuse);
    const r = refuse.scene(200.0 + cue_bloom_dur / 4.0, false);
    try std.testing.expectEqual(Shape.Role.refuse, r.shapes[0].role);
    try std.testing.expect(@abs(r.shapes[0].cx - centre) > 0.5); // motion carries the outcome

    var confirm: SceneState = .{};
    confirm.showMark(200.0, .confirm);
    const g = confirm.scene(200.0 + cue_bloom_dur / 4.0, false);
    try std.testing.expectEqual(Shape.Role.confirm, g.shapes[0].role);
    try std.testing.expectEqual(centre, g.shapes[0].cx); // green still-bloom, no shake
}

test "cue: cancelCue abandons an in-flight cue so it never resumes on a later hidden tick" {
    // Models a Talk Key press right after the recovery chord: the pump cancels the cue and
    // hands the pill to the normal path. A subsequent hidden tick must NOT resume the cue.
    var seq = Sequencer{};
    seq.startCue(400.0, .refuse);
    try std.testing.expect(seq.cueStep(400.0).owns); // cue is live
    seq.cancelCue();
    try std.testing.expectEqual(@as(?f64, null), seq.cue_at);
    // Back on a hidden tick, the cue stays gone — the pump takes the normal path.
    try std.testing.expectEqual(Sequencer.Cue{}, seq.cueStep(400.10));
}


// ============================================================================
// The pump — the composition rules that decide what the user actually sees. Every test
// below drives the real `render` against a FakeChrome with a fed clock; before the Chrome
// seam they were either modelled in prose or not written at all.
// ============================================================================

/// Records the frames the pump emits, and counts the wakes. Because a Frame is a plain
/// comparable value, assertions are equality checks and counts over the Scene rather than a
/// call log.
const FakeChrome = struct {
    frames: [64]Frame = @splat(.{}),
    n: usize = 0,
    wakes: usize = 0,

    pub fn paint(self: *FakeChrome, frame: Frame) void {
        if (self.n < self.frames.len) {
            self.frames[self.n] = frame;
            self.n += 1;
        }
    }
    pub fn wake(self: *FakeChrome) void {
        self.wakes += 1;
    }
    fn last(self: *const FakeChrome) Frame {
        return self.frames[self.n - 1];
    }
    /// How many of the last frame's shapes carry `role`.
    fn count(self: *const FakeChrome, role: Shape.Role) usize {
        var c: usize = 0;
        for (self.last().scene.items()) |s| {
            if (s.role == role) c += 1;
        }
        return c;
    }
    /// The strongest amber in the last frame (ADR-0004).
    fn amber(self: *const FakeChrome) f32 {
        var a: f32 = 0;
        for (self.last().scene.items()) |s| a = @max(a, s.amber);
        return a;
    }
    /// How many emitted frames drew an Undo mark (ADR-0007).
    fn cues(self: *const FakeChrome) usize {
        var c: usize = 0;
        for (self.frames[0..self.n]) |f| {
            for (f.scene.items()) |s| {
                if (s.role == .confirm or s.role == .refuse) {
                    c += 1;
                    break;
                }
            }
        }
        return c;
    }
};

const TestHud = Hud(FakeChrome);

/// The tallest a silent bar gets: the floor plus the silence ripple.
const ripple_ceiling: f32 = @floatCast(min_bar_h + ripple_amp);

test "pump: a press shows the pill and draws bars; a release gathers them into dots" {
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.publish(.recording);
    h.render(100.0);
    try std.testing.expectEqual(Sequencer.WindowFx.show_fade, chrome.last().window);
    h.render(100.3); // the unfurl has played
    try std.testing.expect(chrome.count(.label) > n_bars / 2);
    try std.testing.expectEqual(@as(usize, 0), chrome.count(.secondary));

    h.publish(.processing);
    h.render(100.35);
    try std.testing.expect(chrome.count(.label) > 0); // the frozen bars start to gather
    h.render(100.35 + 0.6);
    try std.testing.expectEqual(@as(usize, 0), chrome.count(.label));
    try std.testing.expectEqual(@as(usize, 3), chrome.count(.secondary));
}

test "pump: a queued level scrolls into the newest bar, and a fresh Utterance starts flat" {
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.publish(.recording);
    h.pushLevel(0.1); // well above the −60 dB floor
    h.render(100.0);
    h.render(100.3);

    // The newest bar is the rightmost, and it stands clear of the silence ripple.
    var newest: Shape = .{};
    for (chrome.last().scene.items()) |s| {
        if (s.cx > newest.cx) newest = s;
    }
    try std.testing.expect(newest.h > ripple_ceiling + 1.0);

    // A second Utterance cuts back to `.bars`, which zeroes the scroll before this tick's
    // samples land — no bleed from the previous one.
    h.publish(.hidden);
    h.render(100.35);
    h.publish(.recording);
    h.render(100.40);
    h.render(100.70);
    for (chrome.last().scene.items()) |s| try std.testing.expect(s.h <= ripple_ceiling + 1e-4);
}

test "pump: a level pushed while not recording is dropped, never drawn" {
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.publish(.processing);
    h.pushLevel(0.9); // a straggler buffer flushed by capture.stop
    h.render(100.0);

    try std.testing.expectEqual(@as([n_bars + 1]f32, @splat(0)), h.scene_state.hist);
    try std.testing.expectEqual(@as(usize, 0), chrome.count(.label));
}

test "pump: a hidden tick carries the window op and the Scene — the dots converge out" {
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.publish(.processing);
    h.render(100.0);
    h.publish(.hidden);
    h.render(100.05);

    const scene = h.scene_state.scene(100.05, false);
    try std.testing.expectEqual(@as(usize, 3), scene.len);
    try std.testing.expectEqual(Frame{ .window = .hide_fade, .scene = scene }, chrome.last());
}

test "pump: the degraded pulse tints the dots amber, then resolves the pill to hidden (ADR-0004)" {
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.publish(.processing);
    h.render(100.0);
    h.pulseDegraded();
    h.render(100.05); // arms the envelope — still untinted at t = 0
    try std.testing.expectEqual(@as(usize, 3), chrome.count(.secondary));
    try std.testing.expectEqual(@as(f32, 0.0), chrome.amber());
    h.render(100.05 + pulse_dur / 2.0); // ramped in
    try std.testing.expect(chrome.amber() > 0.0);

    // Once the ~300 ms envelope elapses the pump resolves `.processing` to `.hidden` itself
    // and the converge carries the amber dots out.
    h.render(100.05 + pulse_dur);
    try std.testing.expectEqual(Sequencer.WindowFx.hide_fade, chrome.last().window);
    try std.testing.expectEqual(@as(f32, 1.0), chrome.amber());
}

test "pump: a degraded resolution with no processing pill degrades to a plain hide" {
    // The composition rule that lived on the untestable side of the old `active` gate.
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.publish(.recording);
    h.render(100.0);
    h.pulseDegraded(); // nothing to pulse — the pill is showing bars, not dots
    h.render(100.05);

    try std.testing.expectEqual(Sequencer.WindowFx.hide_fade, chrome.last().window);
    try std.testing.expectEqual(@as(?f64, null), h.scene_state.amber_since);
}

test "pump: an Undo cue arms from a hidden pill, blooms, and self-hides exactly once" {
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.undoConfirm();
    h.render(200.0);
    try std.testing.expectEqual(Sequencer.WindowFx.show_fade, chrome.last().window);

    h.render(200.0 + cue_bloom_dur);
    try std.testing.expectEqual(@as(usize, 1), chrome.last().scene.len);
    try std.testing.expectEqual(@as(usize, 1), chrome.count(.confirm));
    try std.testing.expect(chrome.last().scene.shapes[0].alpha > 0.9);

    // Hold elapses → hide fade, then the deferred order-out on an empty Scene.
    h.render(200.0 + cue_shown_dur);
    try std.testing.expectEqual(Sequencer.WindowFx.hide_fade, chrome.last().window);
    h.render(200.0 + cue_shown_dur + hide_dur);
    try std.testing.expectEqual(Frame{ .window = .order_out }, chrome.last());
}

test "pump: a refuse cue shakes where a confirm does not (ADR-0007)" {
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.undoRefuse();
    h.render(200.0);
    h.render(200.0 + 0.04);

    try std.testing.expectEqual(@as(usize, 1), chrome.count(.refuse));
    try std.testing.expect(@abs(chrome.last().scene.shapes[0].cx - region_w / 2.0) > 0.5);
}

test "pump: a second cue request while one is playing does not restart it" {
    // The arming guard — previously asserted by re-implementing it inside the test.
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.undoConfirm();
    h.render(200.0);
    h.undoRefuse(); // arrives mid-bloom
    h.render(200.0 + 0.04);

    // Still the SAME confirm cue: the refuse never displaced it, and never queued behind it.
    try std.testing.expectEqual(@as(usize, 1), chrome.count(.confirm));
    h.render(200.0 + cue_shown_dur);
    h.render(200.0 + cue_shown_dur + hide_dur);
    h.render(200.0 + cue_shown_dur + hide_dur + 0.05);
    try std.testing.expectEqual(Frame{}, chrome.last()); // nothing replayed the refuse
}

test "pump: a cue arriving while a pill is up is dropped, not queued" {
    // Deliberate (ADR-0007): a cue is glanceable and tied to its action, so one that cannot
    // be shown this tick is discarded rather than blooming later, detached from the press.
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.publish(.recording);
    h.render(100.0);
    h.undoConfirm(); // an Undo resolves while the user is mid-Utterance
    h.render(100.3);
    try std.testing.expect(chrome.count(.label) > 0); // the pill keeps the waveform

    // …and it never appears afterwards either.
    h.publish(.hidden);
    h.render(100.35);
    h.render(100.70);
    h.render(100.75);
    try std.testing.expectEqual(@as(usize, 0), chrome.cues());
}

test "pump: a Talk Key press preempts an in-flight cue and shows the pill this tick" {
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.undoConfirm();
    h.render(200.0);
    h.render(200.04);
    try std.testing.expectEqual(@as(usize, 1), chrome.count(.confirm));

    h.publish(.recording);
    h.render(200.08);

    // The cue is cancelled and the pill cuts to the waveform: the abandoned mark is gone.
    try std.testing.expectEqual(Sequencer.WindowFx.show_fade, chrome.last().window);
    try std.testing.expectEqual(@as(usize, 0), chrome.count(.confirm));
    try std.testing.expect(h.seq.cue_at == null);
    h.render(200.4);
    try std.testing.expect(chrome.count(.label) > 0);
}

test "pump: an overlay-disabled HUD publishes nothing, cues nothing, and reports isOn false" {
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.setEnabled(false);
    try std.testing.expect(!h.isOn());

    h.publish(.recording);
    h.undoConfirm();
    h.render(100.0);
    h.render(100.3);

    try std.testing.expectEqual(Frame{}, chrome.last());
    try std.testing.expectEqual(@as(usize, 0), chrome.cues());
}

test "pump: re-enabling the overlay lets the next Utterance show the pill again" {
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.setEnabled(false);
    h.publish(.recording);
    h.render(100.0);
    h.setEnabled(true);
    h.publish(.recording);
    h.render(100.05);

    try std.testing.expectEqual(Sequencer.WindowFx.show_fade, chrome.last().window);
}

test "pump: every accepted publish-side change wakes the Chrome; level samples do not" {
    // The Chrome's cadence idles while the pill is hidden, so a press, a resolution or a
    // cue must nudge it to render on the publishing edge ("show on the press").
    var chrome = FakeChrome{};
    var h = TestHud.init(&chrome);

    h.publish(.recording);
    try std.testing.expectEqual(@as(usize, 1), chrome.wakes);
    h.pushLevel(0.1); // the display link is already running while recording
    try std.testing.expectEqual(@as(usize, 1), chrome.wakes);
    h.publish(.processing);
    h.pulseDegraded();
    h.hide();
    h.undoConfirm();
    try std.testing.expectEqual(@as(usize, 5), chrome.wakes);

    // Switched off from the menu: the publish and the cue are dropped, so nothing to render.
    h.setEnabled(false);
    h.publish(.recording);
    h.undoRefuse();
    try std.testing.expectEqual(@as(usize, 5), chrome.wakes);
}

// ============================================================================
// The Scene (ADR-0014, #358). The pump runs at display rate here, as it will under
// MetalChrome, so every in-between frame the Chrome could draw is exercised.
// ============================================================================

test "easeCurve: pinned at both ends and never dips" {
    try std.testing.expectEqual(@as(f64, 0.0), easeCurve(0.0));
    try std.testing.expectEqual(@as(f64, 1.0), easeCurve(1.0));
    var prev: f64 = 0.0;
    for (1..20) |i| {
        const v = easeCurve(@as(f64, @floatFromInt(i)) / 20.0);
        try std.testing.expect(v > prev and v < 1.0);
        prev = v;
    }
}

const frame_dt: f64 = 1.0 / 120.0; // a ProMotion display link

/// Watches every Scene the pump emits: counts shapes that escape the panel region, tracks
/// the tallest recording bar, and keeps the latest Frame.
const SceneChrome = struct {
    last: Frame = .{},
    shapes: usize = 0,
    escaped: usize = 0,
    tallest_bar: f32 = 0,

    pub fn paint(self: *SceneChrome, frame: Frame) void {
        self.last = frame;
        for (frame.scene.items()) |s| {
            self.shapes += 1;
            if (s.cx - s.w / 2 < 0 or s.cx + s.w / 2 > region_w or
                s.cy - s.h / 2 < 0 or s.cy + s.h / 2 > region_h) self.escaped += 1;
            if (s.role == .label) self.tallest_bar = @max(self.tallest_bar, s.h);
        }
    }
    pub fn wake(_: *SceneChrome) void {}
};

const SceneHud = Hud(SceneChrome);

/// Render at display rate for `dur` seconds from `t0`, pushing one `rms` sample per Capture
/// buffer (dropped by the pump unless recording). Returns the clock where it stopped.
fn runFor(h: *SceneHud, t0: f64, dur: f64, rms: ?f32) f64 {
    var t = t0;
    var next_level = t0;
    while (t < t0 + dur) : (t += frame_dt) {
        if (rms) |r| if (t >= next_level) {
            h.pushLevel(r);
            next_level += capture_interval_s;
        };
        h.render(t);
    }
    return t;
}

test "scene: nothing draws outside the panel region" {
    for ([_]bool{ false, true }) |rm| {
        var chrome = SceneChrome{};
        var h = SceneHud.init(&chrome);
        h.setReduceMotion(rm);
        var t: f64 = 1000.0;

        // A full-scale Utterance, then a stalled pump that drains a burst of buffers in one
        // tick, a release, and a degraded Insertion that converges out amber.
        h.publish(.recording);
        t = runFor(&h, t, 0.8, 1.0);
        for (0..8) |_| h.pushLevel(1.0);
        t = runFor(&h, t, 0.3, 0.00631);
        h.publish(.processing);
        t = runFor(&h, t, 0.8, null);
        h.pulseDegraded();
        t = runFor(&h, t, 1.0, null);
        // A silent Utterance abandoned mid-recording (the bars converge), re-pressed mid-hide,
        // abandoned again, then a refuse cue shaking at full amplitude.
        h.publish(.recording);
        t = runFor(&h, t, 0.6, 0.0);
        h.hide();
        t = runFor(&h, t, 0.1, null);
        h.publish(.recording);
        t = runFor(&h, t, 0.4, 0.05);
        h.hide();
        t = runFor(&h, t, 0.5, null);
        h.undoRefuse();
        t = runFor(&h, t, 1.0, null);

        try std.testing.expect(chrome.shapes > 1000); // the Scene really was drawing
        try std.testing.expectEqual(@as(usize, 0), chrome.escaped);
    }
}

test "scene: converge ends at zero alpha, on the Sequencer's order-out deadline" {
    // From the dots (an Insertion) and from the bars (an abandoned Utterance).
    for ([_]State{ .processing, .recording }) |from| {
        var chrome = SceneChrome{};
        var h = SceneHud.init(&chrome);
        h.publish(from);
        const t = runFor(&h, 1000.0, 0.6, 0.1);
        h.hide();
        h.render(t); // converge & drop starts
        try std.testing.expectEqual(Sequencer.WindowFx.hide_fade, chrome.last.window);

        // Mid-converge the marks are still on screen, gathering on the centre…
        try std.testing.expect(h.scene_state.scene(t + converge_dur / 2.0, false).len > 0);
        // …and at the deadline every one has faded to nothing, so none is emitted.
        try std.testing.expectEqual(@as(usize, 0), h.scene_state.scene(t + converge_dur, false).len);
        h.render(t + converge_dur);
        try std.testing.expectEqual(Sequencer.WindowFx.order_out, chrome.last.window);
    }
}

test "scene: the degraded pulse's amber carries through converge (ADR-0004)" {
    var chrome = SceneChrome{};
    var h = SceneHud.init(&chrome);
    h.publish(.processing);
    var t = runFor(&h, 1000.0, 0.6, null);
    h.pulseDegraded();
    // Run until the pulse elapses and the pump hands the pill to the hide.
    while (chrome.last.window != .hide_fade) : (t += frame_dt) h.render(t);

    // Every frame of the converge carries the dots at full amber, right up to the order-out.
    var dots_seen: usize = 0;
    while (chrome.last.window != .order_out) : (t += frame_dt) {
        for (chrome.last.scene.items()) |s| {
            try std.testing.expectEqual(Shape.Role.secondary, s.role);
            try std.testing.expectEqual(@as(f32, 1.0), s.amber);
            dots_seen += 1;
        }
        h.render(t);
    }
    try std.testing.expect(dots_seen > 30);
}

/// Every shape in `b` is the same shape in `a` with its alpha scaled by `k`.
fn expectFaded(a: Scene, b: Scene, k: f64) !void {
    try std.testing.expectEqual(a.len, b.len);
    for (a.items(), b.items()) |x, y| {
        try std.testing.expectEqual(x.cx, y.cx);
        try std.testing.expectEqual(x.w, y.w);
        try std.testing.expectEqual(x.h, y.h);
        try std.testing.expectApproxEqAbs(@as(f64, x.alpha) * k, @as(f64, y.alpha), 1e-4);
    }
}

test "scene: reduce_motion reproduces the fade + crossfade, with no unfurl, gather or converge" {
    var chrome = SceneChrome{};
    var h = SceneHud.init(&chrome);
    h.setReduceMotion(true);
    const ss = &h.scene_state;

    // Show: a plain eased fade. Nothing scales in — every bar is its full 6 pt from the start.
    h.publish(.recording);
    for (0..n_bars) |_| h.pushLevel(0.05);
    const t0 = 1000.0;
    h.render(t0);
    const settled = t0 + 0.1; // past the glide and the newest bar's spring
    const shown = ss.scene(settled + show_dur, true);
    try std.testing.expect(shown.len > n_bars / 2);
    for (shown.items()) |s| try std.testing.expectEqual(@as(f32, bar_w), s.w);
    const frac = 0.1 / show_dur;
    try expectFaded(shown, ss.scene(settled, true), easeCurve(frac));

    // Release: the frozen bars crossfade out in place while the dots fade in at full size.
    const t1 = t0 + 1.0;
    h.publish(.processing);
    h.render(t1);
    const snap = ss.scene(t1, true); // the dots start transparent, so this is the bars alone
    for (snap.items()) |s| try std.testing.expectEqual(Shape.Role.label, s.role);
    const mid = ss.scene(t1 + cross_dur / 4.0, true);
    var bars_mid: Scene = .{};
    var dots_mid: usize = 0;
    for (mid.items()) |s| switch (s.role) {
        .label => {
            bars_mid.shapes[bars_mid.len] = s;
            bars_mid.len += 1;
        },
        else => {
            try std.testing.expectEqual(@as(f32, @floatCast(dot_size)), s.w); // no squash, no pop-in
            try std.testing.expectApproxEqAbs(easeCurve(0.25), @as(f64, s.alpha), 1e-4);
            dots_mid += 1;
        },
    };
    try std.testing.expectEqual(@as(usize, 3), dots_mid);
    try expectFaded(snap, bars_mid, 1.0 - easeCurve(0.25));
    const after = ss.scene(t1 + cross_dur + 0.03, true);
    try std.testing.expectEqual(@as(usize, 3), after.len); // the bars are gone, the dots stay

    // Hide: the dots fade where they are over `hide_dur` — no merge, no drop.
    const t2 = t1 + 1.0;
    h.hide();
    h.render(t2);
    try std.testing.expectEqual(@as(?f64, t2 + hide_dur), h.seq.hide_at);
    const fading = ss.scene(t2 + hide_dur / 2.0, true);
    try std.testing.expectEqual(@as(usize, 3), fading.len);
    for (fading.items(), 0..) |s, j| {
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(region_ox + dotCX(@floatFromInt(j)))), s.cx, 1e-4);
        try std.testing.expectEqual(@as(f32, @floatCast(dot_size)), s.w);
        try std.testing.expectApproxEqAbs(1.0 - easeCurve(0.5), @as(f64, s.alpha), 1e-4);
    }
    h.render(t2 + hide_dur);
    try std.testing.expectEqual(Sequencer.WindowFx.order_out, chrome.last.window);
}

test "scene: a whisper still lifts the bars above the silence ripple's ceiling" {
    var chrome = SceneChrome{};
    var h = SceneHud.init(&chrome);
    const ceiling: f32 = @floatCast(min_bar_h + ripple_amp);

    // Silence: once the unfurl has settled, the ripple breathes but never clears its ceiling.
    h.publish(.recording);
    var t = runFor(&h, 1000.0, 0.6, 0.0);
    chrome.tallest_bar = 0;
    t = runFor(&h, t, 1.5, 0.0);
    try std.testing.expect(chrome.tallest_bar > min_bar_h + 0.5); // it does move
    try std.testing.expect(chrome.tallest_bar <= ceiling + 1e-4);

    // A whisper (~−44 dBFS) stands clear of it.
    chrome.tallest_bar = 0;
    _ = runFor(&h, t, 1.5, 0.00631);
    try std.testing.expect(chrome.tallest_bar > ceiling + 1.0);
}

// ============================================================================
// MetalChrome's pure half (#359): what one Scene becomes as shader input.
// ============================================================================

const test_palette = Palette{
    .label = .{ 1, 1, 1, 0.85 },
    .secondary = .{ 1, 1, 1, 0.55 },
    .orange = .{ 1, 0.62, 0.04, 1 },
    .green = .{ 0.2, 0.84, 0.29, 1 },
    .red = .{ 1, 0.27, 0.23, 1 },
};

test "uniforms: shapes land y-down in the drawable, one slot each, with the locked goo and glow" {
    var scene: Scene = .{};
    scene.shapes[0] = .{ .cx = 20, .cy = 10, .w = 6, .h = 14, .role = .label, .alpha = 1 };
    scene.shapes[1] = .{ .cx = 170, .cy = 40, .w = 8, .h = 8, .role = .secondary, .alpha = 0.5 };
    scene.len = 2;

    const u = packUniforms(&scene, test_palette, 2.0);
    try std.testing.expectEqual(@as(i32, 2), u.count);
    try std.testing.expectEqual([2]f32{ region_w * 2, region_h * 2 }, u.res);
    try std.testing.expectEqual(@as(f32, 2), u.px);
    try std.testing.expectEqual(goo_k, u.k);
    try std.testing.expectEqual(glow_strength, u.glow);
    // The Scene is y-up (the panel's convention); Metal's fragment origin is top-left.
    try std.testing.expectEqual([4]f32{ 20, region_h - 10, 6, 14 }, u.geo[0]);
    try std.testing.expectEqual([4]f32{ 170, region_h - 40, 8, 8 }, u.geo[1]);
    // Unused slots stay zeroed, so no stale shape can ride along.
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, u.geo[2]);
}

test "uniforms: each role takes its own semantic colour, with the shape's alpha folded in" {
    var scene: Scene = .{};
    const roles = [_]Shape.Role{ .label, .secondary, .confirm, .refuse };
    for (roles, 0..) |role, i| scene.shapes[i] = .{ .w = 6, .h = 6, .role = role, .alpha = 0.5 };
    scene.len = roles.len;

    const u = packUniforms(&scene, test_palette, 2.0);
    const want = [_][4]f32{ test_palette.label, test_palette.secondary, test_palette.green, test_palette.red };
    for (want, 0..) |c, i| {
        try std.testing.expectEqual([4]f32{ c[0], c[1], c[2], c[3] * 0.5 }, u.col[i]);
        try std.testing.expectEqual(@as(f32, 0.5), u.fade[i]);
    }
}

test "uniforms: the amber weight blends systemOrange into the dot, alpha included (ADR-0004)" {
    var scene: Scene = .{};
    scene.shapes[0] = .{ .w = 6, .h = 6, .role = .secondary, .alpha = 1, .amber = 1 };
    scene.shapes[1] = .{ .w = 6, .h = 6, .role = .secondary, .alpha = 1, .amber = 0.5 };
    scene.len = 2;

    const u = packUniforms(&scene, test_palette, 1.0);
    try std.testing.expectEqual(test_palette.orange, u.col[0]);
    for (0..4) |c| {
        const mid = (test_palette.secondary[c] + test_palette.orange[c]) / 2;
        try std.testing.expectApproxEqAbs(mid, u.col[1][c], 1e-6);
    }
}

test "uniforms: every Scene fits the shader's shape array" {
    try std.testing.expect(scene_cap <= max_shapes);
}

test "chrome plan: a hidden pill costs nothing — no draw, no link, until a frame shows it" {
    // Idle hidden frames (a wake for a `.hidden` publish, a switched-off overlay) do no GPU work.
    try std.testing.expectEqual(ChromePlan{}, ChromePlan.of(false, .none));
    // The show: draw first (so nothing stale flashes), order in, start the display link.
    try std.testing.expectEqual(ChromePlan{ .draw = true, .order_front = true, .running = true }, ChromePlan.of(false, .show_fade));
    // Shown: every frame draws, whatever the window op — the fades live in the Scene.
    for ([_]Sequencer.WindowFx{ .none, .hide_fade, .cancel_hide }) |fx|
        try std.testing.expectEqual(ChromePlan{ .draw = true, .running = true }, ChromePlan.of(true, fx));
    // The order-out: draw the empty Scene (so the layer holds nothing), take the panel out,
    // and stop the link — the pill is hidden, and hidden costs nothing.
    try std.testing.expectEqual(ChromePlan{ .draw = true, .order_out = true }, ChromePlan.of(true, .order_out));
}
