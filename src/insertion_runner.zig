//! insertion_runner.zig — the **Insertion Runner**: the daemon's one route from a Final
//! Transcript or a Recent Insertions action to bytes at the cursor (ADR-0009).
//!
//! Four things reach the cursor in this daemon: a dictation Insertion, a Re-insert, a Copy,
//! and an Undo's Backspaces. This module owns the first three end to end and sets the
//! priority for the fourth. Its rule, generalized from ADR-0008's Undo path to all of them:
//!
//!   **every cursor job resolves at drain time, on the Insert Worker, beside the effect it
//!   authorizes — and any ring bookkeeping flips only after that effect landed.**
//!
//! For a dictation job that means copying the transcript, applying the Insertion separator,
//! reading the Settings Snapshot at execution time, running the slow macOS mechanism off the
//! Coordinator mutex, and reporting the **landed bytes** back through the reverse edge —
//! *before* draining the mechanism's deferred clipboard restore, so the restore window never
//! pads the Coordinator's `.inserting` lockout (issue #38). Because those bytes ride the
//! reverse edge, this module is the *sole* applier of the separator: the Coordinator no
//! longer re-derives them for the Insertion Record, so there is one rule in one place.
//!
//! For a menu job it means the slot carries a **capture stamp, not bytes**. The record is
//! resolved from the ring on the worker, the separator is applied (Re-insert) or stripped
//! (Copy) here, and `clearUndone` — the redo edge (#225) — flips only after a replay
//! actually posted. Resolving at click time is what let a *failed* replay un-dim a record
//! whose text never came back: the same defect class ADR-0008 removed from the Undo path.
//!
//! The two menu jobs share one bounded queue because they share one producer (the main
//! thread) and one consumer (this worker), which makes the single-producer contract
//! structural rather than prose — a second click inside a ~300 ms drain now queues instead
//! of silently overwriting the first.
//!
//! The Ring is held concretely, for the reason `undo.zig` states: it is heap-free and
//! test-constructible, so faking it would mean re-implementing eviction and stamp-keying
//! rather than exercising them. `insert.zig` remains the macOS mechanism module; this module
//! is the policy owner between the Utterance lifecycle, the menu, and those mechanisms.

const std = @import("std");
const coord = @import("coordinator.zig");
const feedback = @import("feedback.zig");
const insertmod = @import("insert.zig");
const recent_insertions = @import("recent_insertions.zig");

fn explainInsert(e: insertmod.InsertError) []const u8 {
    return switch (e) {
        error.PostEventDenied => "no PostEvent grant — enable type-wave under System Settings > Privacy & Security > Accessibility",
    };
}

/// Which cursor effect a queued menu job carries. Both resolve the same way — one stamp
/// against the ring at drain time — and differ only in what they do with the bytes.
pub const MenuAction = enum { copy, reinsert };

/// One queued Recent Insertions action: 9 bytes, where the old byte-slice slots were 8193
/// each. The stamp is the record's stable capture `timestamp`, the same identity the ring's
/// `textForStamp` / `clearUndone` and the menu's reveal state key on.
const MenuJob = struct { action: MenuAction, stamp: i64 };

/// The Insertion Runner's dependency seam: everything the OS and the Coordinator own.
/// Asserted by name here and invoked by the Runner itself below, so a production adapter can
/// never skip the check.
pub fn assertDeps(comptime Deps: type) void {
    const required = [_][]const u8{
        "insertionPlan", "insert",         "complete", "focusedApp",
        "finishInsert",  "copyToClipboard", "actionRefused", "shouldQuit",
        "idle",
    };
    inline for (required) |name| {
        if (!@hasDecl(Deps, name))
            @compileError("type '" ++ @typeName(Deps) ++ "' is not Insertion Runner Deps: missing method '" ++ name ++ "'");
    }
}

