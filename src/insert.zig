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
const feedback = @import("feedback.zig");

pub const InsertError = error{
    /// No kTCCServicePostEvent grant — CGEventPost is silently dropped. §7. The
    /// mechanisms below no longer raise this themselves: post-grant the preflight can
    /// stay stale-`false` for the process lifetime (#129), so gating on it would refuse
    /// Insertion forever after a live grant. The error stays in the seam's contract (and
    /// the Insertion Runner's failure path) for mechanism-level failures.
    PostEventDenied,
};

/// Which Insertion mechanism to use (wayfinder #16 config). `paste` is the proven
/// primary (clipboard swap + ⌘V); `keystroke` is the synthetic-typing fallback.
pub const Method = enum { paste, keystroke };

/// The Insertion knobs for one job, read off a single Settings Snapshot so the
/// mechanism and its pre-paste settle can never mix two snapshots (issue #37).
pub const Plan = struct {
    method: Method = .paste,
    pre_paste_ms: u32 = default_pre_paste_ms,
};
// NB: Secure Event Input (crib sheet §6) is a *policy* concern, not a mechanism
// one — whether it actually suppresses CGEventPost/Cmd-V is undocumented (§6,
// spike item 4). So these functions just attempt the post; the caller decides
// whether to skip when `secureInputActive()` is true. The spike attempts anyway
// (warn-and-observe) precisely to answer that open question.

// ---- CoreGraphics event synthesis ----
const CGEvent = opaque {};
const CGEventRef = ?*CGEvent;
const CGEventSourceRef = ?*opaque {};
const CGEventFlags = u64;
const UniChar = u16;

const kCGHIDEventTap: u32 = 0;
const kCGSessionEventTap: u32 = 1;
const kCGEventSourceStateCombinedSessionState: i32 = 0; // Maccy's choice
const kCGEventFlagMaskCommand: CGEventFlags = 0x100000; // CGEventTypes.h
const kCGEventFlagMaskControl: CGEventFlags = 0x040000; // CGEventTypes.h (tests only, so far)
/// An **un-modified** post: no ⌘, no ⌃, and — the point of naming it — nothing inherited from
/// whatever the user's hand is on (#244).
const no_flags: CGEventFlags = 0;
const kVK_ANSI_V: u16 = 0x09; // layout note: Dvorak-QWERTY-⌘ would need a keycode map
const kVK_Delete: u16 = 0x33; // Backspace / delete-backwards (Carbon HIToolbox Events.h)

extern "c" fn CGEventSourceCreate(state: i32) CGEventSourceRef;
extern "c" fn CGEventSourceSetUserData(src: CGEventSourceRef, data: i64) void;
extern "c" fn CGEventCreateKeyboardEvent(src: CGEventSourceRef, vk: u16, key_down: bool) CGEventRef;
extern "c" fn CGEventCreate(src: CGEventSourceRef) CGEventRef;
extern "c" fn CGEventSetType(ev: CGEventRef, etype: u32) void;
extern "c" fn CGEventSetFlags(ev: CGEventRef, flags: CGEventFlags) void;
extern "c" fn CGEventKeyboardSetUnicodeString(ev: CGEventRef, len: c_ulong, s: [*]const UniChar) void;
extern "c" fn CGEventPost(where: u32, ev: CGEventRef) void;
extern "c" fn CFRelease(cf: ?*anyopaque) void;

const kCGEventFlagsChanged: u32 = 12;

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

/// Default pre-paste settle: the gap between writing the pasteboard and posting Cmd-V.
/// NSPasteboard writes are synchronous to the pasteboard server, so this only guards
/// slow target apps — espanso's conservative 100 ms (§3) added a flat 100 ms to every
/// perceived insert, and comparable tools get away with 20–30 ms (issue #37). This is
/// the `Settings.pre_paste_ms` default; a slow target can dial it back up in config.zon.
pub const default_pre_paste_ms: u32 = 25;
/// espanso's constants (§3): let the async paste read finish after Cmd-V.
const restore_ms: u32 = 300;
const cmd_v_gap_ms: u32 = 10;
/// The Backspace burst's pacing, down-to-up and between pairs — `keystroke`'s chunk rhythm.
const key_gap_ms: u32 = 1;
/// Ceiling on a hand-edited `pre_paste_ms`: keeps `sleepMs`'s µs conversion inside u32
/// and `usleep` under its POSIX-specified 1 s — a settle beyond this is nonsense anyway.
const max_pre_paste_ms: u32 = 999;

