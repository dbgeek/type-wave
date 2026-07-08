//! hud.zig — the silent waveform pill, driven PURELY through the ObjC runtime
//! C API (objc_getClass / sel_registerName / objc_msgSend) from Zig. No Swift, no
//! ObjC shim .m files. The panel + focus-avoidance recipe graduated from
//! prototypes/overlay-hud (wayfinder #20/#22); the waveform mechanism — a fixed row
//! of plain CALayers whose frames the render pump pokes each tick — graduated from
//! prototypes/waveform-hud (wayfinder #25, into the daemon by #27). The HUD shows
//! **no text, ever**: while recording it scrolls live mic volume as bars; after the
//! Talk Key release three green dots bounce until the Insertion resolves.
//!
//! The msgSend pattern (cast &objc_msgSend to a typed fn-pointer per call site) is
//! the exact one proven for NSPasteboard in src/insert.zig, extended to NSPanel /
//! NSColor / NSScreen / CALayer / CATransaction.
//!
//! # How it composes with the daemon
//!
//!   - **All AppKit calls stay on the main thread.** The daemon's main thread runs
//!     `CFRunLoopRun` (src/tap.zig) servicing the Talk Key tap; the HUD adds a
//!     `CFRunLoopTimer` render pump to that same loop (no `[NSApp run]` — proven by
//!     #20, and 20 Hz proven smooth for the scroll by #25). `init` +
//!     `startRenderPump` + every `render` tick run there.
//!   - **Producers publish from any thread.** `publish(state)` sets the lifecycle
//!     state; `pushLevel(rms)` queues one raw linear RMS sample per 50 ms Capture
//!     buffer from the audio queue's thread. Both are mutex-guarded, no AppKit.
//!     The render pump drains the queue and pokes the layers — a queue, not a
//!     latest-value slot, so the scroll advances exactly one bar per buffer
//!     regardless of pump jitter (#26).
//!   - **Headless degrades cleanly.** `init` returns `false` when there is no display
//!     (`[NSScreen mainScreen]` is nil — e.g. a bare-SSH run); the daemon then leaves
//!     the HUD inactive and every method is a no-op, falling back to sound-only
//!     feedback (#18) without failing startup.
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
// [self op:a]  (id arg) -> void
inline fn msg1v(self: id, op: [*:0]const u8, a: id) void {
    const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), a);
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

// ---- Cocoa geometry ---------------------------------------------------------
/// NSRect == {origin{x,y}, size{w,h}}; flat here, identical layout. Four f64 = an HFA,
/// so it is passed/returned in SIMD regs by the arm64 C ABI (Zig lowers this for us).
const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

/// [NSColor colorWithSRGBRed:green:blue:alpha:]
inline fn rgba(r: f64, g: f64, b: f64, a: f64) id {
    const f: *const fn (id, SEL, f64, f64, f64, f64) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSColor"), sel_registerName("colorWithSRGBRed:green:blue:alpha:"), r, g, b, a);
}
/// CGColorRef from an NSColor — CALayer.backgroundColor wants the CG flavour.
inline fn cgColor(nscolor: id) id {
    return msg(nscolor, "CGColor");
}
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

// ---- CFRunLoopTimer render pump (main thread) -------------------------------
const CFRunLoopTimerRef = ?*anyopaque;
const CFRunLoopRef = ?*anyopaque;
const CFRunLoopTimerContext = extern struct {
    version: c_long = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copyDescription: ?*const anyopaque = null,
};
extern "c" fn CFAbsoluteTimeGetCurrent() f64;
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopAddTimer(rl: CFRunLoopRef, timer: CFRunLoopTimerRef, mode: ?*anyopaque) void;
extern "c" fn CFRunLoopTimerCreate(
    alloc: ?*anyopaque,
    fireDate: f64,
    interval: f64,
    flags: c_ulong,
    order: c_long,
    callout: *const fn (CFRunLoopTimerRef, ?*anyopaque) callconv(.c) void,
    context: ?*CFRunLoopTimerContext,
) CFRunLoopTimerRef;
extern var kCFRunLoopCommonModes: ?*anyopaque;

/// How often the render pump pokes the layers. 20 Hz — proven smooth for the scroll
/// with implicit animations off (#25), cheap on an idle (hidden) tick.
const render_interval_s: f64 = 0.05;

