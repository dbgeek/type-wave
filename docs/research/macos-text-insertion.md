# macOS text insertion (Insertion at the cursor) — research crib sheet for type-wave

Researched 2026-07-07/08 against primary sources: the macOS SDK headers **on this machine** (the
nix `apple-sdk-14.4` that `xcrun --show-sdk-path` resolves to, cross-checked against the Command
Line Tools 12.1/15.4/26.4 SDKs — every header quote below is verbatim from those files), Apple
developer documentation and archived technotes (TN2150), WWDC 2019 session 701, Apple DevForums
posts by Quinn "The Eskimo!" (DTS), and the **actual source** of tools that solve this exact
problem — espanso, Hammerspoon, Maccy, cliclick, Hex, talon-axkit, WebKit, Chromium, Electron,
iTerm2, Ghostty, kitty — plus **compile-and-run probes built with clang and the flake's Zig
(`0.17.0-dev.1267+300116b02`) on this macOS 26.5.1 machine**. Nothing here posted a synthetic
event, wrote a focused AX element, or hijacked the real clipboard: anything that would touch
another app's UI (and hence need a TCC grant or affect the user's session) was compiled but
deliberately not run, and is marked as such. Companion sheets: capture format in
[coreaudio-capture-zig.md](./coreaudio-capture-zig.md) §1, the transcript this inserts comes from
[openai-realtime-transcription.md](./openai-realtime-transcription.md) §2, toolchain context
(`@cImport` gone; extern-decl pattern; `-L"$SDK/usr/lib"` for `-lobjc`) from
[zig-websocket-tls.md](./zig-websocket-tls.md) §9.

## Summary table

| Question | Answer | Evidence |
|---|---|---|
| Chosen primary mechanism | **Pasteboard swap + synthetic Cmd-V** (mechanism 2) | §3, §10 |
| Fallback | **Synthetic Unicode keystrokes** (mechanism 1, chunked) for short text / paste-hostile apps | §2, §10 |
| Rejected as primary | **AX `kAXSelectedTextAttribute` write** — broken in Electron/Chromium web content and all terminals | §4, §5 |
| CGEventKeyboardSetUnicodeString documented limit? | **None in the header** (CGEvent.h, all SDK versions); the event object holds ≥4096 UniChars (ran) | §1 |
| Real per-event limit | **~20 UTF-16 code units on *delivery*** — silent truncation; espanso calls it "a bug ( or undocumented limit )" and chunks at 20 | §1, §2 (espanso `native.mm`) |
| Emoji / surrogate pairs | Pass through as UTF-16 code units; the event round-trips `D83D DE00` intact (ran). Keystroke path must not split a surrogate pair across chunk boundaries | §1 |
| Keyboard-layout dependence | `SetUnicodeString` **overrides** layout translation → layout-independent for text; modifier chords (Cmd-V) are keycode-based and layout-sensitive (Maccy uses Sauce) | §1, §3 |
| Speed, long text | Keystrokes: per-chunk key-down+up + ~1 ms delays → tens of ms for a paragraph. Paste: one-shot, ~0.4–0.7 s dominated by deliberate clipboard settle delays | §2, §3 |
| Secure Event Input blocks… | **listening** (event taps stop) — documented. Does **not** document blocking `CGEventPost`, pasteboard reads, or AX writes | §6 (TN2150) |
| Detect secure input | `IsSecureEventInputEnabled()` (system-wide bool); culprit PID via `kCGSSessionSecureInputPID` (ran: held by Ghostty here) | §6 (ran) |
| TCC: posting events | **`kTCCServicePostEvent`**, shown in System Settings under **Accessibility**; `CGRequestPostEventAccess()` prompts | §7 (Quinn, WWDC19-701) |
| TCC: listening (hotkey tap) | **`kTCCServiceListenEvent`** = Input Monitoring; `CGEventTapCreate` returns NULL if denied | §7 |
| TCC: AX writes | **`kTCCServiceAccessibility`** (full); untrusted → `kAXErrorAPIDisabled` (−25211) (ran) | §4, §7 (ran) |
| TCC: pasteboard | **No classic TCC service** gates NSPasteboard; macOS 15.4+/26 adds an AppKit access-behavior alert on programmatic *reads* | §7, §8 |
| CLI attribution | Run from a terminal, the grant attaches to **the terminal app** (like mic TCC); a launchd/bundled binary is its own responsible process — exact rule per-service undocumented | §7 |
| Clipboard restore loses | Rich types, promised data, source metadata — espanso restores plain text only; mark our writes `TransientType`+`ConcealedType` | §8 |

## 1. CGEventKeyboardSetUnicodeString — capacity, the "20" limit, emoji, layout

The header is the primary source and it states **no length limit**. `CGEvent.h`
(`CoreGraphics.framework/Headers`, identical comment in the 12.1 / 14.4 / 15.4 / 26.4 SDKs):

```c
/* Set the Unicode string associated with a keyboard event.

   By default, the system translates the virtual key code in a keyboard
   event into a Unicode string based on the keyboard ID in the event source.
   This function allows you to manually override this string. Note that
   application frameworks may ignore the Unicode string in a keyboard event
   and do their own translation based on the virtual keycode and perceived
   event state. */
CG_EXTERN void CGEventKeyboardSetUnicodeString(CGEventRef event,
    UniCharCount stringLength, const UniChar *unicodeString);
```

Two load-bearing facts hide in that comment:

