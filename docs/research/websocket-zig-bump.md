# Is there value in bumping the websocket.zig pin?

Researched 2026-08-18 against primary sources — the GitHub API for
[karlseguin/websocket.zig](https://github.com/karlseguin/websocket.zig) (commit list, full
diffs, PR/issue state), the raw source and readme at the `dev` HEAD, the Zig std source
shipped with the flake's own pinned compiler, and **two compile probes run on this machine**
with both the pinned nightly and today's zig-overlay `master` nightly. Nothing was built in
the repo and nothing in the working tree was touched; probes lived in the session scratchpad.
Policy context: [docs/toolchain.md](../toolchain.md). Background:
[zig-websocket-tls.md](./zig-websocket-tls.md) §3.5, §9.

Every claim below says whether it is **verified by running**, **verified by reading a primary
source**, or **inference**.

## Recommendation (TL;DR)

**Don't bump now. Nothing has landed upstream that this repo needs, and nothing we work
around has been fixed. Fold the bump into the next compiler bump, per the lockstep policy.**

- Upstream `dev` is exactly **3 commits ahead** of our pin and 0 behind (§1). All three touch
  only `src/client/client.zig` (plus a readme typo). None touch the server, the handshake, the
  framing/masking path, close frames, the buffer/allocator layer, or any `std.Io` adaptation.
- The **net functional delta is one new feature and one unreachable one-liner** (§2):
  a `connect_timeout_ms` config knob (default 10 s) bounding the TCP connect and the TLS
  handshake, and an INT_MAX clamp on the `poll()` read-timeout cast. We set no read timeout at
  all, so the clamp is dead code for us.
- The TLS-read fix we depend on (§3.5, upstream `4b475a8` — our pin) was **accidentally
  reverted on 2026-07-11 and restored on 2026-08-11** (§3). It is byte-identical at `dev` HEAD
  to what we already have. This is the one genuinely load-bearing finding: it means "any newer
  `dev` commit" is *not* automatically safe — only `bfe7619` or later.
- A bump would **not** force a Zig-nightly bump. `dev` HEAD compiles under our pinned
  `0.17.0-dev.1267+300116b02`, and both our pin *and* `dev` HEAD compile under today's
  zig-overlay `master` nightly `0.17.0-dev.1786+75044cb04` (§5, verified by running). The
  lockstep constraint is not currently binding in either direction.
- The one thing a bump would actually buy is the **bounded connect** (§4): today a blackholed
  `api.openai.com` can hang `websocket.Client.init` indefinitely on the supervisor thread, and
  `daemon.zig`'s shutdown joins that thread. That is a real, if rare, hazard — but it is a new
  *feature* with new behaviour (a hand-rolled per-address connect loop and a watchdog thread
  per TLS handshake), not a fix, and it deserves to ride a deliberate bump with a live re-prove,
  not a drive-by pin change.

**Bump-when:** at the next compiler bump (step 2 of the [bump procedure](../toolchain.md)),
pinning `bfe761959b05030eaf4943fcf0fd5ecd1daca68a` or later — never an intermediate commit.
Earlier than that only if we decide the unbounded connect is worth its own ticket.

## Summary table

| Question | Answer | Evidence |
|---|---|---|
| How far behind is the pin? | 3 commits, 0 behind; pin `4b475a8` (2026-07-08), `dev` HEAD `bfe7619` (2026-08-11) | §1 |
| Any bug fix we'd benefit from? | **No.** One clamp fix in a path we don't use (we never call `readTimeout`) | §2.2 |
| Any fix for something we work around? | **No.** We carry no workaround; the §3.5 patch went upstream *as* our pin | §3, [toolchain.md](../toolchain.md) |
| Any API change affecting our call sites? | **No.** `init`/`handshake`/`write*`/`writeFrame`/`close`/`deinit`/`OpCode` unchanged; `_reader.pos`/`_reader.static` still present | §4.1 (ran) |
| Any security fix? | **No.** No auth, masking, cert-validation or parsing change | §2 |
| Any Zig-compat change? | **No.** No `std.Io` adaptation commit in the range | §5 |
| Would a bump force a compiler bump? | **No** — `dev` HEAD builds on the pinned nightly | §5 (ran) |
| Would the *current* nightly force a websocket bump? | **No** — our pin also builds on `0.17.0-dev.1786+75044cb04` | §5 (ran) |
| Is PR #107 (ours) still open? | No — closed unmerged 2026-07-09; the maintainer's own fix is our pin | §3 |
| Anything new that matters? | One: `connect_timeout_ms` (default 10 s) bounds `init()`. Useful, not urgent | §4.2 |
| Trap to know about | `dev` carried a **month-long regression** of the §3.5 fix (2026-07-11 → 2026-08-11) | §3 |

