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
//!     `deps.audio` / `deps.transcription` / `deps.insertion` / `deps.deadline` /
//!     `deps.feedback` by duck-typed method name. Real adapters in daemon.zig / surface.zig;
//!     fakes in the tests. No vtables, no @ptrCast — a shape mismatch is a compile error.
//!   - **Inbound events arrive via `handle(event)`**, serialized on one `os_unfair_lock`.
//!     The tap (press/release), the always-on Transcription observer (partial/final), the
//!     deadline timer (deadline), and the insert worker (inserted) all trampoline here from
//!     their own threads; the mutex makes the machine single-threaded from its own view, so
//!     the old atomics become the plain `phase` enum (`busy` ≡ `phase != .idle`).
//!
//! # Phases (ADR-0001: fully serialized)
//!
//!   idle → capturing → awaiting_final → inserting → idle
//!
//!   `.inserting` is blocking: one Utterance resolves fully (paste included) before the
//!   next hold is accepted. This is what lets `hideIfFinal` collapse to `hide()` — nothing
//!   can repaint the pill mid-Insertion. See ADR-0001 for the traded-away #19 overlap.

const std = @import("std");
const feedback = @import("feedback.zig");

/// Outcome the insert worker reports back as the `.inserted` event.
pub const InsertResult = enum { ok, failed };

/// Everything that can happen *to* an Utterance, from whichever thread observed it.
/// The `final` slice borrows the Transcription Session's accumulator and is valid only
/// for the duration of the `handle` call — the insertion seam copies synchronously
/// (exactly the memcpy the old worker did before releasing the guard). Partial
/// Transcripts no longer reach the Coordinator at all: the HUD shows no text (#27),
/// and their log lives upstream in session.zig (#18).
pub const Event = union(enum) {
    press,
    release,
    final: []const u8,
    deadline,
    inserted: InsertResult,
};

const Phase = enum { idle, capturing, awaiting_final, inserting };

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
                .final => |t| self.onFinal(t),
                .deadline => self.onDeadline(),
                .inserted => |r| self.onInserted(r),
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
            // The tap can be live before a Transcription Session exists (Input Monitoring
            // granted, API key not yet present) — nowhere to stream to.
            if (!self.deps.transcription.available()) {
                feedback.log("  Talk Key pressed but no Transcription Session yet (missing API key?) — ignored\n", .{});
                self.deps.feedback.abandoned();
                return;
            }
            self.deps.transcription.beginUtterance();
            self.deps.audio.start() catch |e| {
                feedback.log("  capture.start failed: {s} — Utterance aborted\n", .{@errorName(e)});
                self.deps.transcription.endUtterance();
                self.deps.feedback.abandoned();
                return; // stays .idle
            };
            self.phase = .capturing;
            self.deps.feedback.listening();
            feedback.log("  [REC] listening — release the Talk Key to insert\n", .{});
        }

        fn onRelease(self: *Self) void {
            if (self.phase != .capturing) return; // press was rejected / no live hold

            self.deps.audio.stop(); // synchronous; final buffers flush + forward during this
            self.deps.transcription.endUtterance(); // stop forwarding before committing
            self.deps.feedback.released();

            // Link dropped mid-Utterance: the head audio already streamed live is gone
            // server-side, so committing the buffered tail would insert a truncated Final
            // Transcript. Abandon cleanly rather than commit a fragment.
            if (self.deps.transcription.isPoisoned()) {
                feedback.log("  Transcription Session dropped mid-Utterance — discarded; hold the Talk Key and say it again\n", .{});
                self.deps.feedback.abandoned();
                self.phase = .idle;
                return;
            }
            // Mic-silence detection: TCC denial yields all-zero PCM with no error.
            if (!self.deps.audio.heardSound())
                feedback.log("  microphone captured only silence — is Microphone permission granted to this process?\n", .{});

            const expecting = self.deps.transcription.commitUtterance() catch |e| blk: {
                feedback.log("  commit error: {s}\n", .{@errorName(e)});
                break :blk false;
            };
            if (expecting) {
                self.phase = .awaiting_final;
                self.deps.deadline.arm(); // release-anchored deadline; final cancels it
            } else {
                // Nothing committed (no audio) — no Final Transcript is coming.
                feedback.log("  Utterance produced no audio — nothing to insert\n", .{});
                self.deps.feedback.abandoned();
                self.phase = .idle;
            }
        }

        fn onFinal(self: *Self, text: []const u8) void {
            if (self.phase != .awaiting_final) return; // stale (abandoned, or not awaiting)
            self.deps.deadline.cancel();
            if (text.len == 0) {
                // Empty/failed transcript (mic silence, transcription.failed, …).
                feedback.log("  empty Final Transcript — nothing to insert\n", .{});
                self.deps.feedback.abandoned();
                self.phase = .idle;
                return;
            }
            // No feedback edge here: the processing dots have been up since `released`
            // and hold until `.inserted` resolves (wayfinder #26/#27).
            self.deps.insertion.submit(text); // copies text; worker inserts, then .inserted
            self.phase = .inserting; // blocking: next hold waits (ADR-0001)
        }

        fn onDeadline(self: *Self) void {
            if (self.phase != .awaiting_final) return; // final already arrived / not awaiting
            feedback.log("  no Final Transcript within the deadline — nothing inserted\n", .{});
            self.deps.feedback.abandoned();
            self.phase = .idle;
        }

        fn onInserted(self: *Self, r: InsertResult) void {
            if (self.phase != .inserting) return; // defensive: only the active insert resolves
            switch (r) {
                .ok => self.deps.feedback.inserted(),
                .failed => {
                    feedback.log("  insertion failed — nothing landed at the cursor\n", .{});
                    self.deps.feedback.abandoned();
                },
            }
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
    heard: bool = true,
    fn start(self: *FakeAudio) anyerror!void {
        self.started += 1;
        return self.start_result;
    }
    fn stop(self: *FakeAudio) void {
        self.stopped += 1;
    }
    fn heardSound(self: *FakeAudio) bool {
        return self.heard;
    }
};

