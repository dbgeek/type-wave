# type-wave

**Hold-to-talk dictation for macOS.** Hold a key, speak, release, and the
transcribed text is inserted at the cursor of the app you are already using.

type-wave is a Zig daemon for Apple Silicon macOS. It captures with CoreAudio and
inserts through macOS event/pasteboard APIs, and transcribes with either of two
backends: **OpenAI's Realtime API** over WebSocket/TLS (streaming, the default), or an
**offline local Whisper** model (audio never leaves your Mac). It can run in the
foreground while developing, or as a signed per-user LaunchAgent for daily use.

<p align="center">
  <img src="assets/type-wave-demo.gif"
       alt="type-wave demo: hold a key, speak, release, and the text lands at your cursor"
       width="640">
</p>

> **Status:** experimental research project, `v0.4.2`, Apple Silicon macOS only.
> Single-maintainer, no support or SLA — small fixes welcome, larger changes worth
> discussing first. The hold-to-talk -> transcribe -> insert pipeline works end-to-end
> on either backend. Distribution hardening (hardened runtime, entitlements,
> notarization) is out of scope for now, so you build from source.

## How It Works

```mermaid
flowchart TD
    TK([Hold Talk Key, speak, release]) --> CAP[CoreAudio Capture]
    CAP --> ROUTER{Backend Router<br/>pins backend + settings + Vocabulary<br/>for this Utterance}
    ROUTER -->|OpenAI, default| OA[OpenAI Realtime<br/>Transcription Session<br/>Vocabulary biases as keywords]
    ROUTER -->|Local, offline| LW[Local Whisper Backend<br/>Segmenter cuts at silences<br/>Whisper Helper transcribes<br/>Vocabulary biases the prompt]
    OA --> FT[Final Transcript]
    LW --> FT
    FT --> BT{Backtrack on?<br/>OpenAI only}
    BT -->|yes| RW[OpenAI Rewrite<br/>corrections + fillers removed]
    BT -->|no / Local, or on failure| IR
    RW --> IR

    subgraph IW ["Insert Worker — one thread: dictation, then menu actions, then Undo"]
        IR[Insertion Runner]
        UR[Undo Runner]
    end

    IR --> CUR([Text at the Focused Target cursor])
    UR --> DEL([Backspaces at the Focused Target cursor])
    CUR --> RING[(Recent Insertions ring<br/>last 20 Insertion Records)]
    RING -.->|menu: Copy / Re-insert here| IR
    RING -.->|recovery chord ⌃⌘⌫| UR
```

The default **Talk Key** is Right Option. Holding it opens one **Utterance**; while it
is held, type-wave captures mic audio and routes it through the **Backend Router**, which
pins that Utterance to the selected **Transcription Backend** and to the settings in force
at press time. On release it commits the Utterance and waits for the **Final Transcript** —
the only text ever inserted — then the **Insertion Runner** places it at the **Focused
Target** cursor through either a clipboard-swap paste or synthetic keystrokes.

The two backends reach that same Final Transcript by different routes. **OpenAI**
streams: it emits revisable **Partial Transcripts** live, then commits the Final
Transcript on release. **Local Whisper** runs offline: its **Segmenter** cuts a long
Utterance into **Segments** at silences and hands each to the warm **Whisper Helper**
child process in the background, and the ordered **Segment Transcripts** concatenate into
the Final Transcript. In local mode the audio never leaves the Mac. An optional
**Vocabulary** — one hand-curated list of names, jargon, and identifiers edited from the menu
bar — biases spelling toward your terms on both backends: local Whisper takes it as the
Segment prompt, and OpenAI takes it as the `keywords` field of the session, re-bound on the
warm session the next time you edit it. On OpenAI it applies only to models known to accept
`keywords` (today `gpt-live-transcribe` and `gpt-transcribe`); with any other model pinned the
list is inert and the menu says so.

With the opt-in **Backtrack** setting on and OpenAI selected, one more stage sits between
the Final Transcript and Insertion: a single OpenAI **Rewrite** pass applies spoken
self-corrections ("at 20:00 no 18:00" → "at 18:00") and drops fillers ("um", "öh"), so the
inserted text is what you meant to say. Enablement is pinned at Talk Key press, a
mid-Utterance flip cannot half-apply, and any rewrite failure or timeout falls back to
inserting the raw transcript — dictation never breaks. Backtrack sends the transcript
**text** to OpenAI and needs internet; it does not apply on the Local backend, where the
raw transcript inserts unchanged.

