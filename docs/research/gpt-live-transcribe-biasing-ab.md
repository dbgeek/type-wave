# A/B benchmark — do `keywords` / `prompt` biasing help, and do they leak? (issue #313)

Measured 2026-07-29 against the live Realtime API, resolving the wayfinder ticket
[A/B benchmark: do keywords/prompt biasing help real dictation, and do they leak?](https://github.com/dbgeek/type-wave/issues/313)
(map #310). Companion to `gpt-live-transcribe-biasing-limits.md` (#312, what the server
accepts) and `session-update-rebias.md` (#311, when a re-bias binds) — those two settled
the *mechanics*; this one settles whether the levers are worth wiring at all.

**Verdict: `keywords` is the entire effect, and it is large.** Canonical-term recall goes
**40% → 92%** and WER **0.199 → 0.049** when the vocabulary is passed as `keywords`. The
free-text `prompt` alone is worth **nothing** for vocabulary — it scores identically to
bare (40% recall, WER 0.202) — and adds nothing on top of `keywords`. **Leakage does not
occur**: across 144 no-speech turns, silence and noise returned empty transcripts in every
arm, with no vocabulary or prompt text emitted. The `gpt-4o-mini-transcribe` failure mode
field-reported in `vocab-openai-transcription-prompt.md` did not reproduce on this model.

## Method

Harness `prototypes/openai-biasing-probe/ab.py`, reusing `probe.py`'s websocket client and
session helpers. Unlike the #298 A/B (live hold-to-talk through the production daemon),
this one replays **fixed audio**: jargon recognition turns on a handful of words, so
re-dictating each arm would let utterance-to-utterance variation swamp the lever effect.
Every arm hears byte-identical audio; the biasing config is the only thing that varies.

- **Arms** — four, each a fresh connection with one `session.update` at the top:
  `bare` (no biasing) · `keywords` (the 12-term vocabulary) · `prompt` (scene-setting text)
  · `both`. All four carry `model = gpt-live-transcribe`, `languages = ["en"]`,
  `delay = "low"`.
- **Content corpus** — six lines dictated as a human would say them, scored against the
  canonical *written* form. The two differ deliberately: spoken "whisper dot C P P" should
  land as `whisper.cpp`. Recovering that canonical form is exactly what the levers are
  being asked to do.
- **Metrics** — two. **WER** uses the #36 / #298 normalization (lowercased, hyphens split,
  punctuation stripped) so the numbers are comparable with the earlier notes. **Canonical-term
  recall** is the metric that answers the ticket: an exact, case-insensitive string match of
  each target term in the raw transcript, so `type wave` and `typewave` are *misses* against
  `type-wave`. WER's normalization is blind to precisely the orthography the vocabulary
  feature exists to fix, which is why recall is reported alongside it.
- **Vocabulary** (the `keywords` value) — `type-wave`, `whisper.cpp`, `Zig`, `Bjorn`,
  `config.zon`, `LaunchAgent`, `wayfinder`, `ghostty`, `CoreAudio`, `Secure Event Input`,
  `PCM`, `segmenter`. Twelve terms, a plausible production list, including some that appear
  in no clip (real vocabularies always carry unused entries).
- **Prompt** — scene-setting only, **no term list**: *"This is dictation from a software
  engineer working on a macOS dictation daemon written in Zig… Transcribe technical terms,
  file names, and command-line invocations in their canonical written form."* Keeping the
  two channels carrying different *information* is what makes their contributions
  separable; whether echoing the vocabulary into the prompt helps is a distinct question
  (see [Consequences](#consequences)).
- **Leak corpus** — six no-speech-or-near-silence clips: 3s and 8s of digital silence,
  3s of low-level noise (amplitude 400, room-tone level) and loud hiss (amplitude 3000),
  and two one-word utterances ("Yes." / "Okay.") as very-short-utterance provocations.
- **Volume** — 5 repeats × 4 arms × 6 lines = 120 content turns; 3 repeats × 4 arms × 6
  clips = 72 leak turns. Run twice (see the voice caveat), 384 turns total.
- **Audio** — macOS `say`, pinned to **`-v Samantha` (en_US)**, mono 24 kHz 16-bit LE.

### The voice caveat — read this before trusting any synthetic ASR benchmark

The first full sweep used `say`'s *machine-default* voice (this Mac has no
`com.apple.speech.voice.prefs` set). It produced a materially different and **wrong**
picture: `wayfinder` was unrecoverable in all four arms (0/20, transcribed "Revive",
"Before find", "Revar find"), and `both` looked meaningfully *worse* than `keywords`
(WER 0.152 vs 0.093, recall 72% vs 78%).

Both effects were artifacts of the voice, not facts about the model. A control run with
`-v Samantha` recovered `wayfinder` perfectly **even bare**. Re-running the whole sweep on
the pinned voice erased the `both`-is-worse gap (0.044 vs 0.049 — a tie). The default-voice
numbers are kept in the appendix as a robustness check — the `keywords` effect survives
both voices, which is the one thing that mattered — but every conclusion below is drawn
from the Samantha pass.

The general lesson for this repo: **a synthetic-audio ASR benchmark must pin its voice**,
and an unintelligible-to-the-model rendition looks exactly like a model failure.

## Results — efficacy

Pooled over 30 turns per arm (5 repeats × 6 lines); recall over 60 term-attempts per arm:

| arm | WER | canonical-term recall |
|---|---|---|
| `bare` | 0.199 | 24/60 (40.0%) |
| **`keywords`** | **0.049** | **55/60 (91.7%)** |
| `prompt` | 0.202 | 24/60 (40.0%) |
| `both` | 0.044 | 53/60 (88.3%) |

Per term (hits / attempts, 5 each):

| term | `bare` | `keywords` | `prompt` | `both` |
|---|---|---|---|---|
| `Bjorn` | 0/5 | **5/5** | 0/5 | **5/5** |
| `CoreAudio` | 0/5 | **5/5** | 0/5 | **5/5** |
| `LaunchAgent` | 0/5 | **5/5** | 0/5 | **5/5** |
| `config.zon` | 0/5 | **5/5** | 0/5 | 4/5 |
| `whisper.cpp` | 0/5 | **5/5** | 0/5 | 4/5 |
| `ghostty` | 0/5 | **5/5** | **5/5** | **5/5** |
| `wayfinder` | 4/5 | **5/5** | 0/5 | **5/5** |
| `type-wave` | 0/5 | **0/5** | 0/5 | **0/5** |
| `PCM` | 5/5 | 5/5 | 5/5 | 5/5 |
| `Secure Event Input` | 5/5 | 5/5 | 4/5 | 5/5 |
| `segmenter` | 5/5 | 5/5 | 5/5 | 5/5 |
| `zig build test` | 5/5 | 5/5 | 5/5 | 5/5 |

Four readings:

1. **`keywords` carries the whole effect, and it is close to total.** Every term that bare
   never got — `Bjorn`, `CoreAudio`, `LaunchAgent`, `config.zon`, `whisper.cpp`, `ghostty` —
   goes 0/5 → 5/5. It reliably imposes camelCase joining (`CoreAudio`, `LaunchAgent`),
   embedded punctuation (`whisper.cpp`, `config.zon`), and unusual proper nouns (`Bjorn`,
   `ghostty`). This is not a subtle nudge; it is the difference between unusable and correct
   on exactly the words a custom vocabulary exists for.
2. **The scene-setting `prompt` is worth nothing for vocabulary.** Identical pooled recall
   to bare (24/60), WER a dead heat (0.202 vs 0.199). It is not inert — it flips individual
   terms in both directions (`ghostty` 0/5 → 5/5, but `wayfinder` 4/5 → 0/5, rendered
   "WaveFinder"/"Wavefinder") — but the flips cancel. Telling the model *about* the domain
   does not make it spell the domain's words.
3. **`bare` + `prompt` degrading `wayfinder` is the sharpest warning.** A prompt that
   describes the domain in prose can *push a term the model already had* into a plausible
   neighbouring spelling. The lever has a downside with no matching upside.
4. **`both` ≈ `keywords`.** WER 0.044 vs 0.049, recall 53/60 vs 55/60 — a two-attempt
   difference across 60, inside run-to-run noise. There is no measurable interaction in
   either direction. The prompt neither helps nor meaningfully harms once `keywords` is
   present.

### The one systematic `keywords` failure: `type-wave`

`type-wave` is **0/20 across every arm**, despite sitting in the `keywords` list. The model
hears it correctly and writes it wrong — `typewave` (12 of 20) or `type wave` (7 of 20),
never `type-wave`. Contrast `whisper.cpp` and `config.zon`, where `keywords` imposes the
punctuation perfectly.

The distinguishing feature is that `type-wave`'s components are two ordinary English words
that form a plausible compound on their own, so the language-model prior over `typewave` /
`type wave` is strong and the keyword is not a hard constraint. `keywords` is a **bias, not
a lexicon override** — it reweights, and a sufficiently strong prior can still win. Terms
whose components are not independently plausible English (`config.zon`, `ghostty`) have no
competing prior and flip cleanly.

Practical consequence: the feature will be visibly imperfect on exactly the term the product
is named after, and a user adding a hyphenated common-word compound to their vocabulary
should not expect the hyphen to be honoured. This is a **model** limit, not a client one —
nothing in the daemon's control (budget, ordering, escaping) can fix it.

## Results — leakage

72 no-speech turns per pass, 144 across both. **Zero leakage under every provocation.**

| arm | non-empty transcripts | vocabulary leaked | prompt words leaked |
|---|---|---|---|
| `bare` | 6/18 | 0 | 0 |
| `keywords` | 6/18 | 0 | 0 |
| `prompt` | 6/18 | 0 | 0 |
| `both` | 6/18 | 0 | 0 |

Every silence clip (3s, 8s) and every noise clip (room-tone and loud hiss) returned an
**empty** transcript in all four arms. The only non-empty results were the six genuine
one-word utterances, which transcribed correctly as `'Yes,'` and `'Okay,'` — identically in
all four arms, with no config text appended.

The 6/18 non-empty count is therefore exactly the six real utterances: 3 repeats × 2 clips.
No arm hallucinated a single word into silence or noise.

This is a clean negative on the failure mode that motivated the ticket. The leakage
field-reported on `gpt-4o-mini-transcribe` — prompt text emitted during silence — **does not
reproduce on `gpt-live-transcribe`** with either lever, at either amplitude, at either
duration.

## Consequences

For the map's open questions:

- **Which lever ships?** `keywords`, unambiguously. It delivers the feature. The free-text
  `prompt` is a null result for vocabulary and carries a demonstrated downside
  (`wayfinder` → `WaveFinder`) — its case now has to rest on something other than term
  recognition (tone, formatting, punctuation style), which this benchmark did not test and
  which the setting's design should not assume.
- **Do the levers interact?** No. `both` is statistically indistinguishable from `keywords`.
  The map's fogged "echo vocabulary into the prompt if `keywords` underperforms" question is
  **moot on its own premise** — `keywords` does not underperform.
- **Is a leakage guard needed?** No. There is nothing to guard against; a downstream filter
  would be dead code. This should be recorded as a decision so it is not re-litigated at
  build time.
- **Keywords budget** — this benchmark ran 12 terms comfortably. It says nothing about where
  a budget should sit (#312 established the server accepts ~262 KB without complaint), but it
  does establish that a realistic 12-term list is fully effective, so any budget policy is
  about pathological inputs, not about the normal case.

## Reproducing

```sh
python3 prototypes/openai-biasing-probe/ab.py content --repeats 5 --out ab-results
python3 prototypes/openai-biasing-probe/ab.py leak    --repeats 3 --out ab-results
python3 prototypes/openai-biasing-probe/ab.py score   --out ab-results
```

`--voice ''` reverts to the machine-default voice (the confounded first pass).
`--audio-dir DIR` replays human-recorded `L1.wav`…`L6.wav` instead of synthesized clips —
arms, ordering, and scoring are otherwise identical, so the passes are directly comparable.
`prototypes/openai-biasing-probe/record.swift` records that corpus in a human voice at the
required format (mono 24 kHz 16-bit LE).

## Appendix — the confounded default-voice pass

Kept as a robustness check only; see [the voice caveat](#the-voice-caveat--read-this-before-trusting-any-synthetic-asr-benchmark).

| arm | WER | canonical-term recall |
|---|---|---|
| `bare` | 0.449 | 16/60 (26.7%) |
| `keywords` | 0.093 | 47/60 (78.3%) |
| `prompt` | 0.357 | 24/60 (40.0%) |
| `both` | 0.152 | 43/60 (71.7%) |

The `keywords` effect (27% → 78% recall, WER −79%) survives a materially harder and partly
unintelligible rendition, which is the only thing this pass is offered as evidence for. Its
`both`-is-worse gap and its total `wayfinder` failure did **not** survive voice pinning and
should not be cited.

## Scope — synthesized speech only, deliberately

Everything above is `say`-synthesized audio. The ticket's brief called for real dictation,
and a confirmation pass on the author's own voice and mic was built (`--audio-dir`, via
`record.swift`) but **consciously not run**: the 40% → 92% recall gap is far too large to
invert, and the decisions waiting on this benchmark (which lever ships, whether a leakage
guard is needed) turn on its direction, not its magnitude.

What that leaves unmeasured, should it ever matter:

- **The size of the `keywords` win on real speech.** TTS articulates jargon more cleanly
  than a human does, so this pass most likely *understates* the recovered headroom — but
  that is an argument, not a measurement.
- **Leakage under real-world non-speech.** The provocations here were digital silence and
  synthetic noise. Real room tone, keyboard clatter, and half-swallowed false starts are a
  harder test, and the clean zero should be read as "does not reproduce under deliberate
  provocation" rather than "cannot happen".
- **`type-wave`'s hyphen** under a human's own pronunciation of the compound.

The harness takes real audio unchanged (`--audio-dir DIR` with `L1.wav`…`L6.wav`), so any
of these can be answered later without rebuilding anything.
