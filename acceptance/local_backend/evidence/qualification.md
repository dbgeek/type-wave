# Pinned local-backend qualification

Verdict: **NO-GO**. The complete release report fails nine independent gates. Every fixed
category was exercised with retained observations. No model, artifact, runtime, corpus,
threshold, language mode, fallback, or score was substituted or waived after observation.

The authoritative machine-readable result is `release-report.json`. Its 40 `utterances` rows
report per-fixture/mode WER plus median and worst latency. `candidate-evidence.json` binds that
report to the raw transcriptions, operational observations, four privacy traces, and all 18
deterministic lifecycle traces.

## Exact candidate and evidence

- Machine: MacBook Air (`MacBookAir10,1`), Apple M1, 8 GB RAM.
- Daemon SHA-256: `1a150a1412fe931a024254150253f8bfb29c24084016357f404a96bfece464b8`;
  code-directory SHA-256: `82a2308ff9bb019da9aaca61f2144e494af894df7ca2c566748d5cf8aa633692`.
- Helper SHA-256: `9269bd6f80d837778582007ee2ce4edde8fcc626a1ecb82144c080c6c92f09f8`;
  code-directory SHA-256: `0d0407787da33f21368ef3fd1a64355212ea053dc997bbd4770f56aa71333d4f`.
- Model: revision `3564d61a42fc210ceaa55a22a96dd64478959c78`, F16,
  487,601,984 bytes, SHA-256
  `de6911330cbdc131362f7a955682b65c8a5a2394caba73e7ea821a9822efb8c6`.
- Runtime: `whisper.cpp-v1.9.1`; source SHA-256
  `147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447`.
- Packaged provenance SHA-256:
  `9958e1aa0151a7465fb66a98e1a58939589029059423df88207de57dc1b2f834`.
- Active receipt SHA-256:
  `6322c2792e706b368cabea13c9be30bc05af1200623e5f3021be421a454f2a64`.
- Corpus manifest SHA-256:
  `834db9a8f36326d2b03ed49fabb28db8789a894e8617a05d0bb9d7c06a54e9b1`;
  canonical SHA-256: `3ef873bf646b00e49c84049d41f3e0ff4dbf0b1d188a1255546d3ee95a3d8916`.
- Exact Common Voice source index SHA-256:
  `9bf9de418e5c9b3e06ddeb3656cd8b8c2d1bc642751d3bdd6522c35d2cefc508`.
- Raw transcription observations SHA-256:
  `45120389bd8541c3ee6339623f6f653117c8b89a45e646574323f3d07b0674ef`.
- Complete candidate evidence SHA-256:
  `a6dafb44a3b2a88cf23d44dbb6d022915c668bb0552505fee806b5dfb0002af8`.
- Release report SHA-256:
  `f1bf6f8a8a8e43e61b4502d01243359f68250b4c6488ef91d78da35f0b407027`.

The pinned model and packaged provenance agree. The packaged identity gate fails because the
active receipt binds runtime SHA-256
`434fd174281eccc472404fd1b58ed89964618182b13e13e5c17cd24a08d29645`,
not the tested helper SHA-256 above.

## Independent release gates

| Gate | Required | Observed | Result |
| --- | --- | --- | --- |
| Pinned design | exact model/runtime pins | exact match | PASS |
| Packaged identity | paired signed binaries; receipt binds helper | signatures/pins match; receipt helper digest differs | **FAIL** |
| Corpus | exact bilingual shape/tags/protected cases | exact match | PASS |
| Explicit English WER | <= 0.15 | 0.876289 | **FAIL** |
| Explicit Swedish WER | <= 0.15 | 0.128713 | PASS |
| English auto WER | <= 0.20 | 0.824742 | **FAIL** |
| Swedish auto WER | <= 0.20 | 0.128713 | PASS |
| Worst per-Utterance WER | <= 0.40 | 1.000000 | **FAIL** |
| Punctuation F1 | >= 0.75 | 0.303030 | **FAIL** |
| Protected semantic errors | 0 | 0 after predeclared human semantic review | PASS |
| Performance machine | Apple M1, 8 GB | Apple M1, 8 GB | PASS |
| Warmed Final Transcript latency | <= 2,000 ms, worst of 3 | 1,198.562 ms worst | PASS |
| Cached ready | <= 2,000 ms | 580.046 ms | PASS |
| First Metal preparation | <= 15,000 ms; visible; reject Capture | 3,351 ms and visible, but Capture accepted before inference pipelines compiled | **FAIL** |
| Warmed idle RSS | <= 600 MiB | 478.250 MiB | PASS |
| Peak inference RSS | <= 750 MiB | 490.266 MiB | PASS |
| Forced overrun | cancel 9,500 ms; terminate by 10,000 ms; abandon; 0 Insertions | cancel 9,510 ms; terminated 10,002 ms; abandoned; 0 Insertions | **FAIL** |
| Offline operation | no credentials/network; Ready offline; corpus complete | empty keychain/environment, sandboxed Ready, corpus complete | PASS |
| Network boundary | 0 helper socket attempts; 0 daemon requests | instrumented 0 / 0 | PASS |
| Default-log privacy | no PCM/transcript; operational metadata retained | no PCM; conservative Partial Transcript scan matched log words | **FAIL** |
| Model Operation privacy | artifact request; no PCM/transcript | artifact-only transport request | PASS |
| Lifecycle/fault matrix | all 18 scenarios pass | forced-termination timing assertion failed; other 17 pass | **FAIL** |

## Decision

This is the `ACCEPT-14` recorded no-go path after a complete rerun under unchanged pins and
thresholds. English quality is more than four times its limit, multiple Utterances reach 1.0
WER and punctuation fail, the measured cancellation/termination path misses both deadlines,
first-use Metal accepts Capture before
inference-pipeline preparation finishes, and the active receipt does not bind the packaged
helper. The retained default-log scan also finds Partial Transcript word markers and therefore
fails conservatively. No release, fallback, or
experimental substitution is authorized by this result.
