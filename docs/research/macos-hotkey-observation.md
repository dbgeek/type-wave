# Observing a global hold-to-talk key (the Talk Key) — research crib sheet for type-wave

Researched 2026-07-08 against primary sources: the macOS SDK headers **on this machine** (the nix
`apple-sdk-14.4` that `xcrun --show-sdk-path` resolves to — every header quote below is verbatim
from those files, `iconv`-decoded where the Carbon headers are ISO-8859), Apple developer
documentation and the archived Carbon/Quartz reference, WWDC 2019 session 701 and Apple DevForums
posts by Quinn "The Eskimo!" (DTS) on event taps / Input Monitoring (carried over from the
companion sheet), and the **actual source** of the tools that solve this exact problem — **skhd**,
**Hammerspoon** (`hs.hotkey` = Carbon vs `hs.eventtap` = CGEventTap, contrasted), **Karabiner-
Elements** (IOKit HID seize + a DriverKit virtual keyboard), and **espanso** (NSEvent global
monitor + the self-event marker trick) — plus **compile-and-run probes built with the flake's Zig
(`0.17.0-dev.1267+300116b02`) on this macOS 26.5.1 machine**. The probe is a `kCGEventTapOption‐
ListenOnly` observer: it is *safe* to actually run (it posts nothing and consumes nothing), and it
did run here. What it could **not** do is press physical keys — this is a headless agent with no
human at the keyboard and no TCC grant — so every "which bits does Fn set" style observation that
needs a real keypress is marked as deferred to the spike, and grounded in the header + the
reference tools instead. **No synthetic events were posted and no real keystroke was consumed.**

