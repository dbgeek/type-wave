//! rewrite_adapter.zig — asynchronous Backtrack Rewrite adapter for the Utterance
//! Coordinator (docs/backtrack-spec.md).
//!
//! The Coordinator's Rewrite seam is intentionally tiny, mirroring the Insertion seam:
//! submit one raw Final Transcript, then later report `.rewritten`. This module owns the
//! adapter implementation behind that seam: copy the transcript at submit (the borrowed
//! slice is only valid during the Coordinator's `handle` call), run the slow OpenAI call
//! off the Coordinator mutex on a worker thread, and report the result back through the
//! reverse edge. On any failure — HTTP error, unusable response, empty rewrite — it
//! completes with the **raw** transcript and `.failed`, so dictation never breaks.
//!
//! A hung call is bounded by the Coordinator's ~3 s rewrite budget (spec §Pipeline): the
//! Coordinator inserts the raw transcript itself and stale-rejects this worker's late
//! completion. That means the *next* Utterance can submit a new job while the old call is
//! still in flight — so the job hand-off below copies under a lock: `submit` stages the
//! job, `takeJob` claims it into worker-local storage, and the slow call runs only on
//! that claimed copy.
//!
//! `openai_rewrite.zig` is the OpenAI Responses API mechanism module. This module is the
//! policy adapter between the Utterance lifecycle and that mechanism.

const std = @import("std");
const coord = @import("coordinator.zig");
const feedback = @import("feedback.zig");

/// Serializes the job hand-off between the Coordinator (`submit`) and the worker
/// (`takeJob`). Same os_unfair_lock choice as coordinator.zig: std.Thread.Mutex is gone
/// on this Zig nightly, and std.Io.Mutex needs an Io this adapter shouldn't carry.
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

pub fn RewriteAdapter(comptime Deps: type) type {
    return struct {
        const Self = @This();

        deps: Deps,

        /// The staged rewrite job — sized to the Transcription Session's Final
        /// Transcript accumulator (session.zig), so the whole transcript always fits
        /// (the spec sets no per-utterance cap of its own). All fields below through
        /// `pending` are guarded by `mu`: written by `submit`, claimed by `takeJob`.
        job: [8192]u8 = undefined,
        job_len: usize = 0,
        job_id: coord.UtteranceId = 0,
        /// When `submit` handed the job over (≈ the Final Transcript's arrival) —
        /// anchors the final→rewritten split in the timing logs.
        submitted_at_ms: i64 = 0,
        pending: bool = false,
        mu: Mutex = .{},

        // Worker-local (only the single worker thread touches these): the claimed job
        // the slow call runs on, immune to an overlapped `submit`, and the rewritten
        // text — the `.rewritten` reverse edge borrows `out` only for the duration of
        // `complete` (the insertion seam copies synchronously).
        work: [8192]u8 = undefined,
        work_len: usize = 0,
        work_id: coord.UtteranceId = 0,
        work_submitted_at_ms: i64 = 0,
        out: [8192]u8 = undefined,

        pub fn init(deps: Deps) Self {
            return .{ .deps = deps };
        }

        /// Coordinator seam. Runs under the Coordinator's mutex; must not block (the
        /// hand-off lock is only ever held for a memcpy).
        pub fn submit(self: *Self, id: coord.UtteranceId, text: []const u8) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.job_id = id;
            const n = @min(text.len, self.job.len);
            @memcpy(self.job[0..n], text[0..n]);
            self.job_len = n;
            self.submitted_at_ms = feedback.nowMs();
            self.pending = true;
        }

        /// Claim the staged job into worker-local storage. Returns whether there was one.
        fn takeJob(self: *Self) bool {
            self.mu.lock();
            defer self.mu.unlock();
            if (!self.pending) return false;
            self.pending = false;
            self.work_id = self.job_id;
            self.work_len = self.job_len;
            @memcpy(self.work[0..self.job_len], self.job[0..self.job_len]);
            self.work_submitted_at_ms = self.submitted_at_ms;
            return true;
        }

        /// Run the slow OpenAI call on the claimed job and report the completion.
        fn processJob(self: *Self) void {
            const t_pick = feedback.nowMs();
            const raw = self.work[0..self.work_len];
            if (self.deps.rewrite(raw, &self.out)) |rewritten| {
                if (rewritten.len == 0) {
                    // A rewrite that erased the whole Utterance is a failure, not a
                    // cleanup — the raw transcript inserts instead (spec: never lose
                    // dictation). The mechanism already rejects this; belt-and-braces.
                    feedback.log("  Backtrack rewrite came back empty — completing with the raw Final Transcript\n", .{});
                    self.deps.complete(self.work_id, raw, .failed);
                    return;
                }
                const now = feedback.nowMs();
                feedback.log("  Backtrack rewrote the Final Transcript (+{d}ms after the Final Transcript; call {d}ms)\n", .{ now - self.work_submitted_at_ms, now - t_pick });
                self.deps.complete(self.work_id, rewritten, .ok);
            } else |e| {
                // Never lose dictation: the raw Final Transcript rides the same reverse
                // edge. No error cue — text lands via the Coordinator (spec §failure
                // policy). "Completing", not "inserting": if the ~3 s budget already
                // fired, this completion is stale-rejected and nothing more inserts.
                feedback.log("  Backtrack rewrite failed: {s} — completing with the raw Final Transcript\n", .{@errorName(e)});
                self.deps.complete(self.work_id, raw, .failed);
            }
        }

        /// One worker tick. Exposed so tests can drive the adapter without spawning a
        /// thread or sleeping. Returns whether a job was drained.
        pub fn runOnce(self: *Self) bool {
            if (!self.takeJob()) return false;
            self.processJob();
            return true;
        }

        /// Process jobs until the owning daemon is quitting. Idle behavior stays with
        /// the dependency set so tests do not inherit wall-clock sleeps.
        pub fn workerLoop(self: *Self) void {
            while (!self.deps.shouldQuit()) {
                if (!self.runOnce()) self.deps.idle();
            }
        }
    };
}

