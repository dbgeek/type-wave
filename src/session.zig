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
//!     proactively before the 60-min `expires_at` cap, and on a detected drop. Utterance
//!     invalidation stays with the Coordinator; the Session reports link drops as events.
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
const backend = @import("transcription_backend.zig");

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
const OutKind = enum(u8) { audio, control, commit };
const OutRecord = struct {
    kind: OutKind,
    utterance_id: backend.UtteranceId,
    identity_registered: bool,
    len: u16,
    data: [out_payload_cap]u8,
};

const identity_capacity = 16;
const item_id_capacity = 128;

const ItemBinding = struct {
    id: backend.UtteranceId = 0,
    item_id: [item_id_capacity]u8 = undefined,
    item_id_len: usize = 0,
};

const PendingIdentity = struct {
    id: backend.UtteranceId,
    cancelled: bool = false,
};

/// Correlates our commit order with OpenAI's item IDs. Kept as a pure value so the
/// late-reply behavior is deterministic under test; Session supplies synchronization.
const IdentityMap = struct {
    pending: [identity_capacity]PendingIdentity = undefined,
    pending_head: usize = 0,
    pending_count: usize = 0,
    bindings: [identity_capacity]ItemBinding = @splat(.{}),

    fn push(self: *IdentityMap, id: backend.UtteranceId) bool {
        if (self.pending_count == identity_capacity) return false;
        const tail = (self.pending_head + self.pending_count) % identity_capacity;
        self.pending[tail] = .{ .id = id };
        self.pending_count += 1;
        return true;
    }

    fn clear(self: *IdentityMap) void {
        self.pending_head = 0;
        self.pending_count = 0;
        self.bindings = @splat(.{});
    }

    fn bindNext(self: *IdentityMap, item_id: []const u8) ?backend.UtteranceId {
        if (self.pending_count == 0 or item_id.len > item_id_capacity) return null;
        const pending = self.pending[self.pending_head];
        self.pending_head = (self.pending_head + 1) % identity_capacity;
        self.pending_count -= 1;
        if (pending.cancelled) return pending.id;
        for (&self.bindings) |*binding| {
            if (binding.id != 0) continue;
            binding.id = pending.id;
            binding.item_id_len = item_id.len;
            @memcpy(binding.item_id[0..item_id.len], item_id);
            return pending.id;
        }
        return null;
    }

    fn cancel(self: *IdentityMap, id: backend.UtteranceId) void {
        var offset: usize = 0;
        while (offset < self.pending_count) : (offset += 1) {
            const index = (self.pending_head + offset) % identity_capacity;
            if (self.pending[index].id == id) self.pending[index].cancelled = true;
        }
        for (&self.bindings) |*binding| {
            if (binding.id != id) continue;
            binding.id = 0;
            binding.item_id_len = 0;
        }
    }

    fn take(self: *IdentityMap, item_id: []const u8) ?backend.UtteranceId {
        for (&self.bindings) |*binding| {
            if (binding.id == 0) continue;
            if (!std.mem.eql(u8, binding.item_id[0..binding.item_id_len], item_id)) continue;
            const id = binding.id;
            binding.id = 0;
            binding.item_id_len = 0;
            return id;
        }
        return null;
    }
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
    on_final: *const fn (ctx: ?*anyopaque, id: backend.UtteranceId, text: []const u8) void,
    /// The live link dropped before the current Utterance could resolve. The Utterance
    /// Coordinator decides whether this invalidates a Capture in progress, abandons an
    /// awaiting Final Transcript, or is irrelevant to the current phase.
    on_drop: ?*const fn (ctx: ?*anyopaque, id: backend.UtteranceId) void = null,
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

// ---- the maintenance decider: pure per-tick keepalive + reconnect policy ------------

/// Why the maintenance loop cycles the link — carried on the decision so the operator log
/// stays specific after the policy moved behind the seam. A `.reconnect` with no reason
/// resumes a drop the read loop already logged (the `.reconnecting`-state case), so no
/// second line prints.
const ReconnectReason = enum { params_changed, link_dropped, approaching_cap, no_pong };

/// One coherent snapshot the maintenance thread gathers per tick.
const MaintenanceFacts = struct {
    state: State,
    streaming: bool,
    now: i64,
    expires_at_ms: i64,
    awaiting_pong: bool,
    last_ping_ms: i64,
    last_pong_ms: i64,
    read_ended: bool,
    params_dirty: bool,
};

const MaintenanceAction = union(enum) {
    idle,
    ping,
    reconnect: ?ReconnectReason,
};

const MaintenanceDecision = struct {
    action: MaintenanceAction,
    /// The `awaiting_pong` probe flag after this tick (a healthy pong clears it).
    awaiting_pong: bool,
};

fn reconnectMessage(reason: ReconnectReason) []const u8 {
    return switch (reason) {
        .params_changed => "session: transcription settings changed — cycling the session",
        .link_dropped => "session: link dropped (read loop ended) — reconnecting",
        .approaching_cap => "session: approaching the 60-min cap — cycling the session",
        .no_pong => "session: no pong within the timeout — reconnecting",
    };
}

/// The maintenance loop's per-tick decision: keepalive cadence, drop/expiry/params-change
/// detection, and the idle-only reconnect gate — pure, fed a `MaintenanceFacts` snapshot
/// (the Supervisor / `Router.tick` shape). The loop gathers the facts and runs the effect;
/// all the policy lives here, exercised by fed values rather than a live link.
fn maintenanceDecision(f: MaintenanceFacts) MaintenanceDecision {
    switch (f.state) {
        .closed, .connecting => return .{ .action = .idle, .awaiting_pong = f.awaiting_pong },
        .reconnecting => return .{
            // A drop was flagged (possibly mid-Utterance); cycle once idle, without a second
            // log line (the drop was logged where it was detected).
            .action = if (!f.streaming) .{ .reconnect = null } else .idle,
            .awaiting_pong = f.awaiting_pong,
        },
        .ready => {},
    }
    if (f.streaming) return .{ .action = .idle, .awaiting_pong = f.awaiting_pong }; // never disturb a live Capture
    if (f.params_dirty) return .{ .action = .{ .reconnect = .params_changed }, .awaiting_pong = f.awaiting_pong };
    if (f.read_ended) return .{ .action = .{ .reconnect = .link_dropped }, .awaiting_pong = f.awaiting_pong };
    if (f.expires_at_ms != 0 and f.now >= f.expires_at_ms - expiry_margin_ms)
        return .{ .action = .{ .reconnect = .approaching_cap }, .awaiting_pong = f.awaiting_pong };
    var awaiting = f.awaiting_pong;
    if (f.awaiting_pong and f.now - f.last_ping_ms >= pong_timeout_ms) {
        if (f.last_pong_ms >= f.last_ping_ms) {
            awaiting = false; // pong arrived — healthy
        } else {
            return .{ .action = .{ .reconnect = .no_pong }, .awaiting_pong = awaiting };
        }
    }
    if (f.now - f.last_ping_ms >= ping_interval_ms) return .{ .action = .ping, .awaiting_pong = awaiting };
    return .{ .action = .idle, .awaiting_pong = awaiting };
}

/// The Transport seam (mirrors local_backend's Helper seam, #154): everything the Session
/// does to the wire, behind one contract, so the read/write data path and the three
/// lifecycle FSMs are exercised against a `FakeTransport` rather than a live socket. The
/// production adapter is `WebsocketTransport`; `Session(comptime Transport)` is generic over
/// it. Method signatures stay enforced at the Session's own call sites; this asserts the
/// methods exist by name so a missing one fails here — with the name — not deep inside
/// `Session` instantiation.
pub fn assertTransport(comptime Transport: type) void {
    const required = [_][]const u8{
        "init",      "connect",         "startReadLoop", "write",  "writePing",
        "writePong", "writeCloseFrame", "forceClose",    "deinit",
    };
    inline for (required) |name| {
        if (!@hasDecl(Transport, name))
            @compileError("type '" ++ @typeName(Transport) ++ "' is not a Transport: missing method '" ++ name ++ "'");
    }
    if (!@hasDecl(Transport, "Reader"))
        @compileError("type '" ++ @typeName(Transport) ++ "' is not a Transport: missing 'Reader' handle");
}

/// The production Transport: a thin wrapper over the vendored `websocket.Client`. It owns
/// the client and the read-loop thread handle; every method maps 1:1 onto the library call
/// the Session used to make directly. Re-establishable — `connect` re-inits the client after
/// a `deinit`, so the maintenance loop's reconnect cycles it in place.
pub const WebsocketTransport = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    client: websocket.Client = undefined,

    /// The read-loop handle: the OS thread the library spawns. `join` waits it out — called
    /// by `closeCurrent` after the read loop has ended (drain-wait on `read_ended`).
    pub const Reader = struct {
        thread: std.Thread,
        pub fn join(self: Reader) void {
            self.thread.join();
        }
    };

    pub fn init(io: std.Io, alloc: std.mem.Allocator) WebsocketTransport {
        return .{ .io = io, .alloc = alloc };
    }

    /// TCP+TLS connect + HTTP upgrade to the transcription session. A realtime session's
    /// type is fixed at connect (?intent=transcription); params are set via session.update
    /// on session.created. On any failure the client is deinited and the error propagates.
    pub fn connect(self: *WebsocketTransport, api_key: []const u8) !void {
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
        const headers = try std.fmt.bufPrint(&hdr_buf, "Host: {s}\r\nAuthorization: Bearer {s}", .{ host, api_key });
        try self.client.handshake("/v1/realtime?intent=transcription", .{ .timeout_ms = 10_000, .headers = headers });
    }

    pub fn startReadLoop(self: *WebsocketTransport, handler: anytype) !Reader {
        return .{ .thread = try self.client.readLoopInNewThread(handler) };
    }

    // The data-write methods take `[]u8` because the library masks each frame in place
    // (a websocket client MUST mask); every Session write buffer is a mutable local.
    pub fn write(self: *WebsocketTransport, bytes: []u8) !void {
        try self.client.write(bytes);
    }
    pub fn writePing(self: *WebsocketTransport, bytes: []u8) !void {
        try self.client.writePing(bytes);
    }
    pub fn writePong(self: *WebsocketTransport, bytes: []u8) !void {
        try self.client.writePong(bytes);
    }
    pub fn writeCloseFrame(self: *WebsocketTransport, bytes: []u8) !void {
        try self.client.writeFrame(websocket.OpCode.close, bytes);
    }
    /// Force the socket down to unblock a half-open read (readLoop requires a blocking read,
    /// so this is the only way to wake it). The one path that carries the library's teardown
    /// race, and only on a dead link where the raced-over bytes are meaningless.
    pub fn forceClose(self: *WebsocketTransport) void {
        self.client.close(.{}) catch {};
    }
    pub fn deinit(self: *WebsocketTransport) void {
        self.client.deinit();
    }
};

