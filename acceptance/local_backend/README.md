# Local-backend release gate

This directory contains the deterministic release gate for **Local — KB Whisper Small**.
It implements `ACCEPT-1` through `ACCEPT-14` from
[`docs/local-kb-whisper-backend.md`](../../docs/local-kb-whisper-backend.md) and issue #69.
Every check is release-blocking; the JSON report never averages one category into another.

The harness uses only the Python standard library. Enter the pinned development environment
before running it:

```sh
nix develop
zig build acceptance-test # tests plus strict static type checking
python3 acceptance/local_backend/gate.py \
  --manifest path/to/corpus-manifest.json \
  --evidence path/to/candidate-evidence.json \
  --report path/to/release-report.json
```

Exit status is `0` for a passing candidate, `1` for measured gate failures, and `2` for an
invalid manifest/evidence contract. Output and reports contain no wall-clock timestamp or
machine-specific path, so identical inputs produce byte-identical evidence. A report contains
fixture IDs, modes, scores, timings, and operational probe results, but never audio or Final
Transcript content.

## Fixture manifest

The manifest root has `schema_version: 1`, corpus identity/licensing facts, and `fixtures`:

```json
{
  "schema_version": 1,
  "corpus": {
    "id": "local-kb-whisper-human-v1",
    "human_speech": true,
    "redistributable": true,
    "license": "SPDX license identifier or distribution grant"
  },
  "fixtures": []
}
```

The corpus
must be redistributable human speech. The gate requires exactly two English and two Swedish
speakers, ten Utterances per language, and balanced `short`, `medium`, and `long` duration
classes. Every fixture runs once in its explicit language and once in `auto` mode.

Each fixture has this shape:

```json
{
  "id": "en-speaker-1-01",
  "audio": "audio/en-speaker-1-01.wav",
  "audio_sha256": "64-lowercase-hex-characters",
  "speaker_id": "en-speaker-1",
  "language": "en",
  "language_modes": ["en", "auto"],
  "exact_final_transcript": "Do not delete 42 files!",
  "duration_seconds": 3.2,
  "duration_class": "short",
  "punctuation": true,
  "tags": ["command", "numbers", "negation"],
  "protected_semantics": [
    {"kind": "negation", "text": "not"},
    {"kind": "number", "text": "42"},
    {"kind": "command", "text": "delete"}
  ]
}
```

Across the corpus, tags must also cover `technical-term`, `proper-noun`, and
`self-correction`. The gate reads every audio path relative to the manifest, rejects paths that
escape that directory, and verifies `audio_sha256` before scoring. Synthetic fixtures are useful
for harness tests, but a synthetic corpus must not be presented as release evidence.

## Candidate evidence

Evidence has `schema_version: 1` and five sections:

- `candidate` identifies the immutable model revision, exact byte count and digest, plus
  `whisper.cpp-v1.9.1` and its pinned source-archive digest.
- `transcription_runs` contains one row per fixture/mode with the observed `final_transcript`,
  explicit `meaning_changing_errors`, and exactly three warmed `latency_ms` measurements.
- `performance` records the base-M1 machine, cached and first-Metal readiness, warmed idle and
  inference peak RSS, and the forced-overrun trace.
- `privacy` points to digest-bound probe artifacts for credential removal,
  disabled-network/offline completion, helper socket and daemon request counts, content scans of
  default logs, and the isolated Model Operation. The gate derives observations from those files.
- `fault_probes` names every deterministic scenario and points to its relative trace path plus
  SHA-256 digest. The gate verifies and parses each trace, then derives pass/fail from its named
  assertions. Traces contain operational state/events only—never PCM or Final Transcript.

The required fault names and scenario-specific assertions are `REQUIRED_FAULT_ASSERTIONS` in
[`gate.py`](gate.py). The names deliberately match the public lifecycle behaviors from the
acceptance decision: success and empty paths; helper loss/crash/malformed IPC/inference faults;
restart/latch/reset; both cancellation paths and the terminal race; stale events and non-idle
presses; drain-then-switch; prerequisite loss and recovery; and side-effect-free abandonment.

Raw observations should be captured by the system test or deterministic contract test that owns
the relevant boundary, then serialized into this contract. The release owner must retain those
raw artifacts beside the candidate evidence. Do not manufacture booleans after a run: the JSON
is the stable interchange format, not a substitute for instrumentation.

## Scoring

WER uses Unicode NFKC case-folded word tokens with punctuation removed and word-level
Levenshtein distance. Corpus scores are micro-averaged (total edits / total reference words) for
explicit English, explicit Swedish, English-in-auto, and Swedish-in-auto. Per-Utterance WER is
also reported.

Punctuation F1 covers `. , ? ! : ;`. A mark is matched only when both the mark and its position
after the same reference word count agree, preserving placement rather than scoring a bag of
marks. Protected negation, number, and command phrases must remain present after word
normalization, and each run records any manually reviewed `meaning_changing_errors`. Proper
names and technical terms affect WER but have no separate threshold.

Thresholds are fixed in `gate.py`: 15% explicit WER, 20% auto WER per language, 40% maximum
per-Utterance WER, 0.75 punctuation F1, zero protected errors; 2 seconds warmed latency/cached
readiness, 15 seconds first Metal preparation, 600/750 MiB idle/peak RSS; cancellation requested
at 9.5 seconds and forced termination by 10 seconds; and zero privacy/lifecycle violations.
