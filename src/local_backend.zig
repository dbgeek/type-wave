//! Segmenting adapter for the local Whisper Transcription Backend: a short Utterance is one
//! Segment submitted on release; a long one is cut at silences into background Segments and
//! assembled into one Final Transcript on release (ADR-0003).

const std = @import("std");
const backend = @import("transcription_backend.zig");
const ipc = @import("whisper_ipc.zig");
const helper_core = @import("whisper_helper_core.zig");
const helper_supervisor = @import("whisper_supervisor.zig");
const coordinator = @import("coordinator.zig");
const model_store = @import("model_store.zig");
const segmentation = @import("segmenter.zig");

extern "c" fn usleep(usec: c_uint) c_int;

/// Release-anchored (ADR-0003). It no longer bounds a single transcription but the whole
/// post-release **drain** — the trailing Segment plus any still-queued Segments — so it is
/// raised from the old 10 s single-inference budget to ~15 s. Cooperative cancel fires a
/// little before the hard deadline; an overrun fails the whole Utterance loudly.
pub const local_deadline = backend.DeadlinePolicy{ .cooperative_cancel_ms = 13_500, .final_ms = 15_000 };
pub const ModelArtifact = helper_core.Artifact;

pub const Events = struct {
    ctx: *anyopaque,
    final: *const fn (*anyopaque, backend.UtteranceId, []const u8) void,
    failed: *const fn (*anyopaque, backend.UtteranceId) void,
};

const HelperEvents = Events;

/// The silence-cut policy and its accumulation state live in the pure Segmenter (ADR-0003);
/// re-exported here so callers and tests that reach for `local_backend.SegmentPolicy` still do.
pub const SegmentPolicy = segmentation.SegmentPolicy;

/// One cut-but-not-yet-submitted Segment: its spoken-order index and owned Capture bytes.
const Segment = struct { index: u16, pcm: []u8 };

/// Segments are keyed to the helper with an id derived from the Utterance id (ADR-0003):
/// the Utterance in the high bits, the spoken-order index in the low 16. The helper and its
/// supervisor stay single-slot and identity-checked; the derived id lets a stale Segment
/// final from a resolved Utterance be recognised and dropped.
const segment_index_bits = 16;
fn segmentId(utterance: backend.UtteranceId, index: u16) backend.UtteranceId {
    return (utterance << segment_index_bits) | index;
}
fn utteranceOf(seg_id: backend.UtteranceId) backend.UtteranceId {
    return seg_id >> segment_index_bits;
}
fn segmentIndex(seg_id: backend.UtteranceId) usize {
    return @truncate(seg_id & ((1 << segment_index_bits) - 1));
}

/// RMS (0..1 of full scale) of one Capture buffer — the silence signal, computed the same
/// way capture.zig computes it for the HUD level sink, here off the bytes the Adapter is
/// already handed so segmentation needs no second data channel.
fn bufferRms(pcm: []const u8) f32 {
    const even = pcm[0 .. pcm.len - (pcm.len & 1)];
    const samples = std.mem.bytesAsSlice(i16, even);
    if (samples.len == 0) return 0;
    var acc: f64 = 0;
    for (samples) |s| {
        const x = @as(f64, @floatFromInt(s)) / 32768.0;
        acc += x * x;
    }
    return @floatCast(@sqrt(acc / @as(f64, @floatFromInt(samples.len))));
}

/// The `Helper` contract the segmenting Adapter drives: the warm local Whisper Helper process
/// — `whisper_process_helper.ProcessHelper` in production, `FakeHelper` in the Adapter tests.
/// The Adapter is `comptime Helper`-generic; this is the one written record of what a Helper
/// must provide, and it lives with the Adapter that requires it:
///
///   isReady(*Helper) bool
///   usesModel(*Helper, []const u8) bool
///   setEvents(*Helper, Events) void
///   reserveUtterance(*Helper, backend.UtteranceId) !void
///   submit(*Helper, backend.UtteranceId, ipc.Language, []const u8) !void
///   requestCancel(*Helper, backend.UtteranceId) void
///   cancel(*Helper, backend.UtteranceId) void
///   shutdown(*Helper) void
///   retry(*Helper) void
///
/// Method signatures stay enforced at the Adapter's own comptime call sites; this asserts the
/// methods exist by name so a missing one fails here — with the name — instead of cryptically
/// deep inside `Adapter` instantiation.
pub fn assertHelper(comptime Helper: type) void {
    const required = [_][]const u8{
        "isReady",       "usesModel", "setEvents", "reserveUtterance", "submit",
        "requestCancel", "cancel",    "shutdown",  "retry",
    };
    inline for (required) |name| {
        if (!@hasDecl(Helper, name))
            @compileError("type '" ++ @typeName(Helper) ++ "' is not a Helper: missing method '" ++ name ++ "'");
    }
}

