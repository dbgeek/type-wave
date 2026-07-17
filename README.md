# type-wave

**Hold-to-talk dictation for macOS.** Hold a key, speak, release, and the
transcribed text is inserted at the cursor of the app you are already using.

type-wave is a Zig daemon for Apple Silicon macOS. It uses CoreAudio for capture,
OpenAI's Realtime transcription API over WebSocket/TLS, and macOS event/pasteboard
APIs for insertion. It can run in the foreground while developing, or as a signed
per-user LaunchAgent for daily use.

> Status: research repo, `v0.0.0`, macOS-only. The mic -> transcribe -> insert
> pipeline is implemented end-to-end. Distribution work such as hardened runtime,
> entitlements, and notarization is still out of scope.

## How It Works

```text
hold Talk Key
    -> CoreAudio Capture (24 kHz mono PCM)
    -> warm OpenAI Realtime Transcription Session
release Talk Key
    -> manual commit
    -> Final Transcript
    -> insertion at the Focused Target cursor
```

The default **Talk Key** is Right Option. While it is held, type-wave streams mic
audio to a warm transcription session. On release, it commits the utterance, waits
for the **Final Transcript**, then inserts that text through either a clipboard-swap
paste or synthetic keystrokes.

The floating HUD is visual feedback only: a red waveform while recording, then green
processing dots until the utterance resolves. It never shows transcript text. Partial
transcripts are logged and may be revised; only Final Transcripts are inserted.

A menu-bar Status Item derives readiness for the selected Transcription Backend and exposes
the persisted OpenAI/local chooser. Its compact menu shows one relevant primary action,
keeps OpenAI controls in OpenAI context, and leaves full Local Model management reachable
under either selection. Ready local mode says that audio stays on this Mac; an explicit
network-using Model Operation gets its own separate cue.

The project vocabulary is kept in [CONTEXT.md](./CONTEXT.md).

## Requirements

- Apple Silicon macOS.
- Nix with flakes, or a matching bare Zig nightly. See [docs/toolchain.md](./docs/toolchain.md).
- An OpenAI API key with access to Realtime transcription.
- macOS grants for Input Monitoring, Accessibility, and Microphone.

## Quick Start

For a foreground development run:

```sh
export OPENAI_API_KEY=sk-...
nix develop --command zig build run
```

On first run, macOS may prompt for:

- **Input Monitoring**: observing the Talk Key.
- **Accessibility**: posting insertion events.
- **Microphone**: capturing audio.

Missing prerequisites do not crash the daemon. It reports what it is waiting for and
self-heals when the key or permission appears.

## Daily Install

Install type-wave as a signed per-user LaunchAgent:

```sh
nix develop --command zig build install-agent
~/.local/bin/type-wave --set-key
```

The install step signs the binary with the local `type-wave dev` identity, installs it
to `~/.local/bin/type-wave`, and writes the LaunchAgent plist. Running `--set-key`
through the installed signed binary stores the OpenAI key in the login keychain so the
daemon can read it without prompts across rebuilds.

The one-time signing identity setup, LaunchAgent load/unload commands, and TCC grant
persistence checks are documented in [docs/packaging.md](./docs/packaging.md). Logs go
to `~/Library/Logs/type-wave.log`.

## Configuration

Every field is optional. Copy the annotated example when you want a hand-editable file:

```sh
mkdir -p ~/.config/type-wave
cp packaging/config.example.zon ~/.config/type-wave/config.zon
```

| Field | Default | Notes |
| --- | --- | --- |
| `transcription_backend` | `.openai` | `.openai` or `.local_kb_whisper`; selection is a hard audio boundary |
| `talk_key` | `.right_option` | `.right_option`, `.left_option`, or `.globe` |
| `model` | `"gpt-realtime-whisper"` | String, so model experiments do not require a rebuild |
| `language` | `"en"` | `"en"`, `"sv"`, or `""` for auto-detect |
| `delay` | `"low"` | `"minimal"`, `"low"`, `"medium"`, `"high"`; other strings stay hand-editable |
| `noise_reduction` | `.near_field` | `.near_field`, `.far_field`, or `.off` |
| `insertion` | `.paste` | `.paste` or `.keystroke` |
| `pre_paste_ms` | `25` | Pasteboard settle delay before Cmd-V |
| `overlay` | `true` | Show the silent waveform/processing HUD |

The menu bar is the live settings writer. It swaps in complete immutable settings
snapshots and patches single fields in `config.zon` while preserving comments. Hand
edits are picked up on restart or the next time the menu opens.

Secrets do not live in `config.zon`. Key precedence is:

1. `OPENAI_API_KEY` from the process environment, for foreground dev runs.
2. The login keychain item created by the menu or `~/.local/bin/type-wave --set-key`.
3. One-time migration from the retired `~/.config/type-wave/env` file, if present.

The pinned local KB Whisper Model Installation uses a separate Hugging Face credential.
Store it through the installed signed binary, then explicitly start the Model Operation:

```sh
~/.local/bin/type-wave --set-hf-token
~/.local/bin/type-wave --install-model
```

