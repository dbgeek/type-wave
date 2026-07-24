# OpenAI transcription prompt support & the Partial-Transcript tradeoff (issue #163)

Researched 2026-07-23 against current OpenAI API docs. The question, per the ticket:
type-wave streams over a **Realtime transcription session** (`src/session.zig:199-211`)
with the default model `gpt-realtime-whisper`. Can we hand that model a **bias prompt**
(domain vocabulary — proper nouns, jargon, spellings) to improve accuracy? And if not,
what must we switch to, and at what cost?

## Bottom line for the spec

- **(a) Can we bias the default realtime model?** **No.** `gpt-realtime-whisper` does
  **not** accept a transcription bias `prompt`. OpenAI's own field docs say so verbatim:
  *"Prompt is not supported with `gpt-realtime-whisper` in GA Realtime sessions."* There
  is also no session-level `instructions` for a transcription-type session (that field
  belongs to speech-to-speech/response sessions, not the transcription session type
  type-wave opens). So on the current default, prompt biasing is simply unavailable.

- **(b) If not, what model + what tradeoff?** Switch the `.model` to
  **`gpt-4o-transcribe`** (higher accuracy) or **`gpt-4o-mini-transcribe`** (lower cost)
  — both accept a free-text bias `prompt`. `whisper-1` also accepts a prompt but only as
  a keyword list and is the weakest model, so skip it. **The tradeoff: you lose reliable
  live partial transcripts.** `gpt-realtime-whisper` is the *natively streaming* model —
  it emits incremental `…input_audio_transcription.delta` events as audio arrives, tuned
  by the `delay` field. The `gpt-4o-transcribe` family is positioned by OpenAI for
  request/response transcription *"where streaming isn't required"*; the `delay` tuning
  knob applies only to `gpt-realtime-whisper`. In practice, moving off the whisper model
  means the transcript arrives essentially as a single completed event rather than a
  stream of growing deltas. **For type-wave this cost is largely notional:** Partial
  Transcripts are logged-only — never shown in the HUD, never inserted at the cursor
  (only the Final Transcript on `…transcription.completed` is inserted). So losing live
  partials degrades a debug log line, not the user-visible product. The real cost to weigh
  is accuracy/latency/price of the gpt-4o models vs. whisper, not the partials per se.

- **(c) Exact JSON field + location.** The bias prompt is a **`prompt`** string that
  lives **inside the `transcription` object**, as a sibling of `model` / `language` /
  `delay`. In type-wave's GA-shaped `session.update` (`src/session.zig:210`), that is:

  ```json
  {"type":"session.update","session":{"type":"transcription",
    "audio":{"input":{
      "transcription":{"model":"gpt-4o-mini-transcribe","language":"en","prompt":"…"},
      "turn_detection":null, "noise_reduction":{"type":"near_field"}}}}}
  ```

  i.e. `session.audio.input.transcription.prompt`. (In the older beta shape the same
  field is `session.input_audio_transcription.prompt`; type-wave uses the GA
  `session.type = "transcription"` grammar, so it's the nested `audio.input.transcription`
  path.) The `delay` field should be **dropped** when switching off `gpt-realtime-whisper`
  — it is whisper-specific.

## Which models support a transcription bias prompt, and how

| Model | Prompt accepted? | Format | Streams live partials? |
|---|---|---|---|
| `gpt-realtime-whisper` (current default) | **No** (GA Realtime) | — | **Yes** — native streaming deltas, `delay`-tunable |
| `gpt-4o-transcribe` | **Yes** | Free-text string, e.g. *"expect words related to technology"* | Not the streaming path — request/response, *"where streaming isn't required"* |
| `gpt-4o-mini-transcribe` | **Yes** | Free-text string | Same as above (lower cost) |
| `gpt-4o-transcribe-diarize` | **No** | — | n/a |
| `whisper-1` | **Yes** | Keyword list; only the **last 224 tokens** are considered | n/a for the whisper realtime streaming behaviour |

OpenAI's `prompt`-field description (Realtime transcription session reference), quoted:

