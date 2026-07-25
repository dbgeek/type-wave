//! undo.zig — the **Undo Runner**: the daemon's one route from the recovery chord `⌃⌘⌫`
//! to a deletion (undo-spec, ADR-0008).
//!
//! One Undo is a single sequence — resolve the newest Insertion Record, count its grapheme
//! clusters, read the frontmost app, evaluate the app-level focus gate, post that many
//! Backspaces, flag the record `undone`, show the cue — and this module owns **all** of it,
//! start to finish, **on the insert worker**. The chord callback does one thing: bump a
//! counter (`request`). That placement is the point (ADR-0008):
//!
//!   - The gate's contract is a **fresh** `frontmost()` read immediately before posting, and
//!     the read is a cross-process NSWorkspace query — so it cannot move up to the tap's
//!     run-loop thread, where it would both go stale before the post and stall the tap
//!     callback (a slow tap callback makes the OS disable the tap).
//!   - Everything *else* therefore moves **down** to meet it. Resolution happens at post
//!     time, beside the focus read, under one rule rather than two.
//!   - So the `undone` flag flips **after** a committed deletion, never before it. The old
//!     split flagged on the trigger thread ahead of the worker's gate, which left a refused
//!     Undo rendering a dimmed record that nothing had deleted.
//!
//! The Ring is held concretely: it is heap-free and test-constructible, so faking it would
//! mean re-implementing eviction and stamp-keying rather than exercising them. `Deps` covers
//! only what the OS owns — the pause/grant gate, the frontmost read, the Secure Event Input
//! probe, the deletion mechanism, and the two HUD cue verbs (ADR-0007) — so the whole sequence
//! is driven from tests by fed values, including the joins that were previously unreachable.
//!
//! One rule runs through every exit (#244): **nothing claims a deletion that did not happen.**
//! The deletion mechanism reports whether it posted, the runner probes Secure Event Input —
//! which silently suppresses posted events — before it posts at all, and the `undone` flag and
//! the green confirm cue both hang off a *successful* post. An Undo that could not land is a
//! refusal that leaves the record retryable, never a green cue over unchanged text.
//!
//! Serialization against dictation stays the Insert Worker's: `insertion_runner.workerLoop`
//! drains this last, after the dictation / replay / copy slots, so a deletion can never
//! interleave with an Insertion's clipboard-swap dance.

const std = @import("std");
const coord = @import("coordinator.zig");
const feedback = @import("feedback.zig");
const grapheme = @import("grapheme.zig");
const recent_insertions = @import("recent_insertions.zig");

/// Why an Undo refused — written to the log for the feedback layer (#213: every reason
/// collapses to the one red-shake cue on the HUD, ADR-0007/#226). Unlike the pre-ADR-0008
/// split, every variant is produced by one function in one module: the reasons no longer
/// live apart from the code that returns them.
pub const RefuseReason = enum {
    /// The ring holds no Insertion to delete.
    no_target,
    /// The newest record is already undone — a second `⌃⌘⌫` on it refuses rather than eating
    /// earlier text (#225's single-shot model). A re-insert redoes it.
    already_undone,
    /// Dictation is paused, or the PostEvent grant is missing (ADR-0008). `⌃⌘⌫` is a
    /// system-wide chord and Backspaces are destructive: a paused daemon is inert, and
    /// without the grant `deleteChars` would post nothing while the confirm cue claimed
    /// otherwise.
    paused,
    /// Missing evidence — the record has no stored `focused_app`, or `frontmost()` returned
    /// null (fail-closed, #213's null-evidence rule).
    focus_null,
    /// Positive evidence of a change: bundle id or display name differs from the record's.
    app_changed,
    /// Secure Event Input is held (a password field, Terminal's Secure Keyboard Entry), so
    /// posted events are suppressed (#244). The deletion would vanish while the confirm cue
    /// claimed it landed, which is the one outcome this module exists to prevent.
    secure_input,
    /// The deletion mechanism reported that it could not post (#244). Nothing landed, so the
    /// record is left un-undone and the next press retries it.
    post_failed,
};

