//! status-item-icons spike (wayfinder #42, map #39) — THROWAWAY.
//!
//! The question: which menu-bar icon makes type-wave's Status Item sit naturally
//! among Tahoe's system icons — SF Symbol, weight/size/scale, and how the dimmed
//! tier (paused / no key / permission missing) renders in the new language.
//!
//! The harness plants one NSStatusItem PER CANDIDATE in the live menu bar, side
//! by side with the real system icons — the only honest backdrop. Terminal
//! commands flip every candidate at once between the healthy and dimmed tiers,
//! cycle four dim styles, and cycle symbol weight/size/scale, so candidates are
//! judged in place and can be toggled down to a single finalist.
//!
//! Clicking a candidate's icon pops a small identifying menu (name + rationale)
//! — which is why this blocks on [NSApp run], not bare CFRunLoopRun (the #31
//! finding: bare CFRunLoopRun never routes status-item clicks).
//!
//! Recipe: prototypes/menu-bar (#31) + src/menu.zig, all AppKit via the ObjC
//! runtime C API. Apple Silicon only. No Swift, no .m shims.

const std = @import("std");

// ---- ObjC runtime primitives (same as src/menu.zig) --------------------------
const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

const os_unfair_lock = extern struct { _opaque: u32 = 0 };
extern "c" fn os_unfair_lock_lock(lock: *os_unfair_lock) void;
extern "c" fn os_unfair_lock_unlock(lock: *os_unfair_lock) void;

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
inline fn msg1(self: id, op: [*:0]const u8, a: id) id {
    const f: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op), a);
}
inline fn msg1v(self: id, op: [*:0]const u8, a: id) void {
    const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), a);
}
inline fn msgBool(self: id, op: [*:0]const u8, b: bool) void {
    const f: *const fn (id, SEL, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), b);
}
inline fn msgDouble(self: id, op: [*:0]const u8, x: f64) void {
    const f: *const fn (id, SEL, f64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), x);
}
inline fn nsstr(s: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSString"), sel_registerName("stringWithUTF8String:"), s);
}
inline fn setActivationPolicy(app: id, policy: c_long) void {
    const f: *const fn (id, SEL, c_long) callconv(.c) bool = @ptrCast(&objc_msgSend);
    _ = f(app, sel_registerName("setActivationPolicy:"), policy);
}
const NSApplicationActivationPolicyAccessory: c_long = 2;

