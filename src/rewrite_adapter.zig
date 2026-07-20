//! rewrite_adapter.zig — asynchronous Backtrack Rewrite adapter for the Utterance
//! Coordinator (docs/backtrack-spec.md).
//!
//! The Coordinator's Rewrite seam is intentionally tiny, mirroring the Insertion seam:
//! submit one raw Final Transcript, then later report `.rewritten`. This module owns the
//! adapter implementation behind that seam: copy the transcript at submit (the borrowed
//! slice is only valid during the Coordinator's `handle` call), run the slow OpenAI call
//! off the Coordinator mutex on a worker thread, and report the result back through the
//! reverse edge. On any failure — HTTP error, unusable response, empty rewrite — it
//! completes with the **raw** transcript and `.failed`, so dictation never breaks; the
//! ~3 s timeout that bounds a hung call is the follow-on ticket (spec §Pipeline).
//!
//! `openai_rewrite.zig` is the OpenAI Responses API mechanism module. This module is the
//! policy adapter between the Utterance lifecycle and that mechanism.

const std = @import("std");
const coord = @import("coordinator.zig");
const feedback = @import("feedback.zig");

pub fn RewriteAdapter(comptime Deps: type) type {
    return struct {
        const Self = @This();

        deps: Deps,

        /// The single rewrite job — sized to the Transcription Session's Final
        /// Transcript accumulator (session.zig), so the whole transcript always fits
        /// (the spec sets no per-utterance cap of its own). Written by `submit` before
        /// the `pending` release-store; read by the worker after acquire.
        job: [8192]u8 = undefined,
        job_len: usize = 0,
        job_id: coord.UtteranceId = 0,
        /// When `submit` handed the job over (≈ the Final Transcript's arrival) —
        /// anchors the final→rewritten split in the timing logs. Ordered across threads
        /// by the `pending` release-store / acquire-swap, like `job`.
        submitted_at_ms: i64 = 0,
        /// The rewritten text; the `.rewritten` reverse edge borrows it only for the
        /// duration of `complete` (the insertion seam copies synchronously).
        out: [8192]u8 = undefined,
        pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(deps: Deps) Self {
            return .{ .deps = deps };
        }

        /// Coordinator seam. Runs under the Coordinator's mutex; must not block.
        pub fn submit(self: *Self, id: coord.UtteranceId, text: []const u8) void {
            self.job_id = id;
            const n = @min(text.len, self.job.len);
            @memcpy(self.job[0..n], text[0..n]);
            self.job_len = n;
            self.submitted_at_ms = feedback.nowMs();
            self.pending.store(true, .release);
        }

        /// One worker tick. Exposed so tests can drive the adapter without spawning a
        /// thread or sleeping. Returns whether a job was drained.
        pub fn runOnce(self: *Self) bool {
            if (!self.pending.swap(false, .acquire)) return false;
            const t_pick = feedback.nowMs();

            const raw = self.job[0..self.job_len];
            if (self.deps.rewrite(raw, &self.out)) |rewritten| {
                if (rewritten.len == 0) {
                    // A rewrite that erased the whole Utterance is a failure, not a
                    // cleanup — the raw transcript inserts instead (spec: never lose
                    // dictation). The mechanism already rejects this; belt-and-braces.
                    feedback.log("  Backtrack rewrite came back empty — inserting the raw Final Transcript\n", .{});
                    self.deps.complete(self.job_id, raw, .failed);
                    return true;
                }
                const now = feedback.nowMs();
                feedback.log("  Backtrack rewrote the Final Transcript (+{d}ms after the Final Transcript; call {d}ms)\n", .{ now - self.submitted_at_ms, now - t_pick });
                self.deps.complete(self.job_id, rewritten, .ok);
            } else |e| {
                // Never lose dictation: the raw Final Transcript rides the same reverse
                // edge. No error cue — text IS inserted (spec §failure policy).
                feedback.log("  Backtrack rewrite failed: {s} — inserting the raw Final Transcript\n", .{@errorName(e)});
                self.deps.complete(self.job_id, raw, .failed);
            }
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
