//! secure_input.zig — the **Secure Input Observer**: the pure decider that turns a polled
//! Secure Event Input reading into the transitions the daemon logs and the menu shows (#245).
//!
//! While any process in the login session holds Secure Event Input, the WindowServer
//! withholds key events from **every** event tap — so the recovery chord `⌃⌘⌫` never reaches
//! the daemon at all. `tap.isRecoveryChordPress` is never evaluated and `Daemon.onRecoveryChord`
//! never fires. The Undo Runner's own `secure_input` refusal (#244) covers the neighbouring
//! case — a press that *arrives* and cannot be acted on, because the hold went up between the
//! press and the post — but nothing downstream of the tap can report a press that was never
//! delivered, which is why this observer sits beside the *probe* rather than beside the chord.
//!
//! What makes the condition so hard to recognise unaided is the asymmetry: modifier
//! `flagsChanged` events keep flowing, so the Talk Key keeps working perfectly and every
//! visible sign says the tap is healthy. Only the chord is dead. This module exists so the
//! daemon says so out loud instead of leaving the user to infer it from silence.
//!
//! Pure by design (ADR-0005): the daemon owns the impure half — `insert.secureInputActive()`,
//! `insert.secureInputHolderPid()` and `insert.procName()` — and this module owns everything
//! decided *about* those readings: when one is worth saying, what it means, the published
//! `State` the menu renders, and the wording itself. The narration lives here rather than at
//! the call site for ADR-0010's reason: `daemon.zig` carries no test blocks, so a rule that
//! lives there is a rule no test can reach.
//!
//! It observes and narrates; it gates nothing.

const std = @import("std");

/// One poll's reading of the session-wide Secure Event Input state. Gathered by the daemon on
/// the supervisor's existing facts pass — the state changes rarely, so its ~3 s cadence is
/// ample and no thread of its own is warranted.
pub const Facts = struct {
    /// `IsSecureEventInputEnabled()` — the authoritative flag. The session dictionary's
    /// holder pid can be stale while this is the truth, so this is the field that decides
    /// whether the condition is on at all.
    active: bool,
    /// `kCGSSessionSecureInputPID` from the session dictionary, or null when absent.
    holder_pid: ?i32 = null,
    /// The holder's process name via libproc, or `""` when the pid answers to nothing —
    /// `insert.procName`'s own contract, passed through unchanged so the daemon does no
    /// policy of its own. Borrowed for the duration of the call.
    holder_name: []const u8 = "",
};

/// Who is holding it, as far as the session can tell — the distinction matters because the
/// remedy differs, which is the whole reason this is three cases and not a bool.
pub const Holder = union(enum) {
    /// A live process the user can quit.
    named: struct { pid: i32, name: []const u8 },
    /// The session names a pid, but no process answers to it: the holder died without
    /// releasing the flag. **No app can release this** — it takes a re-login to clear, so it
    /// must never be reported as "quit <app>". (A live process whose name libproc will not
    /// give up reads the same way; the honest wording covers both.)
    stale: i32,
    /// Held, with no pid in the session dictionary to attribute it to.
    unknown,
};

/// What changed this poll. Emitted only on a change — a hold that persists for an hour is one
/// `taken`, not twelve hundred repetitions of it.
pub const Transition = union(enum) {
    taken: Holder,
    released,
};

/// The published condition, as everything outside this module needs it: what the Status Item
/// renders, and all the daemon has to carry across threads. Three states rather than the
/// `Holder` union's three cases, because the *remedy* is what the user acts on and `unknown`
/// shares its remedy with `named` — an unattributable holder is still a live one that may let
/// go on its own, so sending the user to log out for it would be wrong. Only `stuck` names a
/// hold that nothing can release.
pub const State = enum {
    clear,
    /// Held by a process that can release it (named or not).
    held,
    /// Held by a process that is gone: it will never release, and only a re-login clears it.
    stuck,
};

/// The condition a transition leaves behind — the daemon publishes this, never the `Holder`,
/// so the collapse from three holder cases to three states is decided here where it is tested
/// rather than at an untested call site.
pub fn state(t: Transition) State {
    return switch (t) {
        .released => .clear,
        .taken => |holder| switch (holder) {
            .named, .unknown => .held,
            .stale => .stuck,
        },
    };
}

/// The longest line `narrate` can render, holder name included — sized so the daemon's buffer
/// and this function cannot drift apart.
pub const max_line = 256;

