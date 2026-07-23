# Recent Insertions history — locked spec

- Status: locked (2026-07-23; wayfinder map [#182](https://github.com/dbgeek/type-wave/issues/182), tickets [#183](https://github.com/dbgeek/type-wave/issues/183)–[#187](https://github.com/dbgeek/type-wave/issues/187), assembled in [#190](https://github.com/dbgeek/type-wave/issues/190))
- Scope: this is the **spec** a single implementation session picks up without
  reopening any decision. It ships **no code** — the map is plan-only. The
  threading/ownership decision has its own record in
  [ADR-0006](adr/0006-recent-insertions-ring-is-daemon-owned-and-leaf-locked.md).

## What Recent Insertions history is

A **small in-memory ring of the last N Final Transcripts**, surfaced under the
Status Item menu (`src/menu.zig`) with per-entry **Copy** and **Re-insert**
actions. It exists to **recover lost dictations**: an Insertion sometimes lands
in the wrong Focused Target, or is lost when focus shifts mid-Utterance, and
today the text is simply gone. The ring keeps a receipt so the user can copy it
or replay it. **Privacy-conscious by default, entirely offline.**

Domain terms (Utterance, Final Transcript, Insertion, Focused Target, Backtrack,
Rewrite, Settings Snapshot, Status Item, HUD, **Insertion Record**, **App
Identity**, **Recent Insertions View**) are defined in
[`CONTEXT.md`](../CONTEXT.md).

## Charting constraints (fixed before the route)

Locked when the map was charted; they bound every decision below:

- **Plan, don't do** — the map produces this spec plus its supporting glossary
  and ADR; it ships no code.
- **Entirely offline** — no network call is on any path (recording, reveal, copy,
  or re-insert).
- **Privacy-conscious by default** — retained transcript text must not be visible
  at rest in an open menu.
- **The paired Undo last Insertion feature is out of scope** — split into its own
  future map. This spec keeps the recorded-entry shape reusable by that effort but
  charts none of its machinery (notably Accessibility field-level Focused Target
  capture).

---

## 1. The Insertion Record — what one entry contains ([#183](https://github.com/dbgeek/type-wave/issues/183))

One entry in the ring is an **Insertion Record**. Fields:

| Field | Type | What it holds |
|---|---|---|
| `inserted` | `[]const u8` | The **with-space** form — the literal bytes placed at the cursor (post-Rewrite when Backtrack ran, raw otherwise). Re-insert replays it verbatim; its char count is what a future Undo would delete. |
| `raw` | `?[]const u8` | The **trimmed** Final Transcript, present **only when it differs** from `inserted` (i.e. a Rewrite changed it). Absent ⇒ identical to `inserted`. Gives faithful pre-Rewrite recovery when Backtrack mangled a dictation. |
| `timestamp` | `i64` | `nowMs()` at capture — drives newest-first ordering and menu labels. |
| `outcome` | `InsertResult` (`ok` / `degraded` / `failed`) | Full enum, not a bool. Drives the menu's status dot and the high-value "recover a *failed* insertion" case. **Known only at `onInserted`.** |
| `focused_app` | `?AppIdentity` | Best-effort **App Identity** hint (bundle id + display name via `NSWorkspace.frontmostApplication`). Nullable, never load-bearing. |

**Byte forms are deliberate:** `inserted` is what hit the cursor (with its single
trailing space — the Insertion-chaining artifact); `raw` is what you said
(trimmed — the space is not part of the transcript).

**App Identity is app-level only.** It answers "did it land in the wrong app?".
The Accessibility field-level Focused Target capture is **deferred to the future
Undo map** — the cheap app-level hint is kept, the expensive AX field capture is
left out of this effort.

**Reusability constraint:** this record shape is shared with the future Undo map
— both features lean on the last-Insertion record. `inserted`'s char count and
`raw`'s pre-Rewrite recovery are the fields Undo reuses.

---

## 2. Retention & privacy model ([#184](https://github.com/dbgeek/type-wave/issues/184))

Four coupled rules.

### 2.1 Persistence — in-memory only
Never serialized to disk; cleared on daemon quit. Deliberately kept **out of
`feedback.log`** too — a structured, retained, re-openable ring is a categorically
stronger form of retention than a transient log line, so it stays out even though
Partial/Final Transcript text already reaches stderr today
(`session.zig:1078` / `session.zig:1088`). **No cross-restart recovery**; adding
persistence later is a separate, deliberate opt-in effort.

### 2.2 Which Utterances get recorded — every non-empty Final Transcript
Record whenever a non-empty Final Transcript was produced, i.e.
`outcome ∈ {ok, degraded, failed}`.

- **`.failed` is explicitly IN** — a lost / mis-targeted Insertion is the
  feature's primary recovery case; excluding it would omit exactly the scenario
  the ring exists to rescue.
- **Excluded** (no text to recover): empty Final Transcript
  (`coordinator.zig:226`); abandoned Utterances — no Final Transcript within the
  deadline (`coordinator.zig:278`) or backend failure mid-Utterance
  (`coordinator.zig:294`).

The capture design (§4) realizes this rule for free — no extra filter is needed.

### 2.3 Ring size — N = 20, fixed
`N = 20`, a fixed compile-time constant, **not** user-configurable (configurability
is scope creep for a recovery buffer; add later only if asked). Newest-first; the
oldest entry is evicted once the 21st arrives.

### 2.4 Exposure — masked-by-default, explicit reveal, no auto-clear
**Threat:** retained transcript text in an on-demand menu is visible to any
screen-share / screenshot / shoulder-surf while the menu is open (unlike the HUD,
which shows no text — #27).

- **Masked by default.** Menu entries show App Identity + time + a masked /
  char-count placeholder; actual transcript text is shown only on a **deliberate
  reveal** (interaction in §5). An idle open menu leaks nothing.
- **No time-based auto-clear.** The highest-value recovery case is a `.failed`
  Insertion noticed a few minutes late; a retention timer would delete exactly
  that text right when the user reaches for it. Masking bounds exposure without
  sacrificing recovery.

---

## 3. Capture hook, ring ownership & cross-thread sync ([#185](https://github.com/dbgeek/type-wave/issues/185))

> Full rationale and rejected alternatives are recorded in
> [ADR-0006](adr/0006-recent-insertions-ring-is-daemon-owned-and-leaf-locked.md).
> This section is the implementable contract.

### 3.1 Capture point — buffer-then-commit at `onInserted`
A record is committed **once, at `onInserted`** (`coordinator.zig:310`), where
`outcome` is known. The transcript text is buffered in Coordinator-local state
from the `submit` sites until then. This realizes §2.2's retention rule for free:

- **empty** → `onFinal` early-returns (`coordinator.zig:224`), never submits →
  never committed ✓ (excluded)
- **abandoned** (deadline / backend-failure) → never reaches `onInserted` → never
  committed ✓ (excluded)
- **`.failed`** → *does* reach `onInserted` (`r = .failed`,
  `coordinator.zig:317`) → committed with `outcome = .failed` ✓ (recorded — the
  primary recovery case)
- **`.degraded` / `.ok`** → committed ✓

### 3.2 Coordinator-local buffering
- New `pending` / `pending_len` inline buffer (`[8192]u8`, mirroring `raw`) holds
  the with-space text, stashed at each submit site
  (`coordinator.zig:248/259/271`). The Coordinator applies `ensureTrailingSpace`
  (the insertion module's pure helper, `insertion_adapter.zig:53`) when buffering,
  so the stored `inserted` bytes are **byte-identical to what hit the cursor**.
- The record's nullable `raw` **reuses the existing `raw` / `raw_len`** field —
  already the pre-Rewrite raw Final Transcript on the Backtrack detour
  (`coordinator.zig:241`) — selected by the Utterance's `active.?.backtrack` flag
  (`null` for non-Backtrack Utterances).

### 3.3 `focused_app` hint (greenfield — nothing captures app identity today)
Captured **off-mutex on the insertion worker** (`daemon.zig:562`) — the faithful
moment where the text lands — and carried back through the `.inserted` report. A
principled one-field widening of the `.inserted` / `InsertResult` seam: unlike the
text (known to the Coordinator at submit), `focused_app` is *only* observable at
the worker's insertion moment. `onInserted` stamps `focused_app` + `timestamp`
into the record (cheap, under the lock).

Reading `NSWorkspace.frontmostApplication` **inside `onInserted` under
`coordinator.mu` is rejected** — it is a cross-process query and would violate the
seam's "must not block" discipline, stalling the serialized state machine.

### 3.4 Owning type & synchronization contract
- A **standalone, daemon-owned ring**: fixed `[20]`, newest-first, inline string
  buffers, **zero heap / no leak**. Static footprint ≈ 20 × (~8 KB `pending` +
  ~8 KB `raw` + small fields) ≈ **~320 KB**, bounded — consistent with §2.1.
- Wired to the Coordinator as a **write-only seam** —
  `deps.recorder.record(finished_record)` at `onInserted`, contract *"runs under
  `coordinator.mu`; must not block"* (same as `insertion` / `rewrite`). The
  Coordinator stays ignorant of the concrete ring.
- Guarded by a **dedicated `os_unfair_lock`** that is a **leaf lock**: the
  Coordinator holds `coordinator.mu` (outer) and briefly takes `ring.lock` (inner)
  to memcpy; the menu takes `ring.lock` alone; **`ring.lock` never wraps
  `coordinator.mu`** — mirroring the codebase's "`out_mu` never nests with
  `write_mu`" rule (`session.zig:493`). No lock-ordering cycle.
- The menu reads via a **snapshot-copy under `ring.lock`** on open; contention is
  effectively nil.

---

## 4. Menu presentation ([#186](https://github.com/dbgeek/type-wave/issues/186))

**Layout — Variant 1, "Entry ▸ actions".**

- A top-level **`Recent Insertions ▸`** submenu on the Status Item menu, built with
  the `addLocalModel` submenu template (`menu.zig:601`).
- Entries listed **strictly newest-first** (the ring's own order) — **no**
  failed-first sectioning. Chronological order is predictable: "the last thing I
  said is at the top." (Failed entries are already visually marked, so recovery
  does not need re-ordering.)
- **Each entry is itself a submenu** carrying its per-entry actions: **Copy** and
  **Re-insert here** (semantics in §6).
- **Empty ring:** the `Recent Insertions` parent is shown **disabled** reading
  "No recent insertions" — surfacing state over hiding the item, consistent with
  this repo's UX posture.

**Masked entry label (at rest)** — metadata only, never transcript text:

```
● ••••••• · 39 chars · Slack · 2m ago            [failed]
```

- Leading **status dot**: green `ok` · amber `degraded` · red `failed` (red gets
  a soft halo).
- Masked placeholder (`•` run, capped) · **char count** (of `inserted`) · **App
  Identity** display name · relative **time**.
- **`.failed` marker** (hard req from §2.4): a distinct `failed` tag/pill in
  addition to the red dot, so never-inserted entries are unmistakable. `degraded`
  likewise tagged.

**Reveal — ⌥-click the entry row.** Holding **⌥ and clicking** a row toggles *that
single entry's* text inline (masked ↔ shown); nothing is revealed at rest, reveal
is per-entry. Chosen over an explicit "Reveal text" item and over global ⌥-hold.
- _Discoverability note (non-binding):_ ⌥-click is a hidden gesture. Since each
  entry already opens a submenu, the impl session **may** also list a `Reveal text`
  item inside that submenu as the discoverable equivalent, with ⌥-click as the
  shortcut. Does not change the decision.

### 4.1 Pure-split — through `Snapshot` → `derive`, masked descriptors only

The ring reaches the menu **through the pure pipeline**
(`status_item.project` / `derive` → `Presentation`), keeping `menu.zig` a dumb
adapter — **not** a direct read at `menuWillOpen`. This reconciles two locked
constraints:

1. `refreshChrome` value-compares the whole `Snapshot` with `std.meta.eql`
   (`menu.zig:658`), which needs fixed-size, slice-free fields.
2. §2.4 privacy: transcript bytes must not sit in a projected, value-compared
   structure anything can read.

**Both point the same way:** the `Snapshot` carries a fixed `[20]` array of
**masked entry descriptors — the Recent Insertions View — metadata only, no
transcript bytes**:

```
HistoryEntryView = { char_len: u16, app: AppIdentity, timestamp: i64, outcome: InsertResult }
```

- Fixed-size and `eql`-comparable, so `refreshChrome`'s early-out keeps working,
  and **no transcript text ever enters `Snapshot` / `Presentation`** — the pure
  path stays privacy-clean by construction.
- `derive` turns those descriptors into `Presentation.history` (masked labels,
  newest-first order, dot colour, failed/degraded tags). The menu renders
  `Presentation.history` — dumb adapter.
- **Full text (`inserted` / `raw`) is fetched on demand only** at reveal / copy /
  re-insert, read from the daemon-owned ring under its dedicated lock (§3), via a
  new **Host seam** keyed by entry index/id (add `historyText` / `historyAction`
  fptrs to `Host`, `menu.zig:193`).
- **Own refresh path:** the history submenu is (re)populated at `menuWillOpen`
  (`menu.zig:1212`), which already ends with the `last_snapshot = null;
  refreshChrome()` idiom, rather than leaning on the 1 s `chromeTick` (note
  `refreshChrome` early-outs on unchanged snapshots, `menu.zig:660`). Per-entry
  action items dispatch through **one shared selector** (`onHistoryEntry:`,
  registered in `makeTarget` `menu.zig:1241`) with the entry index encoded in the
  item `tag`, mirroring `onModelAction` + `setTag:`.

**Relation to §3:** the **authoritative** ring stays daemon-owned behind its leaf
lock; the Recent Insertions View is a **derived, text-free projection** of it that
rides through `Snapshot` / `derive` for rendering. The Insertion Record (§1, with
text) is unchanged and stays in the ring.

---

## 5. Reveal, Copy & Re-insert — the behaviour contract ([#187](https://github.com/dbgeek/type-wave/issues/187))

Reveal (§4), Copy, and Re-insert all fetch full text on demand via the Host seams
(§4.1), resolving the entry index against §3's authoritative daemon-owned ring
under its leaf lock. The daemon does the work; the menu only dispatches.

### 5.1 Re-insert (`Host.reinsert(index)`)

1. **Routing / concurrency.** Serviced as a **Coordinator-bypassing job on the
   shared insert worker** — serialized against dictation inserts (it cannot
   interleave with a live Utterance's `job` / `pending` state or the clipboard-swap
   dance), but carrying **no Utterance identity**: no overlap guard, no
   release-anchored deadline, no poison abandonment. Minting a synthetic Utterance
   through the Coordinator is **rejected** — that machinery is meaningless for a
   replay and would force a fake `UtteranceId`.
2. **Content — verbatim, never re-Backtrack.** Insert the stored `inserted` bytes
   exactly; no second Rewrite pass. Re-running Backtrack would be a
   non-deterministic OpenAI call needing a backend Lease, could yield text
   *different* from the row the user is looking at, and only works when the pinned
   backend is OpenAI. Verbatim keeps re-insert **fully offline**, faithful to the
   row, and backend-agnostic.
3. **Trailing space.** `inserted` already carries its single trailing space, so a
   re-insert lands **identically** to the original dictation; any
   `ensureTrailingSpace` on the path is an idempotent no-op.
4. **Ring — never recorded.** A re-insert **never writes to the ring**, on success
   *or* failure — it falls out of routing for free (recording happens only at
   `onInserted`, which the bypassing job never reaches). A replay is not a new
   Final Transcript; recording it would create near-duplicate entries.
   **Consequence accepted:** a *failed* re-insert produces no `.failed` record —
   it is silent except for the log / any HUD cue. Correct, because it is not a
   dictation.
5. **Target — unconditional, then-frontmost, no focus capture.** Re-insert
   **defers until the Status Item menu closes** (NSMenu tracking holds key focus
   during its modal loop; the prior app regains key only after dismissal), then
   lands at **whatever Focused Target is frontmost at that moment** — the same
   targeting a live dictation Insertion uses. **No target-changed guard:** the user
   chose the destination by clicking into an app and invoking the menu. The
   record's **App Identity** hint is shown for the user's judgment but is **never
   enforced as a gate**. (This is the opposite of Undo, which must verify the
   target is unchanged before deleting — hence Undo's AX capture, deferred.)

### 5.2 Copy (`Host.copy(index)`)

6. **Content — trimmed `inserted`.** Copy yields the `inserted` text with its
   single trailing space **stripped**: resolved content (post-Rewrite when
   Backtrack ran), matching the menu row. **Not `raw`** — when Backtrack ran, `raw`
   is the *pre-Rewrite, different-content* transcript; copy must give the text the
   user actually sees. Trimming one trailing space needs no extra stored field.
7. **Clipboard — permanent, non-transient, drain-first.** An honest **permanent**
   `NSPasteboard` write: **no** save-and-restore (unlike Insertion). Before writing
   it **drains any pending deferred Insertion restore** (`drainDeferredRestore`,
   `insert.zig:293` — already a no-op when nothing is pending) so a late restore
   cannot silently clobber the copied text, then does a plain `clearContents` +
   `setString`. It must **not** set the `org.nspasteboard.TransientType` /
   `ConcealedType` markers Insertion uses (`insert.zig:276`) — those tell clipboard
   managers to skip the write; a user-initiated Copy should be a **normal, visible**
   entry. Copy runs on the **insert-worker serialization** so it can drain safely
   without racing the worker.

---

## Implementation hand-off notes

- **Insert worker widening (§5).** Both Copy and Re-insert need the insert worker
  to accept a **Coordinator-less job** — a small widening of the worker's job
  source beyond `insertion_adapter.submit`. Keep it serialized with dictation
  inserts.
- **New Host seams (§4.1, §5).** `historyText(index)` / `historyAction`,
  `reinsert(index)`, `copy(index)` on `Host` (`menu.zig:193`); one shared
  `onHistoryEntry:` selector with the index in the item `tag`
  (`makeTarget` `menu.zig:1241`).
- **No new Focused-Target / Accessibility machinery** is introduced. Targeting
  reuses the existing "land at the frontmost cursor" model. AX field-level capture
  stays with the future Undo map.
- **Prototype asset (menu presentation):** interactive mockup and verdict on
  branch `worktree-wf-186-menu-presentation`,
  `prototypes/recent-insertions-menu/` (throwaway — captured, not for merge).

## Out of scope (this effort)

- **Undo last Insertion** — its own future map. Its Focused-Target-capture infra
  (greenfield AX field capture) and modifier-chord trigger belong to that effort.
  This spec keeps the Insertion Record shape reusable by it.
- **Configurable ring size**, **cross-restart persistence**, and **enforcing App
  Identity as a re-insert gate** — all deliberately excluded above.