pub fn Adapter(comptime Helper: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        helper: *Helper,
        events: Events,
        mu: std.Io.Mutex = .init,
        active_id: ?backend.UtteranceId = null,
        language: ipc.Language = .english,
        released: bool = false,
        /// Set once any Segment of this Utterance fails — realizes all-or-nothing: no
        /// further Segment is submitted and the Utterance is discarded whole.
        failed: bool = false,

        // ---- segmentation state (all guarded by `mu`) ----------------------------
        /// The silence-cut policy and the Segment being accumulated from Capture. Pure: the
        /// Adapter feeds it Capture (with the per-buffer RMS) and enqueues the Segments it cuts.
        segmenter: segmentation.Segmenter = .{},
        /// Cut-but-not-yet-submitted Segments, FIFO in spoken order (stays shallow: inference
        /// outpaces speech). Each `.pcm` is owned until submitted (the helper copies it).
        pending: std.ArrayList(Segment) = .empty,
        /// The helper id of the one Segment submitted and awaiting its final; null means the
        /// single slot is idle. Its presence also marks the Segment there is to cancel.
        in_flight_id: ?backend.UtteranceId = null,
        /// The Final Transcript assembled from Segment Transcripts in spoken order.
        assembled: std.ArrayList(u8) = .empty,
        /// Segments cut so far (also the next Segment's spoken-order index) and Segments whose
        /// Segment Transcript has arrived; the drain is complete once they are equal.
        segments_cut: usize = 0,
        segments_done: usize = 0,

        inference_root: [std.fs.max_path_bytes]u8 = undefined,
        inference_root_len: usize = 0,
        inference_lease: ?model_store.InferenceLease = null,
        runtime_lease: ?model_store.RuntimeLease = null,

        const commands = backend.Commands{
            .begin = beginCommand,
            .append_audio = appendCommand,
            .release = releaseCommand,
            .request_cancel = requestCancelCommand,
            .cancel = cancelCommand,
        };

        pub fn init(allocator: std.mem.Allocator, io: std.Io, helper: *Helper, events: Events) Self {
            return .{ .allocator = allocator, .io = io, .helper = helper, .events = events };
        }

        pub fn acquire(self: *Self, id: backend.UtteranceId, language: backend.Language) ?backend.Lease {
            if (!self.isReady()) return null;
            return .{
                .id = id,
                .backend = .local,
                .language = language,
                .deadline = local_deadline,
                .ctx = self,
                .commands = &commands,
            };
        }

        pub fn bindHelperEvents(self: *Self) void {
            self.helper.setEvents(.{ .ctx = self, .final = helperFinal, .failed = helperFailed });
        }

        pub fn setInferenceRoot(self: *Self, root: []const u8, runtime: *model_store.RuntimeLease) !void {
            if (root.len > self.inference_root.len) return error.NameTooLong;
            if (self.runtime_lease != null) return error.InferenceRootAlreadySet;
            self.runtime_lease = runtime.take();
            @memcpy(self.inference_root[0..root.len], root);
            self.inference_root_len = root.len;
        }

        pub fn isReady(self: *Self) bool {
            return self.helper.isReady() and self.usesActiveInstallation();
        }

        /// Backend Router resource contract: a warm helper goes stale once it stops
        /// using the active Model Installation (an update activated underneath it).
        pub fn stillValid(self: *Self) bool {
            return self.usesActiveInstallation();
        }

        pub fn usesActiveInstallation(self: *Self) bool {
            if (self.inference_root_len == 0) return true;
            if (model_store.modelRemovalPending(self.io, self.inference_root[0..self.inference_root_len])) return false;
            if (comptime !@hasDecl(Helper, "usesModel")) return true;
            var active_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const active_path = (model_store.activeModelPath(
                self.io,
                self.inference_root[0..self.inference_root_len],
                &active_path_buffer,
            ) catch return false) orelse return false;
            return self.helper.usesModel(active_path);
        }

        pub fn shutdown(self: *Self) void {
            self.helper.shutdown();
            if (self.runtime_lease) |*lease| lease.release();
            self.runtime_lease = null;
        }

        /// Recovery action exposed for the readiness/Status Item layer.
        pub fn retry(self: *Self) void {
            self.helper.retry();
        }

        pub fn begin(self: *Self, id: backend.UtteranceId, language: backend.Language) !void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.active_id != null) return error.Busy;
            if (!self.isReady()) return error.NotReady;
            var inference_lease: ?model_store.InferenceLease = if (self.inference_root_len > 0)
                try model_store.InferenceLease.acquire(self.io, self.inference_root[0..self.inference_root_len])
            else
                null;
            errdefer if (inference_lease) |*lease| lease.release();
            if (!self.usesActiveInstallation()) return error.NotReady;
            self.language = if (std.mem.eql(u8, language, "en"))
                .english
            else if (std.mem.eql(u8, language, "sv"))
                .swedish
            else if (language.len == 0)
                .auto_detect
            else
                return error.UnsupportedLanguage;
            // The helper is reserved per Segment (at submit), not per Utterance: a long
            // Utterance submits many Segments, one at a time, through the same single slot.
            self.resetUtteranceStateLocked();
            self.inference_lease = inference_lease;
            self.active_id = id;
            self.released = false;
        }

        pub fn appendAudio(self: *Self, id: backend.UtteranceId, pcm: []const u8) !void {
            self.mu.lockUncancelable(self.io);
            if (self.active_id != id or self.released) {
                self.mu.unlock(self.io);
                return error.WrongUtterance;
            }
            if (self.failed) {
                self.mu.unlock(self.io);
                return error.SegmentSubmitFailed;
            }
            // The Segmenter accumulates and decides where a Segment ends (ADR-0003); a returned
            // cut is enqueued and submitted here. Below the soft floor a short Utterance stays whole.
            const cut = self.segmenter.push(self.allocator, bufferRms(pcm), pcm) catch |failure| {
                self.mu.unlock(self.io);
                return failure;
            };
            var submit_failed = false;
            if (cut) |pcm_out| {
                submit_failed = self.enqueueCutLocked(pcm_out) catch |failure| {
                    self.mu.unlock(self.io);
                    return failure;
                };
            }
            self.mu.unlock(self.io);
            if (submit_failed) return error.SegmentSubmitFailed;
        }

        pub fn release(self: *Self, id: backend.UtteranceId) !void {
            self.mu.lockUncancelable(self.io);
            if (self.active_id != id or self.released) {
                self.mu.unlock(self.io);
                return error.WrongUtterance;
            }
            if (self.failed) {
                self.mu.unlock(self.io);
                return error.SegmentSubmitFailed;
            }
            // Flush the trailing partial Segment, then drain: nothing was inserted mid-Utterance.
            const trailing = self.segmenter.flush(self.allocator) catch |failure| {
                self.mu.unlock(self.io);
                return failure;
            };
            var flush_failed = false;
            if (trailing) |pcm_out| {
                flush_failed = self.enqueueCutLocked(pcm_out) catch |failure| {
                    self.mu.unlock(self.io);
                    return failure;
                };
            }
            if (self.segments_cut == 0) {
                self.mu.unlock(self.io);
                return error.EmptyCapture;
            }
            self.released = true;
            const submit_failed = flush_failed or self.pumpLocked();
            const drained = !submit_failed and self.drainCompleteLocked();
            self.mu.unlock(self.io);
            if (submit_failed) return error.SegmentSubmitFailed;
            // Every Segment already finished before release could arm the drain — rare, since
            // stopping Capture flushes a non-empty trailing Segment. Emit off a detached thread
            // so we never re-enter the Coordinator that is still inside this release call.
            if (drained) self.spawnDrainedFinal(id);
        }

        pub fn cancel(self: *Self, id: backend.UtteranceId) void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.active_id != id) return;
            if (self.in_flight_id) |seg_id| self.helper.cancel(seg_id);
            self.resetUtteranceStateLocked();
            self.releaseInferenceLease();
            self.active_id = null;
            self.released = false;
        }

        pub fn requestCancel(self: *Self, id: backend.UtteranceId) void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.active_id == id) {
                if (self.in_flight_id) |seg_id| self.helper.requestCancel(seg_id);
            }
        }

        /// A Segment Transcript arrived. Concatenate it in spoken order; when the drain has
        /// completed after release, emit the one Final Transcript; otherwise pump the next.
        pub fn receiveFinal(self: *Self, seg_id: backend.UtteranceId, text: []const u8) void {
            self.mu.lockUncancelable(self.io);
            if (self.active_id == null or utteranceOf(seg_id) != self.active_id.? or self.in_flight_id != seg_id) {
                self.mu.unlock(self.io);
                return;
            }
            const id = self.active_id.?;
            self.in_flight_id = null;
            // Reassembly order rests on the single-slot invariant: this Segment's final must be
            // the next one in spoken order. A dev tripwire — the `in_flight_id` guard above
            // already prevents misattribution in release builds, where this compiles out.
            std.debug.assert(segmentIndex(seg_id) == self.segments_done);
            self.segments_done += 1;
            self.appendAssembledLocked(text) catch {
                self.failed = true;
                self.mu.unlock(self.io);
                self.events.failed(self.events.ctx, id);
                self.clearAfterTerminal(id);
                return;
            };
            if (self.released and self.drainCompleteLocked()) {
                self.emitFinalAndClearLocked(id); // unlocks, emits, clears
                return;
            }
            const submit_failed = self.pumpLocked();
            self.mu.unlock(self.io);
            if (submit_failed) {
                self.events.failed(self.events.ctx, id);
                self.clearAfterTerminal(id);
            }
        }

        /// Any Segment failing discards the whole Utterance (all-or-nothing, ADR-0003).
        pub fn receiveFailed(self: *Self, seg_id: backend.UtteranceId) void {
            self.mu.lockUncancelable(self.io);
            if (self.active_id == null or utteranceOf(seg_id) != self.active_id.? or self.failed) {
                self.mu.unlock(self.io);
                return;
            }
            const id = self.active_id.?;
            self.failed = true;
            self.in_flight_id = null;
            self.mu.unlock(self.io);
            self.events.failed(self.events.ctx, id);
            self.clearAfterTerminal(id);
        }

        /// The post-release drain has finished: no Segment is inflight, none are queued, and
        /// every cut Segment's Segment Transcript has arrived.
        fn drainCompleteLocked(self: *Self) bool {
            return self.in_flight_id == null and self.pending.items.len == 0 and self.segments_done == self.segments_cut;
        }

        /// Enqueue a freshly cut Segment (owned `pcm`) in spoken order and try to submit it.
        /// Returns whether submitting a Segment failed (the caller fails the Utterance).
        fn enqueueCutLocked(self: *Self, pcm: []u8) !bool {
            errdefer self.allocator.free(pcm);
            try self.pending.append(self.allocator, .{ .index = @intCast(self.segments_cut), .pcm = pcm });
            self.segments_cut += 1;
            return self.pumpLocked();
        }

        /// Submit the next queued Segment to the single-slot helper if it is idle. Returns
        /// true when a submit failed — the Utterance is then discarded whole.
        fn pumpLocked(self: *Self) bool {
            if (self.failed or self.in_flight_id != null or self.pending.items.len == 0) return false;
            const seg = self.pending.orderedRemove(0);
            const seg_id = segmentId(self.active_id.?, seg.index);
            self.helper.reserveUtterance(seg_id) catch {
                self.allocator.free(seg.pcm);
                self.failed = true;
                return true;
            };
            self.helper.submit(seg_id, self.language, seg.pcm) catch {
                self.helper.cancel(seg_id); // undo the reservation we just took
                self.allocator.free(seg.pcm);
                self.failed = true;
                return true;
            };
            self.allocator.free(seg.pcm); // the helper copied it synchronously
            self.in_flight_id = seg_id;
            return false;
        }

        /// Concatenate one Segment Transcript into the Final Transcript. The first enters
        /// verbatim (so a single-Segment Utterance is byte-for-byte as before); later ones
        /// join with exactly one space, the seam trimmed from both sides.
        fn appendAssembledLocked(self: *Self, text: []const u8) !void {
            if (self.assembled.items.len == 0) {
                try self.assembled.appendSlice(self.allocator, text);
                return;
            }
            const seg = std.mem.trimStart(u8, text, &std.ascii.whitespace);
            if (seg.len == 0) return; // an empty Segment Transcript adds nothing
            var end = self.assembled.items.len;
            while (end > 0 and std.ascii.isWhitespace(self.assembled.items[end - 1])) end -= 1;
            self.assembled.items.len = end;
            if (self.assembled.items.len != 0) try self.assembled.append(self.allocator, ' ');
            try self.assembled.appendSlice(self.allocator, seg);
        }

        /// Lock held on entry; unlocks it. Takes ownership of the assembled Final Transcript,
        /// emits it once, then clears terminal state.
        fn emitFinalAndClearLocked(self: *Self, id: backend.UtteranceId) void {
            const done = self.assembled.toOwnedSlice(self.allocator) catch {
                self.failed = true;
                self.mu.unlock(self.io);
                self.events.failed(self.events.ctx, id);
                self.clearAfterTerminal(id);
                return;
            };
            self.mu.unlock(self.io);
            self.events.final(self.events.ctx, id, done);
            self.allocator.free(done);
            self.clearAfterTerminal(id);
        }

        fn spawnDrainedFinal(self: *Self, id: backend.UtteranceId) void {
            const thread = std.Thread.spawn(.{}, drainedFinalWorker, .{ self, id }) catch return;
            thread.detach();
        }

        fn drainedFinalWorker(self: *Self, id: backend.UtteranceId) void {
            self.mu.lockUncancelable(self.io);
            if (self.active_id != id or !self.released or self.failed or !self.drainCompleteLocked()) {
                self.mu.unlock(self.io);
                return;
            }
            self.emitFinalAndClearLocked(id);
        }

        fn clearAfterTerminal(self: *Self, id: backend.UtteranceId) void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.active_id != id) return; // Coordinator cancellation already cleared it.
            self.resetUtteranceStateLocked();
            self.releaseInferenceLease();
            self.active_id = null;
            self.released = false;
        }

        fn resetUtteranceStateLocked(self: *Self) void {
            for (self.pending.items) |queued| self.allocator.free(queued.pcm);
            self.pending.clearRetainingCapacity();
            self.segmenter.reset();
            self.assembled.clearRetainingCapacity();
            self.in_flight_id = null;
            self.segments_cut = 0;
            self.segments_done = 0;
            self.failed = false;
        }

        /// Free the Adapter's owned buffers. For tests — the daemon's Adapter lives for the
        /// process lifetime.
        pub fn deinit(self: *Self) void {
            for (self.pending.items) |queued| self.allocator.free(queued.pcm);
            self.pending.deinit(self.allocator);
            self.segmenter.deinit(self.allocator);
            self.assembled.deinit(self.allocator);
        }

        fn releaseInferenceLease(self: *Self) void {
            if (self.inference_lease) |*lease| lease.release();
            self.inference_lease = null;
        }

        fn from(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }
        fn beginCommand(ctx: *anyopaque, id: backend.UtteranceId, language: backend.Language) !void {
            try from(ctx).begin(id, language);
        }
        fn appendCommand(ctx: *anyopaque, id: backend.UtteranceId, pcm: []const u8) !void {
            try from(ctx).appendAudio(id, pcm);
        }
        fn releaseCommand(ctx: *anyopaque, id: backend.UtteranceId) !void {
            try from(ctx).release(id);
        }
        fn requestCancelCommand(ctx: *anyopaque, id: backend.UtteranceId) void {
            from(ctx).requestCancel(id);
        }
        fn cancelCommand(ctx: *anyopaque, id: backend.UtteranceId) void {
            from(ctx).cancel(id);
        }
        fn helperFinal(ctx: *anyopaque, id: backend.UtteranceId, text: []const u8) void {
            from(ctx).receiveFinal(id, text);
        }
        fn helperFailed(ctx: *anyopaque, id: backend.UtteranceId) void {
            from(ctx).receiveFailed(id);
        }
    };
}

