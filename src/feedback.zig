//! feedback.zig — the daemon's feedback + failure surfacing (wayfinder #18).
//!
//! Two headless, ObjC-free surfaces (the overlay HUD is a separate ObjC front, #20):
//!
//!   1. Sound cues (AudioToolbox `AudioServicesPlaySystemSound`, pure C): a light
//!      **start** chime when an Utterance begins, a distinct **stop** chime on release,
//!      and a distinct **error** chime meaning "this Utterance produced no Insertion".
//!      Three built-in /System/Library/Sounds/*.aiff files are registered once at
//!      startup; playback is async (returns immediately) so it is safe to fire from the
//!      tap/run-loop/worker threads.
//!
//!   2. `log()` — a timestamped line writer. It writes to **stderr**; under the
//!      LaunchAgent (#15) launchd's `StandardErrorPath`/`StandardOutPath` route stderr
//!      to `~/Library/Logs/type-wave.log` — so that file is the daemon's diagnostic
//!      surface without this module fighting launchd for the handle. In a foreground
//!      `nix develop` run the same lines appear live in the terminal. Every state
//!      transition + operational error goes through here; Partial Transcripts are
//!      logged (never shown — there is no HUD yet).
//!
//! This module knows nothing about the Talk Key, Capture, the Session, or Insertion —
//! callers own the failure *policy* (what is an error, when to sound the error cue);
//! feedback only provides the mechanisms. Startup misconfiguration (config.zig) stays
//! on plain stderr: it precedes the running daemon, so it is not a state transition.

const std = @import("std");

// ---- timestamped logging ----------------------------------------------------
// libc time, to match session.zig's gettimeofday choice (std time-API churn on this
// nightly). localtime_r turns the epoch second into local wall-clock fields.

const timeval = extern struct { sec: i64, usec: i32 };
/// Darwin `struct tm`: nine ints, then tm_gmtoff (long) and tm_zone (char*).
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;
extern "c" fn localtime_r(clock: *const c_long, result: *Tm) ?*Tm;

/// Wall-clock milliseconds. libc, to sidestep std time-API churn on this nightly.
/// Lives here (not session.zig) so the insert-side modules can stamp timing deltas
/// without a dependency on the OpenAI half.
pub fn nowMs() i64 {
    var tv: timeval = undefined;
    _ = gettimeofday(&tv, null);
    return tv.sec * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

/// Format the current local time as `YYYY-MM-DD HH:MM:SS.mmm` into `buf`.
///
/// The components are cast to **unsigned** before formatting: on this Zig nightly a
/// width/fill spec (`{d:0>2}`) applied to a *signed* integer emits a `+` sign and skips
/// the zero-pad (e.g. `+7` instead of `07`); the same spec zero-pads correctly for an
/// unsigned value. All the fields here are non-negative, so the cast is safe.
fn writeTimestamp(buf: []u8) []const u8 {
    var tv: timeval = undefined;
    _ = gettimeofday(&tv, null);
    var t: c_long = tv.sec;
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null)
        return std.fmt.bufPrint(buf, "{d}", .{@as(u64, @bitCast(tv.sec))}) catch "?";
    const year: u32 = @intCast(1900 + tm.year);
    const mon: u32 = @intCast(tm.mon + 1);
    const mday: u32 = @intCast(tm.mday);
    const hour: u32 = @intCast(tm.hour);
    const min: u32 = @intCast(tm.min);
    const sec: u32 = @intCast(tm.sec);
    const ms: u32 = @intCast(@divTrunc(tv.usec, 1000));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        year, mon, mday, hour, min, sec, ms,
    }) catch "?";
}

/// Write one timestamped line. `fmt`/`args` are the std.debug.print convention (keep
/// the caller's trailing `\n`). The whole line is emitted in a single std.debug.print
/// call, which serialises on the global stderr lock — so lines from concurrent threads
/// (read-loop, maintenance, audio, worker, run-loop) never interleave.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    var tsbuf: [32]u8 = undefined;
    const ts = writeTimestamp(&tsbuf);
    var msgbuf: [16384]u8 = undefined; // holds a full Final Transcript (final[] is 8192)
    const msg = std.fmt.bufPrint(&msgbuf, fmt, args) catch {
        // Message too long to format — at least stamp and emit the template.
        std.debug.print("{s} {s}", .{ ts, fmt });
        return;
    };
    std.debug.print("{s} {s}", .{ ts, msg });
}

// ---- sound cues (AudioToolbox, pure C) --------------------------------------

const OSStatus = i32;
const SystemSoundID = u32;
const CFURLRef = ?*anyopaque;

extern "c" fn AudioServicesCreateSystemSoundID(inFileURL: CFURLRef, outSystemSoundID: *SystemSoundID) OSStatus;
extern "c" fn AudioServicesPlaySystemSound(inSystemSoundID: SystemSoundID) void;
extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?*anyopaque, buffer: [*]const u8, bufLen: c_long, isDir: u8) CFURLRef;
extern "c" fn CFRelease(cf: ?*anyopaque) void;

// Distinct built-in sounds so the three cues are audibly different: a light tick to
// start listening, a soft pop on release, and the classic macOS failure tone for a
// dropped Utterance.
const start_sound: []const u8 = "/System/Library/Sounds/Tink.aiff";
const stop_sound: []const u8 = "/System/Library/Sounds/Pop.aiff";
const error_sound: []const u8 = "/System/Library/Sounds/Basso.aiff";

/// The three registered system sounds. `init` once at startup; a failed registration
/// leaves that id 0 and its play call becomes a silent no-op (never blocks the daemon).
pub const Cues = struct {
    start_id: SystemSoundID = 0,
    stop_id: SystemSoundID = 0,
    error_id: SystemSoundID = 0,

    pub fn init(self: *Cues) void {
        self.start_id = register(start_sound);
        self.stop_id = register(stop_sound);
        self.error_id = register(error_sound);
        if (self.start_id == 0 or self.stop_id == 0 or self.error_id == 0)
            log("  feedback: a sound cue failed to register — cues may be silent\n", .{});
    }

    fn register(path: []const u8) SystemSoundID {
        const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0) orelse return 0;
        defer CFRelease(url);
        var id: SystemSoundID = 0;
        if (AudioServicesCreateSystemSoundID(url, &id) != 0) return 0;
        return id;
    }

    /// Utterance began — the daemon is listening.
    pub fn start(self: *Cues) void {
        if (self.start_id != 0) AudioServicesPlaySystemSound(self.start_id);
    }
    /// Talk Key released — Capture stopped, transcript pending.
    pub fn stop(self: *Cues) void {
        if (self.stop_id != 0) AudioServicesPlaySystemSound(self.stop_id);
    }
    /// This Utterance produced no Insertion (empty/failed transcript, no audio, a
    /// denied grant, or a failed insert).
    pub fn err(self: *Cues) void {
        if (self.error_id != 0) AudioServicesPlaySystemSound(self.error_id);
    }
};
