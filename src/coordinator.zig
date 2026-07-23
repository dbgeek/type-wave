//! coordinator.zig — the Utterance Coordinator (architecture review 2026-07-08, candidate 1).
//!
//! The state machine that drives one Utterance from Talk Key press to a resolved
//! Insertion. It owns the lifecycle policy that used to be smeared across daemon.zig's
//! onPress / onRelease / workerLoop / processUtterance and coordinated through four
//! cross-thread atomics (busy / hold_active / insert_pending / got_final). Here it is a
//! single **synchronous** state machine under one mutex, reached only by feeding it
//! events — so every grilled edge case (overlap, poison-on-drop, the release-anchored
//! deadline, empty/failed transcripts, insert failure) is exercised by a scripted event
//! sequence against fakes, with no threads and no hardware (see the tests below).
//!
//! # Shape
//!
//!   - **Outbound seams are comptime-generic deps.** `Coordinator(Deps)` calls
//!     `deps.audio` / `deps.transcription` / `deps.rewrite` / `deps.insertion` /
//!     `deps.deadline` / `deps.feedback` by duck-typed method name. Real adapters in daemon.zig / surface.zig;
//!     fakes in the tests. No vtables, no @ptrCast — a shape mismatch is a compile error.
//!   - **Inbound events arrive via `handle(event)`**, serialized on one `os_unfair_lock`.
//!     The tap (press/release), the always-on Transcription observer (partial/final), the
//!     deadline timer (deadline), and the insert worker (inserted) all trampoline here from
//!     their own threads; the mutex makes the machine single-threaded from its own view, so
//!     the old atomics become the plain `phase` enum (`busy` ≡ `phase != .idle`).
//!
//! # Phases (ADR-0001: fully serialized)
//!
//!   idle → capturing → awaiting_final → [rewriting →] inserting → idle
//!
//!   `.inserting` is blocking: one Utterance resolves fully (paste included) before the
//!   next hold is accepted. This is what lets `hideIfFinal` collapse to `hide()` — nothing
//!   can repaint the pill mid-Insertion. See ADR-0001 for the traded-away #19 overlap.
//!
//!   `.rewriting` (docs/backtrack-spec.md) sits between `awaiting_final` and `inserting`
//!   and is entered only when the Lease pinned Backtrack on AND the OpenAI backend at
//!   press. It is just as blocking as `.inserting` — Talk Key presses are rejected — and
//!   the green processing HUD spans it unchanged (released → resolution, no new state).
//!   The `rewrite_deadline` budget (~3 s) bounds the extra wait: past it the raw Final
//!   Transcript inserts instead, so a slow rewrite degrades rather than stalls.

const std = @import("std");
const feedback = @import("feedback.zig");
const backend = @import("transcription_backend.zig");
const insert = @import("insert.zig");

pub const UtteranceId = backend.UtteranceId;

/// Which text the Insertion seam is placing. `.normal` is a successful rewrite or any
/// non-Backtrack insert; `.raw_fallback` is the raw Final Transcript inserted because the
/// Backtrack rewrite timed out or errored (docs/backtrack-spec.md §UX 4, ADR-0004). The
/// kind rides `submit` so a clean `.raw_fallback` insert reports `.degraded` — the seam
/// alone can't tell the raw fallback from a normal insert.
pub const InsertKind = enum { normal, raw_fallback };

/// Outcome the insert worker reports back as the `.inserted` event. `.degraded` is a
/// successful `.raw_fallback` insertion (docs/backtrack-spec.md §UX 4, ADR-0004): the text
/// still landed — no error cue — but the downgrade earns the amber HUD pulse. The insertion
/// mechanism failing outright is still `.failed`, whatever the submitted kind.
pub const InsertResult = enum { ok, degraded, failed };

/// Best-effort **App Identity** hint (CONTEXT.md) stamped into an Insertion Record's
/// `focused_app`: the frontmost app's bundle id + display name, read best-effort from
/// `NSWorkspace` on the insert worker at the moment the text lands — never under
/// `coordinator.mu` (ADR-0006). Fixed inline buffers, zero-filled past the length so the
/// value stays `std.meta.eql`-comparable for the future text-free Recent Insertions View
/// projection (#186). Nullable, never load-bearing.
pub const AppIdentity = struct {
    bundle_id_bytes: [255]u8 = std.mem.zeroes([255]u8),
    bundle_id_len: u8 = 0,
    name_bytes: [255]u8 = std.mem.zeroes([255]u8),
    name_len: u8 = 0,

    pub fn init(bundle_id: []const u8, display_name: []const u8) AppIdentity {
        var self = AppIdentity{};
        const b = @min(bundle_id.len, self.bundle_id_bytes.len);
        @memcpy(self.bundle_id_bytes[0..b], bundle_id[0..b]);
        self.bundle_id_len = @intCast(b);
        const n = @min(display_name.len, self.name_bytes.len);
        @memcpy(self.name_bytes[0..n], display_name[0..n]);
        self.name_len = @intCast(n);
        return self;
    }
    pub fn bundleId(self: *const AppIdentity) []const u8 {
        return self.bundle_id_bytes[0..self.bundle_id_len];
    }
    pub fn displayName(self: *const AppIdentity) []const u8 {
        return self.name_bytes[0..self.name_len];
    }
};

/// The write payload handed across the recorder seam at `onInserted` (ADR-0006). The
/// `inserted` / `raw` slices borrow Coordinator-local buffers and are valid **only for the
/// duration of the `record` call** — the daemon-owned ring copies them into its own inline
/// buffers under its leaf lock (exactly the memcpy discipline the rest of the seams use).
/// Assembled once per resolved Insertion, whatever the outcome.
pub const InsertionRecord = struct {
    /// The with-space bytes that hit the cursor (post-Rewrite when Backtrack ran, raw
    /// otherwise) — byte-identical to the insert because the Coordinator buffers it through
    /// the same `ensureTrailingSpace` the Insertion adapter applies.
    inserted: []const u8,
    /// The trimmed Final Transcript, present only on the Backtrack detour (its pre-Rewrite
    /// form); `null` for non-Backtrack Utterances, where it would equal `inserted`.
    raw: ?[]const u8,
    /// `feedback.nowMs()` stamped at `onInserted`.
    timestamp: i64,
    /// Known only at `onInserted`; `.failed` insertions are recorded too (§2.2).
    outcome: InsertResult,
    /// Read off-mutex on the insert worker, carried back through the `.inserted` report.
    focused_app: ?AppIdentity,
};