/// Models the single-slot helper faithfully enough to drive segmentation: a reservation
/// that rejects a second concurrent Segment, per-Segment submit records, and drivers that
/// deliver a Segment's terminal the way the reader loop does — freeing the slot first, so
/// the Adapter can immediately submit the next queued Segment.
const FakeHelper = struct {
    reserves: usize = 0,
    submits: usize = 0,
    lease_id: ?backend.UtteranceId = null,
    last_id: backend.UtteranceId = 0,
    language: ipc.Language = .english,
    ids: [64]backend.UtteranceId = undefined,
    lens: [64]usize = undefined,
    pcm: [4096]u8 = undefined,
    pcm_len: usize = 0,
    cancellation_requests: usize = 0,
    last_request_id: backend.UtteranceId = 0,
    cancels: usize = 0,
    last_cancel_id: backend.UtteranceId = 0,
    retries: usize = 0,
    reserve_error: bool = false,
    submit_error: bool = false,

    fn isReady(_: *FakeHelper) bool {
        return true;
    }
    fn setEvents(_: *FakeHelper, _: HelperEvents) void {}
    fn reserveUtterance(self: *FakeHelper, id: backend.UtteranceId) !void {
        if (self.reserve_error) return error.NotReady;
        if (self.lease_id != null) return error.Busy;
        self.lease_id = id;
        self.reserves += 1;
    }

    fn submit(self: *FakeHelper, id: backend.UtteranceId, language: ipc.Language, pcm: []const u8) !void {
        if (self.submit_error) return error.BrokenPipe;
        if (self.lease_id != id) return error.WrongUtterance;
        self.ids[self.submits] = id;
        self.lens[self.submits] = pcm.len;
        @memcpy(self.pcm[self.pcm_len..][0..pcm.len], pcm);
        self.pcm_len += pcm.len;
        self.submits += 1;
        self.last_id = id;
        self.language = language;
    }
    fn cancel(self: *FakeHelper, id: backend.UtteranceId) void {
        self.cancels += 1;
        self.last_cancel_id = id;
        if (self.lease_id == id) self.lease_id = null;
    }
    fn requestCancel(self: *FakeHelper, id: backend.UtteranceId) void {
        self.cancellation_requests += 1;
        self.last_request_id = id;
    }
    fn retry(self: *FakeHelper) void {
        self.retries += 1;
    }
    // The Adapter's segmentation tests never drive backend reselection or teardown, so these
    // two members of the Helper contract are inert here — present so the fake is a complete
    // Helper (asserted below), not a partial one.
    fn usesModel(_: *FakeHelper, _: []const u8) bool {
        return true;
    }
    fn shutdown(_: *FakeHelper) void {}
};

