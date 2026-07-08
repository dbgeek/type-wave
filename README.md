# type-wave

**Hold-to-talk dictation for macOS.** Hold a key, speak, release — the transcribed
text lands at the cursor of whatever app is focused. Built for whisper-quiet speech,
running headless in the background.

> Status: research repo, `v0.0.0`, macOS-only. Built [Zig](https://ziglang.org)
> against the OpenAI Realtime transcription API. The full mic → transcribe → insert
> pipeline runs end-to-end; distribution (notarization, hardened runtime) is still fog.

## How it works

```
hold Talk Key ─► CoreAudio Capture (24 kHz mono s16le)
                     │
                     ▼
              OpenAI Realtime Transcription Session  (warm, reconnecting websocket)
                     │  Partial Transcripts stream back while you speak
                     ▼
release Talk Key ─► commit ─► Final Transcript ─► Insertion at the Focused Target's cursor
```

You hold the **Talk Key** (Right-Option by default), speak one **Utterance**, and
release. Audio streams to a warm OpenAI Transcription Session that keeps itself
connected between Utterances; **Partial Transcripts** stream back as live feedback
while you hold; on release the **Final Transcript** is committed and inserted at the
cursor via a clipboard-swap paste (or synthetic keystrokes). A floating overlay pill
shows the live partials, plus sound cues for start / stop / error.

The vocabulary above (Utterance, Talk Key, Partial/Final Transcript, Insertion,
Focused Target, Capture, Transcription Session) is the project's ubiquitous language —
see [`CONTEXT.md`](./CONTEXT.md) for the precise definitions the code and docs use.

## Requirements

- **macOS** (Apple Silicon; uses CoreAudio, CoreGraphics, AppKit, Carbon).
- **[Nix](https://nixos.org)** with flakes — pins the exact Zig nightly the WebSocket/TLS
  stack needs. (Bare Zig works too if you match the pinned nightly; see
  [`docs/toolchain.md`](./docs/toolchain.md).)
- An **OpenAI API key** with access to the Realtime transcription API.

## Quick start (foreground)

```sh
# 1. Provide the OpenAI secret (the dev override for foreground runs)
export OPENAI_API_KEY=sk-...

# 2. Build and run the daemon in the foreground
nix develop --command zig build run
```

On first run macOS prompts for **Input Monitoring** (the Talk Key tap),
**Accessibility** (Insertion), and **Microphone** (Capture). Grant all three, then
hold Right-Option and speak. The daemon **self-heals**: a missing key or ungranted
permission never crashes it — it logs what it's waiting on and goes live the moment the
prerequisite appears.

`nix develop` alone drops you into a dev shell with the pinned Zig on `PATH`; if a
legacy `~/.config/type-wave/env` file exists, the shell sources it so the override is
exported automatically.

## Configuration

Every setting is optional. Copy the annotated example and edit:

```sh
cp packaging/config.example.zon ~/.config/type-wave/config.zon
```

| Field | Default | Notes |
|---|---|---|
| `talk_key` | `.right_option` | `.right_option` / `.left_option` (proven), `.globe` (Fn key, opt-in) |
| `model` | `"gpt-realtime-whisper"` | A/B a different model with no rebuild |
| `language` | `"en"` | |
| `delay` | `"low"` | |
| `noise_reduction` | `.near_field` | `.near_field` / `.far_field` / `.off` |
| `insertion` | `.paste` | `.paste` (clipboard + ⌘V) or `.keystroke` (synthetic typing) |
| `overlay` | `true` | The floating live-partials pill; `false` = sound-only |

An absent or malformed `config.zon` falls back to all defaults, so a typo never keeps
the daemon from starting. The OpenAI secret lives in the **login keychain** (set it with
`~/.local/bin/type-wave --set-key`), never in `config.zon` or a committed plist; an
exported `OPENAI_API_KEY` overrides it for foreground dev runs. A key from the retired
`~/.config/type-wave/env` file is migrated into the keychain automatically on first
sight — the daemon logs when the file can be deleted.

## Install as a background daemon

For daily-driver use, install type-wave as a headless per-user **LaunchAgent** with a
stable code-signing identity — so its three permission grants **survive rebuilds**:

```sh
nix develop --command zig build install-agent

# then store the API key in the login keychain, via the *installed signed* binary:
~/.local/bin/type-wave --set-key
```

Plain builds in this repo default to Zig's `ReleaseFast` optimization mode, so
`zig build install-agent` installs a speed-optimized binary without needing
`-Doptimize=ReleaseFast`.

This requires a one-time self-signed `type-wave dev` code-signing certificate and a
`launchctl bootstrap` to start it. The full procedure — creating the identity, loading /
unloading, granting permissions, and verifying grant persistence across a rebuild — is in
[`docs/packaging.md`](./docs/packaging.md). Logs land in `~/Library/Logs/type-wave.log`.

`--set-key` must run via `~/.local/bin/type-wave` (not `zig-out/`): the keychain item's
ACL keys to its creator's code signature, so only the stable-signed binary gives the
daemon prompt-free reads across rebuilds (`src/keychain.zig` has the full story).

## Development

```sh
nix develop --command zig build            # build the daemon → zig-out/bin/type-wave
nix develop --command zig build test       # Coordinator lifecycle matrix + pure-function tests
nix develop --command zig build capture-check   # live Capture start/stop regression probe (real mic IO)
```

Build optimization defaults to `ReleaseFast` for the daemon, tests, and local probes.
Override it explicitly when you need a different tradeoff:

```sh
nix develop --command zig build -Doptimize=Debug       # development checks + easier debugging
nix develop --command zig build -Doptimize=ReleaseSafe # optimized, with runtime safety checks
nix develop --command zig build -Doptimize=ReleaseSmall # optimized for binary size
```

### Architecture

The daemon is thin wiring around a testable core. The **Utterance Coordinator**
(`src/coordinator.zig`) is a single synchronous state machine —
`idle → capturing → awaiting_final → inserting → idle` — that owns the whole lifecycle
policy (overlap guard, poison-on-drop abandonment, the release-anchored deadline,
empty/failed handling). It reaches the outside world only through four seams, so it's
exercised by feeding it events, not hardware. `daemon.zig` builds the real adapters
behind those seams and runs the supervisory state machines (self-heal + link state).

| Module | Role |
|---|---|
| `coordinator.zig` | The Utterance Coordinator — the tested lifecycle state machine |
| `daemon.zig` | Wiring: real adapters, threads, self-heal supervisor |
| `capture.zig` | CoreAudio Capture via AudioQueue (24 kHz mono s16le) |
| `session.zig` | OpenAI Realtime Transcription Session (warm, reconnecting websocket) |
| `tap.zig` | Global Talk Key observation (listen-only `CGEventTap`) |
| `insert.zig` | Insertion — pasteboard swap + ⌘V, or synthetic keystrokes |
| `surface.zig` | Feedback Surface — HUD-vs-cue arbitration |
| `hud.zig` | Overlay pill, driven purely through the ObjC runtime C API |
| `feedback.zig` | Sound cues + timestamped logging |
| `config.zig` | ZON settings + env-file secret loading |
| `info_plist.zig` | Embeds `Info.plist` into the `__TEXT,__info_plist` section |

Key design records live in [`docs/adr/`](./docs/adr) (e.g. why the Utterance lifecycle is
fully serialized) and the research crib sheets that seeded each piece are in
[`docs/research/`](./docs/research).

## Repository layout

```
src/                 the daemon and its modules
docs/
  toolchain.md       the pinned Zig ↔ websocket.zig pair and bump procedure
  packaging.md       signing identity + LaunchAgent install
  adr/               architecture decision records
  research/          research crib sheets (CoreAudio, TLS, insertion, hotkeys, OpenAI)
  agents/            issue-tracker (wayfinder) conventions
packaging/           Info.plist, LaunchAgent plist, install.sh, config.example.zon
prototypes/          throwaway spikes that proved the pipeline before it was graduated
vendor/              vendored karlseguin/websocket.zig (with the §3.5 TLS-read fix)
flake.nix            dev shell pinning the Zig nightly
```

## Notes

- The websocket/TLS stack rides a **pinned Zig nightly + `websocket.zig` `dev`** pair
  that must move in lockstep. Don't `nix flake update` casually — read
  [`docs/toolchain.md`](./docs/toolchain.md) first.
- Work is tracked as [GitHub Issues](https://github.com/dbgeek/type-wave/issues) using the
  *wayfinder* map/ticket convention (see [`docs/agents/issue-tracker.md`](./docs/agents/issue-tracker.md)).
- `vendor/websocket.zig` is MIT-licensed (see its `LICENSE`).