/// Outcome the Rewrite worker reports back as the `.rewritten` event
/// (docs/backtrack-spec.md). `.failed` means the OpenAI call did not yield a usable
/// rewrite — the event then carries the raw Final Transcript so dictation never
/// breaks; the distinction feeds the degraded-insertion surface (spec §UX 4).
pub const RewriteResult = enum { ok, failed };

/// The Backtrack rewrite budget (docs/backtrack-spec.md §failure policy): a ~3 s hard
/// timeout armed at rewrite-submit, independent of the release-anchored deadline (which
/// the Final Transcript already cancelled). ~10% of warm calls exceed the original
/// 2.5 s, with rare 9.8 s / 14.7 s outliers — past this budget the raw Final Transcript
/// inserts instead, so the degraded path is expected on roughly 1 in 10–20 utterances.
pub const rewrite_deadline = backend.DeadlinePolicy{ .final_ms = 3_000 };

/// Everything that can happen *to* an Utterance, from whichever thread observed it.
/// The `final` slice borrows the Transcription Session's accumulator and is valid only
/// for the duration of the `handle` call — the insertion seam copies synchronously
/// (exactly the memcpy the old worker did before releasing the guard). Partial
/// Transcripts no longer reach the Coordinator at all: the HUD shows no text (#27),
/// and their log lives upstream in session.zig (#18).
pub const Event = union(enum) {
    press,
    release,
    final: struct { id: UtteranceId, text: []const u8 },
    backend_failed: UtteranceId,
    cooperative_cancel: UtteranceId,
    /// A claimed deadline fire. The kind names which wait it bounded — the claim and a
    /// phase-advancing event race on different locks, so id + phase alone cannot tell
    /// a stale release-anchored fire from the rewrite budget (they share the id).
    deadline: struct { id: UtteranceId, kind: backend.DeadlineKind },
    /// Reverse edge from the Rewrite worker (docs/backtrack-spec.md). Like `final`,
    /// the `text` slice borrows the worker's buffer and is valid only for the
    /// duration of the `handle` call — the insertion seam copies synchronously.
    rewritten: struct { id: UtteranceId, text: []const u8, result: RewriteResult },
    /// The insert worker's reverse edge. `focused_app` is the App Identity hint read
    /// off-mutex the moment the text landed (ADR-0006), stamped into the Insertion Record
    /// here under the lock; defaulted so the Coordinator's own tests can omit it.
    inserted: struct { id: UtteranceId, result: InsertResult, focused_app: ?AppIdentity = null },
};

const Phase = enum { idle, capturing, awaiting_final, rewriting, inserting };

/// A single fast, self-contained mutex (os_unfair_lock — same choice as hud.zig, since
/// std.Thread.Mutex is gone on this Zig nightly and std.Io.Mutex needs an Io the pure
/// state machine shouldn't carry). Zero-initializable, so a test builds one for free.
const Mutex = struct {
    lock_: OsUnfairLock = .{},
    fn lock(self: *Mutex) void {
        os_unfair_lock_lock(&self.lock_);
    }
    fn unlock(self: *Mutex) void {
        os_unfair_lock_unlock(&self.lock_);
    }
};
const OsUnfairLock = extern struct { _opaque: u32 = 0 };
extern "c" fn os_unfair_lock_lock(lock: *OsUnfairLock) void;
extern "c" fn os_unfair_lock_unlock(lock: *OsUnfairLock) void;

