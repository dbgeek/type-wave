//! keychain.zig — the OpenAI API key's home (wayfinder #33): one generic password in
//! the file-based **login keychain**, driven through the SecItem C API.
//!
//! Everything here follows the research crib sheet
//! (docs/research/macos-keychain-generic-passwords.md, wayfinder #30):
//!
//!   - **File-based keychain, not the data protection keychain** — the DP keychain needs a
//!     keychain-access-groups entitlement authorized by a provisioning profile, which a
//!     self-signed unbundled CLI cannot carry. SecItem defaults to the file-based keychain
//!     on macOS, so we simply never pass `kSecUseDataProtectionKeychain`.
//!   - **No `kSecAttrAccessible`** — unsupported for file-based items (SecItem.h); the login
//!     keychain is unlocked while the user is logged in, which covers the LaunchAgent.
//!   - **Uniqueness = (service, account)**, so the write path is Quinn's "Prefer to Update"
//!     dance: `SecItemAdd` → on `errSecDuplicateItem` → `SecItemUpdate`. Never
//!     delete-and-re-add — an update preserves the item's ACL.
//!   - **The creator reads prompt-free.** The item's ACL keys to the creating binary's
//!     Designated Requirement, so the item must be created by the *installed signed* daemon
//!     (`type-wave --set-key` run via `~/.local/bin/type-wave`, or the in-daemon migration).
//!     The stable `type-wave dev` identity (#15) keeps that DR constant across rebuilds;
//!     ad-hoc `zig-out` builds are strangers to the item and will prompt or get
//!     `errSecAuthFailed` — dev runs use the process-env override instead (config.zig).
//!
//! This module is pure mechanism: it returns OSStatus outcomes and never logs — the
//! policy (precedence, migration, log dedup) lives in config.zig.

const std = @import("std");

// ---- CoreFoundation (hand-written externs, same style as insert.zig / hud.zig) ------

const CFTypeRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFDictionaryRef = ?*anyopaque;
const CFDataRef = ?*anyopaque;
const CFIndex = c_long;
pub const OSStatus = i32;
const kCFStringEncodingUTF8: u32 = 0x08000100;

extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) CFStringRef;
extern "c" fn CFStringGetCString(str: CFStringRef, buffer: [*]u8, buffer_size: CFIndex, encoding: u32) u8;
extern "c" fn CFDataCreate(alloc: ?*anyopaque, bytes: [*]const u8, len: CFIndex) CFDataRef;
extern "c" fn CFDataGetLength(data: CFDataRef) CFIndex;
extern "c" fn CFDataGetBytePtr(data: CFDataRef) ?[*]const u8;
extern "c" fn CFRelease(cf: ?*anyopaque) void;

// CFDictionary.h's two callback structs, declared field-for-field so we can pass the
// standard CFType callbacks (they make the dictionary retain/release its keys and values —
// which is why the temporary CFStrings/CFData can be `defer CFRelease`d after creation).
const CFDictionaryKeyCallBacks = extern struct {
    version: CFIndex,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copyDescription: ?*const anyopaque,
    equal: ?*const anyopaque,
    hash: ?*const anyopaque,
};
const CFDictionaryValueCallBacks = extern struct {
    version: CFIndex,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copyDescription: ?*const anyopaque,
    equal: ?*const anyopaque,
};
extern var kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
extern var kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
extern var kCFBooleanTrue: CFTypeRef;

extern "c" fn CFDictionaryCreate(
    alloc: ?*anyopaque,
    keys: [*]const CFTypeRef,
    values: [*]const CFTypeRef,
    num_values: CFIndex,
    key_callbacks: *const CFDictionaryKeyCallBacks,
    value_callbacks: *const CFDictionaryValueCallBacks,
) CFDictionaryRef;

// ---- Security.framework (linked via build.zig's linkFrameworks) ----------------------

extern "c" fn SecItemAdd(attributes: CFDictionaryRef, result: ?*CFTypeRef) OSStatus;
extern "c" fn SecItemCopyMatching(query: CFDictionaryRef, result: ?*CFTypeRef) OSStatus;
extern "c" fn SecItemUpdate(query: CFDictionaryRef, attributes_to_update: CFDictionaryRef) OSStatus;
extern "c" fn SecItemDelete(query: CFDictionaryRef) OSStatus;
extern "c" fn SecCopyErrorMessageString(status: OSStatus, reserved: ?*anyopaque) CFStringRef;

// The kSec* keys are exported CFStringRef DATA symbols, not literals — `extern var`,
// same pattern as hud.zig's kCFRunLoopCommonModes. Read-only by convention; never released.
extern var kSecClass: CFStringRef;
extern var kSecClassGenericPassword: CFStringRef;
extern var kSecAttrService: CFStringRef;
extern var kSecAttrAccount: CFStringRef;
extern var kSecAttrLabel: CFStringRef;
extern var kSecValueData: CFStringRef;
extern var kSecReturnData: CFStringRef;
extern var kSecMatchLimit: CFStringRef;
extern var kSecMatchLimitOne: CFStringRef;

pub const errSecSuccess: OSStatus = 0;
pub const errSecDuplicateItem: OSStatus = -25299;
pub const errSecItemNotFound: OSStatus = -25300;
const errSecAllocate: OSStatus = -108; // "Failed to allocate memory" (SecBase.h)
/// Keychain locked and no UI possible — retry later, and never treat it as a cue to
/// rewrite the item (Quinn's non-destructive rule).
pub const errSecInteractionNotAllowed: OSStatus = -25308;