pub fn InsertionRunner(comptime Deps: type) type {
    assertDeps(Deps);
    return struct {
        const Self = @This();

        /// One job slot's byte buffer: the Coordinator's 8192-byte transcript window plus a
        /// NUL terminator for insert.paste's NSString.
        const job_buf_len = 8193;

        /// How many un-drained menu actions the queue holds. A Copy's pasteboard write and a
        /// Re-insert's paste each take a few hundred milliseconds, so a user clicking through
        /// several rows in a row must not lose clicks; beyond this depth the extra clicks are
        /// refused with a cue rather than silently dropped.
        pub const menu_queue_depth = 4;

        /// The authoritative Recent Insertions ring (ADR-0006). Held concretely, not behind
        /// `Deps`, exactly as the Undo Runner holds it: the Runner only drives it — resolve a
        /// stamp, clear a flag — and its own leaf lock is taken and released inside each call.
        ring: *recent_insertions.Ring,
        deps: Deps,

        /// The single insert job (NUL-terminated for insert.paste's NSString). Written by
        /// `submit` before the `pending` release-store; read by the worker after acquire.
        job: [job_buf_len]u8 = undefined,
        /// How many bytes of `job` the separator rule produced — the exact slice that hits the
        /// cursor, and what the reverse edge hands back for the Insertion Record so the
        /// Coordinator never re-derives it (ADR-0009).
        job_len: usize = 0,
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

        /// The **Coordinator-less** menu queue (recent-insertions spec §5/§5.2, issues
        /// #194/#197; ADR-0009). Re-insert and Copy both ride here carrying no Utterance
        /// identity — no overlap guard, no release-anchored deadline, no poison abandonment,
        /// and no reverse edge into the Coordinator (so neither reaches `onInserted`, and
        /// neither pushes a ring entry). They ride the *same* single worker as `job`, which is
        /// what serializes them against dictation: the worker drains at most one job per tick,
        /// so a replay or a pasteboard write can never interleave with a live Utterance's
        /// clipboard-swap dance.
        ///
        /// A single-producer / single-consumer ring, not a slot: the producer is always the
        /// main thread (both are menu actions, and Re-insert is deferred until the menu
        /// closes) and the consumer is always this worker, so `head` is written only by the
        /// producer and `tail` only by the consumer. That makes the single-producer contract
        /// **structural** — a second click inside a still-draining job queues behind it
        /// instead of overwriting it, which is what the two byte-slice slots used to do
        /// silently. `head`'s release-store publishes the slot the same way `pending` does.
        menu_jobs: [menu_queue_depth]MenuJob = undefined,
        menu_head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        menu_tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init(ring: *recent_insertions.Ring, deps: Deps) Self {
            return .{ .ring = ring, .deps = deps };
        }

        /// Coordinator seam. Runs under the Coordinator's mutex; must not block. The
        /// adapter owns the Insertion invariant that every non-empty Final Transcript
        /// lands with exactly one trailing separator.
        pub fn submit(self: *Self, id: coord.UtteranceId, text: []const u8, kind: coord.InsertKind) void {
            self.job_id = id;
            self.job_kind = kind;
            // The one application of the Insertion separator (ADR-0009). The length is kept
            // because these exact bytes ride the reverse edge into the Insertion Record.
            self.job_len = insertmod.ensureTrailingSpace(&self.job, text).len;
            self.submitted_at_ms = feedback.nowMs();
            self.pending.store(true, .release);
        }

        /// The Recent Insertions seam (spec §5/§5.2, ADR-0009): queue one menu action against
        /// the record with capture `stamp`. Runs on the main thread and does no ring read, no
        /// memcpy of transcript bytes and no resolution — the worker does all of it at drain
        /// time. A full queue refuses with a cue rather than dropping the click silently.
        pub fn submitMenu(self: *Self, action: MenuAction, stamp: i64) void {
            const head = self.menu_head.load(.monotonic); // producer-owned; only we write it
            if (head - self.menu_tail.load(.acquire) >= menu_queue_depth) {
                feedback.log("  {s}: the Insert Worker is still draining {d} queued actions — refused\n", .{ @tagName(action), menu_queue_depth });
                self.deps.actionRefused();
                return;
            }
            self.menu_jobs[head % menu_queue_depth] = .{ .action = action, .stamp = stamp };
            self.menu_head.store(head + 1, .release); // publishes the slot, like `pending`
        }

        /// Take the oldest queued menu action, or null when the queue is empty. Consumer side:
        /// only the worker writes `tail`.
        fn nextMenuJob(self: *Self) ?MenuJob {
            const tail = self.menu_tail.load(.monotonic); // consumer-owned; only we write it
            if (self.menu_head.load(.acquire) == tail) return null;
            const job = self.menu_jobs[tail % menu_queue_depth];
            self.menu_tail.store(tail + 1, .release);
            return job;
        }

        /// One worker tick. Exposed so tests can drive the Runner without spawning a thread or
        /// sleeping. Returns whether a job was drained. Dictation takes priority (it is
        /// time-sensitive); menu actions defer to it and, being drained on the same single
        /// thread, can never run concurrently with one. The Undo Runner (undo.zig) is drained
        /// after all of these by `workerLoop` below.
        pub fn runOnce(self: *Self) bool {
            if (self.pending.swap(false, .acquire)) {
                self.runInsertion();
                return true;
            }
            if (self.nextMenuJob()) |job| {
                self.runMenuJob(job);
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
            //
            // The landed bytes ride along (ADR-0009): they are what the Insertion Record
            // must hold, and this module is the only one that knows them. The slice borrows
            // `self.job` and is valid for the duration of the call — the same discipline
            // `coord.InsertionRecord` documents for its own slices; the Coordinator memcpys
            // into the ring before returning.
            self.deps.complete(self.job_id, result, focused_app, self.job[0..self.job_len]);
            self.deps.finishInsert();
        }

        /// Drain one queued Recent Insertions action (ADR-0009). Resolution happens **here**,
        /// on the worker, beside the effect it authorizes: the record's bytes come out of one
        /// hold of the ring's leaf lock immediately before they are used, so nothing acts on a
        /// record that went away in the meantime. A stamp that no longer resolves — evicted
        /// since the menu's projection was taken — is a refusal, not a silent no-op: the click
        /// happened and earns a verdict.
        fn runMenuJob(self: *Self, job: MenuJob) void {
            var resolved: [recent_insertions.max_bytes]u8 = undefined;
            const n = self.ring.textForStamp(job.stamp, &resolved);
            if (n == 0) {
                feedback.log("  {s}: the Insertion Record was evicted — nothing to do\n", .{@tagName(job.action)});
                self.deps.actionRefused();
                return;
            }
            switch (job.action) {
                .copy => self.runCopy(resolved[0..n]),
                .reinsert => self.runReinsert(job.stamp, resolved[0..n]),
            }
        }

        /// Re-insert one record's text at the frontmost cursor (spec §5.1): the stored bytes
        /// land **verbatim**, trailing separator and all, never re-running Backtrack
        /// (§5.1.2/3), so the row lands identically to the original dictation. No `complete` /
        /// `focusedApp`: a replay carries no Utterance identity, so it never reaches
        /// `onInserted` and never pushes a ring entry, on success or failure (§5.1.4).
        fn runReinsert(self: *Self, stamp: i64, inserted: []const u8) void {
            var out: [job_buf_len]u8 = undefined;
            // A stored row already carries its single separator — this module is the sole
            // applier — so this is the documented no-op of §5.1.3. It runs anyway because it
            // is also what lays down the NUL terminator the NSString cast needs.
            _ = insertmod.ensureTrailingSpace(&out, inserted);
            const t_pick = feedback.nowMs();
            const plan = self.deps.insertionPlan();
            if (self.deps.insert(plan, @ptrCast(&out))) |_| {
                feedback.log("  re-inserted at the cursor (mechanism {d}ms)\n", .{feedback.nowMs() - t_pick});
                // The redo edge (#225), flipped **after** the post — the ADR-0008 rule, now
                // covering this path too (ADR-0009). Flipping it at click time was what let a
                // failed replay stop a row rendering dimmed with nothing restored. A no-op on
                // an entry that was never undone.
                self.ring.clearUndone(stamp);
            } else |e| {
                feedback.log("  re-insertion failed: {s}\n", .{explainInsert(e)});
                self.deps.actionRefused();
            }
            self.deps.finishInsert();
        }

        /// Copy one record's text to the clipboard (spec §5.2): **drain any deferred Insertion
        /// restore first** (`finishInsert` — a no-op once the worker already drained the prior
        /// job) so a late restore can't clobber the copy, then write the bytes as a permanent,
        /// non-transient pasteboard entry. The single trailing Insertion separator is stripped
        /// (§5.2.6): Copy yields the text the row shows, not the with-space bytes that hit the
        /// cursor. No `complete` / `focusedApp` — the pasteboard write is its only effect.
        fn runCopy(self: *Self, inserted: []const u8) void {
            self.deps.finishInsert();
            const trimmed = insertmod.stripTrailingSpace(inserted);
            var out: [job_buf_len]u8 = undefined;
            @memcpy(out[0..trimmed.len], trimmed);
            out[trimmed.len] = 0; // the pasteboard NSString cast needs it
            self.deps.copyToClipboard(@ptrCast(&out));
        }

        /// Process jobs until the owning daemon is quitting. Idle behavior stays with the
        /// dependency set so tests do not inherit wall-clock sleeps.
        ///
        /// `undo` is the **Undo Runner** (undo.zig), duck-typed on `runOnce() bool` and
        /// drained on this same single worker — the **Insert Worker**, whose single-threadedness
        /// is exactly what serializes a deletion against dictation. Undo goes **last**: an
        /// Insertion is time-sensitive and its clipboard-swap dance must never interleave with
        /// posted Backspaces, whereas an Undo waiting one more tick is imperceptible. The Undo
        /// Runner owns the deletion policy end to end (ADR-0008); this loop owns only the
        /// priority — dictation, then queued menu actions, then Undo.
        pub fn workerLoop(self: *Self, undo: anytype) void {
            while (!self.deps.shouldQuit()) {
                if (self.runOnce()) continue;
                if (undo.runOnce()) continue;
                self.deps.idle();
            }
        }
    };
}


// ============================================================================
// Tests — the four cursor paths against a real Ring and a fake OS, including the joins
// that were unreachable while resolution happened on the producer's thread (ADR-0009).
// ============================================================================

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
    /// The landed bytes the reverse edge carried — what the Insertion Record is built from
    /// now that this module is the sole applier of the separator (ADR-0009).
    last_inserted: [256]u8 = undefined,
    last_inserted_len: usize = 0,
    focused_app: ?coord.AppIdentity = null,
    /// How many times the worker read the frontmost app — lets the gate tests prove the
    /// read is fresh and skipped when nothing would post (#224).
    focus_reads: usize = 0,
    finishes: usize = 0,
    completions_at_finish: usize = 0,
    copies: usize = 0,
    last_copy: [256]u8 = undefined,
    last_copy_len: usize = 0,
    /// `finishes` seen at the moment `copyToClipboard` ran — proves the drain preceded the
    /// write (spec §5.2.7: the copy drains any deferred restore before it writes).
    finishes_at_copy: usize = 0,
    /// Refusals surfaced to the user: a failed replay, an evicted stamp, a full queue.
    refuses: usize = 0,
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

    fn complete(self: *FakeDeps, id: coord.UtteranceId, result: coord.InsertResult, focused_app: ?coord.AppIdentity, inserted: []const u8) void {
        self.completions += 1;
        self.last_completion_id = id;
        self.last_completion = result;
        self.last_focused_app = focused_app;
        @memcpy(self.last_inserted[0..inserted.len], inserted);
        self.last_inserted_len = inserted.len;
    }

    fn focusedApp(self: *FakeDeps) ?coord.AppIdentity {
        self.focus_reads += 1;
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

    fn actionRefused(self: *FakeDeps) void {
        self.refuses += 1;
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

    fn lastCopy(self: *FakeDeps) []const u8 {
        return self.last_copy[0..self.last_copy_len];
    }

    fn lastInserted(self: *FakeDeps) []const u8 {
        return self.last_inserted[0..self.last_inserted_len];
    }
};

const Runner = InsertionRunner(FakeDeps);

const slack = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack");

/// One stored Insertion Record, as the Coordinator would have committed it — with-space
/// bytes, since this module is what applied the separator on the way to the cursor.
fn rec(text: []const u8, stamp: i64) coord.InsertionRecord {
    return .{ .inserted = text, .raw = null, .timestamp = stamp, .outcome = .ok, .focused_app = slack };
}

// --- dictation jobs -----------------------------------------------------------------

test "submit copies a Final Transcript and applies the Insertion separator" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    runner.submit(7, "hello", .normal);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("hello ", runner.deps.lastText());
    try std.testing.expectEqual(@as(usize, 1), runner.deps.completions);
    try std.testing.expectEqual(@as(coord.UtteranceId, 7), runner.deps.last_completion_id);
    try std.testing.expectEqual(coord.InsertResult.ok, runner.deps.last_completion);
}

test "the reverse edge carries the landed bytes, separator included (ADR-0009)" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    // The Coordinator no longer re-derives these — it records exactly what came back, so
    // the Insertion Record can never disagree with what hit the cursor.
    runner.submit(7, "hello", .normal);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("hello ", runner.deps.lastInserted());
    try std.testing.expectEqualStrings(runner.deps.lastText(), runner.deps.lastInserted());
}