comptime {
    assertHelper(FakeHelper);
}

/// Deliver a Segment's Final Transcript as the reader loop would: free the single slot,
/// then hand the Adapter the terminal keyed by the Segment id it was submitted under.
fn deliverFinal(helper: *FakeHelper, adapter: *Adapter(FakeHelper), seg_id: backend.UtteranceId, text: []const u8) void {
    if (helper.lease_id == seg_id) helper.lease_id = null;
    adapter.receiveFinal(seg_id, text);
}
fn deliverFailed(helper: *FakeHelper, adapter: *Adapter(FakeHelper), seg_id: backend.UtteranceId) void {
    if (helper.lease_id == seg_id) helper.lease_id = null;
    adapter.receiveFailed(seg_id);
}

/// A buffer of quiet Capture (RMS 0) and one of loud Capture (RMS ≈ full scale). With a
/// test policy whose `silence_rms` sits between them, `loud` is speech and `quiet` is a pause.
const quiet4 = [_]u8{ 0, 0, 0, 0 };
const loud4 = [_]u8{ 0xff, 0x7f, 0xff, 0x7f };

/// A tiny policy: 4-byte soft floor, 8-byte hard max, 4-byte (one buffer) pause, threshold
/// between quiet and loud — so a few 4-byte buffers exercise real cuts.
const tiny_policy = SegmentPolicy{ .soft_floor_bytes = 4, .hard_max_bytes = 8, .pause_bytes = 4, .silence_rms = 0.5 };

