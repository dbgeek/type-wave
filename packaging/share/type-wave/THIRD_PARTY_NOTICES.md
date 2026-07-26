# Third-party notices

## Whisper Large v3 Turbo

type-wave supports the official F16 `ggml-large-v3-turbo.bin` from
[`ggerganov/whisper.cpp`](https://huggingface.co/ggerganov/whisper.cpp), the GGML
conversion published by Georgi Gerganov of OpenAI's Whisper large-v3-turbo model.
The exact artifact and immutable revision are recorded in `PROVENANCE`. The model is
offered under the MIT License (© 2022 OpenAI); the complete text is in
`LICENSES/OpenAI-Whisper-MIT.txt`.

## whisper.cpp

The private `type-wave-whisper` helper statically links whisper.cpp v1.9.1. Its exact source
archive identity is recorded in `PROVENANCE`; its MIT license is in
`LICENSES/whisper.cpp-MIT.txt`.

## websocket.zig

The `type-wave` daemon statically links `karlseguin/websocket.zig` — the client that carries
the Transcription Session to the server. Unlike the two above it is not fetched by our own
tooling and so is not in `PROVENANCE`: it is a Zig source dependency, pinned by URL and
content hash in the daemon's `build.zig.zon` and verified by the Zig package manager on every
fetch. Copyright (c) 2024 Karl Seguin; its MIT license is in
`LICENSES/websocket.zig-MIT.txt`.
