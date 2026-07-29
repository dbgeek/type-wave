# OpenAI keywords biasing — locked spec

- Status: locked (2026-07-29; wayfinder map [#310](https://github.com/dbgeek/type-wave/issues/310),
  tickets [#311](https://github.com/dbgeek/type-wave/issues/311)–[#319](https://github.com/dbgeek/type-wave/issues/319)
  and [#323](https://github.com/dbgeek/type-wave/issues/323), assembled in
  [#319](https://github.com/dbgeek/type-wave/issues/319))
- Scope: this is the **spec** a fresh implementation effort picks up without
  reopening any decision. Implementation and deployment are a separate effort
  (see [Branching & handoff](#branching--handoff)). The map is planning-only —
  no product code shipped by it (the empirical tickets built throwaway probe
  harnesses under `prototypes/openai-biasing-probe/`, evidence-gathering only).

## What this is

`docs/vocab-biasing-spec.md` shipped vocabulary biasing as **local-Whisper-only**
because the then-default OpenAI model (`gpt-realtime-whisper`) could not accept a
prompt. The 0.4.0 default flip to `gpt-live-transcribe`
([#303](https://github.com/dbgeek/type-wave/issues/303)) killed that premise: the
new default accepts server-side biasing. This spec wires the **same shared,
menu-edited `vocabulary` list** into the OpenAI backend as the `keywords` field of
`session.update` — nothing else. There is **no free-text prompt setting** (cut on
A/B evidence — see [Charting constraints](#charting-constraints-fixed-before-the-route-amendments-reconciled)),
no new user-facing surface beyond one menu-suffix condition, and no change to the
local-Whisper path.

The data model is unchanged: one flat, shared, menu-editable list of strings
(`Settings.vocabulary`, `config.zig`), clamped at load to 128 items × 100 chars.
Empty list stays a behavioural no-op on every backend.

Domain terms (Utterance, Segment, Talk Key, Backend, Lease, Settings Snapshot,
Status Item) are defined in [`CONTEXT.md`](../CONTEXT.md).

## Charting constraints (fixed before the route; amendments reconciled)

- ~~Both levers in scope: `vocabulary` → `keywords`; a new free-text `prompt`
  setting.~~ **Superseded by
  [#323](https://github.com/dbgeek/type-wave/issues/323): the spec is
  `keywords`-only.** The A/B ([#313](https://github.com/dbgeek/type-wave/issues/313))
  measured the prompt as worthless for vocabulary — pooled canonical-term recall
  identical to bare (24/60 both), WER a dead heat — with a demonstrated downside
  (`wayfinder` 4/5 bare → 0/5 with the prompt, rendered "WaveFinder") and no
  interaction on top of `keywords`. The untested tone/formatting hypothesis does
  not justify a config field, a menu surface, and a permanent OpenAI-only
  settings asymmetry; if it ever matters it returns as a **fresh effort with its
  own A/B**. Do not re-litigate at build time.
- ~~The prompt is OpenAI-only, signalled in the menu; it never feeds Whisper's
  `initial_prompt`.~~ Moot — no prompt setting.
- **The spec locked only after the empirical leg**: live probe
  ([#312](https://github.com/dbgeek/type-wave/issues/312)) and A/B
  ([#313](https://github.com/dbgeek/type-wave/issues/313)) ran before budgets and
  defaults were fixed. Every number below is grounded in observed behaviour, not
  documentation trust.
- **Planning-only.** Build is a separate effort against this document.

## Empirical foundations ([#311](https://github.com/dbgeek/type-wave/issues/311), [#312](https://github.com/dbgeek/type-wave/issues/312), [#313](https://github.com/dbgeek/type-wave/issues/313))

Full write-ups: [`research/session-update-rebias.md`](research/session-update-rebias.md),
[`research/gpt-live-transcribe-biasing-limits.md`](research/gpt-live-transcribe-biasing-limits.md),
[`research/gpt-live-transcribe-biasing-ab.md`](research/gpt-live-transcribe-biasing-ab.md),
with [`research/gpt-live-transcribe.md`](research/gpt-live-transcribe.md) as the
lever survey. The facts every decision below rests on:

- **Live re-update is documented and works.** A second `session.update` on a warm
  transcription session re-binds `keywords` without a reconnect. Ack is binary
  per update: `session.updated` (full effective config) xor a recoverable `error`
  event — the session stays open and **the previously applied config keeps
  running** after a rejection. Updates **merge field-wise**, so clearing requires
  an explicit empty value; omission leaves the old set bound. A client `event_id`
  is echoed on `error` but *not* on `session.updated` — keep **one re-bias in
  flight** at a time.
- **The server will not police a keywords budget.** The probe pushed 16,384
  items, 1,024-char items, ~262 KB total — silent acceptance throughout, and
  `session.updated` **never echoes `keywords`**, so silent truncation is
  invisible. Any cap is client policy. The one hard server rule: any item
  containing `<`, `>`, CR, or LF rejects the **whole** update
  (`invalid_value`, with `error.event_id: null` — uncorrelatable).
- **The apply boundary is the turn.** Mid-session re-update confirmed end to end
  (bare → "clavex"; re-update `keywords:["Klarvex"]` → next turn "Klarvex");
  a re-update sent *mid-append* did **not** reliably bias the in-flight turn.
  Re-bias pushes belong between Utterances.
- **`keywords` is the entire effect, and it is large.** A/B over byte-identical
  audio, four arms: WER 0.199 → **0.049**, canonical-term recall 40.0% →
  **91.7%**. Terms bare never got go 0/5 → 5/5 (`Bjorn`, `CoreAudio`,
  `LaunchAgent`, `config.zon`, `whisper.cpp`, `ghostty`).
- **No leakage — no guard needed.** 144 no-speech turns (silence, room-tone,
  loud hiss) returned **empty** transcripts in every arm. The
  `gpt-4o-mini-transcribe` prompt-leakage failure mode
  ([`research/vocab-openai-transcription-prompt.md`](research/vocab-openai-transcription-prompt.md))
  does not reproduce on this model. **A downstream leakage filter would be dead
  code — do not build one.** Recorded here so it is not re-litigated at build
  time.
- **`keywords` is a bias, not a lexicon override.** `type-wave` itself went 0/20
  in every arm (written `typewave` or `type wave`) — two ordinary English words
  carry a language-model prior strong enough to win. A model limit; no
  client-side budget, ordering, or escaping fixes it. Sets expectations for
  support/debugging: a term in the list is *nudged*, not guaranteed.

## 1. Session lifecycle ([#314](https://github.com/dbgeek/type-wave/issues/314))

**Read-at-use via eager idle-gated re-update.** `session_shaped = false` stands
for the biasing config; the vocab spec's #167 classification is not reversed for
OpenAI.

### How an edit reaches a warm session

- `keywords` join the **connect-time** `session.update` — the reconnect/60-min
  cycle path is covered for free, because the `ParamsProvider` re-reads the
  Settings Snapshot at every connect attempt.
- A vocabulary edit re-binds a **warm** session via a `session.update` push from
  the **maintenance loop at the next idle tick**. Never a reconnect, never a
  control write on the Talk-Key press path.

### Atomicity — one keywords set per Utterance

Pushes are gated on `!streaming`, so an in-flight Utterance always finishes under
the set bound when it began. The **Lease does not carry vocabulary on the OpenAI
path** — `leaseBegin` keeps discarding it; the session's currently-bound set is
the pin. One accepted deviation from local parity: an Utterance buffered during a
reconnect may replay under keywords *fresher* than its press (the connect re-reads
the snapshot). No machinery guards that race — **bound-at-begin,
fresher-on-replay accepted**; a newer bias is simply the config the user just
saved, applied early.

### Failure policy — log-and-degrade, no retry

Sanitation at construction (§2) is the hard precondition; the content ban is the
only known rejection trigger, so an unexpected rejection signals a construction
bug and retrying the same payload deterministically re-rejects. On an `error`
event the client **logs and keeps running** under the previously-bound set (or
unbiased, at connect time) — transcription is never blocked or torn down for a
biasing failure. The next edit or next natural reconnect is the retry. **One
re-bias in flight at a time** (the uncorrelatable-rejection discipline). The user
sees no degraded-state chrome (§3).

### The seam

- `config.Diff` grows a third category, **`rebias`** — a vocabulary change sets
  it; it stays out of `session_shaped` (and supersedes the current
  `d.any = true`-only branch at `config.zig:534` when the OpenAI backend is in
  play — the local path's read-at-use classification is untouched).
- The daemon translates it into a new **`markRebiasDirty()`** on the session,
  symmetric with the existing `markParamsDirty`.
- The pure maintenance decider gains a **`.rebias` action gated on `!streaming`**
  exactly like reconnect; the effect rebuilds the **full, always-emit-every-lever**
  `session.update` from the `ParamsProvider` snapshot and sends it on the warm
  link.
- **Precedence:** a pending cycle (`params_dirty`) supersedes a pending push and
  clears both — a reconnect re-reads everything anyway.

## 2. Keywords construction & budget policy ([#316](https://github.com/dbgeek/type-wave/issues/316))

### No OpenAI-side truncation

The structural clamp of `docs/vocab-biasing-spec.md` §1 (**128 items × 100
chars**, enforced at load in `config.zig`) is the **single size authority**.
Every clamped item ships verbatim — no token budget, no byte cap, no drop-tail.
Rationale: the server budget is unbounded/unobservable (§Empirical foundations),
a realistic list is fully effective, and any client-side number would be
arbitrary. The generalized rule: **each backend truncates only when its own
engine forces it** — Whisper's silent head-drop did (the ~180-token cut in
`vocab.buildPrompt` stands); OpenAI's doesn't exist.

**Consequence:** the menu's tri-state budget hint (`vocab.budget`) stays
**Whisper-only**. There is no OpenAI over-budget state to warn about — do not
invent one (§3).

### Per-item sanitation drop — OpenAI path only

Any item containing `<`, `>`, CR, or LF is **dropped whole** at construction —
never stripped or mangled (the load clamp's own "drop, never mangle" rule,
applied at the backend-specific layer where the constraint lives). One such item
rejects the *entire* update with an uncorrelatable error, which under §1's
log-and-degrade would silently cost the user **all** their terms. Not pure
pathology: `Vec<T>`, `Result<T, E>` are plausible real vocabulary. Local Whisper
keeps biasing those items untouched; the menu says nothing about them (§3).

### Construction home — `vocab.zig`, writer-based

- `TranscriptionParams` (`src/session.zig:181`) gains the **raw list**:
  `keywords: []const []const u8 = &.{}` — a zero-copy slice into the
  leak-by-design Settings Snapshot, exactly like `language`.
- `vocab.zig` gains a **pure, allocation-free `writeKeywordsJson(writer, list)`**
  beside `buildPrompt`, called by `formatSessionUpdate` mid-payload. Vocabulary
  policy stays single-homed and independently testable; `formatSessionUpdate`
  stays allocator-free in its logic (the destination buffer allocates — below).

**Contract of `writeKeywordsJson`:**

1. Emits a valid JSON string array (`["term1","term2"]`) in **user list order** —
   no dedup, no reordering (the flat-unweighted-model rule `buildPrompt`
   follows).
2. Item content is **verbatim** except JSON escaping: `"` → `\"`, `\` → `\\`,
   remaining control chars per the JSON spec (`std.json`'s string-escape helper
   is the natural build tool).
3. **Skips** items containing `<`, `>`, CR, LF (sanitation above) and empty
   items (legal on the wire but pointless; the load clamp drops blanks anyway —
   belt-and-braces purity).
4. **Never truncates.**

### Single payload shape — always emit, `[]` when empty

On keywords-capable models the `keywords` field is **always present** —
`"keywords":[]` for an empty list. Connect payload and the §1 idle-gated re-bias
push are **byte-identical by construction**, satisfying both the "same
constructed payload" rule and the merge-semantics constraint (`session.update`
merges field-wise — omission cannot clear a previously-bound set; only an
explicit `[]` can). `[]` at session open is proven harmless (probed live). The
charter's "pure no-op" rule is read **behaviourally, not byte-wise**: golden
tests for `gpt-live-transcribe` update once; the pinned `gpt-realtime-whisper`
payload stays byte-identical because the capability gate (§3) withholds the
field from non-capable models entirely.

### Allocating payload build

`su_buf: [2048]u8` (`src/session.zig:525`) cannot hold the escaped worst case
(~26 KB realistic, ~80 KB adversarial with `\uXXXX` escapes). The spec mandates:
build the `session.update` **with an allocator** at each connect attempt /
re-bias push (a cold path — once per connect or edit, never per audio frame); the
Session **owns the bytes** for the stored-payload re-send behaviour
(`session.zig:1118`), replacing them on each rebuild. Direct precedent:
`docs/vocab-biasing-spec.md` §1 mandated the same fixed-buffer→allocating switch
for `serializeSettings` when this exact 128×100 list overflowed `[4096]u8`.

## 3. Model-capability gating & the menu signal ([#317](https://github.com/dbgeek/type-wave/issues/317))

### Capability predicate — allowlist, withhold on unknown

A **`modelSpeaksKeywords`** predicate lives in `src/session.zig` directly beside
the existing `modelSpeaksLanguages` (`session.zig:200`), same shape: true for
exactly **`gpt-live-transcribe`** and **`gpt-transcribe`**, false for everything
else. Unknown/future model strings get `keywords` **withheld**. Rationale: the
downside asymmetry — rejections bounce the **whole** `session.update`, so
emitting to an incapable model at connect time would strand the session on server
defaults (wrong model, wrong delay) with an uncorrelatable error, while
withholding from a future capable model merely loses biasing and is a one-line
allowlist follow-up. Mirroring `modelSpeaksLanguages` means a future model lights
up both levers by touching one obvious place.

### Menu signal — the suffix condition tightens

From `backend == .openai` to **`openai and !keywords_capable`**. The vocabulary
row across the matrix:

| Backend | Model speaks keywords? | Row reads |
|---|---|---|
| local | any | `Vocabulary (3 terms)…` — unchanged |
| openai | yes | `Vocabulary (3 terms)…` — suffix dropped; identical to local |
| openai | no (`gpt-realtime-whisper`, unknown) | `Vocabulary (3 terms) — local only` — wording unchanged |

The suffix flags *inertness*; on a keywords-capable model the list is live, so
the flag vanishes and the absence of the warning is the positive signal (no
`— biasing active` chrome for the normal case). For the incapable cell,
`— local only` stays literally true — with that model selected the vocabulary
biases only the local backend — so the learned string is kept rather than minting
a second phrase.

Plumbing: `SettingsView` gains one field, **`keywords_capable: bool`**, computed
in `settingsView` by the exported predicate on `s.model`; `Presentation` stays
value-comparable and the pump's early-out stays honest.

### Status Item — nothing beyond the row suffix

Vocabulary-configured-but-model-incapable is stable, deliberately chosen
*configuration* state, not a runtime event — no icon/title change, no one-shot
transient on model switch. Runtime trouble is already covered by §1's
log-and-degrade. The moment a nudge could help — switching to an incapable
model — happens with the menu open, where the suffix change is visible on the
very row carrying the term count.

## Amendments this spec locks in

- **The free-text prompt setting is cut**
  ([#323](https://github.com/dbgeek/type-wave/issues/323)): no config field, no
  menu surface, no `prompt` key ever emitted. Measured null for vocabulary with a
  measured downside; the tone/formatting hypothesis returns only as a fresh
  effort with its own A/B.
- **No leakage guard** ([#313](https://github.com/dbgeek/type-wave/issues/313)):
  zero leakage across 144 no-speech turns — a downstream filter would be dead
  code.
- **`session_shaped = false` stands** for the biasing config on both backends
  ([#314](https://github.com/dbgeek/type-wave/issues/314)); the new `rebias`
  diff category — not a session cycle — carries OpenAI re-binding.
- **The budget hint stays Whisper-only**
  ([#316](https://github.com/dbgeek/type-wave/issues/316)): the structural load
  clamp is the single size authority for the OpenAI path.
- All names and numbers (`writeKeywordsJson`, `modelSpeaksKeywords`, escape
  mechanism, buffer strategy details) are **tunable by the build session**; the
  decisions — eager idle-gated re-update, log-and-degrade, clamp-only sizing,
  per-item banned-char drop, writer-based single-homed construction, always-emit
  single shape, allocating build, allowlist-withhold gating, suffix-tightening
  menu signal — are locked.

## Out of scope (never graduate here)

- **Seeding Backtrack's rewrite call with the vocabulary** — the vocab spec's
  deferred question stays a separate effort.
- **Feeding a free-text prompt to local Whisper** — moot (no prompt setting);
  Whisper's ~223-token `initial_prompt` budget stays dedicated to the glossary.
- **`languages` semantics** — settled by the 0.4.0 flip work
  ([#302](https://github.com/dbgeek/type-wave/issues/302),
  [#303](https://github.com/dbgeek/type-wave/issues/303)).
- **Implementation & deployment** — a separate effort builds against this
  document, exactly as vocab-biasing ([#161](https://github.com/dbgeek/type-wave/issues/161)
  → build) did.

## Branching & handoff

Implementation is a **separate effort**, not part of map #310. Per the repo's
convention, `main` is PR-gated by branch protection:

- Build on one shared feature branch (e.g. `feat/openai-keywords-biasing`),
  branched off `main`, landing via **PR**. Stacked PRs off that branch are fine
  as long as nothing hits `main` until the feature is whole.
- Natural build order: `writeKeywordsJson` + the `TranscriptionParams.keywords`
  field first (pure, testable off-network, golden-payload tests updated once);
  then the allocating payload build and the `modelSpeaksKeywords` gate; then the
  `rebias` diff category → `markRebiasDirty` → maintenance-decider `.rebias`
  action; finally the `SettingsView.keywords_capable` menu signal.

Nothing in this spec is left open on the route to the destination: every forking
decision is made. A fresh effort can start implementing against this document
directly.
