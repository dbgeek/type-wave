//! appkit.zig — the one place the daemon brings NSApplication up and runs it down
//! (wayfinder #34). Two modules present AppKit UI — the overlay HUD (hud.zig) and the
//! menu-bar status item (menu.zig) — and either may be the first to need the app, so the
//! bring-up (shared accessory-policy app + `finishLaunching`) lives here behind a
//! once-guard instead of being duplicated per module.
//!
//! It also owns the main loop's run/stop pair. The #31 spike's load-bearing finding: a
//! bare `CFRunLoopRun()` spins the main run loop but never runs AppKit's
//! `nextEvent → sendEvent:` dispatch, so status-item clicks are never routed and the menu
//! never pops. `[NSApp run]` drives the SAME main run loop — the CGEventTap source
//! (tap.zig) and the HUD's CFRunLoopTimer keep firing under it — plus the event dispatch
//! the status item needs. `run`/`stop` here are that swap; the headless daemon path (no
//! display, no status item) keeps blocking on plain CFRunLoopRun via tap.run().
//!
//! Same ObjC-runtime msgSend pattern as insert.zig / hud.zig. Apple Silicon only.

// ---- ObjC runtime primitives -------------------------------------------------
const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site

inline fn cls(name: [*:0]const u8) id {
    return objc_getClass(name);
}
inline fn msg(self: id, op: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}
inline fn msgv(self: id, op: [*:0]const u8) void {
    const f: *const fn (id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op));
}
inline fn msg1v(self: id, op: [*:0]const u8, a: id) void {
    const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), a);
}

const NSApplicationActivationPolicyAccessory: c_long = 2;

var launched = false;

/// The shared accessory-policy NSApplication (no Dock icon, never force-activated).
/// Idempotent; safe before `ensureLaunched`. Main thread only.
pub fn app() id {
    const a = msg(cls("NSApplication"), "sharedApplication");
    const f: *const fn (id, SEL, c_long) callconv(.c) bool = @ptrCast(&objc_msgSend);
    _ = f(a, sel_registerName("setActivationPolicy:"), NSApplicationActivationPolicyAccessory);
    return a;
}

/// `finishLaunching` exactly once — wires AppKit up enough to draw and dispatch without
/// double-posting the did-finish-launching notifications when both the HUD and the menu
/// come up. Main thread only, before the run loop starts.
pub fn ensureLaunched() void {
    const a = app();
    if (launched) return;
    launched = true;
    msgv(a, "finishLaunching");
}

/// Block the main thread in `[NSApp run]` — the #31 swap. Returns after `stop`.
pub fn run() void {
    msgv(app(), "run");
}

/// Unwind `run` cleanly. `stop:` only takes effect after an event finishes processing,
/// so when the caller is not inside one (the SIGTERM path arrives via
/// performSelectorOnMainThread, outside event dispatch) a synthetic application-defined
/// event is posted to nudge the loop; from a menu action the extra event is harmless.
/// Main thread only — reach it cross-thread via menu.requestStop().
pub fn stop() void {
    const a = app();
    msg1v(a, "stop:", null);
    const post: *const fn (id, SEL, id, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    post(a, sel_registerName("postEvent:atStart:"), wakeEvent(), true);
}

const NSPoint = extern struct { x: f64, y: f64 };
const NSEventTypeApplicationDefined: c_ulong = 15;

/// [NSEvent otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:
/// subtype:data1:data2:] — the do-nothing event that makes `run` re-check its stop flag.
fn wakeEvent() id {
    const f: *const fn (id, SEL, c_ulong, NSPoint, c_ulong, f64, c_long, id, c_short, c_long, c_long) callconv(.c) id =
        @ptrCast(&objc_msgSend);
    return f(
        cls("NSEvent"),
        sel_registerName("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"),
        NSEventTypeApplicationDefined,
        .{ .x = 0, .y = 0 },
        0,
        0.0,
        0,
        null,
        0,
        0,
        0,
    );
}
