# Third-Party Notices

type-wave is licensed under the MIT License (see [`LICENSE`](./LICENSE)). It
builds on the following third-party components, each MIT-licensed. Nothing is
vendored into this git tree: every one of them is fetched at build or install
time against a recorded integrity hash, and their full license texts are
preserved in the locations noted below.

Where each pin lives differs, because the two fetchers differ:

- **`build.zig.zon`** pins the Zig source dependency, by `url` + `hash`. The Zig
  package manager verifies that hash on every fetch.
- **[`packaging/share/type-wave/PROVENANCE`](./packaging/share/type-wave/PROVENANCE)**
  pins the two artifacts our own tooling downloads (revision, size, SHA-256),
  which that tooling checks before using them.

## Fetched by the Zig package manager

- **karlseguin/websocket.zig** — Copyright (c) 2024 Karl Seguin. MIT. Pinned in
  [`build.zig.zon`](./build.zig.zon) at `dev` commit `4b475a8`, by archive URL
  plus content hash. Full text:
  [`packaging/share/type-wave/LICENSES/websocket.zig-MIT.txt`](./packaging/share/type-wave/LICENSES/websocket.zig-MIT.txt)
  — kept here rather than read out of the fetched package, because upstream's
  `build.zig.zon` `.paths` does not ship `LICENSE`, so the fetched copy has none.
  Sitting there also means it installs beside the binary that statically links
  it, as the two below do.

## Fetched and bundled at build/install time

These are pinned by `PROVENANCE` and their license texts are installed
alongside the binary (under `~/.local/share/type-wave/`).

- **whisper.cpp v1.9.1** (ggml-org/whisper.cpp) — Copyright (c) 2023-2026 The
  ggml authors. MIT. Full text:
  [`packaging/share/type-wave/LICENSES/whisper.cpp-MIT.txt`](./packaging/share/type-wave/LICENSES/whisper.cpp-MIT.txt).
- **Whisper large-v3-turbo model weights** (`ggml-large-v3-turbo.bin`, a GGML
  conversion by Georgi Gerganov of OpenAI's Whisper large-v3-turbo) —
  Copyright (c) 2022 OpenAI. MIT. Full text:
  [`packaging/share/type-wave/LICENSES/OpenAI-Whisper-MIT.txt`](./packaging/share/type-wave/LICENSES/OpenAI-Whisper-MIT.txt).
