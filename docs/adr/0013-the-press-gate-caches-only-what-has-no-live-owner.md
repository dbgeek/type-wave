# ADR 0013 — The press gate caches only what has no live owner

- Status: accepted (2026-07-29)
- Refines: ADR-0005 (the Supervisor stays a pure decider — it simply decides less)

## Context

The Talk Key press gate consulted `capture_enabled`, an atomic published once per ~3 s
Supervisor tick as `configured AND backend_available AND !paused`. Two of those three terms
have a live owner that moves them between ticks, and the gate returned **silently** — no log,
no cue — so a wrong cached value presented as a Talk Key that simply did nothing.

Three defects came out of the one violation:

1. `Router.available()` delegated to a `Selection` predicate that meant *ready **and**
   unleased*. A lease is held for the whole of every Utterance, so availability was false
   throughout, and any tick landing inside that window latched the gate false. The Utterance
   then resolved and nothing re-evaluated: **the Talk Key stayed dead for up to 3 s after
   every Utterance long enough to straddle a tick.** Neither backend resource is actually
   un-ready during dictation — a session's readiness is its connection state, and the helper's
   is a warm flag with busy tracked separately — so the lease term was the sole cause.

2. `paused` was in the gate *and* read live one line above it. Nothing republished the gate on
   the pause toggle, so **every un-pause left the Talk Key dead for up to 3 s** — guaranteed,
   not probabilistic, because a pause always outlasts a tick.

3. The same availability read fed the Configuration Phase's backend fact, so the status line
   read *reconnecting* through every ordinary dictation.

Measured on 191 consecutive dictation cycles from a real log: after an Utterance short enough
to miss a tick, 20 % of next presses landed within a second; after one long enough to
guarantee hitting a tick, 2 % did. Across 345 Utterances the Coordinator's own refusal lines
fired 0 and 6 times — the drops users felt left no trace at all, which only the silent gate
can do.

Both smuggled terms were already owned elsewhere, by owners that handle them *better*: lease
contention by the Utterance Coordinator's overlap guard, which logs; backend warmth by its
lease acquisition, which refuses, logs, and fires the error cue. The gate's stale copies
silently pre-empted both.

## Decision

**A cached fact never gates what a live owner already decides.**

The press gate is the conjunction of three terms, and each is read from the owner that can act
on it:

- **`configured`** — cached per tick, because it is the only term with no live owner: a
  Configuration Phase composite over TCC probes, tap liveness, and the selected backend's
  durable prerequisite. The Supervisor's capture-enable action reduces to exactly this, with
  no conjunction, and is renamed to say so. The Supervisor remains its single publisher —
  moving the decision into the daemon would put it where no test can reach it.
- **pause** — read live at the tap, where it already was. The cached copy is deleted.
- **backend readiness** — not consulted by the gate at all. `Facts`' backend-availability field
  is deleted; it had exactly one consumer.

`Selection`'s readiness predicate now answers one question — *has preparation published a live
resource for the selected Backend?* The staleness probe, which genuinely needs a drained route,
states that term itself; the same-backend teardown already did, and sheds the redundant one.
`Router.available()` inherits the corrected meaning, which retires defect 3 as a side effect
rather than as a separate change.

## Consequences

- **The whole class of stall is gone, not shortened.** Republishing the flag on resolve and on
  un-pause would have left the same shape with a shorter fuse — and a race between the
  republish and the press. There is now nothing in the cached value that can be stale-wrong.
- **A refused press is audible.** A press while the backend is cold — a reconnect, or before
  the first connect — now reaches the Coordinator, which logs and fires the error cue, where
  before it vanished. This is the point, not a cost: a Talk Key that does nothing and says
  nothing is the defect this ADR exists about, and the Feedback Surface's rule is already that
  the error cue is always audible.
- **Behaviour during an Utterance is unchanged, and now visible.** A second press still does
  nothing, but it reaches the overlap guard and is logged.
- **One less fact gathered per tick**, and the Supervisor decides one term where it decided
  three.
- **The regression is pinned where it can be seen.** Nothing previously asserted availability
  under a live lease, which is exactly why this shipped. That assertion now exists, in a file
  with test blocks — unlike the daemon, where the gate itself lives.

## Alternatives considered

- **Republish `capture_enabled` at each write site** (on Utterance resolve, on the pause
  toggle). Rejected: it is the pattern that produced all three defects. A hand-synced cache
  needs a republish at every future write site, and the first one anybody forgets is the next
  silent dead Talk Key.
- **Keep the backend term, fixed.** Rejected: it leaves two owners of *is the backend ready to
  take an Utterance?* — a 3 s-stale cached copy and a live one — which can still disagree, and
  when they do the silent copy wins. That is the bug's exact shape with a shorter fuse.
- **Have the press callback read availability live** instead of caching it. Rejected: on the
  local path that read touches the filesystem, and the callback runs on the tap's run loop
  where a slow callback makes the OS disable the tap. The cache exists for this reason.
- **Add the warmth predicate beside the existing readiness one**, keeping both names.
  Rejected: one predicate quietly answering two questions is what caused this. A second name
  leaves the ambiguity alive one identifier away.
- **A third spelling at the Router tier.** Rejected: three representations of one fact, coupled
  only by convention, is the failure mode CONTEXT.md already warns about under SettingsView.
- **Shorten the Supervisor tick.** Rejected: it treats a design error as a latency problem, and
  ADR-0005 chose the polled loop deliberately. This fix removes the need for a faster tick.
