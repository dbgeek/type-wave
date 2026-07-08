//! Transcription Session over the OpenAI Realtime API (gpt-realtime-whisper,
//! manual commit). This module knows the OpenAI protocol and owns the websocket;
//! it knows nothing about CoreAudio or the Talk Key.
//!
//! Graduated from prototypes/cli-dictation/src/session.zig (wayfinder #8). The one
//! change from the prototype: a `final`/`final_len` buffer that retains the just-
//! completed Utterance's Final Transcript so Insertion can read it — the prototype
//! only printed it. The warm/reconnect lifecycle stays in fog here (wayfinder #17).
//!
//! Protocol per docs/research/openai-realtime-transcription.md.
//! Websocket API + the vendored §3.5 fix per docs/research/zig-websocket-tls.md.

const std = @import("std");
const websocket = @import("websocket");

pub const host = "api.openai.com";

// Manual-commit transcription config (crib sheet §2). turn_detection:null is
// mandatory for gpt-realtime-whisper and maps 1:1 onto hold-to-talk.
pub const session_update =
    \\{"type":"session.update","session":{"type":"transcription","audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"transcription":{"model":"gpt-realtime-whisper","language":"en","delay":"low"},"turn_detection":null,"noise_reduction":{"type":"near_field"}}}}}
;

const timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;

/// Wall-clock milliseconds. libc, to sidestep std time-API churn on this nightly.
pub fn nowMs() i64 {
    var tv: timeval = undefined;
    _ = gettimeofday(&tv, null);
    return tv.sec * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

pub const Session = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    client: websocket.Client,

    /// Guards ALL writes to the client. The library has no internal write lock
    /// (crib sheet §3.4): the read-loop thread (session.update, pongs), the audio
    /// thread (append), and main (commit, close) all write through this.
    write_mu: std.Io.Mutex = .init,

    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    got_final: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    bytes_utt: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// True only between beginUtterance and endUtterance. The audio thread forwards
    /// Capture chunks only while this is set, so buffers delivered outside an Utterance
    /// (the queue can deliver before an explicit start) are dropped.
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set under write_mu once the client is closed, so no write races with close.
    closed: bool = false,

    /// Utterance start, for relative event timestamps. Set by main before events flow.
    t0_ms: i64 = 0,

    /// Live Partial Transcript accumulator. Touched only on the read-loop thread.
    partial: [8192]u8 = undefined,
    partial_len: usize = 0,

    /// Final Transcript of the just-completed Utterance, retained for Insertion.
    /// Written on the read-loop thread *before* got_final is released; a consumer
    /// that reads it *after* observing got_final (acquire) sees the finished write.
    final: [8192]u8 = undefined,
    final_len: usize = 0,

    pub fn connect(io: std.Io, alloc: std.mem.Allocator, api_key: []const u8) !*Session {
        const self = try alloc.create(Session);
        errdefer alloc.destroy(self);

        self.* = .{
            .io = io,
            .alloc = alloc,
            .client = try websocket.Client.init(io, alloc, .{
                .host = host,
                .port = 443,
                .tls = true,
                .buffer_size = 16 * 1024,
                .max_size = 1 << 20,
            }),
        };
        errdefer self.client.deinit();

        // The library sends no Host header itself, so include it here alongside auth.
        var hdr_buf: [512]u8 = undefined;
        const headers = try std.fmt.bufPrint(&hdr_buf, "Host: {s}\r\nAuthorization: Bearer {s}", .{ host, api_key });
        // A transcription session's type is fixed at connect: a realtime session cannot be
        // reconfigured to transcription via session.update. Open it directly with
        // ?intent=transcription (resolves crib-sheet open Q2); the transcription model,
        // language, etc. are then set via session.update below.
        try self.client.handshake("/v1/realtime?intent=transcription", .{ .timeout_ms = 10_000, .headers = headers });

        return self;
    }

    pub fn deinit(self: *Session) void {
        self.client.deinit();
        self.alloc.destroy(self);
    }

    pub fn startReadLoop(self: *Session, handler: *Handler) !std.Thread {
        return self.client.readLoopInNewThread(handler);
    }

    fn sendControl(self: *Session, text: []const u8) !void {
        var buf: [1024]u8 = undefined;
        std.debug.assert(text.len <= buf.len);
        @memcpy(buf[0..text.len], text);
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        if (self.closed) return;
        try self.client.write(buf[0..text.len]);
    }

    /// Reset per-Utterance state. Call on Talk Key press, before capture starts.
    pub fn beginUtterance(self: *Session) void {
        self.bytes_utt.store(0, .release);
        self.got_final.store(false, .release);
        self.partial_len = 0;
        self.t0_ms = nowMs();
        self.active.store(true, .release);
    }

    /// Stop forwarding Capture audio. Call after the queue is stopped, before commit.
    pub fn endUtterance(self: *Session) void {
        self.active.store(false, .release);
    }

    /// Append one Capture chunk. Called on the AudioQueue thread; base64 + JSON +
    /// masked write all happen here (crib sheet blesses this on the AQ thread).
    pub fn appendAudio(self: *Session, pcm: []const u8) void {
        if (pcm.len == 0) return; // a 0-byte buffer (delivered during stop) => empty append, which errors
        if (!self.active.load(.acquire)) return; // not in an Utterance — drop it
        var buf: [8192]u8 = undefined; // 2400B pcm -> 3200 b64 + framing
        const prefix = "{\"type\":\"input_audio_buffer.append\",\"audio\":\"";
        const suffix = "\"}";
        @memcpy(buf[0..prefix.len], prefix);
        const enc = std.base64.standard.Encoder;
        const b64 = enc.encode(buf[prefix.len..], pcm);
        var end = prefix.len + b64.len;
        @memcpy(buf[end..][0..suffix.len], suffix);
        end += suffix.len;

        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        if (self.closed) return;
        self.client.write(buf[0..end]) catch return;
        _ = self.bytes_utt.fetchAdd(pcm.len, .monotonic);
    }

    /// Commit the Utterance (Talk Key release). Suppresses empty commits, which error.
    pub fn commitUtterance(self: *Session) !void {
        if (self.bytes_utt.load(.acquire) == 0) {
            std.debug.print("  (no audio captured — skipping commit)\n", .{});
            return;
        }
        try self.sendControl("{\"type\":\"input_audio_buffer.commit\"}");
    }

    pub fn shutdown(self: *Session) void {
        self.active.store(false, .release);
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        self.closed = true;
        self.client.close(.{}) catch {};
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

fn usageSeconds(root: std.json.Value) f64 {
    const u = getField(root, "usage") orelse return 0;
    const s = getField(u, "seconds") orelse return 0;
    return switch (s) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

fn errMessage(root: std.json.Value) []const u8 {
    const e = getField(root, "error") orelse return "(no message)";
    return getStr(e, "message") orelse "(no message)";
}

/// Websocket read-loop handler. All methods run on the read-loop thread.
pub const Handler = struct {
    session: *Session,

    pub fn serverMessage(self: *Handler, data: []u8) !void {
        const s = self.session;
        const parsed = std.json.parseFromSlice(std.json.Value, s.alloc, data, .{}) catch {
            std.debug.print("  [unparseable event] {s}\n", .{data});
            return;
        };
        defer parsed.deinit();
        const root = parsed.value;
        const typ = getStr(root, "type") orelse return;

        if (std.mem.eql(u8, typ, "session.created")) {
            try s.sendControl(session_update);
            std.debug.print("  session.created -> sent session.update\n", .{});
        } else if (std.mem.eql(u8, typ, "session.updated")) {
            s.ready.store(true, .release);
            std.debug.print("  session.updated -> READY\n", .{});
        } else if (std.mem.eql(u8, typ, "conversation.item.input_audio_transcription.delta")) {
            const d = getStr(root, "delta") orelse "";
            if (s.partial_len + d.len <= s.partial.len) {
                @memcpy(s.partial[s.partial_len..][0..d.len], d);
                s.partial_len += d.len;
            }
            std.debug.print("[{d:>6}ms] partial: {s}\n", .{ nowMs() - s.t0_ms, s.partial[0..s.partial_len] });
        } else if (std.mem.eql(u8, typ, "conversation.item.input_audio_transcription.completed")) {
            const t = getStr(root, "transcript") orelse "";
            const n = @min(t.len, s.final.len);
            @memcpy(s.final[0..n], t[0..n]);
            s.final_len = n;
            std.debug.print("[{d:>6}ms] FINAL: {s}  ({d:.2}s audio)\n", .{ nowMs() - s.t0_ms, t, usageSeconds(root) });
            s.got_final.store(true, .release); // release: publishes final[0..final_len]
        } else if (std.mem.eql(u8, typ, "conversation.item.input_audio_transcription.failed")) {
            std.debug.print("  transcription FAILED: {s}\n", .{errMessage(root)});
            s.final_len = 0; // nothing to insert
            s.got_final.store(true, .release);
        } else if (std.mem.eql(u8, typ, "error")) {
            std.debug.print("  ERROR event: {s}\n", .{errMessage(root)});
        } else if (std.mem.eql(u8, typ, "input_audio_buffer.committed")) {
            std.debug.print("[{d:>6}ms] committed (awaiting transcript)\n", .{nowMs() - s.t0_ms});
        }
        // else: item.created / item.added / etc. — ignored.
    }

    /// Route pongs through the write mutex like every other write (crib sheet §3.4).
    pub fn serverPing(self: *Handler, data: []u8) !void {
        const s = self.session;
        s.write_mu.lockUncancelable(s.io);
        defer s.write_mu.unlock(s.io);
        try s.client.writePong(data);
    }

    pub fn close(self: *Handler) void {
        _ = self;
        std.debug.print("  [read loop ended]\n", .{});
    }
};
