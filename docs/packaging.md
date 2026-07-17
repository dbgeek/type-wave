# Packaging: signed TCC identity + LaunchAgent

type-wave runs as a **headless per-user LaunchAgent** with a **stable code-signing
identity**, so its three TCC grants — Input Monitoring (the Talk Key tap), Accessibility
(PostEvent, for Insertion), and Microphone (Capture) — **survive rebuilds**. This note is
the one-time setup, the install/load commands, and the grant-persistence verification.
Background: [the daemon-architecture design (#10)](https://github.com/dbgeek/type-wave/issues/10)
§2 and [the packaging ticket (#15)](https://github.com/dbgeek/type-wave/issues/15).

## Why a stable signing identity

TCC keys each grant to the responsible process's **code identity**. A plain Zig arm64
build is only *ad-hoc* signed, so TCC keys on the **cdhash** — which changes on every
build, silently dropping all three grants each rebuild. Signing with a **stable
self-signed certificate** instead keys the grants to the certificate, via the signature's
**Designated Requirement** (roughly `identifier "me.ba78.type-wave" and certificate leaf =
H"<cert hash>"`). Neither half of that requirement depends on the binary's code, so a
rebuilt-and-re-signed binary satisfies the *same* requirement and **keeps the grants**.

Two more pieces make the identity whole, both already wired into the build:

- A fixed install path, `~/.local/bin/type-wave` (the LaunchAgent points here, not
  `zig-out/`).
- An embedded **Info.plist** in the `__TEXT,__info_plist` Mach-O section
  (`src/info_plist.zig` ← `packaging/Info.plist`), carrying the stable
  `CFBundleIdentifier` `me.ba78.type-wave` and `NSMicrophoneUsageDescription`. For a bare
  (non-`.app`) tool that section *is* the Info.plist that macOS and `codesign` read.

Out of scope for now (distribution — fog): hardened runtime, entitlements, notarization.

## One-time: create the signing identity

Create a self-signed **code-signing** certificate named **`type-wave dev`** in your
**login** keychain. Via Keychain Access (the reliable, GUI path):

1. Open **Keychain Access**.
2. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Set:
   - **Name:** `type-wave dev`
   - **Identity Type:** `Self Signed Root`
   - **Certificate Type:** `Code Signing`
4. (Optional but recommended) tick **Let me override defaults** and bump the validity
   period (e.g. 3650 days) so the cert doesn't expire out from under your grants; keep it
   in the **login** keychain.
5. **Create**, then **Done**.

Confirm the toolchain can see it as a valid code-signing identity:

```sh
security find-identity -v -p codesigning | grep "type-wave dev"
```

If it does **not** appear, mark it trusted for code signing: in Keychain Access,
double-click the `type-wave dev` cert → **Trust** → **Code Signing: Always Trust**, then
re-check the command above.

> The installer refuses to run until this identity exists (it prints this section). You
> can name the cert differently and pass `TYPE_WAVE_SIGN_IDENTITY="my name"` to the build.

## Install

```sh
nix develop --command zig build install-agent
```

This builds the binary, **code-signs** it with `type-wave dev` (identifier
`me.ba78.type-wave`), installs it to `~/.local/bin/type-wave`, and renders +
installs the LaunchAgent plist to `~/Library/LaunchAgents/me.ba78.type-wave.plist`
(absolute paths baked in — launchd does not expand `~`/`$HOME`). It does **not** start
the daemon; loading it triggers the permission prompts, so that stays a deliberate step.

## Load / unload

```sh
# load (start) — RunAtLoad launches it immediately
launchctl bootout  gui/$(id -u) ~/Library/LaunchAgents/me.ba78.type-wave.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/me.ba78.type-wave.plist

# unload (stop) — a clean bootout stays down (KeepAlive only respawns on a crash)
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/me.ba78.type-wave.plist
```

Logs (both stdout and stderr): `~/Library/Logs/type-wave.log`.

## Grant the three permissions

On its first run under launchd the daemon is its **own** TCC-responsible process, so the
prompts (and the entries in **System Settings → Privacy & Security**) are attributed to
**type-wave** (`me.ba78.type-wave`), not to a terminal. Enable it under all three:

- **Input Monitoring** — the Talk Key tap.
- **Accessibility** — PostEvent, for Insertion (`kTCCServicePostEvent` surfaces here).
- **Microphone** — Capture (prompted on the first Utterance, with the Info.plist
  rationale).

> **`OPENAI_API_KEY`.** A launchd process has no shell environment, so the daemon reads the
> key from the **login keychain** ([#33](https://github.com/dbgeek/type-wave/issues/33);
> service `me.ba78.type-wave`, account `openai-api-key`). Store it once via the installed
> signed binary — `~/.local/bin/type-wave --set-key` — so the item's ACL keys to the stable
> `type-wave dev` signature and every later read is prompt-free (see `src/keychain.zig`).
> **No plist `EnvironmentVariables` secret hack is needed**; never put the key in a committed
> plist. A key still sitting in the legacy `~/.config/type-wave/env` file is auto-migrated
> into the keychain the first time the daemon looks for it (the log says when the file can
> be deleted). A missing key is not fatal: the self-heal supervisor polls until one appears.

The Hugging Face token for an explicit local-model operation is a second generic-password
item under the same service, account `huggingface-token`, label
`type-wave Hugging Face token`. Store it separately with
`~/.local/bin/type-wave --set-hf-token`; `HF_TOKEN` is a foreground-only override for
`--install-model` or `--resume-model` and is never written to Keychain or the LaunchAgent
plist. Interrupted work stays paused without automatic network access; use `--model-status`,
then explicitly run `--resume-model` or `--discard-model`.

## Verify grant persistence across a rebuild (the point of #15)

After granting the permissions once:

1. Record the Designated Requirement TCC keys the grants to:

   ```sh
   codesign -d --requirements - ~/.local/bin/type-wave
   ```

   Expect something like `identifier "me.ba78.type-wave" and certificate leaf = H"…"`.

2. Rebuild and reinstall from scratch:

   ```sh
   rm -rf .zig-cache zig-out
   nix develop --command zig build install-agent
   launchctl bootout  gui/$(id -u) ~/Library/LaunchAgents/me.ba78.type-wave.plist 2>/dev/null || true
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/me.ba78.type-wave.plist
   ```

3. Confirm the Designated Requirement is **unchanged** (same cert → same requirement), and
   that System Settings still shows the three grants enabled — **no re-granting**.
   Dictation should work immediately after the rebuild.

Contrast: had the binary been ad-hoc signed (`codesign -s -`), step 3 would show a
different cdhash-based requirement and the grants would have dropped.

## Uninstall

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/me.ba78.type-wave.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/me.ba78.type-wave.plist
rm -f ~/.local/bin/type-wave
# optionally: remove the three entries under System Settings → Privacy & Security,
# and delete the "type-wave dev" cert from Keychain Access.
```

This leaves Model Installations and both login-Keychain items intact. Remove model data
under `~/Library/Application Support/type-wave/models/`, the `openai-api-key` item, and the
`huggingface-token` item only as separate, explicit actions.