Companion sheets: the mandatory transcript this key gates comes from
[coreaudio-capture-zig.md](./coreaudio-capture-zig.md) (Capture) and
[openai-realtime-transcription.md](./openai-realtime-transcription.md) (Transcription Session); the
**Insertion** mechanism that posts synthetic events (the self-event hazard, §4) and the TCC /
CLI-attribution / Secure-Event-Input discussion are in
[macos-text-insertion.md](./macos-text-insertion.md) §6–§7; Zig toolchain context (`@cImport` is
gone on the flake's Zig — use extern decls; framework/link-path gotchas) is in
[zig-websocket-tls.md](./zig-websocket-tls.md) §9.

## Summary table

| Question | Answer | Evidence |
|---|---|---|
| Recommended observation API | **listen-only CGEventTap** (`kCGSessionEventTap` + `kCGEventTapOptionListenOnly`) | §1, §7 |
| Recommended Talk Key | **Right-Option** (`kVK_RightOption` = 0x3D); **F13** as the zero-TCC fallback; Fn/Globe as an A/B option with caveats | §2, §7 |
| Sees events while ANY app is focused? | **Yes for all three candidates** — session tap, global hotkey, and raw HID are all system-wide | §1 |
| Delivers key-UP (the release edge — mandatory)? | CGEventTap: **yes** (`keyUp`, or a flag-cleared `flagsChanged` for a modifier). Carbon: **yes** (`kEventHotKeyReleased`, id 6). IOKit HID: **yes** (report value 0) | §1 |
| Listen-only / non-consuming (key still works in the focused app)? | CGEventTap: **yes** (`kCGEventTapOptionListenOnly`). Carbon hotkey: observe-only by nature. IOKit HID grab: **consuming** (`kIOHIDOptionsTypeSeizeDevice`) | §1 |
| Does a plain CGEventTap see Fn as keyDown, or only flagsChanged? | **Only `flagsChanged`**, carrying `kCGEventFlagMaskSecondaryFn` (= `NX_SECONDARYFNMASK` = 0x00800000). Fn never arrives as a `keyDown`/`keyUp` on a Quartz tap — the crux | §2 |
| Right-Option vs Left-Option distinguishable? | **Yes** — via the `flagsChanged` **keycode** (0x3A left / 0x3D right) and via **device bits** in the raw `CGEventFlags` (`NX_DEVICELALTKEYMASK` 0x20 / `NX_DEVICERALTKEYMASK` 0x40). **Not** via the device-independent `kCGEventFlagMaskAlternate` (both set it) | §2 |
| TCC for a listen-only tap | **Input Monitoring** (`kTCCServiceListenEvent`); `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`. **Ran:** tap is created **non-NULL but DISABLED** until granted (stale header says "returns NULL") | §3, §5 |
| TCC for Carbon `RegisterEventHotKey` | **NONE.** **Ran:** registered `noErr` with a non-null ref in a process holding zero grants | §3, §5 |
| TCC for IOKit `IOHIDManager` | **Input Monitoring.** **Ran:** `IOHIDManagerOpen` → `kIOReturnNotPermitted` (0xe00002e2) in this un-granted process | §3, §5 |
| CLI attribution (unbundled binary) | Run from a terminal, the Input-Monitoring grant attaches to **the terminal app** (same as mic / PostEvent) — cross-ref [macos-text-insertion.md](./macos-text-insertion.md) §7 | §3 |
| Secure Event Input | A password field / "Secure Keyboard Entry" **disables the tap's listening** — the observer goes silent — cross-ref [macos-text-insertion.md](./macos-text-insertion.md) §6 | §3 |
| Self-event hazard (we also POST Cmd-V/keystrokes) | We observe Right-Option; we post `V`/Cmd-V — **different keys, no logical collision**. Tag our posts anyway via `kCGEventSourceUserData` (**ran:** round-trips) or espanso's location marker | §4 |
| Tap auto-disable gotcha | `kCGEventTapDisabledByTimeout` / `kCGEventTapDisabledByUserInput` arrive as event types; must catch them and call `CGEventTapEnable(tap, true)` | §6 |

## 1. Candidate observation APIs, head to head

Three ways to observe a global key while another app is focused. All three are **system-wide**; they
differ on the release edge, on whether they consume the key, on latency, and — decisively — on TCC.

### 1.1 Listen-only `CGEventTap`

`CGEventTapCreate` (CoreGraphics `CGEvent.h`, verbatim) with the passive option from
`CGEventTypes.h`:

```c
typedef CF_ENUM(uint32_t, CGEventTapOptions) {
  kCGEventTapOptionDefault = 0x00000000,
  kCGEventTapOptionListenOnly = 0x00000001
};
```
```c
/* Create an event tap. */
CG_EXTERN CFMachPortRef __nullable CGEventTapCreate(CGEventTapLocation tap,
    CGEventTapPlacement place, CGEventTapOptions options,
    CGEventMask eventsOfInterest, CGEventTapCallBack callback,
    void * __nullable userInfo)
    CG_AVAILABLE_STARTING(10.4);
```

The tap-location enum (`CGEventTypes.h`) and the header's own rule that **HID-level taps are
root-only**:

```c
typedef CF_ENUM(uint32_t, CGEventTapLocation) {
  kCGHIDEventTap = 0,
  kCGSessionEventTap,
  kCGAnnotatedSessionEventTap
};
```
> "Taps may only be placed at `kCGHIDEventTap' by a process running as the root user. NULL is
> returned for other users." … "Taps may be passive event listeners, or active filters." —
> `CGEvent.h`

So an unprivileged CLI uses **`kCGSessionEventTap`** (events as they enter the session — still every
app). Both real listen/consume tools do exactly this: **skhd** `event_tap.c` `event_tap_begin` and
**Hammerspoon** `hs.eventtap` `eventtap_start` both call
`CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, …)` (source-verified). skhd uses
`kCGEventTapOptionDefault` because it *consumes* matched hotkeys (returns `NULL` from the callback);
type-wave wants the opposite — **`kCGEventTapOptionListenOnly`** so the Talk Key still reaches the
focused app.

- **Sees both key-down and key-up:** yes. The event-type enum (`CGEventTypes.h`) has
  `kCGEventKeyDown = NX_KEYDOWN` (10), `kCGEventKeyUp = NX_KEYUP` (11), and
  `kCGEventFlagsChanged = NX_FLAGSCHANGED` (12). The mask you pass selects which. For a **normal key**
  Talk Key (e.g. F13) you tap `keyDown|keyUp`; for a **modifier** Talk Key (Right-Option, Fn) you tap
  `flagsChanged` (§2). The release edge is native either way.
- **Non-consuming:** yes, with `kCGEventTapOptionListenOnly` — the callback's return value is ignored
  and the event flows on to the focused app unchanged.
- **Latency:** in-band, synchronous — the tap sits in the delivery path, so callback dispatch is
  sub-millisecond; the only pacing hazard is the auto-disable-on-timeout watchdog (§6), which never
  fires for a trivial callback. Irrelevant against human hold durations.
- **TCC:** **Input Monitoring** (`kTCCServiceListenEvent`) — §3.

### 1.2 Carbon `RegisterEventHotKey`

HIToolbox `CarbonEvents.h` (ISO-8859, `iconv`-decoded), verbatim:

```c
extern OSStatus
RegisterEventHotKey(
  UInt32            inHotKeyCode,       /* virtual key code */
  UInt32            inHotKeyModifiers,  /* 10.3+: may be zero */
  EventHotKeyID     inHotKeyID,
  EventTargetRef    inTarget,
  OptionBits        inOptions,
  EventHotKeyRef *  outRef)             AVAILABLE_MAC_OS_X_VERSION_10_0_AND_LATER;
```

The **key-up question answered by the header**: the keyboard event class defines *both* edges —

```c
/* kEventClassKeyboard quick reference:
   kEventRawKeyDown = 1, kEventRawKeyRepeat = 2, kEventRawKeyUp = 3,
   kEventRawKeyModifiersChanged = 4, kEventHotKeyPressed = 5, kEventHotKeyReleased = 6 */
```
> "kEventClassKeyboard / kEventHotKeyReleased — Summary: A registered hot key was released." —
> `CarbonEvents.h`

So `RegisterEventHotKey` **can** deliver a release edge — but *only if you install a handler for
`kEventHotKeyReleased`*. This is easy to get wrong: most Carbon-hotkey code registers
`kEventHotKeyPressed` only. **Hammerspoon `hs.hotkey` does it right** (`extensions/hotkey/libhotkey.m`,
source-verified): it registers via `RegisterEventHotKey(…, GetEventDispatcherTarget(),
kEventHotKeyExclusive, …)` and installs a handler for **both** `kEventHotKeyPressed` and
`kEventHotKeyReleased`, routing them to `pressedfn` / `releasedfn`. That existence proof — a shipping
tool relying on `kEventHotKeyReleased` for years — is the strongest evidence the release edge is
real for a held hotkey. (Hammerspoon also *fakes* auto-repeat with an `NSTimer` because Carbon
hotkeys don't repeat — a bonus for hold-to-talk: no repeat spam while the key is held.)

**The disqualifier for our ergonomic Talk Keys:** `RegisterEventHotKey` fires off the **keyDown
path** for a virtual keycode (+ optional modifier mask). A **bare modifier** (Right-Option) or **Fn**
does not generate a keyDown — it generates `flagsChanged` — so a Carbon hotkey on it will not fire.
**Ran:** registering keycode 0x3D (Right-Option) and 0x3F (Fn) each returned `noErr` with a non-null
ref — i.e. registration is *accepted with no validation* — but that does **not** mean it fires;
firing for a bare modifier/Fn is unverifiable headless and is expected **not** to happen (spike item).
Carbon is therefore only viable with a **real key** Talk Key such as **F13**.

- **Sees system-wide:** yes (global hot key, all apps). **Both edges:** yes (pressed + released, if
  you handle both). **Non-consuming:** it's observe-only — it does not swallow the key from other
  apps (it's a *notification*, and non-exclusive by default). **Latency:** through the Carbon event
  queue — marginally higher than a tap, still trivial. **TCC:** **none** (§3) — the headline
  advantage.

### 1.3 IOKit HID (`IOHIDManager`)

`IOHIDManager.h` gives `IOHIDManagerCreate` → `IOHIDManagerSetDeviceMatching` →
`IOHIDManagerRegisterInputValueCallback` → `IOHIDManagerScheduleWithRunLoop` → `IOHIDManagerOpen`.
This reads the **raw HID report stream** (usage page + usage + integer value), below Quartz.

- **Sees system-wide:** yes (it's the device, not a window). **Both edges:** yes — press = report
  value 1, release = value 0. **Karabiner-Elements** (the gold standard) is built on this:
  `event_queue/utility.hpp` decodes `v.get_integer_value() ? event_type::key_down : event_type::key_up`
  (source-verified). **Fn and left/right modifiers are native** here (§2) — Karabiner goes to raw HID
  *precisely because* the Quartz layer mangles Fn.
- **But it is a consuming grab, and it is gated.** To actually intercept (not just observe) Karabiner
  opens the device with **`kIOHIDOptionsTypeSeizeDevice`** (`device_grabber_details/entry.hpp`,
  `async_start_queue_value_monitor`), which takes the keyboard away from the OS and forces you to
  **re-inject** everything through a virtual HID device — a kext/DriverKit-class project, wildly out
  of scope for a hold-to-talk key that must remain non-consuming. And even a non-seizing open is
  gated: **Ran:** `IOHIDManagerOpen()` → **`kIOReturnNotPermitted` (0xe00002e2)** in this un-granted
  process (Input Monitoring, §3). **Rejected** for type-wave — all cost, no benefit over a
  listen-only tap for our use.

### 1.4 Verdict of the comparison

| | listen-only CGEventTap | Carbon RegisterEventHotKey | IOKit IOHIDManager |
|---|---|---|---|
| System-wide (any focused app) | ✅ | ✅ | ✅ |
| Key-down **and** key-up | ✅ (keyUp / flag-cleared flagsChanged) | ✅ (`kEventHotKeyReleased`, if handled) | ✅ (value 1/0) |
| Non-consuming (key still works) | ✅ (`kCGEventTapOptionListenOnly`) | ✅ (notification only) | ❌ (seize + re-inject) |
| Can observe a **bare modifier / Fn** Talk Key | ✅ (raw `flagsChanged`) | ❌ (keyDown path only) | ✅ (raw HID usages) |
| TCC permission | **Input Monitoring** | **none** | **Input Monitoring** |
| Latency | in-band, sub-ms | Carbon queue, ~ms | lowest | 
| Complexity | low | low | very high (virtual device) |

CGEventTap and Carbon are both cheap and both give the release edge; the split is **Talk-Key
freedom vs zero-TCC** (resolved in §7). IOKit is out.

## 2. The Fn/Globe key and the practical Talk Keys

### 2.1 How Fn surfaces — the crux

The flag exists in `CGEventTypes.h` in the "Special key identifiers" group (alongside Help), and is
defined in `IOLLEvent.h`:

```c
/* CGEventTypes.h */
kCGEventFlagMaskSecondaryFn = NX_SECONDARYFNMASK,
```
```c
/* IOKit/hidsystem/IOLLEvent.h */
#define NX_SECONDARYFNMASK 0x00800000
```

Fn is a **flag**, not a key event, on the Quartz layer. There *is* a virtual keycode for it —
`Events.h`: `kVK_Function = 0x3F` — but on Apple built-in keyboards pressing Fn/Globe emits a
**`flagsChanged` (`NX_FLAGSCHANGED`) event** that carries keycode 0x3F in the keycode field and
toggles `kCGEventFlagMaskSecondaryFn` (set on press, cleared on release). It does **not** emit
`keyDown`/`keyUp`. Corroboration from the reference tools:

- **skhd** (`hotkey.h`, `hotkey.c` `cgevent_flags_to_hotkey_flags`) treats Fn purely as a flag test:
  `Event_Mask_Fn = kCGEventFlagMaskSecondaryFn`; `if ((eventflags & Event_Mask_Fn) == …) flags |= Hotkey_Flag_Fn;`
  (source-verified) — it never sees an Fn keyDown.
- **Hammerspoon `hs.eventtap`** reads Fn as `NSEventModifierFlagFunction` from `[NSEvent modifierFlags]`
  (`libeventtap.m` `checkKeyboardModifiers`) — again a modifier flag, not a key.
- **Karabiner** cannot get Fn from Quartz at all and reads it as a **raw HID usage**
  (`momentary_switch_event.hpp`): either `apple_vendor_top_case::keyboard_fn` (older keyboards) **or**
  `apple_vendor_keyboard::function` (newer Globe keyboards) → `modifier_flag::fn` (source-verified).

**Consequence for hold-to-talk with Fn:** you observe it via a `flagsChanged` tap and derive the
edge from the `kCGEventFlagMaskSecondaryFn` bit — press = bit newly set, release = bit newly cleared
— confirming it's Fn (not another modifier) via the keycode field 0x3F. The **release edge is
available** (the flag clears), so Fn *can* satisfy the mandatory Utterance-end. The hazards (§2.3)
are why it isn't the default.

**Note — the Apple Fn/Globe HID usages are NOT in this SDK.** `IOHIDUsageTables.h` on this machine
has the standard pages (`kHIDPage_KeyboardOrKeypad = 0x07`, modifiers `kHIDUsage_KeyboardLeftAlt =
0xE2` … `kHIDUsage_KeyboardRightGUI = 0xE7`) but **no** `kHIDPage_AppleVendorTopCase` /
`AppleVendorKeyboard` and **no** `keyboard_fn` / `function` usage (grepped the whole
`IOKit.framework`; absent). Those live in Apple's private `AppleHIDUsageTables.h` (IOHIDFamily) —
which is exactly the header Karabiner vendors. So the IOKit-HID route to Fn also carries a
"reconstruct private constants" tax on top of the seize/virtual-device tax.

### 2.2 Left vs right modifier distinction

The device-independent flags do **not** separate left from right — both Options set
`kCGEventFlagMaskAlternate` (= `NX_ALTERNATEMASK` = 0x00080000). Two things do:

1. **The `flagsChanged` keycode field.** `Events.h`, verbatim:
   ```c
   kVK_Command       = 0x37,   kVK_RightCommand  = 0x36,
   kVK_Shift         = 0x38,   kVK_RightShift    = 0x3C,
   kVK_Option        = 0x3A,   kVK_RightOption   = 0x3D,
   kVK_Control       = 0x3B,   kVK_RightControl  = 0x3E,
   kVK_Function      = 0x3F,
   ```
   A Right-Option `flagsChanged` reports keycode **0x3D**, Left-Option **0x3A**. This is how
   **espanso** does it (`espanso-detect/src/mac/native.mm`): in the flagsChanged branch it splits
   left/right by `keyCode` (`kVK_Option` vs `kVK_RightOption`, `kVK_Shift` vs `kVK_RightShift`).
2. **Device-dependent bits in the raw `CGEventFlags`.** `IOLLEvent.h`, verbatim:
   ```c
   #define NX_DEVICELCTLKEYMASK   0x00000001
   #define NX_DEVICELSHIFTKEYMASK 0x00000002
   #define NX_DEVICERSHIFTKEYMASK 0x00000004
   #define NX_DEVICELCMDKEYMASK   0x00000008
   #define NX_DEVICERCMDKEYMASK   0x00000010
   #define NX_DEVICELALTKEYMASK   0x00000020
   #define NX_DEVICERALTKEYMASK   0x00000040
   #define NX_DEVICERCTLKEYMASK   0x00002000
   ```
   Right-Option sets bit **0x40** in the 64-bit `CGEventGetFlags` value; Left-Option 0x20. **skhd**
   reads exactly these (`hotkey.h`: `Event_Mask_LAlt=0x20`, `Event_Mask_RAlt=0x40`,
   `Event_Mask_LCmd=0x08`, `Event_Mask_RCmd=0x10`, `Event_Mask_RControl=0x2000`, …).

So on a CGEventTap you have **two** independent ways to know it was the *right* Option: keycode
0x3D and device bit 0x40. (Carbon `RegisterEventHotKey` has neither — its modifier mask is
`cmdKey/optionKey/…` with no left/right, another reason it can't target Right-Option specifically.)

### 2.3 Which keys are practical Talk Keys

| Candidate | Present on all Macs? | Default action if pressed alone | Observable release edge | Verdict |
|---|---|---|---|---|
| **Right-Option** (0x3D) | ✅ | none (modifier-in-waiting) | ✅ flagsChanged, Alt bit clears | **Best default** — universal, inert, L/R-distinct, no Cmd overlap with our Cmd-V insertion |
| **Fn / Globe** (0x3F) | ✅ (laptops) | **remappable** in Settings ("Press 🌐 key to…"; can be Dictation) | ✅ flagsChanged, Fn bit clears | Ergonomic (thumb) but risky — see hazards below |
| **F13** (0x69) | ❌ (full-size / external only; laptops need a remap) | none in most apps | ✅ keyUp | **Fallback** — the one that works with **Carbon / zero TCC** |
| **Right-Command** (0x36) | ✅ | none alone | ✅ flagsChanged | Fine, but Cmd overlaps our Cmd-V insertion path — prefer Right-Option |

Fn/Globe hazards, specifically: (a) System Settings → Keyboard → "Press 🌐 key to" can be set to
*Change Input Source*, *Show Emoji & Symbols*, or *Start Dictation* — pressing-and-holding it then
also triggers that action, and *Start Dictation* directly collides with us; (b) macOS's own
"press Fn twice for Dictation" can double-fire; (c) on some external/third-party keyboards Fn is
handled in-keyboard and never reaches the OS as `kCGEventFlagMaskSecondaryFn` at all. Right-Option
has none of these. A held bare modifier also does **not** autorepeat, so there's no keyDown storm to
debounce (verify in the spike).

## 3. TCC permission for a bare CLI binary

The three candidates split cleanly, and this is the load-bearing trade-off.

- **Listen-only CGEventTap → Input Monitoring (`kTCCServiceListenEvent`).** The modern access API is
  in `CGEvent.h`, verbatim:
  ```c
  /* Checks whether the current process already has event listening access */
  CG_EXTERN bool CGPreflightListenEventAccess(void) CG_AVAILABLE_STARTING(10.15);
  /* Requests event listening access if absent, potentially prompting */
  CG_EXTERN bool CGRequestListenEventAccess(void) CG_AVAILABLE_STARTING(10.15);
  ```
  The `CGEventTapCreate` header still carries the *pre-TCC* wording ("…may only receive key up and
  down events if access for assistive devices is enabled … If the tap is not permitted … NULL is
  returned"). **That NULL claim is stale.** **Ran** on this machine, in a process with **no** grant
  (`CGPreflightListenEventAccess()` = `false`): the listen-only keyboard tap was created
  **NON-NULL but `CGEventTapIsEnabled` = `false`**, and calling `CGEventTapEnable(tap, true)` left it
  **still `false`**. So modern behaviour is *tap created, permanently disabled until Input Monitoring
  is granted* — a naive `tap != NULL` check would falsely conclude success. Use
  `CGPreflightListenEventAccess()` at startup and `CGRequestListenEventAccess()` to prompt; treat a
  disabled tap as "not yet granted". (Nuance carried from the companion sheet: an *active/consuming*
  keyboard tap may engage Accessibility rather than / in addition to Input Monitoring — but we are
  listen-only, so `kTCCServiceListenEvent` is the one that applies. Cross-ref
  [macos-text-insertion.md](./macos-text-insertion.md) §7, WWDC19-701, Quinn.)

- **Carbon `RegisterEventHotKey` → NO TCC AT ALL.** **Ran:** in the *same* un-granted process
  (`AXIsProcessTrusted()` = `false`, both CG preflights `false`), `RegisterEventHotKey(F13, mods=0,
  …, GetApplicationEventTarget(), …)` returned **OSStatus 0 (`noErr`) with a non-null
  `EventHotKeyRef`**. A global hot key is a WindowServer registration, not an event interception, so
  it is not gated by TCC. This is the decisive property in Carbon's favour and it is confirmed
  empirically here. (Receiving the pressed/released events still needs an `InstallEventHandler` on the
  event target + a running run loop — registration alone is proven; delivery is a spike item since it
  needs a keypress.)

- **IOKit `IOHIDManager` → Input Monitoring.** **Ran:** `IOHIDManagerOpen()` →
  **`kIOReturnNotPermitted` (0xe00002e2)** in this un-granted process. Unlike the tap (created but
  silently disabled), HID open **fails loudly** with an error — easier to detect, but still needs the
  grant.

**CLI attribution.** Identical story to the microphone (Capture) and PostEvent (Insertion) grants:
run the unbundled binary **from a terminal and the Input-Monitoring grant attaches to the terminal
app** (the "responsible process"); a launchd-run binary is its own responsible process and can
appear in the pane in its own right. Exact per-service rule is not documented by Apple — cross-ref
[macos-text-insertion.md](./macos-text-insertion.md) §7 (Quinn's responsible-process doctrine;
cliclick precedent). Reset for testing: `tccutil reset ListenEvent` (optionally scoped to the
terminal's bundle id).

**Secure Event Input caveat.** A focused password field, or a terminal with "Secure Keyboard Entry"
on, enables secure input, which **stops event taps and the Carbon event monitor from seeing
keystrokes** (documented in TN2150 and in `CarbonEvents.h`'s `GetEventMonitorTarget` note: *"both
Carbon and Cocoa password edit text controls enable a secure input mode … which prevents keyboard
events from being passed to other applications"*). So **whichever observer we pick, the Talk Key can
go dark while a password field is focused** — a real edge to surface to the user, not a bug. Detect
via `IsSecureEventInputEnabled()` and name the holder PID — cross-ref
[macos-text-insertion.md](./macos-text-insertion.md) §6.

## 4. Self-event hazard (we also POST synthetic events)

The same binary posts synthetic events for **Insertion** (Cmd-V or Unicode keystrokes —
[macos-text-insertion.md](./macos-text-insertion.md) §2–§3). Can our observer see its own output and
loop?

- **For hold-to-talk specifically, the logical collision is nil.** We *observe* the **Talk Key**
  (Right-Option / F13). We *post* **V + Command** (or unicode-carrier keystrokes on keycode 0x31).
  Different keys — our observer, filtering for Right-Option, will simply not match the `V`/`Cmd`
  events. And the sequencing helps: by the time Insertion posts Cmd-V, the Talk Key has already been
  *released* (release ends the Utterance → transcript → Insertion), so the observer isn't even
  looking for a down edge. This is the opposite of espanso's problem (espanso observes *all* keys to
  detect triggers, so it *must* filter its own injected text).
- **Still, tag our posts defensively.** Two source-verified techniques:
  - **`kCGEventSourceUserData`** — `CGEventTypes.h`: *"Key to access a field that contains the event
    source user-supplied data, up to 64 bits."* Create a tagged `CGEventSource`, set a magic value,
    and have the observer skip events whose source user data matches. **Ran:**
    `CGEventSourceCreate(kCGEventSourceStateCombinedSessionState=0)` → `CGEventSourceGetSourceStateID`
    returned 0; `CGEventSourceSetUserData(src, -27469)` then `CGEventSourceGetUserData` returned
    **-27469** — the tag round-trips. In the tap callback, read it with
    `CGEventGetIntegerValueField(event, kCGEventSourceUserData)`.
  - **espanso's actual trick** is *not* the source user data (the prompt's hypothesis) — it abuses
    the event **location**. `espanso-inject/src/mac/native.mm`: `CGEventSetLocation(e,
    CGPointMake(-27469, 0))` on every posted event; `espanso-detect/src/mac/native.mm` drops any
    event whose `NSEvent.locationInWindow.x` is within 0.001 of `-27469` (source-verified constant).
    Works, but `kCGEventSourceUserData` is the cleaner, purpose-built channel — recommend that.
- **Also relevant:** `kCGEventSourceStateID` / `CGEventSourceGetSourceStateID` (state 0 =
  combined-session, 1 = HID-system, −1 = private) lets you tell HID-origin events from
  synthesized/session events, a coarser filter than the user-data tag.

Net: for type-wave, self-observation is a **non-issue by key-disjointness**, and we add a
`kCGEventSourceUserData` tag on our Insertion posts as cheap insurance.

## 5. Empirical results (what actually ran on this machine)

Probe in the session scratchpad (`probe.zig`), extern-decls only (no `@cImport`), built with the
flake's Zig `0.17.0-dev.1267+300116b02` and run on macOS 26.5.1. It is a `kCGEventTapOptionListenOnly`
observer — it posts nothing and consumes nothing. Build line (all flags verified):

```
zig build-exe probe.zig -lc -framework CoreGraphics -framework Carbon \
  -framework ApplicationServices -framework IOKit -framework CoreFoundation \
  -F"$(xcrun --show-sdk-path)/System/Library/Frameworks"
```

| Probe | Result | Meaning |
|---|---|---|
| `CGPreflightListenEventAccess()` | `false` | this process has **no** Input Monitoring |
| `CGPreflightPostEventAccess()` | `false` | no PostEvent (Insertion) grant either |
| `AXIsProcessTrusted()` | `false` | no Accessibility grant — clean un-granted baseline |
| `CGEventSourceCreate(0)` → `GetSourceStateID` | `0` | combined-session source (self-event §4) |
| `SetUserData(-27469)` → `GetUserData` | `-27469` | self-event tag round-trips |
| `CGEventTapCreate(session, listen-only, kbd mask)` | **NON-NULL**, `IsEnabled=false` | **stale header:** tap is *created but disabled* without Input Monitoring |
| … after `CGEventTapEnable(tap, true)` | `IsEnabled` **still false** | cannot force-enable without the grant |
| `CGEventTapCreate(HID, listen-only, …)` | NON-NULL, `IsEnabled=false` | HID-level tap also created-but-disabled (root-only per header; also gated) |
| `RegisterEventHotKey(F13, mods=0)` | **OSStatus 0, ref non-null** | **Carbon needs NO TCC** — registered in the un-granted process |
| `RegisterEventHotKey(RightOption 0x3D / Fn 0x3F, mods=0)` | OSStatus 0, ref non-null | registration *accepted without validation* — does **not** prove it fires (expected: it won't, §1.2) |
| `IOHIDManagerOpen()` | `0xe00002e2` = **`kIOReturnNotPermitted`** | HID observation gated by Input Monitoring; fails loudly |
| listen-only tap on run loop, 1.5 s | **0 events** | headless — no human at the keyboard (see limitation below) |

**Could not run (honest limitations):** no physical keypress was possible (headless agent, no TTY
with a human), and this process holds no Input Monitoring grant — so the *content* observations the
spike needs (press Fn → confirm it's `flagsChanged` + `kCGEventFlagMaskSecondaryFn` and not
`keyDown`; press Right-Option → keycode 0x3D + device bit 0x40; confirm the key-UP edge for each
candidate; measure press-to-callback latency) were **not** captured here. They are grounded above in
the SDK headers + the four reference tools, and listed as spike items in §7. Everything marked
"**Ran:**" executed exactly as reported.

## 6. Zig integration notes

- **Bindings: extern declarations** (the flake's Zig has no `@cImport` —
  [zig-websocket-tls.md](./zig-websocket-tls.md) §9). The whole observer surface is ~10 functions
  and a callback typedef. All ran in the probe.
- **The callback typedef** is `CGEventTapCallBack` from `CGEventTypes.h`, verbatim:
  ```c
  typedef CGEventRef __nullable (*CGEventTapCallBack)(CGEventTapProxy proxy,
    CGEventType type, CGEventRef event, void * __nullable userInfo);
  ```
  In Zig: `*const fn (CGEventTapProxy, u32, CGEventRef, ?*anyopaque) callconv(.c) CGEventRef`.
  **The callback must return the event** (even for listen-only, where the return is ignored) — return
  the incoming `event`, never `null`, or you'd be behaving like a consuming tap.
- **Run-loop wiring** (the exact sequence the probe ran):
  ```zig
  const tap = CGEventTapCreate(1, 0, 1, mask, tapCB, ctx); // session, headInsert, listenOnly
  const src = CFMachPortCreateRunLoopSource(null, tap, 0);
  CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
  CGEventTapEnable(tap, true);
  // then run the loop: CFRunLoopRun() on a dedicated thread, or integrate with the app's loop.
  ```
  The mask for a **modifier** Talk Key is `CGEventMaskBit(kCGEventFlagsChanged)` (bit 12); for a
  **normal key** it's `CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp)` (bits 10|11).
  Read the keycode with `CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode /* 9 */)` and the
  modifier state with `CGEventGetFlags(event)`.
- **The auto-disable gotcha — do not skip this.** `CGEventTypes.h`:
  ```c
  /* Out of band event types … to notify it of unusual conditions that disable the event tap. */
  kCGEventTapDisabledByTimeout = 0xFFFFFFFE,
  kCGEventTapDisabledByUserInput = 0xFFFFFFFF
  ```
  If the callback is ever slow, or the user does certain input, the OS **disables the tap** and
  delivers one of these as the event `type`. Both skhd and Hammerspoon handle it identically
  (source-verified) — catch the type and re-enable:
  ```zig
  if (type == 0xFFFFFFFE or type == 0xFFFFFFFF) { CGEventTapEnable(tap, true); return event; }
  ```
- **ABI notes:** `CGEventRef`, `CFMachPortRef`, `CGEventSourceRef` are opaque pointers (`?*opaque{}`);
  `CGEventMask`/`CGEventFlags` = `u64`; `CGKeyCode` = `u16`; `CGEventType` = `u32`; a virtual keycode
  read from the field comes back `i64`. `EventHotKeyID` is an `extern struct { signature: u32, id:
  u32 }`.
- **Frameworks / link flags** (all *ran*): `-framework CoreGraphics` (the tap + access APIs),
  `-framework Carbon` (RegisterEventHotKey), `-framework ApplicationServices` (`AXIsProcessTrusted`),
  `-framework CoreFoundation` (run loop), and `-framework IOKit` only if the HID route is used;
  `-lc` and `-F"$SDK/System/Library/Frameworks"`. No `-lobjc` needed for the CGEventTap path (unlike
  the pasteboard path in the insertion sheet) — the whole observer is plain C.
- **AppKit alternative — `+[NSEvent addGlobalMonitorForEventsMatchingMask:]`.** This is what
  **espanso** uses (`espanso-detect/src/mac/native.mm`, mask
  `NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged`). It is **observe-only** (a global
  monitor *cannot* consume — good for us) and it **does** deliver key-up. Two catches: (1) it needs
  the same Input Monitoring/Accessibility grant as a tap for keyboard events, and (2) it requires a
  running **AppKit** app (`NSApplication` + its run loop) and, per Apple, a global monitor **does not
  see events delivered to your own app** — fine for a background dictation tool that never has focus.
  From Zig it means the ObjC-runtime-C bridge (`objc_getClass`/`sel_registerName`/`objc_msgSend`
  casts, plus a block for the handler) — strictly more moving parts than the plain-C CGEventTap.
  Mentioned for completeness; the CGEventTap is simpler and equally capable.

## 7. Recommendation (for the blocked spike ticket #9 "Prototype the hold-to-talk insertion spike")

**Talk Key: Right-Option (`kVK_RightOption` = 0x3D). Observation API: a listen-only CGEventTap
(`kCGSessionEventTap`, `kCGEventTapOptionListenOnly`, mask = `kCGEventFlagsChanged`).** Track the
edge by the `kCGEventFlagMaskAlternate` bit (press = newly set / release = newly cleared) and confirm
it's the *right* Option via keycode 0x3D and/or device bit `NX_DEVICERALTKEYMASK` (0x40).

Three load-bearing reasons:

1. **The mandatory release edge is delivered natively and non-consumingly.** Hold-to-talk lives or
   dies on the key-UP that ends the Utterance; a listen-only tap sees the Right-Option release as a
   flag-cleared `flagsChanged` (§1, §2), while `kCGEventTapOptionListenOnly` guarantees the key still
   works normally in the Focused Target (§1.1).
2. **Right-Option is the lowest-risk ergonomic key:** present on every Mac keyboard, inert when
   pressed alone, cleanly distinguishable from Left-Option (keycode + device bit, §2.2), and — unlike
   Right-Command — it has **no overlap with the Cmd-V we post for Insertion**, so the self-event
   question is moot (§4).
3. **Only a CGEventTap (or raw HID) can observe a bare-modifier Talk Key at all** — Carbon
   `RegisterEventHotKey` fires off the keyDown path and cannot see Right-Option/Fn (§1.2, confirmed:
   registration is accepted but won't fire). The one cost is the **Input Monitoring** grant, and
   type-wave is *already* sending the user to the same System Settings area for the Microphone
   (Capture) and PostEvent (Insertion) grants — a third toggle in the same pane is acceptable friction
   for the Talk-Key freedom it buys.

**The sharp tension, stated plainly: Carbon (no TCC) vs CGEventTap (Input Monitoring, sees
everything).** Carbon's zero-TCC property is genuinely attractive and empirically confirmed here
(§3, §5), and Carbon *does* give a clean pressed/released for a held real key (Hammerspoon proves it).
But Carbon can only watch a **keycode+modifier chord on the keyDown path**, which forces the Talk Key
to be something like **F13** — a key most laptops don't have without a `hidutil` remap. For a tool
whose whole value is "hold one easy key anywhere," constraining the key to F13 to save one toggle is
the wrong trade. **CGEventTap wins for the default.** Keep **Carbon + F13 as the documented
zero-TCC fallback** for users (or environments) that refuse the Input Monitoring grant — it's a small
amount of extra code and it genuinely needs no permission.

**Rejected:** IOKit `IOHIDManager` (needs a seize + virtual-device re-injection to stay
non-consuming, plus reconstructing Apple's private Fn HID usages, plus the same Input Monitoring
grant — all cost, no benefit here, §1.3); and Fn/Globe as the *default* Talk Key (remappable to
Dictation, "press twice" double-fire, and inconsistent surfacing across keyboards — §2.3) — worth an
A/B, not the default.

### What the spike must verify empirically (headless research could not press keys)

1. **Right-Option edges, for real:** with Input Monitoring granted, confirm press/release each arrive
   as `flagsChanged` with keycode 0x3D, `kCGEventFlagMaskAlternate` toggling, and device bit 0x40 set
   — and that a *held* Right-Option produces exactly one down edge and one up edge (no autorepeat
   storm). Map press → start Capture / open Transcription Session, release → commit the Utterance.
2. **Fn/Globe behaviour on this OS+keyboard:** does pressing Fn emit `flagsChanged` +
   `kCGEventFlagMaskSecondaryFn` (keycode 0x3F)? Does the "Press 🌐 key to…" setting or "press twice
   for Dictation" interfere? (Decides whether Fn is a viable A/B alternative.)
3. **The created-but-disabled TCC dance:** confirm that after `CGRequestListenEventAccess()` and a
   grant, `CGEventTapIsEnabled` flips to true and events flow; and that the grant attaches to the
   **terminal** for a CLI run (vs the bare binary under launchd). Reset with `tccutil reset ListenEvent`.
4. **Latency press-to-callback** on the chosen key — should be sub-ms, but confirm capture starts
   promptly enough that the first ~100 ms of speech isn't clipped.
5. **Self-event non-collision under load:** with Insertion actively posting Cmd-V, confirm the
   Right-Option observer never matches our synthetic `V`/`Cmd`; add the `kCGEventSourceUserData` tag
   on Insertion posts and confirm the observer can read/skip it (belt-and-braces).
6. **Secure Event Input:** with a password field focused (or "Secure Keyboard Entry" on), confirm the
   tap goes silent, and that `IsSecureEventInputEnabled()` + holder-PID lets us tell the user why the
   Talk Key stopped working (rather than dropping the Utterance silently).
7. **The Carbon/F13 fallback end-to-end:** with **no** TCC granted, does `RegisterEventHotKey(F13)` +
   `InstallEventHandler(GetEventDispatcherTarget(), …, kEventHotKeyPressed|kEventHotKeyReleased)` +
   a CFRunLoop actually deliver a clean **pressed and released** for a *held* F13 from a pure CLI
   (no `NSApplication`)? This is the load-bearing unknown that decides whether the zero-TCC path is
   real.
8. **The tap auto-disable path:** artificially stall the callback (or trigger `…DisabledByUserInput`)
   and confirm the re-enable handler (§6) recovers the observer.

### Open questions / unverified

1. **All physical-keypress observations** (edges, keycodes, flag bits, Fn surfacing, latency) — the
   headless probe could not press keys; grounded in headers + tool source, but spike item #1–#2.
2. Whether `RegisterEventHotKey` **fires** for a bare modifier/Fn — registration is accepted with no
   validation (**ran**), firing is expected *not* to happen but unverified (§1.2).
3. Whether a **consuming** (`kCGEventTapOptionDefault`) keyboard tap needs Accessibility rather than
   Input Monitoring — moot for our listen-only observer, but undocumented; noted for completeness.
4. The exact **CLI TCC attribution** rule per service (terminal vs. bare binary) — not stated by
   Apple; microphone/PostEvent precedent (companion sheet §7) suggests the terminal.
5. Whether `RegisterEventHotKey` + Carbon event delivery works in a **pure CLI without
   `NSApplication`** (spike item #7) — registration proven headless; delivery unproven.
6. Fn/Globe **surfacing variance** across built-in vs external/third-party keyboards and macOS
   versions — Karabiner's need to drop to raw HID for Fn suggests the Quartz surfacing is not
   universal.
7. The private **Apple Fn/Globe HID usages** (`apple_vendor_top_case::keyboard_fn`,
   `apple_vendor_keyboard::function`) are absent from this SDK — only relevant if the (rejected) HID
   route is ever revisited.
