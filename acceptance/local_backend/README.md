# Local-backend release gate

This directory contains the deterministic release gate for **Local — Whisper Large v3 Turbo**.
It implements `ACCEPT-1` through `ACCEPT-14` from
[`docs/local-backend.md`](../../docs/local-backend.md) and issue #69.
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

For a real candidate, assemble the raw transcription and operational observations, run the
complete deterministic suite once, materialize all digest-bound traces, and emit the report:

```sh
python3 acceptance/local_backend/finalize.py \
  --observations path/to/transcription-observations.json \
  --operational path/to/operational-observations.json \
  --evidence path/to/candidate-evidence.json \
  --report path/to/release-report.json
```

Finalization exits `0` for go, `1` for a valid no-go report, and `2` for an invalid contract
or failing deterministic suite.

Collect the packaged helper's raw Final Transcripts, three warmed timings per
fixture/mode, cached readiness, and helper RSS through the public IPC boundary:

```sh
python3 acceptance/local_backend/collect.py \
  --manifest path/to/corpus-manifest.json \
  --helper ~/.local/libexec/type-wave/current/type-wave-whisper \
  --daemon ~/.local/libexec/type-wave/current/type-wave \
  --model "$HOME/Library/Application Support/type-wave/models/installations/98aa99a0a9db-f16/ggml-large-v3-turbo.bin" \
  --receipt "$HOME/Library/Application Support/type-wave/models/active.receipt" \
  --provenance ~/.local/libexec/type-wave/current/share/PROVENANCE \
  --semantic-review path/to/semantic-review.json \
  --deny-helper-network \
  --diagnostics-output path/to/helper-diagnostics.log \
  --output path/to/transcription-observations.json
```

The collector hashes and validates the model, receipt, packaged provenance, paired daemon and
helper, and both code signatures. A stale receipt-to-helper binding remains visible as a gate
failure. It also rejects a helper that does not identify the pinned model, a fixture that is
not mono 24 kHz signed-16 WAV, malformed or timed-out IPC, failed inference, or a semantic
review that does not cover the exact fixture/mode set. It retains all three raw Final
Transcripts and uses the first pre-declared run for gate scoring, so a varying result cannot
be selected after observation. Timeout/privacy/lifecycle observations remain separately
retained release evidence. When `--diagnostics-output` is supplied, the full helper stderr is
retained and scanned for raw, hexadecimal, and base64 PCM chunks plus exact
reference/observed transcripts and word-boundary three-word phrases from them (shorter
runs are not markers: operational metadata legitimately contains natural-language words
and function-word pairs, while any real transcript echo discloses three or more
consecutive words); daemon diagnostics must be retained and assessed separately.

`--deny-helper-network` launches the exact hashed helper inside a macOS sandbox that denies
all network operations while leaving the collector outside that sandbox for RSS sampling.
For an instrumented qualification, compile `network_trace.c` as a dynamic library, set
`TYPE_WAVE_NETWORK_TRACE` and `DYLD_INSERT_LIBRARIES` while collecting, then run
`probe_runtime.py` with the same library and trace path. The probe launches the exact daemon
under the same network sandbox, can temporarily select an empty keychain, restores the original
keychain configuration in a `finally` block, and retains daemon diagnostics plus its observation.
Finalization requires those raw artifacts and derives the four privacy gates from them.

Exit status is `0` for a passing candidate, `1` for measured gate failures, and `2` for an
invalid manifest/evidence contract. Gate reports contain no wall-clock timestamp or
machine-specific path, so identical evidence inputs produce byte-identical reports. A report contains
fixture IDs, modes, scores, timings, and operational probe results, but never audio or Final
Transcript content.

## Fixture manifest

The manifest root has `schema_version: 1`, corpus identity/licensing facts, and `fixtures`:

```json
{
  "schema_version": 1,
  "corpus": {
    "id": "type-wave-common-voice-17-en-sv-v1",
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
marks. Protected negation, number, and command cases receive a predeclared human semantic
review so equivalent forms such as `two` and `2` do not become false failures; each run records
any `meaning_changing_errors`. Proper
names and technical terms affect WER but have no separate threshold.

Thresholds are fixed in `gate.py` and are per-model calibration for the pinned turbo
candidate (#88): 12% English and 20% Swedish explicit WER, 12%/26% English/Swedish auto WER,
40% maximum per-Utterance WER with pinned waivers (`sv-b-02` both modes and `sv-b-01` auto,
each <=80%), 0.72 punctuation F1, zero protected errors; 2.6/4.8 seconds warmed
explicit/auto latency, 4 seconds cached readiness, 15 seconds first Metal preparation (cold system Metal cache),
300/500 MiB idle/peak RSS as helper leak detectors; cancellation requested at 9.5 seconds
and forced termination by 10 seconds (both timer-driven; the retained observation may
carry up to 250 ms of scheduling overshoot, never an early firing); and zero
privacy/lifecycle violations.