pub fn Coordinator(comptime Deps: type) type {
    return struct {
        const Self = @This();

        deps: Deps,
        mu: Mutex = .{},
        phase: Phase = .idle,
        next_id: UtteranceId = 1,
        active: ?backend.Lease = null,
        poisoned: bool = false,
        /// The raw Final Transcript, copied when the Utterance detours into `.rewriting`
        /// (the `final` slice is only valid during that `handle` call). This is what the
        /// rewrite-budget fallback inserts — sized like the Rewrite adapter's job buffer
        /// to the Transcription Session's accumulator, so the whole transcript fits.
        raw: [8192]u8 = undefined,
        raw_len: usize = 0,
        /// The **with-space** Insertion text, buffered from the submit sites so the Insertion
        /// Record committed at `onInserted` holds bytes byte-identical to what hit the cursor
        /// (ADR-0006 §capture). Sized like the Insertion adapter's job buffer so
        /// `ensureTrailingSpace` produces the same result the adapter does.
        pending: [8193]u8 = undefined,
        pending_len: usize = 0,

        pub fn init(deps: Deps) Self {
            return .{ .deps = deps };
        }

        /// Stash the with-space form of the text this Utterance is inserting, applying the
        /// same `ensureTrailingSpace` the Insertion adapter applies at `submit` — so the
        /// buffered `inserted` bytes match the cursor exactly. Called at every submit site.
        fn bufferPending(self: *Self, text: []const u8) void {
            const s = insert.ensureTrailingSpace(&self.pending, text);
            self.pending_len = s.len;
        }

        /// The one entry point. Serializes every inbound edge onto the state machine.
        pub fn handle(self: *Self, ev: Event) void {
            self.mu.lock();
            defer self.mu.unlock();
            switch (ev) {
                .press => self.onPress(),
                .release => self.onRelease(),
                .final => |e| self.onFinal(e.id, e.text),
                .backend_failed => |id| self.onBackendFailed(id),
                .cooperative_cancel => |id| self.onCooperativeCancel(id),
                .deadline => |e| self.onDeadline(e.id, e.kind),
                .rewritten => |e| self.onRewritten(e.id, e.text, e.result),
                .inserted => |e| self.onInserted(e.id, e.result, e.focused_app),
            }
        }

        // ---- handlers (all run under self.mu) ------------------------------------

        fn onPress(self: *Self) void {
            // Overlap guard: any non-idle phase means the previous Utterance is still
            // resolving. Drop this press so nothing races the in-flight Utterance.
            if (self.phase != .idle) {
                feedback.log("  Talk Key pressed while the previous Utterance is still resolving — ignored\n", .{});
                return;
            }
            const id = self.next_id;
            const lease = self.deps.backends.acquire(id) orelse {
                feedback.log("  Talk Key pressed but the selected Transcription Backend is not ready — ignored\n", .{});
                self.deps.feedback.abandoned();
                return;
            };
            self.next_id +%= 1;
            self.poisoned = false;
            self.active = lease;
            lease.begin() catch |e| {
                feedback.log("  backend begin failed: {s} — Utterance aborted\n", .{@errorName(e)});
                lease.cancel();
                self.abandon();
                return;
            };
            self.deps.audio.start() catch |e| {
                feedback.log("  capture.start failed: {s} — Utterance aborted\n", .{@errorName(e)});
                lease.cancel();
                self.abandon();
                return; // stays .idle
            };
            self.phase = .capturing;
            self.deps.feedback.listening();
            feedback.log("  [REC] listening — release the Talk Key to insert\n", .{});
        }

        fn onRelease(self: *Self) void {
            if (self.phase != .capturing) return; // press was rejected / no live hold

            const lease = self.active.?;

            self.deps.audio.stop(); // synchronous; final buffers flush + forward during this
            self.deps.feedback.released();

            // Link dropped mid-Utterance: the head audio already streamed live is gone
            // server-side, so committing the buffered tail would insert a truncated Final
            // Transcript. Abandon cleanly rather than commit a fragment.
            if (self.poisoned) {
                feedback.log("  part of that was lost — the whole Utterance was discarded; hold the Talk Key and say it again\n", .{});
                self.abandon();
                return;
            }
            if (!self.deps.audio.capturedAudio()) {
                feedback.log("  Utterance produced no audio — nothing to insert\n", .{});
                lease.cancel();
                self.abandon();
                return;
            }
            // Mic-silence detection: TCC denial yields all-zero PCM with no error.
            if (!self.deps.audio.heardSound())
                feedback.log("  microphone captured only silence — is Microphone permission granted to this process?\n", .{});

            self.deps.deadline.arm(lease.id, .release, lease.deadline); // release-anchored; final cancels it
            lease.release() catch |e| {
                self.deps.deadline.cancel(lease.id);
                feedback.log("  backend release failed: {s}\n", .{@errorName(e)});
                lease.cancel();
                self.abandon();
                return;
            };
            self.phase = .awaiting_final;
        }

        fn onFinal(self: *Self, id: UtteranceId, text: []const u8) void {
            if (!self.matches(id, .awaiting_final)) return;
            self.deps.deadline.cancel(id);
            if (text.len == 0) {
                // Empty/failed transcript (mic silence, transcription.failed, …).
                feedback.log("  empty Final Transcript — nothing to insert\n", .{});
                self.active.?.cancel();
                self.abandon();
                return;
            }
            // No feedback edge here: the processing dots have been up since `released`
            // and hold until `.inserted` resolves (wayfinder #26/#27).
            //
            // Backtrack (docs/backtrack-spec.md): when the Lease pinned it on with the
            // OpenAI backend at press, the Final Transcript detours through the Rewrite
            // seam; the `.rewritten` reverse edge then reaches the insertion seam. The
            // processing dots span the extra wait unchanged.
            if (self.active.?.backend == .openai and self.active.?.backtrack) {
                // Keep a copy for the rewrite-budget fallback: if the ~3 s budget fires,
                // the raw Final Transcript inserts from here.
                self.raw_len = @min(text.len, self.raw.len);
                @memcpy(self.raw[0..self.raw_len], text[0..self.raw_len]);
                self.deps.rewrite.submit(id, text); // copies text; worker rewrites, then .rewritten
                self.deps.deadline.arm(id, .rewrite, rewrite_deadline); // the ~3 s rewrite budget
                self.phase = .rewriting; // blocking, exactly like .inserting (ADR-0001)
                return;
            }
            self.bufferPending(text); // stash the with-space form for the Insertion Record
            self.deps.insertion.submit(id, text, .normal); // copies text; worker inserts, then .inserted
            self.phase = .inserting; // blocking: next hold waits (ADR-0001)
        }

        fn onRewritten(self: *Self, id: UtteranceId, text: []const u8, r: RewriteResult) void {
            if (!self.matches(id, .rewriting)) return;
            self.deps.deadline.cancel(id); // the rewrite resolved within its ~3 s budget
            // `.failed` already carries the raw Final Transcript (the worker's fallback):
            // dictation never breaks; the worker logged the downgrade. The `.raw_fallback`
            // kind rides the insert so `.inserted` earns the amber pulse (spec §UX 4, ADR-0004).
            const kind: InsertKind = if (r == .failed) .raw_fallback else .normal;
            self.bufferPending(text); // stash the with-space form for the Insertion Record
            self.deps.insertion.submit(id, text, kind); // copies text; worker inserts, then .inserted
            self.phase = .inserting;
        }

        fn onDeadline(self: *Self, id: UtteranceId, kind: backend.DeadlineKind) void {
            if (kind == .rewrite) {
                if (!self.matches(id, .rewriting)) return;
                // The ~3 s rewrite budget fired (docs/backtrack-spec.md §failure policy):
                // stop waiting and insert the raw Final Transcript copied at submit. No
                // error cue — text still lands. The abandoned call's late `.rewritten`
                // is stale-rejected by the phase guard.
                feedback.log("  Backtrack rewrite exceeded {d} ms — inserting the raw Final Transcript\n", .{rewrite_deadline.final_ms});
                self.bufferPending(self.raw[0..self.raw_len]); // stash the with-space form for the Insertion Record
                self.deps.insertion.submit(id, self.raw[0..self.raw_len], .raw_fallback); // earns the amber pulse
                self.phase = .inserting;
                return;
            }
            if (!self.matches(id, .awaiting_final)) return;
            // For local Segments this is a drain overrun: part of that was lost. The loud error
            // cue fires via abandon; the retry advice makes the signal specific (#92).
            feedback.log("  no Final Transcript within the deadline — nothing inserted; hold the Talk Key and say it again\n", .{});
            self.active.?.cancel();
            self.abandon();
        }

        fn onCooperativeCancel(self: *Self, id: UtteranceId) void {
            if (!self.matches(id, .awaiting_final)) return;
            self.active.?.requestCancellation();
        }

        fn onBackendFailed(self: *Self, id: UtteranceId) void {
            if (self.active == null or self.active.?.id != id) return;
            switch (self.phase) {
                .capturing => {
                    self.poisoned = true;
                    self.active.?.cancel();
                    feedback.log("  Transcription Backend failed mid-Utterance — will discard this Utterance on release\n", .{});
                },
                .awaiting_final => {
                    self.deps.deadline.cancel(id);
                    self.active.?.cancel();
                    // A local Segment failing during the post-release drain lands here: part of
                    // that was lost, discard whole (all-or-nothing) with the retry cue (#92).
                    feedback.log("  part of that was lost — the whole Utterance was discarded; hold the Talk Key and say it again\n", .{});
                    self.abandon();
                },
                // .rewriting: the Transcription Backend already delivered its Final
                // Transcript; a late backend failure cannot invalidate the rewrite.
                .idle, .rewriting, .inserting => {},
            }
        }

        fn onInserted(self: *Self, id: UtteranceId, r: InsertResult, focused_app: ?AppIdentity) void {
            if (!self.matches(id, .inserting)) return;
            // Commit the Insertion Record (ADR-0006): buffer-then-commit realizes §2.2's
            // retention rule for free — only Utterances that reach here are recorded, and
            // `.failed` reaches here (the primary recovery case). `raw` is present only on
            // the Backtrack detour (the Lease's pinned flag), where the pre-Rewrite transcript
            // was copied at `onFinal`; a non-Backtrack `raw` would just equal `inserted`.
            self.deps.recorder.record(.{
                .inserted = self.pending[0..self.pending_len],
                .raw = if (self.active.?.backtrack) self.raw[0..self.raw_len] else null,
                .timestamp = feedback.nowMs(),
                .outcome = r,
                .focused_app = focused_app,
            });
            switch (r) {
                .ok => self.deps.feedback.inserted(),
                // Raw-transcript fallback landed: dictation held (no error cue), but the
                // downgrade earns the amber HUD pulse instead of the silent hide (ADR-0004).
                .degraded => self.deps.feedback.degraded(),
                .failed => {
                    feedback.log("  insertion failed — nothing landed at the cursor\n", .{});
                    self.deps.feedback.abandoned();
                },
            }
            self.deps.backends.resolve(id);
            self.active = null;
            self.phase = .idle;
        }

        fn matches(self: *Self, id: UtteranceId, phase: Phase) bool {
            return self.phase == phase and self.active != null and self.active.?.id == id;
        }

        fn abandon(self: *Self) void {
            self.deps.feedback.abandoned();
            if (self.active) |lease| self.deps.backends.resolve(lease.id);
            self.active = null;
            self.phase = .idle;
        }
    };
}