/// [NSImage imageWithSystemSymbolName:accessibilityDescription:] — nil when the
/// SF Symbol name is unknown on this macOS (the startup probe reports those).
inline fn sfSymbol(name: [*:0]const u8) id {
    const f: *const fn (id, SEL, id, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSImage"), sel_registerName("imageWithSystemSymbolName:accessibilityDescription:"), nsstr(name), null);
}
/// [NSImageSymbolConfiguration configurationWithPointSize:weight:scale:]
inline fn symbolConfig(point_size: f64, weight: f64, scale: c_long) id {
    const f: *const fn (id, SEL, f64, f64, c_long) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSImageSymbolConfiguration"), sel_registerName("configurationWithPointSize:weight:scale:"), point_size, weight, scale);
}
inline fn statusItemVariable(bar: id) id {
    const f: *const fn (id, SEL, f64) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(bar, sel_registerName("statusItemWithLength:"), -1.0); // NSVariableStatusItemLength
}
inline fn makeItem(title: [*:0]const u8) id {
    const allocd = msg(cls("NSMenuItem"), "alloc");
    const f: *const fn (id, SEL, id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(allocd, sel_registerName("initWithTitle:action:keyEquivalent:"), nsstr(title), null, nsstr(""));
}

const CFRunLoopTimerRef = ?*anyopaque;
extern "c" fn CFAbsoluteTimeGetCurrent() f64;
extern "c" fn CFRunLoopGetCurrent() ?*anyopaque;
extern "c" fn CFRunLoopAddTimer(rl: ?*anyopaque, timer: CFRunLoopTimerRef, mode: ?*anyopaque) void;
extern "c" fn CFRunLoopTimerCreate(
    alloc: ?*anyopaque,
    fireDate: f64,
    interval: f64,
    flags: c_ulong,
    order: c_long,
    callout: *const fn (CFRunLoopTimerRef, ?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
) CFRunLoopTimerRef;
extern var kCFRunLoopCommonModes: ?*anyopaque;

// =====================================================================================
// The candidates. Healthy symbol + (optional) slash variant for the dimmed tier.
// Missing names are reported by the startup probe and that candidate is skipped.
// =====================================================================================

const Candidate = struct {
    name: [*:0]const u8, // healthy SF Symbol
    slash: ?[*:0]const u8, // needs-attention slash variant; null = none exists
    why: [*:0]const u8,
};

const candidates = [_]Candidate{
    .{ .name = "waveform", .slash = "waveform.slash", .why = "the incumbent (#31): pure audio, matches the HUD's bars" },
    .{ .name = "mic", .slash = "mic.slash", .why = "the classic dictation glyph — what the OS itself uses for speech" },
    .{ .name = "mic.fill", .slash = "mic.slash.fill", .why = "filled mic — heavier presence, like Control Center's indicators" },
    .{ .name = "waveform.badge.mic", .slash = null, .why = "waveform + mic badge: says dictation, not just audio" },
    .{ .name = "mic.and.signal.meter", .slash = null, .why = "mic + level meter: speech with live feedback" },
    .{ .name = "waveform.circle", .slash = null, .why = "enclosed waveform — rounder, softer footprint" },
};

// ---- the look axes cycled from the terminal ----------------------------------------

const Weight = struct { label: []const u8, v: f64 };
// NSFontWeight* constants (regular/medium/semibold/bold).
const weights = [_]Weight{
    .{ .label = "regular", .v = 0.0 },
    .{ .label = "medium", .v = 0.23 },
    .{ .label = "semibold", .v = 0.3 },
    .{ .label = "bold", .v = 0.4 },
};
// null = no NSImageSymbolConfiguration at all — the incumbent daemon's rendering.
const sizes = [_]?f64{ null, 13, 15, 17 };
const Scale = struct { label: []const u8, v: c_long };
const scales = [_]Scale{
    .{ .label = "small", .v = 1 },
    .{ .label = "medium", .v = 2 },
    .{ .label = "large", .v = 3 },
};

/// How the dimmed (needs-attention) tier renders.
const DimStyle = enum {
    slash_alpha, // incumbent: slash variant + alpha 0.35 (src/menu.zig)
    alpha_only, // same glyph, alpha 0.35
    appears_disabled, // NSStatusBarButton.appearsDisabled — the system-native dim
    slash_only, // slash variant at full alpha
};

const State = struct {
    visible: [candidates.len]bool = @splat(true),
    available: [candidates.len]bool = @splat(false), // startup probe result
    dimmed: bool = false,
    dim_style: DimStyle = .slash_alpha,
    weight_i: usize = 0,
    size_i: usize = 0,
    scale_i: usize = 1, // medium
};

var g_state: State = .{};
var g_items: [candidates.len]id = @splat(null);

// stdin thread → main-thread applier: a lock-guarded byte queue (AppKit is
// main-thread-only, so commands are applied by a 10 Hz CFRunLoopTimer).
var g_mu: os_unfair_lock = .{};
var g_pending: [64]u8 = undefined;
var g_pending_len: usize = 0;

// =====================================================================================
// Rendering (main thread only).
// =====================================================================================

/// Re-derive every candidate item's image + dim treatment from g_state.
fn applyAll() void {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const s = &g_state;

    for (candidates, 0..) |c, i| {
        const item = g_items[i];
        if (item == null) continue;
        msgBool(item, "setVisible:", s.visible[i]);
        if (!s.visible[i]) continue;
        const button = msg(item, "button");

        var symbol = c.name;
        var alpha: f64 = 1.0;
        var appears_disabled = false;
        if (s.dimmed) switch (s.dim_style) {
            .slash_alpha => {
                if (c.slash) |sl| symbol = sl;
                alpha = 0.35;
            },
            .alpha_only => alpha = 0.35,
            .appears_disabled => appears_disabled = true,
            .slash_only => {
                if (c.slash) |sl| symbol = sl else alpha = 0.35; // no slash variant → fall back
            },
        };

        var img = sfSymbol(symbol);
        if (img == null) img = sfSymbol(c.name); // slash name missing on this macOS
        if (sizes[s.size_i]) |pt| {
            const cfg = symbolConfig(pt, weights[s.weight_i].v, scales[s.scale_i].v);
            img = msg1(img, "imageWithSymbolConfiguration:", cfg);
        }
        msgBool(img, "setTemplate:", true); // adopt the menu bar's monochrome + vibrancy
        msg1v(button, "setImage:", img);
        msgDouble(button, "setAlphaValue:", alpha);
        msgBool(button, "setAppearsDisabled:", appears_disabled);
    }
}

fn printStatus() void {
    const s = &g_state;
    std.debug.print("  [tier={s} dim_style={s} weight={s} size={s} scale={s}]\n  visible:", .{
        if (s.dimmed) "DIMMED" else "healthy",
        @tagName(s.dim_style),
        weights[s.weight_i].label,
        if (sizes[s.size_i]) |pt| switch (@as(i64, @intFromFloat(pt))) {
            13 => "13pt",
            15 => "15pt",
            17 => "17pt",
            else => "?",
        } else "default (no config — the incumbent rendering)",
        scales[s.scale_i].label,
    });
    for (candidates, 0..) |c, i| {
        if (!s.available[i]) continue;
        std.debug.print(" {d}:{s}{s}", .{ i + 1, std.mem.span(c.name), if (s.visible[i]) "" else "(off)" });
    }
    std.debug.print("\n", .{});
    if (s.dimmed and (s.dim_style == .slash_alpha or s.dim_style == .slash_only)) {
        for (candidates, 0..) |c, i| {
            if (s.available[i] and s.visible[i] and c.slash == null)
                std.debug.print("  note: {s} has no slash variant — shown alpha-dimmed instead\n", .{std.mem.span(c.name)});
        }
    }
    if (sizes[g_state.size_i] == null)
        std.debug.print("  note: weight/scale need a point size — press s first\n", .{});
}

/// One command byte, applied on the main thread.
fn apply(ch: u8) void {
    const s = &g_state;
    switch (ch) {
        '1'...'6' => {
            const i: usize = ch - '1';
            if (!s.available[i]) {
                std.debug.print("  candidate {d} is unavailable on this macOS\n", .{i + 1});
                return;
            }
            s.visible[i] = !s.visible[i];
        },
        'a' => for (0..candidates.len) |i| {
            s.visible[i] = s.available[i];
        },
        'd' => s.dimmed = !s.dimmed,
        'y' => {
            s.dim_style = switch (s.dim_style) {
                .slash_alpha => .alpha_only,
                .alpha_only => .appears_disabled,
                .appears_disabled => .slash_only,
                .slash_only => .slash_alpha,
            };
            s.dimmed = true; // styles only differ while dimmed — jump there so it's visible
        },
        'w' => s.weight_i = (s.weight_i + 1) % weights.len,
        's' => s.size_i = (s.size_i + 1) % sizes.len,
        'e' => s.scale_i = (s.scale_i + 1) % scales.len,
        'q' => {
            std.debug.print("quitting.\n", .{});
            msg1v(msg(cls("NSApplication"), "sharedApplication"), "terminate:", null);
        },
        else => return, // newlines etc.
    }
    applyAll();
    printStatus();
}

fn applierTick(_: CFRunLoopTimerRef, _: ?*anyopaque) callconv(.c) void {
    var buf: [64]u8 = undefined;
    os_unfair_lock_lock(&g_mu);
    const n = g_pending_len;
    @memcpy(buf[0..n], g_pending[0..n]);
    g_pending_len = 0;
    os_unfair_lock_unlock(&g_mu);
    for (buf[0..n]) |ch| apply(ch);
}

fn stdinLoop() void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.posix.read(0, &buf) catch break;
        if (n == 0) break;
        os_unfair_lock_lock(&g_mu);
        for (buf[0..n]) |ch| {
            if (g_pending_len < g_pending.len) {
                g_pending[g_pending_len] = ch;
                g_pending_len += 1;
            }
        }
        os_unfair_lock_unlock(&g_mu);
    }
}

// =====================================================================================
// Build.
// =====================================================================================

/// The identifying menu: clicking a candidate's icon names it (disabled items,
/// no actions — but popping the menu at all is why we block on [NSApp run]).
fn identifyingMenu(index: usize, c: Candidate) id {
    const menu = msg(msg(cls("NSMenu"), "alloc"), "init");
    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(title_buf[0 .. title_buf.len - 1], "candidate {d}: {s}", .{ index + 1, c.name }) catch unreachable;
    title_buf[title.len] = 0;
    const t = makeItem(@ptrCast(title.ptr));
    msgBool(t, "setEnabled:", false);
    msg1v(menu, "addItem:", t);
    const why = makeItem(c.why);
    msgBool(why, "setEnabled:", false);
    msg1v(menu, "addItem:", why);
    return menu;
}

pub fn main() void {
    const pool = objc_autoreleasePoolPush();

    const app = msg(cls("NSApplication"), "sharedApplication");
    setActivationPolicy(app, NSApplicationActivationPolicyAccessory);
    msgv(app, "finishLaunching");

    // Startup probe: which candidate (and slash) names exist on this macOS.
    std.debug.print("\nSF Symbol probe:\n", .{});
    for (candidates, 0..) |c, i| {
        const ok = sfSymbol(c.name) != null;
        g_state.available[i] = ok;
        g_state.visible[i] = ok;
        const slash_state: []const u8 = if (c.slash) |sl|
            (if (sfSymbol(sl) != null) "slash ok" else "slash MISSING")
        else
            "no slash variant";
        std.debug.print("  {d}. {s:<24} {s}  ({s})\n", .{ i + 1, std.mem.span(c.name), if (ok) "ok " else "MISSING", slash_state });
    }

    // Create in reverse so candidate 1 lands closest to the system icons — new
    // status items are inserted to the left of the process's existing ones.
    // (Ordering is cosmetic either way: click an icon to identify it.)
    const bar = msg(cls("NSStatusBar"), "systemStatusBar");
    var i: usize = candidates.len;
    while (i > 0) {
        i -= 1;
        if (!g_state.available[i]) continue;
        const item = statusItemVariable(bar);
        _ = msg(item, "retain"); // autoreleased; hold for the process lifetime
        msg1v(item, "setMenu:", identifyingMenu(i, candidates[i]));
        g_items[i] = item;
    }

    applyAll();

    const stdin_thread = std.Thread.spawn(.{}, stdinLoop, .{}) catch {
        std.debug.print("failed to spawn the stdin thread\n", .{});
        return;
    };
    stdin_thread.detach();

    // 10 Hz command applier — commands land on the main thread, where AppKit lives.
    const timer = CFRunLoopTimerCreate(null, CFAbsoluteTimeGetCurrent() + 0.1, 0.1, 0, 0, applierTick, null);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);

    std.debug.print(
        \\
        \\Status Item icon spike (wayfinder #42) — the candidates are in the menu bar,
        \\side by side with the real system icons. Click one to identify it.
        \\
        \\Commands (letter + Enter):
        \\  1..6  toggle a candidate           a  show all
        \\  d     toggle dimmed tier           y  cycle dim style (slash+alpha /
        \\  w     cycle weight                    alpha / appearsDisabled / slash)
        \\  s     cycle size (default/13/15/17pt) — weight+scale apply at a size
        \\  e     cycle scale (small/medium/large)
        \\  q     quit
        \\
        \\React to: which glyph reads "dictation" at a glance among the system icons;
        \\weight/size that matches its neighbours (flip light/dark menu bar); which
        \\dim style reads "needs attention" without looking broken. Toggle down to
        \\one finalist and stare at it for a while.
        \\
    , .{});
    printStatus();

    objc_autoreleasePoolPop(pool);
    // [NSApp run] — routes the status-item clicks so the identifying menus pop
    // (the #31 finding: bare CFRunLoopRun never delivers them).
    msgv(app, "run");
}