/// The Undo Runner's dependency seam: everything the OS owns. Asserted by name here and
/// invoked by `Undo` itself below, so a production adapter can never skip the check — the
/// gap the Helper and Session Transport contracts leave open, where the generic type never
/// calls its own assertion.
pub fn assertDeps(comptime Deps: type) void {
    const required = [_][]const u8{
        "enabled",     "focusedApp",    "secureInputActive",
        "deleteChars", "undoConfirmed", "undoRefused",
    };
    inline for (required) |name| {
        if (!@hasDecl(Deps, name))
            @compileError("type '" ++ @typeName(Deps) ++ "' is not Undo Deps: missing method '" ++ name ++ "'");
    }
}

/// Evaluate the app-level focus gate: `expected` is the record's stored `focused_app`,
/// `fresh` the `frontmost()` read taken immediately before posting. Returns null when the
/// gate passes (post the backspaces) or the refuse reason when it does not (post nothing).
///
/// The safety property that keeps a misfired `⌃⌘⌫` from eating text in some other app:
/// Undo proceeds only on positive evidence that the frontmost app is unchanged since the
/// Insertion. "Same app" is the strictest rule #213 offers — **both** the bundle id **and**
/// the display name must match — and the gate is **fail-closed**: `focused_app` is a
/// best-effort nullable hint and `frontmost()` can itself return null, so either side
/// missing refuses. Backspaces are destructive and irreversible; the gate never posts on
/// missing evidence.
///
/// App-level only by design (#209's out-of-scope: no Accessibility field-level capture) —
/// the residual "user kept typing in the same app" hazard is a known, accepted limitation.
fn evaluate(expected: ?coord.AppIdentity, fresh: ?coord.AppIdentity) ?RefuseReason {
    const e = expected orelse return .focus_null;
    const f = fresh orelse return .focus_null;
    if (!std.mem.eql(u8, e.bundleId(), f.bundleId())) return .app_changed;
    if (!std.mem.eql(u8, e.displayName(), f.displayName())) return .app_changed;
    return null;
}