## 1. The exact delta

Verified by reading the compare API
([`4b475a8...dev`](https://github.com/karlseguin/websocket.zig/compare/4b475a8683f9769bd12f0221e5e87141c9a9175f...dev)):
`ahead_by: 3`, `behind_by: 0`, `total_commits: 3`.

| SHA | Date | Message | Files |
|---|---|---|---|
| [`b225565`](https://github.com/karlseguin/websocket.zig/commit/b22556504169) | 2026-07-11 | "Merge pull request #108 from privkeyio/feat/client-connect-timeout" | `src/client/client.zig` +198/−20 |
| [`83f8725`](https://github.com/karlseguin/websocket.zig/commit/83f872552942) | 2026-07-11 | "client: clamp read timeout to INT_MAX before passing to poll (#110)" | `src/client/client.zig` +6/−1 |
| [`bfe7619`](https://github.com/karlseguin/websocket.zig/commit/bfe761959b05) | 2026-08-11 | "fix tls read" | `src/client/client.zig` +17/−1, `readme.md` +1/−1 |

The **net** diff `4b475a8...bfe7619` is `src/client/client.zig` +203/−4 and a one-word readme
typo fix (`accomodate` → `accommodate`). `build.zig.zon` upstream is unchanged and still
declares no `minimum_zig_version` and no dependencies
([raw at `dev` HEAD](https://raw.githubusercontent.com/karlseguin/websocket.zig/bfe761959b05/build.zig.zon)),
so a bump imposes no new floor and pulls in no transitive package.

Note for orientation: upstream `dev` and `master` are **diverged** (18 ahead / 16 behind,
verified via the compare API). PRs #108 and #110 both declare `base.ref: master` yet their
content landed on `dev` — the maintainer applies work to both branches by hand. That is the
mechanism behind the regression in §3.

## 2. Commit-by-commit, against our surface

### 2.1 `b225565` — bounded connect and TLS handshake timeout (PR [#108](https://github.com/karlseguin/websocket.zig/pull/108), kwsantiago, merged 2026-07-11)

Verified by reading the diff. Adds, all client-side:

- `Client.Config.connect_timeout_ms: u32 = 10000`.
- `connectTimeout()` — replaces `Io.net.HostName.HostName.connect` with a manual
  `HostName.lookup` into an `Io.Queue`, then a non-blocking `connect()` gated by `poll()`,
  with a **single deadline spanning all resolved addresses**.
- `connectAddrTimeout()` — the per-address non-blocking connect, checking `SO_ERROR` after
  `poll()` readiness and mapping it to `ConnectionRefused` / `ConnectTimeout` /
  `NetworkUnreachable` / `ConnectFailed`, then restoring blocking mode via `fcntl`.
- `HandshakeGuard` + `initTLSClientTimeout()` — a watchdog thread parked on a `pipe2()` wake
  fd that `shutdown()`s the socket if the blocking TLS handshake overruns, surfacing
  `error.TlsHandshakeTimeout`. POSIX-only; Windows falls through to the unbounded path.
- An `errdefer net_stream.close(io)` in `init`, closing the fd if anything after the connect
  fails (TLS handshake, buffer-provider create, `reader_buf` alloc).

The stated bound is DNS + connect + handshake, where connect and handshake are each bounded by
`connect_timeout_ms` (so ~2× in the worst case) and **DNS is explicitly not bounded** — the
Threaded `Io` cannot cancel `HostName.lookup`. `0` disables the timeout.

This is the only commit in the range with any behavioural weight for us; see §4.2.

### 2.2 `83f8725` — clamp read timeout to INT_MAX (PR [#110](https://github.com/karlseguin/websocket.zig/pull/110), merged 2026-07-11)

Verified by reading the diff. One statement in `Stream.pollReadable`:

```zig
const poll_ms: i32 = @intCast(@min(self.read_timeout_ms, @as(u32, std.math.maxInt(i32))));
```

replacing a bare `@intCast(self.read_timeout_ms)`. It only bites when a caller sets a read
timeout above `INT_MAX` ms (~24.9 days). **Unreachable for us**: `grep` over `src/` finds no
call to `readTimeout` or `writeTimeout` anywhere in type-wave (verified by reading). Our only
timeout is the `handshake` `timeout_ms: 10_000` at `src/session.zig:421`, which the handshake
loop bounds by its own deadline.

Related but *not* in the range: issue
[#109](https://github.com/karlseguin/websocket.zig/issues/109) — `readTimeout` is silently a
no-op on Windows since the `poll()`-based rewrite. Open, Windows-only, irrelevant to a macOS
daemon.

### 2.3 `bfe7619` — "fix tls read" (2026-08-11)

Verified by reading the diff. Re-adds `hasBufferedTlsRecord` and its guard in `Stream.read`,
restoring the code we already have. See §3.

### 2.4 Nothing else

No commit in the range touches `src/server/`, `src/proto.zig` (framing/masking), the handshake
request/reply composition, close-frame handling, `src/buffer.zig`, or any Zig-version-gated
code. Verified by reading the per-file diff list: the only files changed across all three
commits are `src/client/client.zig` and `readme.md`.

## 3. The trap: `dev` reverted the §3.5 fix for a month

**This is the most important finding, and it argues for care rather than for bumping.**

Our pin `4b475a8` ("Don't poll if tls has buffered client",
[commit](https://github.com/karlseguin/websocket.zig/commit/4b475a8683f9769bd12f0221e5e87141c9a9175f),
Karl Seguin, 2026-07-08) is the fix for the TLS-read starvation described in
[zig-websocket-tls.md](./zig-websocket-tls.md) §3.5 — the one thing standing between us and a
handshake read starving against Cloudflare/api.openai.com's bursty delivery.

`b225565` has **a single parent, `4b475a8`** (verified via the commits API — despite the
"Merge pull request" subject it is a flat cherry-pick of the PR's file, not a two-parent
merge). PR #108 was written against a base that predated the TLS fix, so applying its version
of `client.zig` wholesale **deleted `hasBufferedTlsRecord` and its call site**. Verified by
grepping the raw file at each SHA:

| SHA | occurrences of `hasBufferedTlsRecord` |
|---|---|
| `4b475a8` (our pin) | present |
| [`b225565`](https://raw.githubusercontent.com/karlseguin/websocket.zig/b22556504169/src/client/client.zig) | **0** |
| [`83f8725`](https://raw.githubusercontent.com/karlseguin/websocket.zig/83f872552942/src/client/client.zig) | **0** |
| [`bfe7619`](https://raw.githubusercontent.com/karlseguin/websocket.zig/bfe761959b05/src/client/client.zig) | 2 |

A third party re-reported the bug three weeks later as PR
[#111](https://github.com/karlseguin/websocket.zig/pull/111) ("fix: TLS Stream.read() ignores
buffered-but-undecrypted bytes", Adrigamer2950, 2026-07-30). The maintainer closed it unmerged
on 2026-08-11 with: *"Thanks. I fixed this in a separate commit..This was already fixed and then
got accidentally reverted. I prefer the original fix."* — and `bfe7619` restores exactly the
original. Verified by reading the PR and its comment.

Consequences for us:

1. **We were never exposed.** The pin is `4b475a8`; the regression only ever lived downstream
   of it.
2. **`dev` HEAD is byte-identical to our pin in that function.** The net diff `4b475a8...bfe7619`
   does not mention `hasBufferedTlsRecord` at all — proof by absence that the restore is
   verbatim. So a bump buys **zero** on the axis we care most about.
3. **A future bump must land on `bfe7619` or later**, and the "find a `dev` commit built against
   the same nightly" instruction in [toolchain.md](../toolchain.md) step 2 is not by itself
   sufficient — the §3.5 re-check that step already recommends is load-bearing, not
   belt-and-braces. It caught a real month-wide hole.

Also settled: our PR
[#107](https://github.com/karlseguin/websocket.zig/pull/107) was **closed unmerged on
2026-07-09** (verified via the pulls API), consistent with what
[toolchain.md](../toolchain.md) records except that it is now closed rather than open.

## 4. Cross-check against our actual call sites

### 4.1 API surface: unchanged (verified by running)

`src/session.zig`'s `WebsocketTransport` (lines ~405–480) is our entire consumption surface:
`websocket.Client.init`, `.handshake`, `.readLoopInNewThread`, `.write`, `.writePing`,
`.writePong`, `.writeFrame(websocket.OpCode.close, …)`, `.close`, `.deinit`, plus
`scrubHandshakeBuffer` reaching into the library's private `client._reader.pos` and
`._reader.static` (`src/session.zig:449`) — deliberately, so a vendor bump that restructures
those fields fails the compile instead of silently skipping the key scrub.

Two scratchpad probe modules were compiled against the `dev` HEAD source tree with the pinned
compiler: one taking the address of every method above and referencing `OpCode.close`, one
replaying `scrubHandshakeBuffer`'s exact field access plus `writeFrame` and `close(.{})`. Both
compiled clean (exit 0). So **no signature, no field name, and no enum we touch has moved.**
`Reader` still declares `static: []u8` and `pos: usize`
([`src/proto.zig`](https://raw.githubusercontent.com/karlseguin/websocket.zig/bfe761959b05/src/proto.zig)
lines 72/78), and `Client._reader` is still the field name.

`WebsocketTransport.connect` returns `!void` with an inferred error set and its one caller
(`src/session.zig:665`) uses plain `try` with no exhaustive `switch` on the error — verified by
reading. So the new `ConnectTimeout` / `TlsHandshakeTimeout` / `NetworkUnreachable` /
`ConnectFailed` members would not break the compile.

### 4.2 The one thing that would actually change: bounded connect

Today `websocket.Client.init` → `HostName.connect` blocks with no upper bound. Our connect runs
on the supervisor/maintenance thread, and `src/daemon.zig`'s shutdown does
`supervisor_thread.join()` "so it is not mid-connect" before the graceful websocket close. So a
blackholed or stalling `api.openai.com` — a captive portal, a hostile relay, a route that drops
SYNs — can in principle wedge quit indefinitely. **Inference**, not something reproduced here:
the hazard follows from the unbounded `init` plus the unconditional join, but no hang has been
observed and there is no open type-wave issue about it (`gh issue list` finds none mentioning
connect/shutdown/hang/timeout — verified).

Upstream's default of `connect_timeout_ms = 10000` would bound it at ~10 s per phase without any
code change on our side, which is a genuine improvement.

Against that, the same commit is the largest single behaviour change in the range and carries
real risk to weigh at bump time (**inference**, from reading the diff):

- It **replaces `std.Io.net.HostName.connect` with a hand-rolled per-address loop**. Whatever
  address ordering, dual-stack handling or future Happy-Eyeballs behaviour std provides is
  bypassed; the loop walks the resolver's `LookupResult` stream in order and takes the first
  address that connects. On a dual-stack Mac with a degraded IPv6 path this could plausibly be
  *slower* to first byte than what we have.
- Each TLS connect now **spawns a watchdog thread and a pipe pair**, joined on `disarm`. For a
  daemon that reconnects on a 60-minute session cap that is cheap, but it is new machinery on
  the reconnect path.
- The watchdog works by `shutdown()`ing the socket underneath a blocking handshake. The code
  handles the race where it fires just as the handshake completes (deinit + report timeout),
  but this is exactly the class of teardown race `forceClose` already documents on our side.

None of that is a reason not to take it eventually; it is a reason to take it as a deliberate,
live-re-proved change rather than as a hash swap.

## 5. Zig compatibility: the lockstep constraint is not binding right now

[toolchain.md](../toolchain.md) requires the compiler and websocket.zig `dev` to move together,
because `dev` chases zig-master and `std.Io` churns. Both directions were probed empirically in
the scratchpad with `zig build-exe --dep websocket -Mroot=probe.zig -Mwebsocket=<tree>/src/websocket.zig -lc`:

| Library tree | Compiler | Result |
|---|---|---|
| `dev` HEAD `bfe7619` | pinned `0.17.0-dev.1267+300116b02` | **compiles clean** (ran) |
| pin `4b475a8` | current nightly `0.17.0-dev.1786+75044cb04` | **compiles clean** (ran) |
| `dev` HEAD `bfe7619` | current nightly `0.17.0-dev.1786+75044cb04` | **compiles clean** (ran) |

(Current zig-overlay `master` resolves to `0.17.0-dev.1786+75044cb04`, dated 2026-08-17 —
verified against [ziglang.org/download/index.json](https://ziglang.org/download/index.json);
both toolchains were already in the local nix store, so no download was needed.)

That is a *compile* result on a probe module that instantiates the client type and touches every
method we call — it is not a link, a test run, or a live wss round-trip, and the readme's
warning still applies. But it is enough to settle the question asked: **a websocket.zig bump
would not force a compiler bump**, and equally, a compiler bump to today's nightly would not
force a websocket bump.

Consistent with that, none of the three commits is a Zig-version adaptation. The std APIs the
new connect path uses all exist in our pinned compiler (verified by reading the flake compiler's
own std source): `Io.net.HostName.lookup` and `LookupResult`
(`lib/std/Io/net/HostName.zig:150,163`), `Io.Queue.getOneUncancelable` (`lib/std/Io.zig:2382`),
`Io.Timestamp.now(io, clock)` (`lib/std/Io.zig:926`), `Io.net.Stream.close(io)`
(`lib/std/Io/net.zig:1255`), and `IpAddress.Ip6Address.interface` (`lib/std/Io/net.zig:441`).
Everything else it uses (`posix.Address`, `getOsSockLen`, `pipe2`, `fcntl`, `shutdown`) comes
from websocket.zig's **own** `src/posix.zig` shim, not std — so it is insulated from std churn
by construction.

## 6. Upstream health, read but not verified

- The readme at `dev` HEAD
  ([raw](https://raw.githubusercontent.com/karlseguin/websocket.zig/bfe761959b05/readme.md))
  still says: *"The master branch targets the latest stable of Zig (0.15.1). The dev branch
  targets the latest version of Zig"*, and, of the 0.16 line, *"This ZIG 0.16 version is not
  well tested. Like Zig 0.16 itself, consider this experimental!"* The `dev` branch is
  described as one *"which may or may not be up to date with zig dev."* Note the drift: the
  readme's stable-branch claim (0.15.1) no longer matches its own Zig-version section (0.16.0).
  Either way, nothing here changes the [toolchain.md](../toolchain.md) decision to stay on the
  nightly pair.
- Issue [#84](https://github.com/karlseguin/websocket.zig/issues/84) — *"Unit tests in `dev`
  branch are not passing"* — has been **open since 2025-09-30**. So upstream's own test suite is
  not a signal we can lean on when validating a bump; our live end-to-end re-prove is.
- No open upstream issue reports breakage of the `dev` client on a recent nightly. Issues open
  in the window are #109 (Windows `readTimeout`), #99 and #93 (Windows server), and #90 (client
  proxy support) — none of which touch a macOS TLS client.

## 7. What a bump would cost, if we do it

Mechanical, from [toolchain.md](../toolchain.md) step 2 — recorded here so the "when" is cheap
to execute later. The pin appears in **two** files that must stay identical:
`build.zig.zon` and `prototypes/cli-dictation/build.zig.zon` (verified by grep; the other four
prototype `build.zig.zon`s carry `minimum_zig_version` but no websocket dependency). Upstream's
`.paths` still omits `LICENSE`, so `packaging/share/type-wave/LICENSES/websocket.zig-MIT.txt`
must be re-checked by hand on any bump. And the live wss re-prove against
`wss://api.openai.com/v1/realtime` is the acceptance test — doubly so if the bump brings
`connect_timeout_ms`, since that rewrites the connect path this repo has never exercised.

## 8. Bottom line

Leave the pin at `4b475a8`. The honest summary of two months of upstream work, from this
repo's point of view, is: one feature we could use but have not asked for, one fix in a code
path we never enter, and a month-long regression of the one fix that matters to us — now
repaired back to exactly the state we already ship. Revisit at the next compiler bump, pin
`bfe761959b05030eaf4943fcf0fd5ecd1daca68a` or later, and keep the §3.5 re-check in the
procedure: §3 is the proof it earns its place.
