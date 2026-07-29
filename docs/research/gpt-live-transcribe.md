# gpt-live-transcribe — identity, protocol fit, and comparison to gpt-realtime-whisper

Researched 2026-07-29 against live primary sources, resolving the wayfinder ticket
[What is gpt-live-transcribe and does it fit the Transcription Session?](https://github.com/dbgeek/type-wave/issues/297)
(map #296). Sources: the OpenAI developer docs at `developers.openai.com` (fetched as raw markdown
by appending `.md`, so quotes are verbatim doc source), and the generated SDK types in
[openai/openai-python](https://github.com/openai/openai-python) and
[openai/openai-node](https://github.com/openai/openai-node) (both fetched from their default
branches on 2026-07-29). Baseline for comparison is the 2026-07-07 crib sheet
`openai-realtime-transcription.md`, which documents the `gpt-realtime-whisper` world.

## Summary table

| Question | Answer | Source |
|---|---|---|
| Does the ID exist? | **Yes — `gpt-live-transcribe`, exactly as named.** Released **2026-07-28** (the day before this research) alongside sibling `gpt-transcribe` | [changelog](https://developers.openai.com/api/docs/changelog); [model page](https://developers.openai.com/api/docs/models/gpt-live-transcribe) |
| Positioning | "streaming speech-to-text model for applications that need low-latency transcript deltas from live audio" — and it has **replaced `gpt-realtime-whisper` as the recommended transcription-session model** in the realtime guide's session-type table | model page; [realtime guide](https://developers.openai.com/api/docs/guides/realtime) |
| Snapshot | single snapshot `gpt-live-transcribe`, no dated suffix | model page |
| Transcription session? | Yes — the [transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)'s `session.update` examples now use it, `type: "transcription"` |
| Manual commit | Yes — guide examples use `turn_detection: null` + `input_audio_buffer.commit` (hold-to-talk fit preserved) | transcription guide |
| Streaming deltas | Yes — "The recommended model returns transcript deltas as speech arrives" | transcription guide |
| Audio in | unchanged: `audio/pcm`, "Only a 24kHz sample rate is supported", mono s16le | SDK [`realtime_transcription_session_audio_input.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/realtime_transcription_session_audio_input.py) |
| `delay` | same enum `minimal \| low \| medium \| high \| xhigh`; guide shows `delay: "low"` on `gpt-live-transcribe` (SDK docstring lags, see §3) | transcription guide; SDK [`audio_transcription.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/audio_transcription.py) |
| `noise_reduction` | unchanged (session-level, model-agnostic): `near_field`/`far_field`/`null` | SDK audio-input type |
| **Vocabulary levers** | **Yes, three of them** — free-text `prompt`, `keywords: [string]`, `languages: [ISO-639-1]`: "Supported by `gpt-transcribe` and `gpt-live-transcribe`" | SDK `audio_transcription.py`; transcription guide |
| Price | **$0.017 / minute — identical to `gpt-realtime-whisper`**, duration-billed | [pricing](https://developers.openai.com/api/docs/pricing) |
| Session cap | unchanged: "The maximum duration of a Realtime session is **60 minutes**" | [conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations) |
| Rate limits | not yet published on the model page (day-old model) | model page |
| Deprecation of old model | **none** — `gpt-realtime-whisper` model page unchanged, not on the [deprecations page](https://developers.openai.com/api/docs/deprecations) |
| Migration guide | none published; the docs simply swapped the recommended model | realtime + transcription guides |
| Timestamps / diarization / confidence | not provided: "does not return word-level timestamps, speaker labels, or transcription confidence scores" | transcription guide |

**Bottom line for type-wave:** same price, same protocol skeleton (manual commit, 24 kHz PCM, same
delay tiers, streaming deltas), plus the vocabulary-biasing levers `gpt-realtime-whisper` lacks —
which is exactly what `docs/vocab-biasing-spec.md`'s server-side path was blocked on. The bare model
swap is a `config.zon` edit; *using* the new levers is a small `session.zig` code change (§4).

## 1. Identity and lineup

The [changelog](https://developers.openai.com/api/docs/changelog) entry (2026-07-28), verbatim:

> "Released [GPT Transcribe](https://developers.openai.com/api/docs/models/gpt-transcribe) for
> accurate file transcription and final transcripts of committed Realtime turns, along with
> [GPT Live Transcribe](https://developers.openai.com/api/docs/models/gpt-live-transcribe) for
> low-latency streaming transcription."

Both models support "free-form transcription context, keyword hints, and multiple expected input
languages" (same entry). The [model page](https://developers.openai.com/api/docs/models/gpt-live-transcribe)
describes it as a "streaming speech-to-text model for applications that need low-latency transcript
deltas from live audio", priced "$0.017 per minute of realtime audio duration", single snapshot
`gpt-live-transcribe`, sole endpoint `v1/realtime/transcription_sessions`, feature `streaming`.

The [realtime guide](https://developers.openai.com/api/docs/guides/realtime)'s session-type table
now reads: voice-agent → `gpt-realtime-2.1`, translation → `gpt-realtime-translate`,
**transcription → `gpt-live-transcribe`** (it read `gpt-realtime-whisper` on 2026-07-07). "For
realtime transcription, `gpt-live-transcribe` gives you controllable latency."

The full model enum accepted in a transcription config, from
[`audio_transcription.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/audio_transcription.py)
(identical union in [openai-node `realtime.ts`](https://github.com/openai/openai-node/blob/master/src/resources/realtime/realtime.ts)):

```
whisper-1 | gpt-transcribe | gpt-live-transcribe | gpt-4o-mini-transcribe |
gpt-4o-mini-transcribe-2025-12-15 | gpt-4o-transcribe | gpt-4o-transcribe-diarize |
gpt-realtime-whisper
```

`gpt-realtime-whisper` remains in the enum, on its model page, and on the pricing page, with **no
deprecation notice** anywhere (the only transcription deprecation listed is snapshot
`gpt-4o-mini-transcribe-2025-03-20`, shutdown 2027-01-20). No migration guide from
`gpt-realtime-whisper` exists — staying put carries no announced deadline.

**Accuracy claims:** OpenAI's announcement blog ("Advancing voice intelligence with new models in
the API", openai.com) is bot-blocked (HTTP 403), so its WER numbers could not be read first-party.
Secondary coverage claims a further-reduced error rate vs `gpt-realtime-whisper` and better
handling of "accents, languages, short phrases, numbers, jargon, loud background noise", but treat
those as **unverified** — the docs themselves make no quantitative accuracy claim. The transcription
guide's advice stands: "Test against real production audio, not only clean samples."

## 2. Protocol fit — the session.update shape

Verbatim from the [transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription),
the basic session config:

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": { "type": "audio/pcm", "rate": 24000 },
        "transcription": { "model": "gpt-live-transcribe" },
        "turn_detection": null
      }
    }
  }
}
```

and the "enhanced" config showing every new lever at once:

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": { "type": "audio/pcm", "rate": 24000 },
        "transcription": {
          "model": "gpt-live-transcribe",
          "prompt": "A customer support call about a premium plan and account AC-42.",
          "keywords": ["premium plan", "AC-42", "billing"],
          "languages": ["en", "fr"],
          "delay": "low"
        },
        "turn_detection": null
      }
    }
  }
}
```

Point-by-point against the crib sheet's shape (which `src/session.zig` `formatSessionUpdate` emits):

- **Session type / events**: still `type: "transcription"`; append/commit flow unchanged
  (`input_audio_buffer.append` → `input_audio_buffer.commit`); delta/completed event names unchanged
  per the guide.
- **Manual commit**: both official examples set `turn_detection: null` and commit manually — the
  1:1 hold-to-talk mapping is preserved. (Whether `gpt-live-transcribe` *also* supports VAD is not
  stated; the [VAD guide](https://developers.openai.com/api/docs/guides/realtime-vad) still only
  names `gpt-realtime-whisper` as VAD-unsupported. Irrelevant to type-wave, which wants VAD off.)
- **Streaming deltas while appending**: "The recommended model returns transcript deltas as speech
  arrives" — same wording family as before; the crib sheet's open question #1 (deltas before vs
  after commit in manual mode) remains empirically untested for the new model.
- **Audio format**: unchanged — `audio/pcm`, "Only a 24kHz sample rate is supported", mono s16le.
- **`delay`**: same five-tier enum; the guide applies `delay: "low"` to `gpt-live-transcribe`.
  Note the SDK docstring still reads "Only supported with `gpt-realtime-whisper` in GA Realtime
  sessions" — a generated-doc lag contradicted by the newer guide (see Open questions).
- **`noise_reduction`**: field unchanged at the session level ("Configuration for input audio noise
  reduction. This can be set to `null` to turn off"); the new examples merely omit it.
- **`language` (singular)**: the field still exists, described model-agnostically ("Supplying the
  input language in ISO-639-1 format (e.g. `en`) will improve accuracy and latency"). But the
  new model's *documented* language lever is the plural `languages` array — "Possible languages of
  the input audio, in ISO-639-1 format. Supported by `gpt-transcribe` and `gpt-live-transcribe`."
  Whether singular `language` is accepted/effective for `gpt-live-transcribe` is not stated.
- **`gpt-transcribe`** (the sibling, $0.0045/min): also takes prompt/keywords/languages and
  `turn_detection: null`, can "emit transcript deltas before the final completion event", but is
  positioned for "transcription to begin after a committed audio turn" and detected-language
  output — i.e. a cheaper post-commit path, not a live-caption path.

## 3. Vocabulary biasing — the blocked lever unblocks

`gpt-realtime-whisper` supports no `prompt` (crib sheet §5: "Prompt is not supported with
`gpt-realtime-whisper` in GA Realtime sessions" — that sentence is still in the SDK docstring).
`gpt-live-transcribe` gets **three** levers, per the SDK types and the guide's enhanced example:

| Field | Type | SDK docstring (verbatim) |
|---|---|---|
| `prompt` | free-text string | announcement: "free-form transcription context"; guide example shows scene-setting prose |
| `keywords` | `List[str]` | "Words or phrases to guide transcription of the input audio. Supported by `gpt-transcribe` and `gpt-live-transcribe`." |
| `languages` | `List[str]` (ISO-639-1) | "Possible languages of the input audio, in ISO-639-1 format. Supported by `gpt-transcribe` and `gpt-live-transcribe`." |

`keywords` is the natural carrier for type-wave's learned lexicon (`docs/vocab-biasing-spec.md`
server-side path); `prompt` can carry style/context. No length limits are documented for either
(open question). The stale `prompt` docstring (still listing only whisper-1/4o behaviors) hasn't
caught up with the 2026-07-28 release; the guide's example is the newer authority.

## 4. What would change in type-wave

**Config-string-only (works today, no code change):**

- Set `.model = "gpt-live-transcribe"` in `config.zon`. `formatSessionUpdate`
  (`src/session.zig:199–211`) already emits model/language/delay/noise_reduction as data, and every
  field it emits still exists in the new schema. Two residual risks, both empirically checkable in
  one session: (a) whether the server accepts `delay` for this model despite the stale SDK
  docstring — the guide says yes; (b) whether singular `language` is accepted for this model —
  undocumented. If either is rejected, the `session.updated`-vs-`error` handshake will say so
  immediately.

**Code changes (to actually use the new levers):**

- `TranscriptionParams` (`src/session.zig:179`) has no `prompt`/`keywords`/`languages` fields;
  `formatSessionUpdate` would need to emit them (keywords/languages as JSON string arrays — the
  first array-valued knob in the payload, so the hand-rolled formatter grows real escaping/joining
  logic). This is the vocab-biasing-spec integration, not part of a bare model swap.
- If singular `language` turns out ignored/rejected for `gpt-live-transcribe`, the language knob
  migrates to `languages: ["<code>"]` — a formatter change plus a settings-semantics decision
  (single hint → list of possible languages).
- Nothing else: audio pipeline (24 kHz mono s16le), commit flow, event handling, reconnect/60-min
  cap logic, and the delay-tier settings enum all carry over unchanged.

**Commercials:** identical $0.017/min, duration-billed; 60-minute session cap unchanged; idle
connections still free ("There is no cost currently for network bandwidth or connections",
[costs guide](https://developers.openai.com/api/docs/guides/realtime-costs)). The costs guide has
not been updated to name the new model, and still says nothing about billing of
appended-but-uncommitted audio (crib sheet open question #4 stands). Rate limits for the new model
are not yet published; `gpt-realtime-whisper`'s were 100 audio-min/min at Tier 1, never a
constraint for single-user dictation.

## Open questions / unverified

1. **Quantitative accuracy vs `gpt-realtime-whisper`** — the announcement blog (403 to fetchers)
   is the only place OpenAI might state WER numbers; docs make no claim. Needs the #36-style A/B
   benchmark on real dictation audio (map #296's second leg).
2. **`delay` acceptance** — guide shows `delay: "low"` on `gpt-live-transcribe`; SDK docstring
   still says gpt-realtime-whisper-only. Verify live via `session.updated` vs `error`.
3. **Singular `language` vs plural `languages`** for this model — singular is documented
   model-agnostically, plural is the model's named feature; server behavior for singular untested.
4. **Deltas before commit in manual mode** — crib sheet open question #1, still unresolved for the
   new model; decides whether Partial Transcript feedback flows while the Talk Key is held.
5. **`prompt`/`keywords` length limits** — none documented.
6. **Rate-limit tiers** — model page shows none yet (released 2026-07-28).
7. **Whether `gpt-live-transcribe` supports VAD** at all (irrelevant to hold-to-talk, but the VAD
   guide hasn't been updated to say).
8. **Billing of appended-but-uncommitted audio** — still undocumented for duration-billed models.

## Addendum (2026-07-29, same day): `language` resolved — it's `languages`, and "Don't send both"

A parallel pass over the same transcription guide surfaced lines the sections above missed. They
resolve open questions 3 and 7 and **supersede the "bare swap is a config edit" bottom line**.
Verbatim from the [transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription):

> "`gpt-live-transcribe` uses `languages` instead of the singular `language` field. Don't send both."

> "ISO 639-1 codes, such as `en`, `es`, and `fr`. Selected ISO 639-3 codes, such as `eng`, `spa`,
> `yue`, and `cmn`. Regional `zh` locale codes, such as `zh-cn`, `zh-tw`, and `zh-hk`."

> "The Realtime API rejects unsupported or incorrectly formatted language codes."

Spec shape: `languages: array of string, minItems: 1`. Consequences for type-wave:

- **A pinned language makes the swap a code change, not a config edit.** `formatSessionUpdate`
  (`src/session.zig:199`) emits the singular `"language":"<code>"` whenever `language` is
  non-empty — off-spec for this model, and the guide's rejection language suggests a refused
  `session.update` is plausible. Open question 3 is answered at the docs level; only the exact
  server behavior on an off-spec singular field remains untested.
- **A no-code A/B benchmark survives**: `language = ""` already omits the field entirely
  (`src/session.zig:206`, the auto-detect path from wayfinder #34), so
  `.model = "gpt-live-transcribe"` + `.language = ""` is a valid config-only setup for map #296's
  benchmark leg. For symmetry, run `gpt-realtime-whisper` with `.language = ""` too, or record
  the asymmetry in the write-up.
- **On switch, the language knob migrates**: pinning becomes `languages: ["<code>"]` — a
  formatter change plus a small settings-semantics decision (single hint → list of possible
  languages), folding into §4's `prompt`/`keywords` emission work.
- **Open question 7 (VAD)**: the guide positions VAD as *optional* for this model ("configure
  voice activity detection instead" of manual commit) — unlike `gpt-realtime-whisper`'s
  mandatory-off. Irrelevant to hold-to-talk, which keeps manual commit.