> "An optional text to guide the model's style or continue a previous audio segment. For
> `whisper-1`, the prompt is a list of keywords. For `gpt-4o-transcribe` models
> (excluding `gpt-4o-transcribe-diarize`), the prompt is a free text string, for example
> 'expect words related to technology'. Prompt is not supported with
> `gpt-realtime-whisper` in GA Realtime sessions."

## Length limits & format expectations

- **`gpt-4o-transcribe` / `gpt-4o-mini-transcribe`:** free-text natural language. The
  guidance is to prompt them "similarly to how you would prompt other GPT-4o models" —
  but keep it **short**: prefer a compact keyword/vocabulary list or a one-line style
  note over long instructions, and focus on **domain vocabulary, spellings, and style**
  rather than restating the transcription task. No explicit hard character limit is
  documented, but long prompts are discouraged and can leak into output (see caveat).
- **`whisper-1`:** treated as a keyword list; the model **only considers the final 224
  tokens** of the prompt and ignores anything earlier. It "operates more like a base
  GPT model" — limited instruction-following, mostly nudges style/spelling.
- **Prompt leakage caveat:** community reports document `gpt-4o-mini-transcribe` occasionally
  emitting prompt text into the transcript during long pauses / background noise / non-speech
  audio. A bias vocabulary would need to be short and would want a downstream guard if we
  ever inserted partials (we don't). Worth a live A/B before committing a default change.

## The "loses live Partial Transcripts" caveat — what exactly is lost and why

`gpt-realtime-whisper` is the only one of these models *designed* for the Realtime
streaming path: OpenAI describes it as "Natively streaming and designed for realtime
sessions" that "stream transcript deltas as audio arrives," with the `delay` knob trading
latency for accuracy (lower `delay` = earlier partial text). The `gpt-4o-transcribe`
family is described as "Higher-accuracy speech-to-text where streaming isn't required"
(and `-mini` as "Lower-cost transcription") — request/response shaped, no `delay` knob.
So the thing lost by switching is the **stream of incremental `delta` events** that grow a
partial transcript in real time; the completed-transcript event still arrives. **type-wave
never uses those deltas for anything user-facing** (partials are logged only; only the
Final Transcript is inserted), so the practical loss is one debug log becoming coarser.

## REST vs. Realtime — don't conflate them

The `prompt` parameter on the REST `POST /v1/audio/transcriptions` endpoint and the
`prompt` field inside a Realtime transcription session are the **same concept** but
different call sites. type-wave uses the **Realtime** path only, so the relevant location
is `session.audio.input.transcription.prompt` (above), not a REST body param — and the
same "supported on gpt-4o-transcribe / mini / whisper-1, not on gpt-realtime-whisper"
matrix applies to the Realtime field.

## Sources (OpenAI primary, plus one Microsoft mirror)

- Realtime transcription session — `prompt` field reference (the "not supported with
  gpt-realtime-whisper" quote):
  https://developers.openai.com/api/reference/resources/realtime/subresources/transcription_sessions/methods/create
- Realtime transcription guide (transcription object = `audio.input.transcription`;
  model list; streaming deltas):
  https://developers.openai.com/api/docs/guides/realtime-transcription
- Speech-to-text guide (prompt format per model; whisper-1 last-224-tokens limit):
  https://developers.openai.com/api/docs/guides/speech-to-text
- GPT-Realtime-Whisper model page (streaming positioning):
  https://developers.openai.com/api/docs/models/gpt-realtime-whisper
- GPT-4o Transcribe model page:
  https://developers.openai.com/api/docs/models/gpt-4o-transcribe
- openai-node SDK type (`InputAudioTranscription` = `{language?, model?, prompt?}`):
  https://github.com/openai/openai-node/blob/master/src/resources/beta/realtime/transcription-sessions.ts
- Azure/Microsoft mirror confirming gpt-realtime-whisper is the streaming model:
  https://learn.microsoft.com/en-us/azure/foundry/openai/concepts/gpt-realtime-whisper
- Prompt-leakage field report (`gpt-4o-mini-transcribe`):
  https://community.openai.com/t/transcription-model-gpt-4o-mini-transcribe-prompt-leakage/1371126
