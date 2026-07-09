//! THROWAWAY delay-tier benchmark (issue #36). Streams a WAV fixture to a
//! Transcription Session at real-time pace — standing in for live Capture —
//! commits, and measures commit→Final-Transcript latency per `delay` tier,
//! plus word error rate against a reference text.
//!
//! Usage:
//!   bench <clip.wav> <tier> <runs> <gain> <reference text...>
//!
//! The WAV must be 24kHz mono s16le (generate with
//! `say -o clip.wav --data-format=LEI16@24000 "..."`). `gain` scales samples
//! (e.g. 0.15 ≈ -16dB) to simulate quiet speech. One Transcription Session per
//! invocation, `runs` Utterances over it — mirroring the real daemon's shape.
//!
//! Protocol + websocket idioms copied from session.zig; audio replaced by file
//! playback. Meant to be deleted with the rest of this prototype.

const std = @import("std");
const websocket = @import("websocket");

const host = "api.openai.com";

const timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn exit(code: c_int) noreturn;
// std.os.argv is gone on this nightly; this is macOS-only anyway.
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;

fn nowMs() i64 {
    var tv: timeval = undefined;
    _ = gettimeofday(&tv, null);
    return tv.sec * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

// ---------------------------------------------------------------------------
// WAV

const Wav = struct { pcm: []u8 };

/// Minimal RIFF parse; asserts 24kHz mono s16le, the Transcription Session's
/// input format. Returns the raw `data` chunk bytes.
fn parseWav(bytes: []u8) !Wav {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE"))
        return error.NotWav;
    var off: usize = 12;
    var pcm: ?[]u8 = null;
    while (off + 8 <= bytes.len) {
        const id = bytes[off .. off + 4];
        const size = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
        const body_end = off + 8 + size;
        if (body_end > bytes.len) return error.TruncatedChunk;
        const body = bytes[off + 8 .. body_end];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16) return error.BadFmt;
            const format = std.mem.readInt(u16, body[0..2], .little);
            const channels = std.mem.readInt(u16, body[2..4], .little);
            const rate = std.mem.readInt(u32, body[4..8], .little);
            const bits = std.mem.readInt(u16, body[14..16], .little);
            if (format != 1 or channels != 1 or rate != 24000 or bits != 16)
                return error.WrongFormat; // need 24kHz mono s16le
        } else if (std.mem.eql(u8, id, "data")) {
            pcm = body;
        }
        off = body_end + (size & 1); // chunks are word-aligned
    }
    return .{ .pcm = pcm orelse return error.NoData };
}

/// Scale samples in place; simulates quiet speech (e.g. gain 0.15 ≈ -16dB).
fn applyGain(pcm: []u8, gain: f64) void {
    var i: usize = 0;
    while (i + 1 < pcm.len) : (i += 2) {
        const s: f64 = @floatFromInt(std.mem.readInt(i16, pcm[i..][0..2], .little));
        const scaled = std.math.clamp(s * gain, -32768.0, 32767.0);
        std.mem.writeInt(i16, pcm[i..][0..2], @intFromFloat(scaled), .little);
    }
}

// ---------------------------------------------------------------------------
// WER

/// Normalize into lowercase words (alnum + apostrophe), then word-level
/// Levenshtein against the reference. Returns errors/ref_words.
fn wer(alloc: std.mem.Allocator, ref: []const u8, hyp: []const u8) !f64 {
    const r = try splitWords(alloc, ref);
    const h = try splitWords(alloc, hyp);
    if (r.len == 0) return if (h.len == 0) 0.0 else 1.0;

    // Two-row edit distance.
    var prev = try alloc.alloc(usize, h.len + 1);
    var cur = try alloc.alloc(usize, h.len + 1);
    for (prev, 0..) |*p, j| p.* = j;
    for (r, 0..) |rw, i| {
        cur[0] = i + 1;
        for (h, 0..) |hw, j| {
            const sub = prev[j] + @intFromBool(!std.mem.eql(u8, rw, hw));
            cur[j + 1] = @min(sub, @min(prev[j + 1], cur[j]) + 1);
        }
        std.mem.swap([]usize, &prev, &cur);
    }
    return @as(f64, @floatFromInt(prev[h.len])) / @as(f64, @floatFromInt(r.len));
}

fn splitWords(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    for (text) |c| {
        const lc = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lc) or lc == '\'') {
            try word.append(alloc, lc);
        } else if (word.items.len > 0) {
            try words.append(alloc, try word.toOwnedSlice(alloc));
        }
    }
    if (word.items.len > 0) try words.append(alloc, try word.toOwnedSlice(alloc));
    return words.items;
}