- **The event object has no small cap.** *Ran* (`clang` probe, this machine): set 1/10/20/21/50/
  100/500/1000/2000/**4096** UniChars, then `CGEventKeyboardGetUnicodeString` back — every length
  round-tripped exactly. So the folkloric "20-character limit" is **not** a storage limit of the
  event.
- **"application frameworks may ignore the Unicode string … and do their own translation."** This
  is the whole ballgame. The *receiving* app decides whether it honors the string or re-derives
  text from the virtual keycode + modifier state. The practical truncation lives here, on the
  delivery side, not in the setter.

The real, observed limit is **~20 UTF-16 code units per posted event**, discovered by espanso the
hard way. `espanso-inject/src/mac/native.mm` splits every injected string into chunks of 20 and
comments (verbatim, source-verified):

> `// The Unicode string of a keyboard event can only hold up to 20 UTF-16 code units. This is a bug ( or undocumented limit ) of the macOS API.`

So: the setter accepts any length; posting more than ~20 UTF-16 units in one event silently drops
the tail in most apps. **Chunk at 20 for the keystroke path.**

Emoji / surrogate pairs (*ran*): `SetUnicodeString` with `{D83D, DE00, 00E9, 0065, 0301, 0021}`
(😀, é, e+combining-acute, !) round-tripped all six UTF-16 units unchanged. Emoji are just two
UTF-16 code units (a surrogate pair); a combining sequence is multiple units. Consequence for
chunking: **never split a surrogate pair (or ideally a grapheme cluster) across a 20-unit chunk
boundary** or the receiving app may render a lone half-surrogate.

Keyboard-layout dependence: because `SetUnicodeString` *overrides* the keycode→text translation,
the **text** you inject is layout-independent — you don't need to know whether the user is on
QWERTY, Dvorak, or AZERTY (this is exactly why the string API exists, vs. synthesizing keycodes).
The catch is *modifier chords* like Cmd-V for paste (§3), which are keycode-based and therefore
layout-sensitive. Also relevant: dead keys / IME. `native.mm` posts a plain keycode `0x31` (space)
as the carrier and overrides its string — a key that is not itself a dead key. And macism's README
warns that after an input-source switch the new IME activates **asynchronously** (~150 ms on macOS
26); text injected immediately can be eaten by the outgoing IME. type-wave does not switch input
sources, but a user's IME being mid-composition is a real edge to test.

## 2. Mechanism 1 — synthetic Unicode keystrokes (`CGEventPost` + `CGEventKeyboardSetUnicodeString`)

The classic recipe from `CGEvent.h` (`CGEventCreateKeyboardEvent` comment) is keycode-driven and
requires you to press SHIFT etc. yourself:

```c
/* All keystrokes needed to generate a character must be entered, including
   SHIFT, CONTROL, OPTION, and COMMAND keys. For example, to produce a 'Z',
   ... CGEventCreateKeyboardEvent(source, (CGKeyCode)56, true);  // shift down
   CGEventCreateKeyboardEvent(source, (CGKeyCode) 6, true);  // 'z' down ... */
