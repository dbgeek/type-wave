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
//!     `deps.deadline` / `deps.feedback` / `deps.secure_input` by duck-typed method name. Real
//!     adapters in daemon.zig / surface.zig;
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
//!
//! # One per-Utterance fact travels the whole lifecycle (#286)
//!
//! Whether Secure Event Input was held — probed fresh at the press edge and again at the
//! release edge, sticky once set, cleared with the phase. It gates nothing about dictation;
//! it decides whether this Utterance's transcript is **retained**: a marked one is recorded
//! with no text and its words stay out of the log. It rides here rather than through the
//! insertion seam because `onInserted` runs on this same machine, so the flag is simply in
//! scope where the record is assembled.

const std = @import("std");
const feedback = @import("feedback.zig");
const backend = @import("transcription_backend.zig");

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
///
/// `.refused` is the Focused Target gate (ADR-0009 amendment): the frontmost app positively
/// changed between the Talk Key release and the paste, so the Insertion Runner placed nothing
/// rather than pasting a Final Transcript into whatever now owns the cursor. Like `.failed`
/// nothing landed — but unlike it nothing *went wrong*, so it carries the red refuse cue the
/// Runner already fires for a cursor action that did nothing, not the audible error cue.
pub const InsertResult = enum { ok, degraded, failed, refused };

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
/// `inserted` slice borrows the Insertion Runner's job buffer and `raw` a Coordinator-local
/// one; both are valid **only for the duration of the `record` call** — the daemon-owned ring
/// copies them into its own inline buffers under its leaf lock (exactly the memcpy discipline
/// the rest of the seams use). Assembled once per resolved Insertion, whatever the outcome.
pub const InsertionRecord = struct {
    /// The with-space bytes that hit the cursor (post-Rewrite when Backtrack ran, raw
    /// otherwise) — byte-identical to the insert because they *are* the insert: the Insertion
    /// Runner applies the separator and reports the bytes it landed back through the
    /// `.inserted` edge, so nothing re-derives them (ADR-0009).
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
    /// The Utterance was spoken while Secure Event Input was held (#286): the ring keeps the
    /// record but **stores none of the text**. Defaulted false because that is the reading that
    /// holds before anything marks an Utterance, and because exactly one place decides it — the
    /// Coordinator's own mark, below.
    withheld: bool = false,
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
    /// The Insert Worker's reverse edge. `focused_app` is the App Identity hint read
    /// off-mutex the moment the text landed (ADR-0006), and `inserted` is the exact
    /// with-space slice that hit the cursor — the Insertion Runner is the sole applier of
    /// the Insertion separator, so the Coordinator stamps what it is handed rather than
    /// re-deriving it (ADR-0009). Like `final`, `inserted` borrows the Runner's job buffer
    /// and is valid only for the duration of the `handle` call; the ring memcpys it
    /// synchronously. Both are defaulted so the Coordinator's own tests can omit them.
    inserted: struct { id: UtteranceId, result: InsertResult, focused_app: ?AppIdentity = null, inserted: []const u8 = "" },
};

const Phase = enum { idle, capturing, awaiting_final, rewriting, inserting };

/// Which edge's Secure Event Input reading marked an Utterance (#286) — the two the machine
/// probes at, and the two the narration can name.
pub const MarkEdge = enum { press, release };

