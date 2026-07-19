//! THROWAWAY spike shell (wayfinder ticket #129, "Live tap re-arm: does
//! CGEventTapEnable or a full recreate bring the tap live post-grant?"). Empirically
//! settles what docs/research/macos-tcc-live-grant-pickup.md (#127) predicted:
//!
//!   1. Input Monitoring: does CGEventTapEnable on a created-while-denied port ever
//!      bring it live (path A), or does only teardown+CGEventTapCreate (path B)?
//!   2. PostEvent: does a synthesized CGEventPost actually land after Accessibility
//!      is granted live, with no uncached probe to lean on?
//!   3. Does setting Accessory activation policy before the first grant probe clear
//!      the Sequoia+ background-only CGPreflightPostEventAccess==false bug?
//!
//! Run protocol in NOTES.md. Delete or graduate once #129 is answered; tap.zig /
//! insert.zig / daemon.zig are the portable graduation candidates for whichever
//! re-arm this confirms — this shell is scaffolding.

const std = @import("std");

extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;

fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}

/// Blocking read of one line from stdin (terminal is line-buffered).
fn readLine(buf: []u8) []const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        const r = read(0, buf[n..].ptr, 1);
        if (r <= 0) break;
        if (buf[n] == '\n') break;
        n += 1;
    }
    return buf[0..n];
}

// ---- CoreGraphics: event taps, event synthesis, TCC preflight -------------------

const CGEventRef = ?*opaque {};
const CGEventTapProxy = ?*anyopaque;
const CFMachPortRef = ?*opaque {};
const CFRunLoopSourceRef = ?*opaque {};
const CFRunLoopRef = ?*opaque {};
const CFStringRef = ?*opaque {};
const CFAllocatorRef = ?*anyopaque;
const CGEventMask = u64;
const CGEventSourceRef = ?*opaque {};
const UniChar = u16;

const CGEventTapCallBack = *const fn (CGEventTapProxy, u32, CGEventRef, ?*anyopaque) callconv(.c) CGEventRef;

const kCGSessionEventTap: u32 = 1;
const kCGHIDEventTap: u32 = 0;
const kCGHeadInsertEventTap: u32 = 0;
const kCGEventTapOptionListenOnly: u32 = 1;

const kCGEventKeyDown: u32 = 10;
const kCGEventKeyUp: u32 = 11;
const kCGEventFlagsChanged: u32 = 12;
const kCGEventTapDisabledByTimeout: u32 = 0xFFFFFFFE;
const kCGEventTapDisabledByUserInput: u32 = 0xFFFFFFFF;

const kCGKeyboardEventKeycode: u32 = 9;
const kCGEventSourceUserData: u32 = 42; // CGEventField

const NX_DEVICELALTKEYMASK: u64 = 0x20;
const NX_DEVICERALTKEYMASK: u64 = 0x40;

const kVK_Option: i64 = 0x3A;
const kVK_RightOption: i64 = 0x3D;
const kVK_carrier: u16 = 0x31; // space — carrier keycode for a Unicode-string post (insert.zig)

const kCGEventSourceStateCombinedSessionState: i32 = 0;

/// Tags every event this spike posts (matches tap.zig's self_event_tag). Lets the
/// tap distinguish "my own synthetic post reached the event stream" (an objective,
/// in-process signal) from a real keystroke the human typed.
const self_event_tag: i64 = -27469;