const EventRecorder = struct {
    finals: usize = 0,
    failures: usize = 0,
    id: backend.UtteranceId = 0,
    buf: [256]u8 = undefined,
    buf_len: usize = 0,

    fn events(self: *EventRecorder) Events {
        return .{ .ctx = self, .final = final, .failed = failed };
    }
    // Copies synchronously, as the real Final Transcript consumer (the Insertion seam via the
    // Coordinator) does — the Adapter frees the assembled text the moment this returns.
    fn final(ctx: *anyopaque, id: backend.UtteranceId, text: []const u8) void {
        const self: *EventRecorder = @ptrCast(@alignCast(ctx));
        self.finals += 1;
        self.id = id;
        @memcpy(self.buf[0..text.len], text);
        self.buf_len = text.len;
    }
    fn failed(ctx: *anyopaque, id: backend.UtteranceId) void {
        const self: *EventRecorder = @ptrCast(@alignCast(ctx));
        self.failures += 1;
        self.id = id;
    }
    fn lastText(self: *EventRecorder) []const u8 {
        return self.buf[0..self.buf_len];
    }
};

const IntegrationAudio = struct {
    captured: bool = true,
    pub fn start(_: *IntegrationAudio) !void {}
    pub fn stop(_: *IntegrationAudio) void {}
    pub fn capturedAudio(self: *IntegrationAudio) bool {
        return self.captured;
    }
    pub fn heardSound(_: *IntegrationAudio) bool {
        return true;
    }
};

