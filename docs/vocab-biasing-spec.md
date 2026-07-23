# Custom vocabulary / phrase biasing — locked spec

- Status: locked (2026-07-23; wayfinder map [#161](https://github.com/dbgeek/type-wave/issues/161),
  tickets [#162](https://github.com/dbgeek/type-wave/issues/162)–[#168](https://github.com/dbgeek/type-wave/issues/168),
  assembled in [#169](https://github.com/dbgeek/type-wave/issues/169))
- Scope: this is the **spec** a fresh implementation effort picks up without
  reopening any decision. Implementation and deployment are a separate effort
  (see [Branching & handoff](#branching--handoff)). The map is planning-only —
  no code shipped by it.

## What vocabulary biasing is

Vocabulary biasing is an **opt-in, user-curated list of terms/phrases** — names,
jargon, product words like `type-wave`, `whisper.cpp`, `Bjorn` — that nudges the
speech recognizer to spell them the way you mean. The list is a single flat,
shared, menu-editable set of strings; there are no per-language lists, no weights,
no pronunciation hints (all ruled out of scope).

The biasing **effect is local-Whisper-only**. The OpenAI backend cannot bias its
default transcription model (`gpt-realtime-whisper`) and a model switch is ruled
out (see [OpenAI backend](#4-openai-backend--inert-with-signal-167)), so on OpenAI
the feature is **inert with a menu signal**: the list is still editable and stored,
but it changes nothing until you switch to the Local backend. When the list is
empty — the default — biasing is a **pure no-op** on both backends, byte-identical
to today's behaviour: dictation never changes surface unless you opt in.

Domain terms (Utterance, Segment, Segment Transcript, Final Transcript, Talk Key,
Backend, Lease, Settings Snapshot, Whisper Helper, Status Item) are defined in
[`CONTEXT.md`](../CONTEXT.md).

## Charting constraints (fixed before the route)

- **Single shared flat list.** Per-language lists and weighted/pronunciation
  entries are out of scope.
- **Local-Whisper-only effect.** OpenAI is specified as inert-with-signal, not
  wired ([#167](https://github.com/dbgeek/type-wave/issues/167)).
- **Menu-editable behind the Settings Snapshot seam**, honoring the app's
  menu-bar-only, no-preferences-window posture.
- **Empty = zero regression.** Opt-in; the default (empty) touches nothing.

### Premise correction — the plumbing did *not* already exist

The originating idea claimed "the plumbing already exists on both backends." That
is **inaccurate**; only the *seams* exist, and neither backend wires a prompt
today. The two research tickets and a plumbing survey established:

- **OpenAI**: the transcription-session JSON (`src/session.zig:210`) carries only
  `model`/`language`/`delay` — no `prompt`/`instructions`. Prompt support is
  model-dependent; the default `gpt-realtime-whisper` **cannot** accept one, and
  the prompt-capable `gpt-4o(-mini)-transcribe` loses live Partial Transcripts.
- **Whisper**: `whisper_full_params.initial_prompt` is never set
  (`src/whisper_bridge.cpp:75`), the C ABI (`whisper_bridge.h:19`) has no prompt
  arg, the IPC `Transcribe` frame (`src/whisper_ipc.zig:28`) carries no prompt
  string, and **no Settings→helper channel exists for any free-form string** (only
  the 1-byte `language` enum). The whole thread must be built (see
  [Whisper backend](#5-whisper-backend-wiring-168)).

## Research foundations ([#162](https://github.com/dbgeek/type-wave/issues/162), [#163](https://github.com/dbgeek/type-wave/issues/163))

Two facts ground every budget and wiring decision below:

- **whisper.cpp `initial_prompt`** is a *soft* KV-cache prior, capped at
  **~223 BPE tokens** (448/2). Overflow silently drops the **head** of the prompt,
  so the highest-value terms must survive: keep the total comfortably under the cap
  and frame as a compact comma-separated glossary. `no_context` / `single_segment`
  do **not** disable it.
- **OpenAI transcription prompt** exists only on `gpt-4o(-mini)-transcribe`
  (field `session.audio.input.transcription.prompt`, and those models drop `delay`
  and the live Partial stream). The GA default `gpt-realtime-whisper` returns, in
  OpenAI's words, *"Prompt is not supported… in GA Realtime sessions."* Biasing
  OpenAI is therefore impossible without a model switch, which is rejected.

## 1. Config schema & data model ([#164](https://github.com/dbgeek/type-wave/issues/164))

### Field & type

```zig
vocabulary: []const []const u8 = &.{},
```

On the `Settings` struct (`config.zig:49`), parsed straight from `config.zon` as
`.vocabulary = .{ "type-wave", "Bjorn", "whisper.cpp" }`. Default `&.{}` = "no
biasing," mirroring how `language = ""` is the omission signal.

### Structural caps — coarse, tokenizer-free

- **Per item: 100 chars.**
- **Whole list: 128 items.**

These are pathology guards for a hand- or menu-edited file, deliberately
**generous** — larger than Whisper's usable token budget so they don't starve the
(unlimited) OpenAI path. The real per-backend **token-budget truncation** happens
at construction time (§2), not here.

### Degradation — clamp at load, per-field, non-destructive

In `loadSettingsOnly`, after parse:

- Item > 100 chars → **dropped** (not truncated — a chopped term biases toward a
  broken fragment, worse than absent).
- Beyond 128 items → dropped (overflow tail).
- Blank / whitespace-only items (`""`, `"  "`) → dropped.
- **No dedup** at this layer.

A *type* mismatch (e.g. `.vocabulary = 5`) still falls the whole file back to
defaults via the existing `zonValid` / `std.zon` all-or-nothing path — unchanged.

### In-place array patch — single-line, quote-aware (build it)

`findZonField` / `patchZonField` (`config.zig:340` / `:388`) do **not** handle
arrays today: for a non-quoted value they scan to the first `,` or `//`, so an
array literal's inner comma cuts the span and corrupts the file. Fix:

- When a value opens with `.{`, scan to the matching `}` on that line while
  tracking `"…"` so string-internal commas don't terminate the span.
- The menu **always serializes `vocabulary` on one line**
  (`.vocabulary = .{ "a", "b" },`). A multi-line hand-formatted array returns
  `null` → **full re-serialize fallback** (same as today's "value on the next line"
  case at `config.zig:356`). Comments are preserved on the common single-line path.
- `patchZonField`'s absent-field insert path already writes
  `    .vocabulary = <value>,` on one line, so it works unchanged.

### Three-place landing (or a path drifts)

- **`Settings` struct (`config.zig:49`)** — add the field.
- **`serializeSettings` (`config.zig:410`)** — **switch from the fixed
  `[4096]u8` stack buffer to an allocating build**. A max list (128 × 100 ≈ 12.8 KB)
  overflows 4096 and makes `bufPrint` return `error.NoSpaceLeft`, nulling the whole
  serialize. Accumulate header + fields + the vocabulary array (item loop) via an
  `ArrayList`/`Writer`. Add a header-comment line documenting the field. Write empty
  explicitly as `.vocabulary = .{},`.
- **Debug print (`daemon.zig:1085`)** — **count only**: `vocabulary=<N terms>`, so
  the startup log line stays bounded.

### Empty representation

`serializeSettings` writes it explicitly as `.vocabulary = .{},` (mirrors
`language = ""`; keeps the feature discoverable in the generated file). An absent
line still parses to the empty `&.{}` default, so hand-deleting it is fine. Note
this is distinct from §2's "omit the field from the *prompt* when empty."

## 2. Prompt construction & Settings-Snapshot flow ([#165](https://github.com/dbgeek/type-wave/issues/165))

> **Amended by [#167](https://github.com/dbgeek/type-wave/issues/167):** #165
> originally specified an *asymmetric* flow where OpenAI baked the vocabulary into
> `session.update` and cycled it via `session_shaped`. With OpenAI ruled
> inert (§4), that half is **cancelled**. The flow below is the corrected, final
> single-backend picture. See [Amendments](#amendments-this-spec-locks-in).

### Read-and-pin flow — read-at-use, Lease-pinned

The bias string is read at **Talk-Key press** and **pinned with the backend Lease**
(exactly like `backtrack`), then applied to every Segment's `submit()` for that
Utterance (`local_backend.zig:390`). Read-at-use — no session cycle, no persistent
session; the warm Whisper Helper is stateless per Segment. OpenAI reads nothing (§4).

### Coherence = per-Utterance atomicity

Within a single Utterance, exactly **one** vocabulary applies end-to-end; an edit
takes effect **no sooner than the next Utterance**. This is guaranteed by
press-pinning — every Segment of the Utterance reads the Lease's pinned list.
Explicitly **rejected**: reading the snapshot live per-`submit()`, which could bias
Segment 3 differently from Segments 1–2 of the same Utterance — segments
concatenate into one Final Transcript (`appendAssembledLocked`), so mixed
vocabularies within one Utterance are incoherent. This is byte-for-byte the rule
Backtrack already follows.

### Construction — single shared bare comma-separated glossary

One pure function: `list → "term1, term2, term3"`. **User list order preserved**
(the data model is flat with no weights, so we cannot reorder by importance). No
instructional wrapper. Built inside `local_backend.begin` via a shared,
independently-testable helper **`vocab.buildPrompt(allocator, list)`** — single-homed
and reusable if OpenAI is ever wired.

### Truncation — self-truncate, drop-tail / keep-head, whole-item

- Truncate **ourselves** at construction time to a per-backend budget — never rely
  on the backend's invisible internal truncation.
- **Drop-tail / keep-head**: keep the first items that fit, drop later ones, at
  **whole-item boundaries** (never split a term). Documented user convention:
  **most important terms first.**
- Budget via a simple char→token estimate (no BPE tokenizer in the daemon).

### Making keep-head safe on Whisper — conservative estimate

Whisper *itself* silently drops the **head** if what we send overflows its
~223-BPE ceiling (#162) — which would kill our most-important (head) terms. Fix:
size the Whisper budget **conservatively** so Whisper never truncates further.
Over-count tokens: assume **~3 chars/token**, target **~180 real tokens**, margin
below 223. The constructed string then always fits Whisper intact, so keep-head is
safe. **All numbers are tunable by the build session.** (OpenAI's generous
~1000-token ceiling from #165 is now moot — OpenAI is not wired.)

### Empty list — pure no-op

An empty list ⟺ an empty constructed string (blanks are clamped at load and
keep-head always preserves ≥1 item, so there is no partial-empty edge). Whisper
leaves `whisper_full_params.initial_prompt` **null/unset** — current behaviour.
Vocabulary is thus pure opt-in; the default (empty) has zero regression surface.

## 3. Menu-bar editing ([#166](https://github.com/dbgeek/type-wave/issues/166))

> **Amended by [#167](https://github.com/dbgeek/type-wave/issues/167):** Save
> commits with **`session_shaped = false`** (no `markSessionDirty`) — a vocabulary
> change cycles no session — and the menu item is **backend-aware** (§4). The
> mockup asset (four candidate interactions) is on
> [#166](https://github.com/dbgeek/type-wave/issues/166#issuecomment).

### The interaction — one "Edit Vocabulary…" dialog

An `NSAlert` with a **multi-line accessory** (`NSTextView` inside an `NSScrollView`,
fixed size), **one term per line**, pre-filled with the current loaded list.
**Save** parses and commits; **Cancel** is a no-op. This is a modest step up from
the app's existing one-accessory `NSAlert` recipe (`onSetApiKey`, `menu.zig:917`)
— a multi-line `NSTextView` instead of a single-line field — but stays inside the
modal-alert idiom and needs **no** net-new `NSWindow`, `NSTableView`, sheet, or
runtime view-controller class.

Rejected alternatives (all four mocked and reacted to): *hand-edit config.zon*
(exposes raw ZON, redundant with "Open config file"); *submenu + add/remove*
(tedious for bulk paste — a glossary is naturally pasted in bulk); *dedicated
`NSTableView` window* (largest net-new surface, against the minimal-chrome posture).

### Menu item — reflects live state, backend-aware

A single item built once at startup; only its title/visibility is driven per
`refreshChrome` tick (`status_item.derive` → `Presentation`, `menu.zig:570`).
`Presentation` gains **`vocabulary_count: usize`** plus the over-budget flag (§6),
and the render reads the active backend (already tracked for the `openai_only`
groups — a rendering-time check, not new state):

- Active backend **`.local`**: `Vocabulary (N terms)…` / `Vocabulary (off)`
- Active backend **`.openai`**: `Vocabulary (N terms) — local only` /
  `Vocabulary (off) — local only`

Placed in the bottom settings cluster, **just above "Open config file"**
(`menu.zig:455`) — both are "manage your setup" actions.

### Live-edit flow through the single-writer swap

On **Save**, entirely on the main thread (the menu is the sole Settings-Snapshot
writer):

1. Read the `NSTextView` string.
2. Split on newlines → trim each line → drop blank lines.
3. Apply the §1 clamp: drop items > 100 chars; keep at most 128 items; no dedup.
4. Build the `vocabulary: []const []const u8` value.
5. `commitSettings(next, "vocabulary", <serialized array>, session_shaped = false)`
   (`menu.zig:681`).

`commitSettings` does the whole publish sequence: copies the live snapshot,
`store.swap(heap)` publishes the new immutable snapshot (`config.zig:247`),
`config.writeField` persists to `~/.config/type-wave/config.zon` (the **single-line
quote-aware array patch** from §1; multi-line arrays fall back to full
re-serialize). Because vocabulary is **`session_shaped = false`** (§4), there is
**no `markSessionDirty`** — Whisper picks the new list up at the **next Talk-Key
press**, pinned with the Lease. **Cancel** performs no swap and no write.

### Empty / first-run state

- **Menu item:** `Vocabulary (off)` (backend-aware suffix as above).
- **Dialog:** opens with an **empty field** and a placeholder hint ("One term per
  line"). First-run is identical to empty — no separate onboarding.
- The field is pre-filled from the **loaded (already clamped)** list, so any items
  dropped by the load-time clamp are **visibly absent** the next time the dialog
  opens — the app's quiet "surface by round-trip" idiom.

### Save validation — clamp + inline note

Save **always succeeds** (never blocks) and clamps exactly per §1. When the clamp
**dropped anything**, tell the user the count: after a Save that dropped `N` items,
present a brief **follow-up informational `NSAlert`** — *"Dropped N item(s) over
the limit (100 chars/item, 128 items max)."* — reusing the `confirmModelAction`
alert recipe (`menu.zig:840`). The committed list is the clamped one. (Build-time
alternative left open: re-present the editor pre-filled with the clamped text and an
`informativeText` note. The count message is the requirement; the presentation is
the build session's call.)

### Over-budget — soft, non-blocking hint

A large-but-structurally-valid list can still exceed the Whisper **token** budget.
Per §2 this is graceful degradation, not an error, so the signal is advisory and
**never blocks Save**:

- A small **budget-estimation projection** — a pure function estimating token count
  from the vocabulary array using §2's conservative heuristic (~3 chars/token;
  Whisper target ~180 tokens, margin below the ~223 cap) — lives alongside
  `status_item.derive` and feeds an `over_budget` flag (or a tri-state near/over) on
  `Presentation`.
- **Primary surface:** a **disabled hint line inside the dialog**
  (`informativeText`) when the estimate is near/over budget, e.g. *"Long list — may
  be truncated for local Whisper (~N tokens)."*
- **Optional secondary surface:** a Status-Item line via `Presentation`, deferred to
  the build as an add-on; the dialog hint is the committed requirement.

Two distinct treatments, together closing the map's "cap-exceeded / validation UX"
fog: **structural** caps → clamp + count note; **token-budget** overrun → soft hint.

## 4. OpenAI backend — inert with signal ([#167](https://github.com/dbgeek/type-wave/issues/167))

**Vocabulary biasing is local-Whisper-only. The OpenAI backend gets no session
wiring — the shared config field stays but is inert, and the menu says so.**

In-band ASR biasing on the default `gpt-realtime-whisper` is impossible (§Research
foundations), and switching to `gpt-4o-mini-transcribe` was **explicitly ruled out**
by the maintainer (unwilling to trade the streaming partials / `delay` knob).

### Do **not** build the OpenAI wiring

The steps #167 originally listed are **cancelled**:

- `TranscriptionParams` (`session.zig:179`) gains **no** `prompt` field.
- **Nothing** is injected at `session.zig:210` — `formatSessionUpdate` is unchanged.
- `Daemon.getParams` (`daemon.zig:885`) maps **no** vocabulary.
- OpenAI **never** emits a `prompt` key — for any list, empty or not.

### `diffSettings` classification — read-at-use, not session_shaped

Vocabulary is **not** `session_shaped`. It mirrors `backtrack`: a change sets only
`d.any = true` (so the snapshot swap + `config.zon` write + menu re-render happen)
and cycles **no** warm session. Add the branch next to `backtrack` at
`config.zig:283`:

```zig
if (!vocabularyEql(a.vocabulary, b.vocabulary)) d.any = true; // read-at-use at press (Lease-pinned) — never session-shaped
```

This **supersedes** #165/#166's "reuse `session_shaped`" — that call assumed
OpenAI baked vocabulary into `session.update`. With no backend cycling a session on
a vocabulary change, `session_shaped` would spuriously force an idle OpenAI
reconnect for a setting OpenAI doesn't read.

### Menu signal

The backend-aware suffix (§3): `— local only` on `.openai`, no suffix on `.local`.
No save-time dialog, no blocking, no auto-anything. The item stays **editable in
both backends** — curate the list while on OpenAI and it takes effect the moment you
switch to Local.

## 5. Whisper backend wiring ([#168](https://github.com/dbgeek/type-wave/issues/168))

This backend carries the **entire** biasing implementation. None of it exists today.

### Frame encoding — extend `Transcribe`, don't add a `Kind`

The prompt rides the existing `Transcribe` frame as per-Segment data bundled with
the PCM, so the helper stays stateless. New **v2** payload layout:

```
id(u64, 8) · language(u8, 1) · prompt_len(u16, 2) · prompt(N, UTF-8) · pcm_len(u32, 4) · pcm
```

All 7 former reserved bytes are consumed (2 become `prompt_len`, the rest give way
to the variable prompt region) — **no reserved bytes survive**. `u16` comfortably
covers the §1-clamped worst case (128 × ~100 chars ≈ 13 KB < 65535). The prompt is
re-sent on every Segment `submit` (~540 chars typical — negligible).

### Version bump / compat — lockstep clean cutover

Bump `ipc.version` 1→2 in the one shared `whisper_ipc.zig`; both binaries compile
it. **No negotiation, no drain-and-relaunch** — there is no live cross-version pipe:
a daemon only ever talks to a helper child it spawned from the current on-disk
binary (`~/.local/libexec/type-wave/type-wave-whisper`), and killing the daemon
kills the child. The drift backstop is the existing `error.UnsupportedVersion`
rejection in `decode`/`readFd` (rejects before interpreting any bytes) plus the
crash → fail-active → backoff → relaunch ladder. **Document:** a botched *partial*
upgrade (new daemon + stale helper binary, or vice-versa) surfaces as a **transient
helper-startup failure on the Status Item** — expected and acceptable, not a bug to
prevent.

### Threading — pin the raw array on the Lease, build in `begin`

- Pin the **raw vocabulary array** `[]const []const u8` onto the `Lease` at
  `acquire`, from a new `deps.vocabulary()` — a zero-copy slice into the immutable,
  leak-by-design Settings Snapshot, mirroring how `language` is a slice today.
  Classification per §4: read-at-use, `d.any = true` only, **not** `session_shaped`.
- Widen the `begin` Commands vtable (`transcription_backend.zig:73`) from
  `(ctx, id, language)` to `(ctx, id, language, vocabulary)`; `Lease.begin()` passes
  `self.vocabulary`. OpenAI's `begin` **ignores** the extra arg (inert, §4).
- Construct the bare comma-glossary string **inside `local_backend.begin`** via the
  shared pure `vocab.buildPrompt(allocator, list)` (§2). Allocate + own it for the
  Utterance, re-send on each Segment `submit`, free it in
  `resetUtteranceStateLocked`.
- **Empty list → empty string → `prompt_len` 0 → helper leaves `initial_prompt`
  null** = the pure no-op.

### C ABI — NUL-terminated `const char * prompt`

```c
int tw_whisper_transcribe(
    tw_whisper_runtime * runtime,
    uint8_t language,
    const char * prompt,          // NEW — next to language
    const float * samples,
    size_t sample_count,
    const char ** text,
    size_t * text_len);
```

Zig `WhisperRuntime.transcribe` builds the glossary as a sentinel-terminated
`[:0]u8`; `parameters(runtime, language_name, prompt)` sets
`params.initial_prompt = (prompt && prompt[0]) ? prompt : nullptr`. **Zero C++ heap
on the inference path** — the borrowed pointer lives across the synchronous
`whisper_full`. `nullptr` / empty ⇒ no biasing.

### Application model + wire validation

- **Same glossary biases every Segment identically.** Because `no_context = true`,
  the prompt is the **only** prior each Segment sees — there is deliberately **no
  rolling cross-Segment context**. A build session must **not** add prior-Segment
  carryover (it would fight ADR-0003 and blow the ~223-token budget). No other
  `parameters()` field changes (`no_context` / `single_segment` / `n_threads` /
  greedy untouched).
- **Validation:** in `decode`, the prompt gets the same treatment as `final.text` —
  length-consistency check + `utf8ValidateSlice` (reject `InvalidUtf8`).
  **`prompt_len == 0` is legal** (unlike PCM, which rejects zero length). **No
  tighter prompt-length ceiling** beyond the existing `max_payload_len` (2 MB) — the
  §1 load-time clamp is the single size authority. The reserved-byte zero-check is
  *replaced* by the prompt field.

### Seam impact

The **Helper seam** (`reserveUtterance` / `submit` / `requestCancel` / `cancel` +
`final` / `failed`) grows the prompt arg on `submit`; the `FakeHelper` and the
`local_backend.assertHelper` contract carry it too, so the adapter's off-subprocess
tests exercise the prompt path without a real child.

## Amendments this spec locks in

- **#167 supersedes #165 & #166 on classification.** Vocabulary is **not**
  `session_shaped`; it is a read-at-use, Lease-pinned field mirroring `backtrack`
  (`d.any = true` only). Menu Save commits `session_shaped = false` (no
  `markSessionDirty`). The OpenAI "asymmetric flow" half of #165 is cancelled.
- **OpenAI is inert-with-signal**, not wired — the biasing *effect* is
  local-Whisper-only. The shared config field and menu editing remain; only the
  effect is gated to the Local backend, marked `— local only` in the menu.
- **Whisper budget is conservative** (~3 chars/token, ~180-token target, margin
  below ~223) so the shared glossary always fits Whisper intact and keep-head never
  bites. All budget/cap numbers are tunable by the build session.

## Deferred — downstream fog (not part of this spec)

- **Vocabulary ↔ Backtrack interaction.** Backtrack's rewrite is a separate OpenAI
  `/v1/responses` call with its own prompt (`openai_rewrite.zig:31`). Whether the
  vocabulary should *also* seed that rewrite prompt is a legitimate downstream
  question left open on the map — it is **not** a blocker for this local-Whisper
  biasing spec and is intentionally out of this document. Revisit as its own effort.

Explicitly ruled **out of scope** by the map (never graduate here): per-language
vocabulary lists; pronunciation hints / weighted terms; in-band OpenAI ASR biasing
(impossible on `gpt-realtime-whisper`); output-side OpenAI correction via a
per-utterance `/v1/responses` pass.

## Branching & handoff

Implementation is a **separate effort**, not part of this map (#161 is
planning-only). Per the repo's convention, `main` is PR-gated by branch protection:

- Build the feature on one shared feature branch (e.g. `feat/vocab-biasing`),
  branched off `main`, landing via **PR**. Stacked PRs off that branch are fine as
  long as nothing hits `main` until the feature is whole.
- Natural build order: config schema + clamp (§1) and the `vocab.buildPrompt`
  helper (§2) first (pure, testable off-hardware); then the Whisper IPC/C-ABI wiring
  (§5) against the `FakeHelper` seam; then the menu editing (§3) and the
  backend-aware signal (§4).

Nothing in this spec is left open on the route to the destination: every forking
decision is made. A fresh effort can start implementing against this document
directly.