extern "c" fn CGEventTapCreate(tap: u32, place: u32, options: u32, mask: CGEventMask, cb: CGEventTapCallBack, userInfo: ?*anyopaque) CFMachPortRef;
extern "c" fn CGEventTapEnable(tap: CFMachPortRef, enable: bool) void;
extern "c" fn CGEventTapIsEnabled(tap: CFMachPortRef) bool;
extern "c" fn CGEventGetIntegerValueField(ev: CGEventRef, field: u32) i64;
extern "c" fn CGEventGetFlags(ev: CGEventRef) u64;
extern "c" fn CFMachPortCreateRunLoopSource(alloc: CFAllocatorRef, port: CFMachPortRef, order: c_long) CFRunLoopSourceRef;
extern "c" fn CFMachPortInvalidate(port: CFMachPortRef) void;
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopAddSource(rl: CFRunLoopRef, src: CFRunLoopSourceRef, mode: CFStringRef) void;
extern "c" fn CFRunLoopRemoveSource(rl: CFRunLoopRef, src: CFRunLoopSourceRef, mode: CFStringRef) void;
extern "c" fn CFRunLoopRunInMode(mode: CFStringRef, seconds: f64, returnAfterSourceHandled: bool) i32;
extern "c" fn CFRelease(cf: ?*anyopaque) void;
extern var kCFRunLoopDefaultMode: CFStringRef;

extern "c" fn CGPreflightListenEventAccess() bool;
extern "c" fn CGPreflightPostEventAccess() bool;

extern "c" fn CGEventSourceCreate(state: i32) CGEventSourceRef;
extern "c" fn CGEventSourceSetUserData(src: CGEventSourceRef, data: i64) void;
extern "c" fn CGEventCreateKeyboardEvent(src: CGEventSourceRef, vk: u16, key_down: bool) CGEventRef;
extern "c" fn CGEventKeyboardSetUnicodeString(ev: CGEventRef, len: c_ulong, s: [*]const UniChar) void;
extern "c" fn CGEventPost(where: u32, ev: CGEventRef) void;

// ---- ObjC runtime, just enough for NSApplication.setActivationPolicy: -----------

const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void;

const NSApplicationActivationPolicyAccessory: c_long = 2;

/// The Sequoia+ fix under test (§5 of the research doc): a headless process (no
/// NSApplication) can read CGPreflightPostEventAccess()==false despite a live
/// grant. `--accessory` sets the Accessory activation policy before the first
/// grant probe, same as appkit.zig's app() — but WITHOUT bringing up a run loop
/// or calling finishLaunching, since this spike drives its own CFRunLoopRunInMode
/// loop for the tap instead.
fn setAccessoryActivationPolicy() void {
    const a_cls = objc_getClass("NSApplication");
    const shared: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    const a = shared(a_cls, sel_registerName("sharedApplication"));
    const setPolicy: *const fn (id, SEL, c_long) callconv(.c) bool = @ptrCast(&objc_msgSend);
    _ = setPolicy(a, sel_registerName("setActivationPolicy:"), NSApplicationActivationPolicyAccessory);
}

// ---- shared state: tap callback (run-loop thread) <-> director (prompt thread) --

var press_seen = std.atomic.Value(bool).init(false);
var self_post_seen = std.atomic.Value(bool).init(false);
var last_press_keycode = std.atomic.Value(i64).init(0);

/// Runs on the run-loop thread. Kept fast per tap.zig's own doc comment — a slow
/// callback makes the OS disable the tap.
fn callback(_: CGEventTapProxy, etype: u32, event: CGEventRef, _: ?*anyopaque) callconv(.c) CGEventRef {
    if (etype == kCGEventTapDisabledByTimeout or etype == kCGEventTapDisabledByUserInput) {
        return event;
    }
    const tagged = CGEventGetIntegerValueField(event, kCGEventSourceUserData) == self_event_tag;
    if (etype == kCGEventKeyDown and tagged) {
        self_post_seen.store(true, .release);
        return event;
    }
    if (etype != kCGEventFlagsChanged) return event;
    if (tagged) return event;

    const keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    const flags = CGEventGetFlags(event);
    const down = (keycode == kVK_RightOption and (flags & NX_DEVICERALTKEYMASK) != 0) or
        (keycode == kVK_Option and (flags & NX_DEVICELALTKEYMASK) != 0);
    if (down) {
        last_press_keycode.store(keycode, .monotonic);
        press_seen.store(true, .release);
    }
    return event;
}