// ============================================================================
// Tests — the whole point of the seam: scripted events, fake deps, no hardware.
// ============================================================================

const FakeAudio = struct {
    start_result: anyerror!void = {},
    started: usize = 0,
    stopped: usize = 0,
    captured: bool = true,
    heard: bool = true,
    fn start(self: *FakeAudio) anyerror!void {
        self.started += 1;
        return self.start_result;
    }
    fn stop(self: *FakeAudio) void {
        self.stopped += 1;
    }
    fn capturedAudio(self: *FakeAudio) bool {
        return self.captured;
    }
    fn heardSound(self: *FakeAudio) bool {
        return self.heard;
    }
};

const FakeBackends = struct {
    avail: bool = true,
    begin_result: anyerror!void = {},
    release_result: anyerror!void = {},
    backend_kind: backend.Backend = .openai,
    backtrack: bool = false,
    language: []const u8 = "en",
    policy: backend.DeadlinePolicy = backend.openai_deadline,
    began: usize = 0,
    appended: usize = 0,
    released: usize = 0,
    cancellation_requests: usize = 0,
    cancelled: usize = 0,
    resolved: usize = 0,
    resolved_id: UtteranceId = 0,
    last_id: UtteranceId = 0,

    const commands = backend.Commands{
        .begin = begin,
        .append_audio = appendAudio,
        .release = release,
        .request_cancel = requestCancel,
        .cancel = cancel,
    };

    fn acquire(self: *FakeBackends, id: UtteranceId) ?backend.Lease {
        if (!self.avail) return null;
        return .{
            .id = id,
            .backend = self.backend_kind,
            .language = self.language,
            .deadline = self.policy,
            .backtrack = self.backtrack,
            .ctx = self,
            .commands = &commands,
        };
    }
    fn from(ctx: *anyopaque) *FakeBackends {
        return @ptrCast(@alignCast(ctx));
    }
    fn begin(ctx: *anyopaque, id: UtteranceId, _: backend.Language, _: backend.Vocabulary) !void {
        const self = from(ctx);
        self.began += 1;
        self.last_id = id;
        return self.begin_result;
    }
    fn appendAudio(ctx: *anyopaque, id: UtteranceId, _: []const u8) !void {
        const self = from(ctx);
        self.appended += 1;
        self.last_id = id;
    }
    fn release(ctx: *anyopaque, id: UtteranceId) !void {
        const self = from(ctx);
        self.released += 1;
        self.last_id = id;
        return self.release_result;
    }
    fn requestCancel(ctx: *anyopaque, id: UtteranceId) void {
        const self = from(ctx);
        self.cancellation_requests += 1;
        self.last_id = id;
    }
    fn cancel(ctx: *anyopaque, id: UtteranceId) void {
        const self = from(ctx);
        self.cancelled += 1;
        self.last_id = id;
    }
    fn resolve(self: *FakeBackends, id: UtteranceId) void {
        self.resolved += 1;
        self.resolved_id = id;
    }
};

const FakeInsertion = struct {
    submits: usize = 0,
    last_id: UtteranceId = 0,
    last: [256]u8 = undefined,
    last_len: usize = 0,
    last_kind: InsertKind = .normal,
    fn submit(self: *FakeInsertion, id: UtteranceId, text: []const u8, kind: InsertKind) void {
        self.submits += 1;
        self.last_id = id;
        @memcpy(self.last[0..text.len], text);
        self.last_len = text.len;
        self.last_kind = kind;
    }
    fn lastText(self: *FakeInsertion) []const u8 {
        return self.last[0..self.last_len];
    }
};

const FakeRewrite = struct {
    submits: usize = 0,
    last_id: UtteranceId = 0,
    last: [256]u8 = undefined,
    last_len: usize = 0,
    fn submit(self: *FakeRewrite, id: UtteranceId, text: []const u8) void {
        self.submits += 1;
        self.last_id = id;
        @memcpy(self.last[0..text.len], text);
        self.last_len = text.len;
    }
    fn lastText(self: *FakeRewrite) []const u8 {
        return self.last[0..self.last_len];
    }
};

const FakeDeadline = struct {
    arms: usize = 0,
    cancels: usize = 0,
    last_id: UtteranceId = 0,
    last_kind: backend.DeadlineKind = .release,
    last_policy: backend.DeadlinePolicy = .{ .final_ms = 0 },
    fn arm(self: *FakeDeadline, id: UtteranceId, kind: backend.DeadlineKind, policy: backend.DeadlinePolicy) void {
        self.arms += 1;
        self.last_id = id;
        self.last_kind = kind;
        self.last_policy = policy;
    }
    fn cancel(self: *FakeDeadline, id: UtteranceId) void {
        self.cancels += 1;
        self.last_id = id;
    }
};

const FakeFeedback = struct {
    listenings: usize = 0,
    releaseds: usize = 0,
    inserteds: usize = 0,
    degradeds: usize = 0,
    abandoneds: usize = 0,
    fn listening(self: *FakeFeedback) void {
        self.listenings += 1;
    }
    fn released(self: *FakeFeedback) void {
        self.releaseds += 1;
    }
    fn inserted(self: *FakeFeedback) void {
        self.inserteds += 1;
    }
    fn degraded(self: *FakeFeedback) void {
        self.degradeds += 1;
    }
    fn abandoned(self: *FakeFeedback) void {
        self.abandoneds += 1;
    }
};

