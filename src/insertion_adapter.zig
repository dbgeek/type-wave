//! insertion_adapter.zig — asynchronous Insertion adapter for the Utterance Coordinator.
//!
//! The Coordinator's Insertion seam is intentionally tiny: submit one Final Transcript,
//! then later report `.inserted`. This module owns the adapter implementation behind that
//! seam: copy the transcript, enforce the Insertion separator invariant, read the current
//! Settings Snapshot at job execution time, run the slow macOS Insertion mechanism off the
//! Coordinator mutex, and report completion back through the reverse edge — *before*
//! draining the mechanism's deferred clipboard restore, so the restore window never pads
//! the Coordinator's `.inserting` lockout (issue #38).
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

        /// One job slot's byte buffer: the Coordinator's 8192-byte transcript window plus a
        /// NUL terminator for insert.paste's NSString. Shared by both slots below.
        const job_buf_len = 8193;

        deps: Deps,

        /// The single insert job (NUL-terminated for insert.paste's NSString). Written by
        /// `submit` before the `pending` release-store; read by the worker after acquire.
        job: [job_buf_len]u8 = undefined,
        job_id: coord.UtteranceId = 0,
        /// Which text this job carries (docs/backtrack-spec.md §UX 4): a `.raw_fallback`
        /// job that inserts cleanly reports `.degraded` instead of `.ok`, so the HUD pulses
        /// amber (ADR-0004). Set by `submit`, read by the worker — ordered across threads by
        /// `pending` like `job`.
        job_kind: coord.InsertKind = .normal,
        /// When `submit` handed the job over (≈ the Final Transcript's arrival) — anchors
        /// the final→inserted split in the timing logs (issues #36–#38). Ordered across
        /// threads by the `pending` release-store / acquire-swap, like `job`.
        submitted_at_ms: i64 = 0,
        pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        /// A second, **Coordinator-less** job slot (recent-insertions spec §5, issue #194).
        /// Re-insert / Copy dispatch a verbatim replay through here carrying no Utterance
        /// identity — no overlap guard, no release-anchored deadline, no poison abandonment,
        /// and no reverse edge into the Coordinator (so it never reaches `onInserted` / the
        /// ring). It rides the *same* single worker as `job`, which is what serializes it
        /// against dictation inserts: the worker drains at most one job per tick, so a bypass
        /// replay can never interleave with a live Utterance's `job` / `pending` state or the
        /// clipboard-swap dance. A dedicated slot (not `job`) so the two producers — the
        /// Coordinator under its mutex, the menu off the main thread — never clobber each
        /// other. NUL-terminated for insert's NSString, ordered across threads by
        /// `bypass_pending` exactly like `job` by `pending`.
        bypass_job: [job_buf_len]u8 = undefined,
        bypass_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        /// A third, **clipboard-copy** job slot (recent-insertions spec §5.2, issue #197). The
        /// menu's per-entry Copy dispatches the trimmed `inserted` text through here so the
        /// permanent, non-transient pasteboard write runs on this same single worker — the
        /// serialization that lets it drain any pending deferred Insertion restore without
        /// racing a live dictation insert (§5.2.7). Like `bypass_job` it carries no Utterance
        /// identity and never reports back. A dedicated slot (not `job` / `bypass_job`) so the
        /// menu producer never clobbers a Coordinator or a replay job. NUL-terminated for the
        /// pasteboard NSString, ordered across threads by `copy_pending` exactly like `job` by
        /// `pending`.
        copy_job: [job_buf_len]u8 = undefined,
        copy_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(deps: Deps) Self {
            return .{ .deps = deps };
        }

        /// Coordinator seam. Runs under the Coordinator's mutex; must not block. The
        /// adapter owns the Insertion invariant that every non-empty Final Transcript
        /// lands with exactly one trailing separator.
        pub fn submit(self: *Self, id: coord.UtteranceId, text: []const u8, kind: coord.InsertKind) void {
            self.job_id = id;
            self.job_kind = kind;
            _ = insertmod.ensureTrailingSpace(&self.job, text);
            self.submitted_at_ms = feedback.nowMs();
            self.pending.store(true, .release);
        }

        /// Coordinator-less seam (recent-insertions spec §5, issue #194). Hands the worker a
        /// verbatim replay of already-final bytes — the shared seam the menu's Re-insert /
        /// Copy actions dispatch through. Unlike `submit` it carries no `UtteranceId`: the
        /// worker inserts the bytes and never reports back, so a replay is never a Final
        /// Transcript and never records to the ring (§5.1.4). `inserted` rows already carry
        /// their single trailing space, so `ensureTrailingSpace` is an idempotent no-op here
        /// (§5.1.3); it also guarantees the NUL terminator the worker's NSString cast needs.
        /// Runs off the menu thread; the caller must not submit while a bypass job is still
        /// pending (mirrors `submit`'s single-producer contract).
        pub fn submitBypass(self: *Self, text: []const u8) void {
            _ = insertmod.ensureTrailingSpace(&self.bypass_job, text);
            self.bypass_pending.store(true, .release);
        }

        /// Clipboard-copy seam (recent-insertions spec §5.2, issue #197). Hands the worker the
        /// exact bytes to put on the clipboard — the caller (`daemon.menuCopy`) has already
        /// resolved the entry against the ring and stripped the single trailing Insertion space
        /// (§5.2.6), so this stores `text` **verbatim** (no `ensureTrailingSpace`) and only adds
        /// the NUL terminator the pasteboard NSString cast needs. Runs off the menu thread; the
        /// caller must not submit while a copy job is still pending (mirrors `submit`'s
        /// single-producer contract). An over-long `text` is capped to the job buffer.
        pub fn submitCopy(self: *Self, text: []const u8) void {
            const n = @min(text.len, self.copy_job.len - 1);
            @memcpy(self.copy_job[0..n], text[0..n]);
            self.copy_job[n] = 0;
            self.copy_pending.store(true, .release);
        }

        /// One worker tick. Exposed so tests can drive the adapter without spawning a
        /// thread or sleeping. Returns whether a job was drained. Dictation jobs take
        /// priority (time-sensitive); the Coordinator-less replay defers to them and, being
        /// drained on the same single thread, can never run concurrently with one.
        pub fn runOnce(self: *Self) bool {
            if (self.pending.swap(false, .acquire)) {
                self.runInsertion();
                return true;
            }
            if (self.bypass_pending.swap(false, .acquire)) {
                self.runBypass();
                return true;
            }
            if (self.copy_pending.swap(false, .acquire)) {
                self.runCopy();
                return true;
            }
            return false;
        }

        /// Drain the one pending dictation job: insert it, report `.inserted` back into the
        /// Coordinator (which records the Insertion Record), then drain the deferred restore.
        fn runInsertion(self: *Self) void {
            const t_pick = feedback.nowMs();

            const z: [*:0]const u8 = @ptrCast(&self.job);
            const plan = self.deps.insertionPlan();
            // A successful insert of a rewrite-fallback job is `.degraded`, not `.ok`: the
            // raw text landed, but the downgrade earns the amber HUD pulse (ADR-0004). An
            // insert that *fails* is `.failed` regardless — nothing landed at the cursor.
            const result: coord.InsertResult = if (self.deps.insert(plan, z)) |_|
                (if (self.job_kind == .raw_fallback) .degraded else .ok)
            else |e| blk: {
                feedback.log("  insertion failed: {s}\n", .{explainInsert(e)});
                break :blk .failed;
            };
            if (result != .failed) {
                const now = feedback.nowMs();
                const note = if (result == .degraded) " [raw fallback]" else "";
                feedback.log("  inserted at the cursor (+{d}ms after the Final Transcript; mechanism {d}ms){s}\n", .{ now - self.submitted_at_ms, now - t_pick, note });
            }
            // App Identity hint for the Insertion Record (ADR-0006 §3.3): read off-mutex here,
            // the moment the text landed — never under coordinator.mu — and carried back
            // through the `.inserted` report. Best-effort; a null just leaves the hint empty.
            const focused_app = self.deps.focusedApp();
            // Report completion *before* the deferred clipboard restore (issue #38): the
            // Coordinator leaves `.inserting` at the Cmd-V settle, so the ~300 ms restore
            // pads this worker's time, not the lockout. Serialization is the ordering
            // guard — the restore finishes before this loop can drain the next job, so a
            // following paste never interleaves with a pending restore.
            self.deps.complete(self.job_id, result, focused_app);
            self.deps.finishInsert();
        }

        /// Drain the one pending Coordinator-less job (spec §5): insert the stored bytes
        /// verbatim, then drain the deferred restore on the worker — same clipboard-swap
        /// discipline as a dictation insert, which is what lets a following Copy drain
        /// safely without racing this one (§5.2.7). Deliberately **no** `complete` /
        /// `focusedApp`: a replay carries no Utterance identity, so it never reaches
        /// `onInserted` and never writes the ring, on success or failure (§5.1.4). A failed
        /// replay is silent but for the log — it is not a dictation, so it earns no `.failed`
        /// record.
        fn runBypass(self: *Self) void {
            const t_pick = feedback.nowMs();
            const z: [*:0]const u8 = @ptrCast(&self.bypass_job);
            const plan = self.deps.insertionPlan();
            if (self.deps.insert(plan, z)) |_| {
                feedback.log("  re-inserted at the cursor (mechanism {d}ms)\n", .{feedback.nowMs() - t_pick});
            } else |e| {
                feedback.log("  re-insertion failed: {s}\n", .{explainInsert(e)});
            }
            self.deps.finishInsert();
        }

        /// Drain the one pending clipboard-copy job (spec §5.2): **drain any deferred Insertion
        /// restore first** (`finishInsert` — the same drain the dictation path runs, a no-op
        /// once the worker already drained the prior job) so a late restore can't clobber the
        /// copy, then write the stored bytes to the clipboard as a permanent, non-transient
        /// entry. No `complete` / `focusedApp`: a Copy carries no Utterance identity, so it never
        /// reaches `onInserted` and never writes the ring — the pasteboard write is its only
        /// effect. Running on this worker is what lets the drain happen without racing an insert.
        fn runCopy(self: *Self) void {
            self.deps.finishInsert();
            const z: [*:0]const u8 = @ptrCast(&self.copy_job);
            self.deps.copyToClipboard(z);
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
    plan: insertmod.Plan = .{},
    calls: usize = 0,
    last_plan: insertmod.Plan = .{},
    last: [256]u8 = undefined,
    last_len: usize = 0,
    result: insertmod.InsertError!void = {},
    completions: usize = 0,
    last_completion_id: coord.UtteranceId = 0,
    last_completion: coord.InsertResult = .ok,
    last_focused_app: ?coord.AppIdentity = null,
    focused_app: ?coord.AppIdentity = null,
    finishes: usize = 0,
    completions_at_finish: usize = 0,
    copies: usize = 0,
    last_copy: [256]u8 = undefined,
    last_copy_len: usize = 0,
    /// `finishes` seen at the moment `copyToClipboard` ran — proves the drain preceded the
    /// write (spec §5.2.7: the copy drains any deferred restore before it writes).
    finishes_at_copy: usize = 0,
    quit: bool = false,
    idles: usize = 0,

    fn insertionPlan(self: *FakeDeps) insertmod.Plan {
        return self.plan;
    }

    fn insert(self: *FakeDeps, plan: insertmod.Plan, text: [*:0]const u8) insertmod.InsertError!void {
        self.calls += 1;
        self.last_plan = plan;
        const s = std.mem.span(text);
        @memcpy(self.last[0..s.len], s);
        self.last_len = s.len;
        return self.result;
    }

    fn complete(self: *FakeDeps, id: coord.UtteranceId, result: coord.InsertResult, focused_app: ?coord.AppIdentity) void {
        self.completions += 1;
        self.last_completion_id = id;
        self.last_completion = result;
        self.last_focused_app = focused_app;
    }

    fn focusedApp(self: *FakeDeps) ?coord.AppIdentity {
        return self.focused_app;
    }

    fn finishInsert(self: *FakeDeps) void {
        self.finishes += 1;
        self.completions_at_finish = self.completions;
    }

    fn copyToClipboard(self: *FakeDeps, text: [*:0]const u8) void {
        self.copies += 1;
        self.finishes_at_copy = self.finishes;
        const s = std.mem.span(text);
        @memcpy(self.last_copy[0..s.len], s);
        self.last_copy_len = s.len;
    }

    fn lastCopy(self: *FakeDeps) []const u8 {
        return self.last_copy[0..self.last_copy_len];
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

    adapter.submit(7, "hello", .normal);
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqualStrings("hello ", adapter.deps.lastText());
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);
    try std.testing.expectEqual(@as(coord.UtteranceId, 7), adapter.deps.last_completion_id);
    try std.testing.expectEqual(coord.InsertResult.ok, adapter.deps.last_completion);
}

