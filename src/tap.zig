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
extern "c" fn CFMachPortInvalidate(port: CFMachPortRef) void;
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopAddSource(rl: CFRunLoopRef, src: CFRunLoopSourceRef, mode: CFStringRef) void;
extern "c" fn CFRunLoopRemoveSource(rl: CFRunLoopRef, src: CFRunLoopSourceRef, mode: CFStringRef) void;
extern "c" fn CFRunLoopPerformBlock(rl: CFRunLoopRef, mode: CFStringRef, block: *anyopaque) void;
extern "c" fn CFRunLoopWakeUp(rl: CFRunLoopRef) void;
extern "c" fn CFRunLoopRun() void;
extern "c" fn CFRelease(cf: ?*anyopaque) void;
extern var kCFRunLoopCommonModes: CFStringRef;
extern var _NSConcreteStackBlock: anyopaque;

extern "c" fn CGPreflightListenEventAccess() bool;
extern "c" fn CGRequestListenEventAccess() bool;

// scheduleRecreate hands the run loop a manual stack block (same layout as capture.zig's
// PermissionBlock). CFRunLoopPerformBlock copies it, so the stack literal may die at
// return; flags=0 means the copy is a plain memcpy, which is exactly right for the one
// captured raw pointer.
const BlockDescriptor = extern struct { reserved: usize = 0, size: usize };
const RecreateBlock = extern struct {
    isa: *anyopaque,
    flags: c_int = 0,
    reserved: c_int = 0,
    invoke: *const fn (*RecreateBlock) callconv(.c) void,
    descriptor: *const BlockDescriptor,
    tap: *Tap,
};
const recreate_block_descriptor = BlockDescriptor{ .size = @sizeOf(RecreateBlock) };

/// `globe` is the Fn / 🌐 key. Named `globe` (not `fn`) because `fn` is a Zig keyword;
/// it is the "fn" option in the config vocabulary (wayfinder #16). Its observation is
/// compile-verified only — live behaviour is unverified and may collide with macOS's
/// own Fn→Dictation binding (wayfinder #6). right_option / left_option are proven live.
pub const TalkKey = enum { right_option, left_option, globe };

pub const Callbacks = struct {
    ctx: ?*anyopaque,
    on_press: *const fn (ctx: ?*anyopaque, key: TalkKey, keycode: i64, flags: u64) void,
    on_release: *const fn (ctx: ?*anyopaque, key: TalkKey) void,
    /// The OS disabled the tap (a slow callback timeout, or certain user input) and we
    /// tried to re-enable it. `reenabled` reports whether it took — `false` means the
    /// tap is dead (Input Monitoring likely revoked) and the daemon should surface it
    /// (wayfinder #18). Optional; runs on the run-loop thread, so keep it fast.
    on_disabled: ?*const fn (ctx: ?*anyopaque, by_timeout: bool, reenabled: bool) void = null,
    /// A self-tagged synthetic event (insert.zig's Insertion probe) round-tripped the
    /// event stream back into this tap — objective, in-process proof the PostEvent grant
    /// is live, where `CGPreflightPostEventAccess` can stay stale-`false` for the process
    /// lifetime (#129). Optional; runs on the run-loop thread, so keep it fast.
    on_self_event: ?*const fn (ctx: ?*anyopaque) void = null,
};