test "a failed insert still reports the bytes it tried to land" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{ .result = error.PostEventDenied });

    // `.failed` records are kept (ADR-0006 §2.2 — the primary recovery case), so the edge
    // must carry the text on this path too.
    runner.submit(7, "hello", .normal);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqual(coord.InsertResult.failed, runner.deps.last_completion);
    try std.testing.expectEqualStrings("hello ", runner.deps.lastInserted());
}

test "a degraded submit that inserts cleanly reports .degraded (ADR-0004)" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    // The raw-transcript fallback: the text still lands, but flagged degraded.
    runner.submit(7, "um the raw one", .raw_fallback);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("um the raw one ", runner.deps.lastText());
    try std.testing.expectEqual(coord.InsertResult.degraded, runner.deps.last_completion);
}

test "a degraded submit whose insert fails is still .failed" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{ .result = error.PostEventDenied });

    // Nothing landed at the cursor — a hard failure outranks the degraded flag.
    runner.submit(7, "um the raw one", .raw_fallback);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqual(coord.InsertResult.failed, runner.deps.last_completion);
}

test "a fresh submit clears the degraded flag of a prior job" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    runner.submit(7, "raw", .raw_fallback);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqual(coord.InsertResult.degraded, runner.deps.last_completion);

    // The next, normal insertion must not inherit the previous job's degraded flag.
    runner.submit(8, "clean", .normal);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqual(coord.InsertResult.ok, runner.deps.last_completion);
}

