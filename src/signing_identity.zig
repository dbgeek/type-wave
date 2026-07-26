//! signing_identity.zig — the Signing Identity gate: the proof the daemon requires of an
//! executable before it hands that executable privileged work.
//!
//! Today it has exactly one subject, the Whisper Helper. The daemon verifies the *model* the
//! helper loads exhaustively (pinned URL + revision + SHA-256 + size + receipt + smoke test)
//! and then spawns the *code that loads it* off a path in the user's home directory. The
//! helper receives the PCM of every local Utterance, so swapping that binary swaps where the
//! microphone audio goes (wayfinder #284, review finding 5).
//!
//! **What the proof is, and why it is the signature.** The obvious candidate was the
//! receipt's `runtime_sha256` — the helper's digest, recorded at install time right after the
//! smoke test passed. It cannot be the gate. `packaging/install.sh` republishes the helper on
//! every upgrade while the receipt (whose `runtime` field is the constant whisper.cpp version,
//! not a type-wave version) is left untouched, so the recorded digest goes stale on an
//! ordinary upgrade — and nothing recovers it: Verify reads `usable`, Repair returns early on
//! `usable`, Install returns early on an already-present installation. Gating on it would
//! retire the local backend at the next upgrade, permanently, short of a 1.6 GB re-download.
//! It is also the weaker claim: an attacker who can write the helper can rewrite the plaintext
//! receipt beside it.
//!
//! The code signature has neither problem. It survives rebuilds — the `type-wave dev` identity
//! is stable across them, which is the same property `keychain.zig` already depends on to keep
//! the API key item's ACL working — and a leaf certificate is the one thing about the helper a
//! local file-writer cannot forge.
//!
//! **What we demand is what was demanded of us.** A proof anchors to the leaf certificate the
//! *running process* is signed with, so the gate is exactly as strong as this build's own
//! signing and never stronger. A daemon that carries no certificate chain of its own — an
//! unsigned or ad-hoc `zig-out` dev build — has no identity to demand and gates nothing; the
//! degrade is narrated once at startup rather than per spawn (`describeSelf`).
//!
//! **The asymmetry is deliberate.** An unreadable reading of *ourselves* fails open, because
//! refusing there would retire the local backend over an oddity in our own house — the same
//! trade the Insertion's Focused Target gate makes. An unverifiable *candidate* fails closed:
//! that is the thing being guarded.
//!
//! `decide` is the whole policy and is pure; everything Security.framework says arrives as a
//! fed reading, so the trade-offs above are asserted as values rather than against a signed
//! binary no test can produce.

const std = @import("std");

/// Every reason a proof can refuse. These are an error set rather than a tagged union so a
/// refusal rides out through `spawnWarm`'s `!` unchanged and reaches the log as its own name;
/// `isRefusal` is driven by the set itself, so a new reason is classified without a second
/// edit somewhere else.
pub const Refusal = error{
    /// We are signed and the candidate is not.
    HelperUnsigned,
    /// The candidate is signed, but not by our leaf certificate.
    HelperSignedByAnotherIdentity,
    /// We are signed and could not get an answer about the candidate at all.
    HelperSignatureUnverifiable,
};

pub fn isRefusal(err: anyerror) bool {
    inline for (@typeInfo(Refusal).error_set.error_names.?) |name| {
        if (err == @as(anyerror, @field(Refusal, name))) return true;
    }
    return false;
}

/// What the running process can say about its own code signature — the anchor a proof needs.
pub const SelfSigning = union(enum) {
    /// The SHA-1 of our own leaf certificate, which is what a code requirement names.
    leaf: [20]u8,
    /// We carry no certificate chain: unsigned, or ad-hoc signed.
    anonymous,
    /// The reading itself failed, with the OSStatus that said so.
    unreadable: i32,
};

/// What a validity check said about the candidate executable.
pub const Validity = union(enum) {
    valid,
    unsigned,
    /// Validly signed, but not by the identity the requirement named.
    requirement_failed,
    /// Any other OSStatus, including a candidate the checker could not read.
    failed: i32,
};

/// Why a spawn proceeded without a proof. Both arms mean *we* could not anchor one.
pub const Ungated = enum { self_anonymous, self_unreadable };

pub const Verdict = union(enum) {
    proved,
    ungated: Ungated,
    refused: Refusal,
};

/// The whole policy. `validity` is null when the candidate was never asked — which only
/// happens if we hold an anchor and the check could not be set up, and is therefore a
/// refusal, not a degrade.
pub fn decide(self_signing: SelfSigning, validity: ?Validity) Verdict {
    switch (self_signing) {
        .anonymous => return .{ .ungated = .self_anonymous },
        .unreadable => return .{ .ungated = .self_unreadable },
        .leaf => {},
    }
    const answer = validity orelse return .{ .refused = Refusal.HelperSignatureUnverifiable };
    return switch (answer) {
        .valid => .proved,
        .unsigned => .{ .refused = Refusal.HelperUnsigned },
        .requirement_failed => .{ .refused = Refusal.HelperSignedByAnotherIdentity },
        .failed => .{ .refused = Refusal.HelperSignatureUnverifiable },
    };
}

