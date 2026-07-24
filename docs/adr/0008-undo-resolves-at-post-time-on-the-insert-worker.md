# ADR 0008 — Undo resolves at post time, on the insert worker

- Status: accepted (2026-07-24; candidate 1 of the 2026-07-24 architecture review)
- Supersedes: the trigger-side resolution and commit rationale recorded in
  `src/undo_trigger.zig`'s module doc (#223/#225), and the "dim without deleting" edge it
  declared accepted

## Context

The Undo path (`⌃⌘⌫` → delete the newest Insertion) was assembled across four tickets
(#221–#226) and ended up split across two threads and nine files:

- **Run-loop thread** (the Talk Key tap's callback): `tap.isRecoveryChordPress` →
  `daemon.onRecoveryChord` → `undo_trigger.trigger`, which resolved the newest Insertion
  Record from the ring, submitted its bytes and stored App Identity to the insert worker's
  undo slot, and **flagged the record `undone`**.
- **Insert worker**: `insertion_adapter.runUndo`, which counted grapheme clusters, took a
  fresh `frontmost()` read, evaluated the app-level focus gate (`undo_gate.evaluate`), and
  posted the Backspaces — or refused.

The split had a real argument behind it, stated in `undo_trigger.zig`: the gate **cannot**
move up to the run-loop thread. Its contract is a fresh `frontmost()` read taken immediately
before posting, so a value read on the trigger thread would go stale in the trigger→worker
gap; and `frontmost()` is a cross-process NSWorkspace query, which would stall the tap
callback — the OS disables a tap whose callback runs slow.

That argument is sound, and this ADR does not disturb it. What it does not justify is
everything *else* staying up there with it. Three consequences followed from the split:

1. **A refusal left a lie.** `markUndone` fired on the trigger thread before the worker's
   gate ran, so an app-changed or focus-null refusal left the record rendering dimmed in the
   Recent Insertions submenu with nothing deleted — and, because the record was flagged,
   single-shot (#225) then refused the retry too. `undo_trigger.zig:56` documented this as
   "an accepted edge of the app-level model".
2. **A second press clobbered the first.** `submitUndo` overwrote `undo_job` /
   `undo_job_len` / `undo_expected_app` in place. Its single-producer contract
   ("the caller must not submit while an undo job is still pending") was prose that nothing
   enforced, and `trigger` never checked. A press landing during a drain — a ~300 ms paste,
   or a ~200 ms deletion of a long Insertion — silently discarded the earlier job while
   leaving its record flagged.
3. **The chord was ungated.** `onRecoveryChord` had no `paused` or grant check at all, so a
   system-wide destructive chord fired while the daemon was explicitly paused from the menu.
   The Talk Key press path goes through the Supervisor's capture-enable gate; this one went
   through nothing.

None of the three was reachable from a test. Each lived at a *join* between two modules that
were themselves well covered: `undo_gate.evaluate` had 6 pure tests, `undo_trigger.trigger`
had 9 against a `FakeSink`, `insertion_adapter.runUndo` had 10 against `FakeDeps` — and no
test spanned two of them, because the halves ran on different threads behind different fakes
and `daemon.zig` (where they met) carries no test blocks.

## Decision

**One module, `src/undo.zig` — the Undo Runner — owns the whole sequence, on the insert
worker.** The gate could not move up, so everything else moves down to meet it:

```
gate on pause/grant → resolve newest record → count clusters → fresh frontmost read
                    → focus gate → post Backspaces → flag undone → cue
```

The run-loop callback does exactly one thing: `undo.request()`, a single atomic increment.
No ring read, no memcpy, no cross-process query — strictly less work in the tap callback
than before.

Also decided, and load-bearing for the shape:

- **Resolution happens at post time**, beside the focus read, under one rule rather than
  two. This is a behavioural change: an Insertion landing between the press and the drain
  retargets the Undo to that newer record. It is the consistent reading of the gate's own
  "fresh, immediately before posting" discipline — the Runner deletes what is newest at the
  moment it proves the app is unchanged.
- **The `undone` flag flips only after `deleteChars` has posted.** No refusal can leave a
  dimmed record for a deletion that never happened, and a refused Undo stays retryable.
- **`enabled()` is `!paused AND postEventGranted`** — Undo's own prerequisites, nothing
  more. Deliberately *not* the Configuration Phase's `configured`, which bundles an OpenAI
  API key or a verified Model Installation, neither of which deleting already-landed text
  requires; and deliberately *not* the Supervisor's `capture_enabled`, which would refuse an
  Undo because a Transcription Backend dropped. The PostEvent grant is in because without it
  `deleteChars` posts nothing while the confirm cue claims a deletion happened.
- **A saturating press counter, not a pending flag.** One press yields one verdict and one
  cue, in press order. Two presses inside a drain window produce a deletion and then an
  already-undone refusal, rather than one deletion and one silence. It saturates at 3: the
  single-shot model refuses everything after the first anyway, so a deeper queue would only
  render more red shakes.
- **The Ring stays daemon-owned and is held concretely**, not behind the seam. ADR-0006
  governs it; the Runner only drives it. It is heap-free and test-constructible, so a fake
  would mean re-implementing eviction and stamp-keying rather than exercising them.
- **`Deps` is 5 methods** — `enabled`, `focusedApp`, `deleteChars`, `undoConfirmed`,
  `undoRefused` — everything the OS owns and nothing else. `grapheme.graphemeCount` is
  called directly; it already runs against real CoreFoundation under `zig build test`.
- **`assertDeps` is invoked by `Undo(Deps)` itself.** The existing `local_backend.assertHelper`
  and `session.assertTransport` are never called by the generic types they protect, which is
  why `WebsocketTransport` — the production adapter — is asserted nowhere. This seam does not
  repeat that.
- **Serialization stays the insert worker's.** `insertion_adapter.workerLoop` drains the
  Runner **last**, after the dictation / replay / copy slots: an Insertion is time-sensitive
  and its clipboard-swap dance must never interleave with posted Backspaces, whereas an Undo
  waiting one more tick is imperceptible.

`undo_trigger.zig` and `undo_gate.zig` are deleted. `insertion_adapter`'s `Deps` narrows from
11 methods to 8.

## Alternatives rejected

- **Moving the focus gate up to the trigger.** The reason the split existed. A gate evaluated
  on the run-loop thread goes stale before the post, and its cross-process read stalls a
  callback the OS will disable for being slow. Unchanged by this ADR.
- **Moving only the commit point** (leaving resolution and `submitUndo` on the trigger thread
  and dropping just `markUndone` down to the worker). Closes the dim-without-delete edge with
  the smallest diff, but leaves the nine-file bounce path, the unenforced single-producer
  contract, and the missing pause gate exactly as they were.
- **A pure `decide(facts) -> Actions` decider** in the Supervisor / Configuration Phase /
  Segmenter idiom (ADR-0005). The frontmost read has to happen *between* the resolve and the
  post, so a pure decider needs two rounds with the adapter holding the intermediate record —
  which puts the ordering that is the actual defect surface back in the untested half. The
  work here is effect-heavy (3 of 5 `Deps` methods are effects), so the seam earns its keep,
  which is the same test ADR-0005 applied and answered the other way for the Supervisor.
- **Reusing the Supervisor's `capture_enabled` gate** for one gate across both entry points.
  It couples Undo to Transcription Backend availability: a dropped OpenAI connection would
  start refusing undos of text that already landed.
- **A boolean pending flag.** The clobber problem dissolves either way once resolution moves
  to run time (there is no payload left to overwrite), but a flag coalesces presses inside a
  drain window into one cue, leaving a press with no visible response at all.

## Consequences

- **The joins become the test surface.** 22 tests drive the whole sequence in `undo.zig`
  against a real `Ring` and a `FakeDeps`, including three cases no test could previously
  reach: a gate refusal leaves the record *not* undone; a refused Undo is retryable after the
  user switches back; a paused daemon refuses before reading the ring or the frontmost app.
  `insertion_adapter` keeps two — the drain priority that is genuinely its own.
- **One press, one verdict, one cue.** Including the pause refusal, which is surfaced through
  ADR-0007's red bloom + shake rather than swallowed.
- **The tap callback shrinks** from a ring read plus a bounded memcpy to one atomic increment.
- **Two modules and 25 tests are deleted**, replaced by one module and 24. `undo_gate`'s six
  were near-duplicates of the adapter's gate tests; `RefuseReason` — whose own doc conceded
  that two of its four variants were "never returned by `evaluate`" — is now one enum in the
  one module that returns every one of them, plus `paused`.
- **The retarget window is real but narrow.** An Insertion completing between a press and its
  drain shifts which record the Undo deletes. It requires dictation to resolve inside a
  worker tick of the chord, and the outcome — deleting the genuinely newest Insertion — is
  the one the Recent Insertions submenu would show as newest at that instant.

A future review should not "restore" trigger-time resolution without re-reading this record:
resolving on the run-loop thread was the original design and was traded away on purpose,
because splitting the sequence across two threads is what put the `undone` flag, the job
handoff, and the gate in three places that no test could observe together.