What landed at the cursor is kept: each Insertion leaves an **Insertion Record** — the
bytes actually inserted, the raw transcript when a Rewrite changed it, a timestamp, the
outcome, and a best-effort hint at which app was frontmost — in an in-memory **Recent
Insertions** ring of the last 20, reachable under the menu bar for reveal, **Copy**, or
**Re-insert here**. The recovery chord `⌃⌘⌫` triggers **Undo**: one Backspace per extended
grapheme cluster of the newest record, so the pre-Insertion state is restored. Undo is
gated app-level — it proceeds only on positive evidence that the frontmost app is unchanged
since the Insertion — and is single-shot, so a second chord refuses rather than eating
earlier text. Every cursor path, dictation and menu action and Undo alike, is drained on
one **Insert Worker** thread (dictation first, Undo last), which is what keeps a deletion
from landing in the middle of an Insertion. Nothing here is ever written to disk; the ring
is cleared when the daemon quits.

One Utterance is deliberately not remembered: one spoken while any app holds **Secure Event
Input**, the session-wide mode a password field puts macOS into. type-wave probes at both Talk
Key press and release, and a positive reading on either edge withholds that Insertion Record
from the ring and keeps the transcript out of the log even under the `.log_transcripts` opt-in.
The text still lands at the cursor — it is simply never retained, so it cannot be revealed,
copied, re-inserted, or undone. While Secure Event Input is held the WindowServer also withholds
key events from every event tap, so the `⌃⌘⌫` chord never reaches the daemon at all; the menu
bar reports that state rather than leaving you to infer it from a chord that silently does
nothing.

Across the whole lifecycle the **Utterance Coordinator** owns the state machine from
Talk Key press to a resolved Insertion. The floating **HUD** is silent visual feedback
only — a red waveform while recording, green processing dots until the Utterance resolves,
an amber tint on a degraded Insertion, and a green or red mark for an Undo's confirm or
refuse; it never shows transcript text. A menu-bar **Status Item** derives readiness for
the selected backend, exposes the OpenAI/local chooser, and keeps full **Model
Installation** management reachable under either selection. A **Grant Observer** owns the
three macOS permission facts and the serialized cold-start request ladder that asks for
them — and its PostEvent fact is what authorizes Undo to post destructive Backspaces.

The project vocabulary is kept in [CONTEXT.md](./CONTEXT.md).

## Requirements

Common to both backends:

- Apple Silicon macOS.
- Nix with flakes, or a matching bare Zig nightly. See [docs/toolchain.md](./docs/toolchain.md).
- macOS grants for Input Monitoring, Accessibility, and Microphone.

Then pick a Transcription Backend:

- **OpenAI (default):** an OpenAI API key with access to Realtime transcription. Audio
  streams to OpenAI during dictation.
- **Local Whisper (offline):** no API key and no network at dictation time — only a
  one-time, credential-free download of the pinned model (Whisper Large v3 Turbo). Audio
  stays on your Mac.

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

The install step signs and atomically upgrades the compatible daemon/helper pair through one
shared pair pointer with the local `type-wave dev` identity, exposes them at
`~/.local/bin/type-wave` and `~/.local/libexec/type-wave/type-wave-whisper`, and writes the
LaunchAgent plist. It also installs pinned runtime/model provenance and license material under
`~/.local/share/type-wave/`. Running `--set-key` through the installed signed daemon stores
the OpenAI key in the login keychain so it can be read without prompts across rebuilds.

The one-time signing identity setup, LaunchAgent load/unload commands, and TCC grant
persistence checks are documented in [docs/packaging.md](./docs/packaging.md). Logs go
to `~/Library/Logs/type-wave.log` — they record that an Utterance resolved and how long
each stage took, never the words (set `.log_transcripts = true` while debugging a
transcription problem). **Local Model ▸ Clear log…** empties that file after a
confirmation, for disposing of a history an earlier version recorded verbatim; nothing
clears it automatically.

## Configuration

Every field is optional. Copy the annotated example when you want a hand-editable file:

```sh
mkdir -p ~/.config/type-wave
cp packaging/config.example.zon ~/.config/type-wave/config.zon
```