/// The seam a spawn takes. It is a required argument rather than an optional field so a new
/// spawn site has to say which gate it wants — `unproved` reads as the confession it is.
pub const Gate = struct {
    prove: *const fn (executable: []const u8) Verdict,

    /// Production: require the candidate to carry the leaf certificate we carry.
    pub const by_self_signature: Gate = .{ .prove = proveBySelfSignature };

    /// No proof at all. Only for the fake helper executables tests spawn — scripts and
    /// stubs that were never signed and never touch a microphone.
    pub const unproved: Gate = .{ .prove = alwaysProved };

    pub fn check(self: Gate, executable: []const u8) Refusal!void {
        return switch (self.prove(executable)) {
            .proved, .ungated => {},
            .refused => |reason| reason,
        };
    }
};

fn alwaysProved(_: []const u8) Verdict {
    return .proved;
}

fn proveBySelfSignature(executable: []const u8) Verdict {
    const self_signing = describeSelf();
    if (self_signing != .leaf) return decide(self_signing, null);
    return decide(self_signing, checkAgainstLeaf(executable, self_signing.leaf));
}

// ── the Security.framework readings ────────────────────────────────────────────────────
//
// Hand-written externs, the same style as keychain.zig / insert.zig / hud.zig.

const CFTypeRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFDictionaryRef = ?*anyopaque;
const CFArrayRef = ?*anyopaque;
const CFDataRef = ?*anyopaque;
const CFURLRef = ?*anyopaque;
const SecCodeRef = ?*anyopaque;
const SecStaticCodeRef = ?*anyopaque;
const SecRequirementRef = ?*anyopaque;
const SecCertificateRef = ?*anyopaque;
const CFIndex = c_long;

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kSecCSDefaultFlags: u32 = 0;
/// SecCode.h: ask `SecCodeCopySigningInformation` for the certificate chain.
const kSecCSSigningInformation: u32 = 1 << 1;

const errSecSuccess: i32 = 0;
/// CSCommon.h — the two answers that mean something specific rather than "it broke".
const errSecCSUnsigned: i32 = -67062;
const errSecCSReqFailed: i32 = -67050;

extern "c" fn CFRelease(cf: ?*anyopaque) void;
extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) CFStringRef;
extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?*anyopaque, buffer: [*]const u8, len: CFIndex, is_directory: u8) CFURLRef;
extern "c" fn CFDictionaryGetValue(dict: CFDictionaryRef, key: ?*const anyopaque) ?*anyopaque;
extern "c" fn CFArrayGetCount(array: CFArrayRef) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(array: CFArrayRef, index: CFIndex) ?*anyopaque;
extern "c" fn CFDataGetLength(data: CFDataRef) CFIndex;
extern "c" fn CFDataGetBytePtr(data: CFDataRef) ?[*]const u8;

extern "c" fn SecCodeCopySelf(flags: u32, self_code: *SecCodeRef) i32;
extern "c" fn SecCodeCopySigningInformation(code: SecStaticCodeRef, flags: u32, information: *CFDictionaryRef) i32;
extern "c" fn SecStaticCodeCreateWithPath(path: CFURLRef, flags: u32, static_code: *SecStaticCodeRef) i32;
extern "c" fn SecStaticCodeCheckValidity(static_code: SecStaticCodeRef, flags: u32, requirement: SecRequirementRef) i32;
extern "c" fn SecRequirementCreateWithString(text: CFStringRef, flags: u32, requirement: *SecRequirementRef) i32;
extern "c" fn SecCertificateCopyData(certificate: SecCertificateRef) CFDataRef;
extern var kSecCodeInfoCertificates: CFStringRef;

/// Read our own leaf certificate. Deliberately re-read per proof rather than cached: a spawn
/// is rare (a warm and the recovery ladder's relaunches), and a live answer beats one more
/// piece of process-lifetime state to reason about.
pub fn describeSelf() SelfSigning {
    var self_code: SecCodeRef = null;
    const copied = SecCodeCopySelf(kSecCSDefaultFlags, &self_code);
    if (copied != errSecSuccess) return .{ .unreadable = copied };
    defer CFRelease(self_code);

    var information: CFDictionaryRef = null;
    const status = SecCodeCopySigningInformation(self_code, kSecCSSigningInformation, &information);
    if (status == errSecCSUnsigned) return .anonymous;
    if (status != errSecSuccess) return .{ .unreadable = status };
    defer CFRelease(information);

    // An ad-hoc signature is a signature with no chain, so a missing or empty certificate
    // array is `anonymous` rather than a failure.
    const certificates: CFArrayRef = CFDictionaryGetValue(information, kSecCodeInfoCertificates) orelse return .anonymous;
    if (CFArrayGetCount(certificates) < 1) return .anonymous;
    const leaf: SecCertificateRef = CFArrayGetValueAtIndex(certificates, 0) orelse return .anonymous;

    const der: CFDataRef = SecCertificateCopyData(leaf) orelse return .anonymous;
    defer CFRelease(der);
    const bytes = CFDataGetBytePtr(der) orelse return .anonymous;
    const length = CFDataGetLength(der);
    if (length <= 0) return .anonymous;

    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes[0..@intCast(length)], &digest, .{});
    return .{ .leaf = digest };
}