// ---- tap lifecycle: all on the main thread (the run-loop thread) ----------------

var g_port: CFMachPortRef = null;
var g_source: CFRunLoopSourceRef = null;

fn tapMask() CGEventMask {
    const flags_bit: CGEventMask = 1;
    const down_bit: CGEventMask = 1;
    const up_bit: CGEventMask = 1;
    return (flags_bit << kCGEventFlagsChanged) | (down_bit << kCGEventKeyDown) | (up_bit << kCGEventKeyUp);
}

/// Fresh CGEventTapCreate + add-to-run-loop + enable. This IS the live TCC probe
/// Quinn (Apple DTS) recommends — a fresh create re-consults tccd, unlike the
/// cached CGPreflightListenEventAccess(). Returns whether it came up enabled.
fn createAndInstall() bool {
    const p = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, tapMask(), callback, null);
    if (p == null) {
        std.debug.print("  CGEventTapCreate -> NULL (hard failure, not just disabled)\n", .{});
        g_port = null;
        return false;
    }
    g_port = p;
    g_source = CFMachPortCreateRunLoopSource(null, p, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), g_source, kCFRunLoopDefaultMode);
    CGEventTapEnable(p, true);
    return CGEventTapIsEnabled(p);
}

/// Path A: CGEventTapEnable on the EXISTING port. Research verdict: inert for a
/// port created while denied — the header's re-enable contract only covers a
/// previously-healthy tap parked by timeout/user-input, not a cold-denied one.
fn pathAEnable() bool {
    if (g_port == null) return false;
    CGEventTapEnable(g_port, true);
    return CGEventTapIsEnabled(g_port);
}

/// Path B: tear down the run-loop source + port, then CGEventTapCreate fresh.
/// Must run on the run-loop thread (this fn is only ever called from main()).
fn pathBRecreate() bool {
    if (g_source != null) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), g_source, kCFRunLoopDefaultMode);
        CFRelease(@ptrCast(g_source));
        g_source = null;
    }
    if (g_port != null) {
        CFMachPortInvalidate(g_port);
        CFRelease(@ptrCast(g_port));
        g_port = null;
    }
    return createAndInstall();
}

/// Post a tagged, self-detectable synthetic keystroke — deliberately WITHOUT
/// gating on CGPreflightPostEventAccess (unlike insert.zig's paste/keystroke),
/// since the whole point is to observe whether an unguarded post lands live.
fn postSyntheticKeystroke() void {
    self_post_seen.store(false, .release);
    const text: [:0]const u16 = &[_:0]u16{ 'T', 'Y', 'P', 'E', 'W', 'A', 'V', 'E', '-', 'T', 'E', 'S', 'T' };

    const src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    defer if (src != null) CFRelease(@ptrCast(src));
    if (src != null) CGEventSourceSetUserData(src, self_event_tag);

    const down = CGEventCreateKeyboardEvent(src, kVK_carrier, true);
    const up = CGEventCreateKeyboardEvent(src, kVK_carrier, false);
    CGEventKeyboardSetUnicodeString(down, @intCast(text.len), text.ptr);
    CGEventKeyboardSetUnicodeString(up, @intCast(text.len), text.ptr);
    CGEventPost(kCGHIDEventTap, down);
    sleepMs(5);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(@ptrCast(down));
    CFRelease(@ptrCast(up));
}

// ---- director: runs on a background thread; drives the interactive protocol ----

const Action = enum(u8) { none, try_a, try_b, post_test, quit };
var requested = std.atomic.Value(u8).init(@intFromEnum(Action.none));
var action_done = std.atomic.Value(bool).init(false);
var action_result = std.atomic.Value(bool).init(false);

