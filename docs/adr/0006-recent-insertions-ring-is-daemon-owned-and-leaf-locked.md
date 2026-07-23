# ADR 0006 — The Recent Insertions ring is a daemon-owned, leaf-locked buffer captured at `onInserted`

- Status: accepted (2026-07-23; wayfinder map [#182](https://github.com/dbgeek/type-wave/issues/182), decision ticket [#185](https://github.com/dbgeek/type-wave/issues/185))

## Context

The Recent Insertions history feature (spec: `docs/recent-insertions-spec.md`)
keeps the last N=20 Final Transcripts in an in-memory ring, surfaced under the
Status Item menu with Copy / Re-insert. That ring is written on **every**
dictation and read by the **main-thread** menu on open — a genuinely cross-thread
structure. Three questions had to be settled before it could be built, each with
live alternatives already present in this codebase:

1. **Where is a record captured?** The transcript text is known at the `submit`
   sites (`coordinator.zig:248/259/271`), but the `outcome`
   (`ok` / `degraded` / `failed`) — which the feature must record, including
   `.failed` — is known only at `onInserted` (`coordinator.zig:310/317`). Capture
   at submit, at `onInserted`, or provisionally-then-patched?
2. **Who owns the ring, and how is it synchronized?** The Coordinator writes it
   under `coordinator.mu`; the menu reads it on the main thread. Options ranged
   from an inverted lock-free snapshot swap (as `config.Store` does) to a plain
   memcpy-under-lock ring (as the session outbound ring does).
3. **Where is the App Identity hint read?** `NSWorkspace.frontmostApplication` is
   a cross-process query; reading it at the wrong point blocks the serialized state
   machine.

## Decision

### Capture at `onInserted`, buffer-then-commit
A record is committed **once, at `onInserted`**, where `outcome` is known. The
with-space `inserted` text is buffered in Coordinator-local state (a new `pending`
inline buffer) from the `submit` sites until then; `raw` reuses the existing
`raw` / `raw_len` buffer. This point **realizes the feature's retention rule for
free**: empty Final Transcripts (early-return at `coordinator.zig:224`) and
abandoned Utterances (deadline / mid-Utterance backend failure) never reach
`onInserted` and are thus never recorded, while `.failed` insertions *do* reach it
and are recorded — exactly the recording set the feature wants, with no separate
filter.

### A standalone, daemon-owned, heap-free ring behind a write-only seam
The ring is a **standalone type owned by the daemon**: a fixed `[20]` of Insertion
Records with inline string buffers, **zero heap allocation, no leak**. The
Coordinator writes it through a **write-only seam** — `deps.recorder.record(...)`
at `onInserted`, contract *"runs under `coordinator.mu`; must not block"* — the
same shape as the existing `insertion` / `rewrite` seams. The Coordinator stays
ignorant of the concrete ring.

### A dedicated leaf `os_unfair_lock`, never nested outside `coordinator.mu`
The ring is guarded by its **own `os_unfair_lock`, used strictly as a leaf lock**.
The Coordinator holds `coordinator.mu` (outer) and briefly takes `ring.lock`
(inner) to memcpy the finished record in; the menu takes `ring.lock` **alone** to
snapshot-copy the ring out on menu open. **`ring.lock` never wraps
`coordinator.mu`.** This mirrors the codebase's explicit "`out_mu` never nests with
`write_mu`" rule (`session.zig:493`) — there is no lock-ordering cycle and the menu
read never contends the state machine.

### App Identity captured off-mutex on the insertion worker
`focused_app` is read **off-mutex on the insertion worker** (`daemon.zig:562`), the
moment the text lands, and carried back through a one-field widening of the
`.inserted` / `InsertResult` report. `onInserted` then stamps `focused_app` +
`timestamp` into the record under the lock (cheap).

## Alternatives rejected

- **Recording at `submit`, or provisional-then-patch.** Submit-time capture cannot
  carry the `outcome` (stamped at `onInserted`), and a provisional-then-patch scheme
  would let the menu observe outcome-less entries and leave dangling provisionals on
  abandon races. Buffer-then-commit avoids both.
- **The inverted Settings-Snapshot swap** (giving the menu lock-free reads by
  load-and-leak, as `config.Store` does at `config.zig:20`). That is safe for config
  because config changes are *rare*; records occur on *every* dictation, so inverting
  it means either leaking a full snapshot per Utterance (unbounded, in an explicitly
  in-memory-only feature) or adding epoch / hazard-pointer reclamation —
  over-engineering a 20-entry buffer the menu reads only on open.
- **Reading `NSWorkspace.frontmostApplication` inside `onInserted` under
  `coordinator.mu`.** It is a cross-process query and would violate the seam's "must
  not block" discipline, stalling the serialized Utterance state machine.
- **Minting a synthetic Utterance through the Coordinator for Re-insert / Copy** (a
  related decision from [#187](https://github.com/dbgeek/type-wave/issues/187)). Those
  actions run as Coordinator-bypassing jobs on the shared insert worker instead — a
  replay carries no Utterance identity, and routing it through the Coordinator would
  force a fake `UtteranceId` and pointless overlap/deadline/poison machinery.

## Consequences

- **Bounded, heap-free footprint** ≈ 20 × (~8 KB `pending` + ~8 KB `raw` + small
  fields) ≈ ~320 KB, consistent with the feature's in-memory-only stance
  ([#184](https://github.com/dbgeek/type-wave/issues/184)).
- **The write path is the established idiom here:** `os_unfair_lock` (Coordinator,
  rewrite adapter, HUD) plus a memcpy-under-lock ring (the session outbound ring,
  `session.zig:488-500`). No new concurrency primitive is introduced.
- **The menu never contends the state machine.** The leaf lock is held only for two
  memcpys (write-in, snapshot-out); the outer `coordinator.mu` is never taken by the
  menu.
- **A text-free projection is layered on top for rendering.** Per
  [#186](https://github.com/dbgeek/type-wave/issues/186), a masked **Recent
  Insertions View** (metadata only — `HistoryEntryView`) rides through the pure
  `Snapshot` / `derive` path so `refreshChrome`'s `std.meta.eql` early-out keeps
  working and no transcript text enters `Snapshot` / `Presentation`; full text is
  fetched from **this** authoritative ring on demand under this leaf lock. This ADR
  governs the authoritative ring; the projection is a derived view of it, not a
  second store.

A future review should not "upgrade" this ring to the inverted lock-free swap
without re-reading this record: that idiom was considered here and traded away on
purpose, because for a per-dictation write it costs an unbounded leak or a
reclamation scheme that a 20-entry, read-on-open buffer does not justify.