test "worker reads the Settings Snapshot at job execution time" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{ .plan = .{ .method = .paste } });

    runner.submit(7, "hello", .normal);
    runner.deps.plan = .{ .method = .keystroke, .pre_paste_ms = 40 };

    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqual(insertmod.Method.keystroke, runner.deps.last_plan.method);
    try std.testing.expectEqual(@as(u32, 40), runner.deps.last_plan.pre_paste_ms);
}

test "insert failure reports a failed completion" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{ .result = error.PostEventDenied });

    runner.submit(7, "hello", .normal);
    try std.testing.expect(runner.runOnce());

    try std.testing.expectEqual(@as(usize, 1), runner.deps.calls);
    try std.testing.expectEqual(@as(usize, 1), runner.deps.completions);
    try std.testing.expectEqual(coord.InsertResult.failed, runner.deps.last_completion);
    // Deferred cleanup still runs on the failure path (a no-op when nothing is pending).
    try std.testing.expectEqual(@as(usize, 1), runner.deps.finishes);
    // A dictation failure is reported through the Coordinator, which fires the error cue —
    // it does not also take the menu path's refuse cue.
    try std.testing.expectEqual(@as(usize, 0), runner.deps.refuses);
}

test "completion is reported before the deferred clipboard restore (issue #38)" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    runner.submit(7, "hello", .normal);
    try std.testing.expect(runner.runOnce());

    // The Coordinator must leave `.inserting` before the ~300 ms restore runs, so the
    // restore pads worker time — not the lockout. Worker serialization is the ordering
    // guard: runOnce finishes the restore before it can drain the next job.
    try std.testing.expectEqual(@as(usize, 1), runner.deps.finishes);
    try std.testing.expectEqual(@as(usize, 1), runner.deps.completions_at_finish);
}