test "a degraded submit that inserts cleanly reports .degraded (ADR-0004)" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    // The raw-transcript fallback: the text still lands, but flagged degraded.
    adapter.submit(7, "um the raw one", .raw_fallback);
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqualStrings("um the raw one ", adapter.deps.lastText());
    try std.testing.expectEqual(coord.InsertResult.degraded, adapter.deps.last_completion);
}

test "a degraded submit whose insert fails is still .failed" {
    var adapter = InsertionAdapter(FakeDeps).init(.{ .result = error.PostEventDenied });

    // Nothing landed at the cursor — a hard failure outranks the degraded flag.
    adapter.submit(7, "um the raw one", .raw_fallback);
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqual(coord.InsertResult.failed, adapter.deps.last_completion);
}

test "a fresh submit clears the degraded flag of a prior job" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    adapter.submit(7, "raw", .raw_fallback);
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqual(coord.InsertResult.degraded, adapter.deps.last_completion);

    // The next, normal insertion must not inherit the previous job's degraded flag.
    adapter.submit(8, "clean", .normal);
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqual(coord.InsertResult.ok, adapter.deps.last_completion);
}

test "worker reads the Settings Snapshot at job execution time" {
    var adapter = InsertionAdapter(FakeDeps).init(.{ .plan = .{ .method = .paste } });

    adapter.submit(7, "hello", .normal);
    adapter.deps.plan = .{ .method = .keystroke, .pre_paste_ms = 40 };

    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqual(insertmod.Method.keystroke, adapter.deps.last_plan.method);
    try std.testing.expectEqual(@as(u32, 40), adapter.deps.last_plan.pre_paste_ms);
}

