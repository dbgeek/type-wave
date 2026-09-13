//! Settings Snapshot Publication: main-thread edits and reloads share one owner.
//! Prepare before publishing; publish before effects; persist last. Accepted snapshots
//! retain their storage for the process lifetime, including values borrowed by readers.
const std = @import("std");
const config = @import("config.zig");
const backend = @import("transcription_backend.zig");

/// The daemon adapter and the recording test adapter cross this same effect seam.
pub const Effects = struct {
    ctx: *anyopaque,
    selectBackend: *const fn (*anyopaque, backend.Backend) void,
    markSessionDirty: *const fn (*anyopaque) void,
    markSessionRebias: *const fn (*anyopaque) void,
    setOverlay: *const fn (*anyopaque, bool) void,
};

pub const EditResult = struct {
    changed: bool,
    dropped: usize = 0,
    /// The edit is live even when this is non-null. Preparation failures instead
    /// return an error and have neither publication nor effects nor a disk write.
    save_error: ?anyerror = null,
};

pub const Publication = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    store: *config.Store,
    effects: Effects,
    path: ?[]const u8,
    retained: ?*Retained = null,

    const Retained = struct {
        arena: std.heap.ArenaAllocator,
        settings: config.Settings,
        previous: ?*Retained,
    };

    pub fn edit(self: *Publication, comptime field: []const u8, value: @FieldType(config.Settings, field)) !EditResult {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        var retained = false;
        defer if (!retained) arena.deinit();
        const alloc = arena.allocator();
        var next = self.store.current().*;
        var dropped: usize = 0;
        if (comptime std.mem.eql(u8, field, "vocabulary")) {
            const kept = config.clampVocabulary(alloc, value) orelse return error.OutOfMemory;
            const owned = try alloc.alloc([]const u8, kept.len);
            for (kept, 0..) |term, i| {
                if (!std.unicode.utf8ValidateSlice(term)) return error.InvalidUtf8;
                owned[i] = try alloc.dupe(u8, term);
            }
            next.vocabulary = owned;
            dropped = value.len - kept.len;
        } else if (@TypeOf(value) == []const u8) {
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
            @field(next, field) = try alloc.dupe(u8, value);
        } else {
            @field(next, field) = value;
        }
        // Serialization is preparation: a failure here cannot leave a half-applied edit.
        const zon = try config.fieldValueAlloc(alloc, field, @field(next, field));
        const diff = config.diffSettings(self.store.current(), &next);
        if (diff.any) {
            const node = try alloc.create(Retained);
            node.* = .{ .arena = arena, .settings = next, .previous = self.retained };
            self.retained = node;
            retained = true;
            self.publish(&node.settings, diff);
        }
        var result: EditResult = .{ .changed = diff.any, .dropped = dropped };
        const path = self.path orelse {
            result.save_error = error.NoSettingsPath;
            return result;
        };
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        config.writeFieldAt(self.io, scratch.allocator(), path, field, zon, next) catch |err| {
            result.save_error = err;
        };
        return result;
    }

    /// A valid file is authoritative, even over unsaved edits. Failure and no-change
    /// both leave the live pointer untouched; only failure returns an error.
    pub fn reload(self: *Publication) !bool {
        const path = self.path orelse return error.NoSettingsPath;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        var retained = false;
        defer if (!retained) arena.deinit();
        const alloc = arena.allocator();
        const next = try config.readSettingsAt(self.io, alloc, path);
        const diff = config.diffSettings(self.store.current(), &next);
        if (!diff.any) return false;
        const node = try alloc.create(Retained);
        node.* = .{ .arena = arena, .settings = next, .previous = self.retained };
        self.retained = node;
        retained = true;
        self.publish(&node.settings, diff);
        return true;
    }

    fn publish(self: *Publication, next: *const config.Settings, diff: config.Diff) void {
        // Store owns the log-policy-before-pointer ordering. Every callback sees next.
        self.store.swap(next);
        const e = self.effects;
        if (diff.backend_selection) e.selectBackend(e.ctx, next.transcription_backend);
        if (diff.session_shaped) e.markSessionDirty(e.ctx);
        if (diff.rebias) e.markSessionRebias(e.ctx);
        if (diff.overlay) e.setOverlay(e.ctx, next.overlay);
    }

    /// Test cleanup only, after every reader is gone. Production deliberately retains
    /// published snapshots; freeing one while a Session holds it would invalidate it.
    fn releaseForTest(self: *Publication) void {
        while (self.retained) |node| {
            self.retained = node.previous;
            var arena = node.arena;
            arena.deinit();
        }
    }
};