pub fn Undo(comptime Deps: type) type {
    assertDeps(Deps);
    return struct {
        const Self = @This();

        /// How many un-drained presses the counter holds before it saturates. One press
        /// yields one verdict and one cue, so a burst inside a long drain (a ~300 ms paste,
        /// or a ~200 ms deletion of a 200-cluster Insertion) still gets answered press by
        /// press. Beyond this the extra presses collapse — a user cannot meaningfully mean
        /// four queued Undos when the single-shot model refuses everything after the first.
        pub const max_queued: u8 = 3;

        /// The authoritative Recent Insertions ring (ADR-0006). Held concretely, not behind
        /// `Deps`: it is daemon-owned, heap-free and leaf-locked, and the Runner only drives
        /// it — resolve the newest, flag it on a committed deletion. Never under any other
        /// lock; the ring's own leaf lock is taken and released inside each call.
        ring: *recent_insertions.Ring,
        deps: Deps,

        /// Un-drained presses. Written by the tap's run-loop thread (`request`), drained by
        /// the insert worker (`runOnce`) — the whole cross-thread handoff, and the only
        /// state the chord callback touches.
        pending: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

        pub fn init(ring: *recent_insertions.Ring, deps: Deps) Self {
            return .{ .ring = ring, .deps = deps };
        }

        /// The recovery chord fired. Runs on the tap's run-loop thread and does exactly one
        /// atomic increment — no ring read, no memcpy, no cross-process query — so the tap
        /// callback stays as fast as the OS demands. Saturates at `max_queued` rather than
        /// wrapping.
        pub fn request(self: *Self) void {
            var cur = self.pending.load(.monotonic);
            while (cur < max_queued) {
                if (self.pending.cmpxchgWeak(cur, cur + 1, .release, .monotonic)) |actual| {
                    cur = actual;
                } else return;
            }
        }

        /// One worker tick: drain at most one press and run its Undo to a verdict. Exposed
        /// so tests drive the Runner without spawning a thread. Returns whether a press was
        /// drained.
        pub fn runOnce(self: *Self) bool {
            var cur = self.pending.load(.acquire);
            while (cur > 0) {
                if (self.pending.cmpxchgWeak(cur, cur - 1, .acquire, .acquire)) |actual| {
                    cur = actual;
                } else {
                    self.run();
                    return true;
                }
            }
            return false;
        }

        fn refuse(self: *Self, reason: RefuseReason, note: []const u8) void {
            feedback.log("  undo refused: {s} — {s}\n", .{ @tagName(reason), note });
            // Every reason collapses to the one red bloom + shake (ADR-0007, #226); the
            // specific reason is logged only (#213).
            self.deps.undoRefused();
        }

        /// One Undo, start to finish, on the insert worker. The order below is the module's
        /// whole reason to exist and is load-bearing (ADR-0008, amended by #244):
        ///
        ///   gate on pause/grant → resolve → count → secure-input probe → fresh focus read
        ///                       → focus gate → post → **flag undone** → confirm cue
        ///
        /// The flag flips only after `deleteChars` reports that it *did* post, so no refusal
        /// can leave a record rendering dimmed with nothing deleted. Every exit before the post
        /// fires the refuse cue, so a press is never silently swallowed.
        fn run(self: *Self) void {
            // ADR-0008: `⌃⌘⌫` is a system-wide chord, so it is gated like the Talk Key —
            // but on Undo's *own* prerequisites. Not `configured` (that bundles an OpenAI
            // key or a Model Installation, neither of which deleting already-landed text
            // needs) and not the Supervisor's `capture_enabled` (that would refuse an Undo
            // because a Transcription Backend dropped).
            if (!self.deps.enabled()) {
                self.refuse(.paused, "dictation is paused or the PostEvent grant is missing");
                return;
            }

            // Resolved **here**, at post time, not at chord time: bytes, App Identity, stamp
            // and undone flag come out of one hold of the ring's leaf lock, so a concurrent
            // Insertion can never pair one record's text with another's app.
            var buf: [recent_insertions.max_bytes]u8 = undefined;
            const target = self.ring.newestForUndo(&buf) orelse {
                self.refuse(.no_target, "the ring holds no Insertion to delete");
                return;
            };
            if (target.undone) {
                self.refuse(.already_undone, "the newest Insertion is already undone");
                return;
            }
            // The newest record never put bytes at the cursor — the mechanism failed, or the
            // Focused Target gate refused the paste (ADR-0009 amendment). Its clusters are
            // still counted and its text is still re-insertable, but backspacing that count
            // would delete whatever the user *did* write since. `.no_target` is the honest
            // reason for the same reason the degenerate-record exit uses it: this record
            // cannot be a target, and every reason collapses to the one red cue anyway.
            if (!target.landed) {
                self.refuse(.no_target, "the newest Insertion never reached the cursor — there is nothing of it to delete");
                return;
            }

            // One `⌫` per extended grapheme cluster (#220), trailing Insertion space
            // included (#214 — restore the pre-Insertion state).
            const n = grapheme.graphemeCount(buf[0..target.len]);
            if (n == 0) {
                // A degenerate record: empty bytes, or a segmentation failure. There is
                // nothing to delete, so the gate's cross-process read is skipped — but the
                // press still earns its verdict. `.no_target` is the honest reason (this
                // record cannot be a target) and every reason collapses to the one red cue
                // anyway (ADR-0007), so it needs no variant of its own.
                self.refuse(.no_target, "the newest Insertion is empty or unsegmentable");
                return;
            }

            // Secure Event Input suppresses posted events (#244), so a deletion attempted
            // under it lands nowhere while the confirm cue claims it did. Probed here, at post
            // time, for the same freshness reason the focus read is — but *before* it, because
            // this one is a cheap in-process Carbon call and there is no sense paying for a
            // cross-process NSWorkspace query for a post that cannot land.
            if (self.deps.secureInputActive()) {
                self.refuse(.secure_input, "Secure Event Input would suppress the backspaces");
                return;
            }

            const fresh = self.deps.focusedApp();
            if (evaluate(target.focused_app, fresh)) |reason| {
                self.refuse(reason, "nothing posted");
                return;
            }

            // The post is a *result*, not a side effect to assume (#244): the flag and the
            // confirm cue below are this module's claim that text was deleted, and nothing may
            // make that claim on its behalf. Only a post of **zero** Backspaces is retryable —
            // a burst that stopped partway already changed the target app, and re-running the
            // full `n` on the next press would eat text that preceded the Insertion, which is
            // exactly what single-shot (#225) exists to prevent. So a short burst commits like
            // a whole one and says so in the log.
            const posted = self.deps.deleteChars(n);
            if (posted == 0) {
                self.refuse(.post_failed, "the deletion mechanism posted nothing; the record stays retryable");
                return;
            }
            // Flagged **after** the post (ADR-0008), keyed by the record's stable
            // `timestamp` so a concurrent Insertion shifting the newest-first order cannot
            // flag a neighbour. Undo pushes no new ring entry: the record is kept and
            // flagged, and a re-insert redoes it (#225).
            self.ring.markUndone(target.timestamp);
            if (posted < n) {
                feedback.log("  undo: only {d} of {d} backspaces posted — the Insertion is partly deleted and the record is spent\n", .{ posted, n });
            } else {
                feedback.log("  undo: posted {d} backspaces to delete the last Insertion\n", .{n});
            }
            self.deps.undoConfirmed();
        }
    };
}