test "the worker captures the focused app and carries it into the completion (ADR-0006)" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.submit(7, "hello", .normal);
    try std.testing.expect(runner.runOnce());
    try std.testing.expect(runner.deps.last_focused_app != null);
    try std.testing.expectEqualStrings("Slack", runner.deps.last_focused_app.?.displayName());
    try std.testing.expectEqualStrings("com.tinyspeck.slackmacgap", runner.deps.last_focused_app.?.bundleId());
}

test "a null focused app carries through as a null hint" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{}); // focused_app defaults to null

    runner.submit(7, "hello", .normal);
    try std.testing.expect(runner.runOnce());
    try std.testing.expect(runner.deps.last_focused_app == null);
}

test "runOnce reports idle without touching dependencies" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    try std.testing.expect(!runner.runOnce());
    try std.testing.expectEqual(@as(usize, 0), runner.deps.calls);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.completions);
}

// --- menu jobs: resolution happens on the worker (ADR-0009) --------------------------

test "a queued Re-insert resolves its stamp at drain time and lands the bytes verbatim" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("recovered text ", 42));
    var runner = Runner.init(&ring, .{});

    runner.submitMenu(.reinsert, 42);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("recovered text ", runner.deps.lastText());
    // No Utterance identity: nothing reaches onInserted / the ring (spec §5.1.4).
    try std.testing.expectEqual(@as(usize, 0), runner.deps.completions);
    // The deferred clipboard restore is still drained on the worker (spec §5.2.7).
    try std.testing.expectEqual(@as(usize, 1), runner.deps.finishes);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.refuses);
}

