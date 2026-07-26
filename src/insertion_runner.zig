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
//! A dictation job additionally **proves its Focused Target**. The Coordinator notes the
//! frontmost app when the Talk Key is released (`noteTarget`); this module re-reads it at
//! drain time, immediately before the paste, and refuses when it has positively changed —
//! the Undo Runner's gate, applied to the additive path that runs on every Utterance and
//! whose window (transcription latency plus the whole Rewrite budget) is the *longer* of the
//! two. It differs from Undo in exactly one way, and deliberately: see `targetChange`.
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

/// Positive evidence that the Focused Target moved: both readings existed and they differ.
/// Returned rather than reduced to a bool so the refusal's log has both identities without
/// re-unwrapping optionals the predicate has already checked.
const TargetChange = struct { from: coord.AppIdentity, to: coord.AppIdentity };

/// The **Focused Target gate** (ADR-0009 amendment): did the frontmost app at paste time
/// positively change from the one the Utterance was dictated into? `expected` is the reading
/// `noteTarget` took at Talk Key release; `fresh` the one taken immediately before the paste.
/// Null means insert.
///
/// The comparison is the Undo Runner's, byte for byte — bundle id **and** display name, the
/// strictest rule #213 offers. **Which way it fails when a reading is missing is not.** Undo
/// deletes, so a missing reading on either side refuses (`undo.evaluate` returns
/// `.focus_null`). An Insertion is additive and is the entire purpose of the app, so absence
/// is treated as consent: refusing on an unreadable frontmost would break dictation outright
/// on the first app that does not report cleanly, which is far worse than the rare
/// mis-target. **Only positive evidence of a change refuses.** The asymmetry is deliberate —
/// if this ever reads as an oversight, read `undo.evaluate` beside it.
fn targetChange(expected: ?coord.AppIdentity, fresh: ?coord.AppIdentity) ?TargetChange {
    const e = expected orelse return null; // no baseline — insert
    const f = fresh orelse return null; // nothing to compare against — insert
    if (std.mem.eql(u8, e.bundleId(), f.bundleId()) and
        std.mem.eql(u8, e.displayName(), f.displayName())) return null;
    return .{ .from = e, .to = f };
}

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
        /// The Focused Target this Utterance was dictated into: the frontmost app as
        /// `noteTarget` read it at Talk Key release, compared against a fresh reading at paste
        /// time by `targetChange`. Null means no reading — which inserts, per that
        /// predicate's fail-open rule.
        ///
        /// One note per submit, always: the Coordinator takes it on the release edge of the
        /// same Utterance that later submits, and ADR-0001's fully-serialized lifecycle means
        /// no second Utterance can interleave. Written before `submit`, so the same `pending`
        /// release-store / acquire-swap that publishes `job` publishes this too — it needs no
        /// synchronization of its own.
        target: ?coord.AppIdentity = null,
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

        /// Coordinator seam, called on the Talk Key release edge: capture the Focused Target
        /// this Utterance is being dictated into (ADR-0009 amendment). One cross-process
        /// `frontmost()` read, on the tap's run-loop thread under the Coordinator's mutex —
        /// the only point in the lifecycle where that is affordable, and the Coordinator
        /// documents why at the call site. Best-effort: a null reading simply leaves the gate
        /// with no baseline, which inserts.
        pub fn noteTarget(self: *Self) void {
            self.target = self.deps.focusedApp();
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

        /// Drain the one pending dictation job: prove the Focused Target, insert it, report
        /// `.inserted` back into the Coordinator (which records the Insertion Record), then
        /// drain the deferred restore.
        fn runInsertion(self: *Self) void {
            const t_pick = feedback.nowMs();

            // The Focused Target gate (ADR-0009 amendment). Fresh, cross-process, and taken
            // *before* the paste — the one placement that can actually stop bytes from
            // landing, where the pre-amendment read happened after and was only ever a
            // receipt. It doubles as the Insertion Record's App Identity hint below, so the
            // gate costs no extra query: on the insert path it is what the text landed in,
            // proven rather than guessed.
            const fresh = self.deps.focusedApp();
            const expected = self.target;
            self.target = null; // one note, one job — never gate a later job on a stale one
            if (targetChange(expected, fresh)) |change| {
                feedback.log(
                    "  insertion refused: the Focused Target changed since the Talk Key was released ({s} → {s}) — nothing pasted; re-insert it from Recent Insertions\n",
                    .{ change.from.displayName(), change.to.displayName() },
                );
                // The same red bloom + shake every cursor action that did nothing shows
                // (ADR-0007/ADR-0009) — the Coordinator adds no second verb for `.refused`.
                self.deps.actionRefused();
                // Reported like any other resolution so the Utterance leaves `.inserting` and
                // the transcript is retained: a `.refused` record is kept exactly as a
                // `.failed` one is (ADR-0006 §2.2, the recovery case), which is what makes the
                // refusal recoverable from Recent Insertions. `expected` is the hint, not
                // `fresh` — the record names the app the Utterance was dictated into, and
                // claiming the app that stole focus would be a plain lie about text that never
                // went there.
                self.deps.complete(self.job_id, .refused, expected, self.job[0..self.job_len]);
                // A no-op unless a *prior* job left a restore pending; kept for the same
                // reason `runCopy` drains first.
                self.deps.finishInsert();
                return;
            }

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
            // App Identity hint for the Insertion Record (ADR-0006 §3.3): the gate's own fresh
            // reading, taken off-mutex on this worker a moment *before* the text landed rather
            // than after it. Reusing it is what keeps the drain at one cross-process query
            // instead of two, and it is the stronger hint — the paste is gated on it, where
            // the post-paste read was a guess taken after the fact. `expected` covers the case
            // where the gate had a baseline but the fresh read came back null (absence is
            // consent, so the paste went ahead; the release-time reading is still the best
            // name for where it went).
            const focused_app = fresh orelse expected;
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
                // Either the record was evicted since the menu's projection was taken, or it is
                // a withheld one that never held text (#286) — the menu shows those actions
                // disabled, so this arm is the floor under that rather than the gate, and it
                // must not claim an eviction it did not observe.
                feedback.log("  {s}: no text is available for that Insertion Record — nothing to do\n", .{@tagName(job.action)});
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
        /// **This loop never returns owing a deferred clipboard restore** (#273). Every drain
        /// path — the insert, the refusal, the Re-insert, the Copy — calls `finishInsert`
        /// before it returns, and `shouldQuit` is polled only *between* iterations, so a quit
        /// raised at any point during a job still leaves the restore run by the time the loop
        /// exits. That invariant is what makes joining this thread at shutdown sufficient to
        /// keep a Final Transcript off the general pasteboard: the daemon waits for the loop,
        /// not for a flush API, because there is nothing left to flush once it comes around.
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
    /// Raise the quit flag from *inside* the mechanism — the SIGTERM/menu-Quit interleaving
    /// the shutdown join exists for (#273): the process is told to go while a paste is in
    /// flight and its clipboard restore is still owed.
    quit_during_insert: bool = false,

    fn insertionPlan(self: *FakeDeps) insertmod.Plan {
        return self.plan;
    }

    fn insert(self: *FakeDeps, plan: insertmod.Plan, text: [*:0]const u8) insertmod.InsertError!void {
        if (self.quit_during_insert) self.quit = true;
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
const notes = coord.AppIdentity.init("com.apple.Notes", "Notes");
/// Same bundle id, different display name — the half of the gate a bundle-only comparison
/// would miss, and the reason the rule names both fields (as `undo.evaluate` does).
const slack_renamed = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack Canary");

/// One stored Insertion Record, as the Coordinator would have committed it — with-space
/// bytes, since this module is what applied the separator on the way to the cursor.
fn rec(text: []const u8, stamp: i64) coord.InsertionRecord {
    return outcomeRec(text, stamp, .ok);
}

fn outcomeRec(text: []const u8, stamp: i64, outcome: coord.InsertResult) coord.InsertionRecord {
    return .{ .inserted = text, .raw = null, .timestamp = stamp, .outcome = outcome, .focused_app = slack };
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

// --- the Focused Target gate (ADR-0009 amendment) ------------------------------------

/// Drive one Utterance the way the Coordinator does: note the target on the release edge,
/// then let `at_drain` stand in for whatever the user did during transcription and the
/// Rewrite budget before the job drains.
fn dictateInto(runner: *Runner, at_release: ?coord.AppIdentity, at_drain: ?coord.AppIdentity) void {
    runner.deps.focused_app = at_release;
    runner.noteTarget();
    runner.submit(7, "the secret", .normal);
    runner.deps.focused_app = at_drain;
}

test "the Focused Target is unchanged, so the transcript inserts" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    dictateInto(&runner, slack, slack);
    try std.testing.expect(runner.runOnce());

    try std.testing.expectEqualStrings("the secret ", runner.deps.lastText());
    try std.testing.expectEqual(coord.InsertResult.ok, runner.deps.last_completion);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.refuses);
    // Two cross-process reads for the whole Utterance — one at the release note, one at the
    // drain — and the drain's single reading serves both the gate and the record's App
    // Identity hint. The gate costs the note; it does not also cost a second read here.
    try std.testing.expectEqual(@as(usize, 2), runner.deps.focus_reads);
    try std.testing.expectEqualStrings("Slack", runner.deps.last_focused_app.?.displayName());
}

test "a changed Focused Target refuses: nothing is pasted and nothing touches the pasteboard" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    // The window the finding names: between the Talk Key release and the paste there is
    // transcription latency and, with Backtrack on, the whole Rewrite budget — long enough to
    // switch apps deliberately, and long enough for an app to steal activation on its own.
    dictateInto(&runner, slack, notes);
    try std.testing.expect(runner.runOnce());

    try std.testing.expectEqual(@as(usize, 0), runner.deps.calls); // nothing pasted
    try std.testing.expectEqual(@as(usize, 0), runner.deps.copies); // pasteboard untouched
    try std.testing.expectEqual(coord.InsertResult.refused, runner.deps.last_completion);
}

test "a display-name change alone refuses — the gate compares both fields, as Undo's does" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    dictateInto(&runner, slack, slack_renamed);
    try std.testing.expect(runner.runOnce());

    try std.testing.expectEqual(@as(usize, 0), runner.deps.calls);
    try std.testing.expectEqual(coord.InsertResult.refused, runner.deps.last_completion);
}