// ============================================================================
// Tests — the whole sequence against a real Ring and a fake OS, including the joins
// that were unreachable while the path was split across two threads (ADR-0008).
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// The App Identity most gate tests store on the record and set as the fake frontmost.
const slack = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack");
const notes = coord.AppIdentity.init("com.apple.Notes", "Notes");

const FakeDeps = struct {
    /// The pause / PostEvent-grant gate (ADR-0008).
    on: bool = true,
    enabled_reads: usize = 0,
    focused_app: ?coord.AppIdentity = null,
    /// How many times the Runner read the frontmost app — lets the gate tests prove the
    /// read is fresh (taken during `run`) and skipped when nothing would post (#224).
    focus_reads: usize = 0,
    /// Secure Event Input, and how many times the Runner probed it — the probe has to be as
    /// fresh as the focus read (#244).
    secure_input: bool = false,
    secure_reads: usize = 0,
    deletes: usize = 0,
    last_delete_n: usize = 0,
    /// How many Backspace pairs the mechanism manages to post; null means the whole burst (the
    /// healthy case). `0` is the suppressed / refused post the Runner must not confirm, and a
    /// value below `n` is a burst that stopped partway (#244).
    delete_posts: ?usize = null,
    undo_confirms: usize = 0,
    undo_refuses: usize = 0,

    fn enabled(self: *FakeDeps) bool {
        self.enabled_reads += 1;
        return self.on;
    }
    fn focusedApp(self: *FakeDeps) ?coord.AppIdentity {
        self.focus_reads += 1;
        return self.focused_app;
    }
    fn secureInputActive(self: *FakeDeps) bool {
        self.secure_reads += 1;
        return self.secure_input;
    }
    fn deleteChars(self: *FakeDeps, n: usize) usize {
        self.deletes += 1;
        self.last_delete_n = n;
        return @min(self.delete_posts orelse n, n);
    }
    fn undoConfirmed(self: *FakeDeps) void {
        self.undo_confirms += 1;
    }
    fn undoRefused(self: *FakeDeps) void {
        self.undo_refuses += 1;
    }
};

const Runner = Undo(FakeDeps);

fn rec(text: []const u8, stamp: i64, app: ?coord.AppIdentity) coord.InsertionRecord {
    return .{ .inserted = text, .raw = null, .timestamp = stamp, .outcome = .ok, .focused_app = app };
}

// --- resolution: which record, and which bytes ---

test "undo resolves the newest record and deletes one cluster per grapheme, trailing space included" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("first ", 10, slack));
    ring.record(rec("newest ", 20, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    // "newest " is 7 bytes / 7 clusters incl. the trailing Insertion space → 7 ⌫ (#214/#220).
    try expectEqual(@as(usize, 1), runner.deps.deletes);
    try expectEqual(@as(usize, 7), runner.deps.last_delete_n);
    try expectEqual(@as(usize, 1), runner.deps.undo_confirms);
    try expectEqual(@as(usize, 0), runner.deps.undo_refuses);
}

test "undo targets only the newest, ignoring older records (single-shot, #212)" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("older one ", 10, slack));
    ring.record(rec("middle ", 20, slack));
    ring.record(rec("the last thing ", 30, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 15), runner.deps.last_delete_n); // "the last thing "
}