/// Hand an Action to the main/run-loop thread and block (with a timeout) for it to
/// perform the CG call and report back. All tap/port mutation and event posting
/// happens on the main thread — CGEventTapCreate and friends are documented to
/// need the run loop's own thread; keeping the post there too avoids a confound.
fn doAction(a: Action, wait_ms: u32) bool {
    action_done.store(false, .release);
    requested.store(@intFromEnum(a), .release);
    var waited: u32 = 0;
    while (!action_done.load(.acquire)) {
        sleepMs(20);
        waited += 20;
        if (waited >= wait_ms) break;
    }
    return action_result.load(.acquire);
}

fn director() void {
    var line: [256]u8 = undefined;

    std.debug.print("\n=== tap-rearm spike (wayfinder #129) ===\n", .{});
    std.debug.print("Input Monitoring preflight (cached, likely stale): {}\n", .{CGPreflightListenEventAccess()});
    std.debug.print("PostEvent        preflight (cached, likely stale): {}\n\n", .{CGPreflightPostEventAccess()});

    std.debug.print("---- Phase 1: Input Monitoring re-arm ----\n", .{});
    std.debug.print("Tap installed (created-but-disabled is fine). If Input Monitoring is\n", .{});
    std.debug.print("already denied, leave it denied for this run, then grant it now in\n", .{});
    std.debug.print("System Settings > Privacy & Security > Input Monitoring while this loop polls.\n\n", .{});

    var tick: u32 = 0;
    var live = false;
    var winning_path: []const u8 = "";
    while (!live) {
        const preflight = CGPreflightListenEventAccess();
        if (tick < 3) {
            std.debug.print("[{d:>4}ms] preflight={}  trying path A (CGEventTapEnable on existing port)...\n", .{ tick * 1500, preflight });
            if (doAction(.try_a, 2000)) {
                live = true;
                winning_path = "A (CGEventTapEnable on the existing port)";
            }
        } else {
            std.debug.print("[{d:>4}ms] preflight={}  trying path B (teardown + CGEventTapCreate)...\n", .{ tick * 1500, preflight });
            if (doAction(.try_b, 2000)) {
                live = true;
                winning_path = "B (teardown + fresh CGEventTapCreate)";
            }
        }
        if (!live) sleepMs(1500);
        tick += 1;
        if (tick > 400) {
            std.debug.print("Giving up after 10 minutes — Ctrl-C and re-run once Input Monitoring is granted.\n", .{});
            _ = doAction(.quit, 500);
            return;
        }
    }
    std.debug.print("\n  CGEventTapIsEnabled==true via path {s}.\n", .{winning_path});
    std.debug.print("  Confirming with a REAL event: press either Option key now (5s window)...\n", .{});
    press_seen.store(false, .release);
    var waited: u32 = 0;
    while (waited < 5000 and !press_seen.load(.acquire)) {
        sleepMs(100);
        waited += 100;
    }
    if (press_seen.load(.acquire)) {
        std.debug.print("  [LIVE] flagsChanged observed (keycode 0x{X}) — Input Monitoring re-arm CONFIRMED via path {s}.\n\n", .{ last_press_keycode.load(.monotonic), winning_path });
    } else {
        std.debug.print("  [WARN] IsEnabled==true but no real event arrived in 5s — re-run and press Option promptly.\n\n", .{});
    }

    std.debug.print("---- Phase 2: PostEvent / Accessibility live pickup ----\n", .{});
    std.debug.print("Click into a scratch text field (TextEdit/Notes) so you can see what lands.\n", .{});
    std.debug.print("Press Enter for a BASELINE post (expected to fail/be denied pre-grant): ", .{});
    _ = readLine(&line);
    runPostAttempt("baseline (pre-grant)");

    std.debug.print("\nNow grant Accessibility for this binary in System Settings > Privacy &\n", .{});
    std.debug.print("Security > Accessibility (the entry may be the terminal you launched this\n", .{});
    std.debug.print("from, or this binary itself, depending on how it was invoked).\n", .{});
    var retry = true;
    while (retry) {
        std.debug.print("Press Enter once granted, to attempt the post-grant post: ", .{});
        _ = readLine(&line);
        runPostAttempt("post-grant");
        std.debug.print("Retry the post-grant attempt? [y/N]: ", .{});
        const ans = readLine(&line);
        retry = ans.len > 0 and (ans[0] == 'y' or ans[0] == 'Y');
    }

    std.debug.print("\nSpike done. Record the path A/B result + Phase 2 findings on issue #129.\n", .{});
    std.debug.print("Re-run with `--accessory` (and without) to compare the headless\n", .{});
    std.debug.print("Sequoia+ PostEvent-preflight bug per NOTES.md protocol 3.\n", .{});
    _ = doAction(.quit, 500);
}

