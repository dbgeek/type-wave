# session.update re-bias — can a live transcription session's config change mid-connection?

Researched 2026-07-29 against live primary sources, resolving the wayfinder ticket
[Can a live transcription session's biasing config be re-updated mid-connection?](https://github.com/dbgeek/type-wave/issues/311)
(map #310). Sources: the OpenAI developer docs at `developers.openai.com` (fetched as raw markdown
by appending `.md`, so quotes are verbatim doc source) and the generated SDK types in
[openai/openai-python](https://github.com/openai/openai-python) and
[openai/openai-node](https://github.com/openai/openai-node) (default branches, fetched 2026-07-29).
Docs-level only by design — the empirical verification is ticket #312. Baselines:
`openai-realtime-transcription.md` (protocol crib sheet) and `gpt-live-transcribe.md` (the biasing
levers). Every claim below is tagged **documented** (doc prose), **SDK-type** (generated type
shape, i.e. OpenAPI-spec inference), or **undocumented** (unknown, needs #312).

## Summary table

| Question | Answer | Source |
|---|---|---|
| Second `session.update` on a live transcription session? | **Yes — documented, verbatim, for exactly this case**: "Send another `session.update` event to change the transcription configuration during an existing session." | [transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription) §Add transcription context |
| When may it be sent? | "The client may send this event at any time to update any field except for `voice` and `model`" | [client-events reference](https://developers.openai.com/api/reference/resources/realtime/client-events#session.update) |
| `keywords`/`prompt`/`languages` changeable live? | Yes — the guide's mid-session-update sentence introduces precisely those three fields; none is listed as fixed | transcription guide |
| Merge semantics | Partial: "Only the fields that are present in the `session.update` are updated"; clear a string with `""`, an array with `[]`, `turn_detection` with `null` | client-events reference |
| Acknowledgment | `session.updated` "showing the full, effective configuration" / "with the new state of the session" — "unless there is an error" | client-events reference; [conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations); [server-events reference](https://developers.openai.com/api/reference/resources/realtime/server-events#session.updated) |
| Echo of applied biasing fields | SDK-type: `session.updated.session` is the same create-request union as the update itself, so `keywords`/`prompt`/`languages`/`delay` are representable in the echo; the docs-site reference bundle still shows a stale response schema without them (§2) | SDK `session_updated_event.py`; node `realtime.ts` |
| Invalid update | `error` event; "Most errors are recoverable and the session will stay open". Documented rejection triggers: bad language codes, keywords containing `<` `>` CR LF, `prompt` over the model's (unstated) length limit | server-events reference; transcription guide |
| Error correlation | client `event_id` "will be passed back if there is an error with the event, but the corresponding `session.updated` event will not include it" | client-events reference |
| Fields that cannot change | `voice` and `model` — but those are *top-level realtime-session* fields; a transcription session has neither. Whether nested `audio.input.transcription.model` may change mid-session: **undocumented** | client-events reference; SDK `realtime_transcription_session_create_request.py` |
| Timing vs append/commit | **Undocumented** — no statement on whether a new config affects audio already appended but not yet committed | (absence, all sources) |
| Rate limit on updates | none documented anywhere | (absence) |
| `gpt-live-transcribe` vs older models | the mid-session-update instruction is new prose in the reworked (post-2026-07-28) guide, written around this model's biasing fields; no per-model difference in update *mechanics* is stated | transcription guide vs 2026-07-07 crib sheet |

## 1. The direct answer — documented, and specific to the biasing fields

The [transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)'s
"Add transcription context" section opens (verbatim):

> "Add context when the audio contains specialized vocabulary or more than one expected language.
> **Send another `session.update` event to change the transcription configuration during an
> existing session.**"

and immediately shows the enhanced payload carrying `prompt`, `keywords`, `languages`, `delay` on
`"model": "gpt-live-transcribe"` with `turn_detection: null` — i.e. the documented mid-session
update is *the* delivery mechanism for the biasing levers, demonstrated in exactly type-wave's
manual-commit configuration. This sentence is new: the 2026-07-07 crib sheet pass over the same
guide had no mid-session-update statement at all.

The general contract, from the
[client events reference](https://developers.openai.com/api/reference/resources/realtime/client-events#session.update)
(`RealtimeClientEventSessionUpdate`, verbatim; identical docstring in SDK
[`session_update_event.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/session_update_event.py)):

> "Send this event to update the session's configuration. The client may send this event **at any
> time** to update **any field** except for `voice` and `model`. `voice` can be updated only if
> there have been no other audio outputs yet.
>
> When the server receives a `session.update`, it will respond with a `session.updated` event
> showing the full, effective configuration. Only the fields that are present in the
> `session.update` are updated. To clear a field like `instructions`, pass an empty string. To
> clear a field like `tools`, pass an empty array. To clear a field like `turn_detection`, pass
> `null`."

The [conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations)
concurs ("Most session properties can be updated at any time, except for the `voice` … after the
model has responded with audio once during the session") and adds: "When the session has been
updated, the server will emit a `session.updated` event with the new state of the session."

**Merge semantics matter for clearing biases** (documented pattern, applied by analogy): dropping a
keyword list would be `keywords: []` and dropping a prompt `prompt: ""` — merely *omitting* the
field from a later update leaves the previous value in effect, since only present fields are
updated. type-wave's `formatSessionUpdate` (`src/session.zig:211`) always emits the full
`transcription` object, which sidesteps the omit-vs-clear trap as long as every lever is always
emitted (empty array/string rather than omitted, once `keywords`/`prompt` are added).

**Does the new config apply to subsequently committed audio without reconnecting?** The guide's
framing implies yes — "change the transcription configuration during an existing session" *is* its
recipe for adding vocabulary context, and it would be useless otherwise. But no sentence
explicitly states "applies from the next commit" — the effective-boundary question is
**undocumented** (§4) and is the one thing #312 must confirm empirically.

## 2. The acknowledgment — `session.updated`, and what it echoes

Documented: `session.updated` is "Returned when a session is updated with a `session.update`
event, **unless there is an error**"
([server events reference](https://developers.openai.com/api/reference/resources/realtime/server-events#session.updated)),
carrying "the full, effective configuration". So the handshake is binary per update:
`session.updated` (applied) xor `error` (rejected) — the same handshake `session.zig` already
waits on at connect time.

Whether the echoed session object includes the applied `keywords`/`prompt` is messier:

- **SDK-type (both SDKs agree):** `session.updated.session` is typed as the *create-request*
  union — `RealtimeSessionCreateRequest | RealtimeTranscriptionSessionCreateRequest`
  ([`session_updated_event.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/session_updated_event.py);
  [node `realtime.ts`](https://github.com/openai/openai-node/blob/master/src/resources/realtime/realtime.ts)
  `SessionUpdatedEvent`). The transcription variant nests
  [`AudioTranscription`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/audio_transcription.py),
  which has `keywords`, `languages`, `prompt`, `delay`, and `gpt-live-transcribe` in its model
  enum — so the full biasing config is *representable* in the echo.
- **Docs-site reference bundle (stale):** the rendered
  [server-events page](https://developers.openai.com/api/reference/resources/realtime/server-events#session.updated)
  instead types the transcription variant as `RealtimeTranscriptionSessionCreateResponse`, whose
  `transcription` object has only `language`/`model`/`prompt` and a model enum that predates the
  2026-07-28 models. The whole reference bundle shows the same lag (no `keywords`/`languages`/
  `gpt-live-transcribe` anywhere on the page, request side included) — while the *prose* guides
  and both SDKs, regenerated after the release, have them. Treat the bundle as pre-release
  snapshot, not as evidence keywords won't echo.
- **Undocumented residue:** whether the server's actual wire echo includes `keywords` — SDK types
  say it can, the stale reference schema says nothing; #312 should log the raw `session.updated`.

One correlation asymmetry worth engineering around (documented): a client-supplied `event_id` "will
be passed back if there is an error with the event, but the corresponding `session.updated` event
**will not include it**"
([client-events reference](https://developers.openai.com/api/reference/resources/realtime/client-events#session.update)).
So success acks are only attributable to a specific update by ordering — keep at most one
`session.update` in flight, and tag each with an `event_id` so a rejection is unambiguous.

## 3. Invalid updates — the session survives

General error semantics, verbatim from the
[server events reference](https://developers.openai.com/api/reference/resources/realtime/server-events#error)
(same docstring in SDK `realtime_error_event.py`):

> "Returned when an error occurs, which could be a client problem or a server problem. **Most
> errors are recoverable and the session will stay open**, we recommend to implementors to monitor
> and log error messages by default."

Documented rejection triggers specific to the biasing fields
([transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription), verbatim):

> "The Realtime API rejects unsupported or incorrectly formatted language codes."

> "Keywords are hints, not required output. Keep each keyword on one line and don't include `<`,
> `>`, a carriage return, or a line feed. **The Realtime API rejects the session update** if a
> keyword contains one of these characters or `prompt` exceeds the model's length limit."

Note the wording: the *session update* is rejected — not the session. Combined with
"`session.updated` … unless there is an error" and the recoverable-error docstring, the documented
model is: a bad update yields an `error` event, no `session.updated`, and the connection stays
open. That the *previous* config remains in effect after a rejection is the natural reading but is
not stated in so many words — **inference**, cheap to confirm in #312. The `prompt` length limit
exists but its value is nowhere stated; no keyword count/length cap is documented beyond the
character ban (both were already open questions in `gpt-live-transcribe.md`).

Client-side consequence: sanitize learned-vocabulary entries before emission (strip/refuse `<`,
`>`, CR, LF — the first *content*-dependent rejection surface in type-wave's payload, unlike
today's fixed-shape config where only enum typos could reject).

## 4. Constraints, timing, and what stays undocumented

- **Immutable fields:** only `voice` and `model` are named, and both are top-level fields of the
  *realtime* (voice-agent) session variant. A transcription session's create request has just
  `type`/`audio`/`include`
  ([`realtime_transcription_session_create_request.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/realtime_transcription_session_create_request.py))
  — no top-level `model`. Whether the immutability extends to the nested
  `audio.input.transcription.model` is **undocumented**: the guide's mid-session example re-sends
  the same model string, and no doc shows or forbids a mid-session model *swap*. type-wave doesn't
  need one (a model change can keep costing a reconnect); don't rely on it either way.
- **Session `type`:** nothing documents switching a live session between `realtime` and
  `transcription`; assume fixed at first update (undocumented, irrelevant to type-wave).
- **Timing vs the audio buffer:** no source states whether a config change affects audio already
  appended but uncommitted, or only audio appended (or committed) after the ack. For
  `gpt-live-transcribe` — which streams deltas as audio arrives, i.e. may already be decoding
  pre-commit — the question is genuinely ambiguous at the docs level. **Undocumented**; #312's
  cleanest probe is: append, update mid-utterance, commit, and see which vocabulary wins. The safe
  pattern needs no answer: send re-bias updates while idle between Utterances (buffer empty), so
  the ack precedes the next append.
- **Rate limits:** no per-event or per-update limit appears in any guide or reference; Realtime
  limits remain audio-minutes-per-minute. An update per vocabulary edit (human-speed) is far below
  any plausible ceiling — but "no documented limit" is an absence, not a guarantee.
- **`gpt-live-transcribe` vs older models:** no *mechanical* difference in update semantics is
  documented — `session.update`/`session.updated`/`error` are model-agnostic. What's new with this
  model is that there is finally something worth re-updating (`gpt-realtime-whisper` has no
  biasing fields), and the guide prose teaching mid-session updates arrived with it. One sibling
  quirk for contrast: `gpt-transcribe` "automatically uses earlier transcribed turns as context" —
  implicit, unrequested context accumulation; no such statement exists for `gpt-live-transcribe`,
  whose context is exactly what you send. The beta-era `transcription_session.update` event still
  in the node SDK is legacy; GA uses plain `session.update` (crib sheet §2).

## Bottom line for type-wave

**Live re-update works and is documented: biasing config is *not* session-shaped — it is
read-at-write-on-the-warm-link.** A second `session.update` carrying changed `keywords`/`prompt`
(or `languages`/`delay`) may be sent "at any time" on the live transcription session; the server
answers `session.updated` (or a recoverable `error` that leaves the link open), and the guide's
own recipe for adding vocabulary mid-session is precisely this. No reconnect, no #167-style
asymmetry: a vocabulary or prompt edit can bind at the next Utterance by pushing one event on the
warm connection — even cheaper than the read-at-use pattern `backtrack`/`vocabulary` follow, since
the config is pushed once per *edit* rather than read per *use*. The `ParamsProvider`
re-read-at-reconnect seam (`src/session.zig:192`) stays as the fallback binding path; re-bias adds
a push path beside it.

Engineering guardrails from the docs: (1) send re-bias updates between Utterances, not mid-append
— the config/buffer timing boundary is the one undocumented gap; (2) always emit every lever
(empty string/array, never omitted) so partial-merge semantics can't resurrect a cleared bias;
(3) sanitize keywords for `<` `>` CR LF and keep prompts short — both are documented
whole-update-rejection triggers; (4) tag updates with `event_id` and keep one in flight, because
errors echo the `event_id` but `session.updated` doesn't. What #312 must still verify live: the
apply-boundary relative to append/commit, whether `session.updated` echoes `keywords`, and that a
rejected update really leaves the old config running.

## Sources

- [Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)
  ([raw markdown](https://developers.openai.com/api/docs/guides/realtime-transcription.md)) — the
  "Add transcription context" section: mid-session update instruction, rejection triggers,
  language-code formats.
- [Realtime client events reference — session.update](https://developers.openai.com/api/reference/resources/realtime/client-events#session.update)
  ([raw](https://developers.openai.com/api/reference/resources/realtime/client-events.md)) —
  any-time/any-field contract, voice/model exception, merge-and-clear semantics, `event_id`
  asymmetry.
- [Realtime server events reference — session.updated, error](https://developers.openai.com/api/reference/resources/realtime/server-events#session.updated)
  ([raw](https://developers.openai.com/api/reference/resources/realtime/server-events.md)) — ack
  semantics, recoverable-error prose, the stale response-schema echo shape.
- [Realtime conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations)
  ([raw](https://developers.openai.com/api/docs/guides/realtime-conversations.md)) — "Most session
  properties can be updated at any time", `session.updated` carries "the new state of the session".
- openai-python `src/openai/types/realtime/`:
  [`session_update_event.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/session_update_event.py),
  [`session_updated_event.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/session_updated_event.py),
  [`audio_transcription.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/audio_transcription.py),
  [`realtime_transcription_session_create_request.py`](https://github.com/openai/openai-python/blob/main/src/openai/types/realtime/realtime_transcription_session_create_request.py).
- openai-node
  [`src/resources/realtime/realtime.ts`](https://github.com/openai/openai-node/blob/master/src/resources/realtime/realtime.ts)
  — `SessionUpdateEvent` / `SessionUpdatedEvent` (matching union), legacy
  `TranscriptionSessionUpdate`.
- [API changelog](https://developers.openai.com/api/docs/changelog) — 2026-07-28 release entry for
  `gpt-live-transcribe` / `gpt-transcribe` context.