test "insert failure reports a failed completion" {
    var adapter = InsertionAdapter(FakeDeps).init(.{ .result = error.PostEventDenied });

    adapter.submit(7, "hello", .normal);
    try std.testing.expect(adapter.runOnce());

    try std.testing.expectEqual(@as(usize, 1), adapter.deps.calls);
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);
    try std.testing.expectEqual(coord.InsertResult.failed, adapter.deps.last_completion);
    // Deferred cleanup still runs on the failure path (a no-op when nothing is pending).
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.finishes);
}

test "completion is reported before the deferred clipboard restore (issue #38)" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    adapter.submit(7, "hello", .normal);
    try std.testing.expect(adapter.runOnce());

    // The Coordinator must leave `.inserting` before the ~300 ms restore runs, so the
    // restore pads worker time — not the lockout. Worker serialization is the ordering
    // guard: runOnce finishes the restore before it can drain the next job.
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.finishes);
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions_at_finish);
}

test "the worker captures the focused app and carries it into the completion (ADR-0006)" {
    var adapter = InsertionAdapter(FakeDeps).init(.{
        .focused_app = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack"),
    });

    adapter.submit(7, "hello", .normal);
    try std.testing.expect(adapter.runOnce());
    try std.testing.expect(adapter.deps.last_focused_app != null);
    try std.testing.expectEqualStrings("Slack", adapter.deps.last_focused_app.?.displayName());
    try std.testing.expectEqualStrings("com.tinyspeck.slackmacgap", adapter.deps.last_focused_app.?.bundleId());
}

