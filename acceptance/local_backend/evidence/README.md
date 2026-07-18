# Qualification evidence, per candidate

Each subdirectory holds the complete, digest-bound qualification evidence for one release
candidate, named by its Model Installation id:

- [`3564d61a42fc-f16/`](3564d61a42fc-f16/) — KB Whisper Small (F16). **NO-GO**: failed nine
  independent gates; the failure that motivated the switch to Whisper Large v3 Turbo
  (wayfinder map #85).
- [`98aa99a0a9db-f16/`](98aa99a0a9db-f16/) — Whisper Large v3 Turbo (F16), the pinned local
  model. **GO**: all 23 gates pass under the #88 per-model calibration; see its
  `qualification.md`.

The corpus is shared across candidates: `type-wave-common-voice-17-en-sv-v1` in
[`../corpus/`](../corpus/). Corpus identity is content-bound and model-agnostic, so a new
candidate reuses it unchanged; the gate binds every report to the exact manifest digest.
Archived evidence is scored by the gate thresholds of its own era (`gate.py` at the commit
that landed it); thresholds are per-model calibration and are recalibrated per candidate.