```

For arbitrary transcript text you **skip the keycode entirely**: create a keyboard event with any
carrier keycode, override the string with `CGEventKeyboardSetUnicodeString`, and post. *Ran*: after
`SetUnicodeString`, `kCGKeyboardEventKeycode` stays 0 and the event type is `keyDown` (10) — the
keycode is vestigial.

How the reference implementations actually do it (source-verified):

- **espanso** (`espanso-inject/src/mac/native.mm`): chunk the string into ≤20 UTF-16 units; for
  each chunk create a **key-down** and a **key-up** event, both carrying the chunk via
  `SetUnicodeString`, carrier virtual key `0x31`; `usleep(1000)` (1 ms) after the down **and** after
  the up (issue #159 established that a separate key-up per chunk is needed or fast apps drop
  input); before the first chunk it releases a stuck Shift (issue #279); it tags its own events by
  `CGEventSetLocation` / a magic source marker (value `-27469`) so its own listener can ignore
  self-injected events. Config knobs: `key_delay` / `inject_delay` (the inter-event pacing) exist
  precisely because some apps drop characters without them.
- **Hammerspoon** (`hs.eventtap.keyStrokes`, `extensions/eventtap/libeventtap.c`): sends **one**
  UTF-16 code unit per event (which *splits* surrogate pairs — a known emoji bug), keycode 0, sets
  the unicode string on **both** the down and the up event, **no** inter-event delay, posts to
  `kCGHIDEventTap`.

Speed on long text: bounded by (chunks × 2 events × per-event delay). At espanso's 1 ms spacing a
40-character sentence is ~2 chunks ≈ a few ms of sleeps plus posting overhead — tens of ms for a
paragraph. Fast, but **not** one-shot, and every extra app-compatibility delay multiplies. Dropped
characters under load are the failure mode the delays exist to prevent (unverified for our target
apps — spike must measure).

Tap location choice: `CGEventTypes.h` defines `kCGHIDEventTap = 0, kCGSessionEventTap,
kCGAnnotatedSessionEventTap`. Both real keystroke injectors post to **`kCGHIDEventTap`** (espanso
`native.mm`, Hammerspoon `keyStrokes`) — injecting as if from the HID layer, before session taps;
Maccy's *paste* path and Hammerspoon's single `keyStroke`/`event:post` use `kCGSessionEventTap`
instead. The spike should try HID first (matching the injectors) and fall back to session if an app
misbehaves.

Unicode fidelity: **excellent** (full Unicode via UTF-16, layout-independent), provided chunking
respects the 20-unit limit and surrogate boundaries. App behavior: **broadest compatibility of the
three mechanisms** — it looks like typing, so terminals, Electron, browsers, and native apps all
accept it (a terminal receives it as tty input; an Electron app as DOM key events). This is why
espanso's keystroke backend is its default for short expansions.

## 3. Mechanism 2 — pasteboard swap + synthetic Cmd-V

Flow (espanso `espanso-clipboard/src/mac` + `espanso-inject`, source-verified):

1. **Save** the current clipboard (see §8 for what actually survives).
2. **Set** the transcript on `NSPasteboard` (general pasteboard): `clearContents` then
   `setString:forType:NSPasteboardTypeString`.
3. Wait a **pre-paste delay** — espanso source uses **100 ms** (`pre_paste_delay`; the docs say
   300 ms). This lets the pasteboard write settle before the paste reads it.
4. **Synthesize Cmd-V**: key-down Cmd, key-down V, key-up V, key-up Cmd. `V` is virtual keycode
   **9** (`kCGKeyboardEventKeycode = 9` is coincidentally the field id, not the V keycode — V is
   `0x09`); Cmd flag is `kCGEventFlagMaskCommand = 0x100000` (`CGEventTypes.h`). espanso spaces
   these events ~10 ms apart.
5. Wait a **restore delay** — espanso `restore_clipboard_delay` default **300 ms** — so the target
   app finishes its *asynchronous* paste read before we put the old content back.
6. **Restore** the saved clipboard.

Layout sensitivity: the "V" in Cmd-V is a keycode, so on a remapped layout the wrong key can fire.
**Maccy** handles the notorious **Dvorak-QWERTY-⌘** case (Maccy issue #482) by resolving the V
keycode through the **Sauce** library rather than hard-coding 9. type-wave should do the same or
accept that Cmd-V may misfire on exotic layouts.

Maccy's paste specifics (source-verified, `Maccy/`): paste requires `AXIsProcessTrusted()`; it
builds a `CGEventSource` in `combinedSessionState`, enables **local-event suppression** during the
paste (so the user's real keyboard can't interleave), and posts to `kCGSessionEventTap`.

Speed: **one-shot regardless of text length** — a 5-word transcript and a 500-word transcript paste
identically. But wall-clock latency is dominated by the deliberate settle delays: ~100 ms before +
~300 ms after ≈ **0.4 s** minimum with espanso's constants, i.e. *slower for short text* than
keystrokes but *far faster and more reliable for long text*. Unicode fidelity: **perfect** — the
pasteboard carries a real `NSString`, no chunking, no surrogate hazard, no per-app string
re-translation. App behavior: paste is honored almost everywhere a paste menu item is (terminals
included — Cmd-V pastes into the tty; Electron/browser editors handle it as a paste command). Main
risks are the clipboard round-trip (§8) and Cmd-V being remapped by the app.

## 4. Mechanism 3 — Accessibility API (`AXUIElementSetAttributeValue` on the focused element)

Shape: `AXUIElementCreateSystemWide()` → read `kAXFocusedUIElementAttribute` → write
`kAXSelectedTextAttribute` (replace the selection = insert at caret) or `kAXValueAttribute`
(replace the whole field). Requires the Accessibility TCC grant (§7); untrusted, the very first
read returns `kAXErrorAPIDisabled` (*ran*: `AXUIElementCopyAttributeValue(system, AXFocusedUIElement)
→ −25211` in this un-trusted headless process).

**The header says `kAXSelectedTextAttribute` is not writable.** `AXAttributeConstants.h`
(HIServices), verbatim:

```
/*!  @define kAXSelectedTextAttribute
     The selected text of an editable text element.
     Value: A CFStringRef with the currently selected text of the element.
     Writable? No.
     Required for all editable text elements.  */