const FakeDeps = struct {
    result: []const u8 = "rewritten",
    failure: ?anyerror = null,
    calls: usize = 0,
    last_raw: [256]u8 = undefined,
    last_raw_len: usize = 0,
    completions: usize = 0,
    last_completion_id: coord.UtteranceId = 0,
    last_completion: coord.RewriteResult = .ok,
    last_text: [256]u8 = undefined,
    last_text_len: usize = 0,
    quit: bool = false,
    idles: usize = 0,

    fn rewrite(self: *FakeDeps, raw: []const u8, out: []u8) anyerror![]const u8 {
        self.calls += 1;
        @memcpy(self.last_raw[0..raw.len], raw);
        self.last_raw_len = raw.len;
        if (self.failure) |e| return e;
        @memcpy(out[0..self.result.len], self.result);
        return out[0..self.result.len];
    }

    fn complete(self: *FakeDeps, id: coord.UtteranceId, text: []const u8, result: coord.RewriteResult) void {
        self.completions += 1;
        self.last_completion_id = id;
        self.last_completion = result;
        @memcpy(self.last_text[0..text.len], text);
        self.last_text_len = text.len;
    }

    fn shouldQuit(self: *FakeDeps) bool {
        return self.quit;
    }

    fn idle(self: *FakeDeps) void {
        self.idles += 1;
        self.quit = true;
    }

    fn completedText(self: *FakeDeps) []const u8 {
        return self.last_text[0..self.last_text_len];
    }
};

test "submit copies the raw Final Transcript and the worker reports the rewrite" {
    var adapter = RewriteAdapter(FakeDeps).init(.{ .result = "At 18:00" });

    var borrowed = "at 20:00 no 18:00".*;
    adapter.submit(7, &borrowed);
    borrowed[0] = 'X'; // the borrowed slice dies with the handle call — adapter copied

    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqualStrings("at 20:00 no 18:00", adapter.deps.last_raw[0..adapter.deps.last_raw_len]);
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);
    try std.testing.expectEqual(@as(coord.UtteranceId, 7), adapter.deps.last_completion_id);
    try std.testing.expectEqual(coord.RewriteResult.ok, adapter.deps.last_completion);
    try std.testing.expectEqualStrings("At 18:00", adapter.deps.completedText());
}

test "a failed rewrite completes with the raw Final Transcript and .failed" {
    var adapter = RewriteAdapter(FakeDeps).init(.{ .failure = error.RewriteHttpFailure });

    adapter.submit(9, "um the raw one");
    try std.testing.expect(adapter.runOnce());

    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);
    try std.testing.expectEqual(coord.RewriteResult.failed, adapter.deps.last_completion);
    try std.testing.expectEqualStrings("um the raw one", adapter.deps.completedText());
}

test "an empty rewrite is a failure: the raw Final Transcript inserts instead" {
    var adapter = RewriteAdapter(FakeDeps).init(.{ .result = "" });

    adapter.submit(3, "the raw one");
    try std.testing.expect(adapter.runOnce());

    try std.testing.expectEqual(coord.RewriteResult.failed, adapter.deps.last_completion);
    try std.testing.expectEqualStrings("the raw one", adapter.deps.completedText());
}

test "a submit overlapping a hung in-flight call cannot corrupt that call's job" {
    // The Coordinator's ~3 s timeout means it can move on while the worker is still
    // blocked in the OpenAI call — and the next Utterance then submits a new job.
    var adapter = RewriteAdapter(FakeDeps).init(.{ .failure = error.RewriteHttpFailure });
    adapter.submit(1, "first raw");
    try std.testing.expect(adapter.takeJob()); // worker claims the job — call now "in flight"
    adapter.submit(2, "second raw"); // Coordinator timed out; the next Utterance overlaps
    adapter.processJob(); // the hung call resolves — must complete job 1 with its own text
    try std.testing.expectEqual(@as(coord.UtteranceId, 1), adapter.deps.last_completion_id);
    try std.testing.expectEqualStrings("first raw", adapter.deps.completedText());
    try std.testing.expect(adapter.runOnce()); // the overlapped job then drains intact
    try std.testing.expectEqual(@as(coord.UtteranceId, 2), adapter.deps.last_completion_id);
    try std.testing.expectEqualStrings("second raw", adapter.deps.completedText());
}

test "runOnce reports idle without touching dependencies" {
    var adapter = RewriteAdapter(FakeDeps).init(.{});

    try std.testing.expect(!adapter.runOnce());
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.calls);
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.completions);
}

test "workerLoop drains one job then idles out" {
    var adapter = RewriteAdapter(FakeDeps).init(.{});
    adapter.submit(1, "text");
    adapter.workerLoop();
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.idles);
}
