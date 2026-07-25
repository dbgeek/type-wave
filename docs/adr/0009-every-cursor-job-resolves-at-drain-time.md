# ADR 0009 — Every cursor job resolves at drain time

- Status: accepted (2026-07-24; candidate 1 of the 2026-07-24 architecture review)
- Amended: 2026-07-25 (#255) — a dictation Insertion **proves its Focused Target** before it
  pastes, and fails **open** where Undo fails closed. See
  [Amendment](#amendment-2026-07-25-255--an-insertion-proves-its-focused-target).

## Context

Four things reach the cursor in this daemon: a dictation Insertion, a Re-insert, a Copy, and
an Undo's Backspaces. ADR-0008 collapsed the Undo path onto the insert worker and stated the
rule that made it correct — **resolve the record at post time, beside the effect, and flag it
only after the effect landed**. It applied that rule to Undo only. The two menu-driven paths
that share the same worker kept the shape ADR-0008 had just removed, and carried the same two
defect classes with them:

1. **A flag flipped ahead of its effect.** `daemon.menuReinsert` called
   `recent_insertions.clearUndone(stamp)` on the *main thread, at submit time*, while the
   replay drained later on the worker and `runBypass` swallowed failure by design. So a
   **failed** re-insert un-dimmed a record whose text never came back — the exact mirror of
   ADR-0008's Context §1, where a refused Undo left a record rendering dimmed with nothing
   deleted.

2. **An unenforced single-producer contract.** `submitBypass` and `submitCopy` each memcpy'd
   over an 8193-byte slot in place, with the contract written only as a doc comment
   (*"the caller must not submit while a … job is still pending"*) — the same prose ADR-0008
   named as defect class two on `submitUndo`. The drain window is real (a ~300 ms clipboard
   restore plus the paste settle), so two clicks inside it silently discarded the first, with
   no cue and no log.

Both lived at the join between `daemon.zig` and the insertion module — and `daemon.zig` has
no test blocks, so neither was reachable from a test. That is the same observation ADR-0008
opened with.

Two further splits followed from resolution happening on the producer's thread:

- **Stamp→bytes resolution was copy-pasted three times** in `daemon.zig` (`menuHistoryText`,
  `menuCopy`, `menuReinsert`), each declaring its own `[max_bytes]u8` and its own `if (n == 0)
  return`.
- **The Insertion separator's inverse had no home.** `ensureTrailingSpace` is one pure
  function in `insert.zig`, applied by the Coordinator (to buffer the Insertion Record's
  bytes) and by the insertion module (to produce the bytes that land). Its inverse — strip the
  one separator byte for Copy — was hand-rolled inline in `daemon.menuCopy` as
  `if (buf[n - 1] == ' ')`.

## Decision

**Every cursor job resolves at drain time, on the Insert Worker, beside the effect it
authorizes; any ring bookkeeping flips only after that effect landed.** ADR-0008's rule, now
covering all four paths rather than one.

The insertion module becomes the **Insertion Runner** (`src/insertion_runner.zig`, renamed
from `insertion_adapter.zig` — by the project's design vocabulary it is not an adapter at a
seam but the policy owner behind one), and:

- **Menu slots carry a capture stamp, not bytes.** `submitMenu(action, stamp)` replaces
  `submitBypass(text)` / `submitCopy(text)`. The worker resolves against the ring, applies the
  separator (Re-insert) or strips it (Copy), runs the effect, and only then calls
  `clearUndone`. `daemon.menuCopy` / `menuReinsert` are two lines each.
- **The Runner holds the ring concretely**, as the Undo Runner does and for the reason
  `undo.zig` gives: it is heap-free and test-constructible, so faking it would mean
  re-implementing eviction and stamp-keying rather than exercising them. ADR-0006's daemon
  ownership is unchanged.
- **One bounded queue replaces the two menu slots.** Both have one producer (the main thread —
  Copy is a menu action, Re-insert is deferred until the menu closes) and one consumer (the
  worker), so a single-producer/single-consumer ring makes the contract **structural**. A
  second click inside a drain queues behind the first instead of overwriting it; a click past
  the depth is refused with a cue rather than dropped. Net footprint: two 8193-byte buffers
  become four 9-byte jobs.
- **The Runner is the sole applier of the Insertion separator.** The Coordinator stops
  pre-deriving the with-space form; the Runner reports the bytes it actually landed back
  through the `.inserted` edge, and the Coordinator stamps those into the Insertion Record.
  This *deletes* `coordinator.pending: [8193]u8`, `bufferPending`, and one memcpy per
  Insertion — the record can no longer disagree with the cursor because it is no longer
  derived twice.
- **`insert.stripTrailingSpace` joins `ensureTrailingSpace`**, so both halves of the separator
  rule are one pure pair in one module, directly tested.
- **A refused cursor action is surfaced.** A failed replay, a stamp evicted before the worker
  reached it, and a click past the queue depth all fire the same red bloom + shake an Undo
  refusal shows (ADR-0007), through the Feedback Surface. One visual vocabulary for "that
  cursor action did not happen".

Two consequences of the same rule, decided here:

- **`undo.zig`'s degenerate-record exit now fires the refuse cue.** A record with zero
  grapheme clusters was a silent `return` — the one exit of six that swallowed a press,
  against ADR-0008's own "one press, one verdict, one cue". It reuses `.no_target` (every
  reason collapses to one cue anyway, so it needs no new variant).
- **`insert.deleteChars` drains the deferred clipboard restore first**, as `paste` already
  does. It was correct only because the worker happens to drain Undo last; now it is correct
  as a mechanism.

### Not decided here

- **The Undo Runner keeps its own `deleteChars` seam.** Routing deletion through the Insertion
  Runner was considered and rejected: ADR-0008's point is that the Undo Runner owns its
  sequence end to end, and the Insert Worker's drain priority already provides the
  serialization that matters. The Runner sets the priority — dictation, then menu, then Undo —
  and nothing more.
- **`daemon.menuHistoryText` stays in the daemon.** The reveal path is a synchronous read the
  menu needs on the main thread; it cannot go through the worker. Three of the four
  ring-touching entry points moved, not four.
- **`ring.record` stays under `coordinator.mu`.** Moving the record write to the Runner would
  reopen ADR-0006's locking discipline; out of scope.

## Consequences

- The two live defects are gone, and both are pinned by tests that could not exist before:
  *"a FAILED re-insert leaves the record undone"* and *"two clicks inside one drain both land,
  in order"* — each driving a real `Ring` against a fake OS.
- The Insertion Runner's interface grew (`submitMenu` takes a verb and an identity) while its
  callers shrank; `daemon.zig` loses ~40 lines of homeless policy. The reverse edge widened by
  one slice, and that widening is what let 8193 bytes and a whole buffering function go.
- The `.inserted` event's `inserted` slice borrows the Runner's job buffer and is valid only
  for the duration of the `handle` call — the discipline `coord.InsertionRecord` already
  documents for its own slices, and the ring memcpys under its leaf lock before returning.
- Coordinator tests that assert a record's bytes now pass them on the event rather than
  getting them for free from a buffer the Coordinator filled. That is the honest shape: the
  Coordinator's contract is "stamp what the worker reports", and the separator rule is
  exercised in `insertion_runner.zig` and `insert.zig`, where it lives.
- `docs/recent-insertions-spec.md` (§5.1.3, §5.2.6, §5.2.7, and its `insertion_adapter.zig`
  line references) describes the shipped shape and is left as written; where it and this ADR
  disagree on *where* a step happens, this ADR is current. The user-visible behaviour it
  specifies is unchanged except for the added refusal cue.

## Amendment (2026-07-25, #255) — an Insertion proves its Focused Target

This record moved every cursor job's *resolution* to drain time. It left one thing on the
dictation path resolved nowhere at all: **which app the text goes into.**

The Insertion Runner did read the frontmost app — but *after* the paste, as the best-effort
App Identity hint for the Insertion Record (ADR-0006 §3.3). That is a receipt, not a gate.
Between the Talk Key release and the `⌘V` there is transcription latency and, when Backtrack
is on, the whole ~3 s Rewrite budget. That window is long enough to switch apps deliberately
and long enough for an app to steal activation on its own, and what lands in it is a Final
Transcript — often the most sensitive text the user produces — pasted into an arbitrary field
of an arbitrary app.

The argument is the asymmetry inside our own code. The **Undo Runner** gates hard on exactly
this fact, fail-closed on bundle id *and* display name, because posting into the wrong app is
dangerous (ADR-0008). The **additive** path, which runs on every single Utterance and has the
*longer* window, had no gate at all.

**Decided:**

- **The Coordinator notes the Focused Target on the release edge.** `insertion.noteTarget()`
  is called from `onRelease`, after the abandonment checks — so a hold that cannot insert
  never pays for the read — and before `.awaiting_final`. This is the one cross-process
  `frontmost()` read in the lifecycle that is affordable on the tap's run-loop thread under
  `coordinator.mu`: the machine is mid-Utterance and nothing waits on it, and `audio.stop()`
  on the line above already does strictly more work on that same thread. ADR-0006's rejection
  of a read under the mutex was about `onInserted`, the point where the *next press* is
  waiting; it is not disturbed.
- **The Insertion Runner re-reads and compares at drain time**, immediately before the paste —
  the same beside-the-effect rule this ADR states for everything else. A positive change
  refuses: nothing is pasted, the pasteboard is untouched.
- **It fails open where Undo fails closed.** `undo.evaluate` refuses on a null reading on
  either side, because Backspaces are destructive and irreversible. `insertion_runner
  .targetChange` **inserts** on a null, because refusing on an unreadable frontmost would
  break dictation outright on the first app that does not report cleanly — a far worse outcome
  than the rare mis-target. Only *positive evidence of a change* refuses. This is the single
  deliberate divergence between two otherwise identical predicates, and it is stated at both.
- **A refusal is a new `InsertResult`, not a `.failed`.** Both mean nothing landed; only one
  means something went *wrong*. `.refused` carries the red bloom + shake this ADR already gave
  to "that cursor action did not happen", fired by the Runner beside the refusal — the
  Coordinator adds no second Feedback Surface verb, so the audible error cue stays with genuine
  failures. The Status Item tags the row `[refused]` beside the same red dot `[failed]` gets.
- **A refusal is recoverable, and recorded so that it is.** The Utterance still resolves
  through the `.inserted` edge carrying its bytes, so the Insertion Record is committed and the
  transcript is re-insertable from Recent Insertions into the app the user actually meant.
  Re-insert stays unconditional (spec §5.1): it is user-initiated at a moment when the user has
  just chosen the target, so a stale dictation note must not veto it.
- **The record's App Identity hint becomes the gate's own reading.** The post-paste read is
  gone; the pre-paste one serves both, so the drain still costs one query. The hint is now
  *proven* rather than guessed after the fact — and on a refusal it names the app the Utterance
  was dictated into, never the one that stole focus, which would be a plain lie about text that
  never went there.

**A consequence outside the Insertion path, and a latent bug it exposed.** `newestForUndo`
returned the newest record whatever its outcome, and Undo deletes by *count* — so a record
whose text never reached the cursor would have had its clusters backspaced out of whatever the
user wrote instead. `.refused` makes that reachable under a healthy, fully-granted daemon,
where `.failed` had kept it mostly theoretical (an insert fails on a missing PostEvent grant,
which Undo's own `enabled()` also requires). The `UndoTarget` now carries whether the record
*landed*, and the Undo Runner refuses with `.no_target` when it did not — closing the `.failed`
case as well.

**Not decided here.** Field-level Focused Target capture stays out of scope, as the Undo effort
(#209) ruled: the gate is app-level, so "the user kept typing in the same app" remains the
known, accepted residual — the same limit ADR-0008 documents for Undo.