#define kAXSelectedTextAttribute  CFSTR("AXSelectedText")
```

By contrast `kAXSelectedTextRangeAttribute` is `Writable? Yes.` and `kAXValueAttribute` is
`Generally yes.` The insert-at-caret behavior everyone relies on is therefore a **de-facto
convention**, not a documented contract. Its real anchor is AppKit's `NSAccessibilityProtocols.h`
(*ran*: found at line 723), which exposes a **read-write** property:

```objc
// String of selected text
// Invokes when clients request NSAccessibilitySelectedTextAttribute
@property (nullable, copy) NSString *accessibilitySelectedText API_AVAILABLE(macos(10.10));
```

`AXUIElementSetAttributeValue` error contract (`AXUIElement.h`): `kAXErrorAttributeUnsupported`
(−25205) if the element doesn't support the attribute, `kAXErrorIllegalArgument` (−25201) if the
value/args are rejected, `kAXErrorCannotComplete` (−25204) on messaging failure/timeout,
`kAXErrorNotImplemented` (−25208) if the target "does not fully support the accessibility API".
`AXUIElementIsAttributeSettable` lets you pre-check (but see the per-app reality below — a `YES`
from Settable is not a guarantee the write inserts). Set a short messaging timeout via
`AXUIElementSetMessagingTimeout` — AX calls are synchronous IPC and can hang on a busy target.

Why this is **not** the primary mechanism — support is wildly uneven by app class (§5). It is fast
(one IPC round-trip, no chunking, perfect Unicode) and clipboard-free, but it silently or explicitly
fails in exactly the apps a developer dictates into most (Electron IDEs, terminals). Real dictation
tools treat it as a best-effort fast path with a paste/keystroke fallback: **Hex**
(`Hex/Clients/PasteboardClient.swift`) does `AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute,
text)` and on `!= .success` throws to a pasteboard fallback; **talon-axkit** documents "accessibility
dictation only operates in some applications … Safari is better than Chrome … better than Firefox".

## 5. Behavior across app classes (the decisive comparison)

Per-class verdicts, from reading WebKit / Chromium / Electron / terminal source (source-verified
unless marked):

| App class | Keystrokes (mech 1) | Paste Cmd-V (mech 2) | AX write (mech 3) | AX evidence |
|---|---|---|---|---|
| Native AppKit (TextEdit, Notes, Xcode fields) | ✅ | ✅ | ✅ `accessibilitySelectedText` rw | AppKit `NSAccessibilityProtocols.h` |
| WebKit / Safari (input, textarea, contenteditable) | ✅ | ✅ | ✅ `setSelectedText` / `setValueIgnoringResult` | `WebAccessibilityObjectWrapperMac.mm` |
| Chromium **web content** / Electron (VS Code, Cursor, Slack) | ✅ | ✅ | ❌ **not implemented** | `browser_accessibility_cocoa.mm`, `render_accessibility_impl.cc` |
| Chrome omnibox / native Views textfields | ✅ | ✅ | ✅ `Textfield::InsertOrReplaceText` | `ui/views/controls/textfield/textfield.cc` |
| Terminals (Terminal.app, iTerm2, Ghostty, kitty, Alacritty) | ✅ (tty input) | ✅ (tty paste) | ❌ read-only / no-op | iTerm2 `PTYTextView.m`, Ghostty #8717 |

The AX weak spots, with primary evidence:

- **WebKit — works.** `WebAccessibilityObjectWrapperMac.mm`: `accessibilityIsAttributeSettable:`
  returns `backingObject->canSetTextRangeAttributes()` for `NSAccessibilitySelectedTextAttribute`,
  and the setter calls `backingObject->setSelectedText(string)` when `isTextControl()`. So Safari
  and WKWebView editors accept AX selected-text writes.
- **Chromium web content — does NOT work.** In `browser_accessibility_cocoa.mm`,
  `accessibilityIsAttributeSettable:` allows only Focused / Value(if `kSetValue` action) /
  SelectedTextRange(if editable) / SelectedTextMarkerRange — **`NSAccessibilitySelectedTextAttribute`
  is absent**, and `accessibilitySetValue:forAttribute:` has **no AXSelectedText case**. The modern
  `setAccessibilitySelectedText:` (in the `AXPlatformNodeCocoa` base) maps to
  `ax::mojom::Action::kReplaceSelectedText`, but for Blink that action is unimplemented on both ends:
  `render_accessibility_impl.cc` has `case kReplaceSelectedText: … NOTREACHED();`. The only real
  implementation is native Views (`Textfield::InsertOrReplaceText`) — i.e. Chrome's omnibox, **not
  page content**. This covers **every Electron app** (VS Code, Cursor, Slack, Obsidian…).
- **Electron tree is off until forced.** Chromium builds no AX tree until an assistive tech is
  detected: it watches the undocumented `AXEnhancedUserInterface` attribute
  (`chrome_browser_application_mac.mm`, with a **2-second debounce** as of Sonoma). Electron adds
  **`AXManualAccessibility`** (electronjs.org/docs/latest/tutorial/accessibility;
  `electron/shell/browser/mac/electron_application.mm`) — a third party must
  `AXUIElementSetAttributeValue(axApp, "AXManualAccessibility", kCFBooleanTrue)` on the app element
  and **wait ~2 s** for the tree, *and even then* the AXSelectedText write has no implementation
  behind it. Net: in Electron, AX insertion is a dead end; keystrokes/paste are the path.
- **Terminals — do NOT work.** iTerm2 (`PTYTextView.m`) implements `setAccessibilityValue:` as a
  logged **no-op** and has no `setAccessibilitySelectedText:` at all (only selection-*range* set).
  Ghostty's dictation-into-cursor is a **confirmed open bug** (ghostty #8717; #9932 shows its AX
  text ranges are incomplete). kitty exposes a cosmetic `AXTextArea` role with getter-only text.
  Conceptually a terminal's AX "value" is a screen grid, not an editable buffer — AX text insertion
  can't reach the tty. Keystrokes and Cmd-V both work because they enter the normal input path.
  (Terminal.app's settable-ness is closed-source; **unverified** — but no terminal maps AX writes to
  pty input.)

This table is the core argument: **paste and keystrokes work across all five classes; AX writes
fail in two of the most important ones (Electron IDEs and terminals).** That eliminates AX as a
primary mechanism for a system-wide developer dictation tool.

## 6. Secure Event Input (Carbon HIToolbox)

Declarations are in `CarbonEventsCore.h` (HIToolbox); the earlier grep missed them because the
header is ISO-8859 encoded, but they are present and exported by `HIToolbox.tbd`
(`_EnableSecureEventInput`, `_DisableSecureEventInput`, `_IsSecureEventInputEnabled`). Verbatim doc:

```
EnableSecureEventInput()
  When secure event input is enabled, keyboard input will only go to the
  application with keyboard focus, and will not be echoed to other
  applications that might be using the event monitor target to watch
  keyboard input. ... This API maintains a count ... Secure event input is
  not disabled until DisableSecureEventInput has been called the same
  number of times. ... If your application crashes, secure event input
  will automatically be disabled if no other application has enabled it.

IsSecureEventInputEnabled()
  This API returns whether secure event input is enabled by any process,
  not just the current process.
