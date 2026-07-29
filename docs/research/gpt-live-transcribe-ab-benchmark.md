# A/B benchmark — `gpt-live-transcribe` vs `gpt-realtime-whisper` on real dictation (issue #298)

Measured 2026-07-29 against the live Realtime API through the **production daemon** —
real hold-to-talk dictation (this user's voice, mic, and vocabulary), resolving the
wayfinder ticket
[A/B gpt-live-transcribe vs gpt-realtime-whisper on real dictation](https://github.com/dbgeek/type-wave/issues/298)
(map #296). Config-only per issue #11's design intent: no daemon code changed; the model
was swapped by hand-editing `config.zon` and restarting the LaunchAgent. Companion to
`gpt-live-transcribe.md` (identity/protocol research) and `delay-tier-benchmark.md`
(#36, whose discipline this reuses — with live speech instead of synthetic fixtures).

**Verdict: no accuracy landslide either way.** Pooled WER is a near-tie (0.146
`gpt-live-transcribe` vs 0.157 `gpt-realtime-whisper`). The new model is clearly better
on the technical-vocabulary lines and clearly worse on the quiet-speech line, and it
pays ~130ms more commit→Final latency — while streaming its Partial Transcripts
noticeably earlier and denser. The switch decision (#299) is a judgment call on which
axes matter, not a slam dunk; the raw numbers are below.

## Method

- **Utterance set**: five reference lines, each dictated twice per model (10 holds per
  model, 20 total), read from a script so WER is computable (word-level Levenshtein,
  lowercased, hyphens split, punctuation stripped — same normalization as #36):
  1. short command — "Merge the pull request and close the issue."
  2. everyday prose — "I'll be home around seven, so can you order dinner from the usual place tonight?"
  3. technical prose + numbers — "The Zig daemon streams twenty-four kilohertz audio over the websocket, commits on release, and inserts the final transcript at the cursor."
  4. config jargon — "Set the delay tier to low, bump the timeout to fifteen hundred milliseconds, and rerun zig build test."
  5. quiet speech — "The quiet benchmark sentence checks whether soft speech still transcribes correctly." — deliberately spoken softly (the axis #36 flagged: its quiet fixture is where `minimal` turned "benchmark" into "bank market").
- **Config**: both rounds ran `.language = ""` (auto-detect — the symmetric setup the
  research addendum prescribed, since `gpt-live-transcribe` rejects the singular
  `language` field the daemon emits) and `.log_transcripts = true`; everything else at
  the user's production values (`delay = "low"`, `noise_reduction = .near_field`,
  `insertion = .keystroke`, backtrack on but unused). Round A `gpt-realtime-whisper`,
  round B `gpt-live-transcribe`, one Transcription Session per round.
- **Capture**: timings from the daemon log's release-anchored lines (`released`,
  `committed (+Nms after release)`, `FINAL (+Nms after release)`, first `partial`).
  Transcript *words* came from the dictation target document, not the log: Secure Event
  Input was held throughout (Claude/Chrome/ghostty/TextEdit trading it), so the #286
  posture redacted every transcript to a byte count despite `.log_transcripts = true`.
  The inserted text in the scratch TextEdit document was recovered per take and
  hand-split (splits validated against the logged FINAL byte counts, all within ±5
  bytes of punctuation/spacing drift).
- **As-spoken adjustment**: all four takes of line 2, across both models, agree the
  speaker actually said "I will … so you can …" rather than the script's "I'll … so can
  you" — line 2 is scored against the as-spoken rendition (same reference for both
  models).

## Results

Per-take (line.take; latencies in ms; `1st-partial` is relative to hold-start, see caveats):

| | WER `whisper` | WER `live` | commit→final `whisper` | commit→final `live` | 1st-partial `whisper` | 1st-partial `live` |
|---|---|---|---|---|---|---|
| 1.1 | 0.000 | 0.250 | 464 | 702 | 2644 | 2841 |
| 1.2 | 0.000 | 0.000 | 576 | 722 | 2066 | 1415 |
| 2.1 | 0.062 | 0.000 | 448 | 506 | 2730 | 1297 |
| 2.2 | 0.188 | 0.062 | 567 | 684 | 2397 | 1214 |
| 3.1 | 0.318 | 0.182 | 458 | 721 | 1942 | 1408 |
| 3.2 | 0.409 | 0.182 | 584 | 636 | 1600 | 1386 |
| 4.1 | 0.278 | 0.167 | 554 | 822 | 1722 | 2810 |
| 4.2 | 0.222 | 0.167 | 601 | 748 | 1421 | 2221 |
| 5.1 | 0.091 | 0.273 | 630 | 618 | 2419 | 2514 |
| 5.2 | 0.000 | 0.182 | 582 | 695 | 1627 | 1408 |

Pooled (10 takes per model):

| | `gpt-realtime-whisper` | `gpt-live-transcribe` |
|---|---|---|
| WER mean | 0.157 | **0.146** |
| commit→final median | **572ms** | 698ms |
| release→final median | **745ms** | 880ms |
| first-partial median | 2004ms | **1412ms** |

Per-line WER (mean of both takes):

| line | `whisper` | `live` |
|---|---|---|
| 1 short command | **0.000** | 0.125 |
| 2 everyday prose | 0.125 | **0.031** |
| 3 technical prose | 0.364 | **0.182** |
| 4 config jargon | 0.250 | **0.167** |
| 5 quiet speech | **0.045** | 0.227 |

## Reading, per the ticket's axes

- **Word error rate: a wash overall, but the errors have different shapes.** The new
  model halves whisper's WER on the technical lines — whisper produced "Zig dayman",
  "Sick demonsream", "commits an unreleased", "return sigbuild test"; the new model's
  worst on the same lines was "sick demon streams"/"SIGDemon" and it *nailed* "rerun
  zig build test" once (whisper never did). Both butcher "final transcript" → "final
  transcribe" (4/4 takes each — a shared miss on this speaker). But the new model
  fumbled one short-command take badly ("Much the put request") where whisper was
  2-for-2 perfect.
- **Quiet-speech accuracy: the new model regressed.** Line 5 soft-spoken: whisper
  0.045 mean WER (one perfect take), live 0.227 — "checks whether" became "shook
  whatever"/"checks whatever" in both takes. Secondary coverage had claimed better
  noise robustness; on this mic and this speaker's soft voice, the opposite showed.
  n=2, but it is the one axis where the models cleanly diverge in whisper's favor.
- **First-delta latency: the new model streams earlier and denser.** Median first
  partial 1412ms vs 2004ms after hold-start, and its partial cadence in the log is
  visibly tighter. This anchor includes the speaker's pre-speech pause (see caveats),
  but the direction matches the model's "low-latency deltas" positioning — live
  Partial Transcript feedback in the HUD starts sooner.
- **Commit→Final latency: the new model is ~125ms slower.** Median 698ms vs 572ms
  (release→final 880ms vs 745ms). Every take but one was slower; worst 822ms vs
  whisper's worst 630ms. For the insertion-at-cursor moment this is a real, if small,
  regression — about three times the delta the whole `minimal`-vs-`low` tier fight
  (#36) was worth.
- **Protocol fit, verified live**: the daemon's exact `formatSessionUpdate` payload
  with `model = "gpt-live-transcribe"`, `delay: "low"`, omitted language, and
  `noise_reduction: near_field` was accepted — `session.updated → READY`, no error
  event. That closes the research note's open question 2 (the stale SDK docstring
  claiming `delay` is whisper-only is wrong) and confirms deltas, manual commit, and
  event shapes all behave identically end to end.
- **Auto-detect leaked Swedish orthography once**: take 4.2 on the new model opened
  with "Sätt delay tire to low…" ("sätt" = Swedish "set" — this speaker's accent).
  Production pins `.language = "en"`, but the new model rejects that singular field —
  so a switch *without* the `languages: ["en"]` formatter change doesn't just lose a
  knob, it demonstrably costs accuracy for this user. The config-only path is fine for
  benchmarking, not for daily use.

## Caveats

- **n=2 per cell, one session per model, one evening, one mic.** Real speech, so no
  two takes are byte-identical — rendition variance is folded into every number.
  Treat per-line WER as directional, not precise; the pooled near-tie is the robust
  read.
- **First-partial latency is anchored at hold-start**, not speech onset, so it
  includes the speaker's variable pre-speech pause. The 4.x takes show the confound
  (live's 2810ms first partial on a line whisper started in 1722ms). The median gap
  (~600ms) is larger than plausible onset variance, so the direction stands.
- **Rounds were sequential, not interleaved** (config toggle needs a daemon restart),
  so server-side conditions could drift between rounds; #36 saw run-to-run latency
  noise of the same order as the gap measured here.
- Transcripts were recovered from the insertion target document because Secure Event
  Input redacted the log; hand-splitting takes was validated against FINAL byte counts
  but punctuation-level drift (±5 bytes) is possible. WER is word-level, so this is
  sub-error-bar.
- The new model's vocabulary levers (`prompt`/`keywords`) — its headline advantage for
  type-wave — were **not exercised**: they need `session.zig` formatter work first.
  These numbers are the *floor* of what a switch buys.

## What this feeds

The decision ticket
[Decide: switch the OpenAI default model to gpt-live-transcribe or stay](https://github.com/dbgeek/type-wave/issues/299)
is now unblocked: near-tie WER with better jargon / worse quiet speech, ~125ms slower
Finals, earlier Partials, protocol confirmed compatible, and the `languages` formatter
change established as a prerequisite for any switch that keeps a pinned language.
