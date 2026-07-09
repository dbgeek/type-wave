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
//!   - A dedicated **sender thread** owns every data write: Capture appends and commits
//!     are enqueued onto an outbound ring (a memcpy, never a socket write) and drained
//!     in order once the session is ready. The AudioQueue and Talk Key tap threads thus
//!     never block on TLS — a network stall parks the sender while the ring absorbs the
//!     Utterance — and a press while the session is not ready simply accumulates in the
//!     ring and replays on reconnect, deferred commit included, so the Utterance is not
//!     lost.
//!   - A **graceful websocket close** (client close frame + drain) that #8 deferred (it
//!     exited the process instead, to dodge a read-thread teardown race). All stream
//!     teardown now happens single-threaded, on the maintenance/shutdown thread *after*
//!     the read loop has joined — see `closeCurrent`.
//!
//! Protocol per docs/research/openai-realtime-transcription.md.
//! Websocket API + the vendored §3.5 fix per docs/research/zig-websocket-tls.md.

const std = @import("std");
const websocket = @import("websocket");
const feedback = @import("feedback.zig");

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
/// Outbound ring geometry: each slot carries one Capture chunk (capture.zig's 2400 B =
/// 50 ms) or one small control message. 60 s of Capture at 20 chunks/s — the same
/// absorption the old local buffer gave a press that lands while the link is down —
/// plus headroom for control records.
const out_payload_cap: usize = 2400;
const out_slot_count: usize = 60 * 20 + 8;
/// Sender-thread poll cadence while the ring is empty (or the session is not ready).
/// Well under the 50 ms Capture cadence, so a queued chunk never waits meaningfully.
const sender_tick_ms: i64 = 5;

/// One outbound record: a Capture chunk (base64-framed by the sender at write time) or
/// a small control message (the commit / input_audio_buffer.clear JSON).
const OutKind = enum(u8) { audio, control };
const OutRecord = struct {
    kind: OutKind,
    len: u16,
    data: [out_payload_cap]u8,
};