/// The line a marked Utterance earns, once. Pure and exhaustive over both inputs so the wording
/// is asserted rather than eyeballed — the same reason `secure_input.narrate` is pure (ADR-0010),
/// applied to a module that does have test blocks but would otherwise bury four distinct
/// sentences inside a handler.
///
/// Every line says the two things that are load-bearing and neither obvious nor visible
/// elsewhere: **the condition** (Secure Event Input was held, and at which edge) and **what it
/// costs** (the transcript is not retained). The `.log_transcripts` clause is there only when the
/// opt-in is actually on: naming a suppression of something that was never going to be logged
/// would be noise, and *omitting* it while the opt-in is on would let the flag lie silently.
pub fn markLine(edge: MarkEdge, verbatim_opt_in: bool) []const u8 {
    return switch (edge) {
        .press => if (verbatim_opt_in)
            "Secure Event Input was held as this Utterance began — its transcript will not be retained in Recent Insertions, and its words stay out of the log despite .log_transcripts = true"
        else
            "Secure Event Input was held as this Utterance began — its transcript will not be retained in Recent Insertions",
        .release => if (verbatim_opt_in)
            "Secure Event Input was held as this Utterance ended — its transcript will not be retained in Recent Insertions, and its words stay out of the log despite .log_transcripts = true"
        else
            "Secure Event Input was held as this Utterance ended — its transcript will not be retained in Recent Insertions",
    };
}

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
        /// This Utterance was spoken while Secure Event Input was held (#286) — the OS's
        /// strongest available signal that a secure text field has focus somewhere, which is
        /// precisely the moment a user is most likely to dictate a secret. Set from a fresh
        /// probe at the press edge **or** at the release edge, and **sticky**: a holder that
        /// lets go a second later does not change what was probably said. Cleared with the
        /// phase, so it never outlives its Utterance.
        sensitive: bool = false,
        pub fn init(deps: Deps) Self {
            return .{ .deps = deps };
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
                .inserted => |e| self.onInserted(e.id, e.result, e.focused_app, e.inserted),
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
            // Marked here, once the Utterance is committed: a press that was rejected above
            // pays for no probe. Ahead of the `listening` cue because a Partial Transcript can
            // reach the log the moment capture is live, and the mark is what gags it (#286).
            self.mark(.press);
            self.deps.feedback.listening();
            feedback.log("  [REC] listening — release the Talk Key to insert\n", .{});
        }

        /// Fold one edge's Secure Event Input probe into the Utterance's sticky mark, narrating
        /// the moment it goes up (#286). Two edges, because the two readings answer different
        /// questions and either one is enough: *was a secure field focused when the user chose
        /// to speak*, and *was one focused by the time the words were committed*. Probed fresh
        /// rather than read off the Supervisor's published `secure_input` state, whose ~3 s
        /// facts cadence is far too coarse for a per-Utterance decision — the same freshness
        /// reason the Undo Runner probes at post time.
        ///
        /// Deliberately **not** probed at `onInserted`: ADR-0006 keeps OS reads off that handler,
        /// which is the point the next press waits on. Both edges here already do heavier work
        /// on this thread.
        fn mark(self: *Self, edge: MarkEdge) void {
            if (self.sensitive) return; // sticky: said once, held for the Utterance
            if (!self.deps.secure_input.active()) return;
            self.sensitive = true;
            // The words are presumed a secret, so they stay out of the log too — even under the
            // `.log_transcripts` opt-in, which the line below names so the debugging flag never
            // lies silently. Raised **before** the narration, so the reading `markLine` reports
            // is the one now in force.
            feedback.setTranscriptSuppression(true);
            feedback.log("  {s}\n", .{markLine(edge, feedback.transcriptsVerbatim())});
        }

        /// Drop the mark as the Utterance ends. Paired with `mark` on every exit — the resolved
        /// one and every abandon — because the log suppression it raised is process-wide state
        /// (ADR-0001 makes that sound: one Utterance at a time) and must not outlive the
        /// Utterance that earned it.
        fn unmark(self: *Self) void {
            if (!self.sensitive) return;
            self.sensitive = false;
            feedback.setTranscriptSuppression(false);
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

            // The Focused Target this Utterance was dictated into (ADR-0009 amendment). Taken
            // here — once the Utterance is committed to `.awaiting_final`, so an abandoned hold
            // never pays for it — and carried by the Insertion Runner to its own gate at paste
            // time. Deliberately *not* at `onInserted`, which ADR-0006 rules out: that read
            // would stall the machine at the point the next press is waiting on. Here nothing
            // waits — the machine is mid-Utterance and `audio.stop()` above already did far
            // more work on this same thread.
            self.deps.insertion.noteTarget();
            // The second Secure Event Input reading (#286), beside the Focused Target note for
            // the same reason: this is the edge where a cross-boundary read is affordable, and a
            // hold that went up while the user was speaking still means what a hold means.
            self.mark(.release);

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

        fn onInserted(self: *Self, id: UtteranceId, r: InsertResult, focused_app: ?AppIdentity, inserted: []const u8) void {
            if (!self.matches(id, .inserting)) return;
            // Commit the Insertion Record (ADR-0006): only Utterances that reach here are
            // recorded, which realizes §2.2's retention rule for free — and `.failed` reaches
            // here (the primary recovery case). `inserted` is the Insert Worker's own bytes,
            // reported back rather than re-derived (ADR-0009), so the record can never
            // disagree with what hit the cursor. `raw` is present only on the Backtrack detour
            // (the Lease's pinned flag), where the pre-Rewrite transcript was copied at
            // `onFinal`; a non-Backtrack `raw` would just equal `inserted`.
            self.deps.recorder.record(.{
                .inserted = inserted,
                .raw = if (self.active.?.backtrack) self.raw[0..self.raw_len] else null,
                .timestamp = feedback.nowMs(),
                .outcome = r,
                .focused_app = focused_app,
                // Whatever the outcome: a `.failed` or `.refused` Utterance spoken under a hold
                // is withheld on the same terms as a landed one — there is no text either way.
                .withheld = self.sensitive,
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
                // The Focused Target gate refused (ADR-0009 amendment). No Feedback Surface
                // verb here on purpose: the Insertion Runner already fired the red refuse cue
                // beside the refusal, the same cue every other cursor action that did nothing
                // shows (ADR-0007/ADR-0009), and that cue self-hides the pill. A second verb
                // here would either double the cue or bury it under the audible error cue,
                // which belongs to things that went *wrong*.
                .refused => feedback.log("  insertion refused — the Focused Target changed; the transcript is kept in Recent Insertions\n", .{}),
            }
            self.deps.backends.resolve(id);
            self.active = null;
            self.phase = .idle;
            self.unmark();
        }

        fn matches(self: *Self, id: UtteranceId, phase: Phase) bool {
            return self.phase == phase and self.active != null and self.active.?.id == id;
        }

        fn abandon(self: *Self) void {
            self.deps.feedback.abandoned();
            if (self.active) |lease| self.deps.backends.resolve(lease.id);
            self.active = null;
            self.phase = .idle;
            self.unmark();
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
    /// Focused Target notes taken on the release edge (ADR-0009 amendment), and how many
    /// submits had happened when the last one was taken — the Coordinator's whole share of
    /// the gate is *that it notes, once, before the Utterance can reach `submit`*.
    notes: usize = 0,
    submits_at_note: usize = 0,
    fn noteTarget(self: *FakeInsertion) void {
        self.notes += 1;
        self.submits_at_note = self.submits;
    }
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

/// The Secure Event Input probe seam (#286): one cheap in-process Carbon read in the real
/// daemon, a fed reading here. `probes` counts them, because *when* the machine probes is
/// itself the decision — at the two edges, never at `onInserted`.
const FakeSecureInput = struct {
    held: bool = false,
    probes: usize = 0,
    fn active(self: *FakeSecureInput) bool {
        self.probes += 1;
        return self.held;
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
    last_withheld: bool = false,
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
        self.last_withheld = rec.withheld;
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
    secure_input: *FakeSecureInput,
};

const Harness = struct {
    audio: FakeAudio = .{},
    backends: FakeBackends = .{},
    rewrite: FakeRewrite = .{},
    insertion: FakeInsertion = .{},
    deadline: FakeDeadline = .{},
    feedback: FakeFeedback = .{},
    recorder: FakeRecorder = .{},
    secure_input: FakeSecureInput = .{},
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
            .secure_input = &self.secure_input,
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

// --- the Focused Target note (ADR-0009 amendment) ---
// The Coordinator's whole share of the gate: it takes the note on the release edge of an
// Utterance that is going to proceed, exactly once, before anything can reach `submit`. The
// comparison itself belongs to the Insertion Runner.

test "the release edge notes the Focused Target once, before the Utterance can submit" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);

    try expectEqual(@as(usize, 1), h.insertion.notes);
    try expectEqual(@as(usize, 0), h.insertion.submits_at_note); // taken ahead of the paste

    co.handle(.{ .final = .{ .id = 1, .text = "hello" } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqual(@as(usize, 1), h.insertion.notes); // one note per Utterance, not per event
}

test "an Utterance that never reaches awaiting_final takes no note" {
    // No audio, so the hold is abandoned on the release edge. The note sits after that check
    // on purpose: a cross-process read is not worth paying for an Utterance that cannot insert.
    var h = Harness{};
    h.audio.captured = false;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);

    try expectEqual(@as(usize, 0), h.insertion.notes);
}

test "a refused Insertion is recorded and resolves silently — the Runner already cued it" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "the secret" } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .refused, .inserted = "the secret " } });

    // Recorded, so the transcript survives in Recent Insertions for a re-insert.
    try expectEqual(@as(usize, 1), h.recorder.records);
    try expectEqual(InsertResult.refused, h.recorder.last_outcome);
    try expectEqualStrings("the secret ", h.recorder.lastInserted());
    // And silent here: the red refuse cue is the Insertion Runner's, fired beside the refusal.
    // The audible error cue belongs to things that went wrong, which this did not.
    try expectEqual(@as(usize, 0), h.feedback.abandoneds);
    try expectEqual(@as(usize, 0), h.feedback.inserteds);
    try expectEqual(@as(usize, 0), h.feedback.degradeds);
    // The lease resolves and the machine is idle: a refusal ends the Utterance like any other
    // resolution, so the next press is accepted.
    try expectEqual(@as(usize, 1), h.backends.resolved);
    co.handle(.press);
    try expectEqual(@as(usize, 2), h.backends.began);
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

