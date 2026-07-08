//! tap.zig — global Talk Key observation via a listen-only CGEventTap.
//! Observes Right-Option (the paste Talk Key) and Left-Option (the keystroke
//! Talk Key) system-wide, delivering press/release edges to a caller. Stays
//! non-consuming (`kCGEventTapOptionListenOnly`) so the key still works in the
//! Focused Target. Portable half of the spike — knows nothing about Insertion.
//!
//! Extern decls + design per docs/research/macos-hotkey-observation.md §1, §2, §6.
//! (@cImport is gone on this nightly; hand-written externs instead.)

const std = @import("std");

const CGEventRef = ?*opaque {};
const CGEventTapProxy = ?*anyopaque;
const CFMachPortRef = ?*opaque {};
const CFRunLoopSourceRef = ?*opaque {};
const CFRunLoopRef = ?*opaque {};
const CFStringRef = ?*opaque {};
const CFAllocatorRef = ?*anyopaque;
const CGEventMask = u64;

const CGEventTapCallBack = *const fn (CGEventTapProxy, u32, CGEventRef, ?*anyopaque) callconv(.c) CGEventRef;

const kCGSessionEventTap: u32 = 1;
const kCGHeadInsertEventTap: u32 = 0;
const kCGEventTapOptionListenOnly: u32 = 1;

const kCGEventFlagsChanged: u32 = 12;
const kCGEventTapDisabledByTimeout: u32 = 0xFFFFFFFE;
const kCGEventTapDisabledByUserInput: u32 = 0xFFFFFFFF;

const kCGKeyboardEventKeycode: u32 = 9;
const kCGEventSourceUserData: u32 = 42; // CGEventField

// Device-dependent modifier bits (IOKit/hidsystem/IOLLEvent.h). The
// device-independent kCGEventFlagMaskAlternate (0x80000) can't tell L from R.
const NX_DEVICELALTKEYMASK: u64 = 0x20;
const NX_DEVICERALTKEYMASK: u64 = 0x40;

// Fn/Globe surfaces only as this device-independent flag on a flagsChanged event —
// it has no distinct keycode (wayfinder #6). CGEventTypes.h: kCGEventFlagMaskSecondaryFn.
const kCGEventFlagMaskSecondaryFn: u64 = 0x800000;

// Virtual keycodes for the two Option keys (Events.h).
const kVK_Option: i64 = 0x3A; // left
const kVK_RightOption: i64 = 0x3D;

/// Our Insertion posts carry this in kCGEventSourceUserData so we can skip them
/// (belt-and-braces; the Talk Key ≠ the keys we post, so no real collision).
pub const self_event_tag: i64 = -27469;

extern "c" fn CGEventTapCreate(tap: u32, place: u32, options: u32, mask: CGEventMask, cb: CGEventTapCallBack, userInfo: ?*anyopaque) CFMachPortRef;
extern "c" fn CGEventTapEnable(tap: CFMachPortRef, enable: bool) void;
extern "c" fn CGEventTapIsEnabled(tap: CFMachPortRef) bool;
extern "c" fn CGEventGetIntegerValueField(ev: CGEventRef, field: u32) i64;
extern "c" fn CGEventGetFlags(ev: CGEventRef) u64;
extern "c" fn CFMachPortCreateRunLoopSource(alloc: CFAllocatorRef, port: CFMachPortRef, order: c_long) CFRunLoopSourceRef;
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopAddSource(rl: CFRunLoopRef, src: CFRunLoopSourceRef, mode: CFStringRef) void;
extern "c" fn CFRunLoopRun() void;
extern var kCFRunLoopCommonModes: CFStringRef;

extern "c" fn CGPreflightListenEventAccess() bool;
extern "c" fn CGRequestListenEventAccess() bool;

/// `globe` is the Fn / 🌐 key. Named `globe` (not `fn`) because `fn` is a Zig keyword;
/// it is the "fn" option in the config vocabulary (wayfinder #16). Its observation is
/// compile-verified only — live behaviour is unverified and may collide with macOS's
/// own Fn→Dictation binding (wayfinder #6). right_option / left_option are proven live.
pub const TalkKey = enum { right_option, left_option, globe };

pub const Callbacks = struct {
    ctx: ?*anyopaque,
    on_press: *const fn (ctx: ?*anyopaque, key: TalkKey, keycode: i64, flags: u64) void,
    on_release: *const fn (ctx: ?*anyopaque, key: TalkKey) void,
};

pub const Tap = struct {
    cbs: Callbacks,
    port: CFMachPortRef = null,
    right_down: bool = false,
    left_down: bool = false,
    fn_down: bool = false,

    /// Preflight (silent), and prompt for Input Monitoring if absent. Returns the
    /// preflight result — a prompt fired on `false` won't flip this until re-run.
    pub fn requestListenAccess() bool {
        if (CGPreflightListenEventAccess()) return true;
        return CGRequestListenEventAccess();
    }

    /// Runs on the run-loop thread. Must stay fast (a slow callback makes the OS
    /// disable the tap) — it only records the edge and hands off to the caller.
    fn callback(_: CGEventTapProxy, etype: u32, event: CGEventRef, userInfo: ?*anyopaque) callconv(.c) CGEventRef {
        const self: *Tap = @ptrCast(@alignCast(userInfo.?));

        // The OS disables the tap on timeout / certain user input — re-enable it.
        if (etype == kCGEventTapDisabledByTimeout or etype == kCGEventTapDisabledByUserInput) {
            CGEventTapEnable(self.port, true);
            return event;
        }
        if (etype != kCGEventFlagsChanged) return event;

        // Ignore our own synthetic events (never matches the Option filter anyway).
        if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == self_event_tag) return event;

        const keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        const flags = CGEventGetFlags(event);

        if (keycode == kVK_RightOption) {
            self.edge(.right_option, &self.right_down, (flags & NX_DEVICERALTKEYMASK) != 0, keycode, flags);
        } else if (keycode == kVK_Option) {
            self.edge(.left_option, &self.left_down, (flags & NX_DEVICELALTKEYMASK) != 0, keycode, flags);
        }
        // Fn/Globe has no keycode, so track it on every flagsChanged by its SecondaryFn
        // bit (wayfinder #6). Edge-tracked, so the option branches above never spoof it.
        self.edge(.globe, &self.fn_down, (flags & kCGEventFlagMaskSecondaryFn) != 0, keycode, flags);
        return event;
    }

    fn edge(self: *Tap, key: TalkKey, state: *bool, down: bool, keycode: i64, flags: u64) void {
        if (down and !state.*) {
            state.* = true;
            self.cbs.on_press(self.cbs.ctx, key, keycode, flags);
        } else if (!down and state.*) {
            state.* = false;
            self.cbs.on_release(self.cbs.ctx, key);
        }
    }

    /// Create the tap, add it to the current run loop, enable it. `error.TapDisabled`
    /// means Input Monitoring isn't granted yet (the tap is created but stays off —
    /// the header's "returns NULL when denied" is stale; crib sheet §3/§5).
    pub fn install(self: *Tap) !void {
        const mask: CGEventMask = 1 << 12; // CGEventMaskBit(kCGEventFlagsChanged)
        const port = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, mask, callback, self);
        if (port == null) return error.TapCreateFailed;
        self.port = port;
        const source = CFMachPortCreateRunLoopSource(null, port, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        CGEventTapEnable(port, true);
        if (!CGEventTapIsEnabled(port)) return error.TapDisabled;
    }

    /// Block on the current run loop, servicing the tap. Never returns.
    pub fn run(_: *Tap) void {
        CFRunLoopRun();
    }
};
