//! app_focus.zig — the best-effort **App Identity** reader (ADR-0006,
//! docs/recent-insertions-spec.md §3.3).
//!
//! `NSWorkspace.frontmostApplication` is a cross-process query, so reading it inside
//! `onInserted` under `coordinator.mu` is explicitly rejected — it would stall the serialized
//! Utterance state machine. Instead the Insertion adapter calls this **off-mutex on the
//! insert worker**, the faithful moment the text lands, and carries the result back through
//! the `.inserted` report. This module is the one macOS boundary behind the `focused_app`
//! hint; the adapter reaches it through its Deps seam so the adapter stays testable against a
//! FakeDeps. Same ObjC-runtime `objc_msgSend` pattern as appkit.zig / insert.zig; Apple
//! Silicon only.

const std = @import("std");
const coord = @import("coordinator.zig");

const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site

inline fn msg(self: id, op: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}

/// Copy an NSString's UTF-8 bytes into `buf`; "" for a nil string or nil UTF8String.
fn nsStringUtf8(s: id, buf: []u8) []const u8 {
    if (s == null) return "";
    const utf8: *const fn (id, SEL) callconv(.c) ?[*:0]const u8 = @ptrCast(&objc_msgSend);
    const c = utf8(s, sel_registerName("UTF8String")) orelse return "";
    const span = std.mem.span(c);
    const n = @min(span.len, buf.len);
    @memcpy(buf[0..n], span[0..n]);
    return buf[0..n];
}

/// The frontmost application's bundle id + localized name, read best-effort from
/// `NSWorkspace`. Null when there is no frontmost app (rare) — the hint is never
/// load-bearing, so a miss simply leaves the Insertion Record's `focused_app` empty.
pub fn frontmost() ?coord.AppIdentity {
    const workspace = msg(objc_getClass("NSWorkspace"), "sharedWorkspace");
    if (workspace == null) return null;
    const app = msg(workspace, "frontmostApplication");
    if (app == null) return null;
    var bundle_buf: [255]u8 = undefined;
    var name_buf: [255]u8 = undefined;
    const bundle = nsStringUtf8(msg(app, "bundleIdentifier"), &bundle_buf);
    const name = nsStringUtf8(msg(app, "localizedName"), &name_buf);
    return coord.AppIdentity.init(bundle, name);
}
