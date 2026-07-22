//! Models Layout — the single owner of the on-disk path grammar of the models root.
//!
//! Every path under the models root (`active.receipt` and its `.tmp` sibling,
//! `installations/{id}` and the `PROVENANCE` / `MODEL_MANIFEST` files inside each, the
//! `staging-{id}` and `{id}-repair-{ns}` generation directories and their `partial.meta`,
//! and the `.operation.lock` / `.runtime.lock` / `.inference.lock` / `.removal.pending`
//! gate files) is spelled here and nowhere else. model_store owns every read/write; this
//! module owns only *where* the bytes live. It is pure and allocation-free — like the
//! Installation Receipt codec (`receipt.zig`) — so it is exercised directly by fed values
//! rather than through a real filesystem: each accessor writes into a caller-provided
//! `[std.fs.max_path_bytes]u8` buffer and callers that need an owned path dupe the result.
//!
//! The directory-relative half (`Layout.Dir`) is shared with the Whisper Helper process
//! (`whisper_helper.zig`), so the `MODEL_MANIFEST` / `PROVENANCE` file names are single-homed
//! across both processes: a rename here cannot silently desync the helper's identity read.

const std = @import("std");

/// The receipt the daemon reads to find the active Model Installation.
pub const active_receipt_name = "active.receipt";
/// The directory holding every immutable installation generation.
pub const installations_dir_name = "installations";
/// The provenance mirror written inside each installation directory.
pub const provenance_name = "PROVENANCE";
/// The bare size/sha256 identity written inside each installation directory.
pub const manifest_name = "MODEL_MANIFEST";
/// The download-resume record inside a staging directory.
pub const partial_meta_name = "partial.meta";

/// The cross-process gate files that sit directly at the models root.
pub const operation_lock_name = ".operation.lock";
pub const runtime_lock_name = ".runtime.lock";
pub const inference_lock_name = ".inference.lock";
pub const removal_intent_name = ".removal.pending";

const staging_prefix = "staging-";
const repair_infix = "-repair-";
const tmp_suffix = ".tmp";

/// The path grammar rooted at one models root. Methods that depend on the root are member
/// functions; the root-independent name helpers and matchers are namespaced functions.
pub const Layout = struct {
    root: []const u8,

    pub fn init(root: []const u8) Layout {
        return .{ .root = root };
    }

    /// `{root}/{name}` — the gate files (locks, removal intent) that sit at the root.
    pub fn child(self: Layout, name: []const u8, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.root, name });
    }

    pub fn activeReceipt(self: Layout, buffer: []u8) ![]const u8 {
        return self.child(active_receipt_name, buffer);
    }

    /// The `.tmp` sibling the active receipt is written to before the atomic rename.
    pub fn activeReceiptTmp(self: Layout, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}{s}", .{ self.root, active_receipt_name, tmp_suffix });
    }

    pub fn installations(self: Layout, buffer: []u8) ![]const u8 {
        return self.child(installations_dir_name, buffer);
    }

    /// `{root}/installations/{id}`. A repair generation is an installation dir whose id is
    /// `repairName(...)`, so this builds those too.
    pub fn installationDir(self: Layout, id: []const u8, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}/{s}", .{ self.root, installations_dir_name, id });
    }

    pub fn stagingDir(self: Layout, id: []const u8, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}{s}", .{ self.root, staging_prefix, id });
    }

    /// The bare `staging-{id}` basename — for comparing against a directory entry's name.
    pub fn stagingName(id: []const u8, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ staging_prefix, id });
    }

    /// The generation directory name for a repaired installation, timestamped by the
    /// prepared artifact's mtime. The caller supplies the nanoseconds — Layout reads no
    /// clock and touches no filesystem, so the naming convention stays testable by value.
    pub fn repairName(id: []const u8, mtime_ns: anytype, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}{s}{d}", .{ id, repair_infix, mtime_ns });
    }

    /// Whether a directory entry is a staging directory — the reverse of `stagingDir`, so
    /// the `staging-` prefix is spelled once for both construction and iteration.
    pub fn isStagingDir(name: []const u8) bool {
        return std.mem.startsWith(u8, name, staging_prefix);
    }

    /// Whether a directory name is a repair generation — the reverse of `repairName`.
    pub fn isRepairDir(name: []const u8) bool {
        return std.mem.indexOf(u8, name, repair_infix) != null;
    }

    /// Wrap an already-built directory path — an installation dir, a staging dir, or the
    /// `dirname` of a model path — so its sibling files are spelled through one accessor.
    pub fn dir(path: []const u8) Dir {
        return .{ .path = path };
    }

    /// The files that live inside an installation-holding directory, independent of whether
    /// that directory is an active installation, a staging area, or a repair generation.
    pub const Dir = struct {
        path: []const u8,

        pub fn model(self: Dir, artifact: []const u8, buffer: []u8) ![]const u8 {
            return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.path, artifact });
        }

        pub fn provenance(self: Dir, buffer: []u8) ![]const u8 {
            return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.path, provenance_name });
        }

        pub fn manifest(self: Dir, buffer: []u8) ![]const u8 {
            return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.path, manifest_name });
        }

        pub fn partialMeta(self: Dir, buffer: []u8) ![]const u8 {
            return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.path, partial_meta_name });
        }

        /// The `.tmp` sibling `partial.meta` is written to before its atomic rename.
        pub fn partialMetaTmp(self: Dir, buffer: []u8) ![]const u8 {
            return std.fmt.bufPrint(buffer, "{s}/{s}{s}", .{ self.path, partial_meta_name, tmp_suffix });
        }
    };
};