pub const Tap = struct {
    cbs: Callbacks,
    /// Run-loop-thread only after `install` — `recreate` frees and replaces it, so no
    /// other thread may dereference it (cross-thread liveness reads go through `live`).
    port: CFMachPortRef = null,
    source: CFRunLoopSourceRef = null,
    /// The run loop that services the tap, captured at `install`; `scheduleRecreate`
    /// targets it from any thread (CFRunLoop is documented thread-safe).
    run_loop: CFRunLoopRef = null,
    /// Cross-thread mirror of CGEventTapIsEnabled, maintained at every mutation point on
    /// the run-loop thread (create/recreate, and the callback's disabled-by re-enable).
    /// The supervisor polls this instead of the port because `recreate` frees the port.
    live: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Coalesces scheduleRecreate: at most one recreate block in flight.
    recreate_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    right_down: bool = false,
    left_down: bool = false,
    fn_down: bool = false,

    /// Preflight (silent), and prompt for Input Monitoring if absent. Returns the
    /// preflight result — a prompt fired on `false` won't flip this until re-run.
    pub fn requestListenAccess() bool {
        if (CGPreflightListenEventAccess()) return true;
        return CGRequestListenEventAccess();
    }

    /// Silent preflight only — never prompts. The daemon's self-heal supervisor (#19)
    /// polls this to notice Input Monitoring being granted without re-prompting.
    pub fn listenGranted() bool {
        return CGPreflightListenEventAccess();
    }

    /// Runs on the run-loop thread. Must stay fast (a slow callback makes the OS
    /// disable the tap) — it only records the edge and hands off to the caller.
    fn callback(_: CGEventTapProxy, etype: u32, event: CGEventRef, userInfo: ?*anyopaque) callconv(.c) CGEventRef {
        const self: *Tap = @ptrCast(@alignCast(userInfo.?));

        // The OS disables the tap on timeout / certain user input — re-enable it, then
        // check it took. A revoked Input Monitoring grant makes the re-enable a no-op
        // (CGEventTapIsEnabled stays false); report the outcome so the daemon can log +
        // sound the failure and recover once the grant returns (wayfinder #18).
        if (etype == kCGEventTapDisabledByTimeout or etype == kCGEventTapDisabledByUserInput) {
            CGEventTapEnable(self.port, true);
            const took = CGEventTapIsEnabled(self.port);
            self.live.store(took, .release);
            if (self.cbs.on_disabled) |cb|
                cb(self.cbs.ctx, etype == kCGEventTapDisabledByTimeout, took);
            return event;
        }
        if (etype != kCGEventFlagsChanged) return event;

        // Our own synthetic events: report the round-trip (the #129 PostEvent probe),
        // then skip them (they never match the Option filter anyway).
        if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == self_event_tag) {
            if (self.cbs.on_self_event) |cb| cb(self.cbs.ctx);
            return event;
        }

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

    /// Create the tap, add it to the current run loop, and enable it. Returns whether the
    /// tap is actually **live** — `false` means it was created but stays disabled because
    /// Input Monitoring isn't granted yet (the header's "returns NULL when denied" is
    /// stale; crib sheet §3/§5). A created-while-denied port can NEVER be brought live by
    /// CGEventTapEnable (#127, confirmed live by #129) — the daemon's supervisor re-arms
    /// it via `scheduleRecreate` instead — so only a genuine creation failure (null port)
    /// is an error here. Must run on the thread whose run loop will service the tap (the
    /// daemon calls it on the main thread before its run loop starts).
    pub fn install(self: *Tap) error{TapCreateFailed}!bool {
        self.run_loop = CFRunLoopGetCurrent();
        return self.create();
    }

    /// The shared create body: fresh CGEventTapCreate + run-loop source + enable, with
    /// the `live` mirror updated. Run-loop thread only (install, and recreate's block).
    fn create(self: *Tap) error{TapCreateFailed}!bool {
        const mask: CGEventMask = 1 << 12; // CGEventMaskBit(kCGEventFlagsChanged)
        const port = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, mask, callback, self);
        if (port == null) {
            self.live.store(false, .release);
            return error.TapCreateFailed;
        }
        self.port = port;
        self.source = CFMachPortCreateRunLoopSource(null, port, 0);
        CFRunLoopAddSource(self.run_loop, self.source, kCFRunLoopCommonModes);
        CGEventTapEnable(port, true);
        const is_live = CGEventTapIsEnabled(port);
        self.live.store(is_live, .release);
        return is_live;
    }

    /// Tear the port + run-loop source down and create the tap fresh. This is the #127
    /// re-arm, confirmed live by #129: a fresh CGEventTapCreate re-consults tccd, so the
    /// create attempt itself is the grant detector — where CGPreflightListenEventAccess
    /// stays stale in-process and CGEventTapEnable on the created-while-denied port is
    /// permanently inert. Run-loop thread only (the spike kept every tap mutation there);
    /// other threads use `scheduleRecreate`. Returns whether the new tap is live; a hard
    /// create failure leaves no tap and reads as not-live until a later attempt succeeds.
    pub fn recreate(self: *Tap) bool {
        if (self.source != null) {
            CFRunLoopRemoveSource(self.run_loop, self.source, kCFRunLoopCommonModes);
            CFRelease(@ptrCast(self.source));
            self.source = null;
        }
        if (self.port != null) {
            CFMachPortInvalidate(self.port);
            CFRelease(@ptrCast(self.port));
            self.port = null;
        }
        return self.create() catch false;
    }

    /// Fire-and-forget re-arm from any thread: hand `recreate` to the run loop captured
    /// at `install`, coalesced to one attempt in flight. The outcome is read as
    /// `isEnabled` on a later supervisor tick (the spike saw the tap live on the very
    /// next poll after granting).
    pub fn scheduleRecreate(self: *Tap) void {
        if (self.run_loop == null) return;
        if (self.recreate_pending.swap(true, .acq_rel)) return;
        var block = RecreateBlock{
            .isa = &_NSConcreteStackBlock,
            .invoke = recreateOnRunLoop,
            .descriptor = &recreate_block_descriptor,
            .tap = self,
        };
        CFRunLoopPerformBlock(self.run_loop, kCFRunLoopCommonModes, @ptrCast(&block));
        CFRunLoopWakeUp(self.run_loop);
    }

    fn recreateOnRunLoop(block: *RecreateBlock) callconv(.c) void {
        const self = block.tap;
        // Re-check on the owning thread: the OS-timeout re-enable may have raced us live.
        if (!self.live.load(.acquire)) _ = self.recreate();
        self.recreate_pending.store(false, .release);
    }

    /// Whether the tap currently exists and is delivering events. Safe from any thread —
    /// reads the run-loop thread's mirror, never the port itself.
    pub fn isEnabled(self: *Tap) bool {
        return self.live.load(.acquire);
    }

    /// Block on the current run loop, servicing the tap. Never returns.
    pub fn run(_: *Tap) void {
        CFRunLoopRun();
    }
};