test "a refusal fires exactly one refuse cue" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    dictateInto(&runner, slack, notes);
    try std.testing.expect(runner.runOnce());

    // The same red bloom + shake every cursor action that did nothing shows (ADR-0007). The
    // Coordinator deliberately adds no second verb for `.refused`, so this count is the whole
    // user-visible signal.
    try std.testing.expectEqual(@as(usize, 1), runner.deps.refuses);
}

test "a refused transcript is still recorded, so it can be re-inserted" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    dictateInto(&runner, slack, notes);
    try std.testing.expect(runner.runOnce());

    // A refusal is recoverable and must be: the Utterance still resolves through the reverse
    // edge carrying its bytes, so the Coordinator commits an Insertion Record and the user can
    // re-insert it into the app they actually meant.
    try std.testing.expectEqual(@as(usize, 1), runner.deps.completions);
    try std.testing.expectEqualStrings("the secret ", runner.deps.lastInserted());
    // And the hint names the app it was *dictated into*, not the one that stole focus.
    try std.testing.expectEqualStrings("Slack", runner.deps.last_focused_app.?.displayName());
}

test "a record that a refusal produced still re-inserts from Recent Insertions" {
    var ring = recent_insertions.Ring{};
    ring.record(outcomeRec("the secret ", 42, .refused));
    var runner = Runner.init(&ring, .{});

    // The recovery the refusal promises: Re-insert is user-initiated at a moment when the user
    // has just chosen the target, so it stays unconditional — no gate, whatever the outcome
    // the row carries.
    runner.submitMenu(.reinsert, 42);
    try std.testing.expect(runner.runOnce());

    try std.testing.expectEqualStrings("the secret ", runner.deps.lastText());
    try std.testing.expectEqual(@as(usize, 0), runner.deps.refuses);
}

