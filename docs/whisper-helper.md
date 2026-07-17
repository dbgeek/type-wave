# Private KB Whisper helper

`type-wave-whisper` is the persistent, offline inference process for the pinned
KB Whisper Small F16 artifact. It accepts only a model path and version 1 frames on
stdin, writes frames on stdout, and reserves stderr for bounded operational diagnostics.
It has no downloader, credential input, network client, or OpenAI fallback.

## Build from the pinned runtime

Provision the upstream `whisper.cpp-v1.9.1.tar.gz` archive. The build rejects anything
other than the 9,012,805-byte archive with SHA-256
`147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447`:

```sh
nix develop --command zig build \
  -Dwhisper-archive=/path/to/whisper.cpp-v1.9.1.tar.gz
```

The build statically links whisper.cpp with its embedded Metal library. It neither
downloads nor modifies the supplied archive.

## Exercise a manually provisioned artifact

The model must be the 487,601,984-byte `ggml-model.bin` with SHA-256
`de6911330cbdc131362f7a955682b65c8a5a2394caba73e7ea821a9822efb8c6`.
The helper hashes it before model load and emits `ready` only after context creation and
Metal preparation succeed. Probe readiness, or optionally submit a mono 24 kHz signed-16
WAV:

```sh
python3 tools/probe-whisper-helper.py \
  zig-out/bin/type-wave-whisper \
  /path/to/ggml-model.bin \
  --wav /path/to/utterance-24khz.wav \
  --language auto
```

The probe validates protocol version, lengths, model digest, request identity, UTF-8,
and the structured terminal response. The helper supports one inference at a time;
a matching `cancel` frame trips whisper.cpp's abort callback.

## Install the model explicitly

Provision the already-built helper at its private path, then let type-wave acquire and
activate the exact pinned artifact:

```sh
mkdir -p "$HOME/.local/libexec/type-wave"
install -m 755 zig-out/bin/type-wave-whisper \
  "$HOME/.local/libexec/type-wave/type-wave-whisper"

~/.local/bin/type-wave --set-hf-token
~/.local/bin/type-wave --install-model
```

For foreground development, `HF_TOKEN=hf_... zig-out/bin/type-wave --install-model` is a
non-persisted override. Installation data lives under
`~/Library/Application Support/type-wave/models/`; immutable installation directories are
selected by an atomically replaced `active.receipt` only after exact size/digest verification
and a successful helper load/warm smoke test.

An interruption leaves only validator-bound, byte-counted staging data. Restart reports it
as paused without network activity. Inspect with `--model-status`, continue explicitly with
`--resume-model`, or remove only the staged work with `--discard-model`. Ctrl-C cooperatively
cancels transfer, verification, and helper smoke testing; atomic receipt activation completes
without interruption once begun.

Remove all local model data explicitly with `--remove-model`. After confirmation, the
running daemon rejects new local Utterances, lets an accepted Utterance finish, unloads the
helper, and removes the Model Installation plus staged Model Operation data. The configured local backend remains selected
and reports unavailable; the Hugging Face token is not touched. `--forget-hf-token` is the
separate credential action: it first cooperatively stops any authenticated transfer, keeps
validator-bound resumable data, and then deletes only the Hugging Face login-Keychain item.

Select local in `~/.config/type-wave/config.zon`:

```zig
.{
    .transcription_backend = .local_kb_whisper,
}
```

The helper verifies the pinned size and digest and warms the model before local Capture is
accepted. The local Transcription Backend reads neither the OpenAI credential nor the
network, buffers the full 24 kHz mono Capture, and sends exactly one inference request after
Talk Key release. Omit the field to retain the default OpenAI backend. Selection persists
across restarts; opening the Status Item picks up a hand-edited selection immediately and
drains any active Utterance before preparing the latest choice. The full backend chooser and
local-model actions belong to the backend-aware Status Item increment.
