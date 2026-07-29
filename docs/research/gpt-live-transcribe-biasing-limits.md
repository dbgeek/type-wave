# Live probe — `gpt-live-transcribe` keywords/prompt limits and handshake behavior

Probed 2026-07-29 against the live Realtime API, resolving the wayfinder ticket
[Live-probe gpt-live-transcribe keywords/prompt limits and handshake behavior](https://github.com/dbgeek/type-wave/issues/312)
(map #310). Harness: `prototypes/openai-biasing-probe/probe.py` — a throwaway,
stdlib-only Python websocket client speaking the transcription-session grammar
(crib sheet `docs/research/openai-realtime-transcription.md`), mirroring the daemon's
`formatSessionUpdate` envelope (`src/session.zig`). Audio turns were synthesized with
macOS `say` at pcm16/24kHz mono, using the invented term **"klarvex"** so keyword
efficacy is visible as spelling. Companion to `session-update-rebias.md` (#311, the
docs-level answers this run verifies empirically). Everything below is n=1–2 on one
evening, one API key, one region — server-side limits can change without notice.

## Summary table

| Question (ticket bullet) | Observed answer |
|---|---|
| `prompt` max length | **1024 characters** (code points, not bytes — 1024 × 2-byte `é` accepted, 1040 ASCII rejected). Explicit rejection: `error` code `string_above_max_length`, message states the 1024 limit, `param: session.audio.input.transcription.prompt`. |
| `prompt` content rules | Permissive: newline, CR, `<`, `>` all accepted (the keyword character ban does **not** apply to prompt). Echoed verbatim in `session.updated`. |
| `keywords` max item count | **None found up to 16,384 items** — silent acceptance. |
| `keywords` max item length | **None found up to 1,024 chars/item** — silent acceptance. |
| `keywords` total budget | **None found up to ~262 KB** (1,024 items × 256 chars). No error, no truncation signal. |
| Rejection vs silent acceptance vs silent truncation | Over-size `prompt` → explicit rejection. Oversized `keywords` → silent acceptance at every size tried; truncation, if any, is server-internal and **unobservable** (keywords are never echoed). Banned characters in a keyword → explicit rejection. |
| Does `session.updated` echo the applied config? | **Partially.** The echo carries `model`, `languages`, and `prompt` (verbatim) but **never `keywords` and never `delay`** — even when they were just accepted. A build can verify the prompt stuck; it **cannot** verify the keyword list via the handshake. |
| Mid-session re-update | **Confirmed working end to end**: changing `keywords` between two committed turns on one connection changed the second transcript ("clavex" → "Klarvex"). Ack latency ~150–200 ms. |
| Rejected update leaves old config running | **Confirmed**: after a banned-character rejection, the next committed turn still transcribed with the previously applied keywords. |
| Apply boundary vs append | A re-update sent **mid-append did not bias the in-flight turn** — even for audio appended *after* the ack. Effective granularity is the turn: send re-bias between Utterances (#311's guardrail, now empirical). |

## Method

- One websocket per phase to `wss://api.openai.com/v1/realtime?intent=transcription`
  (`Authorization: Bearer` only, no beta header), sending the daemon's exact
  `session.update` envelope (`session.type: "transcription"`, nested
  `audio.input.transcription`, `turn_detection: null`) with `model:
  "gpt-live-transcribe"`, `languages: ["en"]`, `delay: "low"` plus the lever under
  test. Every server event logged raw; limits located by ascending sizes then bisection.
- Audio phases: `say -o … --data-format=LEI16@24000` clips (~2.5–3.4 s), appended in
  ~2 s chunks, manual `input_audio_buffer.commit`, final transcript read from
  `conversation.item.input_audio_transcription.completed`.
- Run it again: `python3 prototypes/openai-biasing-probe/probe.py
  <echo|prompt-len|kw-count|kw-itemlen|malformed|reupdate|boundary|boundary-late|late-control|prompt-misc>`
  (key from `$OPENAI_API_KEY` or the app's keychain item).

## 1. `prompt`: a hard, self-describing 1024-character limit

Ascent + bisection on one connection: 1024 accepted, 1040 rejected. The rejection is
schema-level and precise (verbatim):

> `Invalid 'session.audio.input.transcription.prompt': string too long. Expected a
> string with maximum length 1024, but got a string with length 2048 instead.`
> (`type: invalid_request_error`, `code: string_above_max_length`)

- **Characters, not bytes**: 1024 × `é` (2,048 UTF-8 bytes) and 600 × `🎤` (1,200
  UTF-16 units, 2,400 bytes) both accepted — the count is Unicode code points.
- **No content ban**: newline, CR, and angle brackets in the prompt all ack'd — the
  documented `<`/`>`/CR/LF ban is keyword-specific.
- The echo returns the applied prompt verbatim (length-exact), so a build *can*
  confirm what prompt is live.
- These errors carry the client `event_id` (`error.error.event_id` = the sent id).

## 2. `keywords`: no observable server-side limit, and no echo

Silent acceptance at every size tried on 2026-07-29:

| shape | result |
|---|---|
| 1,024 items × 8 chars | `session.updated` |
| 4,096 items × 8 chars | `session.updated` |
| 16,384 items × 8 chars (~131 KB) | `session.updated` |
| 1 item × 1,024 chars | `session.updated` |
| 1,024 items × 256 chars (~262 KB) | `session.updated` |

No error, no truncation marker — and since `session.updated` **never echoes
`keywords`** (see §3), silent truncation server-side cannot be ruled out; it is
simply invisible. The practical reading for #316: **the server will not police the
keyword budget for us.** Any cap is a client-side policy decision, and its number
must come from biasing *efficacy* (does a 500-item list still bias? — #313's
territory), not from acceptance. Small lists demonstrably work (§4).

Content rules, confirmed against the documented ban:

- `<`, `>`, CR, LF in any item → whole update rejected: `code: invalid_value`,
  `message: "The 'keywords' parameter contains unsupported characters."`,
  `param: …transcription.keywords`. **Caveat for the build: these rejections carry
  `error.event_id: null`** — the documented client-`event_id` echo does *not* happen
  for this class, so correlation is by ordering only (keep one update in flight).
- Empty-string item → **accepted** (not rejected).
- Non-string item (integer) → rejected `invalid_type`, and this one *does* echo the
  client `event_id` — the id echo is schema-level-errors-only.

## 3. The handshake: binary ack, partial echo, survivable rejection

- Every update resolves to exactly one of `session.updated` xor `error` (~150–200 ms),
  as documented.
- **The echo is partial.** `session.updated.session.audio.input.transcription`
  contains `model`, `language` (null), `languages`, and `prompt` — `keywords` and
  `delay` are absent even immediately after being accepted. The SDK-type inference in
  `session-update-rebias.md` §2 ("keywords are representable in the echo") is true of
  the type but **false of the wire**: the build cannot use the ack to verify the
  applied keyword list.
- **Rejection is recoverable and leaves the previous config in effect** — confirmed,
  not just inferred: after a banned-character rejection mid-session, a benign update
  still ack'd, and a committed turn still transcribed with the *previously* applied
  keywords ("Klarvex", §4 turn 3).
- Fresh sessions default to `server_vad` turn detection (visible in
  `session.created`); the first update must null it, as the daemon already does.

## 4. Re-update between turns: works, and the boundary is the turn

Same synthesized clip ("The klarvex module streams audio to the daemon."), three
committed turns on **one** connection:

| turn | config | transcript |
|---|---|---|
| 1 | `keywords: []` | "The **clavex** modulus streams audio to the daemon." |
| 2 | after re-update to `keywords: ["Klarvex"]` | "The **Klarvex** modulus streams audio to the daemon." |
| 3 | after a *rejected* update (`bad<tag`) | "The **Klarvex** modulus streams audio to the daemon." |

The ticket's core question is answered: **a mid-session `session.update` re-binds
`keywords` on the warm link, and the next committed turn reflects the new list.**
(This also confirms keywords have real biasing effect despite never being echoed.)

**Apply boundary** (the #311 residue): with the update sent *between append chunks*
of a single turn, the in-flight turn did **not** pick up the new keywords —

- term in the first half (decoded before the update): "clavex" — old config;
- term in the *second* half, appended after the update's ack, with controls on the
  same clip: no-keywords control → "Clarivox", keywords-pre-set control →
  "Klarvex", mid-append update → "**Klarviks**" — not the keyword spelling.

n=1 per cell and "Klarviks" sits suspiciously between the brackets, so call it
*unreliable* rather than *provably pinned-at-first-append* — but the engineering
rule is the same either way: **a re-update only reliably applies to the next turn.
Push biasing changes while idle between Utterances** (buffer empty, ack before the
next append), exactly the guardrail `session-update-rebias.md` prescribed.

## Caveats

- All numbers are one evening's observation of an undocumented surface (n=1–2 per
  cell, one key, one region). The 1024 prompt limit is schema-enforced and
  error-messaged, so it's presumably stable; the *absence* of keyword limits is an
  absence of evidence — a build should still self-police (#316) rather than lean on
  server generosity.
- Biasing efficacy was only spot-checked (one invented term, one voice, small
  lists). Whether large lists bias well — or degrade recognition — is #313's A/B.
- `say`-synthesized speech is cleaner than real dictation; efficacy magnitudes here
  don't transfer, only the mechanics (what applied when).

## What this feeds

- **[Session lifecycle (#314)](https://github.com/dbgeek/type-wave/issues/314)** —
  both empirical preconditions in: re-update works on the warm link; the boundary is
  per-turn, so an eager push on Save (while idle) or a lazy push at next Talk-Key
  both give whole-Utterance coherence; rejection can't strand a session.
- **[Config schema (#315)](https://github.com/dbgeek/type-wave/issues/315)** — the
  prompt cap is 1024 *characters* server-side; newlines are legal on the wire (the
  clamp decision is purely a ZON-patcher/UX question); the limit is explicit and
  error-messaged, so an over-cap value fails loud, not silent.
- **[Keywords construction/budget (#316)](https://github.com/dbgeek/type-wave/issues/316)** —
  no server budget to size against: acceptance is unbounded in practice, truncation
  unobservable, so any cap is client policy pending #313's efficacy data. Sanitation
  duty confirmed: strip/refuse `<` `>` CR LF (whole-update rejection, uncorrelatable
  `event_id`); empty items are legal but pointless.
- **[A/B benchmark (#313)](https://github.com/dbgeek/type-wave/issues/313)** — the
  harness's turn loop (append/commit/final on a warm biased session) is directly
  reusable; keywords demonstrably bias spelling of out-of-vocabulary terms, so the
  A/B has a live mechanism to measure.