const IntegrationBackends = struct {
    adapter: *Adapter(FakeHelper),
    pub fn acquire(self: *IntegrationBackends, id: backend.UtteranceId) ?backend.Lease {
        return self.adapter.acquire(id, "sv");
    }

    pub fn resolve(_: *IntegrationBackends, _: backend.UtteranceId) void {}
};

const IntegrationInsertion = struct {
    submits: usize = 0,
    id: backend.UtteranceId = 0,
    text: [64]u8 = undefined,
    text_len: usize = 0,
    pub fn submit(self: *IntegrationInsertion, id: backend.UtteranceId, value: []const u8, kind: coordinator.InsertKind) void {
        self.submits += 1;
        self.id = id;
        @memcpy(self.text[0..value.len], value);
        self.text_len = value.len;
        // A local Lease never routes through the rewrite, so it only ever inserts normally.
        std.debug.assert(kind == .normal);
    }
};

/// Backtrack never applies on the local Transcription Backend (docs/backtrack-spec.md),
/// so the local integration Coordinator must never reach this seam.
const IntegrationRewrite = struct {
    pub fn submit(_: *IntegrationRewrite, _: backend.UtteranceId, _: []const u8) void {
        unreachable; // a local Lease can never route a Final Transcript to the rewrite
    }
};

const IntegrationDeadline = struct {
    pub fn arm(_: *IntegrationDeadline, _: backend.UtteranceId, _: backend.DeadlineKind, _: backend.DeadlinePolicy) void {}
    pub fn cancel(_: *IntegrationDeadline, _: backend.UtteranceId) void {}
};

const IntegrationFeedback = struct {
    abandoned_count: usize = 0,
    pub fn listening(_: *IntegrationFeedback) void {}
    pub fn released(_: *IntegrationFeedback) void {}
    pub fn inserted(_: *IntegrationFeedback) void {}
    pub fn degraded(_: *IntegrationFeedback) void {} // local never degrades (no rewrite)
    pub fn abandoned(self: *IntegrationFeedback) void {
        self.abandoned_count += 1;
    }
};

const IntegrationDeps = struct {
    audio: *IntegrationAudio,
    backends: *IntegrationBackends,
    rewrite: *IntegrationRewrite,
    insertion: *IntegrationInsertion,
    deadline: *IntegrationDeadline,
    feedback: *IntegrationFeedback,
};
const IntegrationCoordinator = coordinator.Coordinator(IntegrationDeps);

const CoordinatorBridge = struct {
    co: *IntegrationCoordinator = undefined,
    fn events(self: *CoordinatorBridge) Events {
        return .{ .ctx = self, .final = final, .failed = failed };
    }
    fn final(ctx: *anyopaque, id: backend.UtteranceId, text: []const u8) void {
        const self: *CoordinatorBridge = @ptrCast(@alignCast(ctx));
        self.co.handle(.{ .final = .{ .id = id, .text = text } });
    }
    fn failed(ctx: *anyopaque, id: backend.UtteranceId) void {
        const self: *CoordinatorBridge = @ptrCast(@alignCast(ctx));
        self.co.handle(.{ .backend_failed = id });
    }
};