// --- Oracle tests: assert the exact bytes against hard-coded literals. These are the
// independent ground truth — model_store's fixtures consume Layout, so a wrong template
// here fails loudly regardless of what model_store does. ---

const testing = std.testing;

test "root-anchored receipt and its tmp sibling" {
    const l = Layout.init("/models");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/models/active.receipt", try l.activeReceipt(&buf));
    try testing.expectEqualStrings("/models/active.receipt.tmp", try l.activeReceiptTmp(&buf));
}

test "installations base and an installation directory" {
    const l = Layout.init("/models");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/models/installations", try l.installations(&buf));
    try testing.expectEqualStrings("/models/installations/98aa99a0a9db-f16", try l.installationDir("98aa99a0a9db-f16", &buf));
}

test "gate files route through child with the shared name constants" {
    const l = Layout.init("/models");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/models/.operation.lock", try l.child(operation_lock_name, &buf));
    try testing.expectEqualStrings("/models/.runtime.lock", try l.child(runtime_lock_name, &buf));
    try testing.expectEqualStrings("/models/.inference.lock", try l.child(inference_lock_name, &buf));
    try testing.expectEqualStrings("/models/.removal.pending", try l.child(removal_intent_name, &buf));
}

test "staging directory, its bare name, and the matcher agree" {
    const l = Layout.init("/models");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    const id = "98aa99a0a9db-f16";
    try testing.expectEqualStrings("/models/staging-98aa99a0a9db-f16", try l.stagingDir(id, &buf));
    const name = try Layout.stagingName(id, &name_buf);
    try testing.expectEqualStrings("staging-98aa99a0a9db-f16", name);
    try testing.expect(Layout.isStagingDir(name));
    try testing.expect(!Layout.isStagingDir("installations"));
}

test "repair name is built from a caller-supplied timestamp and matched in reverse" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const name = try Layout.repairName("98aa99a0a9db-f16", @as(i96, 1234567890), &buf);
    try testing.expectEqualStrings("98aa99a0a9db-f16-repair-1234567890", name);
    try testing.expect(Layout.isRepairDir(name));
    try testing.expect(!Layout.isRepairDir("98aa99a0a9db-f16"));
}

test "a repair generation is an installation dir whose id is the repair name" {
    const l = Layout.init("/models");
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const generation = try Layout.repairName("m", @as(i96, 42), &name_buf);
    try testing.expectEqualStrings("/models/installations/m-repair-42", try l.installationDir(generation, &dir_buf));
}

test "directory-relative files are spelled once, whatever the directory kind" {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;

    const l = Layout.init("/models");
    const install = try l.installationDir("m", &dir_buf);
    const d = Layout.dir(install);
    try testing.expectEqualStrings("/models/installations/m/ggml.bin", try d.model("ggml.bin", &file_buf));
    try testing.expectEqualStrings("/models/installations/m/PROVENANCE", try d.provenance(&file_buf));
    try testing.expectEqualStrings("/models/installations/m/MODEL_MANIFEST", try d.manifest(&file_buf));
}

test "staging directory holds partial.meta and its tmp sibling" {
    const l = Layout.init("/models");
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const stage = Layout.dir(try l.stagingDir("m", &dir_buf));
    try testing.expectEqualStrings("/models/staging-m/partial.meta", try stage.partialMeta(&file_buf));
    try testing.expectEqualStrings("/models/staging-m/partial.meta.tmp", try stage.partialMetaTmp(&file_buf));
}

test "the verify path derives an installation Dir from dirname(model)" {
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = "/models/installations/m/ggml.bin";
    const d = Layout.dir(std.fs.path.dirname(model_path).?);
    // The provenance the daemon compares against the receipt is spelled through the same
    // accessor that wrote it, so receipt ≡ PROVENANCE cannot drift on path alone.
    try testing.expectEqualStrings("/models/installations/m/PROVENANCE", try d.provenance(&file_buf));
}
