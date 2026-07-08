# macOS Keychain generic passwords from Zig (the API key's home) — research crib sheet for type-wave

Researched 2026-07-08 (wayfinder #30 on map #29) against primary sources: the macOS SDK headers
**on this machine** (the nix `apple-sdk-14.4` that `xcrun --show-sdk-path` resolves to —
`Security.framework/Headers/SecItem.h`, `SecBase.h`, `SecAccess.h`, `SecTrustedApplication.h`,
`CoreFoundation.framework/Headers/CFDictionary.h`/`CFData.h`; every header quote below is verbatim
from those files), Apple technote [TN3137 "On Mac keychain APIs and implementations"](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains),
Apple DevForums posts by Quinn "The Eskimo!" (DTS) — [SecItem: Fundamentals](https://developer.apple.com/forums/thread/724023),
[SecItem: Pitfalls and Best Practices](https://developer.apple.com/forums/thread/724013),
[thread 649081](https://developer.apple.com/forums/thread/649081) (double prompts / stable DR),
[thread 98182](https://developer.apple.com/forums/thread/98182) (partition IDs) — `man security` /
`man codesign` on this machine, the open-source Security framework
([apple-oss-distributions/Security](https://github.com/apple-oss-distributions/Security); the
macOS SecItem→file-based-keychain shim lives in `OSX/libsecurity_keychain/lib/SecItem.cpp`), plus
**compile-and-link probes built with the flake's Zig (`0.17.0-dev.1267+300116b02`)** and `codesign
-d` inspection of the repo's actual binaries (ran). **Nothing here performed a keychain
operation**: the probe binary only prints symbol addresses (adding/reading an item would train
ACLs and prompts on this machine's login keychain, pre-empting the prototype), so all
prompt-on-rebuild behavior is marked inferred and left for the prototype to confirm. Companion
context: signing + TCC identity in [docs/packaging.md](../packaging.md), the env-file key path in
`src/config.zig` (#16), the extern-decl pattern in `src/insert.zig` / `src/hud.zig`.

## Summary table

| Question | Answer | Evidence |
|---|---|---|
| Which keychain implementation | **File-based login keychain** — the data protection keychain needs keychain-access-groups authorized by a **provisioning profile**, which a self-signed unbundled CLI cannot carry | §1 |
| Which API | **SecItem\*** (`SecItemAdd`/`CopyMatching`/`Update`/`Delete`); it defaults to the file-based keychain on macOS. `SecKeychain*`/`SecAccess*`/`SecTrustedApplication*` are all deprecated | §1, §2, §6 |
| Uniqueness key for a generic password | **(kSecAttrService, kSecAttrAccount)** — other attributes don't contribute; add colliding on those → `errSecDuplicateItem` | §2 (Quinn) |
| `kSecAttrAccessible` | **Not supported for file-based keychain items** (header IMPORTANT note) — omit it; availability is the login keychain's lock state (unlocked at login). Only relevant if we ever move to the data protection keychain (then: `AfterFirstUnlock`) | §2, §7 |
| OSStatus codes to handle | `errSecSuccess` 0, `errSecDuplicateItem` −25299, `errSecItemNotFound` −25300, `errSecAuthFailed` −25293, `errSecUserCanceled` −128, `errSecInteractionNotAllowed` −25308 (+ `errSecMissingEntitlement` −34018 if the DP keychain is ever tried) | §2 (SecBase.h) |
| Memory rules | CF Create/Get rule: `CFRelease` everything from `*Create*`/`*Copy*`, including the `SecItemCopyMatching` out-param (`CF_RETURNS_RETAINED` in the header) | §2 |
| Zig linking | **`Security` framework must be added to build.zig** (`linkFrameworks` helper); CoreFoundation already linked. All needed symbols confirmed in the SDK's `Security.tbd` (ran) | §3 |
| kSec\* constants from Zig | They are **exported CFStringRef data symbols**, not literals — `extern var kSecClass: CFStringRef;` (same pattern as hud.zig's `kCFRunLoopCommonModes`). Sketch **compiled, linked, and dyld-resolved** on this machine (ran) | §3 |
| Service / account names | `kSecAttrService` = **`me.ba78.type-wave`** (the existing CFBundleIdentifier + LaunchAgent label), `kSecAttrAccount` = **`openai-api-key`**, `kSecAttrLabel` = "type-wave OpenAI API key" | §4 |
| Who reads prompt-free | The **creating app** — "the application which creates an item is trusted to access its data without warning" (`man security`); the item's ACL is set to the creator's **Designated Requirement** (Quinn) | §5 |
| Ad-hoc / linker-signed builds | `zig-out/bin/type-wave` is `adhoc,linker-signed`, DR = `cdhash H"…"` (ran) — changes every rebuild; "no way for the system to tell that it's the same code" (Quinn) → prompts/denials every rebuild | §5 |
| The repo's starting point | **Already solved**: install.sh signs every installed build with the stable self-signed `type-wave dev` identity; installed binary's DR = `identifier "me.ba78.type-wave" and certificate leaf = H"…"` (ran) — stable across rebuilds | §5, §6 |
| Dev-loop recommendation | **Primary**: daemon creates its own item (a `--set-key` path run via the signed installed binary) + the existing signed `zig build install-agent` loop. **Fallback**: the existing env-file/process-env key path (`src/config.zig`) so unsigned foreground dev builds never touch the keychain | §6, §7 |

## 1. Two keychain implementations — which one type-wave can use

macOS has two distinct keychains behind the one SecItem API
([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)):

- **File-based keychain** — the traditional Mac one: the per-user **login** keychain
  (`~/Library/Keychains/login.keychain-db`, the default) plus the System keychain. Access control
  is per-item **ACLs** (`SecAccess`). "The file-based keychain is on the road to deprecation.
  It's not officially deprecated, but some of the APIs surrounding it are" (TN3137).
- **Data protection keychain** — the iOS-style one (macOS 10.15+ via
  `kSecUseDataProtectionKeychain`). Access control is **keychain access groups derived from code
  signing entitlements**: "macOS builds the list of data protection keychain access groups
  available to your program from its code signing entitlements … must be authorized by a
  provisioning profile" (TN3137).

"The SecItem API can target either implementation. It **defaults to targeting the file-based
keychain**. To target the data protection keychain, set the `kSecUseDataProtectionKeychain`
attribute or the `kSecAttrSynchronizable` attribute to true" (TN3137).

Quinn's blanket advice is "If you're able to use the data protection keychain, do so"
([Fundamentals](https://developer.apple.com/forums/thread/724023)) — **but type-wave can't**:

1. The restricted `keychain-access-groups` entitlement "must be authorised by a provisioning
   profile … it's problematic for command-line tools on the Mac, which are non-bundled
   executables. There's no obvious way for such executables to include a provisioning profile
   (r. 125850707)" ([Pitfalls](https://developer.apple.com/forums/thread/724013)). A provisioning
   profile requires an Apple Developer account identity; the repo deliberately uses a
   **self-signed** `type-wave dev` cert (docs/packaging.md — distribution signing is fog).
   Attempting it anyway fails with `errSecMissingEntitlement` (−34018, SecBase.h).
2. Context is fine, for the record: the DP keychain "is only available in a user login context.
   You can't use it, for example, from a `launchd` daemon" (TN3137) — type-wave is a per-user
   **LaunchAgent** in the gui/aqua session, which *is* a user login context. The blocker is
   solely the provisioning profile.

So: **SecItem API against the file-based login keychain.** That's also exactly the combination
whose ACL/prompt model §5 charts. The deprecated `SecKeychain*` API family is not needed —
SecItem's defaults (`SecItemAdd` "adds the item to the default keychain", i.e. login;
`SecItemCopyMatching` "consult[s] all keychains in the search list", TN3137) are what we want.

## 2. The SecItem C API for one generic password

### The four calls (SecItem.h, all `API_AVAILABLE(macos(10.6))`)

```c
OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef * __nullable CF_RETURNS_RETAINED result);
OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef * __nullable CF_RETURNS_RETAINED result);
OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
OSStatus SecItemDelete(CFDictionaryRef query);
```

Everything is driven by CFDictionary. Per the `SecItemCopyMatching` header comment, a query is:
a `kSecClass` key + attribute keys to match + search constants + return-type keys.

### The dictionary shape for our item

| Key | Value | Role |
|---|---|---|
| `kSecClass` | `kSecClassGenericPassword` | item class (always) |
| `kSecAttrService` | CFString `"me.ba78.type-wave"` | primary key, half 1 (§4) |
| `kSecAttrAccount` | CFString `"openai-api-key"` | primary key, half 2 (§4) |
| `kSecAttrLabel` | CFString `"type-wave OpenAI API key"` | display name in Keychain Access (add only; defaults to the service string otherwise, `man security`) |
| `kSecValueData` | CFData of the secret bytes | add/update only |
| `kSecReturnData` | `kCFBooleanTrue` | read only → result is a **CFDataRef** |
| `kSecMatchLimit` | `kSecMatchLimitOne` | read only (also the file-based default — see below) |

All of these are **exported `const CFStringRef` data symbols** (`extern const CFStringRef
kSecClass …`, SecItem.h) — there are no literal values to hard-code; §3 shows the Zig extern
declarations. Availability: `kSecAttrService`/`kSecAttrAccount`/`kSecValueData`/`kSecReturnData`/
`kSecMatchLimit` are all macos(10.6); everything needed predates anything this repo supports.

**Do not pass `kSecAttrAccessible`.** SecItem.h is explicit: "IMPORTANT: This attribute is
currently not supported for OS X keychain items, unless the kSecAttrSynchronizable attribute is
also present" (or `kSecUseDataProtectionKeychain` is true — the key's own doc). For a file-based
item, availability is governed by the **keychain's lock state**: the login keychain is unlocked
automatically at login while its password matches the account password ([Keychain Access User
Guide](https://support.apple.com/guide/keychain-access/if-your-mac-keeps-asking-for-the-keychain-password-kyca1242/mac)),
which covers the daemon's start-at-login lifecycle with no attribute at all. Quinn notes "the
shim ignores unsupported attributes" (Pitfalls) — so passing it is likely a silent no-op, but
omitting it is the honest shape. (If the DP keychain ever becomes reachable, the right value for
a login-launched daemon is `kSecAttrAccessibleAfterFirstUnlock` — "recommended for items that
need to be accessible by background applications", SecItem.h.)

### Uniqueness and the add-vs-update dance

For a generic password, **only service + account form the uniqueness constraint** — Quinn
(Pitfalls, verbatim): "for a generic password item … only the service and account attributes are
included in the uniqueness constraint. If you try to add an item where those attributes match an
existing item, the add will fail with `errSecDuplicateItem` even though the value of the generic
attribute is different." His guidance: **"Prefer to Update"** — `SecItemUpdate` preserves the
item (and, load-bearing for §5, its ACL) rather than delete-and-re-add. So the write path is:
`SecItemAdd` → on `errSecDuplicateItem`, `SecItemUpdate` with a (class, service, account) query
and a `{kSecValueData: newData}` update dictionary.

Two macOS file-based quirks (Pitfalls, both flagged as compatibility-frozen bugs): `kSecMatchLimit`
"always defaults to `kSecMatchLimitOne`" on the file-based keychain (r. 105800863), including for
`SecItemDelete` (DP deletes *all* matches, file-based deletes one). With a fully-specified
(service, account) query this doesn't bite us, but pass `kSecMatchLimitOne` on reads anyway.

### OSStatus results (SecBase.h, exact values verified)

| Code | Value | When / what to do |
|---|---|---|
| `errSecSuccess` | 0 | — |
| `errSecItemNotFound` | −25300 | no such item → daemon's not-configured path (poll like the missing env file today) |
| `errSecDuplicateItem` | −25299 | add collided on (service, account) → `SecItemUpdate` |
| `errSecAuthFailed` | −25293 | ACL/partition check failed or user denied at the prompt-less boundary (§5) → log + surface, don't retry hot |
| `errSecUserCanceled` | −128 | user clicked Deny/Cancel on the prompt → same as above |
| `errSecInteractionNotAllowed` | −25308 | keychain locked and UI not possible/allowed → retry later (self-heal supervisor tick, #19). Quinn's warning (Pitfalls): treat this **non-destructively** — never delete/rewrite the credential on this error |
| `errSecMissingEntitlement` | −34018 | only if `kSecUseDataProtectionKeychain` is tried without a profile (§1) |

For logs, `SecCopyErrorMessageString(status, NULL)` (SecBase.h, macos 10.3+) renders any code to
a human string (returned CFString must be CFReleased).

### Memory management

The CF [Create/Get rule](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFMemoryMgmt/Concepts/Ownership.html)
applies untouched: everything obtained from a `*Create*`/`*Copy*` function is owned by the caller
and must be `CFRelease`d — the query CFStrings, the CFData, the CFDictionary, and notably the
`SecItemCopyMatching` **out-param** (its header annotation is `CF_RETURNS_RETAINED`). Values put
*into* a dictionary built with `kCFTypeDictionaryKeyCallBacks`/`kCFTypeDictionaryValueCallBacks`
are retained by the dictionary, so the temporaries can be released after (or `defer`red past)
dictionary creation. The kSec\* constants themselves are **Get-rule globals — never release
them**. After copying the secret out of the returned CFData, release the CFData promptly (and
zero the Zig-side copy when the session is done with it, same hygiene as the env-file key).

## 3. From Zig: linking, externs, and a compiled CRUD sketch

### build.zig

`build.zig`'s `linkFrameworks` helper links AudioToolbox, CoreGraphics, CoreFoundation, Carbon,
ApplicationServices, AppKit, QuartzCore + libobjc — **no Security yet**. One line joins the
party (exe and test module both, via the shared helper):

```zig
mod.linkFramework("Security", .{}); // SecItem* keychain (API key storage, #30)
```

All required symbols were confirmed exported by this SDK's
`Security.framework/Security.tbd` (ran: `_SecItemAdd/_CopyMatching/_Update/_Delete`,
`_SecCopyErrorMessageString`, `_kSecClass`, `_kSecClassGenericPassword`, `_kSecAttrService`,
`_kSecAttrAccount`, `_kSecAttrLabel`, `_kSecValueData`, `_kSecReturnData`, `_kSecMatchLimit`,
`_kSecMatchLimitOne` — all present).

### The extern pattern

Same hand-written extern style as `src/insert.zig`/`src/hud.zig` (`@cImport` is gone on this
nightly — see zig-websocket-tls.md §9). The one new wrinkle vs. the CG functions: the kSec\* keys
are **data symbols**, so they're `extern var`, exactly like hud.zig already does for
`kCFRunLoopCommonModes` (hud.zig line ~169). Zig has no `extern const`; declare `extern var` and
treat as read-only. The only genuinely new C-shape is `CFDictionaryCreate`'s callback structs,
declared as `extern struct`s matching CFDictionary.h field-for-field.

The sketch below **compiled, linked against the SDK frameworks, and ran** on this machine (flake
Zig; `zig build-exe keychain_probe.zig -lc -framework Security -framework CoreFoundation -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib"`)
— with a `main` that only prints the symbol addresses, so dyld resolution is proven but **no
keychain call was executed**.

```zig
// ---- CoreFoundation (extern style per src/insert.zig) ----
const CFTypeRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFDictionaryRef = ?*anyopaque;
const CFDataRef = ?*anyopaque;
const CFIndex = c_long;
const OSStatus = i32;
const kCFStringEncodingUTF8: u32 = 0x08000100;

extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) CFStringRef;
extern "c" fn CFDataCreate(alloc: ?*anyopaque, bytes: [*]const u8, len: CFIndex) CFDataRef;
extern "c" fn CFDataGetLength(data: CFDataRef) CFIndex;
extern "c" fn CFDataGetBytePtr(data: CFDataRef) ?[*]const u8;
extern "c" fn CFRelease(cf: ?*anyopaque) void;

// CFDictionary.h's two callback structs, so we can pass the standard CFType callbacks
// (they make the dictionary retain/release its CF keys and values).
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

// ---- Security.framework (needs mod.linkFramework("Security", .{}) in build.zig) ----
extern "c" fn SecItemAdd(attributes: CFDictionaryRef, result: ?*CFTypeRef) OSStatus;
extern "c" fn SecItemCopyMatching(query: CFDictionaryRef, result: ?*CFTypeRef) OSStatus;
extern "c" fn SecItemUpdate(query: CFDictionaryRef, attributes_to_update: CFDictionaryRef) OSStatus;
extern "c" fn SecItemDelete(query: CFDictionaryRef) OSStatus;
extern "c" fn SecCopyErrorMessageString(status: OSStatus, reserved: ?*anyopaque) CFStringRef;

// kSec* keys are exported CFStringRef DATA symbols, not macros/literals —
// extern var, same as hud.zig's kCFRunLoopCommonModes. Read-only by convention.
extern var kSecClass: CFStringRef;
extern var kSecClassGenericPassword: CFStringRef;
extern var kSecAttrService: CFStringRef;
extern var kSecAttrAccount: CFStringRef;
extern var kSecAttrLabel: CFStringRef;
extern var kSecValueData: CFStringRef;
extern var kSecReturnData: CFStringRef;
extern var kSecMatchLimit: CFStringRef;
extern var kSecMatchLimitOne: CFStringRef;

const errSecSuccess: OSStatus = 0;
const errSecDuplicateItem: OSStatus = -25299; // SecBase.h
const errSecItemNotFound: OSStatus = -25300;

const service = "me.ba78.type-wave"; // §4
const account = "openai-api-key";

fn cfStr(s: [*:0]const u8) CFStringRef {
    return CFStringCreateWithCString(null, s, kCFStringEncodingUTF8);
}
fn dict(keys: []const CFTypeRef, vals: []const CFTypeRef) CFDictionaryRef {
    return CFDictionaryCreate(null, keys.ptr, vals.ptr, @intCast(keys.len),
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

/// Add-or-update (the "Prefer to Update" shape, §2). Run from the *signed installed
/// daemon* (a --set-key path) so the item's ACL keys to the daemon's DR (§5).
pub fn storeKey(key: []const u8) OSStatus {
    const svc = cfStr(service);
    defer CFRelease(svc);
    const acct = cfStr(account);
    defer CFRelease(acct);
    const label = cfStr("type-wave OpenAI API key");
    defer CFRelease(label);
    const data = CFDataCreate(null, key.ptr, @intCast(key.len));
    defer CFRelease(data);

    const add_keys = [_]CFTypeRef{ kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrLabel, kSecValueData };
    const add_vals = [_]CFTypeRef{ kSecClassGenericPassword, svc, acct, label, data };
    const attrs = dict(&add_keys, &add_vals);
    defer CFRelease(attrs);

    const st = SecItemAdd(attrs, null);
    if (st != errSecDuplicateItem) return st;

    // Same (service, account) exists — update in place; keeps the item AND its ACL.
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

/// Read the key into buf; null + status on any failure (see §2's status table).
pub fn readKey(buf: []u8, status: *OSStatus) ?[]const u8 {
    const svc = cfStr(service);
    defer CFRelease(svc);
    const acct = cfStr(account);
    defer CFRelease(acct);
    const keys = [_]CFTypeRef{ kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit };
    const vals = [_]CFTypeRef{ kSecClassGenericPassword, svc, acct, kCFBooleanTrue, kSecMatchLimitOne };
    const query = dict(&keys, &vals);
    defer CFRelease(query);

    var result: CFTypeRef = null;
    status.* = SecItemCopyMatching(query, &result);
    if (status.* != errSecSuccess) return null;
    const data: CFDataRef = result; // kSecReturnData alone -> CFDataRef
    defer CFRelease(data); // CF_RETURNS_RETAINED out-param: ours to release
    const len: usize = @intCast(CFDataGetLength(data));
    if (len > buf.len) return null;
    @memcpy(buf[0..len], CFDataGetBytePtr(data).?[0..len]);
    return buf[0..len];
}

/// Remove the item (uninstall / key rotation escape hatch).
pub fn deleteKey() OSStatus {
    const svc = cfStr(service);
    defer CFRelease(svc);
    const acct = cfStr(account);
    defer CFRelease(acct);
    const keys = [_]CFTypeRef{ kSecClass, kSecAttrService, kSecAttrAccount };
    const vals = [_]CFTypeRef{ kSecClassGenericPassword, svc, acct };
    const query = dict(&keys, &vals);
    defer CFRelease(query);
    return SecItemDelete(query);
}
```

(Compile-verified as described; the SecItem calls themselves are **not run** — their runtime
behavior, prompts included, is the prototype's job. Note `main.zig` currently parses no argv at
all, so a `--set-key` subcommand is a small, additive change.)

## 4. Service / account naming

Apple's docs don't mandate a convention — SecItem.h only says `kSecAttrService` is "a string
representing the service associated with this item" and `kSecAttrAccount` "an account name".
The de-facto conventions visible in Apple's samples and shipping apps are: **service** = either
the product name or the reverse-DNS bundle identifier; **account** = the user/credential name
within that service. `man security` adds one practical detail: the item's **label** (what
Keychain Access displays) "defaults to the service name" when not set explicitly.

For type-wave the repo already owns exactly one stable identifier — `me.ba78.type-wave` — used as
the `CFBundleIdentifier` (packaging/Info.plist), the LaunchAgent `Label`
(packaging/me.ba78.type-wave.plist), and the codesign `--identifier` (packaging/install.sh
`BUNDLE_ID`). Reusing it keeps every identity surface (TCC grants, codesign DR, keychain item)
greppable by one string:

- `kSecAttrService` = **`me.ba78.type-wave`**
- `kSecAttrAccount` = **`openai-api-key`** (names the credential, not the user; leaves room for a
  future second provider under the same service)
- `kSecAttrLabel` = **`type-wave OpenAI API key`** (else Keychain Access shows the bare
  reverse-DNS service string)

Equivalent CLI shapes for debugging (`man security`): `security find-generic-password -s
me.ba78.type-wave -a openai-api-key -w` (prints the secret; will hit the same ACL gates as any
other app — §5) and `security delete-generic-password -s me.ba78.type-wave -a openai-api-key`.

## 5. Prompt behavior for the signed LaunchAgent (the critical part)

### The file-based ACL model

Each file-based keychain item carries an ACL. Two verbatim anchors:

- `man security` (add-generic-password): "**By default, the application which creates an item is
  trusted to access its data without warning.**" (`-T ""` removes even that; `-A` marks it "Allow
  any application to access this item without warning (**insecure, not recommended!**)".)
- Quinn ([649081](https://developer.apple.com/forums/thread/649081)): "Unless you go out of the
  way to change this, **a keychain item's ACL is set to the designated requirement (DR) of the app
  that created it.**"

Any *other* app reading the item's secret triggers the SecurityAgent prompt — "*app* wants to use
your confidential information stored in *item* in your keychain" with Deny / Allow / Always Allow.
**Always Allow adds that app's DR to the item's ACL**, which is why it only sticks for apps whose
DR is stable: "you sign your code with a stable signing identity, which means it has a consistent
designated requirement (DR), which means it's considered the 'same code'" (Quinn,
[98182](https://developer.apple.com/forums/thread/98182)).

### How "the same app" is decided: the Designated Requirement

The DR is the code-signature requirement other subsystems use to recognize future versions of a
program (`man codesign`; TN3127 territory). What the two builds in this repo actually carry (ran,
this machine):

```
$ codesign -d --verbose=2 zig-out/bin/type-wave        # plain `zig build` output
  CodeDirectory … flags=0x20002(adhoc,linker-signed) …
  Signature=adhoc
  Internal requirements=none
$ codesign -d -r- zig-out/bin/type-wave
  # designated => cdhash H"c6615f542aaa08b6ab8def237a42a3aacfd37778"

$ codesign -d -r- ~/.local/bin/type-wave               # install.sh's signed install
  designated => identifier "me.ba78.type-wave" and certificate leaf = H"898df2d4…"
```

`man codesign` explains both shapes: ad-hoc signing "does not use an identity at all, and
**identifies exactly one instance of code**"; linker signatures (the Zig/clang default on Apple
Silicon) "will usually **not contain any embedded code requirements including a designated
requirement**" — so the *implied* DR degenerates to the cdhash, which changes on **every
rebuild**. The consequence for keychain is exactly Quinn's brew diagnosis: unsigned or ad-hoc
"means there's **no way for the system to tell that it's the same code**" (98182).

**So, the question the ticket asks — does an ad-hoc binary re-reading its own item after a
rebuild prompt or fail?** Verified pieces: new cdhash → different DR → the item's ACL (keyed to
the *old* build's DR) no longer matches → the rebuilt binary is a stranger to its own item. What
a stranger gets is: the Allow/Deny prompt when SecurityAgent UI is possible (GUI session), or
`errSecAuthFailed`/`errSecInteractionNotAllowed` when it isn't. The **exact** split (prompt vs.
silent −25293 for a headless LaunchAgent; whether Always Allow even helps until the next rebuild
invalidates it again) is *inferred from the model above and DevForums reports, not
header-verifiable — the prototype must confirm it*. What is certain: with an ad-hoc dev loop,
whatever the failure mode is, it recurs **every rebuild**. This is the same trap #15 already
escaped for TCC (docs/packaging.md "Why a stable signing identity"), for the same root cause.

### Partition IDs (macOS 10.12+), the second gate

Sierra added a second, stricter layer to file-based ACLs: the **partition list** — "an extra
parameter in the ACL which limits access to the item based on an application's code signature.
You must present the keychain's password to change a partition list" (`man security`,
set-generic-password-partition-list). It exists "to prevent unmediated transfer of credentials
between unrelated code" (Quinn, 98182). Entries are strings like `teamid:UBF8T346G9` (all apps of
one developer), `apple:` / `apple-tool:` (Apple apps / the `security` CLI — which is why
CLI-created items prompt when a GUI app reads them), and there is deliberately "no supported way
for you to create keychain items which will be silently used by other apps" (Quinn, 98182). The
constant `kSecACLAuthorizationPartitionID` (SecAccess.h, macos 10.11+) exposes it, but the whole
`SecAccess*` surface is deprecated (§6) — the only sanctioned way into an item's partition list is
being its **creator**, or the user authorizing with the keychain password.

Practical consequences for type-wave:

- **The daemon must create its own item.** Creator trust covers both gates (ACL + partition
  list). An item created via `security add-generic-password` instead would carry
  `apple-tool:,apple:` partitions and the daemon's first read would prompt.
- The `type-wave dev` cert is self-signed → **no team identifier**
  (`TeamIdentifier=not set` on the installed binary, ran) — so what partition entry a
  self-signed creator gets (cert-hash-based? `unsigned:`?) is **not documented anywhere found;
  prototype must dump it** (`security dump-keychain` shows partition lists) and verify self-reads
  stay prompt-free across a rebuild+re-sign, mirroring docs/packaging.md's TCC persistence check.
- Cert lifetime matters: a renewed/recreated cert = new leaf hash = new DR = stranger again.
  packaging.md's advice to mint the cert with ~3650-day validity protects the keychain item too.

## 6. Dev-loop mitigation options, weighed

1. **Stable self-signed identity + daemon-created item — the primary, and it already exists.**
   The repo's dev loop for anything OS-facing is already `zig build install-agent` (sign with
   `type-wave dev` → `~/.local/bin/type-wave` → launchctl), because the TCC grants demand it. A
   keychain item created by the *installed signed daemon* (one-time `type-wave --set-key`, key on
   stdin) keys its ACL to the stable DR `identifier "me.ba78.type-wave" and certificate leaf =
   H"…"` — every rebuild that goes through install.sh satisfies the same DR → **prompt-free reads
   forever, zero new infrastructure**. Cost: none beyond what #15 built. Residual risk: the
   self-signed/no-teamid partition behavior (§5, prototype item).
2. **Env/config override so dev builds never touch the keychain — the fallback, also already
   exists.** `src/config.zig` reads `~/.config/type-wave/env` then falls back to the process
   environment. Keep that path working and order the daemon's key lookup **env file → process env
   → keychain** (file/env stay the dev override; unsigned `zig-out` foreground runs and `zig build
   test` never hit Security.framework at all).
3. **`security add-generic-password -A`** (allow all apps): works, but the man page itself brands
   it "insecure, not recommended!", it makes the API key readable by any process, and the item's
   creator becomes `apple-tool:` anyway. Rejected.
4. **`SecAccess`/`SecTrustedApplication` trusted-app lists** (programmatic ACL editing /
   `kSecAttrAccess` at add time): the entire family — `SecAccessCreate`,
   `SecTrustedApplicationCreateFromPath`, etc. — is `API_DEPRECATED("SecKeychain is deprecated",
   macos(10.x, 10.10))` in this SDK's SecAccess.h/SecTrustedApplication.h (verified). Still
   links, but it's the doomed API surface and solves nothing the stable identity doesn't. Rejected.
5. **Data protection keychain**: cleanest ACL model, but unreachable without a provisioning
   profile (§1). Revisit only if type-wave ever adopts a real Developer ID + bundle/profile
   packaging (the distribution fog).

## 7. Recommendation

- **Keychain**: SecItem API against the **file-based login keychain** (the default — no
  `kSecUseDataProtectionKeychain`, no `kSecAttrSynchronizable`).
- **`kSecAttrAccessible`**: **omit it** — unsupported for file-based items (§2); the login
  keychain's unlocked-while-logged-in state covers the LaunchAgent's lifecycle. (Future DP
  keychain: `kSecAttrAccessibleAfterFirstUnlock`.)
- **Names**: service `me.ba78.type-wave`, account `openai-api-key`, label
  `type-wave OpenAI API key` (§4).
- **Write path**: `SecItemAdd` → on `errSecDuplicateItem` → `SecItemUpdate` (never
  delete-and-re-add; preserves the ACL). Expose as `type-wave --set-key` and document that it
  must be run via the **installed signed binary**, so the daemon is the item's creator (§5).
- **Read path**: (class, service, account, `kSecReturnData`=true, `kSecMatchLimitOne`) at daemon
  startup, ordered after the env-file/process-env overrides (§6.2). Map `errSecItemNotFound` to
  the existing not-configured/poll state; treat `errSecInteractionNotAllowed` as retry-later;
  treat `errSecAuthFailed`/`errSecUserCanceled` as a surfaced misconfiguration, never as a cue to
  rewrite the item.
- **Dev loop**: primary = the existing stable `type-wave dev` signing loop (§6.1); fallback = the
  existing env-file override (§6.2). Nothing new to build besides `--set-key`.
- **Prototype must confirm** (in packaging.md style, after granting once): (a) prompt-free
  re-read across a full rebuild+re-sign; (b) the partition-list entry a self-signed-cert creator
  gets; (c) the ad-hoc failure mode (prompt vs. `errSecAuthFailed`) for the record.

## Open questions / unverified

1. **Ad-hoc rebuild failure mode** — prompt in a GUI session vs. silent `errSecAuthFailed` for a
   headless LaunchAgent: inferred from the DR/ACL model (§5) and DevForums reports; not
   header-verifiable. Prototype.
2. **Partition-list entry for a self-signed, no-teamid creator** — undocumented; dump with
   `security dump-keychain` after the prototype's first `--set-key` and re-check after a
   rebuild+re-sign.
3. **Whether SecurityAgent prompts render at all for a UI-less LaunchAgent** in the aqua session
   (expected yes — same session — but unverified), and whether `kSecUseAuthenticationUI` /
   the deprecated `kSecUseNoAuthenticationUI` can force the no-UI error instead for cleaner
   daemon behavior on the file-based keychain.
4. **"Always Allow" persistence across cert renewal** — new leaf hash ⇒ new DR ⇒ expected to
   drop, mitigated by the 3650-day cert; not tested.
5. **Shim behavior when `kSecAttrAccessible` is passed to a file-based add** — Quinn says the
   shim "ignores unsupported attributes" generally; whether this one is ignored or errors is
   untested (we omit it either way).
6. **Login-keychain lock edge cases** for the daemon: user changed their account password out of
   band (login keychain stays locked → expect `errSecInteractionNotAllowed`/prompt), FileVault
   first-login ordering vs. `RunAtLoad`. Handle via the retry-later mapping (§7) and observe.