test "28 a completed dictation records exactly one Insertion Record with the bytes that landed" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "hello world" } });
    try expectEqual(@as(usize, 0), h.recorder.records); // not until the insert resolves
    // The Insert Worker reports the with-space bytes it actually placed; the Coordinator
    // stamps them rather than re-deriving them (ADR-0009). The separator rule itself is
    // exercised where it lives, in insertion_runner.zig.
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok, .inserted = "hello world " } });
    try expectEqual(@as(usize, 1), h.recorder.records);
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
    // The worker reports the bytes it tried to land, so a `.failed` record still holds them.
    co.handle(.{ .inserted = .{ .id = 1, .result = .failed, .inserted = "lost text " } });
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
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok, .inserted = "At 18:00 " } });
    try expectEqual(@as(usize, 1), h.recorder.records);
    try expectEqualStrings("At 18:00 ", h.recorder.lastInserted()); // the post-Rewrite bytes
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
    co.handle(.{ .inserted = .{ .id = 1, .result = .degraded, .inserted = "um the raw one " } });
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

// --- the Capture watchdog's release (#272) ---
// The watchdog does not get its own event: it feeds the ordinary `.release` the tap never
// delivered, from the supervisor thread. These two tests are the Coordinator's whole share
// of that — the synthesized edge takes the normal path, and a second one cannot double-stop
// Capture if the real edge and the watchdog land together.