test "a short Utterance is one Segment, submitted once after release, byte-for-byte as before" {
    const cases = .{
        .{ "en", ipc.Language.english },
        .{ "sv", ipc.Language.swedish },
        .{ "", ipc.Language.auto_detect },
    };
    inline for (cases) |case| {
        var helper = FakeHelper{};
        var events = EventRecorder{};
        var adapter = Adapter(FakeHelper).init(std.testing.allocator, std.testing.io, &helper, events.events());
        defer adapter.deinit();

        try adapter.begin(41, case[0]);
        try adapter.appendAudio(41, &.{ 1, 2 });
        try adapter.appendAudio(41, &.{ 3, 4, 5, 6 });
        try std.testing.expectEqual(@as(usize, 0), helper.submits); // nothing mid-Utterance

        try adapter.release(41);
        try std.testing.expectEqual(@as(usize, 1), helper.submits);
        try std.testing.expectEqual(segmentId(41, 0), helper.last_id);
        try std.testing.expectEqual(case[1], helper.language);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, helper.pcm[0..helper.pcm_len]);

        // The lone Segment Transcript becomes the Final Transcript verbatim — leading space
        // and all — so the Insertion is identical to the pre-segmentation path.
        deliverFinal(&helper, &adapter, segmentId(41, 0), " Hallå");
        try std.testing.expectEqual(@as(usize, 1), events.finals);
        try std.testing.expectEqualStrings(" Hallå", events.lastText());
        try std.testing.expect(adapter.active_id == null);
    }
}

test "a long Utterance is cut at a pause into ordered Segments assembled into one Final Transcript" {
    var helper = FakeHelper{};
    var events = EventRecorder{};
    var adapter = Adapter(FakeHelper).init(std.testing.allocator, std.testing.io, &helper, events.events());
    adapter.segmenter.policy = tiny_policy;
    defer adapter.deinit();

    try adapter.begin(3, "en");
    // Speech reaches the soft floor, then a pause closes the first Segment in the background.
    try adapter.appendAudio(3, &loud4);
    try adapter.appendAudio(3, &quiet4);
    try std.testing.expectEqual(@as(usize, 1), helper.submits);
    try std.testing.expectEqual(segmentId(3, 0), helper.ids[0]);
    try std.testing.expectEqual(@as(usize, 0), events.finals); // nothing inserted mid-Utterance

    // The first Segment transcribes while the second is still being spoken.
    deliverFinal(&helper, &adapter, segmentId(3, 0), "hello");
    try adapter.appendAudio(3, &loud4);
    try adapter.appendAudio(3, &quiet4);
    try std.testing.expectEqual(@as(usize, 2), helper.submits);
    try std.testing.expectEqual(segmentId(3, 1), helper.ids[1]);

    // Release flushes the (empty) trailing Segment and drains; the last final assembles all.
    try adapter.release(3);
    try std.testing.expectEqual(@as(usize, 0), events.finals);
    deliverFinal(&helper, &adapter, segmentId(3, 1), "world");
    try std.testing.expectEqual(@as(usize, 1), events.finals);
    try std.testing.expectEqualStrings("hello world", events.lastText()); // spoken order, clean seam
    try std.testing.expect(adapter.active_id == null);
}

test "no pause forces a cut at the hard max" {
    var helper = FakeHelper{};
    var events = EventRecorder{};
    var adapter = Adapter(FakeHelper).init(std.testing.allocator, std.testing.io, &helper, events.events());
    adapter.segmenter.policy = .{ .soft_floor_bytes = 4, .hard_max_bytes = 8, .pause_bytes = 4, .silence_rms = 0.5 };
    defer adapter.deinit();

    try adapter.begin(5, "en");
    // Unbroken speech — no pause ever — is force-cut once it reaches the 8-byte hard max.
    try adapter.appendAudio(5, &loud4);
    try std.testing.expectEqual(@as(usize, 0), helper.submits);
    try adapter.appendAudio(5, &loud4);
    try std.testing.expectEqual(@as(usize, 1), helper.submits);
    try std.testing.expectEqual(segmentId(5, 0), helper.ids[0]);
    try std.testing.expectEqual(@as(usize, 8), helper.lens[0]);
}

test "any Segment failing discards the whole Utterance, even an already-transcribed one" {
    var helper = FakeHelper{};
    var events = EventRecorder{};
    var adapter = Adapter(FakeHelper).init(std.testing.allocator, std.testing.io, &helper, events.events());
    adapter.segmenter.policy = tiny_policy;
    defer adapter.deinit();

    try adapter.begin(6, "en");
    try adapter.appendAudio(6, &loud4);
    try adapter.appendAudio(6, &quiet4); // cut + submit Segment 0
    deliverFinal(&helper, &adapter, segmentId(6, 0), "part one"); // transcribes fine
    try adapter.appendAudio(6, &loud4);
    try adapter.appendAudio(6, &quiet4); // cut + submit Segment 1

    deliverFailed(&helper, &adapter, segmentId(6, 1)); // Segment 1 fails
    try std.testing.expectEqual(@as(usize, 1), events.failures);
    try std.testing.expectEqual(@as(usize, 0), events.finals); // "part one" is discarded, not inserted
    try std.testing.expect(adapter.active_id == null);
}

