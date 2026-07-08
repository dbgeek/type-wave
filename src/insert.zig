//! insert.zig — macOS Insertion mechanisms (the OS half, no OpenAI).
//! Primary: pasteboard swap + synthetic Cmd-V (one-shot, perfect Unicode, works
//! in terminals + Electron where the AX write path is a dead end). Fallback:
//! chunked synthetic Unicode keystrokes. Portable half of the spike — knows
//! nothing about the Talk Key or the run loop.
//!
//! Extern decls + design per docs/research/macos-text-insertion.md §2–§3, §7–§9.
//! (@cImport is gone on this nightly; hand-written externs instead.)

const std = @import("std");
const tap = @import("tap.zig");

pub const InsertError = error{
    /// No kTCCServicePostEvent grant — CGEventPost is silently dropped. §7.
    PostEventDenied,
};

/// Which Insertion mechanism to use (wayfinder #16 config). `paste` is the proven
/// primary (clipboard swap + ⌘V); `keystroke` is the synthetic-typing fallback.
pub const Method = enum { paste, keystroke };
// NB: Secure Event Input (crib sheet §6) is a *policy* concern, not a mechanism
// one — whether it actually suppresses CGEventPost/Cmd-V is undocumented (§6,
// spike item 4). So these functions just attempt the post; the caller decides
// whether to skip when `secureInputActive()` is true. The spike attempts anyway
// (warn-and-observe) precisely to answer that open question.

// ---- CoreGraphics event synthesis ----
const CGEventRef = ?*opaque {};
const CGEventSourceRef = ?*opaque {};
const CGEventFlags = u64;
const UniChar = u16;

const kCGHIDEventTap: u32 = 0;
const kCGSessionEventTap: u32 = 1;
const kCGEventSourceStateCombinedSessionState: i32 = 0; // Maccy's choice
const kCGEventFlagMaskCommand: CGEventFlags = 0x100000; // CGEventTypes.h
const kVK_ANSI_V: u16 = 0x09; // layout note: Dvorak-QWERTY-⌘ would need a keycode map

extern "c" fn CGEventSourceCreate(state: i32) CGEventSourceRef;
extern "c" fn CGEventSourceSetUserData(src: CGEventSourceRef, data: i64) void;
extern "c" fn CGEventCreateKeyboardEvent(src: CGEventSourceRef, vk: u16, key_down: bool) CGEventRef;
extern "c" fn CGEventSetFlags(ev: CGEventRef, flags: CGEventFlags) void;
extern "c" fn CGEventKeyboardSetUnicodeString(ev: CGEventRef, len: c_ulong, s: [*]const UniChar) void;
extern "c" fn CGEventPost(where: u32, ev: CGEventRef) void;
extern "c" fn CFRelease(cf: ?*anyopaque) void;

extern "c" fn CGPreflightPostEventAccess() bool;
extern "c" fn CGRequestPostEventAccess() bool;

// Secure Event Input lives in Carbon / HIToolbox (returns a system-wide count > 0).
extern "c" fn IsSecureEventInputEnabled() u8;

// The PID holding Secure Event Input is exposed as kCGSSessionSecureInputPID in
// the session dictionary (crib sheet §6; skhd/deskflow read it the same way).
// CGSessionCopyCurrentDictionary is a private-but-exported CoreGraphics symbol.
extern "c" fn CGSessionCopyCurrentDictionary() ?*anyopaque;
extern "c" fn CFDictionaryGetValue(dict: ?*anyopaque, key: ?*anyopaque) ?*anyopaque;
extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) ?*anyopaque;
extern "c" fn CFNumberGetValue(number: ?*anyopaque, the_type: c_long, value_ptr: *anyopaque) bool;
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int; // libproc, via libSystem
const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCFNumberIntType: c_long = 9; // reads the CFNumber as a C int (i32)

// ---- ObjC runtime, for NSPasteboard ----
const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

extern "c" fn usleep(usec: c_uint) c_int;

// public.utf8-plain-text == NSPasteboardTypeString
const pb_type_utf8 = "public.utf8-plain-text";

fn sendId(self: id, op: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}
fn sendLong(self: id, op: [*:0]const u8) c_long {
    const f: *const fn (id, SEL) callconv(.c) c_long = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}
/// [NSString stringWithUTF8String:s]
fn nsString(s: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), s);
}
/// [pb stringForType:type] — nil if absent.
fn stringForType(pb: id, typ: id) id {
    const f: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(pb, sel_registerName("stringForType:"), typ);
}
/// [pb setString:str forType:type]
fn setStringForType(pb: id, str: id, typ: id) void {
    const f: *const fn (id, SEL, id, id) callconv(.c) bool = @ptrCast(&objc_msgSend);
    _ = f(pb, sel_registerName("setString:forType:"), str, typ);
}

fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}

/// espanso's constants (§3): settle before, let the async paste read finish after.
const pre_paste_ms: u32 = 100;
const restore_ms: u32 = 300;
const cmd_v_gap_ms: u32 = 10;

/// Preflight (silent) and prompt for PostEvent access if absent.
pub fn requestPostEventAccess() bool {
    if (CGPreflightPostEventAccess()) return true;
    return CGRequestPostEventAccess();
}

/// Silent preflight only — never prompts. The daemon's self-heal supervisor (#19) polls
/// this so it re-checks the grant without re-triggering a TCC dialog every tick.
pub fn postEventGranted() bool {
    return CGPreflightPostEventAccess();
}

pub fn secureInputActive() bool {
    return IsSecureEventInputEnabled() != 0;
}