const FakeTranscription = struct {
    avail: bool = true,
    poisoned: bool = false,
    commit_result: anyerror!bool = true,
    began: usize = 0,
    ended: usize = 0,
    committed: usize = 0,
    fn available(self: *FakeTranscription) bool {
        return self.avail;
    }
    fn beginUtterance(self: *FakeTranscription) void {
        self.began += 1;
    }
    fn endUtterance(self: *FakeTranscription) void {
        self.ended += 1;
    }
    fn commitUtterance(self: *FakeTranscription) anyerror!bool {
        self.committed += 1;
        return self.commit_result;
    }
    fn isPoisoned(self: *FakeTranscription) bool {
        return self.poisoned;
    }
};

const FakeInsertion = struct {
    submits: usize = 0,
    last: [256]u8 = undefined,
    last_len: usize = 0,
    fn submit(self: *FakeInsertion, text: []const u8) void {
        self.submits += 1;
        @memcpy(self.last[0..text.len], text);
        self.last_len = text.len;
    }
    fn lastText(self: *FakeInsertion) []const u8 {
        return self.last[0..self.last_len];
    }
};

const FakeDeadline = struct {
    arms: usize = 0,
    cancels: usize = 0,
    fn arm(self: *FakeDeadline) void {
        self.arms += 1;
    }
    fn cancel(self: *FakeDeadline) void {
        self.cancels += 1;
    }
};

const FakeFeedback = struct {
    listenings: usize = 0,
    releaseds: usize = 0,
    inserteds: usize = 0,
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
    fn abandoned(self: *FakeFeedback) void {
        self.abandoneds += 1;
    }
};

const TestDeps = struct {
    audio: *FakeAudio,
    transcription: *FakeTranscription,
    insertion: *FakeInsertion,
    deadline: *FakeDeadline,
    feedback: *FakeFeedback,
};

