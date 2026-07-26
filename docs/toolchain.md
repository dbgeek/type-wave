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
| websocket.zig | `dev` @ commit `4b475a8` (the §3.5 TLS-read fix is now upstream) | a `url` + `hash` dependency in `build.zig.zon` — the root one and the cli-dictation prototype's, carrying the identical pair. The Zig package manager verifies the content hash on every fetch |
| Floor guard | `minimum_zig_version = "0.17.0-dev.1267+300116b02"` | every `build.zig.zon` in the repo |

Three things to understand about how the pin actually holds:

- **The websocket pin is machine-verified, and used to not be.** Until [#290](https://github.com/dbgeek/type-wave/issues/290)
  the library was vendored as plain files in *two* independently-editable trees, and the pin
  "was" the committed tree — meaning nothing tied those bytes to the upstream commit they
  claimed to be, and a fix applied to one copy could silently miss the other. The reason for
  vendoring had already evaporated (see below: the local patch went upstream, leaving an
  unmodified snapshot), so the trees are gone and the pin is the `url` + `hash` pair the
  package manager checks. A tampered mirror fails the fetch; a stale copy cannot exist.
- **flake.lock is the real lock.** `flake.nix` selects `zig-overlay…master` (the idiomatic way
  to get a nightly — zig-overlay exposes named attrs for `master` and *released* versions, not
  for arbitrary nightly strings), and `flake.lock` freezes which nightly `master` means. Anyone
  running `nix develop` gets `0.17.0-dev.1267+300116b02` until the lock is deliberately bumped.
- **`minimum_zig_version` is a floor, not a ceiling.** It makes the build fail loudly if
  someone compiles with a Zig *older* than the pinned nightly. It does **not** catch a `nix
  flake update` that bumps the compiler *forward* — a newer nightly passes the floor check but
  may still break websocket.zig's `dev` branch. The forward-drift guard is the flake.lock pin +
  this procedure, not `minimum_zig_version`.

### The §3.5 TLS-read fix (now upstream — patch dropped)

The §3.5 TLS-read starvation (a TLS handshake read starving against Cloudflare/api.openai.com's
bursty delivery — `Stream.read` polling the raw socket while a complete record already sits
decrypted-pending in the TLS `input` buffer; research §3.5) is **fixed upstream** as of `dev`
commit `4b475a8` ("Don't poll if tls has buffered client", `Closes #106`). The maintainer applied
his own fix rather than merging our one-liner
([PR #107](https://github.com/karlseguin/websocket.zig/pull/107) stayed open;
[#12](https://github.com/dbgeek/type-wave/issues/12) has the trail).

His fix is a **strict superset** of the one-line patch we carried: it gates the poll-skip on a
`hasBufferedTlsRecord` helper that fires only when a *complete* TLS record is buffered, so it also
handles the *partial*-record case (still polls, to honor the read timeout) that our cruder
"any buffered bytes" check got subtly wrong. So the one-line patch is **dropped** — and with it
the only reason we ever vendored. Having no local delta is what made [#290](https://github.com/dbgeek/type-wave/issues/290)'s
swap to a package-manager pin a lossless one: the vendored trees were proved byte-identical to
upstream `4b475a8` before they were deleted.

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
   built against the same/nearby zig-master, then re-pin to that commit's archive:

   ```sh
   zig fetch --save=websocket \
     https://github.com/karlseguin/websocket.zig/archive/<full-commit-sha>.tar.gz
   ```

   That rewrites the root `build.zig.zon`'s `url` + `hash` pair. Copy the same pair into
   `prototypes/cli-dictation/build.zig.zon` — the two must stay identical, which is the one
   thing this arrangement asks of you in exchange for there being no second tree to sync — and
   update the surrounding comment to the new commit. Pin the **full 40-character sha**, not the
   short one: the short form resolves today and the long form is what stays unambiguous.

   The §3.5 TLS-read fix is upstream as of `dev` `4b475a8`, so there is no local patch to
   re-apply. (If a future bump ever lands on a commit *before* the fix, re-check
   `Stream.read`/`hasBufferedTlsRecord` in `src/client/client.zig`. A bump that *does* need a
   local delta means re-vendoring — and re-reading [#290](https://github.com/dbgeek/type-wave/issues/290)
   first, because a vendored tree owes the integrity story the package manager was giving you
   for free.)

   Upstream's `build.zig.zon` `.paths` does not ship `LICENSE`, so the fetched package has no
   license text. Ours lives at `packaging/share/type-wave/LICENSES/websocket.zig-MIT.txt`;
   re-check it against upstream's `LICENSE` on a bump.

3. **Raise the floor.** Set `minimum_zig_version` to the new nightly string in **every**
   `build.zig.zon` (currently the two prototypes; later the root too).

4. **Rebuild clean and re-prove.** Clear stale caches and rebuild:

   ```sh
   rm -rf .zig-cache prototypes/*/.zig-cache
   nix develop --command zig build   # per project
   ```

   The stale-`.path`-dep hazard research §3.5 warns about is gone with the vendor trees — a
   hash-addressed package cannot be served stale under a changed pin, because a changed pin is
   a different cache entry.

   Then re-run the live end-to-end check (the CLI dictation loop against
   `wss://api.openai.com/v1/realtime`). If `dev` hasn't caught up to the new nightly yet
   (`std.Io` API breakage — expected per websocket.zig's readme), either wait for an upstream
   `dev` commit that has, or hold the pair on the previous nightly.

5. **Commit compiler + library together** (`flake.lock` and every `build.zig.zon`) in one
   commit, so the pair is never split across history.

If a bump can't be made to work, the sanctioned fallback is **not** the 0.16.0 pair but a
hand-rolled RFC 6455 client over `std.crypto.tls` (research §7) — std TLS ↔ api.openai.com is
independently proven, and it removes the nightly-chasing dependency entirely.