test "a null focused app carries through as a null hint" {
    var adapter = InsertionAdapter(FakeDeps).init(.{}); // focused_app defaults to null

    adapter.submit(7, "hello", .normal);
    try std.testing.expect(adapter.runOnce());
    try std.testing.expect(adapter.deps.last_focused_app == null);
}

test "runOnce reports idle without touching dependencies" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    try std.testing.expect(!adapter.runOnce());
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.calls);
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.completions);
}

// --- Coordinator-less (bypass) jobs — recent-insertions spec §5, issue #194 ---

test "a bypass job inserts verbatim and never reports back to the Coordinator" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    // Stored `inserted` bytes already carry their trailing space; the seam replays them.
    adapter.submitBypass("recovered text ");
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqualStrings("recovered text ", adapter.deps.lastText());
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.calls);
    // No Utterance identity: nothing reaches onInserted / the ring (spec §5.1.4).
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.completions);
    // The deferred clipboard restore is still drained on the worker (spec §5.2.7).
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.finishes);
}

test "a bypass job applies the trailing-space invariant idempotently" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    // A row stored without its space still lands with exactly one; a row that already
    // has one is unchanged (spec §5.1.3 — ensureTrailingSpace is a no-op there).
    adapter.submitBypass("no space");
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqualStrings("no space ", adapter.deps.lastText());
}