test "an unreadable frontmost at drain time INSERTS — absence is consent, unlike Undo" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    // The one place this gate must differ from `undo.evaluate`, which refuses on a null on
    // either side. Refusing here would break dictation outright on the first app that does not
    // report cleanly — far worse than the rare mis-target this gate is for.
    dictateInto(&runner, slack, null);
    try std.testing.expect(runner.runOnce());

    try std.testing.expectEqualStrings("the secret ", runner.deps.lastText());
    try std.testing.expectEqual(coord.InsertResult.ok, runner.deps.last_completion);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.refuses);
    // With no fresh reading the release-time one is still the best name for where it went.
    try std.testing.expectEqualStrings("Slack", runner.deps.last_focused_app.?.displayName());
}

test "an unreadable frontmost at release time INSERTS — no baseline, no positive evidence" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    dictateInto(&runner, null, notes);
    try std.testing.expect(runner.runOnce());

    try std.testing.expectEqualStrings("the secret ", runner.deps.lastText());
    try std.testing.expectEqual(coord.InsertResult.ok, runner.deps.last_completion);
    // The fresh reading is the honest hint: it is where the text actually went.
    try std.testing.expectEqualStrings("Notes", runner.deps.last_focused_app.?.displayName());
}

test "a job with no note at all inserts, and a refusal cannot gate the next Utterance" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{});

    dictateInto(&runner, slack, notes);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqual(coord.InsertResult.refused, runner.deps.last_completion);

    // The note is consumed by the job it belongs to. A second job that somehow arrives without
    // one must not inherit the refused Utterance's baseline and refuse forever after.
    runner.submit(8, "next one", .normal);
    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("next one ", runner.deps.lastText());
    try std.testing.expectEqual(coord.InsertResult.ok, runner.deps.last_completion);
}

