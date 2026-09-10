# SIMD opportunities in type-wave

**Date:** 2026-09-10

**Scope:** the checked-out production sources at `a4ec18e`; prototypes and test-only loops were
read only to avoid mistaking benchmark/demo work for shipped work.

## Conclusion

There are two credible SIMD-shaped operations in code owned by this project, but neither is a
good optimization to land without measurements:

1. **Benchmark the local helper's 24 kHz → 16 kHz conversion first.** It is the strongest
   candidate: one scalar pass over as many as 624,000 input samples / 416,000 output samples at
   the 26-second helper-input ceiling. Explicit Zig vectors could help, and the helper already links Accelerate,
   whose vDSP supplies signed-16-to-float conversion and filtered decimation primitives. The
   likely end-to-end win is still small because this simple memory pass immediately precedes a
   Whisper inference.
2. **Do not optimize the two RMS loops yet.** Each processes only 1,200 samples every 50 ms.
   Local dictation with the HUD enabled performs the calculation twice, but that is still only
   48,000 samples/second. Removing the duplicate pass is a more promising question than hand
   vectorizing either copy, and even that should wait for an audio-thread profile.

The expensive part—Whisper inference—is already delegated to whisper.cpp/ggml built in Release
mode with Metal and Accelerate. It should not be replaced by project-local SIMD. Model SHA-256
verification is another large linear operation, but Zig's standard library already selects its
AArch64 SHA-2 instruction implementation when the target exposes that feature.

## What SIMD means in this codebase