const Event = enum { backend, session, rebias, overlay };
const Rig = struct {
    tmp: std.testing.TmpDir = undefined,
    path_buf: [4096]u8 = undefined,
    path: []const u8 = undefined,
    first: config.Settings = .{},
    store: config.Store = undefined,
    publication: Publication = undefined,
    events: [32]Event = undefined,
    seen: [32]config.Settings = undefined,
    count: usize = 0,
    disk_overlay_at_effect: ?bool = null,

    fn init(self: *Rig) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buf: [4096]u8 = undefined;
        const n = try self.tmp.dir.realPath(std.testing.io, &root_buf);
        self.path = try std.fmt.bufPrint(&self.path_buf, "{s}/config.zon", .{root_buf[0..n]});
        self.store = .init(&self.first);
        self.publication = .{ .alloc = std.testing.allocator, .io = std.testing.io, .store = &self.store, .effects = .{
            .ctx = self,
            .selectBackend = select,
            .markSessionDirty = dirty,
            .markSessionRebias = rebias,
            .setOverlay = overlay,
        }, .path = self.path };
    }
    fn deinit(self: *Rig) void {
        self.publication.releaseForTest();
        self.tmp.cleanup();
        @import("feedback.zig").setLogTranscripts(false);
    }
    fn write(self: *Rig, text: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = text });
    }
    fn disk(self: *Rig, alloc: std.mem.Allocator) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, "config.zon", alloc, .limited(65536));
    }
    fn record(ctx: *anyopaque, event: Event) void {
        const self: *Rig = @ptrCast(@alignCast(ctx));
        self.events[self.count] = event;
        self.seen[self.count] = self.store.current().*;
        self.count += 1;
    }
    fn select(ctx: *anyopaque, _: backend.Backend) void {
        record(ctx, .backend);
    }
    fn dirty(ctx: *anyopaque) void {
        record(ctx, .session);
    }
    fn rebias(ctx: *anyopaque) void {
        record(ctx, .rebias);
    }
    fn overlay(ctx: *anyopaque, _: bool) void {
        record(ctx, .overlay);
        const self: *Rig = @ptrCast(@alignCast(ctx));
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        const settings = config.readSettingsAt(std.testing.io, scratch.allocator(), self.path) catch return;
        self.disk_overlay_at_effect = settings.overlay;
    }
};

test "publication precedes effects and persistence follows them; hand edits bind on reload" {
    var r = Rig{};
    try r.init();
    defer r.deinit();
    const before = "// keep my comment\n.{\n    .overlay = true,\n    .language = \"sv\",\n}\n";
    try r.write(before);
    const result = try r.publication.edit("overlay", false);
    try std.testing.expect(result.changed and result.save_error == null);
    try std.testing.expectEqualSlices(Event, &.{.overlay}, r.events[0..r.count]);
    try std.testing.expect(!r.seen[0].overlay);
    try std.testing.expectEqual(@as(?bool, true), r.disk_overlay_at_effect);
    try std.testing.expectEqualStrings("en", r.store.current().language);
    const saved = try r.disk(std.testing.allocator);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("// keep my comment\n.{\n    .overlay = false,\n    .language = \"sv\",\n}\n", saved);
    try std.testing.expect(try r.publication.reload());
    try std.testing.expectEqualSlices(Event, &.{ .overlay, .session }, r.events[0..r.count]);
    try std.testing.expectEqualStrings("sv", r.store.current().language);
}

test "reload dispatches every changed owner once and unchanged reload keeps the snapshot" {
    var r = Rig{};
    try r.init();
    defer r.deinit();
    try r.write(".{ .transcription_backend = .local, .model = \"custom\", .vocabulary = .{\"name\"}, .overlay = false, .log_transcripts = true }");
    try std.testing.expect(try r.publication.reload());
    try std.testing.expectEqualSlices(Event, &.{ .backend, .session, .rebias, .overlay }, r.events[0..r.count]);
    for (r.seen[0..r.count]) |s| {
        try std.testing.expectEqual(backend.Backend.local, s.transcription_backend);
        try std.testing.expectEqualStrings("custom", s.model);
        try std.testing.expectEqualStrings("name", s.vocabulary[0]);
        try std.testing.expect(!s.overlay and s.log_transcripts);
    }
    const live = r.store.current();
    try std.testing.expect(!try r.publication.reload());
    try std.testing.expectEqual(live, r.store.current());
    try std.testing.expectEqual(@as(usize, 4), r.count);
}