```

**What it actually blocks.** The authoritative doc is Technical Note **TN2150 "Using Secure Event
Input Fairly"** (Apple's Carbon reference pages for these functions now 404). TN2150 says secure
input defeats three *interception* techniques — HID device seizing, **event taps**, and `GetKeys`
snapshots — i.e. it stops **listening**. It says **nothing** about `CGEventPost` (posting synthetic
keystrokes), nothing about the pasteboard, and nothing about the Accessibility API. Corroboration
that *posting still works*: the Keyboard Maestro wiki states that in a password field KM "will still
simulate the press and release". So, per available evidence:

| Path | Blocked by Secure Event Input? |
|---|---|
| Event tap / listening for the hotkey | **Yes** (documented — taps stop receiving key events) |
| `CGEventPost` synthetic keystrokes | Not documented as blocked (KM implies delivery continues) — **verify in spike** |
| Pasteboard write + Cmd-V | Target app reading NSPasteboard is not an input event; Cmd-V is a posted event → same as above — **verify in spike** |
| AX `SetAttributeValue` write | No source addresses this — **verify in spike** |

**Detecting it and finding the culprit** (*ran* on this machine): `IsSecureEventInputEnabled()`
returned **1** during this research — secure input was live, held by **Ghostty (pid 1302)**. The
holder PID is exposed as `kCGSSessionSecureInputPID` (defined by Apple in xnu
`iokit/IOKit/IOKitKeysPrivate.h`: `#define kIOConsoleSessionSecureInputPIDKey "kCGSSessionSecureInputPID"`).
Two retrieval routes, both in shipping OSS: `CGSessionCopyCurrentDictionary()` and read the key
(*ran*: `probe_secure.c` read pid 1302 out of the session dict; deskflow, fcitx5-macos, skhd use
this), or scan IORegistry `IOConsoleUsers` (what **espanso** does in `espanso-mac-utils/src/native.mm`,
polling every 3 s). Common holders: `loginwindow` at the lock screen, password fields, and — as
observed — a terminal with **"Secure Keyboard Entry"** enabled (a Terminal.app / iTerm2 / Ghostty
menu item). Design rule (espanso's): before inserting, check `IsSecureEventInputEnabled()`; if true
and it would block us, resolve the PID and tell the user which app holds it rather than dropping the
transcript silently.

Note: enabling/disabling secure input in *our own* process had no effect on the system-wide state
here because another process (Ghostty) already held it — the count is system-wide, matching the
header's "enabled by any process".

## 7. TCC permissions for a bare CLI binary

The three relevant services and what gates what — primary sources are WWDC 2019 session 701
("Advances in macOS Security") and Quinn (DTS) on the DevForums:

- **Posting synthetic events → `kTCCServicePostEvent`**, shown in System Settings under
  **Accessibility**. Quinn (forums/thread/789896): *"If you try to post a CGEvent, the system will
  present the TCC alert for you. Alternatively … call `CGPreflightPostEventAccess` and
  `CGRequestPostEventAccess`. … While this privilege shows up in the UI as System Settings > Privacy
  & Security > Accessibility, it doesn't give you complete accessibility access. It's just limited to
  posting events."* WWDC19-701: an unauthorized poster's *"events are discarded"* and a one-time
  dialog appears. This is the permission **mechanisms 1 and 2 (Cmd-V) need**.
- **Listening event taps → `kTCCServiceListenEvent`** = Input Monitoring. `CGEventTapCreate`
  *"will fail and return nil"* without it (WWDC19-701). type-wave needs this **only** for the
  global hold-to-talk hotkey tap, a separate concern from insertion.
- **AX reads/writes → `kTCCServiceAccessibility`** (the *full* Accessibility grant). Untrusted →
  `kAXErrorAPIDisabled` (−25211) (*ran*). This is what **mechanism 3 needs**.

The header for the CG access APIs (`CGEvent.h`, verbatim, *ran* to confirm present in 14.4 + 26.4):

```c
/* Checks whether the current process already has event listening access */
CG_EXTERN bool CGPreflightListenEventAccess(void) CG_AVAILABLE_STARTING(10.15);
/* Requests event listening access if absent, potentially prompting */
CG_EXTERN bool CGRequestListenEventAccess(void) CG_AVAILABLE_STARTING(10.15);
/* Checks whether the current process already has event synthesizing access */
CG_EXTERN bool CGPreflightPostEventAccess(void) CG_AVAILABLE_STARTING(10.15);
/* Requests event synthesizing access if absent, potentially prompting */
CG_EXTERN bool CGRequestPostEventAccess(void) CG_AVAILABLE_STARTING(10.15);
```

*Ran*: in this un-granted process `CGPreflightPostEventAccess()` and `CGPreflightListenEventAccess()`
both returned `false`, and `AXIsProcessTrusted()` returned 0 — the preflights are the silent,
no-prompt way to know our state at startup. `AXIsProcessTrustedWithOptions` with
`kAXTrustedCheckOptionPrompt=true` is the AX equivalent (Apple docs: *"Prompting occurs
asynchronously and does not affect the return value"*).

**Attribution for an unbundled CLI.** Like microphone TCC (companion sheet §5.1), when the binary
is run **from a terminal the grant attaches to the terminal app** — cliclick (an unbundled
CGEvent-posting CLI) instructs users to "give Terminal (or iTerm …) the permission to control the
computer … Security ➔ Accessibility." Quinn's "responsible process/responsible code" doctrine
(forums/thread/731504, /678819) is the framework, and he has said the terminal is the responsible
code for a tool run from it. **But** a bare binary launched via launchd *can* appear in the
Accessibility pane in its own right (skhd/yabai users add the binary). The exact per-service rule
is **not** stated by Apple — flagged for the spike. Failure modes: `CGEventPost` returns `void`
and events are silently discarded when unauthorized (preflight to avoid this); `CGEventTapCreate`
returns NULL; AX calls return `kAXErrorAPIDisabled`. Reset for testing: `tccutil reset Accessibility`,
`tccutil reset ListenEvent`, `tccutil reset PostEvent` (optionally scoped to `com.apple.Terminal` /
the terminal in use).

**Pasteboard needs no classic TCC service** — nothing in `tccutil`'s list gates NSPasteboard; the
15.4+/26 privacy alert (§8) is an AppKit access-behavior mechanism, not an Accessibility/Input-
Monitoring-style prompt.

## 8. Clipboard trade-offs (mechanism 2)

**What save/restore loses.** espanso's restore preserves **plain text only** (`get_text`/`set_text`)
— rich text, RTF, images, file URLs, promised/lazy types, and per-item source metadata are dropped
when it puts the "old" clipboard back. A faithful save/restore must snapshot **all** `types` and
their data, which is more work and still can't reproduce *promised* data (the owning app has to
provide it lazily). type-wave's realistic options: (a) best-effort all-types snapshot, or (b)
accept plain-text-only restore and document it.

**`changeCount` semantics** (*ran*, unique pasteboard): starts at 0; `clearContents` → 1;
`setString:forType:` (into the already-cleared item) → still 1; a **second** `clearContents` → 2.
So `changeCount` increments **per ownership change (clear/declare), not per `setString` write**,
matching Apple's doc: *"increments each time the pasteboard ownership changes … also returned from
clearContents()."* Reading contents does **not** bump it (verified: read-back left it at 2). Use it
to (1) detect a clipboard manager or other app clobbering our transcript mid-flight, and (2) confirm
our restore took.

**nspasteboard.org transient conventions** (verbatim). For a tool that briefly hijacks the
clipboard, mark the write so history managers skip it:

- `org.nspasteboard.TransientType`: *"content will be on the pasteboard only momentarily … Data
  marked transient should not be recorded or displayed in a pasteboard history."*
- `org.nspasteboard.ConcealedType`: *"content that should be treated as confidential … visually
  obfuscated … Avoid recording it to a file."* (Transcripts can be sensitive → set this too.)
- `org.nspasteboard.AutoGeneratedType`: *"content was generated by an application; the user had no
  intention to Copy this content."*

**Managers honor it** — *Maccy* (`Maccy/Clipboard.swift`, source-verified) has
`private let ignoredTypes: Set<NSPasteboard.PasteboardType> = [.autoGenerated, .concealed, .transient]`
and drops any item intersecting that set, polling on a `Timer`. So a conforming manager (1Password,
Alfred, Keyboard Maestro, Paste, Maccy…) never records our ~300 ms transcript. A non-conforming
manager, or one whose poll interval races our restore, still might — the convention is a mitigation,
not a guarantee. **Set `TransientType` + `ConcealedType` (+ optionally `AutoGeneratedType`) on our
transient writes.**

**macOS 15.4+/26 pasteboard privacy.** `NSPasteboard.h` (*ran*: present in 26.4 SDK) adds
`NSPasteboardAccessBehavior` (macOS 15.4): `.default` (General pasteboard "ask upon programmatic
access"; an app that has never triggered an alert isn't shown in System Settings; the first alert
flips it to `.ask` and lists it there), `.ask`, `.alwaysAllow`, `.alwaysDeny` — with the crucial
carve-out that *"access that is both user originated and paste related will always be allowed, and
will not result in a notification."* *Ran*: `accessBehavior` for this responsible process reported
**2 (`.alwaysAllow`)**. The problem for us: **saving the current clipboard is a programmatic read
with no paste gesture**, exactly what triggers the alert under enforcement. Alert-free alternatives
in the header: read only `changeCount`/`types` (metadata, strongly implied safe by the "without
reading the full contents" framing but not guaranteed), or the `detectPatterns…` / `detectMetadata…`
detection APIs (15.4+, documented to not notify). **Undocumented and spike-critical: whether a
synthetic Cmd-V makes the *target* app's read count as "user originated and paste related"** — if
not, our paste could itself trip the target's alert. Rollout: opt-in in 15.4 via
`defaults write <bundleid> EnablePasteboardPrivacyDeveloperPreview -bool yes`; default enforcement
announced for macOS 26 (absent from the release notes I could fetch — verify on-device).

## 9. Zig integration notes

- **Bindings: extern declarations** (consistent with the other crib sheets; `@cImport` is gone on
  the flake's 0.17-dev). The surface is small: `CGEventCreateKeyboardEvent`,
  `CGEventKeyboardSetUnicodeString`, `CGEventSetFlags`, `CGEventPost`, `CGEventSourceCreate`,
  `CFRelease`; the CG access preflights; `IsSecureEventInputEnabled` /
  `CGSessionCopyCurrentDictionary`; and (fallback) `AXUIElementCreateSystemWide` /
  `…CopyAttributeValue` / `…SetAttributeValue` / `AXIsProcessTrustedWithOptions`.
- **NSPasteboard via the ObjC runtime C interface** (allowed by the project constraint). Use
  `objc_getClass("NSPasteboard")`, `sel_registerName`, and cast `objc_msgSend` per call site.
  *Ran*: reading `[[NSPasteboard generalPasteboard] changeCount]` this way returned 43; `setString:
  forType:` and `clearContents` likewise dispatch fine. Each `objc_msgSend` call site needs its own
  correctly-typed function-pointer cast (return type + arg types) — Zig can't overload it.
- **Frameworks / link flags** (all *ran* on this machine):
  `-framework CoreGraphics -framework Carbon -framework ApplicationServices -framework AppKit
  -lobjc -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib"`. The `-L"$SDK/usr/lib"` is required
  or Zig can't find `libobjc.tbd` (same class of issue as the websocket sheet's framework-path note).
  `CGEventPost` etc. resolve from CoreGraphics; `IsSecureEventInputEnabled`/`Enable/Disable` from
  Carbon (HIToolbox); AX from ApplicationServices (HIServices).
- **Callback/ABI:** none of the insertion APIs are block-based (unlike Network.framework), so no
  blocks-ABI problem. `CGEventRef` etc. are opaque pointers; `UniChar` = `u16`, `UniCharCount` =
  `c_ulong`, `Boolean` = `u8`.

Sketch — pasteboard-paste path (primary). **Compiled with the flake's Zig on this machine; the
pasteboard writes and `CGEventPost` were NOT executed** (posting/hijacking is TCC- and
session-visible, out of scope for this headless session). The `changeCount` read and the CGEvent
create/round-trip are the exact calls that *did* run in the probes.

```zig
// zig build-exe insert.zig -lc -lobjc -framework CoreGraphics -framework AppKit \
//   -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib"
const CGEventRef = ?*opaque {};
const CGEventSourceRef = ?*opaque {};
const CGEventFlags = u64;
const kCGEventFlagMaskCommand: CGEventFlags = 0x100000; // CGEventTypes.h
const kCGSessionEventTap: u32 = 1;
const kVK_ANSI_V: u16 = 0x09; // layout note: resolve via a keycode map for Dvorak-QWERTY-⌘

extern "c" fn CGEventSourceCreate(state: i32) CGEventSourceRef;
extern "c" fn CGEventCreateKeyboardEvent(src: CGEventSourceRef, vk: u16, down: bool) CGEventRef;
extern "c" fn CGEventSetFlags(ev: CGEventRef, flags: CGEventFlags) void;
extern "c" fn CGEventPost(tap: u32, ev: CGEventRef) void; // needs kTCCServicePostEvent
extern "c" fn CFRelease(cf: ?*anyopaque) void;
extern "c" fn CGPreflightPostEventAccess() bool;
extern "c" fn CGRequestPostEventAccess() bool;

extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern "c" fn objc_msgSend() void; // cast per call site

fn pasteCmdV() void {
    const src = CGEventSourceCreate(0); // kCGEventSourceStateCombinedSessionState (Maccy's choice)
    const v_down = CGEventCreateKeyboardEvent(src, kVK_ANSI_V, true);
    const v_up = CGEventCreateKeyboardEvent(src, kVK_ANSI_V, false);
    CGEventSetFlags(v_down, kCGEventFlagMaskCommand);
    CGEventSetFlags(v_up, kCGEventFlagMaskCommand);
    CGEventPost(kCGSessionEventTap, v_down);
    CGEventPost(kCGSessionEventTap, v_up);
    CFRelease(@ptrCast(v_down)); CFRelease(@ptrCast(v_up)); CFRelease(@ptrCast(src));
}

// Insertion, sketch:
//   if (!CGPreflightPostEventAccess()) _ = CGRequestPostEventAccess();     // §7 prompt
//   if (IsSecureEventInputEnabled() != 0) { warnUserWithHolderPid(); return; } // §6
//   const saved = savePasteboard();                     // §8 (may trip 15.4+ read alert)
//   setPasteboard(transcript, .{ .transient = true, .concealed = true }); // §8 markers
//   sleep(pre_paste_ms);                                // ~100 ms
//   pasteCmdV();
//   sleep(restore_ms);                                  // ~300 ms, let async paste read finish
//   restorePasteboard(saved);
```

Sketch — keystroke fallback (chunked, §1/§2):

```zig
const UniChar = u16;
extern "c" fn CGEventKeyboardSetUnicodeString(ev: CGEventRef, len: c_ulong, s: [*]const UniChar) void;

/// Post `utf16` in ≤20-unit chunks, key-down+key-up per chunk, never splitting a surrogate pair.
fn typeUnicode(src: CGEventSourceRef, utf16: []const UniChar) void {
    var i: usize = 0;
    while (i < utf16.len) {
        var n: usize = @min(20, utf16.len - i);
        // don't end a chunk on a high surrogate (0xD800..0xDBFF)
        if (n > 0 and utf16[i + n - 1] >= 0xD800 and utf16[i + n - 1] <= 0xDBFF) n -= 1;
        const chunk = utf16[i .. i + n];
        const down = CGEventCreateKeyboardEvent(src, 0x31, true); // carrier keycode (space)
        const up = CGEventCreateKeyboardEvent(src, 0x31, false);
        CGEventKeyboardSetUnicodeString(down, chunk.len, chunk.ptr);
        CGEventKeyboardSetUnicodeString(up, chunk.len, chunk.ptr);
        CGEventPost(kCGSessionEventTap, down); // + ~1 ms
        CGEventPost(kCGSessionEventTap, up);   // + ~1 ms  (espanso pacing, issue #159/#279)
        CFRelease(@ptrCast(down)); CFRelease(@ptrCast(up));
        i += n;
    }
}
```

## 10. Recommendation for the spike ("Prototype the hold-to-talk insertion spike")

**Primary: pasteboard swap + synthetic Cmd-V (mechanism 2).** It is the only mechanism that (a)
inserts correctly across all five app classes including Electron IDEs and terminals (§5), (b) has
perfect Unicode/emoji fidelity with no chunking hazard (§1, §3), and (c) is one-shot regardless of
transcript length — the right shape for pasting a whole utterance. Mark writes with
`org.nspasteboard.TransientType` + `ConcealedType` (§8) and save/restore the clipboard around the
paste.

**Fallback: chunked synthetic Unicode keystrokes (mechanism 1)**, used when (a) the transcript is
short (espanso's auto rule: ≤100 chars → keystrokes, avoiding the clipboard round-trip and its
~0.4 s latency), or (b) paste is unavailable/undesirable — e.g. the clipboard save/restore would
trip the macOS 15.4+/26 read alert, or an app remaps Cmd-V. Chunk at 20 UTF-16 units, never split a
surrogate pair, ~1 ms inter-event pacing (§2).

**Explicitly rejected as primary: AX `kAXSelectedTextAttribute` write (mechanism 3)** — the header
says it isn't writable, and empirically it is unimplemented in Chromium web content / all Electron
apps and in every terminal (§4, §5). Keep it only as an *optional* fast path for native-AppKit /
Safari targets if the spike shows a latency win worth the app-detection complexity; it is not
required for a working prototype.

**Exact TCC permission the spike binary needs:** **`kTCCServicePostEvent`** (posting events; shows
in System Settings → Privacy & Security → **Accessibility**). Acquire via `CGPreflightPostEventAccess()`
then `CGRequestPostEventAccess()` at startup. Both the paste-Cmd-V path and the keystroke path use
only this. **No** full Accessibility (`kTCCServiceAccessibility`) grant is needed unless/until the
AX fast path is implemented; **no** Input Monitoring (`kTCCServiceListenEvent`) is needed for
insertion (that's for the separate hold-to-talk hotkey tap). Pasteboard needs no TCC service.
When run from a terminal, expect the grant to attach to the terminal app (verify — §7).

### The spike must verify empirically (headless research could not)

1. **CLI TCC attribution** — run the binary from Terminal: after `CGRequestPostEventAccess()`, does
   the *terminal* appear under Accessibility (expected, per cliclick), or the bare binary? Repeat via
   launchd. Confirm `CGEventPost` actually delivers once granted, and is silently dropped when not.
2. **Paste round-trip correctness** — save/restore across all types (not just plain text); confirm
   the transcript pastes and the prior clipboard is faithfully restored; measure the minimum safe
   `pre_paste`/`restore` delays (start 100 ms / 300 ms) on a slow target (Electron).
3. **macOS 15.4+/26 pasteboard-privacy alert** — with `EnablePasteboardPrivacyDeveloperPreview` set:
   does *saving* the clipboard trigger the alert? Does a synthetic Cmd-V count as a user paste for
   the *target* app's read (the single biggest unknown, §8)? Is reading only `types`/`changeCount`
   alert-free? Decide whether to save/restore at all or type-instead when privacy is enforced.
4. **Secure Event Input interaction** — with a terminal's "Secure Keyboard Entry" on (and at a real
   password field): does `CGEventPost` still deliver keystrokes? Does Cmd-V still paste? Does an AX
   write work? (§6 says listening is blocked; the rest is undocumented.) Wire up the
   `IsSecureEventInputEnabled()` + `kCGSSessionSecureInputPID` warning either way.
5. **App-class matrix for the two chosen mechanisms** — paste and keystrokes into: Terminal.app,
   iTerm2, Ghostty; VS Code / Cursor (Electron); Safari + Chrome (contenteditable, form fields);
   Notes / TextEdit. Confirm no dropped characters on the keystroke path (tune `key_delay`), and no
   focus/paste-target surprises.
6. **Cmd-V on remapped layouts** — Dvorak and Dvorak-QWERTY-⌘: does hard-coded keycode 9 misfire?
   Decide whether to resolve V via a layout map (Maccy/Sauce approach).
7. **Emoji / combining marks / RTL** end-to-end through both paths (surrogate-pair chunk boundary;
   grapheme clusters) into representative apps.
8. **IME edge** — inserting while a CJK IME is mid-composition (macism's async-activation warning):
   does the transcript land correctly or get consumed?
9. **The 20-unit storage-vs-delivery discrepancy** — the header documents *no* length limit and the
   event object round-tripped 4096 UniChars here (§1), yet espanso's source asserts a ~20-UTF-16-unit
   truncation *on delivery* ("a bug ( or undocumented limit )"). Confirm where the ceiling actually
   is on this macOS version and per target app: post a single 50-unit `SetUnicodeString` event and
   see whether the tail is dropped (delivery-side truncation) or fully inserted. This decides whether
   the keystroke path must chunk at 20 at all, and it is a per-app property (the header warns
   "application frameworks may ignore the Unicode string … and do their own translation").

## Open questions / unverified

1. Whether `CGEventPost` and Cmd-V survive Secure Event Input — TN2150 only documents that listening
   is blocked; KM implies posting continues. (§6, spike item 4.)
2. Whether a synthetic Cmd-V makes the target app's pasteboard read "user originated and paste
   related" under macOS 15.4+/26 privacy — undocumented, spike-critical. (§8, spike item 3.)
3. Exact TCC attribution rule for an unbundled CLI per service (terminal vs. binary) — not stated by
   Apple; microphone precedent + cliclick suggest the terminal. (§7, spike item 1.)
4. `kAXErrorAPIDisabled` (−25211) as *the* modern untrusted-process AX error — observed here, but the
   header comment predates TCC wording.
5. Terminal.app's AX settable-ness — closed source; no terminal inspected maps AX writes to the tty.
6. macOS 26 shipping state of default pasteboard-privacy enforcement — announced May 2025, absent
   from the release notes fetched; verify on a 26.x machine.
7. Maccy's default `clipboardCheckInterval` value (the ignored-types set and polling mechanism are
   source-verified; the numeric default is not).
8. Whether reading only pasteboard `types`/`changeCount` is guaranteed alert-free under 15.4+/26
   (strongly implied, never stated).