test "local Transcription Backend emits only matching terminal events and cancellation never falls back" {
    var helper = FakeHelper{};
    var events = EventRecorder{};
    var adapter = Adapter(FakeHelper).init(std.testing.allocator, std.testing.io, &helper, events.events());
    defer adapter.deinit();

    const empty = adapter.acquire(6, "en").?;
    try empty.begin();
    empty.cancel();
    try std.testing.expectEqual(@as(usize, 0), helper.submits);

    const lease = adapter.acquire(7, "sv").?;
    try lease.begin();
    try lease.appendAudio(&.{ 1, 2 });
    try lease.release();
    lease.requestCancellation();
    try std.testing.expectEqual(@as(usize, 1), helper.cancellation_requests);
    try std.testing.expectEqual(segmentId(7, 0), helper.last_request_id);
    // A Segment final from a resolved Utterance's id is dropped, not misattributed.
    deliverFinal(&helper, &adapter, segmentId(6, 0), "stale");
    try std.testing.expectEqual(@as(usize, 0), events.finals);
    deliverFinal(&helper, &adapter, segmentId(7, 0), "Hej");
    try std.testing.expectEqual(@as(usize, 1), events.finals);
    try std.testing.expectEqualStrings("Hej", events.lastText());

    const failed = adapter.acquire(8, "").?;
    try failed.begin();
    try failed.appendAudio(&.{ 3, 4 });
    try failed.release();
    deliverFailed(&helper, &adapter, segmentId(8, 0));
    try std.testing.expectEqual(@as(usize, 1), events.failures);

    const cancelled = adapter.acquire(9, "en").?;
    try cancelled.begin();
    try cancelled.appendAudio(&.{ 5, 6 });
    try cancelled.release();
    cancelled.cancel(); // an in-flight Segment is cancelled at the helper
    try std.testing.expectEqual(@as(usize, 1), helper.cancels);
    try std.testing.expectEqual(segmentId(9, 0), helper.last_cancel_id);
    deliverFinal(&helper, &adapter, segmentId(9, 0), "late");
    try std.testing.expectEqual(@as(usize, 1), events.finals);

    adapter.retry();
    try std.testing.expectEqual(@as(usize, 1), helper.retries);
}

test "the release-anchored drain deadline covers the Segment queue (~15 s)" {
    try std.testing.expectEqual(@as(u32, 15_000), local_deadline.final_ms);
    try std.testing.expect(local_deadline.cooperative_cancel_ms.? < local_deadline.final_ms);
    try std.testing.expect(local_deadline.cooperative_cancel_ms.? >= 12_000);

    var helper = FakeHelper{};
    var events = EventRecorder{};
    var adapter = Adapter(FakeHelper).init(std.testing.allocator, std.testing.io, &helper, events.events());
    defer adapter.deinit();
    const lease = adapter.acquire(1, "en").?;
    try std.testing.expectEqual(local_deadline.final_ms, lease.deadline.final_ms);
    try std.testing.expectEqual(local_deadline.cooperative_cancel_ms, lease.deadline.cooperative_cancel_ms);
}

test "local Transcription Backend drives one Insertion and abandons empty or failed Utterances without OpenAI" {
    var helper = FakeHelper{};
    var bridge = CoordinatorBridge{};
    var adapter = Adapter(FakeHelper).init(std.testing.allocator, std.testing.io, &helper, bridge.events());
    defer adapter.deinit();
    var audio = IntegrationAudio{};
    var backends = IntegrationBackends{ .adapter = &adapter };
    var insertion = IntegrationInsertion{};
    var rewrite = IntegrationRewrite{};
    var deadline = IntegrationDeadline{};
    var surface = IntegrationFeedback{};
    var co = IntegrationCoordinator.init(.{
        .audio = &audio,
        .backends = &backends,
        .rewrite = &rewrite,
        .insertion = &insertion,
        .deadline = &deadline,
        .feedback = &surface,
    });
    bridge.co = &co;

    co.handle(.press);
    try adapter.appendAudio(1, &.{ 1, 2, 3, 4 });
    co.handle(.release);
    try std.testing.expectEqual(@as(usize, 1), helper.submits);
    deliverFinal(&helper, &adapter, segmentId(1, 0), "Hej världen");
    try std.testing.expectEqual(@as(usize, 1), insertion.submits);
    try std.testing.expectEqualStrings("Hej världen", insertion.text[0..insertion.text_len]);
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });

    co.handle(.press);
    try adapter.appendAudio(2, &.{ 5, 6 });
    co.handle(.release);
    deliverFailed(&helper, &adapter, segmentId(2, 0));
    try std.testing.expectEqual(@as(usize, 1), insertion.submits);

    co.handle(.press);
    try adapter.appendAudio(3, &.{ 7, 8 });
    co.handle(.release);
    deliverFinal(&helper, &adapter, segmentId(3, 0), "");
    try std.testing.expectEqual(@as(usize, 1), insertion.submits);
    // No helper cancellation once a Segment's terminal is in — nothing is inflight to cancel.
    try std.testing.expectEqual(@as(usize, 0), helper.cancels);

    audio.captured = false;
    co.handle(.press);
    co.handle(.release);
    try std.testing.expectEqual(@as(usize, 3), helper.submits);
    try std.testing.expectEqual(@as(usize, 1), insertion.submits);
    try std.testing.expectEqual(@as(usize, 3), surface.abandoned_count);
    try std.testing.expectEqual(@as(usize, 0), helper.retries);
}