test "undo deletes the with-space inserted, never the pre-Rewrite raw" {
    var ring = recent_insertions.Ring{};
    ring.record(.{
        .inserted = "At 18:00 ",
        .raw = "at 20:00 no 18:00",
        .timestamp = 1,
        .outcome = .degraded,
        .focused_app = slack,
    });
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 9), runner.deps.last_delete_n); // "At 18:00 ", not the 17-byte raw
}

test "undo counts grapheme clusters, not bytes or UTF-16 units" {
    var ring = recent_insertions.Ring{};
    // A ZWJ family emoji + a space: 25 + 1 bytes, 11 + 1 UTF-16 units, but 2 clusters → 2 ⌫.
    ring.record(rec("👨\u{200D}👩\u{200D}👧\u{200D}👦 ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 2), runner.deps.last_delete_n);
}

test "undo on an empty ring posts nothing (no_target) and fires the refuse cue (#226)" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce()); // the press still drained this tick

    try expectEqual(@as(usize, 0), runner.deps.deletes);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
    // No target means nothing would post, so the cross-process focus read is skipped.
    try expectEqual(@as(usize, 0), runner.deps.focus_reads);
}

test "a record whose text never reached the cursor is not a deletion target" {
    // The ring keeps records that never inserted — that is the recovery case Recent
    // Insertions exists for — but Undo deletes by *count*. Backspacing this record's clusters
    // would eat that many clusters of whatever the user actually typed since.
    for ([_]coord.InsertResult{ .refused, .failed }) |never_landed| {
        var ring = recent_insertions.Ring{};
        var record = rec("never landed ", 1, slack);
        record.outcome = never_landed;
        ring.record(record);
        var runner = Runner.init(&ring, .{ .focused_app = slack });

        runner.request();
        try expect(runner.runOnce());

        try expectEqual(@as(usize, 0), runner.deps.deletes);
        try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
        // Nothing would post, so the cross-process read is skipped as on every other
        // no-target exit.
        try expectEqual(@as(usize, 0), runner.deps.focus_reads);
    }
}

test "a degraded record IS a deletion target — the raw text still landed" {
    var ring = recent_insertions.Ring{};
    var record = rec("raw fallback ", 1, slack);
    record.outcome = .degraded;
    ring.record(record);
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 1), runner.deps.deletes);
    try expectEqual(@as(usize, 1), runner.deps.undo_confirms);
}

test "a record with zero grapheme clusters refuses without reading the frontmost app" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 0), runner.deps.deletes);
    // Nothing would post, so the gate's cross-process read is still skipped.
    try expectEqual(@as(usize, 0), runner.deps.focus_reads);
    // But the press earns a verdict: one press, one cue, with no exception for a
    // degenerate record (ADR-0009 closed this hole).
    try expectEqual(@as(usize, 0), runner.deps.undo_confirms);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
}

// --- the app-level focus gate — undo-spec / #213, issue #224 ---

test "the gate reads a fresh frontmost app at post time, not one captured at request time" {
    // At press time the frontmost app still matches the record; by the time the worker drains
    // the press the user has switched away. Only a fresh read refuses here — a value captured
    // at press (or record) time would wrongly pass and eat the other app's text.
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    runner.deps.focused_app = notes;
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 1), runner.deps.focus_reads); // read during run, after resolve
    try expectEqual(@as(usize, 0), runner.deps.deletes);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
    try expectEqual(@as(usize, 0), runner.deps.undo_confirms);
}

test "a changed bundle id refuses — zero deletes posted" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{
        .focused_app = coord.AppIdentity.init("com.example.slack-beta", "Slack"),
    });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 0), runner.deps.deletes);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
}

test "a changed display name refuses — zero deletes posted" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{
        .focused_app = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack Canary"),
    });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 0), runner.deps.deletes);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
}

test "a null frontmost app refuses (fail-closed) — zero deletes posted" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{}); // focused_app defaults to null

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 0), runner.deps.deletes);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
}

test "a record with no stored App Identity refuses (fail-closed) — zero deletes posted" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, null)); // the best-effort hint was never captured
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 0), runner.deps.deletes);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
}