test "a menu Re-insert is never gated — it ignores a live note entirely" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("recovered text ", 42));
    var runner = Runner.init(&ring, .{ .focused_app = notes });

    // The user clicked a row in the Status Item just now, so the frontmost app *is* the target
    // they chose; a stale dictation note must not veto it (spec §5.1: unconditional).
    runner.deps.focused_app = slack;
    runner.noteTarget();
    runner.deps.focused_app = notes;
    runner.submitMenu(.reinsert, 42);

    try std.testing.expect(runner.runOnce());
    try std.testing.expectEqualStrings("recovered text ", runner.deps.lastText());
    try std.testing.expectEqual(@as(usize, 0), runner.deps.refuses);
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
    const target = ring.newestForUndo().?;
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
    const target = ring.newestForUndo().?;
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

// --- Shutdown: the loop never returns owing a deferred restore (#273) ---

test "a quit raised mid-insertion still drains the deferred restore before the loop returns" {
    // The interleaving the daemon's join exists for: SIGTERM (or menu Quit) arrives while the
    // paste is in flight, so the Final Transcript is on the general pasteboard and the user's
    // own clipboard lives only in this process's memory. `shouldQuit` is polled between
    // iterations, never inside one, so the drain still runs — which is what makes waiting for
    // this loop sufficient, with no flush API to call.
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{ .quit_during_insert = true });
    var undo = FakeUndo{ .deps = &runner.deps };

    runner.submit(7, "dictation", .normal);
    runner.workerLoop(&undo);

    try std.testing.expectEqual(@as(usize, 1), runner.deps.calls);
    try std.testing.expectEqual(@as(usize, 1), runner.deps.completions);
    // The whole point: the loop had come around, and the restore had run by then.
    try std.testing.expectEqual(@as(usize, 1), runner.deps.finishes);
    // It left through the quit flag, not the idle path — proving the drain was not merely a
    // side effect of the loop having nothing else to do.
    try std.testing.expectEqual(@as(usize, 0), runner.deps.idles);
}

test "a quit raised mid-replay drains that restore too" {
    // The Re-insert path leaves the same deferred restore a dictation does, so a quit landing
    // inside it must be waited for the same way. (Copy drains *before* its write and leaves
    // nothing pending, so it has nothing to owe.)
    var ring = recent_insertions.Ring{};
    ring.record(rec("replay ", 10));
    var runner = Runner.init(&ring, .{ .quit_during_insert = true });
    var undo = FakeUndo{ .deps = &runner.deps };

    runner.submitMenu(.reinsert, 10);
    runner.workerLoop(&undo);

    try std.testing.expectEqual(@as(usize, 1), runner.deps.calls);
    try std.testing.expectEqual(@as(usize, 1), runner.deps.finishes);
    try std.testing.expectEqual(@as(usize, 0), runner.deps.idles);
}
