# CLI dictation prototype — the question

**Throwaway prototype** for wayfinder ticket #8 ("Prototype the CLI dictation loop").
Delete or graduate once the question below is answered.

## Question

Is the end-to-end dictation pipeline real?

    mic → CoreAudio AudioQueue (24 kHz mono s16le) → OpenAI Realtime
    Transcription Session (gpt-realtime-whisper, manual commit, over vendored
    karlseguin/websocket.zig) → live Partial Transcripts → one Final Transcript
    per Utterance

Specifically:

1. Does accurate final text come back, with acceptable latency?
2. Does whisper-quiet speech transcribe? (product goal — see the map's fog)
3. Do the three crib sheets' assumptions hold when wired together live? Notably:
   - **Open Q1 (OpenAI crib sheet):** do Partial Transcripts stream *while the
     Talk Key is held*, or only between commit and completed? (Watch the event
     timestamps this prototype prints.)
   - **Open Q3:** what does a very short commit do?
   - **Open Q5 (CoreAudio crib sheet):** does `AudioQueueStop(immediate=true)`
     clip the tail of the last word?
   - Does the §3.5 websocket TLS-read fix hold up over a real streaming session?

## How to run

    cd prototypes/cli-dictation
    zig build run          # inside `nix develop`, so OPENAI_API_KEY is exported

ENTER starts/stops an Utterance (stand-in for the Talk Key). The first start pops
a macOS microphone-permission dialog attributed to your terminal — grant it, then
start a fresh Utterance. `q` + ENTER quits.

## Structure

- `src/audio.zig` — CoreAudio Capture (portable; graduation candidate)
- `src/session.zig` — OpenAI Transcription Session over websocket (portable; graduation candidate)
- `src/main.zig` — terminal shell wiring the two (throwaway)
- `vendor/websocket.zig` — karlseguin/websocket.zig `dev` @ 4b475a8 (plain upstream; §3.5 fix now upstream)

## Verdict (2026-07-08)

**Yes — the end-to-end pipeline is real.** Two live runs against
`gpt-realtime-whisper` transcribed normal speech accurately with acceptable
latency, e.g. _"This is the second test. How it works. See if it gets some
errors or warnings."_ (8.0s audio), clean, no errors.

- **Accuracy:** clean on normal-volume speech across two utterances (only minor
  word slips). **Whisper-quiet speech: not exercised yet** — stays on the map's
  fog ("Whisper-quiet speech quality").
- **Latency:** first Partial Transcript ~1.4–2.2s after Utterance start; the
  Final Transcript lands ~0.5s after commit (Talk Key release). Acceptable.
- **Open Q1 (partials during hold) — RESOLVED: YES.** Partial Transcripts stream
  continuously _while the key is held_, well before commit. Live feedback during
  the hold is possible (input to the daemon UX, #10).
- **Open Q2 (connect URL) — RESOLVED.** A Transcription Session's type is fixed
  at connect: you cannot reconfigure a realtime session to transcription via
  `session.update` ("Passing a transcription session update to a realtime
  session is not allowed"). The working connect is
  `wss://api.openai.com/v1/realtime?intent=transcription` — with the GA
  `session.update` shape and **without** the `OpenAI-Beta` header (better than
  the crib sheet feared). `?model=<realtime>` opens a realtime session (wrong for
  us); `?model=gpt-realtime-whisper` is rejected outright.
- **Open Q5 (tail clip) — not observed.** `AudioQueueStop(immediate=true)` did
  not clip the last word; post-commit deltas completed the transcript.
- **§3.5 websocket TLS-read fix — validated live** over a full streaming session
  (the crib sheet had only tested connect with an invalid key).

Two bugs found and fixed here:

1. The AudioQueue delivers a 0-byte buffer during stop → we sent an empty
   `input_audio_buffer.append`, which the server rejects ("Invalid 'audio' ...
   empty bytes"). Fixed: drop empty chunks in `appendAudio`.
2. Quitting closed the socket fd while the read-loop thread was reading it →
   `BADF` panic (Zig's debug Io treats concurrent close as a programmer bug).
   Fixed for the CLI by exiting the process on quit; a graceful websocket close
   (close frame + drain) is daemon work (#10).

Also learned: the AudioQueue can deliver a callback outside an explicit
`AudioQueueStart`, so forwarding is gated on an `active` flag — only in-Utterance
audio is sent.

**Disposition:** code stays in `prototypes/cli-dictation/`. `src/session.zig`
(Transcription Session) and `src/audio.zig` (CoreAudio Capture) are the
graduation candidates for the real skeleton; `src/main.zig` is the throwaway
shell. What graduates, and how, is #10's call.