/// A subscriber to the live transcript stream (wayfinder #22). The daemon wires this so
/// the Final Transcript reaches the Utterance Coordinator the moment it lands. The
/// callbacks run on the **read-loop thread**, so they must be fast and thread-safe.
/// `text` borrows the session's accumulator and is valid only for the duration of the
/// call. Left null when nothing subscribes, in which case transcripts are only logged,
/// exactly as before (wayfinder #18).
pub const TranscriptObserver = struct {
    ctx: ?*anyopaque,
    /// The accumulated Partial Transcript so far (grows as deltas arrive). Optional:
    /// the daemon no longer subscribes partials — the HUD shows no text (wayfinder
    /// #27) — but the seam stays for any future consumer. Partials are always logged
    /// (#18) regardless.
    on_partial: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// The completed Final Transcript for the Utterance.
    on_final: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

/// The transcription knobs that vary by config (wayfinder #16), fed to the
/// session.update built at connect time. Defaults reproduce the exact string proven
/// live in #8. `noise_reduction` is null when disabled (emits JSON `null`);
/// `language` empty means auto-detect (the field is omitted from the JSON).
pub const TranscriptionParams = struct {
    model: []const u8 = "gpt-realtime-whisper",
    language: []const u8 = "en",
    delay: []const u8 = "low",
    noise_reduction: ?[]const u8 = "near_field",
};

/// Where the Session gets its TranscriptionParams — re-invoked at EVERY connect attempt
/// (first connect and each reconnect alike), so a live settings change (wayfinder #32)
/// binds simply by cycling the link. The daemon backs this with the current Settings
/// snapshot; the returned slices must outlive the Session (snapshots leak by design).
pub const ParamsProvider = struct {
    ctx: ?*anyopaque,
    get: *const fn (ctx: ?*anyopaque) TranscriptionParams,
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
    var lang_buf: [160]u8 = undefined;
    const lang = if (params.language.len == 0)
        "" // auto-detect: omit the field entirely (wayfinder #34's Language preset)
    else
        try std.fmt.bufPrint(&lang_buf, "\"language\":\"{s}\",", .{params.language});
    return std.fmt.bufPrint(buf, "{{\"type\":\"session.update\",\"session\":{{\"type\":\"transcription\",\"audio\":{{\"input\":{{\"format\":{{\"type\":\"audio/pcm\",\"rate\":24000}},\"transcription\":{{\"model\":\"{s}\",{s}\"delay\":\"{s}\"}},\"turn_detection\":null,\"noise_reduction\":{s}}}}}}}}}", .{ params.model, lang, params.delay, nr });
}

extern "c" fn usleep(usec: c_uint) c_int;

/// Wall-clock milliseconds (feedback.zig owns the libc mechanism).
pub const nowMs = feedback.nowMs;

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

    /// Retained so the maintenance thread can rebuild the connection on reconnect. The
    /// key borrows a process-lifetime allocation (wayfinder #16); the provider re-reads
    /// the current Settings snapshot at every connect (wayfinder #32).
    api_key: []const u8,
    params_provider: ParamsProvider,

    /// Optional live-transcript subscriber (the overlay HUD, wayfinder #22). Set once at
    /// connect, before the read loop starts, so it is never installed mid-stream. Read
    /// only on the read-loop thread (serverMessage). null ⇒ transcripts are only logged.
    observer: ?TranscriptObserver = null,

    /// Guards ALL writes to the client. The library has no internal write lock
    /// (crib sheet §3.4): the sender thread (Capture appends, commits), the read-loop
    /// thread (session.update, pongs), and the maintenance thread (ping, close) all
    /// write through this. The AudioQueue and tap threads never take it — they only
    /// enqueue onto the outbound ring.
    write_mu: std.Io.Mutex = .init,
    /// True only while `client` is a live, handshaken socket safe to write to. Guarded
    /// by `write_mu`; every writer checks it, so a torn-down/reconnecting client is
    /// never written to. Cleared at the very start of `closeCurrent`.
    link_open: bool = false,

    /// Lifecycle state. The read thread flips it to `.ready` (via markReady) and,
    /// on a drop, from `.ready` to `.reconnecting`; the maintenance thread drives the
    /// reconnect. The sender thread reads it to decide whether to drain the outbound
    /// ring or let records accumulate.
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.connecting),

    bytes_utt: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// True only between beginUtterance and endUtterance. The audio thread forwards
    /// Capture chunks only while this is set, so buffers delivered outside an Utterance
    /// (the queue can deliver before an explicit start) are dropped. Also the guard that
    /// keeps reconnects strictly *between* Utterances (maintenance skips while active).
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Set when the link drops (a genuine `.ready`→`.reconnecting` transition) *while an
    /// Utterance is active*: the head audio already streamed live is gone server-side, so
    /// committing the buffered tail would insert a truncated Final Transcript. The daemon
    /// (wayfinder #19) reads this on Talk Key release to abandon the Utterance cleanly
    /// (error cue, no Insertion) rather than commit a fragment. Reset by beginUtterance,
    /// set in Handler.close. This is what distinguishes a real mid-hold drop (abandon)
    /// from a press that merely *landed* during a reconnect (that path buffers-and-flushes
    /// — wayfinder #17 — and never sets this, because no `.ready`→ transition occurs).
    poisoned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

    /// A session-shaped setting (model/language/delay/noise_reduction) changed in the
    /// live snapshot (wayfinder #32). Set by the menu via `markParamsDirty`; the
    /// maintenance loop — already the sole reconnect owner, already idle-only — cycles
    /// the session at its next idle tick, and `openClient` re-reads the snapshot. An
    /// in-flight Utterance always completes on the old params.
    params_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Utterance start, for relative event timestamps. Set by beginUtterance.
    t0_ms: i64 = 0,

    /// Talk Key release, anchoring the post-release timing splits (release→committed→
    /// FINAL — the speak→insert latency hunt, issues #36–#38). Set by endUtterance;
    /// read on the read-loop thread — the same benign cross-thread pattern as t0_ms.
    t_release_ms: i64 = 0,

    /// Live Partial Transcript accumulator. Touched only on the read-loop thread.
    partial: [8192]u8 = undefined,
    partial_len: usize = 0,

    /// Read-loop scratch for building the Final Transcript slice handed to the observer's
    /// `on_final` (the Utterance Coordinator subscribes it). Touched only on the read-loop
    /// thread; the observer copies synchronously, so nothing outlives the callback.
    final: [8192]u8 = undefined,
    final_len: usize = 0,

    /// The config-built session.update, re-formatted from the live snapshot at every
    /// connect attempt (openClient, before the read loop starts — wayfinder #32) and
    /// replayed on every `session.created` (the read-loop thread sends it).
    su_buf: [2048]u8 = undefined,
    su_len: usize = 0,

    handler: Handler = undefined,
    read_thread: ?std.Thread = null,
    maint_thread: ?std.Thread = null,
    sender_thread: ?std.Thread = null,

    /// The outbound ring: EVERY data write — Capture appends and the per-Utterance
    /// commit — is enqueued here and drained in order by the sender thread once the
    /// session is `.ready`. Enqueue is a memcpy under `out_mu`, never a socket write,
    /// so the AudioQueue and tap threads never block on TLS; while the link is down,
    /// records simply accumulate (subsuming #17's press-mid-reconnect buffer) and
    /// replay in order — deferred commit included — on reconnect. `out_mu` never nests
    /// with `write_mu`: producers take only `out_mu`; the sender takes the two strictly
    /// one after the other.
    out: []OutRecord,
    out_head: usize = 0, // next slot to drain
    out_count: usize = 0, // filled slots
    out_overflow: bool = false, // ring-full already logged for this Utterance
    out_mu: std.Io.Mutex = .init,

    pub fn connect(io: std.Io, alloc: std.mem.Allocator, api_key: []const u8, params_provider: ParamsProvider, observer: ?TranscriptObserver) !*Session {
        const self = try alloc.create(Session);
        errdefer alloc.destroy(self);
        const out = try alloc.alloc(OutRecord, out_slot_count);
        errdefer alloc.free(out);

        self.* = .{
            .io = io,
            .alloc = alloc,
            .client = undefined, // openClient establishes it
            .api_key = api_key,
            .params_provider = params_provider,
            .observer = observer, // set before openClient starts the read loop — never mid-stream
            .out = out,
        };
        self.handler = .{ .session = self };

        try self.openClient(); // first connection: init + handshake + start read loop

        // The sender drains the outbound ring for the rest of the run; the maintenance
        // thread keeps the link warm and cycles it between Utterances.
        self.sender_thread = try std.Thread.spawn(.{}, senderLoop, .{self});
        self.maint_thread = try std.Thread.spawn(.{}, maintenanceLoop, .{self});
        return self;
    }

    /// Free memory. Assumes `shutdown` already ran (link + threads torn down).
    pub fn deinit(self: *Session) void {
        self.alloc.free(self.out);
        self.alloc.destroy(self);
    }

    /// Establish `self.client`: TCP+TLS connect, HTTP upgrade, start the read loop.
    /// Leaves `state` untouched (the read loop flips it to `.ready` on session.updated);
    /// on any failure `self.client` is deinited and the error propagates for the caller
    /// (connect / the reconnect loop) to handle.
    fn openClient(self: *Session) !void {
        // Re-read the live Settings snapshot and rebuild the session.update NOW — every
        // connect (first and reconnect alike) speaks the freshest params (wayfinder #32).
        // Clear the dirty flag first: a change landing after the clear is still picked up
        // by this very read (the provider loads the current snapshot), and the stale flag
        // then costs at most one redundant idle cycle later.
        self.params_dirty.store(false, .release);
        const params = self.params_provider.get(self.params_provider.ctx);
        self.su_len = (try formatSessionUpdate(&self.su_buf, params)).len;

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

    /// True when the link dropped mid-Utterance (see `poisoned`). The daemon checks this
    /// on Talk Key release to abandon a would-be-truncated Utterance (wayfinder #19).
    pub fn isPoisoned(self: *Session) bool {
        return self.poisoned.load(.acquire);
    }

    /// A session-shaped setting changed (wayfinder #32) — request an idle cycle so the
    /// next connect re-reads the snapshot. Safe from any thread; never disturbs an
    /// in-flight Utterance (the maintenance loop's existing idle gate).
    pub fn markParamsDirty(self: *Session) void {
        self.params_dirty.store(true, .release);
    }

    // ---- writes (all funnel through write_mu + the link_open guard) --------------

    /// Encode+send one Capture chunk as an input_audio_buffer.append. Sender-thread-only
    /// (the ring is the sole route for audio); drops silently if the link is down.
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
        self.poisoned.store(false, .release); // fresh Utterance — no drop seen yet (#19)
        self.partial_len = 0;
        self.t0_ms = nowMs();
        // This Utterance owns the outbound ring afresh: purge undelivered records of an
        // abandoned predecessor (they only linger when a link outage outlived the
        // worker's insert deadline). If anything was dropped, part of that Utterance may
        // already sit in the server-side input buffer (its audio sent, its commit now
        // purged) — queue a clear ahead of the new audio so stale speech can't be
        // committed into THIS Utterance's transcript (crib sheet: input_audio_buffer.clear).
        var dropped: usize = 0;
        {
            self.out_mu.lockUncancelable(self.io);
            defer self.out_mu.unlock(self.io);
            dropped = self.out_count;
            self.out_head = 0;
            self.out_count = 0;
            self.out_overflow = false;
        }
        if (dropped > 0) {
            feedback.log("  (purged {d} undelivered records of the previous Utterance)\n", .{dropped});
            _ = self.enqueueOut(.control, "{\"type\":\"input_audio_buffer.clear\"}");
        }
        self.active.store(true, .release);
    }

    /// Stop forwarding Capture audio. Call after the queue is stopped, before commit.
    pub fn endUtterance(self: *Session) void {
        self.t_release_ms = nowMs();
        self.active.store(false, .release);
        // The bracketed offset is ms since press, i.e. the hold itself — the anchor the
        // committed/FINAL "+Nms after release" deltas subtract away.
        feedback.log("  [{d:>6}ms] released\n", .{self.t_release_ms - self.t0_ms});
    }

    /// Append one Capture chunk. Called on the AudioQueue thread — which is exactly why
    /// this only memcpys the PCM onto the outbound ring: the base64 + JSON framing and
    /// the blocking TLS write happen on the sender thread, so a network stall can never
    /// starve the queue's 3×50 ms of buffers (capture.zig). While the link is not ready
    /// the records simply accumulate, so a press during a reconnect does not lose the
    /// Utterance (wayfinder #17).
    pub fn appendAudio(self: *Session, pcm: []const u8) void {
        if (pcm.len == 0) return; // a 0-byte buffer (delivered during stop) => empty append, which errors
        if (!self.active.load(.acquire)) return; // not in an Utterance — drop it
        // Capture hands ≤2400 B chunks (capture.zig buffer_bytes == out_payload_cap);
        // slice defensively so a larger future buffer still fits the slots.
        var off: usize = 0;
        while (off < pcm.len) {
            const end = @min(off + out_payload_cap, pcm.len);
            if (!self.enqueueOut(.audio, pcm[off..end])) break; // ring full — truncating (logged once)
            off = end;
        }
        _ = self.bytes_utt.fetchAdd(pcm.len, .monotonic); // count even truncated audio, so commit isn't suppressed
    }

    /// Commit the Utterance (Talk Key release). Suppresses empty commits, which error.
    /// The commit is a ring record like the audio, so it is delivered strictly after
    /// every queued chunk; if the link is down it waits in the ring and replays on
    /// reconnect (the deferred commit of wayfinder #17). Called on the tap's run-loop
    /// thread — enqueue only, no socket write, so the tap callback never blocks on TLS.
    ///
    /// Returns whether a Final Transcript should now be expected: `true` when the commit
    /// was queued (a transcript is coming), `false` when the Utterance held no audio and
    /// was dropped — letting the caller sound the "no Insertion" error cue immediately
    /// instead of waiting out the worker's transcript timeout (#18).
    pub fn commitUtterance(self: *Session) !bool {
        if (self.bytes_utt.load(.acquire) == 0) {
            feedback.log("  (no audio captured — skipping commit)\n", .{});
            return false;
        }
        if (!self.enqueueOut(.control, "{\"type\":\"input_audio_buffer.commit\"}"))
            return error.OutboundRingFull;
        return true;
    }

    /// Session became READY (session.updated). Publish `.ready` — the sender thread then
    /// drains whatever the outbound ring accumulated while the link was down, in order,
    /// deferred commit included (#17's replay, with no special flush path: the single
    /// queue makes chunk-ahead-of-buffered-prefix interleaving impossible by
    /// construction). Runs on the read-loop thread.
    fn markReady(self: *Session) void {
        self.out_mu.lockUncancelable(self.io);
        const backlog = self.out_count;
        self.out_mu.unlock(self.io);
        if (backlog > 0) feedback.log("  session READY — draining {d} buffered records\n", .{backlog});
        self.state.store(.ready, .release);
    }

    // ---- the outbound ring + its sender thread -----------------------------------

    /// Queue one outbound record (a memcpy under `out_mu` — no socket IO; safe on the
    /// AudioQueue and tap threads). False when the ring is full; the once-per-Utterance
    /// truncation log lives here so every producer degrades the same way.
    fn enqueueOut(self: *Session, kind: OutKind, payload: []const u8) bool {
        std.debug.assert(payload.len <= out_payload_cap);
        self.out_mu.lockUncancelable(self.io);
        defer self.out_mu.unlock(self.io);
        if (self.out_count == self.out.len) {
            if (!self.out_overflow) {
                self.out_overflow = true;
                feedback.log("  (outbound ring full — truncating this Utterance)\n", .{});
            }
            return false;
        }
        const slot = &self.out[(self.out_head + self.out_count) % self.out.len];
        slot.kind = kind;
        slot.len = @intCast(payload.len);
        @memcpy(slot.data[0..payload.len], payload);
        self.out_count += 1;
        return true;
    }

    /// Copy the oldest record out of the ring. False when it is empty.
    fn dequeueOut(self: *Session, rec: *OutRecord) bool {
        self.out_mu.lockUncancelable(self.io);
        defer self.out_mu.unlock(self.io);
        if (self.out_count == 0) return false;
        rec.* = self.out[self.out_head];
        self.out_head = (self.out_head + 1) % self.out.len;
        self.out_count -= 1;
        return true;
    }

    /// The sender thread: the only writer of data frames for the session's lifetime.
    /// Drains the ring in order while the session is `.ready`; parks (records
    /// accumulate) while it is connecting/reconnecting; exits on `.closed`. The base64
    /// framing and the blocking TLS write happen here and nowhere else, so no
    /// latency-critical thread ever waits on the network. A write onto a link that died
    /// mid-drain is swallowed exactly like the old live path — the read loop detects the
    /// drop and the Utterance is poisoned as before.
    fn senderLoop(self: *Session) void {
        var rec: OutRecord = undefined;
        while (self.state.load(.acquire) != .closed) {
            if (self.state.load(.acquire) != .ready or !self.dequeueOut(&rec)) {
                sleepMs(sender_tick_ms);
                continue;
            }
            switch (rec.kind) {
                .audio => self.rawAppend(rec.data[0..rec.len]),
                .control => self.sendControl(rec.data[0..rec.len]) catch {},
            }
        }
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

            // Live-apply (wayfinder #32): a session-shaped setting changed — cycle now,
            // while idle; openClient re-reads the snapshot into the session.update.
            if (self.params_dirty.load(.acquire)) {
                feedback.log("  session: transcription settings changed — cycling the session\n", .{});
                self.reconnect();
                continue;
            }

            const now = nowMs();
            if (self.read_ended.load(.acquire)) {
                feedback.log("  session: link dropped (read loop ended) — reconnecting\n", .{});
                self.reconnect();
                continue;
            }
            const exp = self.expires_at_ms.load(.acquire);
            if (exp != 0 and now >= exp - expiry_margin_ms) {
                feedback.log("  session: approaching the 60-min cap — cycling the session\n", .{});
                self.reconnect();
                continue;
            }
            if (self.awaiting_pong and now - self.last_ping_ms >= pong_timeout_ms) {
                if (self.last_pong_ms.load(.acquire) >= self.last_ping_ms) {
                    self.awaiting_pong = false; // pong arrived — healthy
                } else {
                    feedback.log("  session: no pong within {d}ms — reconnecting\n", .{pong_timeout_ms});
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
                feedback.log("  session: ping write failed — link down\n", .{});
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
                feedback.log("  reconnect attempt {d} failed: {s} — retrying in {d}ms\n", .{ attempt, @errorName(e), backoff });
                self.sleepInterruptible(backoff);
                continue;
            };
            if (self.waitReady(ready_wait_ms)) {
                feedback.log("  session: reconnected and READY\n", .{});
                return;
            }
            feedback.log("  reconnect: no session.updated within {d}ms — retrying\n", .{ready_wait_ms});
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
            feedback.log("  session: close drain timed out — forcing the socket down\n", .{});
            self.client.close(.{}) catch {};
        }
        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }
        self.client.deinit();
    }

    /// Graceful shutdown for good: stop the maintenance + sender threads, then close the
    /// link (the sender is joined before closeCurrent so no write can race the teardown).
    pub fn shutdown(self: *Session) void {
        self.active.store(false, .release);
        self.state.store(.closed, .release);
        if (self.maint_thread) |t| {
            t.join();
            self.maint_thread = null;
        }
        if (self.sender_thread) |t| {
            t.join();
            self.sender_thread = null;
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
            feedback.log("  [unparseable event] {s}\n", .{data});
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
            feedback.log("  session.created -> sent session.update\n", .{});
        } else if (std.mem.eql(u8, typ, "session.updated")) {
            s.markReady();
            feedback.log("  session.updated -> READY\n", .{});
        } else if (std.mem.eql(u8, typ, "conversation.item.input_audio_transcription.delta")) {
            const d = getStr(root, "delta") orelse "";
            if (s.partial_len + d.len <= s.partial.len) {
                @memcpy(s.partial[s.partial_len..][0..d.len], d);
                s.partial_len += d.len;
            }
            // Partial Transcript: always logged (#18). The HUD shows no text (#27), so
            // nothing subscribes partials today; the observer hook stays for the future.
            feedback.log("  [{d:>6}ms] partial: {s}\n", .{ nowMs() - s.t0_ms, s.partial[0..s.partial_len] });
            if (s.observer) |o| if (o.on_partial) |f| f(o.ctx, s.partial[0..s.partial_len]);
        } else if (std.mem.eql(u8, typ, "conversation.item.input_audio_transcription.completed")) {
            const t = getStr(root, "transcript") orelse "";
            const n = @min(t.len, s.final.len);
            @memcpy(s.final[0..n], t[0..n]);
            s.final_len = n;
            const now = nowMs();
            feedback.log("  [{d:>6}ms] FINAL (+{d}ms after release): {s}  ({d:.2}s audio)\n", .{ now - s.t0_ms, now - s.t_release_ms, t, usageSeconds(root) });
            // Deliver the Final Transcript to the observer (the Utterance Coordinator, and
            // through it the overlay HUD). This synchronous push IS the delivery — there is
            // no polled got_final flag any more (architecture review 2026-07-08, candidate 1).
            if (s.observer) |o| o.on_final(o.ctx, s.final[0..s.final_len]);
        } else if (std.mem.eql(u8, typ, "conversation.item.input_audio_transcription.failed")) {
            // Operational failure: drop this Utterance, keep the session (crib sheet §).
            // Deliver an EMPTY Final Transcript so the Coordinator resolves the Utterance
            // immediately (error cue, nothing inserted) instead of waiting out the deadline.
            feedback.log("  transcription FAILED: {s}\n", .{errMessage(root)});
            s.final_len = 0; // nothing to insert
            if (s.observer) |o| o.on_final(o.ctx, s.final[0..s.final_len]);
        } else if (std.mem.eql(u8, typ, "error")) {
            feedback.log("  ERROR event: {s}\n", .{errMessage(root)});
        } else if (std.mem.eql(u8, typ, "input_audio_buffer.committed")) {
            const now = nowMs();
            feedback.log("  [{d:>6}ms] committed (+{d}ms after release — awaiting transcript)\n", .{ now - s.t0_ms, now - s.t_release_ms });
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
        feedback.log("  session: server sent a close frame\n", .{});
    }

    /// Read loop ended (drop, server close, or our drain). Flag it for the maintenance
    /// thread, and if this was an unexpected drop while ready, move to `.reconnecting`
    /// so appendAudio starts buffering immediately (the cmpxchg no-ops during a
    /// deliberate reconnect or shutdown).
    pub fn close(self: *Handler) void {
        const s = self.session;
        s.read_ended.store(true, .release);
        // cmpxchg returns null on success (state WAS .ready and we flipped it). If that
        // real ready→reconnecting transition happens with an Utterance in flight, its
        // already-streamed head audio is lost server-side — poison the Utterance so the
        // daemon abandons it cleanly instead of committing a truncated tail (#19). A
        // press that merely landed during a reconnect finds state already non-ready here,
        // so the cmpxchg no-ops and poisoned stays clear (its buffer-and-flush path — #17).
        if (s.state.cmpxchgStrong(.ready, .reconnecting, .monotonic, .monotonic) == null and s.active.load(.acquire))
            s.poisoned.store(true, .release);
        feedback.log("  [read loop ended]\n", .{});
    }
};