fn runPostAttempt(label: []const u8) void {
    const preflight_before = CGPreflightPostEventAccess();
    const seen = doAction(.post_test, 500);
    const preflight_after = CGPreflightPostEventAccess();
    std.debug.print("  [{s}] preflight before={} after={}  self-tap saw the synthetic keyDown={}\n", .{ label, preflight_before, preflight_after, seen });
    std.debug.print("  [{s}] Did \"TYPEWAVE-TEST\" actually appear in the focused field? [y/N]: ", .{label});
    var line: [16]u8 = undefined;
    const ans = readLine(&line);
    const landed = ans.len > 0 and (ans[0] == 'y' or ans[0] == 'Y');
    std.debug.print("  [{s}] recorded: self-tap-saw={} human-confirmed-landed={}\n", .{ label, seen, landed });
}

pub fn main() !void {
    // This nightly dropped std.process's argv iteration entirely (no ArgIterator left
    // in std) — an env var sidesteps it, same as cli-dictation's OPENAI_API_KEY lookup.
    const accessory = std.c.getenv("ACCESSORY") != null;

    if (accessory) {
        setAccessoryActivationPolicy();
        std.debug.print("ACCESSORY POLICY: SET (NSApplication, Accessory) before first grant probe\n", .{});
    } else {
        std.debug.print("ACCESSORY POLICY: NOT SET — headless default, reproduces the Sequoia+ bug if present\n", .{});
    }

    if (!createAndInstall()) {
        std.debug.print("Initial tap: created-but-disabled (expected if Input Monitoring is denied).\n", .{});
    } else {
        std.debug.print("Initial tap: already live — Input Monitoring must already be granted. Revoke\n", .{});
        std.debug.print("it in System Settings and re-run for a clean Phase 1, or Ctrl-C to skip to Phase 2.\n", .{});
    }

    const director_thread = try std.Thread.spawn(.{}, director, .{});
    director_thread.detach();

    // Main thread: services the tap's run-loop source AND performs every tap
    // mutation (path A/B, synthetic post) itself, since CGEventTapCreate / recreate
    // must run on the thread whose run loop services the tap (tap.zig's own
    // constraint) — CGEventTapEnable alone is documented thread-safe, but this
    // spike keeps everything on one thread for simplicity and to avoid muddying
    // the path A/B measurement with a cross-thread confound.
    while (true) {
        _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        const a: Action = @enumFromInt(requested.swap(@intFromEnum(Action.none), .acq_rel));
        switch (a) {
            .none => {},
            .try_a => {
                action_result.store(pathAEnable(), .release);
                action_done.store(true, .release);
            },
            .try_b => {
                action_result.store(pathBRecreate(), .release);
                action_done.store(true, .release);
            },
            .post_test => {
                postSyntheticKeystroke();
                sleepMs(150); // let the tap callback observe it before we report
                action_result.store(self_post_seen.load(.acquire), .release);
                action_done.store(true, .release);
            },
            .quit => {
                action_done.store(true, .release);
                std.process.exit(0);
            },
        }
    }
}
