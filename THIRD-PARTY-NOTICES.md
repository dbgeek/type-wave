# Third-Party Notices

type-wave is licensed under the MIT License (see [`LICENSE`](./LICENSE)). It
builds on the following third-party components, each MIT-licensed. Their full
license texts are preserved in the locations noted below; pinned revisions and
integrity hashes are recorded in
[`packaging/share/type-wave/PROVENANCE`](./packaging/share/type-wave/PROVENANCE).

## Vendored in this repository

- **karlseguin/websocket.zig** — Copyright (c) 2024 Karl Seguin. MIT.
  Full text: [`vendor/websocket.zig/LICENSE`](./vendor/websocket.zig/LICENSE).

## Fetched and bundled at build/install time

These are not vendored into the git tree; they are pinned by `PROVENANCE` and
their license texts are installed alongside the binary (under
`~/.local/share/type-wave/`).

- **whisper.cpp v1.9.1** (ggml-org/whisper.cpp) — Copyright (c) 2023-2026 The
  ggml authors. MIT. Full text:
  [`packaging/share/type-wave/LICENSES/whisper.cpp-MIT.txt`](./packaging/share/type-wave/LICENSES/whisper.cpp-MIT.txt).
- **Whisper large-v3-turbo model weights** (`ggml-large-v3-turbo.bin`, a GGML
  conversion by Georgi Gerganov of OpenAI's Whisper large-v3-turbo) —
  Copyright (c) 2022 OpenAI. MIT. Full text:
  [`packaging/share/type-wave/LICENSES/OpenAI-Whisper-MIT.txt`](./packaging/share/type-wave/LICENSES/OpenAI-Whisper-MIT.txt).