/// The write-only recorder seam (ADR-0006): the Coordinator hands a finished Insertion
/// Record here under `coordinator.mu`. The real daemon backs it with the leaf-locked ring;
/// this fake just captures the last record so the tests can assert on it.
const FakeRecorder = struct {
    records: usize = 0,
    last_inserted: [256]u8 = undefined,
    last_inserted_len: usize = 0,
    last_has_raw: bool = false,
    last_raw: [256]u8 = undefined,
    last_raw_len: usize = 0,
    last_outcome: InsertResult = .ok,
    last_timestamp: i64 = 0,
    last_focused_app: ?AppIdentity = null,
    fn record(self: *FakeRecorder, rec: InsertionRecord) void {
        self.records += 1;
        @memcpy(self.last_inserted[0..rec.inserted.len], rec.inserted);
        self.last_inserted_len = rec.inserted.len;
        if (rec.raw) |raw| {
            self.last_has_raw = true;
            @memcpy(self.last_raw[0..raw.len], raw);
            self.last_raw_len = raw.len;
        } else {
            self.last_has_raw = false;
            self.last_raw_len = 0;
        }
        self.last_outcome = rec.outcome;
        self.last_timestamp = rec.timestamp;
        self.last_focused_app = rec.focused_app;
    }
    fn lastInserted(self: *FakeRecorder) []const u8 {
        return self.last_inserted[0..self.last_inserted_len];
    }
    fn lastRaw(self: *FakeRecorder) []const u8 {
        return self.last_raw[0..self.last_raw_len];
    }
};

const TestDeps = struct {
    audio: *FakeAudio,
    backends: *FakeBackends,
    rewrite: *FakeRewrite,
    insertion: *FakeInsertion,
    deadline: *FakeDeadline,
    feedback: *FakeFeedback,
    recorder: *FakeRecorder,
};

const Harness = struct {
    audio: FakeAudio = .{},
    backends: FakeBackends = .{},
    rewrite: FakeRewrite = .{},
    insertion: FakeInsertion = .{},
    deadline: FakeDeadline = .{},
    feedback: FakeFeedback = .{},
    recorder: FakeRecorder = .{},
    co: Coordinator(TestDeps) = undefined,

    fn wire(self: *Harness) *Coordinator(TestDeps) {
        self.co = Coordinator(TestDeps).init(.{
            .audio = &self.audio,
            .backends = &self.backends,
            .rewrite = &self.rewrite,
            .insertion = &self.insertion,
            .deadline = &self.deadline,
            .feedback = &self.feedback,
            .recorder = &self.recorder,
        });
        return &self.co;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "1 happy path: press → release → final → inserted(ok)" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    try expect(h.backends.began == 1);
    try expect(h.audio.started == 1);
    try expect(h.feedback.listenings == 1);
    co.handle(.release);
    try expect(h.audio.stopped == 1);
    try expect(h.backends.released == 1);
    try expect(h.deadline.arms == 1);
    try expectEqual(@as(UtteranceId, 1), h.deadline.last_id);
    co.handle(.{ .final = .{ .id = 1, .text = "hello world" } });
    try expect(h.deadline.cancels == 1);
    try expect(h.insertion.submits == 1);
    try expectEqualStrings("hello world", h.insertion.lastText());
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    try expectEqual(@as(usize, 1), h.backends.resolved);
    try expectEqual(@as(UtteranceId, 1), h.backends.resolved_id);
    try expect(h.feedback.inserteds == 1);
    try expect(h.feedback.abandoneds == 0);
    // Fully resolved — a fresh press is accepted again.
    co.handle(.press);
    try expect(h.backends.began == 2);
    try expectEqual(@as(UtteranceId, 2), h.backends.last_id);
}

test "backend lease is resolved after abandonment" {
    var h = Harness{};
    h.audio.captured = false;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    try expectEqual(@as(usize, 1), h.backends.resolved);
    try expectEqual(@as(UtteranceId, 1), h.backends.resolved_id);
}

test "2 press while non-idle is dropped" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press); // → capturing
    co.handle(.press); // dropped
    try expect(h.backends.began == 1);
    try expect(h.audio.started == 1);
    try expect(h.feedback.listenings == 1);
}

test "3 press with no ready Transcription Backend lease" {
    var h = Harness{};
    h.backends.avail = false;
    const co = h.wire();
    co.handle(.press);
    try expect(h.backends.began == 0);
    try expect(h.audio.started == 0);
    try expect(h.feedback.abandoneds == 1);
    try expect(h.feedback.listenings == 0);
}

test "4 release without an accepted press is a no-op" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.release);
    try expect(h.audio.stopped == 0);
    try expect(h.backends.released == 0);
    try expect(h.feedback.releaseds == 0);
}

test "5 capture.start failure aborts the Utterance" {
    var h = Harness{};
    h.audio.start_result = error.AudioQueueStart;
    const co = h.wire();
    co.handle(.press);
    try expect(h.backends.began == 1);
    try expect(h.backends.cancelled == 1); // rolled back
    try expect(h.feedback.abandoneds == 1);
    try expect(h.feedback.listenings == 0);
    // stayed idle — a new press is accepted
    h.audio.start_result = {};
    co.handle(.press);
    try expect(h.backends.began == 2);
}

test "6 backend failure while capturing abandons on release without releasing backend" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.{ .backend_failed = 1 });
    co.handle(.release);
    try expect(h.backends.released == 0);
    try expect(h.backends.cancelled == 1);
    try expect(h.deadline.arms == 0);
    try expect(h.feedback.abandoneds == 1);
}

test "7 silence still commits, just warns" {
    var h = Harness{};
    h.audio.heard = false;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    try expect(h.backends.released == 1);
    try expect(h.deadline.arms == 1);
    try expect(h.feedback.abandoneds == 0);
}

test "8 no audio committed → abandon at release" {
    var h = Harness{};
    h.audio.captured = false;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    try expect(h.backends.released == 0);
    try expect(h.backends.cancelled == 1);
    try expect(h.deadline.arms == 0);
    try expect(h.feedback.abandoneds == 1);
    // resolved to idle
    h.audio.captured = true;
    co.handle(.press);
    try expect(h.backends.began == 2);
}

test "9 deadline before final abandons" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release); // → awaiting_final
    co.handle(.{ .deadline = .{ .id = 1, .kind = .release } });
    try expect(h.feedback.abandoneds == 1);
    try expect(h.insertion.submits == 0);
    // a stale final afterwards is ignored
    co.handle(.{ .final = .{ .id = 1, .text = "too late" } });
    try expect(h.insertion.submits == 0);
}

