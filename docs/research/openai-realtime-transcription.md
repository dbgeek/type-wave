# OpenAI Realtime Transcription — protocol crib sheet for type-wave

Researched 2026-07-07 against live primary sources: the OpenAI developer docs (now hosted at
`developers.openai.com` — `platform.openai.com/docs/*` 301-redirects there), the
[openai/openai-openapi](https://github.com/openai/openai-openapi) spec (`main`, pushed 2026-06-23),
and the generated SDK types in [openai/openai-python](https://github.com/openai/openai-python) and
[openai/openai-node](https://github.com/openai/openai-node). Doc pages were fetched as raw markdown
(append `.md` to any `developers.openai.com/api/docs/...` URL), so quotes below are verbatim doc
source, not summarizer output.

## Summary table

| Question | Answer | Source |
|---|---|---|
| Offering | OpenAI **Realtime API** (GA), session `type: "transcription"` | [realtime guide](https://developers.openai.com/api/docs/guides/realtime) |
| Streaming model | **`gpt-realtime-whisper`** — display name "GPT-Realtime-Whisper"; the pitch's name is real | [model page data](https://developers.openai.com/api/docs/models/gpt-realtime-whisper) |
| Connect URL | `wss://api.openai.com/v1/realtime` (then `session.update`); `?model=` only shown for voice-agent sessions | [websocket guide](https://developers.openai.com/api/docs/guides/realtime-websocket) |
| Auth | `Authorization: Bearer $OPENAI_API_KEY`; **no** `OpenAI-Beta` header (GA) | [realtime guide §Beta to GA](https://developers.openai.com/api/docs/guides/realtime#beta-to-ga-migration) |
| Audio in | `audio/pcm`: 16-bit PCM, **24 kHz only**, mono, little-endian, base64 in JSON | SDK types + [openapi.yaml](https://github.com/openai/openai-openapi) |
| Append | `input_audio_buffer.append`, ≤ 15 MiB/event; stream ~50 ms chunks | openapi.yaml; [SDK example](https://github.com/openai/openai-python/blob/main/examples/realtime/audio_util.py) |
| Partial Transcript | `conversation.item.input_audio_transcription.delta` | [transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription) |
| Final Transcript | `conversation.item.input_audio_transcription.completed` | same |
| VAD off / manual commit | `turn_detection: null` + `input_audio_buffer.commit`. For `gpt-realtime-whisper` turn detection **must** be null — VAD unsupported | [VAD guide](https://developers.openai.com/api/docs/guides/realtime-vad); SDK types |
| Price | `gpt-realtime-whisper`: **$0.017 / audio minute** (duration-billed, not tokens) | [pricing](https://developers.openai.com/api/docs/pricing) |
| Session cap | Realtime sessions max **60 minutes** | [conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations) |
| Rate limit (Tier 1) | 100 audio-minutes per minute — irrelevant in practice for dictation | model page data (see §6) |
| Recommendation | `gpt-realtime-whisper`, manual commit, `delay: "low"` | §7 |

---

## 1. The real offering — and the "GPT-Realtime-Whisper" name

The pitch's "GPT-Realtime-Whisper" turns out **not** to be a misnomer anymore. OpenAI now ships a
model whose official display name is exactly **GPT-Realtime-Whisper** (model ID
`gpt-realtime-whisper`), described as a "Streaming speech-to-text model for realtime transcription
… designed for realtime use cases where developers need to tune latency and accuracy … priced by
audio duration rather than text tokens" ([model page](https://developers.openai.com/api/docs/models/gpt-realtime-whisper);
data extracted from the page's `models-page-data` bundle since the page is JS-rendered). It has a
single snapshot, also named `gpt-realtime-whisper` (no dated suffix yet).

It lives inside the **Realtime API** (GA — the beta header is retired, see §2). The Realtime API
now has three session types ([realtime guide](https://developers.openai.com/api/docs/guides/realtime)):

- **Voice-agent session** (`type: "realtime"`, model `gpt-realtime-2.1`) — model talks back.
- **Translation session** (`gpt-realtime-translate`, endpoint `/v1/realtime/translations`).
- **Transcription session** (`type: "transcription"`) — "streaming transcript deltas without
  model-generated spoken responses". This is type-wave's Transcription Session.

Models accepted in a transcription config (enum from
[`audio_transcription.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/audio_transcription.py),
matching openapi.yaml):

| Model | Docs positioning | Streaming deltas | VAD | `prompt` |
|---|---|---|---|---|
| `gpt-realtime-whisper` | "Live audio, transcript deltas, tunable latency. Natively streaming and designed for realtime sessions." | yes (native) | **not supported** — turn detection must be `null` | **not supported** |
| `gpt-4o-transcribe` | "Higher-accuracy speech-to-text where streaming isn't required. Use for file and request-response transcription workflows." | not native | yes (defaults `server_vad`) | free text |
| `gpt-4o-mini-transcribe` (+ snapshot `gpt-4o-mini-transcribe-2025-12-15`) | "Lower-cost transcription." | not native | yes | free text |
| `gpt-4o-transcribe-diarize` | speaker labels; request-response oriented | — | — | no |
| `whisper-1` | "Existing Whisper integrations. Not natively streaming in the same way as `gpt-realtime-whisper`." | no | yes | keyword list |

(Rows from the [transcription guide's model table](https://developers.openai.com/api/docs/guides/realtime-transcription)
and the SDK enum.)

So the pitch was referring to the real, current flagship path: a Realtime API Transcription Session
running `gpt-realtime-whisper`. Note the docs' caveat: it "is an alternative for live transcription,
not a blanket replacement for every transcription model. Test it against your audio, languages,
vocabulary, and latency requirements."

## 2. WebSocket protocol crib sheet

### Connect

```
wss://api.openai.com/v1/realtime
```

Headers:

```
Authorization: Bearer $OPENAI_API_KEY
OpenAI-Safety-Identifier: <hashed-user-id>   (optional, recommended, not required)
```

- **GA status / beta header:** "Remove the `OpenAI-Beta: realtime=v1` header when calling the GA
  interface" ([realtime guide §Beta to GA migration](https://developers.openai.com/api/docs/guides/realtime#beta-to-ga-migration)).
  None of the GA examples send it.
- **Query params:** the GA connect accepts only `model` and `call_id`
  ([`realtime_connect_params.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/realtime_connect_params.py)),
  and the SDK treats both as optional. The docs' WebSocket examples show
  `wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1` for voice-agent sessions
  ([websocket guide](https://developers.openai.com/api/docs/guides/realtime-websocket)); for a
  Transcription Session the model is chosen inside `session.update`, not the URL. The beta-era
  `?intent=transcription` query is legacy (still used by the beta interface, e.g.
  [openai-agents-python `openai_stt.py`](https://github.com/openai/openai-agents-python/blob/main/src/agents/voice/models/openai_stt.py));
  see Open questions.
- **Direct API key is fine for type-wave.** The docs bless raw-API-key WebSocket auth for
  server-side use: "You can use a standard API key to authenticate this connection, since the token
  will only be available on your secure backend server"
  ([websocket guide](https://developers.openai.com/api/docs/guides/realtime-websocket)). A local
  native tool using the user's own key is the same trust model — no ephemeral-token flow needed.
  The ephemeral flow exists for untrusted clients (browsers/mobile): `POST /v1/realtime/client_secrets`
  with a session config (realtime **or** transcription type), returning an `ek_…` token
  ([openapi.yaml `/realtime/client_secrets`](https://github.com/openai/openai-openapi/blob/main/openapi.yaml)).
  A beta-era `POST /v1/realtime/transcription_sessions` endpoint also still exists in the spec but
  uses old field shapes; ignore it.

First server event after connect is `session.created` ("Emitted automatically when a new connection
is established as the first server event", openapi.yaml `RealtimeServerEventSessionCreated`; its
`session` is a oneOf of realtime **or** transcription session objects).

### Session configuration (client → server)

Verbatim from the [transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription),
with `turn_detection` made explicit for type-wave's manual-commit mode:

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": {
          "type": "audio/pcm",
          "rate": 24000
        },
        "transcription": {
          "model": "gpt-realtime-whisper",
          "language": "en",
          "delay": "low"
        },
        "turn_detection": null,
        "noise_reduction": { "type": "near_field" }
      }
    },
    "include": ["item.input_audio_transcription.logprobs"]
  }
}
```

Field notes (all from the transcription guide + SDK types):

- `session.type`: `"transcription"` — transcription-only session, no model responses.
- `audio.input.transcription.model`: see model table in §1.
- `audio.input.transcription.language`: optional ISO-639-1 hint (e.g. `en`); "will improve accuracy
  and latency".
- `audio.input.transcription.delay`: `minimal | low | medium | high | xhigh` — latency/accuracy
  trade-off, "Only supported with `gpt-realtime-whisper` in GA Realtime sessions". Docs: `minimal`
  for most latency-sensitive, `low` for live captions, higher levels improve word error rate. "The
  exact delay in milliseconds can vary by model configuration, so benchmark with representative
  audio."
- `audio.input.turn_detection`: `null` (or omitted) for manual commit; see §4.
- `audio.input.noise_reduction`: optional; `near_field` (headsets/close mics) or `far_field`
  (laptop/conference mics); `null` to disable. "Filtering the audio can improve VAD and turn
  detection accuracy … and model performance."
- `include`: `["item.input_audio_transcription.logprobs"]` adds per-token logprobs to delta/completed
  events — potentially useful later for confidence-gating Insertions.

Server confirms with `session.updated` (or `error` if the config is rejected).

### Appending Capture audio (client → server)

```json
{
  "type": "input_audio_buffer.append",
  "audio": "<base64-encoded 24kHz mono s16le PCM>"
}
```

- Per openapi.yaml (`RealtimeClientEventInputAudioBufferAppend`): "The client may choose how much
  audio to place in each event up to a maximum of 15 MiB", and streaming smaller chunks improves
  realtime behavior. The server sends **no acknowledgement** for appends.
- First-party chunk-size prior art: OpenAI's own push-to-talk example streams 50 ms chunks
  (`CHUNK_LENGTH_S = 0.05`, 24 kHz, `paInt16`, 1 channel —
  [audio_util.py](https://github.com/openai/openai-python/blob/main/examples/realtime/audio_util.py)).
  At 24 kHz mono s16le, 50 ms = 2,400 bytes raw (3,200 base64).

### Committing the Utterance (client → server, on Talk Key release)

```json
{ "type": "input_audio_buffer.commit" }
```

To abandon an Utterance instead (e.g. cancel gesture), clear the buffer:

```json
{ "type": "input_audio_buffer.clear" }
```

(server replies `input_audio_buffer.cleared`).

### Server events, in order

After a manual commit, per openapi.yaml and the SDK types:

1. **`input_audio_buffer.committed`** — buffer became an input item:

```json
{
  "type": "input_audio_buffer.committed",
  "event_id": "event_1121",
  "previous_item_id": "item_002",
  "item_id": "item_003"
}
```

   "The `item_id` property is the ID of the user message item that will be created" — a
   `conversation.item.created`/`conversation.item.added` event follows for that item
   (openapi.yaml `RealtimeServerEventInputAudioBufferCommitted`).

2. **Partial Transcripts** — `conversation.item.input_audio_transcription.delta` (verbatim example
   from the transcription guide; `logprobs` only present if requested via `include`):

```json
{
  "type": "conversation.item.input_audio_transcription.delta",
  "item_id": "item_003",
  "content_index": 0,
  "delta": "Hello,"
}
```

3. **Final Transcript** — `conversation.item.input_audio_transcription.completed`. The guide's
   example plus the `usage` object that the SDK marks required (duration-type for
   duration-billed models like `gpt-realtime-whisper`, tokens-type for token-billed ones —
   [`conversation_item_input_audio_transcription_completed_event.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/conversation_item_input_audio_transcription_completed_event.py)):

```json
{
  "type": "conversation.item.input_audio_transcription.completed",
  "event_id": "event_2122",
  "item_id": "item_003",
  "content_index": 0,
  "transcript": "Hello, how are you?",
  "usage": { "type": "duration", "seconds": 2.1 }
}
```

   **Correlation rule:** "Ordering between completion events from different speech turns isn't
   guaranteed. Use `item_id` to match transcription events to committed input items"
   ([transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)).
   For type-wave: one Utterance = one commit = one `item_id` = one Final Transcript.

### Error signalling

Two distinct channels:

**a) Transcription failure for a specific item** — `conversation.item.input_audio_transcription.failed`,
"separate from other `error` events so that the client can identify the related Item"
([SDK type](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/conversation_item_input_audio_transcription_failed_event.py)):

```json
{
  "type": "conversation.item.input_audio_transcription.failed",
  "event_id": "event_2223",
  "item_id": "item_003",
  "content_index": 0,
  "error": {
    "type": "transcription_error",
    "code": "audio_unintelligible",
    "message": "The audio could not be transcribed.",
    "param": null
  }
}
```

**b) General `error` event** — "Most errors are recoverable and the session will stay open"
([SDK type](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/realtime_error_event.py)).
`error.event_id` echoes the client event that caused it (send `event_id` on client events to use
this):

```json
{
  "type": "error",
  "event_id": "event_890",
  "error": {
    "type": "invalid_request_error",
    "code": "invalid_event",
    "message": "The 'type' field is missing.",
    "param": null,
    "event_id": "my-client-event-id-123"
  }
}
```

Committing an **empty buffer** is an error: "This event will produce an error if the input audio
buffer is empty" (openapi.yaml `RealtimeClientEventInputAudioBufferCommit`). It arrives on channel
(b), not (a). type-wave should therefore suppress commits for zero-length Captures (accidental
Talk Key taps) client-side. See Open questions on the historical 100 ms minimum.

## 3. Audio format (parameterises CoreAudio Capture)

GA formats are a discriminated union ([`realtime_audio_formats.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/realtime_audio_formats.py)):

| `format.type` | What it is | Rate |
|---|---|---|
| `audio/pcm` | Raw PCM. "Only a 24kHz sample rate is supported." | `rate: 24000` (only legal value) |
| `audio/pcmu` | G.711 μ-law (telephony) | 8 kHz implied |
| `audio/pcma` | G.711 A-law (telephony) | 8 kHz implied |

For `audio/pcm` the wire format is: **16-bit signed integer PCM, 24,000 Hz, 1 channel (mono),
little-endian**, base64-encoded into the `audio` field of `input_audio_buffer.append`. Endianness
and channel count are stated in openapi.yaml's pcm16 description ("16-bit PCM at a 24kHz sample
rate, single channel (mono), and little-endian byte order") and confirmed by the first-party
example capturing `paInt16`, `CHANNELS = 1`, `SAMPLE_RATE = 24000`
([audio_util.py](https://github.com/openai/openai-python/blob/main/examples/realtime/audio_util.py)).

CoreAudio implication: request an `AudioStreamBasicDescription` of 24 kHz / 1 ch /
`kAudioFormatLinearPCM` / 16-bit signed integer (native little-endian on Apple silicon), or capture
at hardware rate and resample to 24 kHz before base64.

Declared in session config as shown in §2 (`session.audio.input.format`). There is no
sample-rate negotiation: 24 kHz is the only PCM option.

## 4. Utterance boundary control (hold-to-talk)

**Manual mode is not just possible — for `gpt-realtime-whisper` it is mandatory.**

- "`audio.input.turn_detection`: … For `gpt-realtime-whisper`, omit this field or set it to `null`,
  then commit audio manually" ([transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)).
- "Models that support VAD default to `server_vad`, while `gpt-realtime-whisper` requires turn
  detection to be omitted or set to `null`" ([VAD guide](https://developers.openai.com/api/docs/guides/realtime-vad)).
- "For `gpt-realtime-whisper` transcription sessions, turn detection must be set to `null`; VAD is
  not supported" ([SDK transcription turn-detection type](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/realtime_transcription_session_audio_input.py)).

This aligns perfectly with hold-to-talk: press Talk Key → open/reuse Transcription Session and
stream appends; release Talk Key → send `input_audio_buffer.commit`; the commit is the Utterance
boundary. "When Server VAD is disabled, you must commit the audio buffer manually … Input audio
transcription (if enabled) will be generated when the buffer is committed" (openapi.yaml append
event). After commit: `input_audio_buffer.committed` → deltas → `completed` (see §2 ordering).
Commit does **not** trigger any model response in a transcription session.

### VAD modes (fallback knowledge, for VAD-capable models like `gpt-4o-transcribe`)

From the [VAD guide](https://developers.openai.com/api/docs/guides/realtime-vad) and SDK types:

- **`server_vad`** (default where supported): silence-based chunking. Tunables: `threshold`
  (0–1, default 0.5; higher = needs louder audio — relevant to quiet speech), `prefix_padding_ms`
  (default 300), `silence_duration_ms` (default 500), `idle_timeout_ms` (server_vad only).
  When VAD commits, you additionally get `input_audio_buffer.speech_started` /
  `input_audio_buffer.speech_stopped` events and auto-commit at turn boundaries.
- **`semantic_vad`**: classifier decides the speaker is done based on the words; `eagerness:
  low | medium | high | auto` with "max timeouts of 8s, 4s, and 2s respectively" (auto = medium).
  "In transcription sessions, VAD only controls how audio is chunked" — the `create_response` /
  `interrupt_response` flags are conversation-only.

**Empty/too-short commits:** GA docs/spec only state that committing an *empty* buffer errors (via
the `error` event). The beta-era 100 ms minimum is no longer stated anywhere I could find — treat
"~<100 ms may error or return an empty transcript" as an open question and guard client-side.

## 5. Prompt / vocabulary biasing

The transcription config has a `prompt` field, but **not for the model we want**
([`audio_transcription.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/audio_transcription.py),
verbatim from the OpenAPI spec):

> "For `whisper-1`, the prompt is a list of keywords. For `gpt-4o-transcribe` models (excluding
> `gpt-4o-transcribe-diarize`), the prompt is a free text string, for example 'expect words related
> to technology'. **Prompt is not supported with `gpt-realtime-whisper` in GA Realtime sessions.**"

The [transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)
says the same and adds style guidance for models that do support it: "use short keyword lists
rather than long instructions … focus prompts on domain vocabulary, spelling, or style", example:
`Keywords: metoprolol, atorvastatin, A1C, systolic, diastolic`, and "treat keyword steering as an
aid rather than a guarantee".

Implications for type-wave's learned-vocabulary feature:

- With `gpt-realtime-whisper`: only lever is `language` pinning (ISO-639-1). Vocabulary biasing
  must be client-side post-processing (e.g. fuzzy-correcting Final Transcripts against the learned
  lexicon before Insertion), or a second-pass rewrite.
- Alternative: run the Transcription Session with `gpt-4o-transcribe` / `gpt-4o-mini-transcribe`
  instead — same session type, same manual commit (`turn_detection: null` is allowed for them too),
  plus a free-text `prompt` carrying the user's names/terms. Trade-off: not "natively streaming"
  (Partial Transcripts likely only arrive after commit) but 3–6× cheaper (§6).
- `language` is a first-class field for all models; pin it from user settings rather than
  auto-detecting.
- Max prompt length: not documented in the current docs/spec (whisper-1's historical 224-token
  limit no longer appears). See Open questions.

## 6. Pricing, session limits, rate limits

Prices from the [pricing page](https://developers.openai.com/api/docs/pricing) (values extracted
from the page's embedded table data on 2026-07-07; the tables are client-rendered):

| Model | Price | Basis |
|---|---|---|
| `gpt-realtime-whisper` | **$0.017 / minute** of input audio | duration-billed ("priced by audio duration rather than text tokens" — model page) |
| `gpt-realtime-translate` | $0.034 / minute | duration-billed |
| `whisper-1` | $0.006 / minute | duration-billed |
| `gpt-4o-transcribe` | $2.50 / 1M input tokens, $10.00 / 1M output tokens ≈ **$0.006 / minute** (page's own estimate) | token-billed |
| `gpt-4o-mini-transcribe` | $1.25 / 1M in, $5.00 / 1M out ≈ **$0.003 / minute** | token-billed |
| (context) `gpt-realtime-2.1` audio | $32 / 1M in, $0.40 cached, $64 / 1M out | token-billed |

The [costs guide](https://developers.openai.com/api/docs/guides/realtime-costs) confirms:
"Streaming translation and streaming transcription sessions are billed by audio duration", and the
`completed` event's `usage` object is the billing record per Utterance. There is "no cost currently
for network bandwidth or connections" — an idle open Transcription Session costs nothing, which
matters for type-wave's keep-a-session-warm latency strategy (unverified whether silence *appended*
to the buffer is billed for duration-billed models before commit; see Open questions).

Back-of-envelope for dictation: a heavy user dictating 60 min/day costs ~$1.02/day on
`gpt-realtime-whisper`, ~$0.18–0.36/day on the 4o-transcribe models.

**Session duration cap:** "The maximum duration of a Realtime session is **60 minutes**"
([conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations)) —
up from the historical 30. Session objects carry `expires_at` (unix seconds) so the client can see
its own deadline (openapi.yaml `RealtimeTranscriptionSessionCreateResponseGA`). type-wave must be
prepared to reconnect: never assume one Transcription Session outlives a workday.

**Rate limits** ([rate-limits guide](https://developers.openai.com/api/docs/guides/rate-limits)
plus per-model data from the model pages' data bundle): streaming audio models are limited in
"audio minutes per minute" rather than TPM:

| Tier (qualification) | `gpt-realtime-whisper` audio-min/min |
|---|---|
| Tier 1 ($5 paid) | 100 |
| Tier 2 ($50) | 350 |
| Tier 3 ($100) | 650 |
| Tier 4 ($250) | 1,000 |
| Tier 5 ($1,000) | 1,300 |

Even Tier 1 allows 100 concurrent realtime streams — a single-user dictation tool will never touch
this. (For comparison: `gpt-4o-transcribe` Tier 1 is 500 RPM / 10k TPM; `whisper-1` Tier 1 is
500 RPM.)

## 7. Recommendation for the CLI prototype

**Model: `gpt-realtime-whisper`. Mode: manual commit (`turn_detection: null`). `delay: "low"`,
`language` pinned from config, `noise_reduction: near_field`.**

Rationale:

- **Fit:** manual commit is the only supported mode for this model, and it maps 1:1 onto
  hold-to-talk — Talk Key release is the commit; no fighting VAD heuristics, no risk of the server
  splitting one Utterance into two items. Exactly one `completed` per Utterance, correlated by
  `item_id`.
- **Latency:** it is the only model the docs call "natively streaming and designed for realtime
  sessions", with a tunable `delay`. Start at `low` ("low-latency live captions") for Partial
  Transcript feedback; A/B `medium`/`high` if word error rate on real dictation is unsatisfying —
  the docs are explicit that higher delay "can improve word error rate".
- **Accuracy on quiet speech:** not documented anywhere; must be benchmarked. (The only
  quiet-speech-adjacent knob in the API is `server_vad.threshold`, which doesn't apply here since
  VAD is off — manual commit actually *removes* the quiet-speech failure mode of VAD never
  triggering.)
- **Price:** $0.017/min is 3–6× the 4o-transcribe models but absolutely small for dictation
  workloads (cents per day). Not a deciding factor.
- **Escape hatch:** if learned-vocabulary biasing via `prompt` proves essential before we build
  client-side correction, switch the same session to `gpt-4o-mini-transcribe` +
  `turn_detection: null` + `prompt` — the protocol surface (events, commit flow, audio format) is
  identical; only streaming-delta behavior and billing basis change.

Prototype flow: connect `wss://api.openai.com/v1/realtime` with `Authorization: Bearer` →
wait `session.created` → `session.update` (config in §2) → wait `session.updated` → on Talk Key
down, stream 50 ms `input_audio_buffer.append` events from Capture → on Talk Key up,
`input_audio_buffer.commit` → render deltas as Partial Transcript feedback → treat
`conversation.item.input_audio_transcription.completed.transcript` as the Final Transcript for
Insertion → on `failed`/`error`, surface and drop the Utterance. Suppress commits for near-empty
Captures; handle 60-min session expiry with transparent reconnect.

## Open questions / unverified

1. **Do Partial Transcripts stream before the commit in manual mode?** The transcription guide
   says both "Realtime transcription sessions stream transcript deltas as audio arrives, so users
   can see text before the full utterance is complete" *and* "If you disable turn detection, commit
   the buffer when you want transcription to begin." These conflict for `gpt-realtime-whisper` +
   manual commit (does `delta` flow during append, or only between commit and `completed`?). The
   prototype should handle deltas whenever they arrive; needs an empirical test on day one, since
   it decides whether live Partial Transcript feedback is possible while the Talk Key is held.
2. **Connect-time query params for transcription.** No doc shows the exact WS URL for a GA
   Transcription Session; the voice-agent examples use `?model=…`, the SDK makes `model` optional,
   and session type is set via `session.update`. Plan A: connect with no query params. If the
   server rejects that, try `?model=gpt-realtime-whisper`, then legacy `?intent=transcription`
   (beta interface, would also need `OpenAI-Beta: realtime=v1` and the old
   `transcription_session.update` event shapes).
3. **Minimum commit duration.** Beta docs required ≥100 ms of audio per commit; the GA spec only
   says an *empty* buffer errors. Exact behavior for 10–90 ms commits (error vs empty transcript)
   unverified, as is the exact error `code` string for an empty commit (beta:
   `input_audio_buffer_commit_empty`).
4. **Whether appended-but-uncommitted silence is billed** for duration-billed models (the costs
   guide's "VAD will effectively filter out empty input audio" note is about token-billed
   conversation sessions). Affects whether the prototype should only append while the Talk Key is
   held (recommended regardless).
5. **Whether the 60-minute cap applies identically to transcription sessions** — the statement is
   in the conversations guide about Realtime sessions generally; transcription sessions do carry
   `expires_at`, so read it at runtime.
6. **`delay` level timings** — deliberately unspecified ("exact delay in milliseconds can vary by
   model configuration"); needs benchmarking.
7. **Prompt length limits** for `whisper-1`/`gpt-4o-transcribe` prompts — no limit stated in
   current docs (whisper-1's historical 224-token cap no longer appears).
8. **`gpt-4o-transcribe` audio-token input rate** — the current pricing table shows $2.50 in /
   $10.00 out / "$0.006 / minute" estimate and no separate audio-token column (the pre-2026 rate
   card had audio input at $6.00/1M); the per-minute estimate is what matters and is confirmed.
9. **Accuracy on quiet/whispered speech** — no primary-source data for any model; benchmark with
   real hold-to-talk Captures.