test "a queued Copy resolves its stamp and strips the single Insertion separator (§5.2.6)" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("At 18:00 ", 42));
    var runner = Runner.init(&ring, .{});

    runner.submitMenu(.copy, 42);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqual(@as(usize, 1), runner.deps.copies);
    // Copy yields the text the row shows, not the with-space bytes that hit the cursor.
    try std.testing.expectEqualStrings("At 18:00", runner.deps.lastCopy());
    // A Copy is not an insert and carries no Utterance identity.
    try std.testing.expectEqual(@as(usize, 0), runner.deps.completions);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.calls);
}

test "a copy job drains any deferred Insertion restore before it writes (spec §5.2.7)" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("recovered ", 42));
    var runner = Runner.init(&ring, .{});

    runner.submitMenu(.copy, 42);
    try std.testing.expect(runner.runOnce());
    // The drain (finishInsert) must run, and must precede the pasteboard write so a late
    // restore can't clobber the copy: finishes was already 1 when copyToClipboard ran.
    try std.testing.expectEqual(@as(usize, 1), runner.deps.finishes);
    try std.testing.expectEqual(@as(usize, 1), runner.deps.finishes_at_copy);
}

test "a successful re-insert clears the undone flag — the redo edge (#225)" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("undone text ", 42));
    ring.markUndone(42);
    var runner = Runner.init(&ring, .{});

    runner.submitMenu(.reinsert, 42);
    try std.testing.expect(runner.runOnce());

    // The text came back, so the row stops rendering dimmed.
    var buf: [recent_insertions.max_bytes]u8 = undefined;
    const target = ring.newestForUndo(&buf).?;
    try std.testing.expect(!target.undone);
}