test "9a cooperative deadline requests cancellation without resolving the Utterance" {
    var h = Harness{};
    h.backends.policy = .{ .cooperative_cancel_ms = 9_500, .final_ms = 10_000 };
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);

    co.handle(.{ .cooperative_cancel = 1 });
    try expectEqual(@as(usize, 1), h.backends.cancellation_requests);
    try expectEqual(@as(usize, 0), h.backends.cancelled);
    try expectEqual(@as(usize, 0), h.feedback.abandoneds);

    co.handle(.{ .deadline = .{ .id = 1, .kind = .release } });
    try expectEqual(@as(usize, 1), h.backends.cancelled);
    try expectEqual(@as(usize, 1), h.feedback.abandoneds);
}

test "9b backend failure while awaiting final abandons immediately" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release); // -> awaiting_final
    co.handle(.{ .backend_failed = 1 });
    try expect(h.deadline.cancels == 1);
    try expect(h.backends.cancelled == 1);
    try expect(h.feedback.abandoneds == 1);
    try expect(h.insertion.submits == 0);
    // a stale final afterwards is ignored
    co.handle(.{ .final = .{ .id = 1, .text = "too late" } });
    try expect(h.insertion.submits == 0);
}

test "10 empty/failed final inserts nothing" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "" } });
    try expect(h.deadline.cancels == 1);
    try expect(h.backends.cancelled == 1);
    try expect(h.insertion.submits == 0);
    try expect(h.feedback.abandoneds == 1);
}

test "11 stale final outside awaiting is ignored" {
    var h = Harness{};
    const co = h.wire();
    // final with no Utterance in flight
    co.handle(.{ .final = .{ .id = 99, .text = "ghost" } });
    try expect(h.insertion.submits == 0);
    // final while still capturing (before release) is also ignored
    co.handle(.press);
    co.handle(.{ .final = .{ .id = 1, .text = "early" } });
    try expect(h.insertion.submits == 0);
}

test "12 insert failure sounds the error path" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "text" } });
    try expect(h.insertion.submits == 1);
    co.handle(.{ .inserted = .{ .id = 1, .result = .failed } });
    try expect(h.feedback.inserteds == 0);
    try expect(h.feedback.abandoneds == 1);
    // resolved to idle regardless of insert outcome
    co.handle(.press);
    try expect(h.backends.began == 2);
}

test "13 press during .inserting is dropped (ADR-0001)" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "landing" } }); // → inserting
    co.handle(.press); // must be dropped — one Utterance resolves fully first
    try expect(h.backends.began == 1);
    try expect(h.audio.started == 1);
    // once the paste reports done, the next hold is accepted
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    co.handle(.press);
    try expect(h.backends.began == 2);
}

test "14 accepted Utterance pins unique identity backend language and deadline policy" {
    var h = Harness{};
    h.backends.backend_kind = .openai;
    h.backends.language = "sv";
    h.backends.policy = .{ .final_ms = 12_345 };
    const co = h.wire();

    co.handle(.press);
    try expectEqual(@as(UtteranceId, 1), h.backends.last_id);
    try expectEqual(backend.Backend.openai, co.active.?.backend);
    try expectEqualStrings("sv", co.active.?.language);
    h.backends.language = "en";
    h.backends.policy = .{ .final_ms = 99 };
    co.handle(.release);

    try expectEqualStrings("sv", co.active.?.language);
    try expectEqual(@as(UtteranceId, 1), h.deadline.last_id);
    try expectEqual(@as(u32, 12_345), h.deadline.last_policy.final_ms);
    co.handle(.{ .deadline = .{ .id = 1, .kind = .release } });
    co.handle(.press);
    try expectEqual(@as(UtteranceId, 2), h.backends.last_id);
}

test "15 mismatched duplicate late and phase-invalid events cannot advance an Utterance" {
    var h = Harness{};
    const co = h.wire();

    co.handle(.press); // id 1, capturing
    co.handle(.{ .final = .{ .id = 1, .text = "too early" } });
    co.handle(.{ .backend_failed = 99 });
    co.handle(.{ .deadline = .{ .id = 1, .kind = .release } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    try expectEqual(@as(usize, 0), h.insertion.submits);
    try expectEqual(@as(usize, 0), h.feedback.abandoneds);

    co.handle(.release); // id 1, awaiting_final
    co.handle(.{ .final = .{ .id = 99, .text = "wrong Utterance" } });
    co.handle(.{ .deadline = .{ .id = 99, .kind = .release } });
    try expectEqual(@as(usize, 0), h.insertion.submits);
    co.handle(.{ .final = .{ .id = 1, .text = "right Utterance" } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqual(@as(UtteranceId, 1), h.insertion.last_id);

    co.handle(.{ .final = .{ .id = 1, .text = "duplicate" } });
    co.handle(.{ .deadline = .{ .id = 1, .kind = .release } });
    co.handle(.{ .inserted = .{ .id = 99, .result = .ok } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqual(@as(usize, 0), h.feedback.inserteds);
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    try expectEqual(@as(usize, 1), h.feedback.inserteds);

    co.handle(.press); // id 2
    co.handle(.{ .final = .{ .id = 1, .text = "late" } });
    co.handle(.{ .backend_failed = 1 });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqual(@as(usize, 0), h.backends.cancelled);
}

test "16 begin and release failures abandon without leaving the Coordinator busy" {
    var h = Harness{};
    h.backends.begin_result = error.BeginFailed;
    const co = h.wire();
    co.handle(.press);
    try expectEqual(@as(usize, 1), h.feedback.abandoneds);
    try expectEqual(@as(usize, 1), h.backends.cancelled);

    h.backends.begin_result = {};
    h.backends.release_result = error.ReleaseFailed;
    co.handle(.press);
    co.handle(.release);
    try expectEqual(@as(usize, 2), h.feedback.abandoneds);
    try expectEqual(@as(usize, 2), h.backends.cancelled);

    h.backends.release_result = {};
    co.handle(.press);
    try expectEqual(@as(usize, 3), h.backends.began);
}

// ---- Backtrack: the Rewrite seam (docs/backtrack-spec.md) -----------------------

test "17 backtrack happy path: final detours through the Rewrite seam, the rewrite inserts" {
    var h = Harness{};
    h.backends.backtrack = true; // pinned .openai + Backtrack on at press
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "at 20:00 no 18:00" } });
    try expectEqual(@as(usize, 1), h.rewrite.submits);
    try expectEqualStrings("at 20:00 no 18:00", h.rewrite.lastText());
    try expectEqual(@as(usize, 0), h.insertion.submits); // not inserted yet
    try expect(h.deadline.cancels == 1); // release deadline resolved by the final

    co.handle(.{ .rewritten = .{ .id = 1, .text = "At 18:00", .result = .ok } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqualStrings("At 18:00", h.insertion.lastText());

    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    try expect(h.feedback.inserteds == 1);
    try expectEqual(@as(usize, 1), h.backends.resolved);
    co.handle(.press); // fully resolved — next hold accepted
    try expect(h.backends.began == 2);
}

test "18 backtrack off, or the local backend, inserts the raw final unchanged" {
    var off = Harness{};
    const co_off = off.wire(); // .openai but backtrack off
    co_off.handle(.press);
    co_off.handle(.release);
    co_off.handle(.{ .final = .{ .id = 1, .text = "raw" } });
    try expectEqual(@as(usize, 0), off.rewrite.submits);
    try expectEqual(@as(usize, 1), off.insertion.submits);

    var local = Harness{};
    local.backends.backend_kind = .local;
    local.backends.backtrack = true; // enabled, but Backtrack never applies on local
    const co_local = local.wire();
    co_local.handle(.press);
    co_local.handle(.release);
    co_local.handle(.{ .final = .{ .id = 1, .text = "stays raw" } });
    try expectEqual(@as(usize, 0), local.rewrite.submits);
    try expectEqual(@as(usize, 1), local.insertion.submits);
    try expectEqualStrings("stays raw", local.insertion.lastText());
}

test "19 enablement is pinned at press: a mid-Utterance flip does not change the in-flight Utterance" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press); // Lease pins backtrack=true
    h.backends.backtrack = false; // settings flip mid-Utterance
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "still rewrites" } });
    try expectEqual(@as(usize, 1), h.rewrite.submits);

    // And the mirror image: off at press stays off even if enabled mid-flight.
    co.handle(.{ .rewritten = .{ .id = 1, .text = "x", .result = .ok } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    co.handle(.press); // Lease pins backtrack=false
    h.backends.backtrack = true;
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 2, .text = "raw path" } });
    try expectEqual(@as(usize, 1), h.rewrite.submits); // unchanged
    try expectEqual(@as(usize, 2), h.insertion.submits);
}