For a foreground development operation, `HF_TOKEN` overrides the Hugging Face login-
Keychain item for that invocation and is never persisted. The operation authenticates only
the initial `huggingface.co` request, strips authorization from cross-origin redirects, and
checkpoints only exact validator-matched byte ranges. A cancelled or interrupted operation
never resumes network activity on restart; inspect it with `--model-status`, then explicitly
choose `--resume-model` or `--discard-model`. Download and hashing progress are byte-accurate,
transient retries stop after the displayed budget, and Ctrl-C cooperatively cancels transfer,
hashing, or the helper smoke test. Activation is the only short non-cancellable stage.

`--model-status` derives update availability by comparing the active receipt with the complete
identity embedded in the running type-wave release. An older verified installation remains
ready for offline dictation while `--update-model` stages, verifies, and smoke-tests its
replacement. Activation waits for active local inference to drain, then atomically switches
the receipt; failure or cancellation leaves the working installation selected and usable.

Run `--verify-model` for a full offline integrity check of the active Model Installation.
It hashes every model byte and reports the exact corrupt metadata/artifact class without
reading credentials or using the network. Run `--repair-model` to verify first and preserve
valid local data; metadata-only damage is rebuilt offline, while missing or invalid artifact
data requires typing `yes` before authenticated acquisition begins. A helper load failure
performs this same offline verification before type-wave offers Repair for corruption or
runtime Retry for a verified installation that still cannot load.

After full size/SHA-256 verification and the smoke test, type-wave atomically publishes the
active receipt. Receipts and provenance contain identities and digests, never credentials,
signed URLs, audio, or transcript content.

## Development

```sh
nix develop --command zig build
nix develop --command zig build test
nix develop --command zig build capture-check
```

Useful build modes:

```sh
nix develop --command zig build -Doptimize=Debug
nix develop --command zig build -Doptimize=ReleaseSafe
nix develop --command zig build -Doptimize=ReleaseSmall
```

Plain builds default to `ReleaseFast`, matching the installed daemon. `capture-check`
is a live CoreAudio start/stop probe and uses real microphone IO.

## Architecture

The daemon is thin wiring around testable state machines and OS adapters.

The **Utterance Coordinator** in `src/coordinator.zig` owns the utterance lifecycle:
`idle -> capturing -> awaiting_final -> inserting -> idle`. It handles the overlap
guard, release-anchored deadline, empty or failed transcripts, dropped sessions, and
failed insertions. Hardware and OS effects reach it through seams.

`src/daemon.zig` builds the real adapters, starts the threads, runs the menu/HUD/tap
main loop, and supervises readiness. Three state machines remain outside the Coordinator:
configuration readiness in `src/configuration_phase.zig`, transcription link state in
`src/session.zig`, and local load-failure classification in `src/local_model_recovery.zig`.

| Module | Role |
| --- | --- |
| `src/main.zig` | CLI entry point and `--set-key` subcommand |
| `src/daemon.zig` | Long-running daemon wiring, threads, supervisor, menu seams |
| `src/coordinator.zig` | Utterance lifecycle state machine |
| `src/config.zig` | ZON settings, key loading, immutable settings snapshots, config writes |
| `src/configuration_phase.zig` | Setup readiness transitions and reporting |
| `src/readiness.zig` | Pure readiness/status policy |
| `src/session.zig` | Warm OpenAI Realtime transcription session and reconnect logic |
| `src/capture.zig` | CoreAudio capture |
| `src/tap.zig` | Global Talk Key observation |
| `src/insert.zig` | Clipboard paste and synthetic keystroke insertion |
| `src/insertion_adapter.zig` | Async insertion worker around the Coordinator |
| `src/menu.zig` | Menu-bar status item and live settings UI |
| `src/hud.zig` | Silent waveform/processing overlay |
| `src/surface.zig` | HUD-vs-sound feedback arbitration |
| `src/feedback.zig` | Sound cues and timestamped logging |
| `src/keychain.zig` | Separate OpenAI and Hugging Face login-Keychain items |
| `src/model_store.zig` | Explicit authenticated Model Operation and atomic Model Installation activation |
| `src/local_model_recovery.zig` | Local integrity verification versus runtime-load recovery policy |
| `src/info_plist.zig` | Embedded `Info.plist` Mach-O section |

## Repository Layout

```text
src/                 daemon source
docs/                toolchain, packaging, ADRs, research notes, agent docs
packaging/           Info.plist, LaunchAgent plist, install script, config example
prototypes/          spikes that proved capture, insertion, menu, and HUD behavior
vendor/              vendored karlseguin/websocket.zig
flake.nix            development shell pinning the Zig nightly
```

## Notes

- The Zig nightly and vendored `websocket.zig` commit move together. Read
  [docs/toolchain.md](./docs/toolchain.md) before bumping either.
- Architecture decisions live in [docs/adr](./docs/adr).
- Research crib sheets live in [docs/research](./docs/research).
- Work tracking conventions are in [docs/agents/issue-tracker.md](./docs/agents/issue-tracker.md).
- `vendor/websocket.zig` is MIT-licensed; see its `LICENSE`.