test "a FAILED re-insert leaves the record undone" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("undone text ", 42));
    ring.markUndone(42);
    var runner = Runner.init(&ring, .{ .result = error.PostEventDenied });

    runner.submitMenu(.reinsert, 42);
    try std.testing.expect(runner.runOnce());

    // The join ADR-0009 exists for: the flag flips only *after* a replay posted, so nothing
    // can un-dim a record whose text never came back. Flipping it at submit time — on the
    // producer's thread, before the worker ran — is what made this reachable.
    var buf: [recent_insertions.max_bytes]u8 = undefined;
    const target = ring.newestForUndo(&buf).?;
    try std.testing.expect(target.undone);
    // And the click earns a verdict rather than vanishing.
    try std.testing.expectEqual(@as(usize, 1), runner.deps.refuses);
}

test "an evicted stamp refuses with a cue and touches nothing" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("still here ", 42));
    var runner = Runner.init(&ring, .{});

    // The projection the menu acted on named a record that has since been evicted.
    runner.submitMenu(.reinsert, 999);
    try std.testing.expect(runner.runOnce());
    runner.submitMenu(.copy, 999);
    try std.testing.expect(runner.runOnce());

    try std.testing.expectEqual(@as(usize, 0), runner.deps.calls);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.copies);
    try std.testing.expectEqual(@as(usize, 2), runner.deps.refuses);
}

test "a re-insert resolves the record as it stands at drain time, not at click time" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("original ", 42));
    var runner = Runner.init(&ring, .{});

    runner.submitMenu(.reinsert, 42);
    // A dictation Insertion lands between the click and the drain, evicting nothing but
    // shifting the ring. Resolution is keyed by the stable stamp, so the queued action
    // still finds its own record rather than a neighbour's.
    ring.record(rec("newer dictation ", 43));

    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("original ", runner.deps.lastText());
}

// --- the menu queue: one producer, one consumer, no silent drops ----------------------

test "two clicks inside one drain both land, in order" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("first ", 10));
    ring.record(rec("second ", 20));
    var runner = Runner.init(&ring, .{});

    // The defect the queue removes: the second submit used to memcpy over the first slot
    // in place, so the first click vanished with no cue.
    runner.submitMenu(.copy, 10);
    runner.submitMenu(.copy, 20);

    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("first", runner.deps.lastCopy());
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("second", runner.deps.lastCopy());

    try std.testing.expectEqual(@as(usize, 2), runner.deps.copies);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.refuses);
    try std.testing.expect(!runner.runOnce());
}

test "the queue mixes actions and keeps click order" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("text ", 10));
    var runner = Runner.init(&ring, .{});

    runner.submitMenu(.copy, 10);
    runner.submitMenu(.reinsert, 10);

    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqual(@as(usize, 1), runner.deps.copies);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.calls);

    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqual(@as(usize, 1), runner.deps.calls);
    try std.testing.expectEqualStrings("text ", runner.deps.lastText());
}

test "a full queue refuses the extra click instead of dropping it silently" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("text ", 10));
    var runner = Runner.init(&ring, .{});

    var i: usize = 0;
    while (i < Runner.menu_queue_depth) : (i += 1) runner.submitMenu(.copy, 10);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.refuses);

    runner.submitMenu(.copy, 10); // one too many
    try std.testing.expectEqual(@as(usize, 1), runner.deps.refuses);

    // The queued ones are unharmed — the overflow is refused, not the backlog.
    i = 0;
    while (i < Runner.menu_queue_depth) : (i += 1) try std.testing.expect(runner.runOnce());
    try std.testing.expect(!runner.runOnce());
    try std.testing.expectEqual(@as(usize, Runner.menu_queue_depth), runner.deps.copies);
}