| Field | Default | Notes |
| --- | --- | --- |
| `transcription_backend` | `.openai` | `.openai` or `.local`; selection is a hard audio boundary |
| `talk_key` | `.right_option` | `.right_option`, `.left_option`, or `.globe` |
| `model` | `"gpt-live-transcribe"` | String, so model experiments do not require a rebuild |
| `language` | `"en"` | `"en"`, `"sv"`, or `""` for auto-detect |
| `delay` | `"low"` | `"minimal"`, `"low"`, `"medium"`, `"high"`; other strings stay hand-editable |
| `noise_reduction` | `.near_field` | `.near_field`, `.far_field`, or `.off` |
| `insertion` | `.paste` | `.paste` or `.keystroke`; paste transits the general pasteboard for ~300 ms ([accepted limitations](./SECURITY.md#accepted-limitations)) |
| `pre_paste_ms` | `25` | Pasteboard settle delay before Cmd-V |
| `overlay` | `true` | Show the silent waveform/processing HUD |
| `backtrack` | `false` | Opt-in OpenAI rewrite of spoken self-corrections and fillers; OpenAI backend only, sends transcript text to the cloud |
| `vocabulary` | `.{}` | Phrase biasing on both backends; usually edited from the menu bar, empty = off |
| `log_transcripts` | `false` | Debugging opt-in that logs the words; never applies to a Secure Event Input Utterance |

> **Migrating from before 0.4.0:** the default model flipped from
> `gpt-realtime-whisper` to `gpt-live-transcribe`
> ([#303](https://github.com/dbgeek/type-wave/issues/303)). A config that pins
> `.model` keeps its pinned model — delete the `.model` line from `config.zon` to
> adopt the new default, or pin `"gpt-realtime-whisper"` to stay on the old one.
> No rebuild either way.

The menu bar is the live settings writer. It swaps in complete immutable settings
snapshots and patches single fields in `config.zon` while preserving comments. Hand
edits are picked up on restart or the next time the menu opens.

Secrets do not live in `config.zon`. Key precedence is:

1. `OPENAI_API_KEY` from the process environment, for foreground dev runs.
2. The login keychain item created by the menu or `~/.local/bin/type-wave --set-key`.
3. One-time migration from the retired `~/.config/type-wave/env` file, if present.

The migration finishes the job: once the keychain provably hands the key back, the daemon
overwrites and deletes that plaintext file rather than leaving it on disk. A file left over
from an earlier migration is removed the next time the daemon reads the keychain.

The pinned local Model Installation (Whisper Large v3 Turbo) downloads credential-free.
Explicitly start the Model Operation:

```sh
~/.local/bin/type-wave --install-model
```

The operation starts only at the exact pinned `huggingface.co` coordinates, follows the
CDN redirect only back into Hugging Face's own DNS over TLS — every hop, not just the
first — and checkpoints only exact validator-matched byte ranges. A cancelled or interrupted operation
never resumes network activity on restart; inspect it with `--model-status`, then explicitly
choose `--resume-model` or `--discard-model`. Download and hashing progress are byte-accurate,
transient retries stop after the displayed budget, and Ctrl-C cooperatively cancels transfer,
hashing, or the helper smoke test. Activation is the only short non-cancellable stage.

`--model-status` derives update availability by comparing the active receipt with the complete
identity embedded in the running type-wave release. An older verified installation remains
ready for offline dictation while `--update-model` stages, verifies, and smoke-tests its
replacement. Activation waits for active local inference to drain, then atomically switches
the receipt; failure or cancellation leaves the working installation selected and usable.
`--remove-model` deletes the installation after an interactive confirmation; the Local backend
stays selected if it was, and is simply unavailable until the next Install.

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

Plain builds default to `ReleaseFast`, matching the installed daemon, and produce both the
daemon and the private helper from the byte-verified whisper.cpp v1.9.1 source archive. Use
`-Dwhisper-archive=/path/to/whisper.cpp-v1.9.1.tar.gz` for an offline build. `capture-check`
is a live CoreAudio start/stop probe and uses real microphone IO.

## Architecture

The daemon is thin wiring around testable state machines and OS adapters. It transcribes
through either of two backends — OpenAI Realtime (streaming, the default) or offline local
Whisper — selected at runtime behind a Backend Router.

The **Utterance Coordinator** in `src/coordinator.zig` owns the utterance lifecycle:
`idle -> capturing -> awaiting_final -> rewriting -> inserting -> idle`. The optional
`rewriting` phase runs the Backtrack pass (OpenAI only) when it applies and is otherwise a
pass-through. It handles the overlap guard, release-anchored deadline, empty or failed
transcripts, dropped sessions, and failed insertions. Hardware and OS effects reach it
through seams.

`src/daemon.zig` builds the real adapters, starts the threads, runs the menu/HUD/tap main
loop, and drives readiness through a pure per-tick self-heal decider (`src/supervisor.zig`).
Several state machines run outside the Coordinator: configuration readiness
(`src/configuration_phase.zig`), OpenAI link state (`src/session.zig`), backend selection
(`src/backend_router.zig`), local load-failure classification
(`src/local_model_recovery.zig`), the local Whisper helper lifecycle
(`src/whisper_supervisor.zig`), and the TCC grant facts plus their cold-start request
ladder (`src/grants.zig`).

Everything that touches the cursor is serialized on one **Insert Worker** thread
(`insertion_runner.workerLoop`), which drains two runners in priority order: dictation
Insertions and the menu's Copy / Re-insert jobs (`src/insertion_runner.zig`), then Undo
(`src/undo.zig`). Both follow one rule — every cursor job resolves at drain time, beside
the effect it authorizes, and the bookkeeping in the Recent Insertions ring
(`src/recent_insertions.zig`) flips only after that effect landed (ADR-0006, ADR-0008,
ADR-0009).

**Core pipeline**

| Module | Role |
| --- | --- |
| `src/main.zig` | CLI entry point: `--set-key` and the `*-model` subcommands |
| `src/daemon.zig` | Long-running daemon wiring, threads, supervisor, menu seams |
| `src/coordinator.zig` | Utterance lifecycle state machine |
| `src/supervisor.zig` | Pure per-tick self-heal decider and capture-enable gate |
| `src/appkit.zig` | NSApplication bring-up and main run loop |

**Transcription backends**

| Module | Role |
| --- | --- |
| `src/backend_router.zig` | Utterance-to-backend routing with the drain-then-switch selection FSM |
| `src/transcription_backend.zig` | Backend-neutral transcription contract and deadline types |
| `src/session.zig` | Warm OpenAI Realtime transcription session and reconnect logic |
| `src/local_backend.zig` | Segmenting local Whisper transcription backend adapter |
| `src/segmenter.zig` | Pure silence-cut segment policy |
| `src/vocab.zig` | Pure vocabulary glossary construction and token-budget hint |

**Local Whisper runtime**

| Module | Role |
| --- | --- |
| `src/whisper_runtime.zig` | whisper.cpp Metal runtime FFI wrapper |
| `src/whisper_helper.zig` | Whisper Helper subprocess server (runtime plus IPC loop) |
| `src/whisper_helper_core.zig` | Pinned model identity and inference preparation/gate core |
| `src/whisper_ipc.zig` | Whisper Helper IPC frame protocol |
| `src/whisper_process_helper.zig` | Parent-side warm helper process owner and relaunch ladder |
| `src/whisper_supervisor.zig` | Whisper Helper event/state machine and recovery budget |
| `src/signing_identity.zig` | Signing Identity gate: proves the Whisper Helper binary before it is spawned |

**Local model provisioning & storage**

| Module | Role |
| --- | --- |
| `src/model_store.zig` | Explicit credential-free Model Operations and atomic Model Installation activation |
| `src/model_operation.zig` | Model Operation child-process runner and its observation |
| `src/operation_channel.zig` | Typed Model Operation observation wire (child stdout) |
| `src/local_provisioner.zig` | Warms the local backend with corruption-vs-runtime recovery latch |
| `src/local_model_recovery.zig` | Local integrity verification versus runtime-load recovery policy |
| `src/layout.zig` | Single owner of the on-disk models-root path grammar |
| `src/artifact_identity.zig` | Pure size/sha256 model-artifact identity codec |
| `src/installation_identity.zig` | Owned Model Installation receipt identity for cross-thread presentation |
| `src/receipt.zig` | Installation Receipt codec (schemas plus PROVENANCE/partial.meta) |

**Configuration & readiness**

| Module | Role |
| --- | --- |
| `src/config.zig` | ZON settings, key loading, immutable settings snapshots, config writes |
| `src/configuration_phase.zig` | Setup readiness transitions and reporting |
| `src/readiness.zig` | Pure readiness/status policy |
| `src/grants.zig` | Grant Observer: the three TCC grant facts and their serialized cold-start request sequence |
| `src/api_key.zig` | Key Holder: the daemon's single OpenAI key copy, zeroed before release |
| `src/failure_observation.zig` | Cross-thread failure snapshot the status item reads |

**Audio, insertion & input**

| Module | Role |
| --- | --- |
| `src/capture.zig` | CoreAudio capture |
| `src/tap.zig` | Global Talk Key observation and the `⌃⌘⌫` recovery chord |
| `src/secure_input.zig` | Secure Input Observer: pure decider that narrates a held Secure Event Input |
| `src/insert.zig` | Clipboard paste and synthetic keystroke insertion |
| `src/insertion_runner.zig` | Insertion Runner: dictation and menu cursor jobs, and the Insert Worker loop |
| `src/app_focus.zig` | Best-effort App Identity read at insertion time |

**Recent Insertions & Undo**

| Module | Role |
| --- | --- |
| `src/recent_insertions.zig` | Daemon-owned, leaf-locked ring of the last 20 Insertion Records |
| `src/undo.zig` | Undo Runner: app-level focus gate, deletion, single-shot `undone` flag, cue |
| `src/grapheme.zig` | Extended-grapheme-cluster count — how many Backspaces an Undo posts |

**Backtrack rewrite**

| Module | Role |
| --- | --- |
| `src/rewrite_adapter.zig` | Async Backtrack rewrite worker; falls back to the raw transcript on failure |
| `src/openai_rewrite.zig` | OpenAI Responses API rewrite mechanism over a warm HTTPS client |

**UI, feedback & platform**

| Module | Role |
| --- | --- |
| `src/menu.zig` | Menu-bar AppKit item and live settings UI |
| `src/status_item.zig` | Pure status-item presentation policy |
| `src/hud.zig` | Silent waveform/processing overlay |
| `src/surface.zig` | HUD-vs-sound feedback arbitration |
| `src/feedback.zig` | Sound cues and timestamped logging |
| `src/keychain.zig` | OpenAI login-Keychain item |
| `src/broken_pipe.zig` | Process-wide SIGPIPE disposition: a dead reader fails the write, not the process |
| `src/info_plist.zig` | Embedded `Info.plist` Mach-O section |

## Repository Layout

```text
src/                 daemon source
docs/                toolchain, packaging, ADRs, research notes, agent docs
packaging/           Info.plist, LaunchAgent plist, install script, config example
acceptance/          deterministic local-backend release-gate tests (zig build acceptance-test)
tools/               whisper.cpp runtime build script and the helper probe
prototypes/          spikes that proved capture, insertion, menu, and HUD behavior
build.zig.zon        the url+hash pin for karlseguin/websocket.zig
flake.nix            development shell pinning the Zig nightly
```

## Notes

- The Zig nightly and the `websocket.zig` commit move together. Read
  [docs/toolchain.md](./docs/toolchain.md) before bumping either.
- Architecture decisions live in [docs/adr](./docs/adr).
- Research crib sheets live in [docs/research](./docs/research).
- Work tracking conventions are in [docs/agents/issue-tracker.md](./docs/agents/issue-tracker.md).

## Support

type-wave is a single-maintainer side project. If it's useful to you and you'd
like to support continued work, you can [sponsor me on GitHub](https://github.com/sponsors/dbgeek).
Entirely optional — issues and small PRs are just as welcome.

## License

type-wave is released under the [MIT License](./LICENSE), Copyright (c) 2026
Björn Ahl.

It builds on MIT-licensed third-party components (`websocket.zig`, whisper.cpp,
and the Whisper large-v3-turbo model), none of them vendored into this tree.
Their attributions and license-text locations are listed in
[THIRD-PARTY-NOTICES.md](./THIRD-PARTY-NOTICES.md), which also says where each
one's pin lives: `build.zig.zon` for the Zig dependency,
[packaging/share/type-wave/PROVENANCE](./packaging/share/type-wave/PROVENANCE)
for the two artifacts our own tooling downloads.