test "wer counts substitutions against the reference" {
    const talloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(talloc);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 0.0), try wer(a, "Hello, world!", "hello world"));
    try std.testing.expectEqual(@as(f64, 0.5), try wer(a, "one two", "one three"));
    try std.testing.expectEqual(@as(f64, 1.0), try wer(a, "one", ""));
}

// ---------------------------------------------------------------------------
// Session (bench flavor: parameterized delay, commit→final timing)

const Bench = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    client: websocket.Client,
    write_mu: std.Io.Mutex = .init,
    closed: bool = false,

    /// session.update with the tier under test baked in. Everything else is held
    /// at the daemon's production defaults (src/session.zig buildSessionUpdate).
    session_update: []const u8,

    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    got_final: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    t_final_ms: i64 = 0,
    /// Written on the read-loop thread before got_final's release-store; read on
    /// main after the acquire-load. No other synchronization needed.
    transcript: [8192]u8 = undefined,
    transcript_len: usize = 0,

    fn sendControl(self: *Bench, text: []const u8) !void {
        var buf: [1024]u8 = undefined;
        std.debug.assert(text.len <= buf.len);
        @memcpy(buf[0..text.len], text);
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        if (self.closed) return;
        try self.client.write(buf[0..text.len]);
    }

    fn appendAudio(self: *Bench, pcm: []const u8) !void {
        var buf: [8192]u8 = undefined; // 2400B pcm -> 3200 b64 + framing
        const prefix = "{\"type\":\"input_audio_buffer.append\",\"audio\":\"";
        const suffix = "\"}";
        @memcpy(buf[0..prefix.len], prefix);
        const b64 = std.base64.standard.Encoder.encode(buf[prefix.len..], pcm);
        var end = prefix.len + b64.len;
        @memcpy(buf[end..][0..suffix.len], suffix);
        end += suffix.len;
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        if (self.closed) return;
        try self.client.write(buf[0..end]);
    }
};

fn getField(v: std.json.Value, key: []const u8) ?std.json.Value {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return obj.get(key);
}

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

const Handler = struct {
    bench: *Bench,

    pub fn serverMessage(self: *Handler, data: []u8) !void {
        const b = self.bench;
        const parsed = std.json.parseFromSlice(std.json.Value, b.alloc, data, .{}) catch return;
        defer parsed.deinit();
        const typ = getStr(parsed.value, "type") orelse return;

        if (std.mem.eql(u8, typ, "session.created")) {
            try b.sendControl(b.session_update);
        } else if (std.mem.eql(u8, typ, "session.updated")) {
            b.ready.store(true, .release);
        } else if (std.mem.eql(u8, typ, "conversation.item.input_audio_transcription.completed")) {
            b.t_final_ms = nowMs();
            const t = getStr(parsed.value, "transcript") orelse "";
            b.transcript_len = @min(t.len, b.transcript.len);
            @memcpy(b.transcript[0..b.transcript_len], t[0..b.transcript_len]);
            b.got_final.store(true, .release);
        } else if (std.mem.eql(u8, typ, "conversation.item.input_audio_transcription.failed") or
            std.mem.eql(u8, typ, "error"))
        {
            std.debug.print("  server: {s}\n", .{data});
            if (std.mem.eql(u8, typ, "conversation.item.input_audio_transcription.failed"))
                b.got_final.store(true, .release);
        }
    }

    pub fn serverPing(self: *Handler, data: []u8) !void {
        const b = self.bench;
        b.write_mu.lockUncancelable(b.io);
        defer b.write_mu.unlock(b.io);
        try b.client.writePong(data);
    }

    pub fn close(self: *Handler) void {
        _ = self;
    }
};

