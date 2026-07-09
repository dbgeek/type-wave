//! insertion_adapter.zig — asynchronous Insertion adapter for the Utterance Coordinator.
//!
//! The Coordinator's Insertion seam is intentionally tiny: submit one Final Transcript,
//! then later report `.inserted`. This module owns the adapter implementation behind that
//! seam: copy the transcript, enforce the Insertion separator invariant, read the current
//! Settings Snapshot at job execution time, run the slow macOS Insertion mechanism off the
//! Coordinator mutex, and report completion back through the reverse edge.
//!
//! `insert.zig` remains the macOS mechanism module. This module is the policy adapter
//! between the Utterance lifecycle and those mechanisms.

const std = @import("std");
const coord = @import("coordinator.zig");
const feedback = @import("feedback.zig");
const insertmod = @import("insert.zig");

fn explainInsert(e: insertmod.InsertError) []const u8 {
    return switch (e) {
        error.PostEventDenied => "no PostEvent grant — enable type-wave under System Settings > Privacy & Security > Accessibility",
    };
}

pub fn InsertionAdapter(comptime Deps: type) type {
    return struct {
        const Self = @This();

        deps: Deps,

        /// The single insert job (NUL-terminated for insert.paste's NSString). Written by
        /// `submit` before the `pending` release-store; read by the worker after acquire.
        job: [8193]u8 = undefined,
        /// When `submit` handed the job over (≈ the Final Transcript's arrival) — anchors
        /// the final→inserted split in the timing logs (issues #36–#38). Ordered across
        /// threads by the `pending` release-store / acquire-swap, like `job`.
        submitted_at_ms: i64 = 0,
        pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(deps: Deps) Self {
            return .{ .deps = deps };
        }

        /// Coordinator seam. Runs under the Coordinator's mutex; must not block. The
        /// adapter owns the Insertion invariant that every non-empty Final Transcript
        /// lands with exactly one trailing separator.
        pub fn submit(self: *Self, text: []const u8) void {
            _ = insertmod.ensureTrailingSpace(&self.job, text);
            self.submitted_at_ms = feedback.nowMs();
            self.pending.store(true, .release);
        }

        /// One worker tick. Exposed so tests can drive the adapter without spawning a
        /// thread or sleeping. Returns whether a job was drained.
        pub fn runOnce(self: *Self) bool {
            if (!self.pending.swap(false, .acquire)) return false;
            const t_pick = feedback.nowMs();

            const z: [*:0]const u8 = @ptrCast(&self.job);
            const method = self.deps.insertionMethod();
            const result: coord.InsertResult = if (self.deps.insert(method, z)) |_|
                .ok
            else |e| blk: {
                feedback.log("  insertion failed: {s}\n", .{explainInsert(e)});
                break :blk .failed;
            };
            if (result == .ok) {
                // NB: both deltas include the mechanism's post-paste settle + clipboard
                // restore — the text itself landed at the "[insert] Cmd-V posted" line.
                const now = feedback.nowMs();
                feedback.log("  inserted at the cursor (+{d}ms after the Final Transcript; mechanism {d}ms)\n", .{ now - self.submitted_at_ms, now - t_pick });
            }
            self.deps.complete(result);
            return true;
        }

        /// Process jobs until the owning daemon is quitting. Idle behavior stays with the
        /// dependency set so tests do not inherit wall-clock sleeps.
        pub fn workerLoop(self: *Self) void {
            while (!self.deps.shouldQuit()) {
                if (!self.runOnce()) self.deps.idle();
            }
        }
    };
}

const FakeDeps = struct {
    method: insertmod.Method = .paste,
    calls: usize = 0,
    last_method: insertmod.Method = .paste,
    last: [256]u8 = undefined,
    last_len: usize = 0,
    result: insertmod.InsertError!void = {},
    completions: usize = 0,
    last_completion: coord.InsertResult = .ok,
    quit: bool = false,
    idles: usize = 0,

    fn insertionMethod(self: *FakeDeps) insertmod.Method {
        return self.method;
    }

    fn insert(self: *FakeDeps, method: insertmod.Method, text: [*:0]const u8) insertmod.InsertError!void {
        self.calls += 1;
        self.last_method = method;
        const s = std.mem.span(text);
        @memcpy(self.last[0..s.len], s);
        self.last_len = s.len;
        return self.result;
    }

    fn complete(self: *FakeDeps, result: coord.InsertResult) void {
        self.completions += 1;
        self.last_completion = result;
    }

    fn shouldQuit(self: *FakeDeps) bool {
        return self.quit;
    }

    fn idle(self: *FakeDeps) void {
        self.idles += 1;
        self.quit = true;
    }

    fn lastText(self: *FakeDeps) []const u8 {
        return self.last[0..self.last_len];
    }
};

test "submit copies a Final Transcript and applies the Insertion separator" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    adapter.submit("hello");
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqualStrings("hello ", adapter.deps.lastText());
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);
    try std.testing.expectEqual(coord.InsertResult.ok, adapter.deps.last_completion);
}

test "worker reads the Settings Snapshot at job execution time" {
    var adapter = InsertionAdapter(FakeDeps).init(.{ .method = .paste });

    adapter.submit("hello");
    adapter.deps.method = .keystroke;

    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqual(insertmod.Method.keystroke, adapter.deps.last_method);
}

test "insert failure reports a failed completion" {
    var adapter = InsertionAdapter(FakeDeps).init(.{ .result = error.PostEventDenied });

    adapter.submit("hello");
    try std.testing.expect(adapter.runOnce());

    try std.testing.expectEqual(@as(usize, 1), adapter.deps.calls);
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);
    try std.testing.expectEqual(coord.InsertResult.failed, adapter.deps.last_completion);
}

test "runOnce reports idle without touching dependencies" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    try std.testing.expect(!adapter.runOnce());
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.calls);
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.completions);
}
