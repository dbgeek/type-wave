# Vectorized Segment resampling benchmark

**Date:** 2026-09-10

**Decision:** **Do not ship the vector implementation. Keep the scalar production path.**

## Question and evidence baseline

Issue #346 asked whether explicit SIMD materially improves the Whisper Helper's conversion of a
24 kHz signed-16 Segment to the 16 kHz `f32` samples consumed by Whisper. The experiment follows
[`simd-opportunities.md`](./simd-opportunities.md): compare the current scalar mapping with an
explicit Zig vector candidate first, require output equivalence, and judge it in the whole helper
path rather than by isolated throughput alone.

The benchmark artifact is [`prototypes/segment-resampling`](../../prototypes/segment-resampling/README.md).
The production implementation in `src/whisper_helper_core.zig` was not changed.

## Reproduction environment

- Scalar source baseline: `a4ec18e8c32057c906c6f5453d790ebc0d2e4b23`
- Benchmark implementation: the prototype files in this report's commit
- Compiler: Zig `0.17.0-dev.1786+75044cb04`, the release pinned by `flake.lock`
- Build: `ReleaseFast`, Apple Silicon macOS target
- Host: base MacBook Air (Apple M1, 8 cores, 8 GB), macOS 26.6.2 (25G83)
- Runtime: pinned whisper.cpp v1.9.1 source SHA-256
  `147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447`
- Model: pinned `ggml-large-v3-turbo.bin`, 1,624,555,275 bytes, SHA-256
  `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`
- Corpus: accepted `type-wave-common-voice-17-en-sv-v1`, all 20 fixtures in explicit-language
  and auto-detect modes, three runs per fixture/mode case

The isolated run used deterministic full-range PCM, 32 warm-ups, 501 interleaved observations,
and included the output allocation. The whole-path run kept one warm helper alive and timed from
the Transcribe frame write through its Final response. Model verification, load, and helper
readiness completed before that interval; lazy Metal inference-pipeline preparation on the first
request remained inside the measured production boundary.

## Correctness

The candidate processes 12 input samples into eight output samples with `@Vector`, then uses the
same scalar mapping for the tail. It passed all of these checks:

- 50 ms (1,200 input samples), 5 s (120,000), and the 26 s helper-input ceiling (624,000), plus
  a 13-sample tail case; the ceiling clears the Segmenter's 25 s hard maximum plus one Capture
  buffer of slop;
- identical output length and identical first and last samples;
- every output sample equal to the scalar baseline at the explicitly chosen tolerance
  **`0.0f32`** (bit-identical values for the tested inputs).

ReleaseFast assembly contains AArch64 vector widening/conversion and arithmetic (`sshll.4s`,
`scvtf.4s`, `fadd.4s`, and `fmul.4s`), so this measures an emitted SIMD implementation rather
than vector-shaped source lowered back to scalar work.

## Isolated conversion results

Times are microseconds. Tail means nearest-rank p95/p99 wall time. CPU is median process CPU time.

| Segment | Method | Median | p95 | p99 | CPU median | Median speedup |
|---|---:|---:|---:|---:|---:|---:|
| 50 ms | scalar | 0.97 | 1.56 | 2.03 | 0.97 | — |
| 50 ms | Zig vector | 0.26 | 0.61 | 0.79 | 0.25 | 3.82× |
| 5 s | scalar | 101.04 | 152.05 | 163.04 | 100.75 | — |
| 5 s | Zig vector | 21.47 | 52.16 | 55.48 | 21.50 | 4.71× |
| 26 s helper-input ceiling | scalar | 526.33 | 797.38 | 946.46 | 525.00 | — |
| 26 s helper-input ceiling | Zig vector | 112.58 | 274.38 | 304.00 | 112.00 | 4.68× |

The relative result is real, including a 4.69× reduction in median process CPU at the helper-input ceiling.
The absolute median saving is 0.00071 ms for 50 ms, 0.07957 ms for 5 s, and **0.41375 ms for the
largest accepted helper input**.

## Whole Whisper Helper path

Across the accepted corpus's 120 production-helper requests:

| Boundary | Median | p95 | p99 | Worst |
|---|---:|---:|---:|---:|
| IPC write → scalar conversion → Whisper inference → Final response | 3,158.158 ms | 4,594.436 ms | 4,636.786 ms | 4,691.068 ms |

Even granting the 26 s helper-input ceiling's entire 0.41375 ms isolated median saving to every
corpus request—an intentionally generous upper bound—the vector candidate would remove only
**0.0131%** of the 3,158.158 ms helper-path median. The corpus fixtures are at most 10.44 s, so
their actual conversion opportunity is smaller. The observed helper-path variation is also
orders of magnitude larger than the conversion saving.

CPU evidence was available for the isolated candidate and is reported above. Energy attribution
was not available without a privileged Instruments or `powermetrics` capture. The CPU saving is
at most about 0.413 ms per helper-input ceiling and therefore is not material at the helper level.

## vDSP and ship decision

No vDSP variant was built. After Zig SIMD, only 0.11258 ms of median ceiling-input conversion
time remains; eliminating all of it would be about 0.0036% of the measured helper-path median.
That is not a meaningful opportunity and does not justify another implementation or its
polyphase/interleaving complexity.

**No-ship:** retain `resample24To16Alloc` unchanged. The Zig candidate is roughly 4–5× faster in
the microbenchmark and exact under a zero tolerance, but it produces no material helper-path,
CPU, or demonstrated energy improvement. The prototype remains as reproducible evidence for a
future runtime or hardware change.