test "35 a release the tap never delivered ends the hold by the ordinary path" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    // No tap release ever arrives — this one comes from the watchdog instead.
    co.handle(.release);

    try expectEqual(@as(usize, 1), h.audio.stopped); // the microphone is off, which is the point
    try expectEqual(@as(usize, 1), h.backends.released);
    try expectEqual(@as(usize, 1), h.deadline.arms);
    try expectEqual(@as(usize, 1), h.insertion.notes);
    // And it resolves as any Utterance does, rather than being discarded for its provenance.
    co.handle(.{ .final = .{ .id = 1, .text = "said before the edge was lost" } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    try expectEqual(@as(usize, 1), h.feedback.inserteds);
}

test "36 a real release racing the watchdog's cannot stop Capture twice" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.release); // the loser of the race, whichever it was

    try expectEqual(@as(usize, 1), h.audio.stopped);
    try expectEqual(@as(usize, 1), h.backends.released);
    try expectEqual(@as(usize, 1), h.feedback.releaseds);
    try expectEqual(@as(usize, 1), h.deadline.arms);
    try expectEqual(@as(usize, 1), h.insertion.notes);
}

// ---- Secure Event Input: the per-Utterance mark (#286) ----------------------------------

/// The log's process-wide redaction cells are shared with every other test in this binary, so
/// each test here saves and restores them around its own assertions.
const LogPolicy = struct {
    verbatim: bool,
    suppressed: bool,

    fn save() LogPolicy {
        return .{ .verbatim = feedback.transcriptsVerbatim(), .suppressed = feedback.transcriptsSuppressed() };
    }
    fn restore(self: LogPolicy) void {
        feedback.setLogTranscripts(self.verbatim);
        feedback.setTranscriptSuppression(self.suppressed);
    }
};

