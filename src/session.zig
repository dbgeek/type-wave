//! Transcription Session over the OpenAI Realtime API (gpt-realtime-whisper,
//! manual commit). This module knows the OpenAI protocol and owns the websocket;
//! it knows nothing about CoreAudio or the Talk Key.
//!
//! Graduated from prototypes/cli-dictation/src/session.zig (wayfinder #8), then grown
//! into the **warm long-lived lifecycle** (wayfinder #17):
//!
//!   - One Transcription Session connected at daemon start and kept open; a Talk Key
//!     press just begins appending (near-zero press-to-talk latency, partials stream
//!     immediately).
//!   - A **maintenance thread** keeps the link healthy between Utterances: a keepalive
//!     ping doubles as a drop probe, and the session is reconnected *only when idle* —
//!     proactively before the 60-min `expires_at` cap, and on a detected drop.
//!   - A Talk Key press while the session is not ready **buffers Capture locally** into
//!     `pending` and replays it in order once ready, so the Utterance is not lost.
//!   - A **graceful websocket close** (client close frame + drain) that #8 deferred (it
//!     exited the process instead, to dodge a read-thread teardown race). All stream
//!     teardown now happens single-threaded, on the maintenance/shutdown thread *after*
//!     the read loop has joined — see `closeCurrent`.
//!
//! Protocol per docs/research/openai-realtime-transcription.md.
//! Websocket API + the vendored §3.5 fix per docs/research/zig-websocket-tls.md.

const std = @import("std");
const websocket = @import("websocket");

pub const host = "api.openai.com";

// ---- warm-lifecycle tuning (wayfinder #17) ----------------------------------
/// Keepalive ping cadence when idle. Also the drop probe: a failed ping write, or a
/// missing pong, means the link is gone. Well under any idle-timeout the peer imposes.
const ping_interval_ms: i64 = 20_000;
/// How long after a ping we wait for the matching pong before declaring a drop.
const pong_timeout_ms: i64 = 10_000;
/// Reconnect this far ahead of `expires_at` so the cycle always lands between Utterances
/// rather than the server tearing the session down mid-word at the 60-min cap.
const expiry_margin_ms: i64 = 120_000;
/// Assumed session lifetime until `session.created` reports the real `expires_at` — a
/// conservative floor below the 60-min cap so we still cycle even if the field is absent.
const fallback_session_ms: i64 = 55 * 60 * 1000;
/// Maintenance loop granularity.
const maint_tick_ms: i64 = 200;
/// How long a reconnect waits for `session.updated` before retrying the attempt.
const ready_wait_ms: i64 = 10_000;
/// How long `closeCurrent` waits for the peer's close reply before forcing the socket.
const close_drain_ms: i64 = 1_500;
/// Local Capture buffer: 60 s of 24 kHz mono s16le (24000·2·60). A press that lands
/// while the link is down accumulates here and is replayed on reconnect.
const pending_cap: usize = 60 * 48_000;

/// The transcription knobs that vary by config (wayfinder #16), fed to the
/// session.update built at connect time. Defaults reproduce the exact string proven
/// live in #8. `noise_reduction` is null when disabled (emits JSON `null`).
pub const TranscriptionParams = struct {
    model: []const u8 = "gpt-realtime-whisper",
    language: []const u8 = "en",
    delay: []const u8 = "low",
    noise_reduction: ?[]const u8 = "near_field",
};

/// Manual-commit transcription config (crib sheet §2). turn_detection:null is
/// mandatory for gpt-realtime-whisper and maps 1:1 onto hold-to-talk. Built from
/// `params`; with the defaults it is byte-identical to the #8-proven constant
/// (a scratchpad check asserted this against the literal before it was inlined).
pub fn formatSessionUpdate(buf: []u8, params: TranscriptionParams) ![]const u8 {
    var nr_buf: [128]u8 = undefined;
    const nr = if (params.noise_reduction) |t|
        try std.fmt.bufPrint(&nr_buf, "{{\"type\":\"{s}\"}}", .{t})
    else
        "null";
    return std.fmt.bufPrint(buf, "{{\"type\":\"session.update\",\"session\":{{\"type\":\"transcription\",\"audio\":{{\"input\":{{\"format\":{{\"type\":\"audio/pcm\",\"rate\":24000}},\"transcription\":{{\"model\":\"{s}\",\"language\":\"{s}\",\"delay\":\"{s}\"}},\"turn_detection\":null,\"noise_reduction\":{s}}}}}}}}}", .{ params.model, params.language, params.delay, nr });
}

const timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

/// Wall-clock milliseconds. libc, to sidestep std time-API churn on this nightly.
pub fn nowMs() i64 {
    var tv: timeval = undefined;
    _ = gettimeofday(&tv, null);
    return tv.sec * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

fn sleepMs(ms: i64) void {
    if (ms <= 0) return;
    _ = usleep(@intCast(ms * 1000));
}

/// Where the warm session is in its lifecycle. Drives whether a Capture chunk streams
/// live or is buffered, and lets the daemon (#19) surface a status. `connecting` and
/// `reconnecting` differ only in provenance (first connect vs. a re-establish) so the
/// daemon can word the two states differently; both mean "not ready, buffer locally".
pub const State = enum(u8) { connecting, ready, reconnecting, closed };

pub const Session = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    client: websocket.Client,

    /// Retained so the maintenance thread can rebuild the connection on reconnect. Both
    /// borrow the process-lifetime Config (wayfinder #16), so they outlive the session.
    api_key: []const u8,
    params: TranscriptionParams,

    /// Guards ALL writes to the client. The library has no internal write lock
    /// (crib sheet §3.4): the read-loop thread (session.update, pongs), the audio
    /// thread (append), the maintenance thread (ping, close), and main (commit) all
    /// write through this.
    write_mu: std.Io.Mutex = .init,
    /// True only while `client` is a live, handshaken socket safe to write to. Guarded
    /// by `write_mu`; every writer checks it, so a torn-down/reconnecting client is
    /// never written to. Cleared at the very start of `closeCurrent`.
    link_open: bool = false,

    /// Lifecycle state. The read thread flips it to `.ready` (via markReadyAndFlush) and,
    /// on a drop, from `.ready` to `.reconnecting`; the maintenance thread drives the
    /// reconnect. appendAudio reads it to choose live-stream vs. local-buffer.
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.connecting),

    got_final: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    bytes_utt: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// True only between beginUtterance and endUtterance. The audio thread forwards
    /// Capture chunks only while this is set, so buffers delivered outside an Utterance
    /// (the queue can deliver before an explicit start) are dropped. Also the guard that
    /// keeps reconnects strictly *between* Utterances (maintenance skips while active).
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Session deadline in wall-clock ms (from `session.created`'s `expires_at`, or the
    /// conservative fallback). The maintenance thread cycles the session before it.
    expires_at_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// Last pong arrival (read thread), compared against `last_ping_ms` to detect drops.
    last_pong_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// Maintenance-thread-only ping bookkeeping.
    last_ping_ms: i64 = 0,
    awaiting_pong: bool = false,

    /// Set by the read loop's `close` callback when it ends (drop, server close, or our
    /// close-frame drain). The maintenance/shutdown thread waits on this before joining.
    read_ended: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Utterance start, for relative event timestamps. Set by beginUtterance.
    t0_ms: i64 = 0,

    /// Live Partial Transcript accumulator. Touched only on the read-loop thread.
    partial: [8192]u8 = undefined,
    partial_len: usize = 0,

    /// Final Transcript of the just-completed Utterance, retained for Insertion.
    /// Written on the read-loop thread *before* got_final is released; a consumer
    /// that reads it *after* observing got_final (acquire) sees the finished write.
    final: [8192]u8 = undefined,
    final_len: usize = 0,

    /// The config-built session.update, formatted once at connect (wayfinder #16) and
    /// replayed on every `session.created` (the read-loop thread sends it).
    su_buf: [2048]u8 = undefined,
    su_len: usize = 0,

    /// Local Capture buffer for a press that lands while the link is not ready. Guarded
    /// by `pending_mu`; drained in order by markReadyAndFlush the moment the session
    /// becomes ready. `pending_commit` records that the Utterance was already released
    /// (Talk Key up) while buffering, so the flush also sends the commit.
    handler: Handler = undefined,
    read_thread: ?std.Thread = null,
    maint_thread: ?std.Thread = null,

    pending: []u8,
    pending_len: usize = 0,
    pending_commit: bool = false,
    pending_overflow: bool = false,
    /// Ordered before `write_mu` everywhere it is taken (appendAudio, commitUtterance,
    /// markReadyAndFlush): the only nesting is pending_mu → write_mu, never the reverse.
    pending_mu: std.Io.Mutex = .init,

    pub fn connect(io: std.Io, alloc: std.mem.Allocator, api_key: []const u8, params: TranscriptionParams) !*Session {
        const self = try alloc.create(Session);
        errdefer alloc.destroy(self);
        const pending = try alloc.alloc(u8, pending_cap);
        errdefer alloc.free(pending);

        self.* = .{
            .io = io,
            .alloc = alloc,
            .client = undefined, // openClient establishes it
            .api_key = api_key,
            .params = params,
            .pending = pending,
        };
        self.su_len = (try formatSessionUpdate(&self.su_buf, params)).len;
        self.handler = .{ .session = self };

        try self.openClient(); // first connection: init + handshake + start read loop

        // Keep the link warm and cycle it between Utterances for the rest of the run.
        self.maint_thread = try std.Thread.spawn(.{}, maintenanceLoop, .{self});
        return self;
    }

    /// Free memory. Assumes `shutdown` already ran (link + threads torn down).
    pub fn deinit(self: *Session) void {
        self.alloc.free(self.pending);
        self.alloc.destroy(self);
    }

    /// Establish `self.client`: TCP+TLS connect, HTTP upgrade, start the read loop.
    /// Leaves `state` untouched (the read loop flips it to `.ready` on session.updated);
    /// on any failure `self.client` is deinited and the error propagates for the caller
    /// (connect / the reconnect loop) to handle.
    fn openClient(self: *Session) !void {
        self.client = try websocket.Client.init(self.io, self.alloc, .{
            .host = host,
            .port = 443,
            .tls = true,
            .buffer_size = 16 * 1024,
            .max_size = 1 << 20,
        });
        errdefer self.client.deinit();

        // The library sends no Host header itself, so include it here alongside auth.
        var hdr_buf: [512]u8 = undefined;
        const headers = try std.fmt.bufPrint(&hdr_buf, "Host: {s}\r\nAuthorization: Bearer {s}", .{ host, self.api_key });
        // A transcription session's type is fixed at connect: a realtime session cannot be
        // reconfigured to transcription via session.update. Open it directly with
        // ?intent=transcription (resolves crib-sheet open Q2); the transcription model,
        // language, etc. are then set via session.update on session.created.
        try self.client.handshake("/v1/realtime?intent=transcription", .{ .timeout_ms = 10_000, .headers = headers });

        // Provisional deadline until session.created reports the real one; reset drop probe.
        self.expires_at_ms.store(nowMs() + fallback_session_ms, .release);
        self.read_ended.store(false, .release);
        self.last_pong_ms.store(nowMs(), .release);
        self.last_ping_ms = nowMs();
        self.awaiting_pong = false;
        {
            self.write_mu.lockUncancelable(self.io);
            defer self.write_mu.unlock(self.io);
            self.link_open = true;
        }
        self.read_thread = try self.client.readLoopInNewThread(&self.handler);
    }

    /// Block until the session is `.ready`, or the timeout elapses, or it is closing.
    /// Returns true only on ready. Used by main after connect and by the reconnect loop.
    pub fn waitReady(self: *Session, timeout_ms: i64) bool {
        var waited: i64 = 0;
        while (true) {
            switch (self.state.load(.acquire)) {
                .ready => return true,
                .closed => return false,
                else => {},
            }
            if (waited >= timeout_ms) return false;
            sleepMs(20);
            waited += 20;
        }
    }

    pub fn isReady(self: *Session) bool {
        return self.state.load(.acquire) == .ready;
    }

    // ---- writes (all funnel through write_mu + the link_open guard) --------------

    /// Encode+send one Capture chunk as an input_audio_buffer.append. Caller decides
    /// whether the link is ready; this only writes (dropping if the link is down).
    fn rawAppend(self: *Session, pcm: []const u8) void {
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
        if (!self.link_open) return;
        self.client.write(buf[0..end]) catch {};
    }

    fn sendControl(self: *Session, text: []const u8) !void {
        var buf: [2048]u8 = undefined; // fits the config-built session.update (su_buf)
        std.debug.assert(text.len <= buf.len);
        @memcpy(buf[0..text.len], text);
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        if (!self.link_open) return;
        try self.client.write(buf[0..text.len]);
    }

    /// Reset per-Utterance state. Call on Talk Key press, before capture starts.
    pub fn beginUtterance(self: *Session) void {
        self.bytes_utt.store(0, .release);
        self.got_final.store(false, .release);
        self.partial_len = 0;
        self.t0_ms = nowMs();
        {
            // This Utterance owns the local buffer afresh (overlapping presses during a
            // reconnect are not hardened — same NB as main.zig; deferred to #19).
            self.pending_mu.lockUncancelable(self.io);
            defer self.pending_mu.unlock(self.io);
            self.pending_len = 0;
            self.pending_commit = false;
            self.pending_overflow = false;
        }
        self.active.store(true, .release);
    }

    /// Stop forwarding Capture audio. Call after the queue is stopped, before commit.
    pub fn endUtterance(self: *Session) void {
        self.active.store(false, .release);
    }

    /// Append one Capture chunk. Called on the AudioQueue thread; base64 + JSON +
    /// masked write all happen here (crib sheet blesses this on the AQ thread). When the
    /// link is not ready, the chunk is buffered locally instead of dropped, so a press
    /// during a reconnect does not lose the Utterance (wayfinder #17).
    pub fn appendAudio(self: *Session, pcm: []const u8) void {
        if (pcm.len == 0) return; // a 0-byte buffer (delivered during stop) => empty append, which errors
        if (!self.active.load(.acquire)) return; // not in an Utterance — drop it

        self.pending_mu.lockUncancelable(self.io);
        defer self.pending_mu.unlock(self.io);
        // Live path only when ready AND nothing is queued ahead of us — otherwise this
        // chunk must go behind the buffered prefix to keep the Utterance in order.
        if (self.state.load(.acquire) == .ready and self.pending_len == 0) {
            self.rawAppend(pcm);
        } else if (self.pending_len + pcm.len <= self.pending.len) {
            @memcpy(self.pending[self.pending_len..][0..pcm.len], pcm);
            self.pending_len += pcm.len;
        } else if (!self.pending_overflow) {
            self.pending_overflow = true;
            std.debug.print("  (buffered Capture hit {d}B during reconnect — truncating this Utterance)\n", .{self.pending.len});
        }
        _ = self.bytes_utt.fetchAdd(pcm.len, .monotonic); // count buffered audio too, so commit isn't suppressed
    }

    /// Commit the Utterance (Talk Key release). Suppresses empty commits, which error.
    /// If the link is not ready, the commit is deferred: markReadyAndFlush replays the
    /// buffered audio and sends the commit once the session reconnects.
    pub fn commitUtterance(self: *Session) !void {
        if (self.bytes_utt.load(.acquire) == 0) {
            std.debug.print("  (no audio captured — skipping commit)\n", .{});
            return;
        }
        self.pending_mu.lockUncancelable(self.io);
        defer self.pending_mu.unlock(self.io);
        if (self.state.load(.acquire) == .ready and self.pending_len == 0) {
            try self.sendControl("{\"type\":\"input_audio_buffer.commit\"}");
        } else {
            self.pending_commit = true; // flushed + committed on reconnect
        }
    }

    /// Session became READY (session.updated). Replay any buffered Capture in order,
    /// then commit if the Utterance was already released, then publish `.ready` — all
    /// under pending_mu so appendAudio can't interleave a live chunk ahead of the
    /// buffered prefix. Runs on the read-loop thread.
    fn markReadyAndFlush(self: *Session) void {
        self.pending_mu.lockUncancelable(self.io);
        defer self.pending_mu.unlock(self.io);

        if (self.pending_len > 0) {
            std.debug.print("  replaying {d}B buffered Capture\n", .{self.pending_len});
            var off: usize = 0;
            while (off < self.pending_len) {
                const chunk_end = @min(off + 2400, self.pending_len);
                self.rawAppend(self.pending[off..chunk_end]);
                off = chunk_end;
            }
        }
        if (self.pending_commit) {
            self.sendControl("{\"type\":\"input_audio_buffer.commit\"}") catch {};
            self.pending_commit = false;
        }
        self.pending_len = 0;
        self.pending_overflow = false;
        self.state.store(.ready, .release);
    }

    // ---- maintenance: keepalive + drop detection + reconnect --------------------

    fn maintenanceLoop(self: *Session) void {
        while (self.state.load(.acquire) != .closed) {
            sleepMs(maint_tick_ms);
            switch (self.state.load(.acquire)) {
                .closed => return,
                .connecting => continue, // connect() drives the first handshake
                .reconnecting => {
                    // A drop was flagged (possibly mid-Utterance); cycle once idle.
                    if (!self.active.load(.acquire)) self.reconnect();
                    continue;
                },
                .ready => {},
            }
            if (self.active.load(.acquire)) continue; // never disturb an in-flight Utterance

            const now = nowMs();
            if (self.read_ended.load(.acquire)) {
                std.debug.print("  session: link dropped (read loop ended) — reconnecting\n", .{});
                self.reconnect();
                continue;
            }
            const exp = self.expires_at_ms.load(.acquire);
            if (exp != 0 and now >= exp - expiry_margin_ms) {
                std.debug.print("  session: approaching the 60-min cap — cycling the session\n", .{});
                self.reconnect();
                continue;
            }
            if (self.awaiting_pong and now - self.last_ping_ms >= pong_timeout_ms) {
                if (self.last_pong_ms.load(.acquire) >= self.last_ping_ms) {
                    self.awaiting_pong = false; // pong arrived — healthy
                } else {
                    std.debug.print("  session: no pong within {d}ms — reconnecting\n", .{pong_timeout_ms});
                    self.reconnect();
                    continue;
                }
            }
            if (now - self.last_ping_ms >= ping_interval_ms) self.sendPing();
        }
    }

    fn sendPing(self: *Session) void {
        {
            self.write_mu.lockUncancelable(self.io);
            defer self.write_mu.unlock(self.io);
            if (!self.link_open) return;
            var empty: [0]u8 = .{};
            self.client.writePing(&empty) catch {
                std.debug.print("  session: ping write failed — link down\n", .{});
                _ = self.state.cmpxchgStrong(.ready, .reconnecting, .monotonic, .monotonic);
                return;
            };
        }
        self.last_ping_ms = nowMs();
        self.awaiting_pong = true;
    }

    /// Cycle the connection. Runs on the maintenance thread only (or, at shutdown, on the
    /// main thread after the maintenance thread has joined) — never concurrently.
    fn reconnect(self: *Session) void {
        self.state.store(.reconnecting, .release);
        self.closeCurrent();

        var attempt: usize = 0;
        while (self.state.load(.acquire) != .closed) {
            self.openClient() catch |e| {
                attempt += 1;
                const backoff = backoffMs(attempt);
                std.debug.print("  reconnect attempt {d} failed: {s} — retrying in {d}ms\n", .{ attempt, @errorName(e), backoff });
                self.sleepInterruptible(backoff);
                continue;
            };
            if (self.waitReady(ready_wait_ms)) {
                std.debug.print("  session: reconnected and READY\n", .{});
                return;
            }
            std.debug.print("  reconnect: no session.updated within {d}ms — retrying\n", .{ready_wait_ms});
            self.closeCurrent();
            attempt += 1;
            self.sleepInterruptible(backoffMs(attempt));
        }
    }

    fn backoffMs(attempt: usize) i64 {
        const shift: u6 = @intCast(@min(attempt, 4)); // 0.5s,1s,2s,4s,8s cap
        return @min(@as(i64, 500) << shift, 8_000);
    }

    /// A backoff sleep that returns early if the session is shut down, so `shutdown`'s
    /// join of the maintenance thread never waits a full backoff.
    fn sleepInterruptible(self: *Session, ms: i64) void {
        var waited: i64 = 0;
        while (waited < ms and self.state.load(.acquire) != .closed) {
            sleepMs(50);
            waited += 50;
        }
    }

    /// Graceful close of the current connection (client close frame + drain), then join
    /// the read loop and free the client. Race-free: our close frame does NOT tear down
    /// the stream — the read loop receives the peer's close reply (our `serverClose` is a
    /// no-op) and ends, and *this* thread frees the socket via deinit only after joining.
    /// The read loop being joined first is what makes the teardown single-threaded.
    fn closeCurrent(self: *Session) void {
        {
            self.write_mu.lockUncancelable(self.io);
            defer self.write_mu.unlock(self.io);
            if (self.link_open) {
                self.link_open = false;
                var empty: [0]u8 = .{};
                self.client.writeFrame(websocket.OpCode.close, &empty) catch {};
            }
        }

        var waited: i64 = 0;
        while (!self.read_ended.load(.acquire) and waited < close_drain_ms) {
            sleepMs(20);
            waited += 20;
        }
        // Half-open peer that never replied: force the socket down to unblock the read
        // loop (readLoop requires a blocking read, so this is the only way to wake it).
        // This is the one path that carries the vendored library's teardown race, and
        // only on a dead link where the raced-over bytes are meaningless.
        if (!self.read_ended.load(.acquire)) {
            std.debug.print("  session: close drain timed out — forcing the socket down\n", .{});
            self.client.close(.{}) catch {};
        }
        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }
        self.client.deinit();
    }

    /// Graceful shutdown for good: stop the maintenance thread, then close the link.
    pub fn shutdown(self: *Session) void {
        self.active.store(false, .release);
        self.state.store(.closed, .release);
        if (self.maint_thread) |t| {
            t.join();
            self.maint_thread = null;
        }
        self.closeCurrent();
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

fn getInt(v: std.json.Value, key: []const u8) ?i64 {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
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
            // The session object carries the real 60-min deadline; read it so the
            // maintenance thread cycles the session just before the server would.
            if (getField(root, "session")) |sess| {
                if (getInt(sess, "expires_at")) |secs| {
                    if (secs > 0) s.expires_at_ms.store(secs * 1000, .release);
                }
            }
            try s.sendControl(s.su_buf[0..s.su_len]);
            std.debug.print("  session.created -> sent session.update\n", .{});
        } else if (std.mem.eql(u8, typ, "session.updated")) {
            s.markReadyAndFlush();
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
        if (!s.link_open) return;
        try s.client.writePong(data);
    }

    /// Our keepalive pong: proves the link is alive to the maintenance thread's probe.
    pub fn serverPong(self: *Handler, data: []u8) !void {
        _ = data;
        self.session.last_pong_ms.store(nowMs(), .release);
    }

    /// The peer initiated a close. Deliberately do NOT tear the stream down here: the
    /// read loop returns next, `close` fires, and closeCurrent (on the maintenance/
    /// shutdown thread) frees the socket after joining — keeping teardown single-threaded
    /// so it never races an in-flight read (the race #8's prototype dodged by exiting).
    pub fn serverClose(self: *Handler, data: []u8) !void {
        _ = data;
        _ = self;
        std.debug.print("  session: server sent a close frame\n", .{});
    }

    /// Read loop ended (drop, server close, or our drain). Flag it for the maintenance
    /// thread, and if this was an unexpected drop while ready, move to `.reconnecting`
    /// so appendAudio starts buffering immediately (the cmpxchg no-ops during a
    /// deliberate reconnect or shutdown).
    pub fn close(self: *Handler) void {
        const s = self.session;
        s.read_ended.store(true, .release);
        _ = s.state.cmpxchgStrong(.ready, .reconnecting, .monotonic, .monotonic);
        std.debug.print("  [read loop ended]\n", .{});
    }
};
