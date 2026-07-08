# Toolchain pinning: Zig ↔ websocket.zig

type-wave's WebSocket-over-TLS stack rides two versions that **must move in lockstep**: the
Zig compiler (a `zig-master` nightly) and `karlseguin/websocket.zig` (its `dev` branch). This
note records the pinning decision, the current pinned pair, and the procedure for bumping them
together. Background and evidence: [`docs/research/zig-websocket-tls.md`](./research/zig-websocket-tls.md) §9.

## Decision: stay on the nightly pair

We pin the **zig-master nightly + websocket.zig `dev`** pair rather than de-risking to the
"stable" **Zig 0.16.0 + websocket.zig `master`** pair.

Why:

- **The nightly pair is proven live.** The full mic → transcribe → insert pipeline ran
  end-to-end against `wss://api.openai.com/v1/realtime` on exactly this pair
  ([Prototype the CLI dictation loop, #8](https://github.com/dbgeek/type-wave/issues/8);
  research §2). That is the configuration all the code in this repo was written and validated
  against.
- **The 0.16.0 de-risk is untested and self-described as experimental.** websocket.zig's
  `master` branch (the 0.16-targeting one) "was **not** tried against 0.17-dev" in the
  research, and the library's own readme calls that branch "not well tested… experimental"
  (research §3.3, §9). Switching would mean re-porting our code across the 0.16 ↔ 0.17-dev
  `std.Io` API differences, re-checking whether the §3.5 TLS-read bug even exists on `master`,
  and re-proving the whole live pipeline — trading a proven config for an unproven one.
- **"Stable" buys nothing here.** The only real hazard of the nightly is that `nix flake
  update` silently bumps the compiler. That is fully handled by the pin mechanism below — the
  flake.lock reproduces the exact nightly, and a bump is a deliberate, documented step, not a
  drift.

Reassess only if upstream websocket.zig stops tracking zig-master, or the `dev` branch breaks
against a nightly we need and can't easily patch.

## The currently pinned pair

| Component | Pin | Where it's pinned |
|---|---|---|
| Zig compiler | `0.17.0-dev.1267+300116b02` | `flake.lock` → `zig-overlay` rev `be62cd684cf34f701cd1b91f2aa0c056c29fafa1` (locked 2026-07-07), which resolves `zig-overlay.packages.<system>.master` to this nightly |
| websocket.zig | `dev` @ commit `2283d22` **+ the §3.5 TLS-read fix** | vendored as plain files under `prototypes/cli-dictation/vendor/websocket.zig` (a `.path` dependency), so the pin *is* the committed tree |
| Floor guard | `minimum_zig_version = "0.17.0-dev.1267+300116b02"` | every `build.zig.zon` in the repo |

Two things to understand about how the pin actually holds:

- **flake.lock is the real lock.** `flake.nix` selects `zig-overlay…master` (the idiomatic way
  to get a nightly — zig-overlay exposes named attrs for `master` and *released* versions, not
  for arbitrary nightly strings), and `flake.lock` freezes which nightly `master` means. Anyone
  running `nix develop` gets `0.17.0-dev.1267+300116b02` until the lock is deliberately bumped.
- **`minimum_zig_version` is a floor, not a ceiling.** It makes the build fail loudly if
  someone compiles with a Zig *older* than the pinned nightly. It does **not** catch a `nix
  flake update` that bumps the compiler *forward* — a newer nightly passes the floor check but
  may still break websocket.zig's `dev` branch. The forward-drift guard is the flake.lock pin +
  this procedure, not `minimum_zig_version`.

### The vendored §3.5 patch

The vendored websocket.zig carries a one-line fix on top of `2283d22`: `Stream.read` in
`src/client/client.zig` also checks `tls_client.client.input.bufferedLen()` so a TLS handshake
read doesn't starve against Cloudflare/api.openai.com's bursty delivery (research §3.5). It is
filed upstream as [karlseguin/websocket.zig#107](https://github.com/karlseguin/websocket.zig/pull/107)
([File the websocket.zig TLS-read fix upstream, #12](https://github.com/dbgeek/type-wave/issues/12)).
**Keep carrying the patch until #107 merges**; only then does a bump drop it.

> New root project note: when the root `build.zig` / `build.zig.zon` is scaffolded
> ([Scaffold the daemon skeleton, #14](https://github.com/dbgeek/type-wave/issues/14)), it must
> (a) set the same `minimum_zig_version`, and (b) vendor websocket.zig at the same commit with
> the §3.5 patch still applied.

## Bump procedure

Bumping the compiler and websocket.zig is **one atomic change** — never bump one without the
other. Do it deliberately, on its own branch/commit, and re-prove the live pipeline before
trusting it.

1. **Bump the compiler** (updates `flake.lock`):

   ```sh
   nix flake update zig-overlay      # or `nix flake update` to bump everything
   nix develop --command zig version # note the new nightly string, e.g. 0.17.0-dev.XXXX+YYYY
   ```

2. **Bump websocket.zig to a `dev` commit that matches that nightly.** Find a `dev` commit
   built against the same/nearby zig-master, then refresh the vendored tree and **re-apply the
   §3.5 patch** (until #107 merges):

   ```sh
   # in a scratch checkout:
   zig fetch --save git+https://github.com/karlseguin/websocket.zig#dev   # resolves & prints the commit
   ```

   Replace the files under `prototypes/cli-dictation/vendor/websocket.zig` (and, once it
   exists, the root project's vendored copy) with that commit's tree, then re-apply the §3.5
   `input.bufferedLen()` check to `src/client/client.zig` if upstream still lacks it. Update the
   `// Vendored at commit …` comment in `build.zig.zon` to the new hash.

3. **Raise the floor.** Set `minimum_zig_version` to the new nightly string in **every**
   `build.zig.zon` (currently the two prototypes; later the root too).

4. **Rebuild clean and re-prove.** Clear stale caches and rebuild — a patched `.path` dep is
   easy to serve stale (research §3.5):

   ```sh
   rm -rf .zig-cache prototypes/*/.zig-cache
   nix develop --command zig build   # per project
   ```

   Then re-run the live end-to-end check (the CLI dictation loop against
   `wss://api.openai.com/v1/realtime`). If `dev` hasn't caught up to the new nightly yet
   (`std.Io` API breakage — expected per websocket.zig's readme), either wait for an upstream
   `dev` commit that has, or hold the pair on the previous nightly.

5. **Commit compiler + library together** (`flake.lock`, the vendored tree, and every
   `build.zig.zon`) in one commit, so the pair is never split across history.

If a bump can't be made to work, the sanctioned fallback is **not** the 0.16.0 pair but a
hand-rolled RFC 6455 client over `std.crypto.tls` (research §7) — std TLS ↔ api.openai.com is
independently proven, and it removes the nightly-chasing dependency entirely.