const Harness = struct {
    audio: FakeAudio = .{},
    transcription: FakeTranscription = .{},
    insertion: FakeInsertion = .{},
    deadline: FakeDeadline = .{},
    feedback: FakeFeedback = .{},
    co: Coordinator(TestDeps) = undefined,

    fn wire(self: *Harness) *Coordinator(TestDeps) {
        self.co = Coordinator(TestDeps).init(.{
            .audio = &self.audio,
            .transcription = &self.transcription,
            .insertion = &self.insertion,
            .deadline = &self.deadline,
            .feedback = &self.feedback,
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
    try expect(h.transcription.began == 1);
    try expect(h.audio.started == 1);
    try expect(h.feedback.listenings == 1);
    co.handle(.release);
    try expect(h.audio.stopped == 1);
    try expect(h.transcription.ended == 1);
    try expect(h.transcription.committed == 1);
    try expect(h.deadline.arms == 1);
    co.handle(.{ .final = "hello world" });
    try expect(h.deadline.cancels == 1);
    try expect(h.insertion.submits == 1);
    try expectEqualStrings("hello world", h.insertion.lastText());
    co.handle(.{ .inserted = .ok });
    try expect(h.feedback.inserteds == 1);
    try expect(h.feedback.abandoneds == 0);
    // Fully resolved — a fresh press is accepted again.
    co.handle(.press);
    try expect(h.transcription.began == 2);
}

test "2 press while non-idle is dropped" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press); // → capturing
    co.handle(.press); // dropped
    try expect(h.transcription.began == 1);
    try expect(h.audio.started == 1);
    try expect(h.feedback.listenings == 1);
}

test "3 press with no Transcription Session" {
    var h = Harness{};
    h.transcription.avail = false;
    const co = h.wire();
    co.handle(.press);
    try expect(h.transcription.began == 0);
    try expect(h.audio.started == 0);
    try expect(h.feedback.abandoneds == 1);
    try expect(h.feedback.listenings == 0);
}

test "4 release without an accepted press is a no-op" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.release);
    try expect(h.audio.stopped == 0);
    try expect(h.transcription.committed == 0);
    try expect(h.feedback.releaseds == 0);
}

test "5 capture.start failure aborts the Utterance" {
    var h = Harness{};
    h.audio.start_result = error.AudioQueueStart;
    const co = h.wire();
    co.handle(.press);
    try expect(h.transcription.began == 1);
    try expect(h.transcription.ended == 1); // rolled back
    try expect(h.feedback.abandoneds == 1);
    try expect(h.feedback.listenings == 0);
    // stayed idle — a new press is accepted
    h.audio.start_result = {};
    co.handle(.press);
    try expect(h.transcription.began == 2);
}

test "6 poison on release abandons without committing" {
    var h = Harness{};
    h.transcription.poisoned = true;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    try expect(h.transcription.committed == 0);
    try expect(h.deadline.arms == 0);
    try expect(h.feedback.abandoneds == 1);
}

test "7 silence still commits, just warns" {
    var h = Harness{};
    h.audio.heard = false;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    try expect(h.transcription.committed == 1);
    try expect(h.deadline.arms == 1);
    try expect(h.feedback.abandoneds == 0);
}

test "8 no audio committed → abandon at release" {
    var h = Harness{};
    h.transcription.commit_result = false;
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    try expect(h.transcription.committed == 1);
    try expect(h.deadline.arms == 0);
    try expect(h.feedback.abandoneds == 1);
    // resolved to idle
    h.transcription.commit_result = true;
    co.handle(.press);
    try expect(h.transcription.began == 2);
}

test "9 deadline before final abandons" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release); // → awaiting_final
    co.handle(.deadline);
    try expect(h.feedback.abandoneds == 1);
    try expect(h.insertion.submits == 0);
    // a stale final afterwards is ignored
    co.handle(.{ .final = "too late" });
    try expect(h.insertion.submits == 0);
}

test "10 empty/failed final inserts nothing" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = "" });
    try expect(h.deadline.cancels == 1);
    try expect(h.insertion.submits == 0);
    try expect(h.feedback.abandoneds == 1);
}

test "11 stale final outside awaiting is ignored" {
    var h = Harness{};
    const co = h.wire();
    // final with no Utterance in flight
    co.handle(.{ .final = "ghost" });
    try expect(h.insertion.submits == 0);
    // final while still capturing (before release) is also ignored
    co.handle(.press);
    co.handle(.{ .final = "early" });
    try expect(h.insertion.submits == 0);
}

test "12 insert failure sounds the error path" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = "text" });
    try expect(h.insertion.submits == 1);
    co.handle(.{ .inserted = .failed });
    try expect(h.feedback.inserteds == 0);
    try expect(h.feedback.abandoneds == 1);
    // resolved to idle regardless of insert outcome
    co.handle(.press);
    try expect(h.transcription.began == 2);
}

test "13 press during .inserting is dropped (ADR-0001)" {
    var h = Harness{};
    const co = h.wire();
    co.handle(.press);
    co.handle(.release);
    co.handle(.{ .final = "landing" }); // → inserting
    co.handle(.press); // must be dropped — one Utterance resolves fully first
    try expect(h.transcription.began == 1);
    try expect(h.audio.started == 1);
    // once the paste reports done, the next hold is accepted
    co.handle(.{ .inserted = .ok });
    co.handle(.press);
    try expect(h.transcription.began == 2);
}
