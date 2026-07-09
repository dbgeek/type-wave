# Transcription `delay` tier benchmark — `minimal` vs `low` (issue #36)

Measured 2026-07-09 against the live Realtime API (`gpt-realtime-whisper`, GA websocket
endpoint), using the throwaway harness at `prototypes/cli-dictation/src/bench.zig`
(`zig build` in that prototype produces `zig-out/bin/bench`). The question, per the
crib sheet's field note (openai-realtime-transcription.md §2): the `delay` tier sets how
long the server sits on committed audio before emitting the Final Transcript — is
`minimal` a free latency win over the current `low` default?

**Verdict: no — keep `delay: "low"` as the default.** `minimal` saves only ~30–50ms
median commit→final, and pays for it with a measurably higher word error rate (pooled
0.209 vs 0.169), including semantically damaging misses on the quiet dictation fixture.
`minimal` stays available as a menu preset for anyone who wants the last few tens of
milliseconds.

## Method

- Fixtures: three audio files synthesized with macOS `say` at the session's native
  format (24kHz mono s16le WAV): a short command (1.8s), one sentence of
  dictation-flavored prose (5.7s), and two sentences of technical prose (12.7s).
  Reference text known exactly, so WER is computable (word-level Levenshtein after
  lowercasing and stripping punctuation).
- Each fixture also run at **gain 0.15 (≈ −16dB)** to simulate quiet speech — the docs
  warn lower tiers cost accuracy exactly there.
- The harness plays a fixture into a Transcription Session in 2400-byte (50ms) chunks
  paced in real time on an absolute schedule — the same shape live Capture delivers —
  then sends `input_audio_buffer.commit` and measures
  **commit→`…transcription.completed`** wall ms: the server-side share of the
  release→final latency the daemon's release-anchored timing logs measure end to end
  (release→commit on the client is a few ms and identical across tiers, so the
  comparison is unaffected).
- Everything except `delay` held at production defaults (`language: "en"`,
  `noise_reduction: near_field`, `turn_detection: null`). 5 runs (Utterances) per cell
  over one Transcription Session per cell; full matrix = 2 tiers × 3 fixtures × 2 gains
  × 5 runs = 60 runs, and every run returned a Final Transcript (ok=5/5 in all cells).

## Results

Median commit→final ms (5 runs per cell):

| fixture / gain       | `minimal` | `low` | Δ |
|---|---|---|---|
| short, full          | 761ms | 815ms | −54ms |
| medium, full         | 743ms | 776ms | −33ms |
| long, full           | 810ms | 839ms | −29ms |
| short, quiet (0.15)  | 752ms | 784ms | −32ms |
| medium, quiet (0.15) | 699ms | 897ms | −198ms |
| long, quiet (0.15)   | 857ms | 825ms | +32ms |

Mean WER (5 runs per cell):

| fixture / gain       | `minimal` | `low` |
|---|---|---|
| short, full          | 0.440 | 0.320 |
| medium, full         | 0.057 | 0.014 |
| long, full           | 0.168 | 0.174 |
| short, quiet (0.15)  | 0.280 | 0.320 |
| medium, quiet (0.15) | 0.114 | 0.043 |
| long, quiet (0.15)   | 0.194 | 0.142 |

Pooled across all 30 runs per tier: latency mean 795ms (`minimal`) vs 831ms (`low`);
WER mean 0.209 (`minimal`) vs 0.169 (`low`).

## Reading

- **The latency win is real but small.** ~30–50ms median in most cells, noise-swamped
  in others (`minimal` lost one quiet cell outright). Commit→final sits around
  700–1000ms for *both* tiers regardless of fixture length; the tier knob does not
  dominate it. The issue's hope that this was "the single biggest speak→text latency
  lever" did not survive contact: whatever `low` waits for beyond `minimal` is tens of
  ms, not hundreds.
- **The WER cost is measurable, though not confined to quiet audio.** Pooled, `minimal`
  is ~4 WER points worse, and it lost 4 of the 6 cells (the two exceptions: long/full
  was a wash, and short/quiet actually favored `minimal`). The most damaging example is
  the quiet dictation sentence, where `minimal` transcribed "benchmark" as "bank
  market" in 4/5 runs while `low` got it right in 4/5 — but the largest single gap was
  on the full-gain short command (0.440 vs 0.320), so this is a general accuracy tax,
  not purely the quiet-speech penalty the docs describe. For a tool whose Final
  Transcript lands directly at the cursor, a semantically-wrong word costs the user
  more than 40ms of latency saves.
- Per the issue's own criterion ("if WER holds up, flip the default; otherwise document
  the trade-off"): WER did not hold up. Default stays `low`.

## Caveats

- Synthetic TTS speech, not a human voice. Absolute WER numbers are inflated (both
  tiers reliably butcher the TTS rendering of "flaky retry"); the *comparison* is still
  controlled since both tiers heard byte-identical audio. Worth re-checking with real
  dictation if the default ever gets revisited.
- One machine, one evening, one region. Server-side latency distributions may shift.
- `medium`/`high`/`xhigh` were not measured — nothing suggested spending audio-minutes
  on slower tiers when the fast end already showed the trade.

## What changed because of this

- `config.zon` template comment now lists all five tiers
  (`minimal | low | medium | high | xhigh`) so `minimal` is discoverable.
- The menu bar Delay group gained a `minimal` preset (the latency escape hatch);
  `xhigh` remains hand-edit-only.
- Defaults in `src/config.zig` / `src/session.zig` deliberately stay `"low"`.
