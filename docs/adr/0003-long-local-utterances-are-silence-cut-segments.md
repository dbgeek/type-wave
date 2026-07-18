# ADR 0003 — Long local Utterances are transcribed as silence-cut Segments

- Status: accepted (2026-07-18; issue #92, part of map #1)
- Supersedes: the fixed 15 s local-Utterance cap (`max_pcm_len`), which discarded any
  longer hold outright

## Context

The local Whisper Backend buffered a whole Utterance in memory and hard-capped it at 15 s
of audio (`max_pcm_len` = 24 kHz × 2 bytes × 15 s). A hold past that returned
`CaptureTooLong` on the next Capture append; the daemon reported a backend failure, the
Utterance Coordinator poisoned the Utterance, and on release the whole thing was
discarded with nothing inserted — surfaced only as a log line, so a long sentence
silently "did not work."

The OpenAI Backend streams audio over the live Transcription Session and never
accumulates into that bounded buffer, so long holds already worked there. The cap was
local-only, and the asymmetry is what a user hit and reported.

Two obvious fixes were rejected up front:

- **Raise the cap.** Only moves the wall and trades helper RAM against inference latency;
  a long enough hold still falls off it.
- **Stream like OpenAI.** Local Whisper (`ggml-large-v3-turbo`) is not a streaming model
  — it transcribes a complete audio span, so it cannot emit a running transcript the way
  the Realtime API does.

Turbo runs ~7× faster than real time on the base M1 (the #63 2 s target / 10 s hard cap),
which is what makes transcribing pieces of an Utterance *while it is still being spoken*
viable at all.

## Decision

A long local Utterance is cut into **Segments** and transcribed in the background, then
assembled into one Final Transcript on release.

- **Segmentation is silence-cut.** Accumulate Capture to a **15 s soft floor**; past it,
  cut a Segment at the **next ≥400 ms pause**, detected from the RMS level Capture
  already computes per 50 ms buffer. If no pause comes, **force-cut at a 25 s hard max**
  (the only case that can split a word). A cut at silence keeps whole phrases together —
  what Whisper is built to transcribe — and structurally avoids the split-word "garbled
  seam" that fixed-interval or overlap-and-stitch cutting produce. A short Utterance is a
  single Segment.
- **Transcription is sequential.** Completed Segments go through a **FIFO queue**, one at
  a time, in spoken order. The single-slot inference gate is unchanged; because inference
  outpaces speech the queue stays shallow.
- **Insertion is batched on release.** Nothing is inserted mid-Utterance. On release the
  trailing Segment is flushed, the queue drained, and the Segment Transcripts
  concatenated in spoken order into the **Final Transcript**, inserted once through the
  existing path. Only a Final Transcript ever reaches the cursor (unchanged invariant).
- **Failure is all-or-nothing.** If any Segment fails, the whole Utterance is discarded
  and nothing is inserted, with a specific "part of that was lost — say it again" signal.
  The Coordinator's existing poison/abandon path realizes this.
- **The deadline bounds the drain.** The release-anchored deadline now covers the
  post-release drain (trailing Segment + queued Segments) rather than one transcription,
  raised to ~12–15 s. An overrun fails the whole Utterance loudly.

## Consequences

- **Local Utterance length is unbounded** in practice; `max_pcm_len` becomes a per-Segment
  bound, not a per-Utterance ceiling.
- **Short Utterances are unchanged** — one Segment, one submit, one Insertion — so the
  common case carries no new risk and is regression-guarded.
- **The helper IPC now carries many Segments per Utterance**, reassembled in submission
  order (a Segment sequence/index on the frames, or ids derived from the Utterance id).
- **Two new domain terms** — Segment and Segment Transcript (`CONTEXT.md`). `Partial
  Transcript` is untouched: it stays the revisable OpenAI delta, which a Segment
  Transcript is not.
- **The all-or-nothing contract is preserved.** As with poison-on-drop today, the user
  gets their complete text or nothing plus a clear retry cue — never a silently gapped
  Insertion into a live document.
- **A slower-than-M1 host can back the queue up** enough that the release drain blows the
  deadline on a very long hold; that Utterance fails loudly. Accepted as a rare tail case
  on unsupported hardware.

Rejected alternatives, recorded so a future review does not silently re-adopt them:
raise-the-cap (moves the wall), overlap-window / prompt-conditioning segmentation (fuzzy
text stitching, doesn't structurally prevent split words), parallel multi-context
inference (RAM cost, pointless when sequential keeps pace), progressive live insertion
(dangerous — bursts land in whatever field has focus, and typed text can't be retracted),
and gap-fill best-effort insertion (silent document corruption).

A future review should not "restore" the fixed cap, nor add progressive insertion,
without re-reading this record: unbounded length was delivered by background segmentation
on purpose, and batched all-or-nothing Insertion was chosen over progressive/gap-fill on
purpose.
