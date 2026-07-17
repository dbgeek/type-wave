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
const backend = @import("transcription_backend.zig");

pub const UtteranceId = backend.UtteranceId;

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
    final: struct { id: UtteranceId, text: []const u8 },
    backend_failed: UtteranceId,
    deadline: UtteranceId,
    inserted: struct { id: UtteranceId, result: InsertResult },
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
        next_id: UtteranceId = 1,
        active: ?backend.Lease = null,
        poisoned: bool = false,

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
                .deadline => |id| self.onDeadline(id),
                .inserted => |e| self.onInserted(e.id, e.result),
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
                feedback.log("  Transcription Backend failed mid-Utterance — discarded; hold the Talk Key and say it again\n", .{});
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

            lease.release() catch |e| {
                feedback.log("  backend release failed: {s}\n", .{@errorName(e)});
                lease.cancel();
                self.abandon();
                return;
            };
            self.phase = .awaiting_final;
            self.deps.deadline.arm(lease.id, lease.deadline); // release-anchored; final cancels it
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
            self.deps.insertion.submit(id, text); // copies text; worker inserts, then .inserted
            self.phase = .inserting; // blocking: next hold waits (ADR-0001)
        }

        fn onDeadline(self: *Self, id: UtteranceId) void {
            if (!self.matches(id, .awaiting_final)) return;
            feedback.log("  no Final Transcript within the deadline — nothing inserted\n", .{});
            self.active.?.cancel();
            self.abandon();
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
                    feedback.log("  Transcription Backend failed before a Final Transcript arrived — nothing inserted\n", .{});
                    self.abandon();
                },
                .idle, .inserting => {},
            }
        }

        fn onInserted(self: *Self, id: UtteranceId, r: InsertResult) void {
            if (!self.matches(id, .inserting)) return;
            switch (r) {
                .ok => self.deps.feedback.inserted(),
                .failed => {
                    feedback.log("  insertion failed — nothing landed at the cursor\n", .{});
                    self.deps.feedback.abandoned();
                },
            }
            self.active = null;
            self.phase = .idle;
        }

        fn matches(self: *Self, id: UtteranceId, phase: Phase) bool {
            return self.phase == phase and self.active != null and self.active.?.id == id;
        }

        fn abandon(self: *Self) void {
            self.deps.feedback.abandoned();
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
    language: []const u8 = "en",
    policy: backend.DeadlinePolicy = backend.openai_deadline,
    began: usize = 0,
    appended: usize = 0,
    released: usize = 0,
    cancelled: usize = 0,
    last_id: UtteranceId = 0,

    const commands = backend.Commands{
        .begin = begin,
        .append_audio = appendAudio,
        .release = release,
        .cancel = cancel,
    };

    fn acquire(self: *FakeBackends, id: UtteranceId) ?backend.Lease {
        if (!self.avail) return null;
        return .{
            .id = id,
            .backend = self.backend_kind,
            .language = self.language,
            .deadline = self.policy,
            .ctx = self,
            .commands = &commands,
        };
    }
    fn from(ctx: *anyopaque) *FakeBackends {
        return @ptrCast(@alignCast(ctx));
    }
    fn begin(ctx: *anyopaque, id: UtteranceId, _: backend.Language) !void {
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
    fn cancel(ctx: *anyopaque, id: UtteranceId) void {
        const self = from(ctx);
        self.cancelled += 1;
        self.last_id = id;
    }
};

const FakeInsertion = struct {
    submits: usize = 0,
    last_id: UtteranceId = 0,
    last: [256]u8 = undefined,
    last_len: usize = 0,
    fn submit(self: *FakeInsertion, id: UtteranceId, text: []const u8) void {
        self.submits += 1;
        self.last_id = id;
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
    last_id: UtteranceId = 0,
    last_policy: backend.DeadlinePolicy = .{ .final_ms = 0 },
    fn arm(self: *FakeDeadline, id: UtteranceId, policy: backend.DeadlinePolicy) void {
        self.arms += 1;
        self.last_id = id;
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
    backends: *FakeBackends,
    insertion: *FakeInsertion,
    deadline: *FakeDeadline,
    feedback: *FakeFeedback,
};

const Harness = struct {
    audio: FakeAudio = .{},
    backends: FakeBackends = .{},
    insertion: FakeInsertion = .{},
    deadline: FakeDeadline = .{},
    feedback: FakeFeedback = .{},
    co: Coordinator(TestDeps) = undefined,

    fn wire(self: *Harness) *Coordinator(TestDeps) {
        self.co = Coordinator(TestDeps).init(.{
            .audio = &self.audio,
            .backends = &self.backends,
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
    try expect(h.feedback.inserteds == 1);
    try expect(h.feedback.abandoneds == 0);
    // Fully resolved — a fresh press is accepted again.
    co.handle(.press);
    try expect(h.backends.began == 2);
    try expectEqual(@as(UtteranceId, 2), h.backends.last_id);
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
    co.handle(.{ .deadline = 1 });
    try expect(h.feedback.abandoneds == 1);
    try expect(h.insertion.submits == 0);
    // a stale final afterwards is ignored
    co.handle(.{ .final = .{ .id = 1, .text = "too late" } });
    try expect(h.insertion.submits == 0);
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
    co.handle(.{ .deadline = 1 });
    co.handle(.press);
    try expectEqual(@as(UtteranceId, 2), h.backends.last_id);
}

test "15 mismatched duplicate late and phase-invalid events cannot advance an Utterance" {
    var h = Harness{};
    const co = h.wire();

    co.handle(.press); // id 1, capturing
    co.handle(.{ .final = .{ .id = 1, .text = "too early" } });
    co.handle(.{ .backend_failed = 99 });
    co.handle(.{ .deadline = 1 });
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });
    try expectEqual(@as(usize, 0), h.insertion.submits);
    try expectEqual(@as(usize, 0), h.feedback.abandoneds);

    co.handle(.release); // id 1, awaiting_final
    co.handle(.{ .final = .{ .id = 99, .text = "wrong Utterance" } });
    co.handle(.{ .deadline = 99 });
    try expectEqual(@as(usize, 0), h.insertion.submits);
    co.handle(.{ .final = .{ .id = 1, .text = "right Utterance" } });
    try expectEqual(@as(usize, 1), h.insertion.submits);
    try expectEqual(@as(UtteranceId, 1), h.insertion.last_id);

    co.handle(.{ .final = .{ .id = 1, .text = "duplicate" } });
    co.handle(.{ .deadline = 1 });
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