test "20 press during .rewriting is dropped (ADR-0001)" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "text" } }); // → rewriting
    co.handle(.press); // must be dropped — one Utterance resolves fully first
    try expect(h.backends.began == 1);
    try expect(h.audio.started == 1);
    co.handle(.{ .rewritten = .{ .id = 1, .text = "text", .result = .ok } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    co.handle(.press);
    try expect(h.backends.began == 2);
}

test "21 failed rewrite inserts the carried raw Final Transcript" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "um the raw one" } });
    // The worker's fallback: .failed carries the raw text back for insertion, flagged
    // degraded so the adapter reports `.degraded` and the HUD pulses amber (ADR-0004).
    co.handle(.{ .rewritten = .{ .id = 1, .text = "um the raw one", .result = .failed } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqualStrings("um the raw one", h.insertion.lastText());
    try expectEqual(InsertKind.raw_fallback, h.insertion.last_kind);
    co.handle(.{ .inserted = .{ .id = 1, .result = .degraded } });
    try expect(h.feedback.degradeds == 1); // amber pulse, not the silent hide
    try expect(h.feedback.inserteds == 0);
    try expect(h.feedback.abandoneds == 0); // no error cue — the raw text landed
}

test "21b a successful rewrite inserts un-flagged and hides silently" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "um at 20:00 no 18:00" } });
    co.handle(.{ .rewritten = .{ .id = 1, .text = "At 18:00", .result = .ok } });
    try expectEqualStrings("At 18:00", h.insertion.lastText());
    try expectEqual(InsertKind.normal, h.insertion.last_kind); // the happy path never flags a fallback
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    try expect(h.feedback.inserteds == 1); // silent success hide, no amber
    try expect(h.feedback.degradeds == 0);
}

test "22 stale mismatched or phase-invalid rewritten events cannot advance an Utterance" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    // no Utterance in flight
    co.handle(.{ .rewritten = .{ .id = 1, .text = "ghost", .result = .ok } });
    try expectEqual(@as(usize, 0), h.insertion.submits);

    co.handle(.press);
    co.handle(.{ .rewritten = .{ .id = 1, .text = "early", .result = .ok } }); // while capturing
    co.handle(.release);
    co.handle(.{ .rewritten = .{ .id = 1, .text = "before final", .result = .ok } }); // awaiting_final
    try expectEqual(@as(usize, 0), h.insertion.submits);

    co.handle(.{ .final = .{ .id = 1, .text = "raw" } }); // → rewriting
    co.handle(.{ .rewritten = .{ .id = 99, .text = "wrong Utterance", .result = .ok } });
    try expectEqual(@as(usize, 0), h.insertion.submits);
    co.handle(.{ .rewritten = .{ .id = 1, .text = "right", .result = .ok } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    co.handle(.{ .rewritten = .{ .id = 1, .text = "duplicate", .result = .ok } }); // now .inserting
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqualStrings("right", h.insertion.lastText());
}

test "23 backend failure during .rewriting is ignored (final already delivered)" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "text" } }); // → rewriting
    co.handle(.{ .backend_failed = 1 });
    try expectEqual(@as(usize, 0), h.backends.cancelled);
    try expectEqual(@as(usize, 0), h.feedback.abandoneds);
    co.handle(.{ .rewritten = .{ .id = 1, .text = "text", .result = .ok } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
}

test "24 rewrite timeout: the ~3 s budget fires during .rewriting and the raw Final Transcript inserts" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    try expectEqual(@as(usize, 1), h.deadline.arms); // release-anchored deadline
    try expectEqual(backend.DeadlineKind.release, h.deadline.last_kind);
    co.handle(.{ .final = .{ .id = 1, .text = "um at 20:00 no 18:00" } }); // → rewriting
    try expectEqual(@as(usize, 1), h.deadline.cancels); // release deadline resolved by the final
    try expectEqual(@as(usize, 2), h.deadline.arms); // rewrite budget armed at submit
    try expectEqual(backend.DeadlineKind.rewrite, h.deadline.last_kind);
    try expectEqual(rewrite_deadline.final_ms, h.deadline.last_policy.final_ms);
    try expectEqual(@as(?u32, null), h.deadline.last_policy.cooperative_cancel_ms);

    co.handle(.{ .deadline = .{ .id = 1, .kind = .rewrite } }); // budget exceeded
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqualStrings("um at 20:00 no 18:00", h.insertion.lastText());
    try expectEqual(InsertKind.raw_fallback, h.insertion.last_kind); // the timeout fallback earns the amber pulse
    try expectEqual(@as(usize, 0), h.feedback.abandoneds); // no error cue — text still lands

    // The abandoned call resolves late: stale, must not double-insert.
    co.handle(.{ .rewritten = .{ .id = 1, .text = "At 18:00", .result = .ok } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqualStrings("um at 20:00 no 18:00", h.insertion.lastText());

    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    try expect(h.feedback.inserteds == 1);
    co.handle(.press); // fully resolved — next hold accepted
    try expect(h.backends.began == 2);
}

test "25 a rewrite completing within budget disarms the rewrite deadline" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "raw" } });
    try expectEqual(@as(usize, 2), h.deadline.arms);
    co.handle(.{ .rewritten = .{ .id = 1, .text = "rewritten", .result = .ok } });
    try expectEqual(@as(usize, 2), h.deadline.cancels); // rewrite budget disarmed
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });

    // A failed completion (raw carried back) disarms it just the same.
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 2, .text = "raw two" } });
    co.handle(.{ .rewritten = .{ .id = 2, .text = "raw two", .result = .failed } });
    try expectEqual(@as(usize, 4), h.deadline.cancels);
}

