# Segment resampling benchmark

This prototype compares the production Whisper Helper's scalar 24 kHz signed-16 PCM to
16 kHz `f32` Segment conversion with an explicit Zig `@Vector` implementation. It does not
change or feed the production helper's conversion.

Run the correctness gate and isolated benchmark with the repository's pinned shell:

```sh
nix develop --command zig test prototypes/segment-resampling/resampler.zig -OReleaseFast
nix develop --command zig run -OReleaseFast prototypes/segment-resampling/benchmark.zig
```

The benchmark includes allocation, alternates which implementation runs first, performs 32
warm-ups, and reports 501-observation median, p95, and p99 wall time plus median process CPU
time. Each small observation batches 64 conversions and each 5 s observation batches four to
keep clock overhead small. Before timing, every case must match the scalar output length, first
and last sample, and every sample with tolerance `0.0f32`.

Measure the production whole-helper boundary after building ReleaseFast and provisioning the
exact pinned model with its sibling `MODEL_MANIFEST` or `PROVENANCE` file:

```sh
nix develop --command zig build -Doptimize=ReleaseFast
nix develop --command python3 prototypes/segment-resampling/helper_path.py \
  zig-out/bin/type-wave-whisper \
  /path/to/ggml-large-v3-turbo.bin \
  --runs 3 > /tmp/type-wave-segment-helper-path.json
```

The runner requires the accepted `type-wave-common-voice-17-en-sv-v1` corpus and refuses a
helper readiness digest other than the pinned Large v3 Turbo F16 digest. Its timer starts before
the version-2 Transcribe frame write and stops after the terminal response, covering pipe I/O,
the production scalar conversion, and Whisper inference. Model verification, load, warm-up, and
helper readiness occur before the measured requests; lazy Metal inference-pipeline preparation
on the first request remains inside the production boundary. Every fixture runs in both its
explicit-language mode and auto-detect mode, matching the accepted corpus harness.