test "failed reload preserves live settings; valid empty file deliberately resets them" {
    var r = Rig{};
    try r.init();
    defer r.deinit();
    _ = try r.publication.edit("overlay", false);
    const live = r.store.current();
    r.count = 0;
    try r.tmp.dir.deleteFile(std.testing.io, "config.zon");
    try std.testing.expectError(error.FileNotFound, r.publication.reload());
    try r.write("malformed");
    if (r.publication.reload()) |_| return error.ExpectedReloadFailure else |_| {}
    try std.testing.expectEqual(live, r.store.current());
    try std.testing.expectEqual(@as(usize, 0), r.count);
    // A directory where the file should be exercises a read failure without chmod/root assumptions.
    try r.tmp.dir.deleteFile(std.testing.io, "config.zon");
    try r.tmp.dir.createDir(std.testing.io, "config.zon", .default_dir);
    if (r.publication.reload()) |_| return error.ExpectedReloadFailure else |_| {}
    try std.testing.expectEqual(live, r.store.current());
    try r.tmp.dir.deleteDir(std.testing.io, "config.zon");
    try r.write(".{}");
    try std.testing.expect(try r.publication.reload());
    try std.testing.expect(r.store.current().overlay);
    try std.testing.expectEqualSlices(Event, &.{.overlay}, r.events[0..r.count]);
}

test "unsaved edits stay live, same-value Save retries only persistence, valid reload wins" {
    var r = Rig{};
    try r.init();
    defer r.deinit();
    const old = ".{\n    .overlay = true,\n}\n";
    try r.write(old);
    // Block atomic creation of the write sibling, leaving an older valid file.
    try r.tmp.dir.createDir(std.testing.io, "config.zon.tmp", .default_dir);
    const result = try r.publication.edit("overlay", false);
    try std.testing.expect(result.changed and result.save_error != null);
    try std.testing.expect(!r.store.current().overlay);
    const live = r.store.current();
    r.count = 0;
    try r.tmp.dir.deleteDir(std.testing.io, "config.zon.tmp");
    const retry = try r.publication.edit("overlay", false);
    try std.testing.expect(!retry.changed and retry.save_error == null);
    try std.testing.expectEqual(live, r.store.current());
    try std.testing.expectEqual(@as(usize, 0), r.count);
    try r.write(old);
    try std.testing.expect(try r.publication.reload());
    try std.testing.expect(r.store.current().overlay);
}

test "malformed and unpatchable files survive edits byte-for-byte" {
    const cases = [_][]const u8{
        "a broken file with valuable comments",
        ".{\n    .vocabulary = .{\n        \"hand-edited\",\n    },\n    .language = \"sv\",\n}\n",
    };
    for (cases) |before| {
        var r = Rig{};
        try r.init();
        defer r.deinit();
        try r.write(before);
        const result = try r.publication.edit("vocabulary", &.{"new"});
        try std.testing.expect(result.changed and result.save_error != null);
        try std.testing.expectEqualSlices(Event, &.{.rebias}, r.events[0..r.count]);
        const after = try r.disk(std.testing.allocator);
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualStrings(before, after);
    }
}

test "publication owns borrowed Vocabulary and string values, clamps, and retains old snapshots" {
    var r = Rig{};
    try r.init();
    defer r.deinit();
    var term = [_]u8{ 'a', '"', '\\', '\n', 'z' };
    var too_long: [101]u8 = @splat('x');
    const result = try r.publication.edit("vocabulary", &.{ &term, " ", &too_long });
    try std.testing.expectEqual(@as(usize, 2), result.dropped);
    try std.testing.expect(result.save_error == null);
    const previous = r.store.current();
    const original = term;
    @memset(&term, 'x');
    try std.testing.expectEqualStrings(&original, previous.vocabulary[0]);
    var language = [_]u8{ 's', 'v' };
    _ = try r.publication.edit("language", &language);
    @memset(&language, 'x');
    try std.testing.expectEqualStrings("sv", r.store.current().language);
    try std.testing.expectEqualStrings(&original, previous.vocabulary[0]);
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const parsed = try config.readSettingsAt(std.testing.io, scratch.allocator(), r.path);
    try std.testing.expectEqualStrings(&original, parsed.vocabulary[0]);
}