test "37 an Utterance spoken under a held Secure Event Input is recorded with its text withheld" {
    const saved = LogPolicy.save();
    defer saved.restore();

    var h = Harness{};
    h.secure_input.held = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "my bank password is hunter2" } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok, .inserted = "my bank password is hunter2 " } });

    // The record is made — the row exists and says so — and it is marked withheld. The ring is
    // what drops the bytes; the Coordinator's share is the verdict.
    try expectEqual(@as(usize, 1), h.recorder.records);
    try expect(h.recorder.last_withheld);
    // Dictation itself is untouched: the transcript still landed at the cursor.
    try expectEqual(@as(usize, 1), h.feedback.inserteds);
}

test "38 a clear flag records an ordinary, retained Insertion" {
    var h = Harness{};
    const co = h.wire(); // secure_input.held defaults false
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "hello" } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok, .inserted = "hello " } });

    try expect(!h.recorder.last_withheld);
    try expectEqualStrings("hello ", h.recorder.lastInserted());
}

test "39 the flag is probed at both edges, and the mark is sticky across a release of the hold" {
    const saved = LogPolicy.save();
    defer saved.restore();

    // Held while the user speaks, released before they let go: the words were still said under
    // it, so the mark survives — and the release edge does not un-mark.
    var press_only = Harness{};
    press_only.secure_input.held = true;
    const co1 = press_only.wire();
    co1.handle(.press);
    press_only.secure_input.held = false; // the holder let go mid-Utterance
    co1.handle(.release);
    co1.handle(.{ .final = .{ .id = 1, .text = "spoken under it" } });
    co1.handle(.{ .inserted = .{ .id = 1, .result = .ok, .inserted = "spoken under it " } });
    try expect(press_only.recorder.last_withheld);
    try expectEqual(@as(usize, 1), press_only.secure_input.probes); // sticky: no second probe

    // And the other way: clear at the press, held by the time the words were committed.
    var release_only = Harness{};
    const co2 = release_only.wire();
    co2.handle(.press);
    release_only.secure_input.held = true; // a password field took focus mid-hold
    co2.handle(.release);
    co2.handle(.{ .final = .{ .id = 1, .text = "committed under it" } });
    co2.handle(.{ .inserted = .{ .id = 1, .result = .ok, .inserted = "committed under it " } });
    try expect(release_only.recorder.last_withheld);
    try expectEqual(@as(usize, 2), release_only.secure_input.probes); // both edges paid
}

test "40 the mark is never taken at onInserted — the point the next press waits on (ADR-0006)" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "text" } });
    const before = h.secure_input.probes;
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok, .inserted = "text " } });
    try expectEqual(before, h.secure_input.probes);
}

test "41 a rejected press pays for no probe at all" {
    // The overlap guard and the not-ready backend both return before the Utterance exists.
    var busy = Harness{};
    const co_busy = busy.wire();
    co_busy.handle(.press);
    const after_first = busy.secure_input.probes;
    co_busy.handle(.press); // dropped: the previous Utterance is still resolving
    try expectEqual(after_first, busy.secure_input.probes);

    var unavailable = Harness{};
    unavailable.backends.avail = false;
    const co_unavail = unavailable.wire();
    co_unavail.handle(.press);
    try expectEqual(@as(usize, 0), unavailable.secure_input.probes);
}

test "42 a marked Utterance gags verbatim transcript logging, and only for its own lifetime" {
    const saved = LogPolicy.save();
    defer saved.restore();
    feedback.setLogTranscripts(true); // the operator's hand-edited debugging opt-in

    var h = Harness{};
    h.secure_input.held = true;
    const co = h.wire();
    try expect(feedback.logTranscripts()); // verbatim before the Utterance…

    co.handle(.press);
    try expect(!feedback.logTranscripts()); // …redacted from the mark, while Partials flow…
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "secret" } });
    try expect(!feedback.logTranscripts()); // …including the Final Transcript…

    co.handle(.{ .inserted = .{ .id = 1, .result = .ok, .inserted = "secret " } });
    try expect(feedback.logTranscripts()); // …and the opt-in resumes once it resolves
    try expect(feedback.transcriptsVerbatim()); // never clobbered, only overridden
}