Zig's `@Vector(N, T)` operations are element-wise and use SIMD instructions when the target can
support them; unsupported operations fall back to scalar execution. Zig also provides
`@shuffle`, `@select`, and `@reduce`, which are the relevant tools for this project's strided
audio layouts. [Zig language reference: Vectors](https://ziglang.org/documentation/master/#Vectors)

The release compiler can also vectorize ordinary scalar loops. LLVM documents that its loop and
SLP vectorizers are enabled by default and cost-model driven, but notes two relevant limitations:
complicated control flow may prevent vectorization, and floating-point reductions normally need
reassociation permission (or a less efficient ordered reduction on targets that support it).
[LLVM Auto-Vectorization](https://llvm.org/docs/Vectorizers.html)

As a spot check rather than a durable benchmark, representative isolated versions of the RMS,
i16→f32, and 3:2 pair loops were compiled for `aarch64-macos` with the current flake compiler
(`zig 0.17.0-dev.1786+75044cb04`, `ReleaseFast`). The emitted assembly used scalar `ldrsh`,
`scvtf`, `fmul`, and `fadd`; none of the three probe loops was widened. This is evidence that
automatic vectorization cannot be assumed, not proof about every inlined production call site.
Repeating the RMS probe with `@setFloatMode(.optimized)` did produce a four-sample AArch64 NEON
loop (`sshll`, `scvtf.2d`, and `fmla.2d`), consistent with LLVM's documented requirement for
floating-point reassociation. That confirms a SIMD route exists, but also makes the numerical
semantics change explicit; ReleaseFast alone does not grant it.

## Candidate 1: PCM conversion and 3:2 resampling

Location: [`src/whisper_helper_core.zig:100`](../../src/whisper_helper_core.zig#L100)

`resample24To16Alloc` converts little-endian signed 16-bit PCM to normalized `f32` while mapping
each three input samples to two outputs:

```text
y[2n]   = x[3n] / 32768
y[2n+1] = (x[3n+1] + x[3n+2]) / (2 * 32768)
```

The 26-second guard permits 1,248,000 PCM bytes: 624,000 input samples and 416,000 output floats.
Unlike most control-plane loops in the daemon, this has enough independent arithmetic and enough
iterations to amortize a vector loop and scalar tail.

### Feasible implementations

- **Explicit Zig vectors:** process a fixed block of input triples, widen `i16` lanes, convert to
  `f32`, use `@shuffle` to form the direct and averaged output lanes, then retain the existing
  scalar loop for the tail. This keeps the code portable and adds no dependency. The awkward
  3-input/2-output shuffle means it must beat the scalar version in a benchmark before adoption.
- **Accelerate/vDSP in the helper:** Apple documents `vDSP_vflt16` as vector signed-16-to-float
  conversion, with independent input/output strides, and `vDSP_desamp` as FIR filtering plus
  decimation. [Apple `vDSP_vflt16`](https://developer.apple.com/documentation/accelerate/vdsp_vflt16),
  [Apple `vDSP_desamp`](https://developer.apple.com/documentation/accelerate/vdsp_desamp)
  The helper already links Accelerate in `build.zig`, so this does not add a shipped framework.
  However, 3:2 rational resampling needs two polyphase outputs and interleaving; extra temporary
  storage or extra passes can erase the library-call gain. `vDSP_desamp` also explicitly permits
  reordered floating-point work, so bit-for-bit equivalence cannot be assumed.

### Expected value and blockers

The local transform is O(samples), allocation-backed, and moves about 2.9 MB at the maximum
helper input (input plus output). Inference that follows is a large neural-network computation,
so even a substantial microbenchmark speedup may be invisible in release-to-final latency. This
is an inference from the operation shapes and must be checked with timing data.

Correctness is the larger blocker. The current transformation is a very small interpolation
filter, not a general antialiasing resampler. SIMD work must preserve the existing sample mapping,
output length, endpoint behavior, and tolerances. Improving resampling quality would be a separate
audio/recognition experiment, not a SIMD refactor.

## Candidate 2: the duplicated RMS reductions

Locations:

- [`src/capture.zig:175`](../../src/capture.zig#L175): HUD level on the AudioQueue callback
  thread.
- [`src/local_backend.zig:54`](../../src/local_backend.zig#L54): silence segmentation in the
  local backend.

Both loops widen 1,200 signed samples to `f64`, square, accumulate, divide, and take one square
root. Capture calls the chunk sink before calculating its HUD value, so local dictation with the
HUD enabled scans the same buffer in both components.

The arithmetic is vectorizable in principle, but the current `f64` accumulation is an ordered
reduction. LLVM documents why floating-point reductions can remain scalar without reassociation.
An explicit vector reduction changes addition order unless it is designed around exact integer
sum-of-squares. For this fixed buffer, an unsigned 64-bit integer accumulator can safely hold all
1,200 squared `i16` values; such a variant could vectorize widening/squaring while retaining a
deterministic exact sum, followed by one scalar normalization and square root.

That engineering is unlikely to pay back: each loop sees only 24,000 samples/second, or 48,000
samples/second together. The Capture copy also runs on the audio callback thread, where bounded,
simple work matters more than an impressive isolated throughput number. If profiling identifies
this region, first benchmark a design that computes the statistic once and passes it with the PCM;
compare that contract/locking cost with explicit integer-vector reductions.

Accelerate is unattractive here. Although Apple exposes vector conversion and vector statistics,
the main daemon does not currently link Accelerate, the buffers are small, and a conversion buffer
or additional calls would add overhead. The framework belongs in the comparison benchmark, not in
the initial implementation. [Apple vDSP overview](https://developer.apple.com/documentation/accelerate/vdsp)

## Already optimized or not worth pursuing

### whisper.cpp / ggml inference

[`tools/build-whisper-runtime.sh:44`](../../tools/build-whisper-runtime.sh#L44) configures the
pinned whisper.cpp v1.9.1 runtime as `Release`, enables Metal and embeds its Metal library; the
generated configuration also enables Accelerate/BLAS. The bridge requests the GPU and flash
attention at [`src/whisper_bridge.cpp:87`](../../src/whisper_bridge.cpp#L87). The upstream project
describes Apple Silicon as a first-class target optimized through ARM NEON, Accelerate, Metal, and
Core ML. [whisper.cpp v1.9.1 source and README](https://github.com/ggml-org/whisper.cpp/tree/v1.9.1)

This is where SIMD/GPU acceleration matters most, and it is already owned by the specialized
upstream runtime. Project work should benchmark backend configuration or upstream upgrades, not
write parallel inference kernels.

### Model hashing

The 1.62 GB model is streamed through `std.crypto.hash.sha2.Sha256` during installation and helper
inspection at [`src/model_store.zig:1220`](../../src/model_store.zig#L1220) and
[`src/whisper_helper.zig:194`](../../src/whisper_helper.zig#L194). Zig's AArch64 SHA-256 compressor
checks the target's `.sha2` feature and emits the architecture's `sha256su0`, `sha256su1`,
`sha256h`, and `sha256h2` instructions. [Zig standard-library SHA-2 implementation](https://github.com/ziglang/zig/blob/75044cb04/lib/std/crypto/sha2.zig#L203-L229)

No hand-written SIMD change is indicated. Storage throughput may dominate the full-file pass and
must be profiled independently.

### HUD history movement and byte copies

[`src/hud.zig:810`](../../src/hud.zig#L810) shifts 25 `f32` values per new level. The standard
memory copy implementation/compiler can use suitable bulk moves, and the surrounding tick makes
26 Objective-C layer updates. Hand SIMD for 100 bytes would optimize the wrong scale. Other
`@memcpy`, parsing, queue, menu, and state-machine loops are similarly small, branchy, blocking on
I/O, or already routed through optimized standard-library primitives.

## Benchmark-first next steps

No production change is recommended yet. A bounded experiment should proceed in this order:

1. Add a test-only benchmark for `resample24To16Alloc` using 50 ms, 5 s, and maximum 26 s inputs.
   Compare the current scalar implementation, an explicit `@Vector` block implementation, and—if
   still warranted—a vDSP implementation. Record median and tail time plus allocations/bytes.
2. Require identical output length and endpoint behavior, and compare every sample to the current
   function. Treat any tolerance change as a separate product-quality decision.
3. Time the whole helper path around conversion and `whisper_full` on the same accepted corpus.
   Land SIMD only if conversion is a material fraction of release-to-final latency or CPU/energy,
   not merely faster in isolation.
4. Profile the AudioQueue callback and local adapter during a long local utterance with HUD on and
   off. Only if RMS is visible should a second benchmark compare scalar `f64`, exact integer SIMD,
   and compute-once plumbing. Include callback worst-case time and segmentation decisions near the
   silence threshold.
5. Run the existing local-backend qualification corpus after any candidate optimization; latency,
   transcript quality, cancellation, and silence-cut behavior are all regression surfaces.

## Primary sources

- [Zig language reference: Vectors](https://ziglang.org/documentation/master/#Vectors)
- [LLVM: Auto-Vectorization](https://llvm.org/docs/Vectorizers.html)
- [Apple Accelerate: `vDSP_vflt16`](https://developer.apple.com/documentation/accelerate/vdsp_vflt16)
- [Apple Accelerate: `vDSP_desamp`](https://developer.apple.com/documentation/accelerate/vdsp_desamp)
- [Apple Accelerate: vDSP](https://developer.apple.com/documentation/accelerate/vdsp)
- [whisper.cpp v1.9.1](https://github.com/ggml-org/whisper.cpp/tree/v1.9.1)
- [Zig standard-library SHA-2 source](https://github.com/ziglang/zig/blob/75044cb04/lib/std/crypto/sha2.zig#L203-L229)