test "every edit allocation failure either changes nothing or reports an unsaved live change" {
    var failure_index: usize = 0;
    while (failure_index < 100) : (failure_index += 1) {
        var r = Rig{};
        try r.init();
        defer r.deinit();
        const before = ".{\n    .vocabulary = .{},\n}\n";
        try r.write(before);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure_index });
        r.publication.alloc = failing.allocator();
        const result = r.publication.edit("vocabulary", &.{ "new", "words" }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(&r.first, r.store.current());
            try std.testing.expectEqual(@as(usize, 0), r.count);
            const after = try r.disk(std.testing.allocator);
            defer std.testing.allocator.free(after);
            try std.testing.expectEqualStrings(before, after);
            continue;
        };
        try std.testing.expect(result.changed);
        try std.testing.expectEqualStrings("new", r.store.current().vocabulary[0]);
        try std.testing.expectEqualSlices(Event, &.{.rebias}, r.events[0..r.count]);
        if (result.save_error != null) {
            const after = try r.disk(std.testing.allocator);
            defer std.testing.allocator.free(after);
            try std.testing.expectEqualStrings(before, after);
        }
        if (!failing.has_induced_failure) return;
    }
    return error.AllocationFailureSweepDidNotFinish;
}

test "reload allocation failure never publishes or dispatches" {
    var failure_index: usize = 0;
    while (failure_index < 100) : (failure_index += 1) {
        var r = Rig{};
        try r.init();
        defer r.deinit();
        try r.write(".{ .overlay = false, .vocabulary = .{\"new\"} }");
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure_index });
        r.publication.alloc = failing.allocator();
        const changed = r.publication.reload() catch {
            try std.testing.expectEqual(&r.first, r.store.current());
            try std.testing.expectEqual(@as(usize, 0), r.count);
            continue;
        };
        try std.testing.expect(changed);
        try std.testing.expectEqualSlices(Event, &.{ .rebias, .overlay }, r.events[0..r.count]);
        if (!failing.has_induced_failure) return;
    }
    return error.AllocationFailureSweepDidNotFinish;
}

test "a missing parent is created and string serialization agrees on full-file and patch paths" {
    var r = Rig{};
    try r.init();
    defer r.deinit();
    var nested_buf: [4096]u8 = undefined;
    r.publication.path = try std.fmt.bufPrint(&nested_buf, "{s}/nested/config.zon", .{std.fs.path.dirname(r.path).?});
    const quoted = "custom\"\\model\n";
    const first = try r.publication.edit("model", quoted);
    try std.testing.expect(first.save_error == null);
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const created = try config.readSettingsAt(std.testing.io, scratch.allocator(), r.publication.path.?);
    try std.testing.expectEqualStrings(quoted, created.model);
    const second = try r.publication.edit("model", "another\"model");
    try std.testing.expect(second.save_error == null);
    const patched = try config.readSettingsAt(std.testing.io, scratch.allocator(), r.publication.path.?);
    try std.testing.expectEqualStrings("another\"model", patched.model);
}

test "a compact empty file accepts an absent field and a full-size Vocabulary" {
    var r = Rig{};
    try r.init();
    defer r.deinit();
    try r.write(".{}");
    var terms: [128][]const u8 = @splat("a-term-with-enough-bytes-to-exceed-a-small-buffer");
    const result = try r.publication.edit("vocabulary", &terms);
    try std.testing.expect(result.save_error == null);
    try std.testing.expectEqual(@as(usize, 0), result.dropped);
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const parsed = try config.readSettingsAt(std.testing.io, scratch.allocator(), r.path);
    try std.testing.expectEqual(@as(usize, 128), parsed.vocabulary.len);
    try std.testing.expectEqualStrings(terms[127], parsed.vocabulary[127]);
}

test "invalid typed text is refused before publication, effects or persistence" {
    var r = Rig{};
    try r.init();
    defer r.deinit();
    try r.write(".{}");
    try std.testing.expectError(error.InvalidUtf8, r.publication.edit("model", &.{0xff}));
    try std.testing.expectError(error.InvalidUtf8, r.publication.edit("vocabulary", &.{&.{0xff}}));
    try std.testing.expectEqual(&r.first, r.store.current());
    try std.testing.expectEqual(@as(usize, 0), r.count);
    const unchanged = try r.disk(std.testing.allocator);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(".{}", unchanged);
}