/// The log line for one transition, rendered into `buf` (≥ `max_line`). Every line says the
/// same two things, because both are load-bearing and neither is obvious from the outside:
/// **what still works** (dictation — the Talk Key rides on modifier events, which keep
/// flowing) and **what does not** (the recovery chord, which never arrives at all). The
/// remedy differs per case, which is the reason these are separate strings.
pub fn narrate(t: Transition, buf: []u8) []const u8 {
    return switch (t) {
        .released => "Secure Event Input released — ⌃⌘⌫ is observable again",
        .taken => |holder| switch (holder) {
            .named => |h| std.fmt.bufPrint(
                buf,
                "Secure Event Input held by {s} (pid {d}) — the Talk Key still works, but ⌃⌘⌫ cannot be observed until it clears",
                .{ h.name, h.pid },
            ) catch unnamed_line,
            // No "quit it" here: the holder is already gone, and advice that sends the user
            // after a process that no longer exists is what made #245 take an hour to find.
            .stale => |pid| std.fmt.bufPrint(
                buf,
                "Secure Event Input is held by a process that is gone (pid {d}) — ⌃⌘⌫ cannot be observed; log out and back in to clear it",
                .{pid},
            ) catch unnamed_line,
            .unknown => unnamed_line,
        },
    };
}

const unnamed_line = "Secure Event Input is held by an unidentified process — the Talk Key still works, but ⌃⌘⌫ cannot be observed until it clears";

/// The observer's memory: the last reading, so a steady state stays silent. Cheap to hold —
/// the pid is compared rather than the name, so nothing is borrowed across calls.
pub const Observer = struct {
    held: bool = false,
    /// The pid last reported as holding it, so a hand-off between two holders while the flag
    /// stays set is not silently mis-attributed to the process that let go.
    held_pid: ?i32 = null,
    /// The last holder's *kind*, so the one transition that changes the remedy without
    /// changing the pid — a named holder dying under a flag that stays up — is not silent.
    held_kind: std.meta.Tag(Holder) = .unknown,

    /// Fold one poll's reading in and return what is worth saying, or null for "no change".
    ///
    /// Three things produce a `taken`: the flag going up, and — while it stays up — either
    /// the holder pid changing or its kind changing. Both of the latter move what the user
    /// should *do* about it, so silence there would leave the surfaced attribution pointing
    /// at a process that has already let go, or offer "quit it" for a holder that is gone.
    /// Everything else about a steady hold is silence.
    pub fn observe(self: *Observer, facts: Facts) ?Transition {
        if (!facts.active) {
            if (!self.held) return null;
            self.held = false;
            self.held_pid = null;
            self.held_kind = .unknown;
            return .released;
        }

        const holder = classify(facts);
        const same = self.held and
            pidEql(self.held_pid, facts.holder_pid) and
            self.held_kind == std.meta.activeTag(holder);
        if (same) return null;

        self.held = true;
        self.held_pid = facts.holder_pid;
        self.held_kind = std.meta.activeTag(holder);
        return .{ .taken = holder };
    }
};

fn pidEql(a: ?i32, b: ?i32) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

/// The holder policy: a pid with a name is a process the user can act on, a pid without one
/// cannot be acted on at all, and no pid is neither.
fn classify(facts: Facts) Holder {
    const pid = facts.holder_pid orelse return .unknown;
    if (facts.holder_name.len == 0) return .{ .stale = pid };
    return .{ .named = .{ .pid = pid, .name = facts.holder_name } };
}

// ============================================================================
// Tests — every transition driven by fed readings, so none of this needs live Secure
// Event Input to run under `zig build test`.
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn held(pid: ?i32, name: []const u8) Facts {
    return .{ .active = true, .holder_pid = pid, .holder_name = name };
}

const clear = Facts{ .active = false };

test "a hold is announced once, not once per poll" {
    // The reason the observer exists rather than a bare probe read in the loop: the
    // supervisor polls every ~3 s and a hold can last hours.
    var obs = Observer{};

    const first = obs.observe(held(751, "ghostty")).?;
    try expectEqual(@as(i32, 751), first.taken.named.pid);
    try expectEqualStrings("ghostty", first.taken.named.name);

    for (0..10) |_| try expect(obs.observe(held(751, "ghostty")) == null);
}

test "the release is announced too, and a take/release cycle repeats" {
    var obs = Observer{};

    try expect(obs.observe(held(751, "ghostty")) != null);
    try expectEqual(Transition.released, obs.observe(clear).?);
    try expect(obs.observe(clear) == null); // …and stays quiet once clear

    try expect(obs.observe(held(900, "Terminal")) != null); // the cycle can run again
    try expectEqual(Transition.released, obs.observe(clear).?);
}

test "an observer that starts up while the flag is already held still announces it" {
    // The daemon's first tick after a restart: the hold predates the process, and silence
    // there would be exactly the hole this closes.
    var obs = Observer{};
    try expect(obs.observe(held(751, "ghostty")) != null);
}

test "a dead holder pid is a stale hold, never a named process" {
    // What actually happened in #245: Ghostty enabled Secure Event Input and died without
    // releasing it. Naming it would send the user to quit a process that is already gone;
    // only a re-login clears this.
    var obs = Observer{};

    const t = obs.observe(held(751, "")).?; // libproc gives up nothing for a dead pid
    try expectEqual(@as(i32, 751), t.taken.stale);
}

