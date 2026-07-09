//! readiness.zig - startup readiness policy for the daemon.
//!
//! This module owns the pure policy for setup prerequisites: whether the daemon is
//! configured, which status the menu should show, and when a distinct not-configured
//! missing set should be reported. It does not acquire prerequisites or perform side
//! effects. daemon.zig builds a Snapshot from the real adapters, logs returned report
//! lines, and plays cues.

const std = @import("std");

pub const Snapshot = struct {
    key_present: bool,
    input_monitoring_granted: bool,
    post_event_granted: bool,
    tap_enabled: bool,
    session_ready: bool,
    paused: bool,
};

pub const Status = enum {
    ready,
    reconnecting,
    no_key,
    input_monitoring_needed,
    accessibility_needed,
};

pub const Health = struct {
    paused: bool,
    status: Status,

    pub fn needsAttention(self: Health) bool {
        return self.paused or switch (self.status) {
            .no_key, .input_monitoring_needed, .accessibility_needed => true,
            .ready, .reconnecting => false,
        };
    }
};

const missing_key: u8 = 1;
const missing_input_monitoring: u8 = 2;
const missing_accessibility: u8 = 4;
const nothing_reported: u8 = 0xFF;

pub const Report = struct {
    lines: [3][]const u8 = undefined,
    count: usize = 0,

    pub fn slice(self: *const Report) []const []const u8 {
        return self.lines[0..self.count];
    }
};

pub const Reporter = struct {
    last_missing: u8 = nothing_reported,

    /// Returns a report only when the not-configured missing set changed. A configured
    /// snapshot resets the reporter so a later prerequisite loss is reported again.
    pub fn next(self: *Reporter, snap: Snapshot) ?Report {
        if (configured(snap)) {
            self.last_missing = nothing_reported;
            return null;
        }
        const missing = missingBits(snap);
        if (missing == self.last_missing) return null;
        self.last_missing = missing;
        return reportFor(missing);
    }
};

pub fn configured(snap: Snapshot) bool {
    return snap.key_present and
        snap.input_monitoring_granted and
        snap.post_event_granted and
        snap.tap_enabled;
}

pub fn health(snap: Snapshot) Health {
    if (!snap.key_present) return .{ .paused = snap.paused, .status = .no_key };
    if (!snap.input_monitoring_granted or !snap.tap_enabled)
        return .{ .paused = snap.paused, .status = .input_monitoring_needed };
    if (!snap.post_event_granted)
        return .{ .paused = snap.paused, .status = .accessibility_needed };
    return .{ .paused = snap.paused, .status = if (snap.session_ready) .ready else .reconnecting };
}

fn missingBits(snap: Snapshot) u8 {
    var missing: u8 = 0;
    if (!snap.key_present) missing |= missing_key;
    if (!snap.input_monitoring_granted or !snap.tap_enabled) missing |= missing_input_monitoring;
    if (!snap.post_event_granted) missing |= missing_accessibility;
    return missing;
}

fn reportFor(missing: u8) Report {
    var r: Report = .{};
    if ((missing & missing_key) != 0) {
        r.lines[r.count] = "    - OpenAI API key - use the menu bar's Set API Key... or run:  ~/.local/bin/type-wave --set-key  (login keychain, #33); export OPENAI_API_KEY instead for a foreground run";
        r.count += 1;
    }
    if ((missing & missing_input_monitoring) != 0) {
        r.lines[r.count] = "    - Input Monitoring for type-wave (System Settings > Privacy & Security > Input Monitoring)";
        r.count += 1;
    }
    if ((missing & missing_accessibility) != 0) {
        r.lines[r.count] = "    - Accessibility for type-wave (System Settings > Privacy & Security > Accessibility)";
        r.count += 1;
    }
    return r;
}

fn makeSnapshot(fields: struct {
    key_present: bool = true,
    input_monitoring_granted: bool = true,
    post_event_granted: bool = true,
    tap_enabled: bool = true,
    session_ready: bool = true,
    paused: bool = false,
}) Snapshot {
    return .{
        .key_present = fields.key_present,
        .input_monitoring_granted = fields.input_monitoring_granted,
        .post_event_granted = fields.post_event_granted,
        .tap_enabled = fields.tap_enabled,
        .session_ready = fields.session_ready,
        .paused = fields.paused,
    };
}

test "configured ignores pause and session readiness" {
    try std.testing.expect(configured(makeSnapshot(.{ .paused = true, .session_ready = false })));
}

test "configured requires setup prerequisites and a live tap" {
    try std.testing.expect(!configured(makeSnapshot(.{ .key_present = false })));
    try std.testing.expect(!configured(makeSnapshot(.{ .input_monitoring_granted = false })));
    try std.testing.expect(!configured(makeSnapshot(.{ .post_event_granted = false })));
    try std.testing.expect(!configured(makeSnapshot(.{ .tap_enabled = false })));
}

test "health uses setup priority before link state" {
    try std.testing.expectEqual(Status.no_key, health(makeSnapshot(.{ .key_present = false })).status);
    try std.testing.expectEqual(Status.input_monitoring_needed, health(makeSnapshot(.{ .input_monitoring_granted = false, .post_event_granted = false })).status);
    try std.testing.expectEqual(Status.accessibility_needed, health(makeSnapshot(.{ .post_event_granted = false })).status);
    try std.testing.expectEqual(Status.reconnecting, health(makeSnapshot(.{ .session_ready = false })).status);
    try std.testing.expectEqual(Status.ready, health(makeSnapshot(.{})).status);
}

test "pause affects attention but not status" {
    const h = health(makeSnapshot(.{ .paused = true }));
    try std.testing.expectEqual(Status.ready, h.status);
    try std.testing.expect(h.needsAttention());
}

test "reporter reports only distinct missing prerequisite sets" {
    var reporter: Reporter = .{};
    const missing = makeSnapshot(.{ .key_present = false, .post_event_granted = false });

    const first = reporter.next(missing) orelse return error.ExpectedReport;
    try std.testing.expectEqual(@as(usize, 2), first.count);
    try std.testing.expect(reporter.next(missing) == null);

    const changed = reporter.next(makeSnapshot(.{ .post_event_granted = false })) orelse return error.ExpectedReport;
    try std.testing.expectEqual(@as(usize, 1), changed.count);
    try std.testing.expect(std.mem.indexOf(u8, changed.slice()[0], "Accessibility") != null);
}

test "reporter resets after configured" {
    var reporter: Reporter = .{};
    const missing = makeSnapshot(.{ .key_present = false });

    try std.testing.expect(reporter.next(missing) != null);
    try std.testing.expect(reporter.next(missing) == null);
    try std.testing.expect(reporter.next(makeSnapshot(.{})) == null);
    try std.testing.expect(reporter.next(missing) != null);
}