// --- the join ADR-0008 exists for: the flag flips where the deletion happens ---

test "a committed undo flags the record undone — after the post, keyed by timestamp (#225)" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("undo me ", 55, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 1), runner.deps.deletes);
    var out: [recent_insertions.max_bytes]u8 = undefined;
    try expect(ring.newestForUndo(&out).?.undone); // kept and flagged, not removed
}

test "a gate refusal leaves the record NOT undone — no dimmed row for a deletion that never happened" {
    // The defect ADR-0008 closes: the old split flagged on the trigger thread before the
    // worker's gate ran, so a refusal dimmed a record nothing had deleted.
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = notes }); // app changed → refuse

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 0), runner.deps.deletes);
    var out: [recent_insertions.max_bytes]u8 = undefined;
    try expect(!ring.newestForUndo(&out).?.undone);
}

test "a refused undo stays retryable — fixing the focus and pressing again deletes" {
    // Follows from the flag no longer flipping on a refusal: the user switches back to the
    // app they dictated into and the second press succeeds.
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = notes });

    runner.request();
    try expect(runner.runOnce());
    try expectEqual(@as(usize, 0), runner.deps.deletes);

    runner.deps.focused_app = slack; // back in the right app
    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 1), runner.deps.deletes);
    try expectEqual(@as(usize, 4), runner.deps.last_delete_n);
    try expectEqual(@as(usize, 1), runner.deps.undo_confirms);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses); // the first press
}

// --- the post has to actually happen before anything claims it did (#244) ---

test "a deletion the mechanism could not post refuses: no confirm cue, no undone flag" {
    // #244's amplifier: the runner used to flag and confirm unconditionally after the call, so
    // a mechanism failure became a permanent one — press #1 latched the record undone with
    // nothing deleted, and every later press hit the already-undone guard.
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack, .delete_posts = 0 });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 1), runner.deps.deletes); // it was attempted…
    try expectEqual(@as(usize, 0), runner.deps.undo_confirms); // …but nothing is claimed
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
    var out: [recent_insertions.max_bytes]u8 = undefined;
    try expect(!ring.newestForUndo(&out).?.undone);
}

test "a record left un-undone by a failed post is still the newest target on the next press" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack, .delete_posts = 0 });

    runner.request();
    try expect(runner.runOnce());

    runner.deps.delete_posts = null; // whatever blocked the post cleared
    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 4), runner.deps.last_delete_n); // the same record, retried
    try expectEqual(@as(usize, 1), runner.deps.undo_confirms);
    var out: [recent_insertions.max_bytes]u8 = undefined;
    try expect(ring.newestForUndo(&out).?.undone);
}

test "a burst that stopped partway commits the record — a retry would eat earlier text (#225)" {
    // Only a *zero* post is retryable. Two of four Backspaces are already in the target app, so
    // the record is spent: pressing again must refuse rather than delete four more.
    var ring = recent_insertions.Ring{};
    ring.record(rec("older ", 10, slack));
    ring.record(rec("abc ", 20, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack, .delete_posts = 2 });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 1), runner.deps.undo_confirms); // text *was* deleted
    var out: [recent_insertions.max_bytes]u8 = undefined;
    try expect(ring.newestForUndo(&out).?.undone);

    runner.deps.delete_posts = null;
    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 1), runner.deps.deletes); // no second burst — "older " is safe
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
}

test "a second undo on an already-undone newest record refuses — it never eats earlier text (#225)" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("older ", 10, slack));
    ring.record(rec("newest ", 20, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce()); // deletes "newest " and flags it
    runner.request();
    try expect(runner.runOnce()); // newest is undone → refuse, don't eat "older "

    try expectEqual(@as(usize, 1), runner.deps.deletes);
    try expectEqual(@as(usize, 7), runner.deps.last_delete_n); // "newest ", never "older "
    try expectEqual(@as(usize, 1), runner.deps.undo_confirms);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
}

test "undo adds no new ring entry — the record is kept and flagged, count unchanged (#225)" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("solo ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 1), ring.len()); // still one record; Undo pushes nothing
}

