# ADR 0010 — The Grant Observer owns the grant facts

- Status: accepted (2026-07-24; candidate 3 of the 2026-07-24 architecture review)

## Context

`grant_sequence.zig` was pure and well tested (6 tests over the serialized cold-start request
ladder, #130). Everything *around* it was stranded in `daemon.zig`, which has no test blocks:

- the three OS probes (`cap.microphoneGranted`, `tapmod.Tap.listenGranted`,
  `insertmod.postEventGranted`) and the three request calls;
- the two facts that are **compositions** rather than single reads —
  `inputMonitoringFact` (`tap.isEnabled() or listenGranted()`, because the preflight goes
  stale in-process after a live grant, #127) and `postEventFact` (the observe latch ORed with
  a preflight that can lie `false` for the process lifetime, #129);
- the `post_event_observed` latch itself, written by the tap callback;
- the four narration tables and the print-header-once flag;
- `tickGrantSequence`, which wired all of it together.

So the module's headline promise — *a grant landing minutes after its step timed out still
gets its `[N/3] granted` line* — was tested at the `Action` level and unreachable end to end.

The sharp edge is `postEventFact`. Since the Undo effort (#223/#224, ADR-0008), that predicate
is what `RealUndoDeps.enabled` gates on before posting a burst of destructive Backspaces. A
predicate authorizing data loss was composed in the one file with no tests.

**This overlaps ADR-0005**, whose decision clause reads: *"The daemon keeps the impure
fact-gathering (`supervisorFacts`, `gatherOutcome`, `configurationFacts`, `inputMonitoringFact`,
`postEventFact`) and runs the effects; the Supervisor owns only the decisions."* Two of the
five named functions are the ones above. ADR-0005 predates the Undo effort: when it was
written (2026-07-22), `postEventFact` fed status and a self-heal probe, not a deletion.

## Decision

**The grant facts belong to the Grant Observer; the Supervisor's facts stay the daemon's.**

`grant_sequence.zig` becomes `grants.zig` and grows a second half in the shape `undo.zig` and
`session.zig` already use — a pure decider plus the machine that feeds it the OS:

- `Sequence` is **unchanged**, with its 6 tests, and stays the sole owner of *when to ask*.
- `Observer(Probes)` owns the six TCC calls behind a seam (`micGranted`, `listenGranted`,
  `tapEnabled`, `postEventGranted`, `request`, `nowMs`), both composed facts, the
  attempt-then-observe latch, the header-once flag, and the tick loop.
- `assertProbes` is invoked **by the generic itself**, so a production adapter can never skip
  the check.
- The four narration tables become `pub fn` beside the policy, table-tested. The Observer
  composes and logs them; `feedback.log` is *not* seamed, consistent with every other module
  in this codebase.
- The daemon keeps `RealGrantProbes` (the only stateful probe is the live Talk Key tap) and
  reads facts back as `grants.granted(.post_event)` / `grants.reached(.post_event)`.

### The ADR-0005 boundary

ADR-0005 governs the **Supervisor**: it stays a pure `tick(facts, outcome) -> Actions`, the
daemon still assembles `supervisorFacts` and still runs the effects, and the async
rearm/probe nudges stay visible in the self-heal loop. That reasoning is untouched — it was an
argument about keeping *nudges* legible, and was never an argument about where a gate on data
loss should live.

What changes is narrower: `inputMonitoringFact` and `postEventFact` were never really the
Supervisor's facts. They are the *grant sequence's own inputs* and its authorization output,
consumed by four readers (the sequence, the Configuration Phase, the Supervisor, the Undo
Runner). They move to the module that owns the concept. `supervisorFacts` still reads three
facts the daemon gathers itself (`tap_enabled`, `no_utterance_in_flight`, `backend_available`,
`paused`) and now reads two from the Observer instead of from two free functions beside it.

ADR-0005 remains **accepted**; this ADR states the boundary so a future review does not read
the move as a violation of it.

## Consequences

- `RealUndoDeps.enabled` is now a tested predicate: *"the PostEvent fact is what gates a
  destructive Undo"* drives the latch and the preflight independently against fed values.
- Both composed facts are pinned by tests naming the OS lie each exists to survive (#127's
  stale preflight, #129's lying-false preflight), rather than by a comment.
- The request ladder — order, one-in-flight, the 60 s timeout advance, the late-landing grant
  — is now exercised through the Observer with a fed clock, not only at the `Action` level.
- ~120 lines and three fields leave `daemon.zig`; the grant narration is no longer split from
  the machine that emits it.
- The `Probes` seam has two adapters (`RealGrantProbes`, `FakeProbes`), so it is a real seam
  and not a hypothetical one.
