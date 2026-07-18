//! The Segmenter owns the silence-cut policy (ADR-0003): it accumulates one Utterance's
//! Capture and decides where each Segment ends — a 15 s soft floor, then the next ≥400 ms
//! pause, with a 25 s hard-max force-cut. It is a pure state machine: a Capture buffer and
//! its per-buffer RMS level go in, an owned Segment's PCM comes out at each cut. It holds no
//! queue, no lease, no mutex and never touches the helper — the Adapter drives it under its
//! own lock and owns everything past the cut (see local_backend.zig). Keeping the cut policy
//! here lets the churniest logic in the backend be tested by feeding synthetic (rms, pcm)
//! pairs, with no helper subprocess and no real audio.

const std = @import("std");

/// Silence-cut tuning (ADR-0003). Bytes are 24 kHz · 2 B mono, i.e. 48 kB per second of
/// Capture. Defaults are the grilled values; tests override them to exercise cuts cheaply.
pub const SegmentPolicy = struct {
    /// Never cut before this much Capture has accumulated — a short Utterance is one Segment.
    soft_floor_bytes: usize = 24_000 * 2 * 15, // 15 s
    /// Force a cut here even mid-word when no pause has come. Kept under `max_pcm_len`.
    hard_max_bytes: usize = 24_000 * 2 * 25, // 25 s
    /// A pause is this many consecutive quiet bytes (RMS below `silence_rms`).
    pause_bytes: usize = 24_000 * 2 * 400 / 1_000, // 400 ms
    /// A 50 ms buffer whose RMS (0..1 of full scale) is under this counts as quiet.
    silence_rms: f32 = 0.015,
};

pub const Segmenter = struct {
    policy: SegmentPolicy = .{},
    /// The Segment currently being accumulated from Capture (not yet cut).
    seg: std.ArrayList(u8) = .empty,
    /// Trailing run of quiet Capture bytes in `seg`, for the ≥400 ms pause test.
    quiet_run_bytes: usize = 0,
    /// Whether `seg` has held any above-threshold audio — a silence-cut needs speech to close
    /// off, so leading silence never spawns a spurious Segment.
    has_speech: bool = false,

    /// Accumulate one Capture buffer and its RMS level. Returns the finished Segment's owned
    /// PCM when this buffer closes a cut (the caller takes ownership), else null. Past the soft
    /// floor a cut lands at the next pause; the hard max forces one even mid-word (the only
    /// case that can split a word); below the floor a short Utterance stays whole.
    pub fn push(self: *Segmenter, allocator: std.mem.Allocator, rms: f32, pcm: []const u8) !?[]u8 {
        try self.seg.appendSlice(allocator, pcm);
        if (rms < self.policy.silence_rms) {
            self.quiet_run_bytes += pcm.len;
        } else {
            self.quiet_run_bytes = 0;
            self.has_speech = true;
        }
        const at_hard_max = self.seg.items.len >= self.policy.hard_max_bytes;
        const at_pause = self.seg.items.len >= self.policy.soft_floor_bytes and
            self.has_speech and self.quiet_run_bytes >= self.policy.pause_bytes;
        if (at_hard_max or at_pause) return try self.cut(allocator);
        return null;
    }

    /// Hand back the trailing partial Segment on release, or null if nothing has accumulated
    /// (the caller reads that as an empty Capture).
    pub fn flush(self: *Segmenter, allocator: std.mem.Allocator) !?[]u8 {
        if (self.seg.items.len == 0) return null;
        return try self.cut(allocator);
    }

    /// Take ownership of the accumulated Segment and re-arm the pause accounting for the next.
    fn cut(self: *Segmenter, allocator: std.mem.Allocator) ![]u8 {
        const pcm = try self.seg.toOwnedSlice(allocator);
        self.quiet_run_bytes = 0;
        self.has_speech = false;
        return pcm;
    }

    /// Drop any half-accumulated Segment between Utterances. The Adapter frees the queued,
    /// already-cut Segments itself.
    pub fn reset(self: *Segmenter) void {
        self.seg.clearRetainingCapacity();
        self.quiet_run_bytes = 0;
        self.has_speech = false;
    }

    pub fn deinit(self: *Segmenter, allocator: std.mem.Allocator) void {
        self.seg.deinit(allocator);
    }
};

const testing = std.testing;

// A test policy exercises real cuts over a handful of 4-byte buffers, with an RMS threshold
// sitting between silent (0) and full-scale (1) so `quiet`/`loud` read as pause/speech.
const quiet: f32 = 0.0;
const loud: f32 = 1.0;

