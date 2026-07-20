# Backtrack — locked spec

- Status: locked (2026-07-20; wayfinder map [#136](https://github.com/dbgeek/type-wave/issues/136), tickets #137–#141, assembled in #142)
- Scope: this is the **spec** a fresh implementation effort picks up without reopening
  any decision. Implementation and deployment are a separate effort (see
  [Branching & handoff](#branching--handoff)).

## What Backtrack is

Backtrack is an **opt-in, post-transcription rewrite pass** that runs between an
Utterance's Final Transcript and its Insertion. In one OpenAI call it:

1. **Applies spoken self-corrections** — "Book a meeting at 20:00 no 18:00" →
   "Book a meeting at 18:00"; "today I saw person Johan… no his name was Kalle" →
   "Today I saw person Kalle".
2. **Removes disfluencies** — "um", "uh", "mmm", "aaaa".

Both happen in the *same* pass; there is one toggle and no sub-toggles (see
[Cleanup coupling](#cleanup-coupling-139)). When Backtrack does not apply — Local
backend, offline, or a failed rewrite — the **raw Final Transcript is inserted
unchanged**: dictation never breaks.

Domain terms (Utterance, Final Transcript, Insertion, Backend, Settings Snapshot,
Status Item, HUD) are defined in [`CONTEXT.md`](../CONTEXT.md).

## Charting constraints (fixed before the route)

These were locked when the map was charted and constrain every decision below:

- **Opt-in**, default off, surfaced as a setting.
- **OpenAI only** for the rewrite model — reuse the existing OpenAI API key; no
  second credential. On the Local backend or offline, Backtrack silently does not
  apply.
- **Dictation never breaks**: any time Backtrack cannot run, the raw Final
  Transcript is inserted and the UI makes the non-application visible.
- Enabling Backtrack must **visibly disclose** that transcript text is sent to
  OpenAI (leaves the machine) and that it will not work offline.

## Model, API & prompt ([#137](https://github.com/dbgeek/type-wave/issues/137), [#141](https://github.com/dbgeek/type-wave/issues/141))

**Locked configuration:**

| Parameter | Value |
|---|---|
| Model | `gpt-5.4-mini` |
| API surface | Responses API (non-streaming) |
| Reasoning | `reasoning: { effort: "none" }` |
| Temperature | `0` |
| Service tier | standard (`priority` is the available 2× tail-latency escape hatch if needed) |
| Auth | Bearer key via `config.loadApiKey` (the existing OpenAI key) |
| Prompt | `prompt.txt` v6 — see below |

**Why this config:**

- `gpt-5.4-mini` over `gpt-5.4-nano`: measured latency is identical (~0.64 s TTFT
  p50, ~175–182 t/s in non-reasoning mode), but mini adds instruction-following
  headroom for mixed sv/en utterances and is the tier eligible for the `priority`
  service tier. Cost either way is ~$0.01–0.04 per 100 utterances — negligible.
- **`reasoning: "none"` is the dominant latency knob** — default reasoning takes
  TTFT from 0.64 s to ~4 s. It is honored on the Responses API (not Chat
  Completions), one reason for Responses; OpenAI also recommends Responses for new
  projects (better cache utilization).
- **`temperature: 0` is load-bearing** — it is accepted by `gpt-5.4-mini` with
  `reasoning: "none"` on Responses, and it turned run-to-run wobble on
  correction-scope cases into byte-identical determinism across three consecutive
  runs of the 27-case suite.
- Streaming buys nothing for a one-shot insert; the Realtime API adds a second
  socket for no gain; prompt caching needs ≥1024 prompt tokens (our short fixed
  prompt won't trigger it and wouldn't benefit at this size).
- **No reliable one-pass path.** The transcription `prompt` field is unsupported on
  `gpt-realtime-whisper` and is only a vocabulary-biasing hint elsewhere — a
  separate rewrite call is the only reliable mechanism.

**Prompt.** The locked prompt is `prompt.txt` **v6** on the throwaway branch
[`prototype/backtrack-prompt`](https://github.com/dbgeek/type-wave/tree/prototype/backtrack-prompt/prototypes/backtrack-prompt).
It performs corrections **and** filler removal in one shot. Validation: **27/27**
on the expanded suite (canonical corrections, fillers, multiple corrections per
utterance, multi-sentence, decimals, Swedish/mixed sv-en, "eller nej"), with
**zero false triggers** across ~190 calls on legitimate "no"/"nej", questions, and
"not/inte…utan" contrasts. The implementation effort should copy v6 as the starting
prompt and keep the prototype suite as a regression guard.

## Pipeline placement & failure policy ([#138](https://github.com/dbgeek/type-wave/issues/138))

**A new Rewrite seam, driven by the Coordinator.** The Coordinator gains a
`.rewriting` phase between `awaiting_final` and `inserting`:

- `onFinal` (`src/coordinator.zig:177`) — the single backend-neutral chokepoint
  every Final Transcript passes through — submits the transcript to a new async
  **Rewrite adapter** mirroring `InsertionAdapter`. Copy the borrowed text at
  submit (it is only valid during the `handle` call).
- A **worker thread** makes the OpenAI HTTP call off-mutex — a new
  `std.http.Client` use, since the realtime websocket is not reusable (pattern
  exists in `src/model_store.zig`; Bearer key via `config.loadApiKey`).
- A reverse-edge **`.rewritten` event** then calls `insertion.submit`.
- Policy (opt-in check, timeout, fallback) lives in the **Coordinator**, reached
  through the seam and exercised by fed events, not hardware.

Rejected placements: Backend Router ownership (breaks its charter — it owns no HTTP
machinery); burying the rewrite inside the InsertionAdapter (hides policy inside a
mechanism adapter).

**Timeout — ~3 s hard**, armed at rewrite-submit using the `DeadlineAdapter`
pattern (`src/daemon.zig:339`). This **amends the original 2.5 s** from #138: the
prototype (#141) measured a fat, case-independent latency tail — ~10% of warm calls
exceed 2.5 s, with rare 9.8 s / 14.7 s outliers — so ~3 s is the spec budget and the
fallback covers the rest. Independent of the release-anchored 15 s deadline (which
is cancelled when the Final Transcript arrives).

**Fallback — never lose dictation, and flag the downgrade.** On timeout, API error,
or rate limit: insert the **raw** Final Transcript, show the degraded-insertion
flash (see [UX](#settings--ux-140)), and log one line. The error cue sound is **not**
played — it means "nothing was inserted", which would be false here. Expect this
degraded path on roughly **1 in 10–20 utterances** given the latency tail.

**Concurrency & gating:**

- **`.rewriting` rejects Talk Key presses**, exactly like `.inserting` (ADR-0001
  fully-serialized model — zero new mechanism). The ~3 s timeout bounds the extra
  wait between rapid-fire Utterances.
- **Gating is pinned at press.** Backtrack enablement is read from the Settings
  Snapshot at Talk Key press and pinned alongside the backend Lease, so a
  mid-Utterance settings flip cannot half-apply. The rewrite fires only when the
  pinned backend is OpenAI **and** Backtrack was enabled at press.
- **Multi-Segment interaction is moot** — Backtrack applies only on OpenAI, which
  never segments; the Coordinator always sees one whole Final Transcript.
- **Empty/failed transcripts** abandon in `onFinal` before the rewrite — unchanged.
- **HUD during the wait**: the existing green `.processing` state already spans
  release → resolution, so the rewrite wait needs **no new HUD state** — the dots
  simply cover up to ~3 s more.

## Cleanup coupling ([#139](https://github.com/dbgeek/type-wave/issues/139))

**Combined and intrinsic.** Disfluency cleanup rides the *same* OpenAI call as
self-correction — one prompt does both. There is **no separate local filler
filter**, no offline cleanup path, and **no independent sub-toggle**: Backtrack is a
single setting that applies corrections and filler removal together.

Rationale: Whisper large-v3-turbo (the local Model Installation) already suppresses
most disfluencies, so a local filter would mostly re-solve a solved problem on the
one backend where it'd apply; a *safe* local filter essentially requires the LLM
anyway; cost is negligible; and the "wants corrections but insists on keeping
fillers" user set is near-empty. Splitting the toggle later is a cheap additive
change if a real need appears.

Consequence: on Local/offline the whole pass doesn't apply (no cleanup **and** no
corrections → raw insert); on rewrite failure the raw transcript keeps any fillers.
Both are acceptable and consistent with #138.

## Settings & UX ([#140](https://github.com/dbgeek/type-wave/issues/140))

Four coordinated pieces.

### 1. Setting & config key

- **`config.Settings.backtrack: bool = false`** — opt-in, parallels the existing
  `overlay: bool`. Add the standard way: field in `config.zig`, `diffSettings`,
  `serializeSettings`, and `packaging/config.example.zon` docs.
- **Menu item**: a checkmark toggle (idiom of the Overlay HUD item; handler pattern
  like `onOverlay`) labelled **"Backtrack (rewrite self-corrections)"** — the
  parenthetical because "Backtrack" alone doesn't convey the behaviour on first
  sight.
- **Placement**: directly **beneath the Backend radio group** (co-located with the
  OpenAI/Local choice it depends on), *not* by the Overlay HUD item.
- Lands in the Settings Snapshot like any other field; read at Talk Key press and
  pinned with the Lease (per #138).

### 2. Cloud disclosure

A **persistent disabled disclosure line** beneath the toggle — the app's
established "subtitle" idiom (disabled second item, like the existing
privacy/network lines). **Always visible, on and off. No modal / first-enable
confirmation** — the always-visible line already informs the choice at the consent
moment (the menu is open when you decide), and an NSAlert would be out of character
with every other silent live-apply toggle.

Wording — two short, neutral lines (line 1 mirrors the existing "audio stays on
your Mac" cue):

> `Uses OpenAI cloud — transcript text leaves your Mac`
> `Needs internet; unavailable on the Local backend`

### 3. "Enabled but not applying" indicator

Scoped to the **Local-backend steady state only**. When Local is selected and
Backtrack is on, the toggle stays **visible, checked, and enabled** (so you can
pre-enable it for the switch to OpenAI) and **disclosure line 2 is swapped** for a
sharper disabled status line:

> `Not applying — needs the OpenAI backend`

This diverges from the existing `openai_only`-groups-are-*hidden* pattern on
purpose — hiding would erase an opted-in preference. The **OpenAI-but-offline**
case is *not* handled here: it is transient and not Backtrack-specific (OpenAI
transcription itself needs the network), so it is left to the existing
**reconnecting** headline plus the per-utterance degraded flash. ("Offline" is not
a global flag — it is per-backend readiness: `ready_offline` / `reconnecting`.)

### 4. Degraded-insertion flash

On a failed rewrite (raw transcript inserted, **no error sound**): the processing
dots pulse **`systemOrangeColor` once, ~300 ms**, then fade out — played *instead
of* the plain hide on the degraded path. Amber over a monochrome motion-only signal
because a gray blink is too easily missed against the normal fade-out, and this is a
rare, soundless event that must be noticed; `systemOrangeColor` is a semantic system
color, so it stays light/dark adaptive.

**This carves an exception to ADR-0002** (HUD is bare marks, no accent color) —
captured as [ADR-0004](adr/0004-backtrack-degraded-insertion-amber-accent.md).

Implementation hooks for the follow-on effort: extend `coord.InsertResult` with a
`.degraded` variant (`coordinator.zig:39`, produced in `insertion_adapter.zig`),
handle it in `onInserted` (`coordinator.zig:227`) via a new `surface.Surface` verb,
and add a one-shot pulse primitive to the HUD Sequencer/render split (`hud.zig`).

## Per-utterance size cap — no explicit cap

**Decision (resolved at spec assembly): Backtrack sends the whole Final Transcript
with no size cap.** This resolves the map's last "Not yet specified" patch. It
follows directly from decisions already made:

- **Cost is negligible** at any realistic utterance length (#137).
- The **~3 s timeout + raw-insert fallback already bounds the worst case**: a
  pathologically long utterance that is slow to rewrite simply exceeds the timeout
  and falls back to the raw Final Transcript — the same safe degradation as any
  other failure. No separate cap is needed to protect latency or correctness.
- A hard cap would add a second, redundant degradation threshold and a magic number
  to tune, for no benefit the timeout doesn't already provide.

If a real need for a cap ever appears (e.g. an OpenAI request-size limit surfaces in
practice), adding one is a cheap additive change under the same raw-insert fallback.

## Summary of amendments this spec locks in

- **Timeout: 2.5 s → ~3 s** (from #141's measured latency tail; supersedes #138's
  2.5 s).
- **ADR-0002 exception**: a single semantic accent (`systemOrangeColor`) is
  permitted for the degraded-insertion flash — [ADR-0004](adr/0004-backtrack-degraded-insertion-amber-accent.md).
- **No per-utterance size cap** (resolved here from #137's negligible-cost finding
  plus the existing timeout/fallback bound).

## Branching & handoff

Implementation is a **separate effort**, not part of this map (map #136 is
planning-only). Per the map's branching directive (user, 2026-07-20):

- All Backtrack features (Rewrite seam, failure policy, cleanup, settings +
  disclosure UX) are built together on **one shared feature branch** (e.g.
  `feat/backtrack`), branched once off `main`.
- The branch lands via **PR** — `main` is PR-gated by branch protection. Stacked
  PRs off that branch are fine as long as nothing hits `main` until the feature is
  whole.

Nothing in this spec is left open: every design decision is made and every fog
patch resolved. A fresh effort can start implementing against this document
directly.