test "43 an abandoned marked Utterance drops the suppression too" {
    const saved = LogPolicy.save();
    defer saved.restore();
    feedback.setLogTranscripts(true);

    // Every route out of a marked Utterance must clear it, or the suppression outlives its
    // Utterance and silently redacts the next one.
    var poisoned = Harness{};
    poisoned.secure_input.held = true;
    const co1 = poisoned.wire();
    co1.handle(.press);
    co1.handle(.{ .backend_failed = 1 }); // poisons the in-flight Utterance
    co1.handle(.release); // → discarded whole
    try expect(feedback.logTranscripts());

    var empty = Harness{};
    empty.secure_input.held = true;
    const co2 = empty.wire();
    co2.handle(.press);
    co2.handle(.release);
    co2.handle(.{ .final = .{ .id = 1, .text = "" } }); // empty transcript → abandon
    try expect(feedback.logTranscripts());

    var no_audio = Harness{};
    no_audio.secure_input.held = true;
    no_audio.audio.captured = false;
    const co3 = no_audio.wire();
    co3.handle(.press);
    co3.handle(.release); // nothing to insert → abandon
    try expect(feedback.logTranscripts());
}

test "44 a marked Utterance is withheld whatever its outcome" {
    const saved = LogPolicy.save();
    defer saved.restore();

    for ([_]InsertResult{ .ok, .degraded, .failed, .refused }) |outcome| {
        var h = Harness{};
        h.secure_input.held = true;
        h.backends.backtrack = true; // so `.degraded` is reachable with a raw fallback
        const co = h.wire();
        co.handle(.press);
        co.handle(.release);
        co.handle(.{ .final = .{ .id = 1, .text = "secret" } });
        co.handle(.{ .rewritten = .{ .id = 1, .text = "secret", .result = .ok } });
        co.handle(.{ .inserted = .{ .id = 1, .result = outcome, .inserted = "secret " } });
        try expectEqual(@as(usize, 1), h.recorder.records);
        try expect(h.recorder.last_withheld);
        // The Backtrack detour's `raw` rides the record as always; withholding is the ring's
        // job, and it drops both forms.
        try expect(h.recorder.last_has_raw);
    }
}

test "45 the next Utterance after a marked one is not marked by inheritance" {
    const saved = LogPolicy.save();
    defer saved.restore();

    var h = Harness{};
    h.secure_input.held = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 1, .text = "secret" } });
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok, .inserted = "secret " } });
    try expect(h.recorder.last_withheld);

    h.secure_input.held = false; // the hold cleared between Utterances
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = .{ .id = 2, .text = "ordinary" } });
    co.handle(.{ .inserted = .{ .id = 2, .result = .ok, .inserted = "ordinary " } });
    try expect(!h.recorder.last_withheld);
    try expectEqual(@as(usize, 2), h.recorder.records);
}

test "46 every mark line names the condition, the edge, and what it costs" {
    for ([_]MarkEdge{ .press, .release }) |edge| {
        for ([_]bool{ false, true }) |verbatim| {
            const line = markLine(edge, verbatim);
            // The condition, so the reader knows which of the two secure-input stories this is.
            try expect(std.mem.indexOf(u8, line, "Secure Event Input was held") != null);
            // The cost: the one thing a user cannot infer from anything else they will see.
            try expect(std.mem.indexOf(u8, line, "not be retained") != null);
            // The edge, because the two answer different questions about what was said.
            try expect(std.mem.indexOf(u8, line, switch (edge) {
                .press => "began",
                .release => "ended",
            }) != null);
            // And the opt-in clause exactly when the opt-in is on: a debugging flag that is
            // being overridden has to say so, and one that is off has nothing to say.
            try expectEqual(verbatim, std.mem.indexOf(u8, line, ".log_transcripts") != null);
        }
    }
    // The two edges are distinguishable, in both wordings — a single shared line would lose the
    // difference between "a secure field had focus when they chose to speak" and "one had it by
    // the time the words were committed".
    for ([_]bool{ false, true }) |verbatim|
        try expect(!std.mem.eql(u8, markLine(.press, verbatim), markLine(.release, verbatim)));
}