// ---- tests (backfilled with the coordinator work, 2026-07-08) ----------------

test "formatSessionUpdate defaults reproduce the #8-proven string" {
    var buf: [2048]u8 = undefined;
    const out = try formatSessionUpdate(&buf, .{});
    try std.testing.expectEqualStrings(
        "{\"type\":\"session.update\",\"session\":{\"type\":\"transcription\",\"audio\":{\"input\":{\"format\":{\"type\":\"audio/pcm\",\"rate\":24000},\"transcription\":{\"model\":\"gpt-realtime-whisper\",\"language\":\"en\",\"delay\":\"low\"},\"turn_detection\":null,\"noise_reduction\":{\"type\":\"near_field\"}}}}}",
        out,
    );
}

test "formatSessionUpdate omits language entirely for auto-detect (empty string)" {
    var buf: [2048]u8 = undefined;
    const out = try formatSessionUpdate(&buf, .{ .language = "" });
    try std.testing.expect(std.mem.indexOf(u8, out, "\"language\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"model\":\"gpt-realtime-whisper\",\"delay\":\"low\"") != null);
}

test "formatSessionUpdate emits JSON null when noise reduction is disabled" {
    var buf: [2048]u8 = undefined;
    const out = try formatSessionUpdate(&buf, .{ .noise_reduction = null });
    try std.testing.expect(std.mem.endsWith(u8, out, "\"turn_detection\":null,\"noise_reduction\":null}}}}"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"near_field\"") == null);
}

test "backoffMs ramps 0.5s→8s and caps" {
    try std.testing.expectEqual(@as(i64, 500), Session.backoffMs(0));
    try std.testing.expectEqual(@as(i64, 1000), Session.backoffMs(1));
    try std.testing.expectEqual(@as(i64, 2000), Session.backoffMs(2));
    try std.testing.expectEqual(@as(i64, 4000), Session.backoffMs(3));
    try std.testing.expectEqual(@as(i64, 8000), Session.backoffMs(4));
    try std.testing.expectEqual(@as(i64, 8000), Session.backoffMs(9)); // capped
}