/// Preflight (silent) and prompt for PostEvent access if absent.
pub fn requestPostEventAccess() bool {
    if (CGPreflightPostEventAccess()) return true;
    return CGRequestPostEventAccess();
}

/// Silent preflight only — never prompts. Trustworthy when `true`; a `false` can be a
/// lie for the rest of the process lifetime after a live grant (#129), so the daemon
/// ORs this with its attempt-then-observe latch (a `postTaggedProbe` seen back through
/// its own tap) instead of trusting it alone.
pub fn postEventGranted() bool {
    return CGPreflightPostEventAccess();
}

/// Post a tagged, invisible probe for the attempt-then-observe PostEvent detection
/// (#129): a flagsChanged event whose flags mirror the current session state (so apps
/// see no modifier change), tagged with tap.self_event_tag so the daemon's listen-only
/// tap — whose mask already passes flagsChanged — reports the round-trip via
/// `on_self_event`. Denied, the OS silently drops it; landed, it proves the grant live
/// where the preflight stays stale-`false`. Own throwaway source per post (the spike's
/// pattern), so it never races the Inserter's source across threads.
pub fn postTaggedProbe() void {
    const src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    defer if (src != null) CFRelease(@ptrCast(src));
    if (src != null) CGEventSourceSetUserData(src, tap.self_event_tag);
    const ev = CGEventCreate(src);
    if (ev == null) return;
    CGEventSetType(ev, kCGEventFlagsChanged);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(@ptrCast(ev));
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

/// Copy `text` into `dst`, guarantee it ends with exactly one trailing space, and
/// NUL-terminate — so consecutive Insertions don't run their words together (CONTEXT.md,
/// Insertion). Idempotent: a Final Transcript that already ends in whitespace is left as
/// is (no double space). Empty in → empty out, so an abandoned Utterance never lands a
/// lone space at the cursor. The copy is capped to leave room for the space + NUL, which
/// keeps the content ≤ `dst.len - 1` bytes so `keystroke`'s UTF-16 dest can't overflow.
/// `dst.len` must be ≥ 2 (the daemon's job buffer is 8193). Returns the NUL-terminated
/// slice (handed to `insert`).
pub fn ensureTrailingSpace(dst: []u8, text: []const u8) [:0]const u8 {
    std.debug.assert(dst.len >= 2);
    if (text.len == 0) {
        dst[0] = 0;
        return dst[0..0 :0];
    }
    // Reserve one byte for a possible space and one for the NUL terminator.
    var n = @min(text.len, dst.len - 2);
    @memcpy(dst[0..n], text[0..n]);
    if (!std.ascii.isWhitespace(dst[n - 1])) {
        dst[n] = ' ';
        n += 1;
    }
    dst[n] = 0;
    return dst[0..n :0];
}

/// The inverse of `ensureTrailingSpace`, and its neighbour so the two halves of the Insertion
/// separator rule stay in one place (ADR-0009). Drops the single trailing separator byte —
/// exactly the byte `ensureTrailingSpace` would have added — so a caller yields the text a
/// Recent Insertions row shows rather than the with-space bytes that hit the cursor
/// (recent-insertions spec §5.2.6). Only a literal space is stripped: a transcript that ends
/// in a newline already separated itself and keeps it. Empty in, empty out. Borrows `text`.
pub fn stripTrailingSpace(text: []const u8) []const u8 {
    if (text.len == 0) return text;
    return if (text[text.len - 1] == ' ') text[0 .. text.len - 1] else text;
}

/// The one place a synthesized key pair is built, stamped and posted — ⌘V and the Undo
/// Backspaces both go out through it, so a third primitive cannot repeat #244's omission.
///
/// **Flags are always set explicitly, on both the down and the up.** CoreGraphics stamps an
/// event created from a combined-session-state source with the modifiers the user is
/// *physically holding at creation time*, so a pair that merely omits `CGEventSetFlags`
/// inherits them. That is what made `⌃⌘⌫` reach the target app as `⌃⌘⌫` — unbound in AppKit
/// and Chromium — instead of a plain `⌫`, and delete nothing: the user's hand is still on the
/// chord when the Backspaces post, ~5–20 ms later. Un-modified means `no_flags`, never
/// "no call".
///
/// Generic over the event sink so what goes out is observable by *shape* (keycode, flags,
/// down/up) from a test rather than as a bare call count — the blind spot that let the defect
/// ship. `Sink` supplies `create` (null when the OS refuses), `setFlags`, `post`, `release`
/// and `sleep`; production binds it to `CGEventSink` below.
fn KeyPoster(comptime Sink: type) type {
    return struct {
        /// Post one down/up pair for `vk` carrying exactly `flags`, `gap_ms` apart. Returns
        /// false when the OS would not create the events — nothing was posted, and the caller
        /// must not claim otherwise.
        fn pair(sink: *Sink, vk: u16, flags: CGEventFlags, gap_ms: u32) bool {
            const down = sink.create(vk, true) orelse return false;
            defer sink.release(down);
            const up = sink.create(vk, false) orelse return false;
            defer sink.release(up);

            sink.setFlags(down, flags);
            sink.setFlags(up, flags);
            sink.post(down);
            sink.sleep(gap_ms);
            sink.post(up);
            return true;
        }

        /// The Undo deletion primitive (#214/#222/#244): `n` discrete **un-modified** Backspace
        /// (⌫) pairs, paced ~1 ms down-to-up and ~1 ms between pairs like `keystroke`'s chunks,
        /// **no cap**. `n` is the record's grapheme count, computed by the caller
        /// (`graphemeCount`, #220); `n == 0` posts nothing.
        ///
        /// Returns **how many pairs actually went out** — `n` when the whole burst posted,
        /// fewer when the OS refused to create an event partway. A short count is not "nothing
        /// happened": the pairs before the failure are already in the target app, so the caller
        /// must treat any count above zero as a committed (if incomplete) deletion. Re-running
        /// the full `n` would eat text that preceded the Insertion. Blind best-effort otherwise:
        /// a post-paste transform (autocorrect, smart quotes) can make N over- or under-delete
        /// by a bounded amount — accepted silently, no AX readback (#214).
        fn deleteChars(sink: *Sink, n: usize) usize {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (!pair(sink, kVK_Delete, no_flags, key_gap_ms)) return i;
                sink.sleep(key_gap_ms);
            }
            return n;
        }
    };
}