test "the queue wraps: draining frees a slot for the next click" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("text ", 10));
    var runner = Runner.init(&ring, .{});

    // Fill, drain one, refill — the modular indices must not strand a slot.
    var i: usize = 0;
    while (i < Runner.menu_queue_depth) : (i += 1) runner.submitMenu(.copy, 10);
    try std.testing.expect(runner.runOnce());
    runner.submitMenu(.copy, 10);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.refuses);

    i = 0;
    while (i < Runner.menu_queue_depth) : (i += 1) try std.testing.expect(runner.runOnce());
    try std.testing.expect(!runner.runOnce());
    try std.testing.expectEqual(@as(usize, Runner.menu_queue_depth + 1), runner.deps.copies);
}

test "a menu job is serialized against — never clobbers — a pending dictation job" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("replay ", 10));
    var runner = Runner.init(&ring, .{});

    // Both producers hand off before the worker runs; the dictation slot and the menu
    // queue must not clobber each other.
    runner.submit(7, "dictation", .normal);
    runner.submitMenu(.reinsert, 10);

    // The dictation job drains first, faithfully, and reports to the Coordinator.
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("dictation ", runner.deps.lastText());
    try std.testing.expectEqual(@as(coord.UtteranceId, 7), runner.deps.last_completion_id);
    try std.testing.expectEqual(@as(usize, 1), runner.deps.completions);

    // The menu job drains on the next tick — serialized, never interleaved, no report.
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("replay ", runner.deps.lastText());
    try std.testing.expectEqual(@as(usize, 1), runner.deps.completions);

    try std.testing.expect(!runner.runOnce());
}

// --- Worker priority: the Undo Runner drains last (ADR-0008) ---

/// A stand-in for the Undo Runner (undo.zig) on the Insert Worker: duck-typed on `runOnce`,
/// and it records how many insert-side jobs had already drained when its turn came.
const FakeUndo = struct {
    queued: usize = 0,
    runs: usize = 0,
    inserts_at_run: usize = 0,
    deps: *FakeDeps,

    fn runOnce(self: *FakeUndo) bool {
        if (self.queued == 0) return false;
        self.queued -= 1;
        self.runs += 1;
        self.inserts_at_run = self.deps.calls;
        return true;
    }
};

test "the worker drains every insert-side job before the Undo Runner, and never interleaves" {
    // The one piece of Undo behaviour that stays the Insert Worker's: priority. A deletion
    // must not land between an Insertion's paste and its deferred clipboard restore, so the
    // Undo Runner is drained only once the dictation slot and the menu queue are empty.
    // Everything past this line — resolution, the focus gate, the undone flag, the cues —
    // belongs to undo.zig.
    var ring = recent_insertions.Ring{};
    ring.record(rec("replay ", 10));
    var runner = Runner.init(&ring, .{});
    var undo = FakeUndo{ .deps = &runner.deps, .queued = 1 };

    runner.submit(7, "dictation", .normal);
    runner.submitMenu(.reinsert, 10);
    runner.submitMenu(.copy, 10);

    // FakeDeps.idle flips `quit`, so the loop runs until every slot is empty and then stops.
    runner.workerLoop(&undo);

    try std.testing.expectEqual(@as(usize, 1), runner.deps.completions);
    try std.testing.expectEqual(@as(usize, 2), runner.deps.calls); // dictation + replay
    try std.testing.expectEqual(@as(usize, 1), runner.deps.copies);
    // The Undo ran, and only after every insert-side job had drained.
    try std.testing.expectEqual(@as(usize, 1), undo.runs);
    try std.testing.expectEqual(@as(usize, 2), undo.inserts_at_run);
    try std.testing.expectEqual(@as(usize, 0), undo.queued);
}

test "an idle worker with nothing queued on either side idles once and stops" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});
    var undo = FakeUndo{ .deps = &runner.deps };

    runner.workerLoop(&undo);

    try std.testing.expectEqual(@as(usize, 1), runner.deps.idles);
    try std.testing.expectEqual(@as(usize, 0), undo.runs);
}
