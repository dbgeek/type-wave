# Private Whisper helper

`type-wave-whisper` is the persistent, offline inference process for the pinned
Whisper Large v3 Turbo F16 artifact. It accepts only a model path and version 2 frames on
stdin, writes frames on stdout, and reserves stderr for bounded operational diagnostics.
It has no downloader, credential input, network client, or OpenAI fallback.

## Build from the pinned runtime

Every normal build acquires the upstream `whisper.cpp-v1.9.1.tar.gz` archive and rejects
anything other than the 9,012,805-byte archive with SHA-256
`147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447`. For an offline build,
provide the same verified archive explicitly:

```sh
nix develop --command zig build \
  -Dwhisper-archive=/path/to/whisper.cpp-v1.9.1.tar.gz
```

The build statically links whisper.cpp with its embedded Metal library. It never uses a
preinstalled runtime and does not modify an explicitly supplied archive.

## Exercise a manually provisioned artifact

The model must be the 1,624,555,275-byte `ggml-large-v3-turbo.bin` with SHA-256
`1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`.
The helper hashes it before model load and emits `ready` only after context creation and
Metal preparation succeed. Probe readiness, or optionally submit a mono 24 kHz signed-16
WAV:

```sh
python3 tools/probe-whisper-helper.py \
  zig-out/bin/type-wave-whisper \
  /path/to/ggml-large-v3-turbo.bin \
  --wav /path/to/utterance-24khz.wav \
  --language auto
```

The probe validates protocol version, lengths, model digest, request identity, UTF-8,
and the structured terminal response. The helper supports one inference at a time;
a matching `cancel` frame trips whisper.cpp's abort callback.

## Install the model explicitly

Install the already-built daemon/helper pair, then let type-wave acquire and activate the
exact pinned artifact:

```sh
nix develop --command zig build install-agent
~/.local/bin/type-wave --install-model
```

The paired installer signs and publishes both executables together and installs exact model
and runtime provenance plus their license texts under `~/.local/share/type-wave/`.

The download is credential-free. Installation data lives under
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
and reports unavailable.

Select local in `~/.config/type-wave/config.zon`:

```zig
.{
    .transcription_backend = .local,
}
```

The helper verifies the pinned size and digest and warms the model before local Capture is
accepted. The local Transcription Backend reads neither the OpenAI credential nor the
network, buffers the full 24 kHz mono Capture, and sends exactly one inference request after
Talk Key release. Omit the field to retain the default OpenAI backend. Selection persists
across restarts; opening the Status Item picks up a hand-edited selection immediately and
drains any active Utterance before preparing the latest choice. The Status Item exposes the
backend chooser, selected-backend readiness and primary action, local privacy cue, and Model
Installation management without making an unselected backend compete in the main hierarchy.