test "26 a mismatched rewrite deadline during .rewriting cannot force the fallback" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "raw" } });
    co.handle(.{ .deadline = .{ .id = 99, .kind = .rewrite } });
    try expectEqual(@as(usize, 0), h.insertion.submits);
    co.handle(.{ .rewritten = .{ .id = 1, .text = "rewritten", .result = .ok } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqualStrings("rewritten", h.insertion.lastText());
}

test "27 a stale release-anchored deadline cannot fire the rewrite fallback early" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "raw" } }); // → rewriting; budget armed
    // The 15 s release deadline was claimed just before the final won the Coordinator
    // mutex: its cancel was a no-op and the stale fire arrives now, same id, tagged
    // `.release`. It bounded a wait that is over — it must not cut the budget short.
    co.handle(.{ .deadline = .{ .id = 1, .kind = .release } });
    try expectEqual(@as(usize, 0), h.insertion.submits);
    try expectEqual(@as(usize, 0), h.feedback.abandoneds);
    co.handle(.{ .rewritten = .{ .id = 1, .text = "rewritten", .result = .ok } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqualStrings("rewritten", h.insertion.lastText());
}

// ---- Recent Insertions: the write-only recorder seam (ADR-0006, spec §1–§3) ------

test "28 a completed dictation records exactly one Insertion Record with the with-space text" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "hello world" } });
    try expectEqual(@as(usize, 0), h.recorder.records); // not until the insert resolves
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    try expectEqual(@as(usize, 1), h.recorder.records);
    // `inserted` carries the single trailing space that actually hit the cursor.
    try expectEqualStrings("hello world ", h.recorder.lastInserted());
    try expectEqual(InsertResult.ok, h.recorder.last_outcome);
    try expect(!h.recorder.last_has_raw); // no Rewrite ran → raw absent
    try expect(h.recorder.last_timestamp != 0); // stamped at onInserted
}

test "29 a .failed insertion is still recorded (the primary recovery case)" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "lost text" } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .failed } });
    try expectEqual(@as(usize, 1), h.recorder.records);
    try expectEqualStrings("lost text ", h.recorder.lastInserted());
    try expectEqual(InsertResult.failed, h.recorder.last_outcome);
}

test "30 empty and abandoned Utterances are not recorded" {
    // empty Final Transcript
    var empty = Harness{};
    const co_empty = empty.wire();
    co_empty.handle(.press);
    co_empty.handle(.release);
    co_empty.handle(.{ .final = .{ .id = 1, .text = "" } });
    try expectEqual(@as(usize, 0), empty.recorder.records);

    // abandoned: no Final Transcript within the deadline
    var deadline = Harness{};
    const co_deadline = deadline.wire();
    co_deadline.handle(.press);
    co_deadline.handle(.release);
    co_deadline.handle(.{ .deadline = .{ .id = 1, .kind = .release } });
    try expectEqual(@as(usize, 0), deadline.recorder.records);

    // abandoned: backend failure mid-Utterance
    var backend_fail = Harness{};
    const co_bf = backend_fail.wire();
    co_bf.handle(.press);
    co_bf.handle(.release);
    co_bf.handle(.{ .backend_failed = 1 });
    try expectEqual(@as(usize, 0), backend_fail.recorder.records);
}

test "31 a Backtrack Utterance records the resolved text plus the pre-Rewrite raw" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "at 20:00 no 18:00" } });
    co.handle(.{ .rewritten = .{ .id = 1, .text = "At 18:00", .result = .ok } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    try expectEqual(@as(usize, 1), h.recorder.records);
    try expectEqualStrings("At 18:00 ", h.recorder.lastInserted()); // the with-space rewrite
    try expect(h.recorder.last_has_raw);
    try expectEqualStrings("at 20:00 no 18:00", h.recorder.lastRaw()); // trimmed, pre-Rewrite
    try expectEqual(InsertResult.ok, h.recorder.last_outcome);
}

test "32 a rewrite-timeout fallback is recorded degraded with the raw Final Transcript" {
    var h = Harness{};
    h.backends.backtrack = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "um the raw one" } });
    co.handle(.{ .deadline = .{ .id = 1, .kind = .rewrite } }); // budget fires → raw fallback inserts
    co.handle(.{ .inserted = .{ .id = 1, .result = .degraded } });
    try expectEqual(@as(usize, 1), h.recorder.records);
    try expectEqualStrings("um the raw one ", h.recorder.lastInserted());
    try expect(h.recorder.last_has_raw);
    try expectEqualStrings("um the raw one", h.recorder.lastRaw());
    try expectEqual(InsertResult.degraded, h.recorder.last_outcome);
}

test "33 focused_app rides the .inserted report and is stamped into the record" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "note" } });
    const app = AppIdentity.init("com.tinyspeck.slackmacgap", "Slack");
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok, .focused_app = app } });
    try expectEqual(@as(usize, 1), h.recorder.records);
    try expect(h.recorder.last_focused_app != null);
    try expectEqualStrings("com.tinyspeck.slackmacgap", h.recorder.last_focused_app.?.bundleId());
    try expectEqualStrings("Slack", h.recorder.last_focused_app.?.displayName());
}

test "34 a stale/mismatched .inserted does not record" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "text" } }); // → inserting
    co.handle(.{ .inserted = .{ .id = 99, .result = .ok } }); // wrong id
    try expectEqual(@as(usize, 0), h.recorder.records);
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } }); // the real one
    try expectEqual(@as(usize, 1), h.recorder.records);
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } }); // duplicate late edge, now idle
    try expectEqual(@as(usize, 1), h.recorder.records);
}
