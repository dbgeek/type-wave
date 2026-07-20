# ADR 0001 — Fully serialize the Utterance lifecycle

- Status: accepted (2026-07-08); amended (2026-07-09, issue #38; 2026-07-20, issue #144 — see Amendments)
- Supersedes: the press-during-paste overlap grilled for wayfinder #19

## Context

Wayfinder #19 deliberately released the overlap guard (`busy`) the *instant* the
Final Transcript was copied out of the Transcription Session — **before** the ~400 ms
paste tail (clipboard settle + restore, `insert.zig`). The intent was that holding the
Talk Key again during that paste tail would begin the next Utterance rather than being
dropped. That decision forced two subtleties:

1. A guard released *mid-way* through resolving one Utterance, so the read of the
   shared Final Transcript state had to be sequenced against the next `beginUtterance`
   by hand (daemon.zig's `busy` / `hold_active` / `insert_pending` atomics).
2. `hud.hideIfFinal()` — a take-down that had to check "am I still showing *this*
   Utterance's Final Transcript, or did a successor's `.recording` pill already
   repaint?", because a new Utterance could start while the paste was still landing.

When the lifecycle logic was lifted into the **Utterance Coordinator** (candidate 1 of
the 2026-07-08 architecture review), a single synchronous state machine under one mutex,
the overlap became the one piece of state that could not be expressed as a plain phase:
it required releasing the guard partway through the terminal phase.

## Decision

The Coordinator's phase machine is `idle → capturing → awaiting_final → inserting → idle`.
`.inserting` is a **blocking** phase: the Utterance is not resolved — and no new Talk Key
hold is accepted — until the Insertion completes and the worker reports `.inserted`. One
Utterance resolves fully before the next begins.

## Consequences

- **The ~400 ms re-hold window is dropped.** A Talk Key hold landing within the paste
  tail of the previous Utterance is ignored (logged), perceptible only on very rapid
  back-to-back dictation.
- **`hideIfFinal` collapses to a plain `hide()`.** Nothing can repaint the pill during
  `.inserting`, so the "only if still Final" guard is unnecessary.
- **`busy` / `hold_active` / `insert_pending` disappear**, replaced by the single `phase`
  enum under the Coordinator's mutex (`busy` ≡ `phase != .idle`).
- **`.inserting` carries no deadline.** Insertion is bounded (local `usleep`s, no
  network), so a wedge is unlikely; unlike `.awaiting_final` there is no timer catching a
  stuck paste. Revisit if a hang is ever observed.

A future architecture review should not "restore" the #19 overlap without re-reading this
record: the overlap was reconsidered here and traded away on purpose for a single-source-
of-truth state machine.

## Amendment (2026-07-09, issue #38)

`.inserted` is now reported when the Insertion *lands* — the Cmd-V settle — rather than
after the paste mechanism's ~300 ms clipboard-restore tail. The restore is deferred: the
insert worker reports completion first, then drains the restore before it can pick up the
next job (`insertion_adapter.zig`), and `paste` itself drains any pending restore at entry
as a belt-and-braces interleave guard (`insert.zig`).

This narrows the `.inserting` lockout by ~300 ms but is **not** a return of the #19
overlap this ADR traded away:

- No guard is released partway through a phase. `.inserting` still ends at exactly one
  event (`.inserted`), delivered once per Utterance; the phase machine is unchanged.
- No shared state needs hand-sequencing. The deferred restore lives entirely on the
  single insert-worker thread; the next Utterance's paste cannot start until the worker
  has drained it, because the same thread runs both.
- `hideIfFinal` stays collapsed. The pill for Utterance N is taken down at `.inserted`,
  which still precedes anything Utterance N+1 can paint.

What moved is only *where the Insertion is considered complete*: at the text landing,
not at the end of the mechanism's private cleanup.

## Amendment (2026-07-20, issue #144 — Backtrack)

The phase machine gains an optional `.rewriting` phase between `awaiting_final` and
`inserting`: `idle → capturing → awaiting_final → [rewriting →] inserting → idle`.
It is entered only when the Lease pinned Backtrack on with the OpenAI backend at press
(docs/backtrack-spec.md), and it changes nothing this ADR decided:

- `.rewriting` is exactly as blocking as `.inserting` — Talk Key presses are rejected
  (the same `phase != .idle` overlap guard, zero new mechanism), and the phase ends at
  exactly one event (`.rewritten`), delivered once per Utterance.
- One Utterance still resolves fully before the next begins; the rewrite worker is one
  more single-job thread reporting back through a reverse edge, like the insert worker.
- Unlike `.inserting`, the rewrite *does* cross the network; its ~3 s deadline is part
  of the Backtrack spec and lands with the follow-on failure-policy ticket.