/// One string names every identity surface of this project (CFBundleIdentifier, the
/// LaunchAgent Label, the codesign identifier) — the keychain item joins them.
pub const service = "me.ba78.type-wave";
pub const account = "openai-api-key";
pub const hugging_face_account = "huggingface-token";
const openai_label = "type-wave OpenAI API key";
const hugging_face_label = "type-wave Hugging Face token";

fn cfStr(s: [*:0]const u8) CFStringRef {
    return CFStringCreateWithCString(null, s, kCFStringEncodingUTF8);
}

fn dict(keys: []const CFTypeRef, vals: []const CFTypeRef) CFDictionaryRef {
    return CFDictionaryCreate(null, keys.ptr, vals.ptr, @intCast(keys.len), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

pub const ReadResult = union(enum) {
    /// NUL-terminated (drops straight into the Authorization header), owned by the caller.
    key: [:0]const u8,
    /// `errSecItemNotFound` — the not-configured path; config.zig's cue to try migration.
    absent,
    /// Any other status: locked keychain, ACL denial, user hit Deny… The caller logs it
    /// (render with `describe`) and treats the key as missing; the item is never rewritten.
    err: OSStatus,
};

/// Read the key: (class, service, account, return-data, match-limit-one).
pub fn readKey(gpa: std.mem.Allocator) ReadResult {
    return readSecret(gpa, account);
}

pub fn readHuggingFaceToken(gpa: std.mem.Allocator) ReadResult {
    return readSecret(gpa, hugging_face_account);
}

fn readSecret(gpa: std.mem.Allocator, item_account: [*:0]const u8) ReadResult {
    const svc = cfStr(service);
    defer CFRelease(svc);
    const acct = cfStr(item_account);
    defer CFRelease(acct);
    const keys = [_]CFTypeRef{ kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit };
    const vals = [_]CFTypeRef{ kSecClassGenericPassword, svc, acct, kCFBooleanTrue, kSecMatchLimitOne };
    const query = dict(&keys, &vals);
    defer CFRelease(query);

    var result: CFTypeRef = null;
    const st = SecItemCopyMatching(query, &result);
    if (st == errSecItemNotFound) return .absent;
    if (st != errSecSuccess) return .{ .err = st };

    const data: CFDataRef = result; // kSecReturnData alone → a CFDataRef
    defer CFRelease(data); // CF_RETURNS_RETAINED out-param: ours to release
    const len: usize = @intCast(CFDataGetLength(data));
    const bytes = CFDataGetBytePtr(data) orelse return .absent; // empty item ≙ no key
    if (len == 0) return .absent;
    const key = gpa.dupeSentinel(u8, bytes[0..len], 0) catch return .{ .err = errSecAllocate };
    return .{ .key = key };
}

/// Store (add-or-update) the key. Run this from the *installed signed* binary so the
/// item's ACL keys to the daemon's stable Designated Requirement — see the module doc.
pub fn storeKey(key: []const u8) OSStatus {
    return storeSecret(account, openai_label, key);
}

pub fn storeHuggingFaceToken(token: []const u8) OSStatus {
    return storeSecret(hugging_face_account, hugging_face_label, token);
}

/// Forget only the Hugging Face credential. Model data and the independent OpenAI item
/// are outside this exact (service, account) query.
pub fn deleteHuggingFaceToken() OSStatus {
    const svc = cfStr(service);
    defer CFRelease(svc);
    const acct = cfStr(hugging_face_account);
    defer CFRelease(acct);
    const keys = [_]CFTypeRef{ kSecClass, kSecAttrService, kSecAttrAccount };
    const vals = [_]CFTypeRef{ kSecClassGenericPassword, svc, acct };
    const query = dict(&keys, &vals);
    defer CFRelease(query);
    return SecItemDelete(query);
}

fn storeSecret(item_account: [*:0]const u8, item_label: [*:0]const u8, secret: []const u8) OSStatus {
    const svc = cfStr(service);
    defer CFRelease(svc);
    const acct = cfStr(item_account);
    defer CFRelease(acct);
    const lbl = cfStr(item_label);
    defer CFRelease(lbl);
    const data = CFDataCreate(null, secret.ptr, @intCast(secret.len));
    defer CFRelease(data);

    const add_keys = [_]CFTypeRef{ kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrLabel, kSecValueData };
    const add_vals = [_]CFTypeRef{ kSecClassGenericPassword, svc, acct, lbl, data };
    const attrs = dict(&add_keys, &add_vals);
    defer CFRelease(attrs);

    const st = SecItemAdd(attrs, null);
    if (st != errSecDuplicateItem) return st;

    // Same (service, account) already exists — update in place; keeps the item AND its ACL.
    const q_keys = [_]CFTypeRef{ kSecClass, kSecAttrService, kSecAttrAccount };
    const q_vals = [_]CFTypeRef{ kSecClassGenericPassword, svc, acct };
    const query = dict(&q_keys, &q_vals);
    defer CFRelease(query);
    const u_keys = [_]CFTypeRef{kSecValueData};
    const u_vals = [_]CFTypeRef{data};
    const update = dict(&u_keys, &u_vals);
    defer CFRelease(update);
    return SecItemUpdate(query, update);
}

/// Render an OSStatus for the log via SecCopyErrorMessageString, falling back to the raw
/// number. `buf` backs the returned slice.
pub fn describe(status: OSStatus, buf: []u8) []const u8 {
    fallback: {
        const s = SecCopyErrorMessageString(status, null);
        if (s == null) break :fallback;
        defer CFRelease(s);
        if (CFStringGetCString(s, buf.ptr, @intCast(buf.len), kCFStringEncodingUTF8) == 0) break :fallback;
        return std.mem.span(@as([*:0]u8, @ptrCast(buf.ptr)));
    }
    return std.fmt.bufPrint(buf, "OSStatus {d}", .{status}) catch "OSStatus ?";
}