test "resolution happens at post time: an Insertion landing between press and drain retargets" {
    // The behavioural consequence of ADR-0008's move. The record is resolved beside the
    // focus read, so the Runner deletes what is newest *when it posts* — the same instant
    // the gate proves the app is unchanged — rather than what was newest when the chord fired.
    var ring = recent_insertions.Ring{};
    ring.record(rec("at press time ", 10, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    ring.record(rec("landed after ", 20, slack)); // a dictation resolves before the drain
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 13), runner.deps.last_delete_n); // "landed after "
}

// --- Secure Event Input — the other silent-confirm path (#244) ---

test "Secure Event Input refuses and posts nothing — never a confirm cue for a suppressed post" {
    // A password field or Terminal's Secure Keyboard Entry suppresses posted events, so the
    // Backspaces would vanish while the green cue claimed a deletion. Refuse honestly instead.
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack, .secure_input = true });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 0), runner.deps.deletes);
    try expectEqual(@as(usize, 0), runner.deps.undo_confirms);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
    // Nothing would post, so the gate's cross-process frontmost read is skipped (#224's rule).
    try expectEqual(@as(usize, 0), runner.deps.focus_reads);
    var out: [recent_insertions.max_bytes]u8 = undefined;
    try expect(!ring.newestForUndo(&out).?.undone); // and the record stays retryable
}

test "leaving the secure field makes the same chord land" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack, .secure_input = true });

    runner.request();
    try expect(runner.runOnce());
    try expectEqual(@as(usize, 0), runner.deps.deletes);

    runner.deps.secure_input = false;
    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 1), runner.deps.deletes);
    try expectEqual(@as(usize, 4), runner.deps.last_delete_n);
}

test "the secure-input probe is read fresh on every press, not once at construction" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 1), runner.deps.secure_reads);
}

// --- the pause / PostEvent-grant gate — ADR-0008 ---

test "a paused daemon refuses the chord before reading the ring or the frontmost app" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .on = false, .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());

    try expectEqual(@as(usize, 0), runner.deps.deletes);
    // The outermost gate: no cross-process focus read, and the record is left untouched.
    try expectEqual(@as(usize, 0), runner.deps.focus_reads);
    var out: [recent_insertions.max_bytes]u8 = undefined;
    try expect(!ring.newestForUndo(&out).?.undone);
    // Refused, not swallowed — the user sees why (ADR-0007, #226).
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);
}

test "unpausing makes the same chord land" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .on = false, .focused_app = slack });

    runner.request();
    try expect(runner.runOnce());
    try expectEqual(@as(usize, 0), runner.deps.deletes);

    runner.deps.on = true;
    runner.request();
    try expect(runner.runOnce());
    try expectEqual(@as(usize, 1), runner.deps.deletes);
}

// --- the press counter: one press, one verdict, one cue ---

test "an idle Runner drains nothing" {
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    try expect(!runner.runOnce());
    try expectEqual(@as(usize, 0), runner.deps.enabled_reads);
}

test "two presses inside one drain window yield two verdicts, in order: delete then refuse" {
    // The counter's reason to exist. Both presses land before the worker ticks; the first
    // deletes and flags, the second finds the record already undone and refuses — so the
    // user gets a green bloom and then a red shake rather than one cue and one silence.
    var ring = recent_insertions.Ring{};
    ring.record(rec("abc ", 1, slack));
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    runner.request();
    runner.request();

    try expect(runner.runOnce());
    try expectEqual(@as(usize, 1), runner.deps.deletes);
    try expectEqual(@as(usize, 1), runner.deps.undo_confirms);
    try expectEqual(@as(usize, 0), runner.deps.undo_refuses);

    try expect(runner.runOnce());
    try expectEqual(@as(usize, 1), runner.deps.deletes); // still one deletion
    try expectEqual(@as(usize, 1), runner.deps.undo_confirms);
    try expectEqual(@as(usize, 1), runner.deps.undo_refuses);

    try expect(!runner.runOnce()); // and the queue is empty
}

test "the press counter saturates rather than wrapping" {
    var ring = recent_insertions.Ring{};
    var runner = Runner.init(&ring, .{ .focused_app = slack });

    for (0..64) |_| runner.request();

    var drained: usize = 0;
    while (runner.runOnce()) drained += 1;
    try expectEqual(@as(usize, Runner.max_queued), drained);
}
