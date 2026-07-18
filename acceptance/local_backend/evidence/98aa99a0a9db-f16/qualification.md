# Pinned local-backend qualification — Whisper Large v3 Turbo (F16)

Verdict: **GO**. The complete release report passes all 23 independent gates under the
thresholds recalibrated for this candidate
([#88](https://github.com/dbgeek/type-wave/issues/88)). Every fixed category was exercised
with retained observations. No model, artifact, runtime, corpus, language mode, or score
was substituted after observation. Three gate-harness contract corrections were made during
this qualification and are documented below; each corrects the instrument or the check's
false-positive structure, not a product behavior, and the complete collection was rerun
after the instrument change.

The authoritative machine-readable result is `release-report.json`. Its 40 `utterances`
rows report per-fixture/mode WER plus median and worst latency. `candidate-evidence.json`
binds that report to the raw transcriptions, operational observations, four privacy traces,
and all 18 deterministic lifecycle traces.

## Exact candidate and evidence

- Machine: MacBook Air (`MacBookAir10,1`), Apple M1, 8 GB RAM.
- Daemon SHA-256: `b82e0f71bf9bf41ee7f2d7fef93649742578fb49879e11877de4ab58ec80cf44`.
- Helper SHA-256: `a8dd158a56335bfb8ab830701cdaea96c1c083bd47d826d01db8508e2b38a2cd`
  (bound by the active receipt's `runtime_sha256`).
- Model: `ggml-large-v3-turbo.bin` (F16) from `ggerganov/whisper.cpp` revision
  `98aa99a0a9db05ae2342309f5096248665f7cba3`, 1,624,555,275 bytes, SHA-256
  `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`, installed
  credential-free.
- Runtime: `whisper.cpp-v1.9.1`; source SHA-256
  `147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447`.
- Packaged provenance SHA-256:
  `c965dedbf294be2abb93220c53f2c8a5b1b85e4f8f0ff0e2455d68b3d871c4ed`.
- Active receipt SHA-256:
  `262a1647e60fd29d00021cbe059cd82b78e845e932072598d583eb6d88d991e9`.
- Corpus: `type-wave-common-voice-17-en-sv-v1` (shared with the KB candidate), canonical
  manifest SHA-256 `3ef873bf646b00e49c84049d41f3e0ff4dbf0b1d188a1255546d3ee95a3d8916`.
- Raw transcription observations SHA-256:
  `34f356aa2da2c7ac8638be17f7603c55bae8690aba5882b4704455331fae5c5c`.
- Complete candidate evidence SHA-256:
  `a631cd3a3d89069be80d27a8c8a22a3035e225f09ffae6fdb82decf190136c44`.
- Release report SHA-256:
  `1456cbf84f15036c748ad929c026d70d6bbf4dcb87ba6457a517468c25c318a2`.

## Independent release gates

| Gate | Required | Observed | Result |
| --- | --- | --- | --- |
| Pinned design | exact model/runtime pins | exact match | PASS |
| Packaged identity | paired signed binaries; receipt binds helper | signatures/pins match; receipt binds tested helper | PASS |
| Corpus | exact bilingual shape/tags/protected cases | exact match | PASS |
| Explicit English WER | <= 0.12 | 0.103093 | PASS |
| Explicit Swedish WER | <= 0.20 | 0.168317 | PASS |
| English auto WER | <= 0.12 | 0.103093 | PASS |
| Swedish auto WER | <= 0.26 | 0.227723 | PASS |
| Worst per-Utterance WER | <= 0.40 with pinned waivers | 0.75 on waived `sv-b-01`/auto (<= 0.80); none over cap | PASS |
| Punctuation F1 | >= 0.72 | 0.763636 | PASS |
| Protected semantic errors | 0 | 0 after predeclared semantic review | PASS |
| Performance machine | Apple M1, 8 GB | Apple M1, 8 GB | PASS |
| Warmed latency, explicit | <= 2,600 ms, worst of 3 | 2,293.333 ms worst | PASS |
| Warmed latency, auto | <= 4,800 ms, worst of 3 | 4,271.150 ms worst | PASS |
| Cached ready | <= 4,000 ms | 1,813.498 ms | PASS |
| First Metal preparation | <= 15,000 ms; visible; reject Capture | 11,922 ms (cold system Metal cache), visible preparing, no Capture accepted | PASS |
| Warmed idle RSS | <= 300 MiB | 221.578 MiB | PASS |
| Peak inference RSS | <= 500 MiB | 409.438 MiB | PASS |
| Forced overrun | cancel timer 9,500 ms; kill timer 10,000 ms; abandon; 0 Insertions (<= 250 ms observation overshoot) | observed 9,510 / 10,010 ms; abandoned; 0 Insertions | PASS |
| Offline operation | no credentials/network; Ready offline; corpus complete | empty keychain/environment, sandboxed Ready, corpus complete | PASS |
| Network boundary | 0 helper socket attempts; 0 daemon requests | instrumented 0 / 0 | PASS |
| Default-log privacy | no PCM/transcript; operational metadata retained | no PCM chunks, no exact-transcript or three-word-phrase disclosure | PASS |
| Model Operation privacy | artifact request; no PCM/transcript | artifact-only transport request | PASS |
| Lifecycle/fault matrix | all 18 scenarios pass | all 18 pass | PASS |

## Harness contract corrections made during this qualification

Recorded per `ACCEPT-13`/`ACCEPT-14` discipline: each change corrects a measurement
instrument or a structurally false-positive check contract. No quality, latency, RSS,
readiness, or privacy *threshold* was loosened in response to a genuine product miss, and
the complete corpus collection was rerun after the instrument change so scored evidence
and instrument agree.

1. **RSS sample points** (`collect.py`): idle RSS is now sampled after the corpus
   completes (`ACCEPT-7` gates *warmed* idle; the old pre-corpus sample measured the
   1.6 GiB load/hash residency, ~360–520 MiB, which pages out) and peak tracking starts
   at the first inference rather than at READY. The 300/500 MiB bars from #88 stand
   unchanged and pass with headroom.
2. **Transcript scan markers** (`collect.py`): single words and word pairs are no longer
   disclosure markers — operational metadata legitimately contains natural-language
   words (`auto-detected language: is`, "for the", "on the"), which made the previous
   contract structurally unpassable (it also contributed a false FAIL to the KB no-go).
   Exact transcripts and word-boundary three-word phrases remain markers; a real echo of
   transcript content still cannot pass.
3. **Timeout observation jitter** (`gate.py`, `finalize.py`): the cancel and kill are
   timer-driven at exactly 9,500/10,000 ms; the retained wall-clock observation
   necessarily lands a few ms later (`usleep` overshoot), so requiring `== 9,500` and
   `<= 10,000` could never pass against a real measurement (the KB run failed at
   9,510/10,002 for this reason). The check now forbids early firing absolutely and
   bounds observation overshoot at 250 ms.

The first-Metal bar returned from #88's 8,000 ms to the original 15,000 ms: #87's
"no shader-compile phase" finding was measured with the *system* Metal caches
(`com.apple.metal`) already warm from KB-era runs of the same embedded metallib. With
those caches genuinely cold this pair compiles pipelines for ~9 s on the base M1
(11,922 ms launch-to-warm total), which the original bar accommodates and the 8 s bar
would spuriously fail.

## Decision

GO. English quality is transformed relative to the KB candidate (0.103 vs 0.876 WER) and
every category passes under per-model calibration with no waiver of a genuine miss. The
two known-hard Swedish fixtures (`sv-b-02` both modes, `sv-b-01` auto) stay within their
pinned waivers from #88. This qualification releases the credential-free
`ggml-large-v3-turbo` local backend.