/// The production sink: real CGEvents on the Inserter's **self-tagged** source — so the Talk
/// Key tap recognises them as our own and skips them (#210) — posted to `kCGSessionEventTap`.
const CGEventSink = struct {
    src: CGEventSourceRef,

    fn create(self: *CGEventSink, vk: u16, down: bool) ?*CGEvent {
        return CGEventCreateKeyboardEvent(self.src, vk, down);
    }
    fn setFlags(_: *CGEventSink, ev: *CGEvent, flags: CGEventFlags) void {
        CGEventSetFlags(ev, flags);
    }
    fn post(_: *CGEventSink, ev: *CGEvent) void {
        CGEventPost(kCGSessionEventTap, ev);
    }
    fn release(_: *CGEventSink, ev: *CGEvent) void {
        CFRelease(@ptrCast(ev));
    }
    fn sleep(_: *CGEventSink, ms: u32) void {
        sleepMs(ms);
    }
};

pub const Inserter = struct {
    /// A tagged event source so our observer can recognise our own posts (§4).
    src: CGEventSourceRef = null,
    /// Clipboard restore deferred by `paste` (issue #38): the saved plain text (retained,
    /// or null if the clipboard held none) plus when Cmd-V was posted, so
    /// `drainDeferredRestore` can wait out only the *remainder* of the restore window.
    pending_restore: ?PendingRestore = null,

    const PendingRestore = struct { saved: id, cmdv_at_ms: i64 };

    pub fn init(self: *Inserter) void {
        self.src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
        if (self.src != null) CGEventSourceSetUserData(self.src, tap.self_event_tag);
    }

    /// Insert `utf8` (NUL-terminated) per `plan` (wayfinder #16; knobs read off one
    /// Settings Snapshot at job execution time). The keystroke path converts to the
    /// UTF-16 that `keystroke` wants; malformed UTF-8 (not expected from the
    /// transcription service) degrades to paste.
    pub fn insert(self: *Inserter, plan: Plan, utf8: [*:0]const u8) InsertError!void {
        switch (plan.method) {
            .paste => return self.paste(utf8, plan.pre_paste_ms),
            .keystroke => {
                const s = std.mem.span(utf8);
                // The Final Transcript buffer is 8192 bytes and UTF-16 units never
                // outnumber source bytes, so this dest can't overflow.
                var u16buf: [8192]u16 = undefined;
                const n = std.unicode.utf8ToUtf16Le(&u16buf, s) catch return self.paste(utf8, plan.pre_paste_ms);
                return self.keystroke(u16buf[0..n]);
            },
        }
    }

    /// Primary mechanism: save clipboard → set transcript → Cmd-V. Returns as soon as
    /// the Cmd-V settles; the clipboard restore is *deferred* to `drainDeferredRestore`
    /// so the restore window pads the insert worker's time, not the Coordinator's
    /// `.inserting` lockout (issue #38). `utf8` must be NUL-terminated (→ NSString).
    pub fn paste(self: *Inserter, utf8: [*:0]const u8, pre_paste_ms: u32) InsertError!void {
        // Ordering guard, first thing on every path: never let this paste's pasteboard
        // write interleave with a still-pending restore from the previous one. The
        // worker's serialization makes this a no-op in practice; this keeps the
        // mechanism correct on its own.
        self.drainDeferredRestore();
        // No preflight gate: post-grant it stays stale-`false` for the process lifetime
        // (#129), so the post is attempted unconditionally — the daemon only reaches
        // `configured` (and so ever schedules an insert) once a probe proved the grant.
        const t_paste = feedback.nowMs();

        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        const pb = sendId(objc_getClass("NSPasteboard"), "generalPasteboard");
        const type_utf8 = nsString(pb_type_utf8);

        // Save the current plain text (best effort — rich/promised types are lost
        // on restore, crib sheet §8). Retained so it outlives this pool and survives
        // clearContents, until `drainDeferredRestore` restores and releases it.
        const saved = stringForType(pb, type_utf8);
        if (saved != null) _ = sendId(saved, "retain");

        _ = sendLong(pb, "clearContents");
        setStringForType(pb, nsString(utf8), type_utf8);
        // Mark transient + concealed so clipboard managers skip our write (§8).
        setStringForType(pb, nsString(""), nsString("org.nspasteboard.TransientType"));
        setStringForType(pb, nsString(""), nsString("org.nspasteboard.ConcealedType"));

        sleepMs(@min(pre_paste_ms, max_pre_paste_ms));
        self.postCmdV();
        self.pending_restore = .{ .saved = saved, .cmdv_at_ms = feedback.nowMs() };
        // Text becomes visible at the Cmd-V post — the restore window that used to pad
        // the `.inserting` lockout now runs after completion is reported (issues #37/#38).
        feedback.log("  [insert] Cmd-V posted {d}ms into paste (text lands here; clipboard restore deferred)\n", .{feedback.nowMs() - t_paste});
    }

    /// Drain a restore deferred by `paste`: wait out whatever remains of the restore
    /// window (espanso's §3 rule — let the target's async paste read finish before the
    /// pasteboard changes again), then put the saved plain text back. No-op when nothing
    /// is pending (keystroke path, failed paste). Called by the insert worker *after*
    /// completion is reported, and by `paste` itself as the interleave guard.
    pub fn drainDeferredRestore(self: *Inserter) void {
        const p = self.pending_restore orelse return;
        self.pending_restore = null;

        // nowMs is wall-clock (the repo's deliberate libc choice) — clamp so a backward
        // clock step can't push the wait past restore_ms (and usleep past its 1 s POSIX
        // ceiling); a forward step at worst shortens the window to the fixed-sleep risk
        // every paste tool already accepts.
        const elapsed: i64 = @max(0, feedback.nowMs() - p.cmdv_at_ms);
        if (elapsed < restore_ms) sleepMs(@intCast(restore_ms - elapsed));

        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        const pb = sendId(objc_getClass("NSPasteboard"), "generalPasteboard");
        _ = sendLong(pb, "clearContents");
        if (p.saved != null) {
            setStringForType(pb, p.saved, nsString(pb_type_utf8));
            _ = sendId(p.saved, "release");
        }
    }

    /// A permanent, **non-transient** clipboard write for a user-initiated Copy
    /// (recent-insertions spec §5.2). Unlike `paste`, this is an honest clipboard write with
    /// **no save-and-restore**: the copied text is meant to stay. It does a plain
    /// `clearContents` + `setString` and deliberately does **not** set the
    /// `org.nspasteboard.TransientType` / `ConcealedType` markers `paste` uses: those tell
    /// clipboard managers to skip the write, and a Copy the user asked for should be a
    /// **normal, visible** pasteboard entry they pick up. `utf8` must be NUL-terminated
    /// (→ NSString).
    ///
    /// **Caller contract (spec §5.2.7):** the Insert Worker drains any pending deferred
    /// Insertion restore (`drainDeferredRestore`, via the adapter's `runCopy`) *before* calling
    /// this — so a late restore can't silently clobber the copied text — and this runs on that
    /// worker's serialization so the drain can't race a live insert. This write itself leaves
    /// nothing deferred, so there is no post-write restore to drain.
    pub fn copyToClipboard(self: *Inserter, utf8: [*:0]const u8) void {
        _ = self;
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        const pb = sendId(objc_getClass("NSPasteboard"), "generalPasteboard");
        _ = sendLong(pb, "clearContents");
        setStringForType(pb, nsString(utf8), nsString(pb_type_utf8));
        // No Transient/Concealed markers — a user Copy is a normal, visible entry (§5.2.7).
        feedback.log("  [copy] recorded insertion copied to the clipboard\n", .{});
    }

    /// The pair result is discarded deliberately: `paste` has already written the pasteboard
    /// and its caller reports the Insertion either way, so there is nothing here that could
    /// act on a refused ⌘V. (Undo is the path where a post that did not happen must not be
    /// claimed — see `deleteChars` and undo.zig, #244.)
    fn postCmdV(self: *Inserter) void {
        var sink = CGEventSink{ .src = self.src };
        _ = KeyPoster(CGEventSink).pair(&sink, kVK_ANSI_V, kCGEventFlagMaskCommand, cmd_v_gap_ms);
    }

    /// The Undo deletion mechanism, bound to real CGEvents: `KeyPoster.deleteChars` on this
    /// Inserter's self-tagged source. Returns how many Backspace pairs went out — `0` means
    /// nothing landed and the Undo Runner must refuse rather than confirm, and anything short
    /// of `n` is a committed-but-incomplete deletion the Runner must not retry (#244).
    pub fn deleteChars(self: *Inserter, n: usize) usize {
        // Ordering guard, as in `paste`: never let posted Backspaces land while a previous
        // Insertion's clipboard restore is still pending. The Insert Worker drains the Undo
        // Runner last, which makes this a no-op in practice; this keeps the mechanism correct
        // on its own rather than by the worker's drain order (ADR-0009).
        self.drainDeferredRestore();
        var sink = CGEventSink{ .src = self.src };
        return KeyPoster(CGEventSink).deleteChars(&sink, n);
    }

    /// Fallback: post `utf16` as synthetic keystrokes in ≤20-unit chunks, never
    /// splitting a surrogate pair, key-down+key-up per chunk with ~1 ms pacing
    /// (espanso's rules, §1–§2). Posts to the HID tap like the real injectors do.
    pub fn keystroke(self: *Inserter, utf16: []const UniChar) InsertError!void {
        // No preflight gate — same attempt-then-observe stance as `paste` (#129).
        var i: usize = 0;
        while (i < utf16.len) {
            var n: usize = @min(20, utf16.len - i);
            // Don't end a chunk on a high surrogate (0xD800..0xDBFF).
            if (n > 0 and utf16[i + n - 1] >= 0xD800 and utf16[i + n - 1] <= 0xDBFF) n -= 1;
            const chunk = utf16[i .. i + n];

            const down = CGEventCreateKeyboardEvent(self.src, 0x31, true); // carrier keycode (space)
            const up = CGEventCreateKeyboardEvent(self.src, 0x31, false);
            // Explicitly un-modified, for the reason `KeyPoster` documents (#244): these events
            // are created from a combined-session-state source too, so omitting this inherits
            // whatever the user is holding — and a chunk carrying ⌘ reads as a shortcut rather
            // than text. This path posts to the HID tap with a Unicode payload, so it builds its
            // own pair rather than going through the helper.
            CGEventSetFlags(down, no_flags);
            CGEventSetFlags(up, no_flags);
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

// ---- tests: pure, no OS (the trailing-space separator + the deferred restore) ----

const expectEqualStrings = std.testing.expectEqualStrings;

test "ensureTrailingSpace appends one space to a bare transcript" {
    var buf: [64]u8 = undefined;
    const out = ensureTrailingSpace(&buf, "hello world");
    try expectEqualStrings("hello world ", out);
    try std.testing.expectEqual(@as(u8, 0), buf[out.len]); // NUL-terminated
}

test "ensureTrailingSpace is idempotent when the transcript already ends in whitespace" {
    var buf: [64]u8 = undefined;
    try expectEqualStrings("done ", ensureTrailingSpace(&buf, "done ")); // trailing space kept, not doubled
    try expectEqualStrings("line\n", ensureTrailingSpace(&buf, "line\n")); // newline already separates
}

test "ensureTrailingSpace leaves empty in as empty out (no lone space)" {
    var buf: [64]u8 = undefined;
    const out = ensureTrailingSpace(&buf, "");
    try expectEqualStrings("", out);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
}

test "ensureTrailingSpace keeps content within dst so keystroke's UTF-16 dest can't overflow" {
    // A transcript longer than the buffer: content (incl. the space) must stay ≤ dst.len-1,
    // leaving the final byte for the NUL — the invariant keystroke's [N]u16 dest relies on.
    var buf: [8]u8 = undefined; // room for 7 content bytes + NUL
    const long = "abcdefghijkl";
    const out = ensureTrailingSpace(&buf, long);
    try std.testing.expect(out.len <= buf.len - 1);
    try std.testing.expectEqual(@as(u8, ' '), out[out.len - 1]); // still ends with the separator
    try std.testing.expectEqual(@as(u8, 0), buf[out.len]);
}

test "stripTrailingSpace removes exactly the separator ensureTrailingSpace added" {
    var buf: [64]u8 = undefined;
    // The round trip the Copy path relies on: the row's with-space bytes back to the text
    // the row shows (recent-insertions spec §5.2.6).
    try expectEqualStrings("hello world", stripTrailingSpace(ensureTrailingSpace(&buf, "hello world")));
    try expectEqualStrings("At 18:00", stripTrailingSpace("At 18:00 "));
}

test "stripTrailingSpace keeps a separator the transcript brought itself" {
    // ensureTrailingSpace appends nothing after a newline, so there is nothing to strip —
    // taking the byte anyway would eat the transcript's own formatting.
    try expectEqualStrings("line\n", stripTrailingSpace("line\n"));
    try expectEqualStrings("bare", stripTrailingSpace("bare"));
}

test "stripTrailingSpace leaves empty in as empty out and takes only one byte" {
    try expectEqualStrings("", stripTrailingSpace(""));
    try expectEqualStrings("", stripTrailingSpace(" "));
    // Only the single separator goes: deliberate padding survives, so a re-insert of the
    // stripped text still round-trips through ensureTrailingSpace to the same bytes.
    try expectEqualStrings("two  ", stripTrailingSpace("two   "));
}

test "drainDeferredRestore with nothing pending is a no-op" {
    // The keystroke path and a failed paste leave no deferred restore; the worker drains
    // unconditionally, so the early-out must not touch the pasteboard.
    var inserter = Inserter{};
    inserter.drainDeferredRestore();
    try std.testing.expect(inserter.pending_restore == null);
}

// ---- tests: the posted key pairs, observed by shape (#244) ----
//
// The seam `KeyPoster` exists for is exactly the defect these cover: what the target app
// receives is a (keycode, flags, down) triple, and a count of calls cannot see the flags. The
// fake below reproduces the one CoreGraphics behaviour that made `⌃⌘⌫` delete nothing — an
// event created from a combined-session-state source is stamped with the modifiers the user is
// *physically holding at creation time* — so a primitive that omits `setFlags` inherits them.

/// One synthesized key event as the target app receives it.
const PostedKey = struct { keycode: u16, flags: CGEventFlags, down: bool };

const FakeSink = struct {
    /// What the user is holding when the events are created — CoreGraphics stamps it on.
    live_flags: CGEventFlags = 0,
    /// Creation returns null from this many events on (the OS-refused-to-create path).
    creates_before_failure: usize = std.math.maxInt(usize),

    events: [64]PostedKey = undefined,
    created: usize = 0,
    posted: [64]PostedKey = undefined,
    posts: usize = 0,
    releases: usize = 0,
    sleeps: usize = 0,

    fn create(self: *FakeSink, vk: u16, down: bool) ?*PostedKey {
        if (self.created >= self.creates_before_failure) return null;
        if (self.created == self.events.len) @panic("FakeSink: more events than the fake can hold");
        const slot = &self.events[self.created];
        self.created += 1;
        slot.* = .{ .keycode = vk, .flags = self.live_flags, .down = down };
        return slot;
    }
    fn setFlags(_: *FakeSink, ev: *PostedKey, flags: CGEventFlags) void {
        ev.flags = flags;
    }
    fn post(self: *FakeSink, ev: *PostedKey) void {
        // `zig build test` compiles ReleaseFast, where an out-of-bounds write is silent UB —
        // so the capacity check is explicit rather than left to a safety panic.
        if (self.posts == self.posted.len) @panic("FakeSink: more posts than the fake can record");
        self.posted[self.posts] = ev.*;
        self.posts += 1;
    }
    fn release(self: *FakeSink, _: *PostedKey) void {
        self.releases += 1;
    }
    fn sleep(self: *FakeSink, _: u32) void {
        self.sleeps += 1;
    }
};

const FakeKeys = KeyPoster(FakeSink);

test "the deletion primitive posts one un-modified Backspace pair per cluster while ⌃⌘ is held" {
    // The regression (#244): the user is still holding the recovery chord when the Backspaces
    // go out — the chord handler only bumps a counter and the worker's idle poll is ~2 ms, so
    // the first ⌫ posts within ~5–20 ms of the press. Every posted event must carry flags = 0,
    // or the app sees ⌃⌘⌫ (unbound in AppKit and Chromium) and deletes nothing.
    var sink = FakeSink{ .live_flags = kCGEventFlagMaskControl | kCGEventFlagMaskCommand };

    try std.testing.expectEqual(@as(usize, 3), FakeKeys.deleteChars(&sink, 3));

    try std.testing.expectEqual(@as(usize, 6), sink.posts); // three down/up pairs, in order
    for (sink.posted[0..6], 0..) |k, i| {
        try std.testing.expectEqual(kVK_Delete, k.keycode);
        try std.testing.expectEqual(@as(CGEventFlags, 0), k.flags);
        try std.testing.expectEqual(i % 2 == 0, k.down); // down, up, down, up, …
    }
    try std.testing.expectEqual(sink.created, sink.releases); // nothing leaked
}

test "the deletion primitive posts nothing for zero clusters" {
    var sink = FakeSink{ .live_flags = kCGEventFlagMaskCommand };
    try std.testing.expectEqual(@as(usize, 0), FakeKeys.deleteChars(&sink, 0));
    try std.testing.expectEqual(@as(usize, 0), sink.posts);
}

test "a deletion the OS will not create posts nothing and says so" {
    // The Runner turns a zero count into a refusal: a record it could not delete must not be
    // flagged undone or confirmed (#244).
    var sink = FakeSink{ .creates_before_failure = 0 };

    try std.testing.expectEqual(@as(usize, 0), FakeKeys.deleteChars(&sink, 4));

    try std.testing.expectEqual(@as(usize, 0), sink.posts);
    try std.testing.expectEqual(sink.created, sink.releases);
}

test "a burst that fails partway reports the pairs already posted, not zero" {
    // The count is what stops the Runner from 'retrying' a deletion that half happened: those
    // Backspaces are in the target app, and re-running the full n would eat earlier text.
    var sink = FakeSink{ .creates_before_failure = 3 }; // pair 1 creates two, pair 2 fails on its down

    try std.testing.expectEqual(@as(usize, 1), FakeKeys.deleteChars(&sink, 4));

    try std.testing.expectEqual(@as(usize, 2), sink.posts); // exactly the one completed pair
    try std.testing.expectEqual(sink.created, sink.releases); // the half-built pair is released too
}

test "the paste primitive's pair keeps the ⌘ flag through the same helper" {
    // The other user of the shared helper: ⌘V must still carry ⌘ on *both* events, and must
    // not inherit whatever else is held either.
    var sink = FakeSink{ .live_flags = kCGEventFlagMaskControl };

    try std.testing.expect(FakeKeys.pair(&sink, kVK_ANSI_V, kCGEventFlagMaskCommand, cmd_v_gap_ms));

    try std.testing.expectEqual(@as(usize, 2), sink.posts);
    for (sink.posted[0..2]) |k| {
        try std.testing.expectEqual(kVK_ANSI_V, k.keycode);
        try std.testing.expectEqual(kCGEventFlagMaskCommand, k.flags);
    }
}