test "below the soft floor nothing is cut — a short Utterance stays one Segment" {
    var s = Segmenter{ .policy = .{ .soft_floor_bytes = 100, .hard_max_bytes = 200, .pause_bytes = 4, .silence_rms = 0.5 } };
    defer s.deinit(testing.allocator);

    try testing.expect((try s.push(testing.allocator, loud, &.{ 1, 2, 3, 4 })) == null);
    try testing.expect((try s.push(testing.allocator, quiet, &.{ 5, 6, 7, 8 })) == null);

    // The whole Utterance comes out on flush, in spoken order, as one Segment.
    const cut = (try s.flush(testing.allocator)).?;
    defer testing.allocator.free(cut);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, cut);
}

test "leading silence never spawns a Segment" {
    var s = Segmenter{ .policy = .{ .soft_floor_bytes = 4, .hard_max_bytes = 200, .pause_bytes = 4, .silence_rms = 0.5 } };
    defer s.deinit(testing.allocator);

    // Past the soft floor but silent throughout: no speech to close off, so no cut.
    try testing.expect((try s.push(testing.allocator, quiet, &.{ 0, 0, 0, 0 })) == null);
    try testing.expect((try s.push(testing.allocator, quiet, &.{ 0, 0, 0, 0 })) == null);
    try testing.expect(!s.has_speech);
}

test "past the soft floor a pause cuts a Segment and re-arms" {
    var s = Segmenter{ .policy = .{ .soft_floor_bytes = 4, .hard_max_bytes = 200, .pause_bytes = 4, .silence_rms = 0.5 } };
    defer s.deinit(testing.allocator);

    try testing.expect((try s.push(testing.allocator, loud, &.{ 1, 2, 3, 4 })) == null); // speech, at floor, no pause yet
    const cut = (try s.push(testing.allocator, quiet, &.{ 5, 6, 7, 8 })).?; // the pause closes the Segment
    defer testing.allocator.free(cut);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, cut);

    // The buffer and pause accounting are cleared for the next Segment.
    try testing.expectEqual(@as(usize, 0), s.seg.items.len);
    try testing.expect(!s.has_speech);
    try testing.expectEqual(@as(usize, 0), s.quiet_run_bytes);
}

test "unbroken speech is force-cut at the hard max" {
    var s = Segmenter{ .policy = .{ .soft_floor_bytes = 4, .hard_max_bytes = 8, .pause_bytes = 4, .silence_rms = 0.5 } };
    defer s.deinit(testing.allocator);

    try testing.expect((try s.push(testing.allocator, loud, &.{ 1, 2, 3, 4 })) == null); // seg = 4
    const cut = (try s.push(testing.allocator, loud, &.{ 5, 6, 7, 8 })).?; // seg = 8 == hard max, no pause ever
    defer testing.allocator.free(cut);
    try testing.expectEqual(@as(usize, 8), cut.len);
}

test "speech resets the quiet run, so a lone quiet buffer does not complete a pause" {
    var s = Segmenter{ .policy = .{ .soft_floor_bytes = 4, .hard_max_bytes = 200, .pause_bytes = 8, .silence_rms = 0.5 } };
    defer s.deinit(testing.allocator);

    try testing.expect((try s.push(testing.allocator, loud, &.{ 1, 2, 3, 4 })) == null); // speech
    try testing.expect((try s.push(testing.allocator, quiet, &.{ 0, 0, 0, 0 })) == null); // quiet_run = 4 (< 8)
    try testing.expect((try s.push(testing.allocator, loud, &.{ 5, 6, 7, 8 })) == null); // speech resets quiet_run to 0
    // Only 4 quiet bytes have accrued since the speech — short of the 8-byte pause — so no cut.
    try testing.expect((try s.push(testing.allocator, quiet, &.{ 0, 0, 0, 0 })) == null);
    try testing.expectEqual(@as(usize, 4), s.quiet_run_bytes);
}

test "flush on an empty Segmenter yields nothing" {
    var s = Segmenter{};
    defer s.deinit(testing.allocator);
    try testing.expect((try s.flush(testing.allocator)) == null);
}

test "flush after a cut returns only the trailing remainder" {
    var s = Segmenter{ .policy = .{ .soft_floor_bytes = 4, .hard_max_bytes = 8, .pause_bytes = 4, .silence_rms = 0.5 } };
    defer s.deinit(testing.allocator);

    const first = (try s.push(testing.allocator, loud, &.{ 1, 2, 3, 4, 5, 6, 7, 8 })).?; // seg hits the hard max → cut
    defer testing.allocator.free(first);
    try testing.expectEqual(@as(usize, 8), first.len);

    // A short trailing bit after the cut comes out alone on flush.
    try testing.expect((try s.push(testing.allocator, loud, &.{ 9, 10 })) == null);
    const tail = (try s.flush(testing.allocator)).?;
    defer testing.allocator.free(tail);
    try testing.expectEqualSlices(u8, &.{ 9, 10 }, tail);
}