pub fn Session(comptime Transport: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        alloc: std.mem.Allocator,
        transport: Transport,

        /// Retained so the maintenance thread can rebuild the connection on reconnect. The
        /// key borrows a process-lifetime allocation (wayfinder #16); the provider re-reads
        /// the current Settings snapshot at every connect (wayfinder #32).
        api_key: []const u8,
        params_provider: ParamsProvider,
        params_mu: std.Io.Mutex = .init,
        configured_language: backend.Language = "en",

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

        /// True while the Capture stream is open. This is transport-internal gating: it keeps
        /// reconnects between streams and drops stray AudioQueue buffers outside a captured
        /// span. Utterance invalidation lives in the Coordinator, fed by `observer.on_drop`.
        streaming: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        active_id: std.atomic.Value(backend.UtteranceId) = std.atomic.Value(backend.UtteranceId).init(0),

        identity_mu: std.Io.Mutex = .init,
        identities: IdentityMap = .{},

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
        /// in-flight Capture stream always completes on the old params.
        params_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        /// Utterance start, for relative event timestamps. Set by prepareUtterance.
        t0_ms: i64 = 0,

        /// Talk Key release, anchoring the post-release timing splits (release→committed→
        /// FINAL — the speak→insert latency hunt, issues #36–#38). Set by finishAudio;
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
        read: ?Transport.Reader = null,
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

        pub fn connect(io: std.Io, alloc: std.mem.Allocator, api_key: []const u8, params_provider: ParamsProvider, observer: ?TranscriptObserver) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);
            const out = try alloc.alloc(OutRecord, out_slot_count);
            errdefer alloc.free(out);

            self.* = .{
                .io = io,
                .alloc = alloc,
                .transport = Transport.init(io, alloc), // openClient connects it
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
        pub fn deinit(self: *Self) void {
            self.alloc.free(self.out);
            self.alloc.destroy(self);
        }

        /// Establish the link through the Transport: connect (TCP+TLS + HTTP upgrade), then start
        /// the read loop. Leaves `state` untouched (the read loop flips it to `.ready` on
        /// session.updated); on any failure the transport is deinited and the error propagates for
        /// the caller (connect / the reconnect loop) to handle.
        fn openClient(self: *Self) !void {
            // Re-read the live Settings snapshot and rebuild the session.update NOW — every
            // connect (first and reconnect alike) speaks the freshest params (wayfinder #32).
            // Clear the dirty flag first: a change landing after the clear is still picked up
            // by this very read (the provider loads the current snapshot), and the stale flag
            // then costs at most one redundant idle cycle later.
            self.params_dirty.store(false, .release);
            const params = self.params_provider.get(self.params_provider.ctx);
            self.su_len = (try formatSessionUpdate(&self.su_buf, params)).len;
            self.params_mu.lockUncancelable(self.io);
            self.configured_language = params.language;
            self.params_mu.unlock(self.io);

            try self.transport.connect(self.api_key);
            errdefer self.transport.deinit();

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
            self.read = try self.transport.startReadLoop(&self.handler);
        }

        /// Block until the session is `.ready`, or the timeout elapses, or it is closing.
        /// Returns true only on ready. Used by main after connect and by the reconnect loop.
        pub fn waitReady(self: *Self, timeout_ms: i64) bool {
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

        pub fn isReady(self: *Self) bool {
            return self.state.load(.acquire) == .ready;
        }

        // ---- Backend Router resource contract (isReady/shutdown/stillValid/acquire) ----

        const lease_commands = backend.Commands{
            .begin = leaseBegin,
            .append_audio = leaseAppend,
            .release = leaseRelease,
            .request_cancel = leaseCancel,
            .cancel = leaseCancel,
        };

        fn leaseSelf(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }
        fn leaseBegin(ctx: *anyopaque, id: backend.UtteranceId, language: backend.Language) !void {
            try leaseSelf(ctx).beginUtterance(id, language);
        }
        fn leaseAppend(ctx: *anyopaque, id: backend.UtteranceId, pcm: []const u8) !void {
            try leaseSelf(ctx).appendAudio(id, pcm);
        }
        fn leaseRelease(ctx: *anyopaque, id: backend.UtteranceId) !void {
            try leaseSelf(ctx).releaseUtterance(id);
        }
        fn leaseCancel(ctx: *anyopaque, id: backend.UtteranceId) void {
            leaseSelf(ctx).cancelUtterance(id);
        }

        /// Build the Utterance's Lease. Admission is deliberately NOT gated on `isReady`:
        /// a press during a reconnect buffers on the outbound ring and replays when the
        /// link returns (#17). The Lease pins the language bound at connect (session.update),
        /// not the requested one — a Settings change cycles the session when idle (#32), so
        /// the two converge between Utterances.
        pub fn acquire(self: *Self, id: backend.UtteranceId, requested: backend.Language) ?backend.Lease {
            _ = requested;
            return .{
                .id = id,
                .backend = .openai,
                .language = self.leaseLanguage(),
                .deadline = backend.openai_deadline,
                .ctx = self,
                .commands = &lease_commands,
            };
        }

        /// Nothing swaps underneath a connected session (unlike a Model Installation under
        /// a warm local helper), so a ready session never goes stale.
        pub fn stillValid(self: *Self) bool {
            _ = self;
            return true;
        }

        /// A session-shaped setting changed (wayfinder #32) — request an idle cycle so the
        /// next connect re-reads the snapshot. Safe from any thread; never disturbs an
        /// in-flight Utterance (the maintenance loop's existing idle gate).
        pub fn markParamsDirty(self: *Self) void {
            self.params_dirty.store(true, .release);
        }

        fn notifyLinkDropped(self: *Self) void {
            if (self.observer) |o| if (o.on_drop) |f| f(o.ctx, self.active_id.load(.acquire));
        }

        // ---- writes (all funnel through write_mu + the link_open guard) --------------

        /// Encode+send one Capture chunk as an input_audio_buffer.append. Sender-thread-only
        /// (the ring is the sole route for audio); drops silently if the link is down.
        fn rawAppend(self: *Self, pcm: []const u8) void {
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
            self.transport.write(buf[0..end]) catch {};
        }

        fn sendControl(self: *Self, text: []const u8) !void {
            var buf: [2048]u8 = undefined; // fits the config-built session.update (su_buf)
            std.debug.assert(text.len <= buf.len);
            @memcpy(buf[0..text.len], text);
            self.write_mu.lockUncancelable(self.io);
            defer self.write_mu.unlock(self.io);
            if (!self.link_open) return;
            try self.transport.write(buf[0..text.len]);
        }

        /// Prepare the transport for an accepted Utterance. Call on Talk Key press, before
        /// Capture starts. Lifecycle policy stays in the Coordinator; this method only resets
        /// transcript accumulators and transport queues.
        pub fn leaseLanguage(self: *Self) backend.Language {
            self.params_mu.lockUncancelable(self.io);
            defer self.params_mu.unlock(self.io);
            return self.configured_language;
        }

        pub fn beginUtterance(self: *Self, id: backend.UtteranceId, language: backend.Language) !void {
            if (!std.mem.eql(u8, self.leaseLanguage(), language)) return error.LeaseLanguageMismatch;
            self.active_id.store(id, .release);
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
                _ = self.enqueueOut(.control, 0, "{\"type\":\"input_audio_buffer.clear\"}");
            }
            self.streaming.store(true, .release);
        }

        /// Stop accepting Capture audio. Call after the queue is stopped, before commit.
        fn finishAudio(self: *Self) void {
            self.t_release_ms = nowMs();
            self.streaming.store(false, .release);
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
        pub fn appendAudio(self: *Self, id: backend.UtteranceId, pcm: []const u8) !void {
            if (self.active_id.load(.acquire) != id) return error.MismatchedUtterance;
            if (pcm.len == 0) return; // a 0-byte buffer (delivered during stop) => empty append, which errors
            if (!self.streaming.load(.acquire)) return; // not in a Capture stream — drop it
            // Capture hands ≤2400 B chunks (capture.zig buffer_bytes == out_payload_cap);
            // slice defensively so a larger future buffer still fits the slots.
            var off: usize = 0;
            while (off < pcm.len) {
                const end = @min(off + out_payload_cap, pcm.len);
                if (!self.enqueueOut(.audio, id, pcm[off..end])) return error.OutboundRingFull;
                off = end;
            }
        }

        /// Commit the current audio buffer (Talk Key release). The Coordinator suppresses
        /// commits for captures with no audio; this method only enqueues the transport
        /// control record. The commit is a ring record like the audio, so it is delivered strictly after
        /// every queued chunk; if the link is down it waits in the ring and replays on
        /// reconnect (the deferred commit of wayfinder #17). Called on the tap's run-loop
        /// thread — enqueue only, no socket write, so the tap callback never blocks on TLS.
        pub fn releaseUtterance(self: *Self, id: backend.UtteranceId) !void {
            if (self.active_id.load(.acquire) != id) return error.MismatchedUtterance;
            self.finishAudio();
            if (!self.enqueueOut(.commit, id, "{\"type\":\"input_audio_buffer.commit\"}")) {
                return error.OutboundRingFull;
            }
        }

        /// Discard queued audio/control records for an Utterance the Coordinator has already
        /// abandoned. If records were waiting for reconnect, enqueue a clear so the next
        /// ready session cannot inherit stale audio before a later Utterance starts.
        fn discardAudio(self: *Self) void {
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
                feedback.log("  (discarded {d} queued transcription records for the abandoned Utterance)\n", .{dropped});
                _ = self.enqueueOut(.control, 0, "{\"type\":\"input_audio_buffer.clear\"}");
            }
        }

        pub fn cancelUtterance(self: *Self, id: backend.UtteranceId) void {
            if (self.active_id.load(.acquire) != id) return;
            self.streaming.store(false, .release);
            self.discardAudio();
            self.cancelIdentity(id);
        }

        fn registerIdentity(self: *Self, id: backend.UtteranceId) bool {
            self.identity_mu.lockUncancelable(self.io);
            defer self.identity_mu.unlock(self.io);
            return self.identities.push(id);
        }

        fn bindNextIdentity(self: *Self, item_id: []const u8) ?backend.UtteranceId {
            self.identity_mu.lockUncancelable(self.io);
            defer self.identity_mu.unlock(self.io);
            return self.identities.bindNext(item_id);
        }

        fn takeIdentity(self: *Self, item_id: []const u8) ?backend.UtteranceId {
            self.identity_mu.lockUncancelable(self.io);
            defer self.identity_mu.unlock(self.io);
            return self.identities.take(item_id);
        }

        fn cancelIdentity(self: *Self, id: backend.UtteranceId) void {
            self.identity_mu.lockUncancelable(self.io);
            defer self.identity_mu.unlock(self.io);
            self.identities.cancel(id);
        }

        /// Session became READY (session.updated). Publish `.ready` — the sender thread then
        /// drains whatever the outbound ring accumulated while the link was down, in order,
        /// deferred commit included (#17's replay, with no special flush path: the single
        /// queue makes chunk-ahead-of-buffered-prefix interleaving impossible by
        /// construction). Runs on the read-loop thread.
        fn markReady(self: *Self) void {
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
        fn enqueueOut(self: *Self, kind: OutKind, utterance_id: backend.UtteranceId, payload: []const u8) bool {
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
            slot.utterance_id = utterance_id;
            slot.identity_registered = false;
            slot.len = @intCast(payload.len);
            @memcpy(slot.data[0..payload.len], payload);
            self.out_count += 1;
            return true;
        }

        /// Copy the oldest record out of the ring. False when it is empty.
        fn dequeueOut(self: *Self, rec: *OutRecord) bool {
            self.out_mu.lockUncancelable(self.io);
            defer self.out_mu.unlock(self.io);
            if (self.out_count == 0) return false;
            rec.* = self.out[self.out_head];
            if (rec.kind == .commit) rec.identity_registered = self.registerIdentity(rec.utterance_id);
            self.out_head = (self.out_head + 1) % self.out.len;
            self.out_count -= 1;
            return true;
        }

        /// The sender thread: the only writer of data frames for the session's lifetime.
        /// Drains the ring in order while the session is `.ready`; parks (records
        /// accumulate) while it is connecting/reconnecting; exits on `.closed`. The base64
        /// framing and the blocking TLS write happen here and nowhere else, so no
        /// latency-critical thread ever waits on the network. A write onto a link that died
        /// mid-drain is swallowed exactly like the old live path; link-drop events tell the
        /// Coordinator whether the current Utterance is still valid.
        fn senderLoop(self: *Self) void {
            while (self.state.load(.acquire) != .closed) {
                if (!self.drainStep()) sleepMs(sender_tick_ms);
            }
        }

        /// One drain iteration, factored out of `senderLoop` so it can be driven
        /// synchronously in a test: transmit the ring's oldest record if the session is
        /// `.ready`, returning whether a record was handled (false ⇒ park). A `.commit`
        /// whose Utterance identity never registered (its `input_audio_buffer.committed`
        /// was purged with the link down) fires `on_drop` instead of writing, so the
        /// Coordinator abandons it rather than binding a stray transcript.
        fn drainStep(self: *Self) bool {
            if (self.state.load(.acquire) != .ready) return false;
            var rec: OutRecord = undefined;
            if (!self.dequeueOut(&rec)) return false;
            switch (rec.kind) {
                .audio => self.rawAppend(rec.data[0..rec.len]),
                .control => self.sendControl(rec.data[0..rec.len]) catch {},
                .commit => {
                    if (!rec.identity_registered) {
                        if (self.observer) |o| if (o.on_drop) |f| f(o.ctx, rec.utterance_id);
                    } else {
                        self.sendControl(rec.data[0..rec.len]) catch {};
                    }
                },
            }
            return true;
        }

        // ---- maintenance: keepalive + drop detection + reconnect --------------------

        /// Gather the impure facts the pure `maintenanceDecision` runs on (one coherent
        /// per-tick snapshot; the ADR-0005 gather/decide split).
        fn maintenanceFacts(self: *Self) MaintenanceFacts {
            return .{
                .state = self.state.load(.acquire),
                .streaming = self.streaming.load(.acquire),
                .now = nowMs(),
                .expires_at_ms = self.expires_at_ms.load(.acquire),
                .awaiting_pong = self.awaiting_pong,
                .last_ping_ms = self.last_ping_ms,
                .last_pong_ms = self.last_pong_ms.load(.acquire),
                .read_ended = self.read_ended.load(.acquire),
                .params_dirty = self.params_dirty.load(.acquire),
            };
        }

        fn maintenanceLoop(self: *Self) void {
            while (self.state.load(.acquire) != .closed) {
                sleepMs(maint_tick_ms);
                if (self.state.load(.acquire) == .closed) return; // prompt shutdown
                const decision = maintenanceDecision(self.maintenanceFacts());
                self.awaiting_pong = decision.awaiting_pong; // a healthy pong clears the probe
                switch (decision.action) {
                    .idle => {},
                    .ping => self.sendPing(),
                    .reconnect => |reason| {
                        if (reason) |r| feedback.log("  {s}\n", .{reconnectMessage(r)});
                        self.reconnect();
                    },
                }
            }
        }

        fn sendPing(self: *Self) void {
            {
                self.write_mu.lockUncancelable(self.io);
                defer self.write_mu.unlock(self.io);
                if (!self.link_open) return;
                var empty: [0]u8 = .{};
                self.transport.writePing(&empty) catch {
                    feedback.log("  session: ping write failed — link down\n", .{});
                    if (self.state.cmpxchgStrong(.ready, .reconnecting, .monotonic, .monotonic) == null)
                        self.notifyLinkDropped();
                    return;
                };
            }
            self.last_ping_ms = nowMs();
            self.awaiting_pong = true;
        }

        /// Cycle the connection. Runs on the maintenance thread only (or, at shutdown, on the
        /// main thread after the maintenance thread has joined) — never concurrently.
        fn reconnect(self: *Self) void {
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

        /// A backoff sleep that returns early if the session is shut down, so `shutdown`'s
        /// join of the maintenance thread never waits a full backoff.
        fn sleepInterruptible(self: *Self, ms: i64) void {
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
        fn closeCurrent(self: *Self) void {
            {
                self.write_mu.lockUncancelable(self.io);
                defer self.write_mu.unlock(self.io);
                if (self.link_open) {
                    self.link_open = false;
                    var empty: [0]u8 = .{};
                    self.transport.writeCloseFrame(&empty) catch {};
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
                self.transport.forceClose();
            }
            if (self.read) |t| {
                t.join();
                self.read = null;
            }
            self.identity_mu.lockUncancelable(self.io);
            self.identities.clear();
            self.identity_mu.unlock(self.io);
            self.transport.deinit();
        }

        /// Graceful shutdown for good: stop the maintenance + sender threads, then close the
        /// link (the sender is joined before closeCurrent so no write can race the teardown).
        pub fn shutdown(self: *Self) void {
            self.streaming.store(false, .release);
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

        /// Websocket read-loop handler. All methods run on the read-loop thread.
        pub const Handler = struct {
            session: *Self,

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
                    const item_id = getStr(root, "item_id") orelse "";
                    const utterance_id = s.takeIdentity(item_id);
                    const t = getStr(root, "transcript") orelse "";
                    const n = @min(t.len, s.final.len);
                    @memcpy(s.final[0..n], t[0..n]);
                    s.final_len = n;
                    const now = nowMs();
                    feedback.log("  [{d:>6}ms] FINAL (+{d}ms after release): {s}  ({d:.2}s audio)\n", .{ now - s.t0_ms, now - s.t_release_ms, t, usageSeconds(root) });
                    // Deliver the Final Transcript to the observer (the Utterance Coordinator, and
                    // through it the overlay HUD). This synchronous push IS the delivery — there is
                    // no polled got_final flag any more (architecture review 2026-07-08, candidate 1).
                    if (utterance_id) |id| {
                        if (s.observer) |o| o.on_final(o.ctx, id, s.final[0..s.final_len]);
                    } else {
                        feedback.log("  FINAL for unknown OpenAI item {s} — ignored\n", .{item_id});
                    }
                } else if (std.mem.eql(u8, typ, "conversation.item.input_audio_transcription.failed")) {
                    const item_id = getStr(root, "item_id") orelse "";
                    const utterance_id = s.takeIdentity(item_id);
                    // Operational failure: drop this Utterance, keep the session (crib sheet §).
                    // Deliver an EMPTY Final Transcript so the Coordinator resolves the Utterance
                    // immediately (error cue, nothing inserted) instead of waiting out the deadline.
                    feedback.log("  transcription FAILED: {s}\n", .{errMessage(root)});
                    s.final_len = 0; // nothing to insert
                    if (utterance_id) |id| if (s.observer) |o| o.on_final(o.ctx, id, s.final[0..s.final_len]);
                } else if (std.mem.eql(u8, typ, "error")) {
                    feedback.log("  ERROR event: {s}\n", .{errMessage(root)});
                } else if (std.mem.eql(u8, typ, "input_audio_buffer.committed")) {
                    const item_id = getStr(root, "item_id") orelse "";
                    const utterance_id = s.bindNextIdentity(item_id);
                    const now = nowMs();
                    feedback.log("  [{d:>6}ms] committed (+{d}ms after release — awaiting transcript)\n", .{ now - s.t0_ms, now - s.t_release_ms });
                    if (utterance_id == null)
                        feedback.log("  OpenAI commit item {s} had no pending Utterance identity\n", .{item_id});
                }
                // else: item.created / item.added / etc. — ignored.
            }

            /// Route pongs through the write mutex like every other write (crib sheet §3.4).
            pub fn serverPing(self: *Handler, data: []u8) !void {
                const s = self.session;
                s.write_mu.lockUncancelable(s.io);
                defer s.write_mu.unlock(s.io);
                if (!s.link_open) return;
                try s.transport.writePong(data);
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
                // cmpxchg returns null on success (state WAS .ready and we flipped it). Only
                // that real ready→reconnecting transition can invalidate an Utterance; a press
                // that merely landed during a reconnect finds state already non-ready here, so
                // the cmpxchg no-ops and its buffer-and-flush path remains intact (#17).
                if (s.state.cmpxchgStrong(.ready, .reconnecting, .monotonic, .monotonic) == null)
                    s.notifyLinkDropped();
                feedback.log("  [read loop ended]\n", .{});
            }
        };
    };
}

/// Exponential reconnect backoff: 0.5s,1s,2s,4s,8s cap. Pure, module-scope so the
/// reconnect loop and its test share one definition.
fn backoffMs(attempt: usize) i64 {
    const shift: u6 = @intCast(@min(attempt, 4)); // 0.5s,1s,2s,4s,8s cap
    return @min(@as(i64, 500) << shift, 8_000);
}

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

// ---- test doubles: the FakeTransport standing in for the vendored websocket ----

/// A Transport that opens no socket and spawns no thread. Writes are recorded for
/// assertion; the read loop is driven by the `deliver*` free functions below, which invoke
/// the Session's Handler synchronously on the test thread — exactly what the real reader
/// thread does, minus the thread. Mirrors local_backend's FakeHelper.
const FakeTransport = struct {
    connected: bool = false,
    reads_started: usize = 0,
    pings: usize = 0,
    pongs: usize = 0,
    close_frames: usize = 0,
    force_closes: usize = 0,
    writes: usize = 0,
    write_buf: [1 << 14]u8 = undefined,
    write_len: usize = 0,

    const Reader = struct {
        pub fn join(_: Reader) void {}
    };

    fn init(_: std.Io, _: std.mem.Allocator) FakeTransport {
        return .{};
    }
    fn connect(self: *FakeTransport, _: []const u8) !void {
        self.connected = true;
    }
    fn startReadLoop(self: *FakeTransport, _: anytype) !Reader {
        self.reads_started += 1;
        return .{};
    }
    fn write(self: *FakeTransport, bytes: []u8) !void {
        self.writes += 1;
        if (self.write_len + bytes.len <= self.write_buf.len) {
            @memcpy(self.write_buf[self.write_len..][0..bytes.len], bytes);
            self.write_len += bytes.len;
        }
    }
    fn writePing(self: *FakeTransport, _: []u8) !void {
        self.pings += 1;
    }
    fn writePong(self: *FakeTransport, _: []u8) !void {
        self.pongs += 1;
    }
    fn writeCloseFrame(self: *FakeTransport, _: []u8) !void {
        self.close_frames += 1;
    }
    fn forceClose(self: *FakeTransport) void {
        self.force_closes += 1;
    }
    fn deinit(self: *FakeTransport) void {
        self.connected = false;
    }

    /// Everything the sender wrote, for substring assertions.
    fn written(self: *const FakeTransport) []const u8 {
        return self.write_buf[0..self.write_len];
    }
};

comptime {
    assertTransport(FakeTransport);
}

/// Records the observer edges the read loop drives (the Utterance Coordinator's seat).
const Recorder = struct {
    finals: usize = 0,
    final_id: backend.UtteranceId = 0,
    final_buf: [256]u8 = undefined,
    final_len: usize = 0,
    drops: usize = 0,
    drop_id: backend.UtteranceId = 0,
    partial_len: usize = 0,

    fn onFinal(ctx: ?*anyopaque, id: backend.UtteranceId, text: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.finals += 1;
        self.final_id = id;
        const n = @min(text.len, self.final_buf.len);
        @memcpy(self.final_buf[0..n], text[0..n]);
        self.final_len = n;
    }
    fn onDrop(ctx: ?*anyopaque, id: backend.UtteranceId) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.drops += 1;
        self.drop_id = id;
    }
    fn onPartial(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.partial_len = text.len;
    }
    fn observer(self: *Recorder) TranscriptObserver {
        return .{ .ctx = self, .on_final = onFinal, .on_drop = onDrop, .on_partial = onPartial };
    }
    fn finalText(self: *const Recorder) []const u8 {
        return self.final_buf[0..self.final_len];
    }
};

/// Push a server event into the read-loop handler the way the real reader thread would —
/// synchronously, on the test thread. `serverMessage` never mutates the bytes.
fn deliverServerMessage(sess: anytype, json: []const u8) void {
    sess.handler.serverMessage(@constCast(json)) catch {};
}

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

test "OpenAI item identities keep late and out-of-order Final Transcripts tagged" {
    var ids = IdentityMap{};
    try std.testing.expect(ids.push(41));
    try std.testing.expect(ids.push(42));
    try std.testing.expectEqual(@as(?backend.UtteranceId, 41), ids.bindNext("item_old"));
    try std.testing.expectEqual(@as(?backend.UtteranceId, 42), ids.bindNext("item_new"));

    // The newer Final Transcript may arrive first; item_id, not arrival time, owns identity.
    try std.testing.expectEqual(@as(?backend.UtteranceId, 42), ids.take("item_new"));
    try std.testing.expectEqual(@as(?backend.UtteranceId, 41), ids.take("item_old"));
    try std.testing.expectEqual(@as(?backend.UtteranceId, null), ids.take("item_old"));
    try std.testing.expectEqual(@as(?backend.UtteranceId, null), ids.take("unknown"));
}

test "connection teardown forgets identities that can no longer reply" {
    var ids = IdentityMap{};
    try std.testing.expect(ids.push(7));
    try std.testing.expectEqual(@as(?backend.UtteranceId, 7), ids.bindNext("item_7"));
    ids.clear();
    try std.testing.expectEqual(@as(?backend.UtteranceId, null), ids.take("item_7"));
    try std.testing.expectEqual(@as(?backend.UtteranceId, null), ids.bindNext("item_8"));
}

test "cancelled pending identity consumes its commit without binding a late Final Transcript" {
    var ids = IdentityMap{};
    try std.testing.expect(ids.push(11));
    try std.testing.expect(ids.push(12));
    ids.cancel(11);

    try std.testing.expectEqual(@as(?backend.UtteranceId, 11), ids.bindNext("item_old"));
    try std.testing.expectEqual(@as(?backend.UtteranceId, 12), ids.bindNext("item_new"));
    try std.testing.expectEqual(@as(?backend.UtteranceId, null), ids.take("item_old"));
    try std.testing.expectEqual(@as(?backend.UtteranceId, 12), ids.take("item_new"));
}

test "cancelled bound identity frees its slot and rejects a late Final Transcript" {
    var ids = IdentityMap{};
    try std.testing.expect(ids.push(21));
    try std.testing.expectEqual(@as(?backend.UtteranceId, 21), ids.bindNext("item_old"));
    ids.cancel(21);
    try std.testing.expectEqual(@as(?backend.UtteranceId, null), ids.take("item_old"));

    try std.testing.expect(ids.push(22));
    try std.testing.expectEqual(@as(?backend.UtteranceId, 22), ids.bindNext("item_new"));
    try std.testing.expectEqual(@as(?backend.UtteranceId, 22), ids.take("item_new"));
}

test "formatSessionUpdate emits JSON null when noise reduction is disabled" {
    var buf: [2048]u8 = undefined;
    const out = try formatSessionUpdate(&buf, .{ .noise_reduction = null });
    try std.testing.expect(std.mem.endsWith(u8, out, "\"turn_detection\":null,\"noise_reduction\":null}}}}"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"near_field\"") == null);
}

test "the Session's lease surface pins the connect-time language and forwards identity-tagged commands" {
    var out_buf: [8]OutRecord = undefined;
    var sess = Session(FakeTransport){
        .io = std.testing.io,
        .alloc = std.testing.allocator,
        .transport = .{}, // never connected: no link is opened, so every write no-ops on link_open
        .api_key = "",
        .params_provider = .{ .ctx = null, .get = undefined },
        .out = &out_buf,
    };
    sess.configured_language = "sv";

    try std.testing.expect(sess.stillValid());
    const lease = sess.acquire(73, "en").?; // the requested language loses to the bound one
    try std.testing.expectEqual(backend.Backend.openai, lease.backend);
    try std.testing.expectEqualStrings("sv", lease.language);
    try std.testing.expectEqual(backend.openai_deadline.final_ms, lease.deadline.final_ms);

    try lease.begin();
    try std.testing.expectEqual(@as(backend.UtteranceId, 73), sess.active_id.load(.acquire));
    var pcm = [_]u8{ 1, 2, 3 };
    try lease.appendAudio(&pcm);
    try lease.release();
    try std.testing.expectEqual(@as(usize, 2), sess.out_count); // the audio + its deferred commit
    try std.testing.expectEqual(OutKind.audio, sess.out[0].kind);
    try std.testing.expectEqual(OutKind.commit, sess.out[1].kind);

    lease.cancel(); // discards the queued records; a clear guards the next ready link
    try std.testing.expectEqual(@as(usize, 1), sess.out_count);
    try std.testing.expectEqual(OutKind.control, sess.out[sess.out_head].kind);
}

test "backoffMs ramps 0.5s→8s and caps" {
    try std.testing.expectEqual(@as(i64, 500), backoffMs(0));
    try std.testing.expectEqual(@as(i64, 1000), backoffMs(1));
    try std.testing.expectEqual(@as(i64, 2000), backoffMs(2));
    try std.testing.expectEqual(@as(i64, 4000), backoffMs(3));
    try std.testing.expectEqual(@as(i64, 8000), backoffMs(4));
    try std.testing.expectEqual(@as(i64, 8000), backoffMs(9)); // capped
}

// ---- the Transport seam: the read loop and the sender drain, driven off a FakeTransport ----

/// Construct a Session backed by the FakeTransport in place (its Handler must point back at
/// the same stable address, so tests build it via a pointer rather than by value).
fn initFake(sess: *Session(FakeTransport), out_buf: []OutRecord, rec: *Recorder) void {
    sess.* = .{
        .io = std.testing.io,
        .alloc = std.testing.allocator,
        .transport = .{},
        .api_key = "",
        .params_provider = .{ .ctx = null, .get = undefined },
        .out = out_buf,
        .observer = rec.observer(),
    };
    sess.handler = .{ .session = sess };
}

test "session.created replays the configured session.update through the transport" {
    var out_buf: [8]OutRecord = undefined;
    var rec = Recorder{};
    var sess: Session(FakeTransport) = undefined;
    initFake(&sess, &out_buf, &rec);
    sess.link_open = true; // the read loop only writes when the link is up
    sess.su_len = (try formatSessionUpdate(&sess.su_buf, .{})).len;

    deliverServerMessage(&sess, "{\"type\":\"session.created\",\"session\":{\"expires_at\":0}}");

    try std.testing.expect(std.mem.indexOf(u8, sess.transport.written(), "\"type\":\"session.update\"") != null);
}

test "the read loop tags a completed transcript to its Utterance by OpenAI item id" {
    var out_buf: [8]OutRecord = undefined;
    var rec = Recorder{};
    var sess: Session(FakeTransport) = undefined;
    initFake(&sess, &out_buf, &rec);

    // A pending identity (as the sender registers on commit), bound to OpenAI's item id by
    // the committed event, then resolved by the completed event — late/out-of-order safe.
    try std.testing.expect(sess.identities.push(73));
    deliverServerMessage(&sess, "{\"type\":\"input_audio_buffer.committed\",\"item_id\":\"itm_1\"}");
    deliverServerMessage(&sess, "{\"type\":\"conversation.item.input_audio_transcription.delta\",\"delta\":\"hel\"}");
    deliverServerMessage(&sess, "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"itm_1\",\"transcript\":\"hello\"}");

    try std.testing.expectEqual(@as(usize, 1), rec.finals);
    try std.testing.expectEqual(@as(backend.UtteranceId, 73), rec.final_id);
    try std.testing.expectEqualStrings("hello", rec.finalText());
    try std.testing.expectEqual(@as(usize, 3), rec.partial_len); // the "hel" delta accumulated
}

test "a failed transcription resolves the Utterance with an empty Final Transcript" {
    var out_buf: [8]OutRecord = undefined;
    var rec = Recorder{};
    var sess: Session(FakeTransport) = undefined;
    initFake(&sess, &out_buf, &rec);

    try std.testing.expect(sess.identities.push(42));
    deliverServerMessage(&sess, "{\"type\":\"input_audio_buffer.committed\",\"item_id\":\"itm_2\"}");
    deliverServerMessage(&sess, "{\"type\":\"conversation.item.input_audio_transcription.failed\",\"item_id\":\"itm_2\",\"error\":{\"message\":\"boom\"}}");

    // The current convention (ADR follow-up, not changed here): failure ⇒ empty Final so the
    // Coordinator resolves immediately (error cue, nothing inserted) instead of timing out.
    try std.testing.expectEqual(@as(usize, 1), rec.finals);
    try std.testing.expectEqual(@as(backend.UtteranceId, 42), rec.final_id);
    try std.testing.expectEqual(@as(usize, 0), rec.final_len);
}

test "an unknown OpenAI item id delivers no Final Transcript" {
    var out_buf: [8]OutRecord = undefined;
    var rec = Recorder{};
    var sess: Session(FakeTransport) = undefined;
    initFake(&sess, &out_buf, &rec);

    deliverServerMessage(&sess, "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"ghost\",\"transcript\":\"x\"}");

    try std.testing.expectEqual(@as(usize, 0), rec.finals);
}

test "the sender drains a Capture append and its commit to the transport when ready" {
    var out_buf: [8]OutRecord = undefined;
    var rec = Recorder{};
    var sess: Session(FakeTransport) = undefined;
    initFake(&sess, &out_buf, &rec);
    sess.link_open = true;
    sess.state.store(.ready, .release);

    const lease = sess.acquire(90, "en").?;
    try lease.begin();
    var pcm = [_]u8{ 1, 2, 3, 4 };
    try lease.appendAudio(&pcm);
    try lease.release();

    try std.testing.expect(sess.drainStep()); // the audio append
    try std.testing.expect(sess.drainStep()); // its deferred commit
    try std.testing.expect(!sess.drainStep()); // ring empty ⇒ park

    try std.testing.expect(std.mem.indexOf(u8, sess.transport.written(), "input_audio_buffer.append") != null);
    try std.testing.expect(std.mem.indexOf(u8, sess.transport.written(), "input_audio_buffer.commit") != null);
    try std.testing.expectEqual(@as(usize, 0), rec.drops);
}

test "the sender drops a commit whose Utterance identity cannot register" {
    var out_buf: [8]OutRecord = undefined;
    var rec = Recorder{};
    var sess: Session(FakeTransport) = undefined;
    initFake(&sess, &out_buf, &rec);
    sess.link_open = true;
    sess.state.store(.ready, .release);

    // Saturate the pending-identity map so the commit's registration fails on drain.
    var k: backend.UtteranceId = 0;
    while (k < identity_capacity) : (k += 1) try std.testing.expect(sess.identities.push(1000 + k));

    const lease = sess.acquire(90, "en").?;
    try lease.begin();
    try lease.release();

    try std.testing.expect(sess.drainStep()); // commit → identity full → on_drop, no write
    try std.testing.expectEqual(@as(usize, 1), rec.drops);
    try std.testing.expectEqual(@as(backend.UtteranceId, 90), rec.drop_id);
    try std.testing.expect(std.mem.indexOf(u8, sess.transport.written(), "commit") == null);
}

// ---- the maintenance decider: pure, fed a Facts snapshot ----

/// A ready, idle, healthy session: recently pinged, pong current, far from the cap.
fn healthyReady() MaintenanceFacts {
    return .{
        .state = .ready,
        .streaming = false,
        .now = 100_000,
        .expires_at_ms = 0, // no deadline known yet ⇒ never triggers the cap branch
        .awaiting_pong = false,
        .last_ping_ms = 100_000,
        .last_pong_ms = 100_000,
        .read_ended = false,
        .params_dirty = false,
    };
}

test "maintenance stays idle while connecting, and while a Capture stream is live" {
    var f = healthyReady();
    f.state = .connecting;
    try std.testing.expectEqual(MaintenanceAction.idle, maintenanceDecision(f).action);

    f = healthyReady();
    f.streaming = true;
    try std.testing.expectEqual(MaintenanceAction.idle, maintenanceDecision(f).action);
}

test "maintenance resumes a flagged reconnect only once the Capture stream is idle" {
    var f = healthyReady();
    f.state = .reconnecting;
    f.streaming = true;
    try std.testing.expectEqual(MaintenanceAction.idle, maintenanceDecision(f).action); // never mid-Utterance

    f.streaming = false;
    const d = maintenanceDecision(f);
    try std.testing.expect(d.action == .reconnect);
    try std.testing.expectEqual(@as(?ReconnectReason, null), d.action.reconnect); // no second log line
}

test "maintenance reconnects a ready idle session on params change, drop, cap, and missing pong" {
    var f = healthyReady();
    f.params_dirty = true;
    try std.testing.expectEqual(@as(?ReconnectReason, .params_changed), maintenanceDecision(f).action.reconnect);

    f = healthyReady();
    f.read_ended = true;
    try std.testing.expectEqual(@as(?ReconnectReason, .link_dropped), maintenanceDecision(f).action.reconnect);

    f = healthyReady();
    f.expires_at_ms = f.now + expiry_margin_ms - 1; // inside the reconnect margin
    try std.testing.expectEqual(@as(?ReconnectReason, .approaching_cap), maintenanceDecision(f).action.reconnect);

    f = healthyReady();
    f.awaiting_pong = true;
    f.last_ping_ms = f.now - pong_timeout_ms; // waited out the pong window…
    f.last_pong_ms = f.now - pong_timeout_ms - 1; // …and the last pong predates the ping
    try std.testing.expectEqual(@as(?ReconnectReason, .no_pong), maintenanceDecision(f).action.reconnect);
}

test "maintenance clears the probe when a healthy pong arrived, and pings on cadence" {
    var f = healthyReady();
    f.awaiting_pong = true;
    f.last_ping_ms = f.now - pong_timeout_ms; // window elapsed
    f.last_pong_ms = f.now; // but the pong is current ⇒ healthy
    const healthy = maintenanceDecision(f);
    try std.testing.expectEqual(MaintenanceAction.idle, healthy.action);
    try std.testing.expectEqual(false, healthy.awaiting_pong); // probe cleared

    f = healthyReady();
    f.last_ping_ms = f.now - ping_interval_ms; // due for the next keepalive
    try std.testing.expectEqual(MaintenanceAction.ping, maintenanceDecision(f).action);
}