// ---- the look (HITL-decided in #25; fixed, no config knob) --------------------
const pill_w: f64 = 420;
const pill_h: f64 = 60;
const bar_w: f64 = 3;
const bar_gap: f64 = 2;
const pad_x: f64 = 20; // inner margin before the first / after the last bar
const min_bar_h: f64 = 3; // silence reads as a flat dotted line, not nothing
const max_bar_h: f64 = pill_h * 0.72; // headroom so a full bar never kisses the edge
const dot_size: f64 = 12;
const dot_gap: f64 = 10;

/// How many bars fit the pill. Also how much history it shows: at one level per
/// 50 ms Capture buffer, n_bars/20 seconds scroll across it (76 bars ≈ 3.8 s).
const n_bars: usize = @intFromFloat(@floor((pill_w - 2 * pad_x + bar_gap) / (bar_w + bar_gap)));

/// What the pill is doing — drives which layer family is visible. The daemon maps its
/// Utterance lifecycle onto these: `recording` on Talk Key press (scrolling waveform),
/// `processing` on release (green dots, held over the whole Insertion), `hidden` once
/// the Utterance resolves (inserted, abandoned, empty, or timed out).
pub const State = enum { hidden, recording, processing };

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

/// The floating waveform pill. AppKit objects are owned by the view/window hierarchy once
/// wired up; this struct caches the layer handles the render pump pokes plus the mutex-
/// guarded (state, level-queue) the producers publish into. A single instance lives for
/// the daemon's process lifetime.
pub const Hud = struct {
    // ---- AppKit handles (main-thread only) ----
    panel: id = null,
    bars: [n_bars]id = @splat(null), // the waveform — heights poked per tick
    dots: [3]id = @splat(null), // the processing animation

    /// False until `init` succeeds; false forever on a headless start. Every public
    /// method no-ops while false, so the daemon can call them unconditionally.
    active: bool = false,

    // ---- producer → render handoff (any thread writes, main thread reads) ----
    mu: os_unfair_lock = .{},
    /// The live Overlay toggle (wayfinder #32/#34): a built HUD that has been switched
    /// off from the menu keeps all its machinery — no teardown path is ever exercised —
    /// but ignores lifecycle publishes, so it never shows; re-enable is instant. Guarded
    /// by `mu` like the state it gates.
    enabled: bool = true,
    pending_state: State = .hidden,
    q: [level_queue_cap]f32 = @splat(0), // raw linear RMS, one sample per Capture buffer
    qlen: usize = 0,

    // ---- render-thread-only ----
    shown: bool = false,
    /// Scroll buffer of NORMALIZED heights: levels[n_bars-1] is the newest (rightmost)
    /// bar. Bars themselves never move — heights march left, one slot per sample.
    levels: [n_bars]f32 = @splat(0),
    /// Which layer family the last tick left visible — visibility flips only on state
    /// transitions, so a steady-state tick is just height pokes.
    last_visible: ?State = null,

    /// Backs the CFRunLoopTimer's context (it borrows `&self.timer_ctx`); lives as long
    /// as the Hud, i.e. the process. Set in `startRenderPump`.
    timer_ctx: CFRunLoopTimerContext = .{},

    /// Build the panel + all layers (hidden) and bring AppKit up as an accessory app.
    /// Returns `false` when there is no display (headless) — the daemon then stays
    /// sound-only. MUST run on the main thread, before the run loop starts. Idempotent
    /// guard: a second call is a no-op.
    pub fn init(self: *Hud) bool {
        if (self.active) return true;
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // Shared, accessory-policy app (appkit.zig — also used by the menu-bar status
        // item, #34). Order matters — the policy is set before finishLaunching so no
        // Dock icon ever flashes.
        _ = appkit.app();

        // No display ⇒ no HUD. Bail before finishLaunching / any window work so a headless
        // run degrades to sound-only instead of failing (wayfinder #22).
        const screen = mainScreen();
        if (screen == null) return false;

        // finishLaunching wires up AppKit enough to draw whether the loop is the headless
        // CFRunLoopRun (proven by #20) or [NSApp run] under the status item (#31/#34).
        appkit.ensureLaunched();

        // Bottom-centre of the main screen — the Wispr-Flow pill position.
        const sf = screenFrame(screen);
        const rect = NSRect{ .x = sf.x + (sf.w - pill_w) / 2.0, .y = sf.y + 140, .w = pill_w, .h = pill_h };

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

        // Fully transparent window — no pill background, and no shadow: a window shadow
        // around an invisible pill draws a ghost outline (#25). Only the bars/dots show.
        msgBool(panel, "setOpaque:", false);
        msg1v(panel, "setBackgroundColor:", msg(cls("NSColor"), "clearColor"));
        msgBool(panel, "setHasShadow:", false);

        const content = msg(panel, "contentView");
        msgBool(content, "setWantsLayer:", true);
        const layer = msg(content, "layer");

        // The whole mechanism (#25): a fixed row of plain CALayers. [CALayer layer]
        // returns autoreleased; addSublayer: retains, so the hierarchy owns them after
        // this. Colours never change — recording red bars, green dots — so they are set
        // once here; state changes only flip visibility.
        const bar_color = cgColor(rgba(1.0, 0.38, 0.38, 1.0)); // recording tint-red
        const dot_color = cgColor(rgba(0.30, 0.85, 0.45, 1.0)); // processing green
        const row_w = @as(f64, @floatFromInt(n_bars)) * (bar_w + bar_gap) - bar_gap;
        const x0 = (pill_w - row_w) / 2.0;
        for (&self.bars, 0..) |*bar, i| {
            bar.* = msg(cls("CALayer"), "layer");
            msgBool(bar.*, "setHidden:", true);
            msg1v(bar.*, "setBackgroundColor:", bar_color);
            msgDouble(bar.*, "setCornerRadius:", bar_w / 2.0);
            msgRect(bar.*, "setFrame:", barFrame(i, min_bar_h, x0));
            msg1v(layer, "addSublayer:", bar.*);
        }
        const dots_w = 3 * dot_size + 2 * dot_gap;
        for (&self.dots, 0..) |*dot, j| {
            dot.* = msg(cls("CALayer"), "layer");
            msgBool(dot.*, "setHidden:", true);
            msg1v(dot.*, "setBackgroundColor:", dot_color);
            msgDouble(dot.*, "setCornerRadius:", dot_size / 2.0);
            const fj: f64 = @floatFromInt(j);
            msgRect(dot.*, "setFrame:", .{
                .x = (pill_w - dots_w) / 2.0 + fj * (dot_size + dot_gap),
                .y = (pill_h - dot_size) / 2.0,
                .w = dot_size,
                .h = dot_size,
            });
            msg1v(layer, "addSublayer:", dot.*);
        }

        // Built hidden — the daemon orders it in on the first Talk Key press.
        self.active = true;
        return true;
    }

    /// Add the render pump to the CURRENT run loop (the daemon's main thread, before its
    /// CFRunLoopRun). No-op if the HUD isn't active. The timer fires on the main thread, so
    /// its `renderTick` is the only place AppKit is touched after `init`.
    pub fn startRenderPump(self: *Hud) void {
        if (!self.active) return;
        self.timer_ctx = .{ .info = self };
        const timer = CFRunLoopTimerCreate(
            null,
            CFAbsoluteTimeGetCurrent() + render_interval_s,
            render_interval_s,
            0,
            0,
            renderTick,
            &self.timer_ctx,
        );
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
    }

    /// Publish a lifecycle state. Thread-safe, no AppKit — called from the run-loop thread
    /// (Talk Key press/release) and wherever the Utterance resolves. A state change clears
    /// the level queue so a stale sample never bleeds into the next Utterance. A no-op when
    /// the HUD is inactive.
    pub fn publish(self: *Hud, state: State) void {
        if (!self.active) return;
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        if (!self.enabled and state != .hidden) return; // switched off from the menu
        if (state != self.pending_state) self.qlen = 0;
        self.pending_state = state;
    }

    /// The menu's live Overlay toggle. Disable hides the pill immediately (the render
    /// pump keeps ticking — a hidden tick is just the lock and a state check); enable
    /// lets the next Utterance show it again. No-op while inactive (headless).
    pub fn setEnabled(self: *Hud, on: bool) void {
        if (!self.active) return;
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        self.enabled = on;
        if (!on) {
            self.pending_state = .hidden;
            self.qlen = 0;
        }
    }

    /// Whether the pill is carrying feedback right now — built AND enabled. The Feedback
    /// Surface consults this per verb, so a disabled overlay falls back to sound cues
    /// exactly like an overlay=false start.
    pub fn isOn(self: *Hud) bool {
        if (!self.active) return false;
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        return self.enabled;
    }

    /// Take the pill down. Called at the end of an Utterance (inserted, abandoned, empty,
    /// timed out). Since the Utterance lifecycle is fully serialized (ADR-0001) — no new
    /// `.recording` pill can exist until the current Insertion resolves — this is an
    /// unconditional hide. No-op when inactive.
    pub fn hide(self: *Hud) void {
        self.publish(.hidden);
    }

    /// Queue one raw linear RMS sample (0..1 of full scale) — one Capture buffer's
    /// loudness, i.e. one new bar. Called from the audio queue's thread; no AppKit.
    /// Dropped unless the published state is `.recording`, so a straggler buffer
    /// flushed by `capture.stop` can't repaint a processing/hidden pill.
    pub fn pushLevel(self: *Hud, rms: f32) void {
        if (!self.active) return;
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        if (self.pending_state != .recording) return;
        if (self.qlen < self.q.len) {
            self.q[self.qlen] = rms;
            self.qlen += 1;
        }
    }

    /// Reflect the published state into the layers. Main thread only (the render pump).
    /// An autorelease pool keeps the per-tick ObjC churn from piling up.
    fn render(self: *Hud) void {
        // Snapshot + drain under the lock, then release it before any AppKit — never
        // message ObjC while holding the spinlock (it would stall the audio producer).
        var drained: [level_queue_cap]f32 = undefined;
        os_unfair_lock_lock(&self.mu);
        const st = self.pending_state;
        const n = self.qlen;
        @memcpy(drained[0..n], self.q[0..n]);
        self.qlen = 0;
        os_unfair_lock_unlock(&self.mu);

        if (st == .hidden) {
            if (self.shown) {
                msgv(self.panel, "orderOut:");
                self.shown = false;
                self.levels = @splat(0); // next Utterance starts from a flat line
            }
            return;
        }

        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // Batch every layer poke into one transaction with implicit animations off —
        // at 20 Hz, CA's 0.25 s implicit fades would smear the scroll (#25).
        msgv(cls("CATransaction"), "begin");
        msgBool(cls("CATransaction"), "setDisableActions:", true);
        defer msgv(cls("CATransaction"), "commit");

        self.setVisibleFamily(st);

        const row_w = @as(f64, @floatFromInt(n_bars)) * (bar_w + bar_gap) - bar_gap;
        const x0 = (pill_w - row_w) / 2.0;
        switch (st) {
            .hidden => unreachable,
            .recording => {
                // One drained sample = the scroll advances one bar. The dB mapping is
                // applied here, as levels come off the queue (#26).
                for (drained[0..n]) |rms| {
                    std.mem.copyForwards(f32, self.levels[0 .. n_bars - 1], self.levels[1..]);
                    self.levels[n_bars - 1] = levelToNorm(rms);
                }
                for (self.levels, 0..) |lv, i| {
                    const h = min_bar_h + @as(f64, @floatCast(lv)) * (max_bar_h - min_bar_h);
                    msgRect(self.bars[i], "setFrame:", barFrame(i, h, x0));
                }
            },
            .processing => {
                // Three bouncing green dots, phase-offset — held until the Insertion
                // resolves and the daemon publishes .hidden.
                const t = CFAbsoluteTimeGetCurrent();
                const dots_w = 3 * dot_size + 2 * dot_gap;
                for (self.dots, 0..) |dot, j| {
                    const fj: f64 = @floatFromInt(j);
                    msgRect(dot, "setFrame:", .{
                        .x = (pill_w - dots_w) / 2.0 + fj * (dot_size + dot_gap),
                        .y = (pill_h - dot_size) / 2.0 + 11.0 * @sin(t * 5.0 + fj * 0.8),
                        .w = dot_size,
                        .h = dot_size,
                    });
                }
            },
        }

        if (!self.shown) {
            msgv(self.panel, "orderFrontRegardless"); // never makeKey — #20's recipe
            self.shown = true;
        }
    }

    /// Flip which layer family is visible (bars while recording, dots while processing).
    /// Only on transitions — a steady-state tick skips all 79 setHidden: calls.
    fn setVisibleFamily(self: *Hud, st: State) void {
        if (self.last_visible == st) return;
        self.last_visible = st;
        const dots_mode = st == .processing;
        for (self.bars) |bar| msgBool(bar, "setHidden:", dots_mode);
        for (self.dots) |dot| msgBool(dot, "setHidden:", !dots_mode);
    }
};

/// The frame of bar `i` at height `h`, vertically centred. Bars never move in x/w —
/// only their height (and the y that keeps them centred) is poked per tick.
fn barFrame(i: usize, h: f64, x0: f64) NSRect {
    const fi: f64 = @floatFromInt(i);
    return .{
        .x = x0 + fi * (bar_w + bar_gap),
        .y = (pill_h - h) / 2.0,
        .w = bar_w,
        .h = h,
    };
}

/// CFRunLoopTimer callout — trampolines to `render` on the main thread.
fn renderTick(_: CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self: *Hud = @ptrCast(@alignCast(info.?));
    self.render();
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
