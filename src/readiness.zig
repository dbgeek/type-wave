//! readiness.zig - startup readiness policy for the daemon.
//!
//! This module owns the pure policy for setup prerequisites: whether the daemon is
//! configured, which status the menu should show, and when a distinct not-configured
//! missing set should be reported. It does not acquire prerequisites or perform side
//! effects. daemon.zig builds a Snapshot from the real adapters, logs returned report
//! lines, and plays cues.

const std = @import("std");
const backend = @import("transcription_backend.zig");

pub const Snapshot = struct {
    selected_backend: backend.Backend,
    key_present: bool,
    local_installation_present: bool,
    microphone_granted: bool,
    input_monitoring_granted: bool,
    post_event_granted: bool,
    tap_enabled: bool,
    backend_ready: bool,
    paused: bool,
};

pub const Status = enum {
    ready,
    ready_offline,
    reconnecting,
    preparing_local,
    no_key,
    no_local_installation,
    microphone_needed,
    input_monitoring_needed,
    accessibility_needed,
};

pub const Health = struct {
    paused: bool,
    status: Status,

    pub fn needsAttention(self: Health) bool {
        return self.paused or switch (self.status) {
            .no_key, .no_local_installation, .microphone_needed, .input_monitoring_needed, .accessibility_needed => true,
            .ready, .ready_offline, .reconnecting, .preparing_local => false,
        };
    }
};

const missing_key: u8 = 1;
const missing_local_installation: u8 = 8;
const missing_microphone: u8 = 16;
const missing_input_monitoring: u8 = 2;
const missing_accessibility: u8 = 4;
const nothing_reported: u8 = 0xFF;

pub const Report = struct {
    lines: [4][]const u8 = undefined,
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
    const backend_prerequisite = switch (snap.selected_backend) {
        .openai => snap.key_present,
        .local_kb_whisper => snap.local_installation_present,
    };
    return backend_prerequisite and
        snap.microphone_granted and
        snap.input_monitoring_granted and
        snap.post_event_granted and
        snap.tap_enabled;
}

pub fn health(snap: Snapshot) Health {
    if (!snap.microphone_granted)
        return .{ .paused = snap.paused, .status = .microphone_needed };
    if (!snap.input_monitoring_granted or !snap.tap_enabled)
        return .{ .paused = snap.paused, .status = .input_monitoring_needed };
    if (!snap.post_event_granted)
        return .{ .paused = snap.paused, .status = .accessibility_needed };
    return switch (snap.selected_backend) {
        .openai => if (!snap.key_present)
            .{ .paused = snap.paused, .status = .no_key }
        else
            .{ .paused = snap.paused, .status = if (snap.backend_ready) .ready else .reconnecting },
        .local_kb_whisper => if (!snap.local_installation_present)
            .{ .paused = snap.paused, .status = .no_local_installation }
        else
            .{ .paused = snap.paused, .status = if (snap.backend_ready) .ready_offline else .preparing_local },
    };
}

fn missingBits(snap: Snapshot) u8 {
    var missing: u8 = 0;
    switch (snap.selected_backend) {
        .openai => if (!snap.key_present) {
            missing |= missing_key;
        },
        .local_kb_whisper => if (!snap.local_installation_present) {
            missing |= missing_local_installation;
        },
    }
    if (!snap.microphone_granted) missing |= missing_microphone;
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
    if ((missing & missing_local_installation) != 0) {
        r.lines[r.count] = "    - verified local KB Whisper Model Installation";
        r.count += 1;
    }
    if ((missing & missing_microphone) != 0) {
        r.lines[r.count] = "    - Microphone for type-wave (System Settings > Privacy & Security > Microphone)";
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
    selected_backend: backend.Backend = .openai,
    key_present: bool = true,
    local_installation_present: bool = false,
    microphone_granted: bool = true,
    input_monitoring_granted: bool = true,
    post_event_granted: bool = true,
    tap_enabled: bool = true,
    backend_ready: bool = true,
    paused: bool = false,
}) Snapshot {
    return .{
        .selected_backend = fields.selected_backend,
        .key_present = fields.key_present,
        .local_installation_present = fields.local_installation_present,
        .microphone_granted = fields.microphone_granted,
        .input_monitoring_granted = fields.input_monitoring_granted,
        .post_event_granted = fields.post_event_granted,
        .tap_enabled = fields.tap_enabled,
        .backend_ready = fields.backend_ready,
        .paused = fields.paused,
    };
}

test "configured ignores pause and session readiness" {
    try std.testing.expect(configured(makeSnapshot(.{ .paused = true, .backend_ready = false })));
}

test "configured requires setup prerequisites and a live tap" {
    try std.testing.expect(!configured(makeSnapshot(.{ .microphone_granted = false })));
    try std.testing.expect(!configured(makeSnapshot(.{ .key_present = false })));
    try std.testing.expect(!configured(makeSnapshot(.{ .input_monitoring_granted = false })));
    try std.testing.expect(!configured(makeSnapshot(.{ .post_event_granted = false })));
    try std.testing.expect(!configured(makeSnapshot(.{ .tap_enabled = false })));
}

test "Configuration Phase uses only the selected backend durable prerequisite" {
    try std.testing.expect(configured(makeSnapshot(.{
        .selected_backend = .local_kb_whisper,
        .key_present = false,
        .local_installation_present = true,
    })));
    try std.testing.expect(!configured(makeSnapshot(.{
        .selected_backend = .local_kb_whisper,
        .key_present = true,
        .local_installation_present = false,
    })));
}

test "local readiness is offline and reports a missing Model Installation distinctly" {
    const ready_local = health(makeSnapshot(.{
        .selected_backend = .local_kb_whisper,
        .key_present = false,
        .local_installation_present = true,
    }));
    try std.testing.expectEqual(Status.ready_offline, ready_local.status);

    const missing = makeSnapshot(.{
        .selected_backend = .local_kb_whisper,
        .key_present = false,
        .local_installation_present = false,
    });
    try std.testing.expectEqual(Status.no_local_installation, health(missing).status);
    const report = reportFor(missingBits(missing));
    try std.testing.expect(std.mem.indexOf(u8, report.slice()[0], "Model Installation") != null);
}

test "health uses setup priority before link state" {
    try std.testing.expectEqual(Status.no_key, health(makeSnapshot(.{ .key_present = false })).status);
    try std.testing.expectEqual(Status.input_monitoring_needed, health(makeSnapshot(.{ .input_monitoring_granted = false, .post_event_granted = false })).status);
    try std.testing.expectEqual(Status.accessibility_needed, health(makeSnapshot(.{ .post_event_granted = false })).status);
    try std.testing.expectEqual(Status.reconnecting, health(makeSnapshot(.{ .backend_ready = false })).status);
    try std.testing.expectEqual(Status.ready, health(makeSnapshot(.{})).status);
    try std.testing.expectEqual(Status.microphone_needed, health(makeSnapshot(.{ .microphone_granted = false, .input_monitoring_granted = false })).status);
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
