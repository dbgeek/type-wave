# ADR 0005 — The Supervisor is a pure decider, not a Machine(Deps)

- Status: accepted (2026-07-22; candidate 1 of the 2026-07-22 architecture review)

## Context

The daemon's self-heal loop (`daemon.zig` `supervisorLoop`) polls OS and adapter facts
~every 3 s and, each tick, decides four things that used to live inline in the loop —
reachable only by running the real daemon against live TCC and the Talk Key tap:

1. Re-arm a dead tap (`scheduleRecreate`, #127/#129).
2. Fire a PostEvent probe (`postTaggedProbe`, #129) — gated on
   `grants.reached(.post_event) and tap.isEnabled() and !postEventGranted`.
3. Reclaim a superseded Model Installation, gated on no Utterance in flight.
4. The **capture-enable gate** — the Talk Key press gate:
   `configured and backend_available and !paused`.

The other decisions in the loop were already extracted pure machines: the Configuration
Phase (`configuration_phase.zig`, driving `announce_ready` / `report_missing` /
`connect_session` / `prepare_local`), the grant sequence (`grant_sequence.zig`), and the
Backend Router (`backend_router.zig`). The four decisions above were the residual —
untested because they were tangled with the `usleep`/`g_quit` loop and live subsystems.

Two idioms were on the table, both already used in this codebase:

- **`Machine(Deps)`** — the Coordinator and Backend Router pattern: the machine gathers
  facts and runs effects *through an injected seam*, tested by scripting a `FakeDeps` and
  asserting recorded effects. The self-heal work is effect- and probe-heavy, so this
  idiom would fit the surface area and would shrink the daemon loop to
  `while (!quit) { sleep; supervisor.tick(); }`.
- **Pure `tick(facts) -> actions`** — the Configuration Phase / grant sequence / Segmenter
  pattern: the machine is a pure function; the daemon marshals a `Facts` struct in and
  runs an `Actions` struct out.

## Decision

The Supervisor is a **pure `tick(facts, outcome) -> Actions`** function (`src/supervisor.zig`).
The daemon keeps the impure fact-gathering (`supervisorFacts`, `gatherOutcome`,
`configurationFacts`, `inputMonitoringFact`, `postEventFact`) and runs the effects; the
Supervisor owns only the decisions.

Also decided, and load-bearing for the shape:

- **The Backend Router `wants()` callback is left intact.** The router still drives
  `configuration_phase.tick` mid-tick, between its reconcile and prepare phases, so the
  Configuration Phase sees post-teardown facts. The Supervisor *consumes* the resulting
  `Outcome` as a plain input rather than owning it. Untying that callback (two-phasing the
  router into `reconcile` then `prepare`) is a separate, larger refactor with its own
  blast radius on the router's tests, and was explicitly out of scope.
- **The `Actions` bundle is the complete end-of-tick effect set**, including the
  `announce_ready` / `report_missing` fields forwarded verbatim from the Configuration
  Phase outcome. The Supervisor does not decide those; it assembles them so the daemon
  runs one bundle. This trades a little interface honesty for one execution point.
- **The self-heal nudges moved to end-of-tick.** `rearm_tap` / `post_probe` fire after the
  router tick rather than before it. This is sound because both are asynchronous:
  `scheduleRecreate` posts to the tap's run-loop thread and `postTaggedProbe` posts a
  synthetic event, so neither result is observable within the emitting tick — the daemon
  reads them next tick via `tap.isEnabled()` / the PostEvent latch either way.

## Consequences

- **The two real formulas become unit-tested** from fed facts: the `capture_enabled`
  truth table (the Talk Key press gate) and the `post_probe` three-term gate, plus
  `rearm_tap`, `reclaim_model_storage`, and the announce/report forwarding.
- **The fact-gathering stays untested daemon glue.** Mapping OS probes
  (`tap.isEnabled()`, `listenGranted()`, `postEventGranted()`, `available()`) into `Facts`
  is inherently impure and unreachable by a unit test; the pure-tick choice accepts this
  rather than hiding it behind a `FakeDeps`. This is the cost we chose over a Deps seam.
- **One benign behavioural delta.** The PostEvent probe can now fire one tick (~3 s)
  earlier, because `grants.reached(.post_event)` is read *after* the grant-sequence tick
  advances it rather than before. In a 3 s background poll this is negligible and
  arguably more correct.
- **The daemon loop stays the fact-gatherer and effect-runner.** Unlike a `Machine(Deps)`,
  this extraction does not shrink the loop to a one-liner; it concentrates only the
  decisions. That was the deliberate trade — the residual decisions were too thin to
  justify a new Deps seam and its `FakeDeps`, and keeping the effects in the loop keeps
  the async-nudge ordering (the reason the collapse to one call is safe) visible.

A future architecture review should not "upgrade" the Supervisor to a `Machine(Deps)`
without re-reading this record: the Deps idiom was considered here and traded away on
purpose, because for this module the seam would out-weigh the behaviour behind it.

## Amendment (2026-07-25, #272) — the Supervisor also ends a hold the tap stopped narrating

The four decisions above are all *nudges*: re-arm, probe, reclaim, and a gate a callback
consults. The Capture watchdog is the first Supervisor decision whose action drives the
Utterance Coordinator directly — `end_lost_hold` feeds it the `.release` the tap never
delivered — so it is worth saying why it belongs here rather than in the tap adapter or the
Coordinator.

`.capturing` had exactly one exit: `onRelease`, reachable only from the Talk Key release edge
arriving through the tap. `onBackendFailed` mid-hold poisons and waits for that edge; the
deadline is armed only at release. So anything that ate the edge left the microphone live and
the machine wedged — every later press dropped by the overlap guard, dictation dead until
restart. Two routes did eat it: a Talk Key changed from the Status Item mid-hold (the release
filter compared against the *live* setting, which no longer named the held key), and a tap
death mid-hold (edges fired while disabled are never delivered, and a re-enable that fails
delivers nothing ever again).

The first route is closed where it was opened — the release is matched against the **open
hold** (`tap.Hold`), not the Talk Key setting — and needs no watchdog. The second cannot be:
no fix inside the tap can deliver an edge the OS withheld. That leaves a second, independent
route to the same terminal edge, and this loop already has the two properties it needs — a
~3 s cadence, and a fact-gathering pass that may make cross-process OS reads. The evidence is
`CGEventSourceKeyState` on the held key: HID-level, and specifically *not* anything the tap
observed, since a tap that stopped reporting is the failure being detected.

- **The decision stays two facts and an AND** (`hold_open and !talk_key_down`), so the whole
  rule is a fed-facts test like the capture-enable gate beside it. Duration is deliberately
  not a term: a long dictation hold is legitimate, and "the key is up" is direct evidence
  that this hold is not one.
- **The action is the ordinary `.release`**, so a watchdog-ended hold commits or is abandoned
  by exactly the usual rules — no second lifecycle path, nothing for the Coordinator to know
  about its provenance. `Hold`'s compare-and-swap makes the watchdog and a real release
  racing resolve to one ending, not two.
- **It runs synchronously, unlike `rearm_tap` / `post_probe`.** Those are async nudges read
  next tick; this one calls `coordinator.handle` on the supervisor thread, which is what
  `handle` is built for (four other threads already trampoline into it).

The generalization worth carrying forward: **a state entered on an edge needs an exit that
does not depend on the counterpart edge arriving.** The counterpart is the normal exit and
stays the fast one; the watchdog is the proof that ground truth, polled, can reach the same
exit when the edge never comes.