fn waitFor(flag: *std.atomic.Value(bool), timeout_ms: usize) bool {
    var waited: usize = 0;
    while (!flag.load(.acquire)) {
        _ = usleep(10_000);
        waited += 10;
        if (waited >= timeout_ms) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------

const chunk_bytes = 2400; // 50ms of 24kHz s16le, same as live Capture delivery
const chunk_ms = 50;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    const alloc = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const argv = _NSGetArgv().*[0..@intCast(_NSGetArgc().*)];
    if (argv.len < 6) {
        std.debug.print("usage: bench <clip.wav> <tier> <runs> <gain> <reference text...>\n", .{});
        exit(2);
    }
    const wav_path = std.mem.span(argv[1]);
    const tier = std.mem.span(argv[2]);
    const runs = try std.fmt.parseInt(usize, std.mem.span(argv[3]), 10);
    const gain = try std.fmt.parseFloat(f64, std.mem.span(argv[4]));
    var ref: std.ArrayList(u8) = .empty;
    for (argv[5..], 0..) |a, i| {
        if (i > 0) try ref.append(alloc, ' ');
        try ref.appendSlice(alloc, std.mem.span(a));
    }

    const api_key_z = std.c.getenv("OPENAI_API_KEY") orelse {
        std.debug.print("OPENAI_API_KEY not set.\n", .{});
        exit(2);
    };
    const api_key = std.mem.span(api_key_z);

    const wav_bytes = try std.Io.Dir.cwd().readFileAlloc(io, wav_path, alloc, .limited(32 * 1024 * 1024));
    const wav = try parseWav(wav_bytes);
    if (gain != 1.0) applyGain(wav.pcm, gain);
    const audio_ms = wav.pcm.len / 48; // 48 bytes per ms at 24kHz s16le

    const bench = try alloc.create(Bench);
    bench.* = .{
        .io = io,
        .alloc = std.heap.c_allocator,
        .session_update = try std.fmt.allocPrint(alloc, "{{\"type\":\"session.update\",\"session\":{{\"type\":\"transcription\",\"audio\":{{\"input\":{{\"format\":{{\"type\":\"audio/pcm\",\"rate\":24000}},\"transcription\":{{\"model\":\"gpt-realtime-whisper\",\"language\":\"en\",\"delay\":\"{s}\"}},\"turn_detection\":null,\"noise_reduction\":{{\"type\":\"near_field\"}}}}}}}}}}", .{tier}),
        .client = try websocket.Client.init(io, std.heap.c_allocator, .{
            .host = host,
            .port = 443,
            .tls = true,
            .buffer_size = 16 * 1024,
            .max_size = 1 << 20,
        }),
    };

    var hdr_buf: [512]u8 = undefined;
    const headers = try std.fmt.bufPrint(&hdr_buf, "Host: {s}\r\nAuthorization: Bearer {s}", .{ host, api_key });
    try bench.client.handshake("/v1/realtime?intent=transcription", .{ .timeout_ms = 10_000, .headers = headers });

    var handler = Handler{ .bench = bench };
    _ = try bench.client.readLoopInNewThread(&handler);

    if (!waitFor(&bench.ready, 10_000)) {
        std.debug.print("timed out waiting for session.updated\n", .{});
        exit(1);
    }

    std.debug.print("tier={s} clip={s} audio={d}ms gain={d:.2} runs={d}\n", .{ tier, wav_path, audio_ms, gain, runs });

    var latencies = try alloc.alloc(i64, runs);
    var wers = try alloc.alloc(f64, runs);
    var ok: usize = 0;

    for (0..runs) |run| {
        bench.got_final.store(false, .release);
        bench.transcript_len = 0;

        // Real-time pacing on an absolute schedule (no cumulative drift): chunk i
        // goes out at start + i*50ms, exactly how live Capture would deliver it.
        const start = nowMs();
        var off: usize = 0;
        var i: usize = 0;
        while (off < wav.pcm.len) : (i += 1) {
            const end = @min(off + chunk_bytes, wav.pcm.len);
            try bench.appendAudio(wav.pcm[off..end]);
            off = end;
            const target = start + @as(i64, @intCast((i + 1) * chunk_ms));
            const late = nowMs();
            if (target > late) _ = usleep(@intCast(@as(i64, 1000) * (target - late)));
        }

        const t_commit = nowMs();
        try bench.sendControl("{\"type\":\"input_audio_buffer.commit\"}");

        if (!waitFor(&bench.got_final, 30_000)) {
            std.debug.print("  run {d}: NO FINAL within 30s\n", .{run + 1});
            continue;
        }
        const latency = bench.t_final_ms - t_commit;
        const transcript = bench.transcript[0..bench.transcript_len];
        const w = try wer(alloc, ref.items, transcript);
        latencies[ok] = latency;
        wers[ok] = w;
        ok += 1;
        std.debug.print("  run {d}: commit->final {d}ms  wer {d:.3}  \"{s}\"\n", .{ run + 1, latency, w, transcript });
        _ = usleep(500_000);
    }

    if (ok == 0) {
        std.debug.print("RESULT tier={s}: all runs failed\n", .{tier});
        exit(1);
    }
    std.mem.sort(i64, latencies[0..ok], {}, std.sort.asc(i64));
    var lat_sum: i64 = 0;
    for (latencies[0..ok]) |l| lat_sum += l;
    var wer_sum: f64 = 0;
    for (wers[0..ok]) |w| wer_sum += w;
    std.debug.print("RESULT tier={s} clip={s} ok={d}/{d} median={d}ms mean={d}ms min={d}ms max={d}ms wer_mean={d:.3}\n", .{
        tier,                     wav_path,          ok,               runs, latencies[ok / 2],
        @divTrunc(lat_sum, @as(i64, @intCast(ok))),  latencies[0],     latencies[ok - 1],
        wer_sum / @as(f64, @floatFromInt(ok)),
    });

    // Exit without a graceful close, like the prototype shell: the OS reclaims
    // the socket and we never race the read-loop thread.
    exit(0);
}