test "held with no pid at all is reported as an unknown holder" {
    var obs = Observer{};
    try expectEqual(Holder.unknown, obs.observe(.{ .active = true }).?.taken);
}

test "the flag is what decides, not the presence of a holder pid" {
    // The session dictionary can name a pid while the flag is off — `IsSecureEventInputEnabled`
    // is the authority, so a stale dictionary entry alone must not raise the condition.
    var obs = Observer{};
    try expect(obs.observe(.{ .active = false, .holder_pid = 751, .holder_name = "ghostty" }) == null);
}

test "a hand-off between holders re-announces rather than naming the process that let go" {
    // The flag never drops, but the attribution changes. Staying silent would leave the menu
    // and the log pointing at an app the user has already quit.
    var obs = Observer{};
    try expect(obs.observe(held(751, "ghostty")) != null);

    const t = obs.observe(held(900, "Terminal")).?;
    try expectEqualStrings("Terminal", t.taken.named.name);
    try expect(obs.observe(held(900, "Terminal")) == null); // and then settles again
}

// --- the published state and the wording: the half that used to live untested in daemon.zig ---

test "the published state collapses the three holder cases by remedy, not by shape" {
    // `unknown` shares `held` with `named` on purpose: an unattributable holder is still a
    // live one that may let go, so the log-out remedy would be wrong advice for it.
    try expectEqual(State.held, state(.{ .taken = .{ .named = .{ .pid = 751, .name = "ghostty" } } }));
    try expectEqual(State.held, state(.{ .taken = .unknown }));
    try expectEqual(State.stuck, state(.{ .taken = .{ .stale = 751 } }));
    try expectEqual(State.clear, state(.released));
}

test "a hold and its release round-trip through the observer to the published state" {
    // The whole chain a fed reading drives: probe → transition → what the menu shows.
    var obs = Observer{};
    try expectEqual(State.held, state(obs.observe(held(751, "ghostty")).?));
    try expectEqual(State.clear, state(obs.observe(clear).?));
}

test "the narration names a live holder, and offers the log-out remedy only for a dead one" {
    var buf: [max_line]u8 = undefined;

    const named = narrate(.{ .taken = .{ .named = .{ .pid = 751, .name = "ghostty" } } }, &buf);
    try expect(std.mem.indexOf(u8, named, "ghostty") != null);
    try expect(std.mem.indexOf(u8, named, "751") != null);
    try expect(std.mem.indexOf(u8, named, "log out") == null); // it can still be quit

    const stale = narrate(.{ .taken = .{ .stale = 751 } }, &buf);
    try expect(std.mem.indexOf(u8, stale, "log out") != null);
    try expect(std.mem.indexOf(u8, stale, "751") != null);

    const unknown = narrate(.{ .taken = .unknown }, &buf);
    try expect(std.mem.indexOf(u8, unknown, "unidentified") != null);
    try expect(std.mem.indexOf(u8, unknown, "log out") == null); // it may yet release

    try expect(std.mem.indexOf(u8, narrate(.released, &buf), "released") != null);
}

test "every taken line says what still works and what does not" {
    // The asymmetry is the whole reason the condition is hard to recognise: the Talk Key keeps
    // working, so a line that only said "Secure Event Input is on" would leave the reader
    // guessing which half of the daemon it costs them.
    var buf: [max_line]u8 = undefined;
    for ([_]Transition{
        .{ .taken = .{ .named = .{ .pid = 1, .name = "app" } } },
        .{ .taken = .{ .stale = 1 } },
        .{ .taken = .unknown },
    }) |t| {
        const line = narrate(t, &buf);
        try expect(std.mem.indexOf(u8, line, "⌃⌘⌫") != null);
        try expect(std.mem.indexOf(u8, line, "cannot be observed") != null);
    }
}

test "a holder name too long for the buffer degrades to the unnamed line, never a truncation" {
    var small: [16]u8 = undefined; // deliberately under max_line
    const line = narrate(.{ .taken = .{ .named = .{ .pid = 751, .name = "a-very-long-process-name" } } }, &small);
    try expect(std.mem.indexOf(u8, line, "unidentified") != null);
}

test "a holder that dies while the flag stays up re-announces as stale" {
    // The exact #245 sequence inside one hold: Ghostty holds it, Ghostty is killed, the flag
    // stays up. The pid never changes, so only the *kind* moves — and it has to be said,
    // because the remedy moves with it: "quit ghostty" becomes "log out".
    var obs = Observer{};
    try expect(obs.observe(held(751, "ghostty")) != null);

    try expectEqual(@as(i32, 751), obs.observe(held(751, "")).?.taken.stale);
    for (0..5) |_| try expect(obs.observe(held(751, "")) == null); // then settles again
}