test "a failed bypass insert stays silent — no completion, restore still drained" {
    var adapter = InsertionAdapter(FakeDeps).init(.{ .result = error.PostEventDenied });

    adapter.submitBypass("recovered ");
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.calls);
    // A failed re-insert produces no `.failed` record — it is not a dictation (spec §5.1.4).
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.completions);
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.finishes);
}

test "a bypass job is serialized against — never clobbers — a pending dictation job" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    // Both sources hand off before the worker runs; the separate slots must not clobber.
    adapter.submit(7, "dictation", .normal);
    adapter.submitBypass("replay ");

    // The dictation job drains first, faithfully, and reports to the Coordinator.
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqualStrings("dictation ", adapter.deps.lastText());
    try std.testing.expectEqual(@as(coord.UtteranceId, 7), adapter.deps.last_completion_id);
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);

    // The bypass job drains on the next tick — serialized, never interleaved, no report.
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqualStrings("replay ", adapter.deps.lastText());
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);

    try std.testing.expect(!adapter.runOnce());
}

// --- Clipboard-copy (Copy) jobs — recent-insertions spec §5.2, issue #197 ---

test "a copy job writes the exact bytes to the clipboard and never reports back" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    // The caller has already resolved + trimmed the row; the seam copies it verbatim.
    adapter.submitCopy("At 18:00");
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.copies);
    try std.testing.expectEqualStrings("At 18:00", adapter.deps.lastCopy());
    // A Copy carries no Utterance identity: nothing reaches onInserted / the ring, and it is
    // not an insert (spec §5.2 — the pasteboard write is its only effect).
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.completions);
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.calls);
}

test "a copy job drains any deferred Insertion restore before it writes (spec §5.2.7)" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    adapter.submitCopy("recovered");
    try std.testing.expect(adapter.runOnce());
    // The drain (finishInsert) must run, and must precede the pasteboard write so a late
    // restore can't clobber the copy: finishes was already 1 when copyToClipboard ran.
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.finishes);
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.finishes_at_copy);
}

test "a copy job is serialized against — never clobbers — a pending dictation job" {
    var adapter = InsertionAdapter(FakeDeps).init(.{});

    // Both sources hand off before the worker runs; the separate slots must not clobber.
    adapter.submit(7, "dictation", .normal);
    adapter.submitCopy("copied");

    // The dictation job drains first, faithfully, and reports to the Coordinator.
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqualStrings("dictation ", adapter.deps.lastText());
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);
    try std.testing.expectEqual(@as(usize, 0), adapter.deps.copies);

    // The copy job drains on the next tick — serialized, never interleaved, no report.
    try std.testing.expect(adapter.runOnce());
    try std.testing.expectEqualStrings("copied", adapter.deps.lastCopy());
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.copies);
    try std.testing.expectEqual(@as(usize, 1), adapter.deps.completions);

    try std.testing.expect(!adapter.runOnce());
}