/// The PID currently holding Secure Event Input, or null if none/unknown (§6).
pub fn secureInputHolderPid() ?i32 {
    const dict = CGSessionCopyCurrentDictionary() orelse return null;
    defer CFRelease(dict);
    const key = CFStringCreateWithCString(null, "kCGSSessionSecureInputPID", kCFStringEncodingUTF8) orelse return null;
    defer CFRelease(key);
    const val = CFDictionaryGetValue(dict, key) orelse return null; // CFNumberRef, not owned
    var pid: i32 = 0;
    if (!CFNumberGetValue(val, kCFNumberIntType, &pid)) return null;
    return if (pid == 0) null else pid;
}

/// Best-effort process name for a pid via libproc; "" on failure.
pub fn procName(pid: i32, buf: []u8) []const u8 {
    const n = proc_name(@intCast(pid), buf.ptr, @intCast(buf.len));
    return if (n <= 0) "" else buf[0..@intCast(n)];
}

pub const Inserter = struct {
    /// A tagged event source so our observer can recognise our own posts (§4).
    src: CGEventSourceRef = null,

    pub fn init(self: *Inserter) void {
        self.src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
        if (self.src != null) CGEventSourceSetUserData(self.src, tap.self_event_tag);
    }

    /// Insert `utf8` (NUL-terminated) via the configured mechanism (wayfinder #16).
    /// The keystroke path converts to the UTF-16 that `keystroke` wants; malformed
    /// UTF-8 (not expected from the transcription service) degrades to paste.
    pub fn insert(self: *Inserter, method: Method, utf8: [*:0]const u8) InsertError!void {
        switch (method) {
            .paste => return self.paste(utf8),
            .keystroke => {
                const s = std.mem.span(utf8);
                // The Final Transcript buffer is 8192 bytes and UTF-16 units never
                // outnumber source bytes, so this dest can't overflow.
                var u16buf: [8192]u16 = undefined;
                const n = std.unicode.utf8ToUtf16Le(&u16buf, s) catch return self.paste(utf8);
                return self.keystroke(u16buf[0..n]);
            },
        }
    }

    /// Primary mechanism: save clipboard → set transcript → Cmd-V → restore.
    /// `utf8` must be NUL-terminated (it becomes an NSString). Returns the
    /// pasteboard changeCount delta so the caller can spot a clobbering manager.
    pub fn paste(self: *Inserter, utf8: [*:0]const u8) InsertError!void {
        if (!CGPreflightPostEventAccess()) return error.PostEventDenied;

        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        const pb = sendId(objc_getClass("NSPasteboard"), "generalPasteboard");
        const type_utf8 = nsString(pb_type_utf8);

        // Save the current plain text (best effort — rich/promised types are lost
        // on restore, crib sheet §8). Copied out, so it survives clearContents.
        const saved = stringForType(pb, type_utf8);

        _ = sendLong(pb, "clearContents");
        setStringForType(pb, nsString(utf8), type_utf8);
        // Mark transient + concealed so clipboard managers skip our write (§8).
        setStringForType(pb, nsString(""), nsString("org.nspasteboard.TransientType"));
        setStringForType(pb, nsString(""), nsString("org.nspasteboard.ConcealedType"));

        sleepMs(pre_paste_ms);
        self.postCmdV();
        sleepMs(restore_ms);

        _ = sendLong(pb, "clearContents");
        if (saved != null) setStringForType(pb, saved, type_utf8);
    }

    fn postCmdV(self: *Inserter) void {
        const down = CGEventCreateKeyboardEvent(self.src, kVK_ANSI_V, true);
        const up = CGEventCreateKeyboardEvent(self.src, kVK_ANSI_V, false);
        CGEventSetFlags(down, kCGEventFlagMaskCommand);
        CGEventSetFlags(up, kCGEventFlagMaskCommand);
        CGEventPost(kCGSessionEventTap, down);
        sleepMs(cmd_v_gap_ms);
        CGEventPost(kCGSessionEventTap, up);
        CFRelease(@ptrCast(down));
        CFRelease(@ptrCast(up));
    }

    /// Fallback: post `utf16` as synthetic keystrokes in ≤20-unit chunks, never
    /// splitting a surrogate pair, key-down+key-up per chunk with ~1 ms pacing
    /// (espanso's rules, §1–§2). Posts to the HID tap like the real injectors do.
    pub fn keystroke(self: *Inserter, utf16: []const UniChar) InsertError!void {
        if (!CGPreflightPostEventAccess()) return error.PostEventDenied;

        var i: usize = 0;
        while (i < utf16.len) {
            var n: usize = @min(20, utf16.len - i);
            // Don't end a chunk on a high surrogate (0xD800..0xDBFF).
            if (n > 0 and utf16[i + n - 1] >= 0xD800 and utf16[i + n - 1] <= 0xDBFF) n -= 1;
            const chunk = utf16[i .. i + n];

            const down = CGEventCreateKeyboardEvent(self.src, 0x31, true); // carrier keycode (space)
            const up = CGEventCreateKeyboardEvent(self.src, 0x31, false);
            CGEventKeyboardSetUnicodeString(down, @intCast(chunk.len), chunk.ptr);
            CGEventKeyboardSetUnicodeString(up, @intCast(chunk.len), chunk.ptr);
            CGEventPost(kCGHIDEventTap, down);
            sleepMs(1);
            CGEventPost(kCGHIDEventTap, up);
            sleepMs(1);
            CFRelease(@ptrCast(down));
            CFRelease(@ptrCast(up));
            i += n;
        }
    }
};