/// Ask macOS whether `executable` carries `leaf`. The requirement names only the certificate,
/// not the signing identifier: "signed by us" is the whole claim, and pinning the helper's
/// identifier here would put a second copy of `install.sh`'s bundle id in the daemon.
fn checkAgainstLeaf(executable: []const u8, leaf: [20]u8) ?Validity {
    if (executable.len >= std.fs.max_path_bytes) return null;

    var requirement_buffer: [96]u8 = undefined;
    const written = std.fmt.bufPrint(
        &requirement_buffer,
        "certificate leaf = H\"{s}\"\x00",
        .{&std.fmt.bytesToHex(leaf, .lower)},
    ) catch return null;
    const requirement_text = written[0 .. written.len - 1 :0];

    const url = CFURLCreateFromFileSystemRepresentation(null, executable.ptr, @intCast(executable.len), 0) orelse return null;
    defer CFRelease(url);

    var static_code: SecStaticCodeRef = null;
    const created = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &static_code);
    if (created == errSecCSUnsigned) return .unsigned;
    if (created != errSecSuccess) return .{ .failed = created };
    defer CFRelease(static_code);

    const text = CFStringCreateWithCString(null, requirement_text.ptr, kCFStringEncodingUTF8) orelse return null;
    defer CFRelease(text);
    var requirement: SecRequirementRef = null;
    if (SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement) != errSecSuccess) return null;
    defer CFRelease(requirement);

    return switch (SecStaticCodeCheckValidity(static_code, kSecCSDefaultFlags, requirement)) {
        errSecSuccess => .valid,
        errSecCSUnsigned => .unsigned,
        errSecCSReqFailed => .requirement_failed,
        else => |status| .{ .failed = status },
    };
}

// ── tests ──────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const some_leaf: SelfSigning = .{ .leaf = @splat(0x11) };

test "a signed daemon proves a candidate that carries its leaf" {
    try testing.expectEqual(Verdict.proved, decide(some_leaf, .valid));
}

test "a signed daemon refuses every candidate answer that is not its leaf" {
    try testing.expectEqual(
        Refusal.HelperUnsigned,
        decide(some_leaf, .unsigned).refused,
    );
    try testing.expectEqual(
        Refusal.HelperSignedByAnotherIdentity,
        decide(some_leaf, .requirement_failed).refused,
    );
    try testing.expectEqual(
        Refusal.HelperSignatureUnverifiable,
        decide(some_leaf, .{ .failed = -1 }).refused,
    );
}

test "a candidate that could not be asked is refused, not waved through" {
    // The gate holds an anchor, so silence about the candidate is the guarded case.
    try testing.expectEqual(
        Refusal.HelperSignatureUnverifiable,
        decide(some_leaf, null).refused,
    );
}

test "a daemon with no identity of its own demands none, and says which way it failed open" {
    // An unsigned or ad-hoc dev build: nothing to anchor to, so nothing to require.
    try testing.expectEqual(Ungated.self_anonymous, decide(.anonymous, null).ungated);
    try testing.expectEqual(Ungated.self_unreadable, decide(.{ .unreadable = -67071 }, null).ungated);
    // …and it stays open even where the candidate's own answer would have refused: the
    // asymmetry is the point — our own house being odd must not retire the local backend.
    try testing.expectEqual(Ungated.self_anonymous, decide(.anonymous, .unsigned).ungated);
    try testing.expectEqual(Ungated.self_unreadable, decide(.{ .unreadable = -1 }, .unsigned).ungated);
}

test "isRefusal classifies every reason in the set, and nothing else" {
    inline for (@typeInfo(Refusal).error_set.error_names.?) |name| {
        try testing.expect(isRefusal(@field(Refusal, name)));
    }
    try testing.expect(!isRefusal(error.HelperSpawnFailed));
    try testing.expect(!isRefusal(error.FileNotFound));
}

test "the unproved gate is the only one that lets an unsigned stub through" {
    try Gate.unproved.check("/bin/does-not-matter");
}

test "a gate whose proof refuses surfaces the reason as an error" {
    const Refusing = struct {
        fn prove(_: []const u8) Verdict {
            return .{ .refused = Refusal.HelperSignedByAnotherIdentity };
        }
    };
    const gate = Gate{ .prove = Refusing.prove };
    try testing.expectError(Refusal.HelperSignedByAnotherIdentity, gate.check("/bin/anything"));
}
