# WebSocket-over-TLS client in pure Zig — research for type-wave

Researched 2026-07-07 against primary sources — library source code (cloned and read), the Zig
std source shipped with the flake's own compiler, SDK headers on this machine, curl/nixpkgs
source, and issue trackers — plus **empirical tests run with the flake's Zig on this macOS
26.5.1 machine**, including live connections to `wss://api.openai.com/v1/realtime`. Every
section says whether a claim is verified-by-running, verified-by-reading, or uncertain.
Protocol requirements come from the companion crib sheet
[openai-realtime-transcription.md](./openai-realtime-transcription.md).

## Summary table

| Question | Answer | Evidence |
|---|---|---|
| Flake's Zig | `0.17.0-dev.1267+300116b02` (zig-master nightly via `mitchellh/zig-overlay` `master`, flake.lock rev `be62cd68…`, locked 2026-07-07) | ran `zig version` |
| Does std TLS reach api.openai.com? | **Yes** — `std.http.Client` GET returned `421` + OpenAI welcome JSON; handshake, macOS root-cert verification, record layer all fine | ran it (§2.1) |
| Picked approach | **karlseguin/websocket.zig, `dev` branch, pinned commit `2283d22`**, with a one-line TLS-read fix vendored (§3.5) | ran full wss round-trips (§2) |
| Does it talk to OpenAI? | Yes — `101` on `/v1/realtime`, then received the JSON `error` event (invalid test key) as a text frame + close frame | ran it (§2.4) |
| Its TLS story | Delegates entirely to `std.crypto.tls.Client`; `tls: bool` config, optional own `ca_bundle` | [client.zig `TLSClient`](https://github.com/karlseguin/websocket.zig/blob/dev/src/client/client.zig) |
| Concurrent read/write | Background `readLoopInNewThread` + writer thread verified working; **but** serialize all writes yourself — readme claims write-thread-safety, source has no lock (§3.4) | ran it; read source |
| Fallback | Hand-rolled RFC 6455 client framing directly over `std.crypto.tls` (std TLS is the empirically proven layer); C safety net = **nixpkgs `curlFull`** libcurl WS API | §7 |
| macOS system libcurl | **Unusable**: curl 8.7.1, built without WebSocket (`ws`/`wss` absent from protocol list) | ran `/usr/bin/curl --version` (§6.1) |
| Network.framework | Full WebSocket **C** API exists (`ws_options.h`, macOS 10.15+), but every callback is a C *block* + dispatch queue — workable, shim-like, ranked last | read SDK headers (§6.2) |
| Toolchain pin | zig nightly (flake.lock) + websocket.zig `dev` commit (build.zig.zon) must move in lockstep; stable alternative: Zig 0.16.0 + websocket.zig `master` | §9 |

## 1. What the client must actually support (from the crib sheet)

Per [openai-realtime-transcription.md](./openai-realtime-transcription.md) §2:

- Connect `wss://api.openai.com/v1/realtime` (no query params planned; no subprotocol).
- Headers: `Authorization: Bearer $OPENAI_API_KEY`, optional `OpenAI-Safety-Identifier`;
  **no** `OpenAI-Beta` header (GA).
- **Frames: text only, both directions.** All client events (including audio — base64 inside
  `input_audio_buffer.append` JSON, ≤ 15 MiB/event) and all server events are JSON in text
  frames. Binary-frame support is a nice-to-have, not a requirement.
- Client frames must be masked (RFC 6455); ping/pong and close frames must be handled.
- Long-lived connection: sessions cap at 60 min → reconnect logic; concurrent audio-up /
  events-down while the Talk Key is held.

Empirical addendum discovered during this research: **the server accepts the upgrade (101)
before authenticating** — an invalid API key still gets `HTTP/1.1 101`, then an in-band
`{"type":"error","code":"invalid_api_key"}` text frame and a close frame (verified twice: raw
`openssl s_client` and through websocket.zig). Auth failures surface as WS events, not 4xx.

## 2. Empirical results (all run with the flake's Zig on this machine)

Scratch projects lived in the session scratchpad; nothing was added to the repo. Zig used:
`0.17.0-dev.1267+300116b02` (already on PATH from the flake dev shell).

1. **std.http HTTPS GET to `https://api.openai.com/`** — minimal `std.http.Client.fetch`
   program (needs the new `std.Io` interface: `std.Io.Threaded.init` → `threaded.io()`).
   Result: `status: 421 misdirected_request` with the 124-byte OpenAI welcome JSON body.
   A served response proves: TCP, TLS handshake, certificate verification against macOS
   system roots (`Certificate.Bundle.rescan` → `rescanMac`), record decryption. ✅ ran.
2. **websocket.zig builds with the flake's Zig** — `zig fetch --save
   git+https://github.com/karlseguin/websocket.zig#dev` (resolved to commit `2283d22`,
   2026-07-04) + minimal client: compiles clean. The `master` branch targets Zig 0.16.0 and
   was **not** tried against 0.17-dev. ✅ ran (dev branch only).
3. **wss:// echo round-trip** — connect `wss://echo.websocket.org`, handshake, send masked
   text frame, receive greeting + echo. ✅ ran.
4. **wss://api.openai.com/v1/realtime** — with an intentionally invalid key:
   - upstream `dev` **fails**: `error.Timeout` in `handshake()`, deterministic (3/3 runs) — see §3.5;
   - with a one-line fix: `101` accepted, then read text frame (297 B, the `invalid_api_key`
     error event) and close frame (39 B). ✅ ran.
5. **Two-thread concurrency** — `client.readLoopInNewThread(&handler)` receiving on one
   thread while `main` wrote 3 text frames; all echoed back to the reader thread; clean
   `close` + `thread.join()`. ✅ ran (echo server).
6. **macOS system curl**: `curl 8.7.1 (SecureTransport) LibreSSL/3.3.6` — protocol list has
   **no `ws`/`wss`**. **nixpkgs default curl 8.20.0** (`nix shell nixpkgs#curl`): also no
   `ws`/`wss`. ✅ ran both.
7. **SDK headers**: `Network.framework/Headers/ws_options.h` present in both the CLT macOS 26
   SDK and the nix-provided `apple-sdk-14.4` used by `xcrun` here. ✅ inspected files.
8. **Root-cert keychain files** `rescanMac` depends on exist on macOS 26.5.1
   (`/System/Library/Keychains/SystemRootCertificates.keychain`,
   `/Library/Keychains/System.keychain`) and were exercised by tests 1–5. ✅ ran.

## 3. Option 1: karlseguin/websocket.zig (picked)

Repo: <https://github.com/karlseguin/websocket.zig>. Actively maintained — HEAD commits
2026-07-02…07-04 as of this research.

### 3.1 Client maturity

Real client, not an afterthought: dedicated `src/client/client.zig` with handshake
(incl. `Sec-WebSocket-Accept` verification), raw extra headers (how you send
`Authorization`), timeouts, `read`/`readLoop`/`readLoopInNewThread`, all five write kinds
(`write`/`writeText`/`writeBin`/`writePing`/`writePong` + `writeFrame`), masking (with
pluggable `mask_fn`), close codes/reasons. Fragmented-message reassembly is in the shared
reader ([src/proto.zig](https://github.com/karlseguin/websocket.zig/blob/master/src/proto.zig),
`Fragmented` state; control frames rejected if fragmented). An
[Autobahn conformance harness](https://github.com/karlseguin/websocket.zig/tree/master/support/autobahn)
exists for both client and server (`make abc`). Compression (permessage-deflate) is currently
**disabled** — `Client.init` errors if requested: "Compression is disabled as part of the 0.15
upgrade" (client.zig) — irrelevant for type-wave. Verified by reading source at `2283d22`.

### 3.2 TLS story

`Config{ .tls = true }` wraps the socket in `std.crypto.tls.Client` — no bundled TLS of its
own (`const tls = std.crypto.tls;` … `TLSClient` struct in client.zig). Certificate
verification uses `std.crypto.Certificate.Bundle`: pass your own via `ca_bundle`, or the
library rescans system roots per connection. You cannot hand it an arbitrary pre-wrapped
stream — it creates the TCP connection itself (`Io.net.HostName.connect`) — but since the TLS
layer is std's, there's little reason to. The readme's "Zig only supports TLS 1.3" note is
stale (std master also has TLS 1.2, §4.1); api.openai.com negotiates 1.3 anyway (not
inspected on the wire — inferred from Cloudflare defaults; the connection empirically works).

### 3.3 Zig-version tracking

Branches per Zig release, verified via `git ls-remote`: `zig-0.11` … `zig-0.15`, `master`,
`dev`. Readme: "This is for Zig 0.16.0. Use the zig-0.15.2 branch … or the dev which may or
may not be up to date with zig dev" (the readme's first line still says "targets the latest
stable of Zig (0.15.1)" — stale). `master`↔`dev` diff is currently tiny (a
`@typeInfo(...).@"fn".params` rename). No `minimum_zig_version` in its build.zig.zon.
**Empirically: `dev` @ `2283d22` builds and runs with the flake's `0.17.0-dev.1267`.**

### 3.4 Concurrency (the audio-up / events-down question)

- Intended model, from the readme and the maintainer in
  [issue #55](https://github.com/karlseguin/websocket.zig/issues/55): one thread runs
  `readLoop` (owning `read`/`done` and the receive buffers); "only write and close are thread
  safe" from other threads.
- **However, the current source contains no write lock at all** (no `Mutex` anywhere in
  client.zig on `dev`, `master`, `zig-0.14`, or `zig-0.13`), and `writeFrame` issues two
  separate stream writes (header+mask, then payload); the TLS path funnels through one shared
  buffered `tls.Client.writer`. Two threads writing concurrently can interleave mid-frame.
  Treat the thread-safety claim as **aspirational**: wrap every write (including `close`) in
  your own mutex. Verified by reading; not provoked empirically.
- Watch out: if your handler doesn't define `serverPing`, `readLoop` auto-replies pong **from
  the read thread** (readLoop source) — a concurrent write. Define `serverPing` and route the
  pong through your write mutex.
- The verified pattern (§2.5): `readLoopInNewThread(&handler)` for downstream JSON events;
  one upstream writer (the Talk-Key/audio thread); mutex around all writes. This maps 1:1
  onto type-wave's needs — see §8.

### 3.5 Bug found: TLS handshake read starves against api.openai.com

`Stream.read` (client.zig, dev @ `2283d22`) polls the raw socket whenever the *decrypted*
buffer is empty — ignoring **encrypted** bytes already buffered in the tls input reader.
Cloudflare delivers the `101` + post-handshake records in one burst; the socket drains, the
data sits encrypted-but-buffered, `poll()` blocks for the full timeout → deterministic
`error.Timeout` from `handshake()`. (Instrumented: 1293 encrypted bytes buffered while
polling.) echo.websocket.org doesn't trigger it; api.openai.com does, every time. Fix
verified end-to-end:

```zig
// src/client/client.zig, Stream.read — add the input-buffer check:
if (tls_client.client.reader.bufferedLen() == 0 and
    tls_client.client.input.bufferedLen() == 0 and   // <- added
    !try self.pollReadable()) {
    return error.WouldBlock;
}
```

Upstream HEAD ("Improve Client read over TLS", `2283d22`/`7afc284`, 2026-07-04) touched
exactly this code but missed this case. No existing issue covers it (checked open issues).
**Action item: file upstream with the repro; vendor the patch (fork or local checkout as a
`.path` dependency) until merged.** Beware stale build caches when testing patched deps —
`zig build` served a stale binary here until `.zig-cache` was removed.

## 4. Option 2: std (`std.crypto.tls` + `std.http`) directly

### 4.1 What master's source says (verified by reading the flake compiler's own lib/std)

Files read: `lib/std/crypto/tls/Client.zig`, `lib/std/crypto/tls.zig`,
`lib/std/http/Client.zig`, `lib/std/crypto/Certificate/Bundle.zig` + `Bundle/macos.zig`
(browse on [Codeberg master](https://codeberg.org/ziglang/zig/src/branch/master/lib/std/crypto/tls/Client.zig)).

- **TLS 1.2 and 1.3** client (`ProtocolVersion { tls_1_2, tls_1_3 }`, `ApplicationCipher`
  has per-version variants); modern cipher-suite list (AES-GCM, CHACHA20-POLY1305, AEGIS,
  plus 1.2 ECDHE suites).
- **NewSessionTicket ignored** by design ("This client implementation ignores new session
  tickets") — no session resumption; fine for one long-lived connection.
- **KeyUpdate handled**, including `update_requested` (rederives server *and* client
  secrets). GitHub issue [#22508](https://github.com/ziglang/zig/issues/22508) ("client
  tried to close connection" on KeyUpdate) is still marked open but predates the current
  master code, which visibly contains the response path — treat the GitHub state as frozen
  (see migration note below). Not provoked empirically; Cloudflare is not known to send
  KeyUpdates mid-session.
- **close_notify**: tracked (`received_close_notify`); missing close_notify at EOF ⇒
  `error.TlsConnectionTruncated` unless `allow_truncation_attacks = true`; `end()` sends
  close_notify. Large records: buffers are sized to `max_ciphertext_record_len`; the
  0.13-era `TlsRecordOverflow` reports (e.g. [#21691](https://github.com/ziglang/zig/issues/21691))
  predate the 0.15/0.16 Reader/Writer rewrite.
- **No client-certificate support** — a `certificate_request` from the server ⇒
  `TlsUnexpectedMessage` ([#17446](https://github.com/ziglang/zig/issues/17446), open).
  Irrelevant for OpenAI.
- **macOS cert bundle works**: `Bundle.rescan` dispatches `.macos` → `rescanMac`, which
  parses the legacy `kych` keychain DBs directly (no Security.framework). Both files exist
  on macOS 26.5.1 and verification succeeded in every test here. ✅ ran.
- **API churn is real**: everything now threads a `std.Io` (e.g. `std.Io.Threaded`);
  `tls.Client.Options` wants `entropy`, `realtime_now`, and a `ca` union with
  `{gpa, io, lock, bundle}`. Any pre-0.16 std.http/tls example is wrong on master.

### 4.2 Issue-tracker state

Zig's canonical repo/issues **moved to Codeberg in November 2025**
([ziglang.org announcement](https://ziglang.org/news/migrating-from-github-to-codeberg/));
GitHub is read-only with old issues left "copy-on-write"; Codeberg issue numbers start
at 30000. Open TLS-client-relevant issues found
([search](https://codeberg.org/ziglang/zig/issues?q=tls&type=issues&state=open)):
[#35921](https://codeberg.org/ziglang/zig/issues/35921) "Incorrect assertion in RSA-PSS
signature verification" (2026-06-24 — could break cert verification against some chains),
[#30853](https://codeberg.org/ziglang/zig/issues/30853) "fetch of gitlab repo gives
TlsInitializationFailed" (2026-01-16), plus open items titled "TLS client doesn't validate
cA bit in basic constraints extension" and "TLS Client does not notify the server on key
update" (seen in the open-issue search; numbers not individually confirmed). Net: std TLS
still has server-specific failure reports, but **api.openai.com is empirically fine on
today's master** — twice over (std.http directly, and via websocket.zig).

### 4.3 Assessment

std gives TLS + HTTP/1.1, **no WebSocket layer** — you'd hand-roll RFC 6455 client framing
(masking, frame headers, ping/pong, close; fragmentation optional for this protocol). That's
a few hundred lines against a spec, on top of the same TLS stack websocket.zig uses. Solid
fallback, not the first choice while websocket.zig is maintained.

## 5. Option 3: other Zig-ecosystem pieces

- **[ianic/tls.zig](https://github.com/ianic/tls.zig)** — TLS 1.2+1.3 client (and 1.3
  server), client-auth, cipher/named-group selection, "upgrade existing tcp connection" via
  `tls.clientFromStream`, claims successful connects to ~6k domains "outperforming Zig's
  standard library implementation" (readme). **Maintained and master-compatible**: last
  commits 2026-06-18; `build.zig.zon` `minimum_zig_version = "0.17.0-dev.704+b8cb78023"`
  (verified by cloning). The escape hatch if std TLS hits a wall (e.g. a server quirk or the
  RSA-PSS issue); would pair with hand-rolled WS framing. Not needed today.
- **Other WebSocket clients: effectively none maintained.**
  [nikneym/ws](https://github.com/nikneym/ws) last pushed 2024-02-22;
  [otsmr/websocket](https://github.com/otsmr/websocket) is a 2024 learning project (checked
  via GitHub API). [Zigistry](https://zigistry.dev/) surfaces the same picture —
  websocket.zig is the ecosystem's WS library.

## 6. Option 4: macOS C fallbacks

### 6.1 libcurl WebSocket API

- **Status: official, no longer experimental, since curl 8.11.0** (Nov 2024):
  "WebSockets: make support official (non-experimental)" —
  [8.11.0 changelog](https://curl.se/ch/8.11.0.html); API:
  [libcurl-ws(3)](https://curl.se/libcurl/c/libcurl-ws.html) (`curl_ws_send`/`curl_ws_recv`
  with `CURLOPT_CONNECT_ONLY = 2L`).
- **macOS system libcurl: unusable.** `/usr/bin/curl --version` on macOS 26.5.1 reports
  curl **8.7.1** (predates official status) built with SecureTransport/LibreSSL and **no
  `ws`/`wss` protocols** — WebSocket compiled out. ✅ ran.
- **nixpkgs: default `curl` also lacks it.** `nix shell nixpkgs#curl` → curl 8.20.0, no
  `ws`/`wss`. ✅ ran. Root cause in nixpkgs source:
  [`curlMinimal`](https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/cu/curlMinimal/package.nix)
  has `websocketSupport ? false` + `(lib.enableFeature websocketSupport "websockets")`;
  plain `curl` overrides it without websockets; only **`curlFull`** sets
  `websocketSupport = true` (`pkgs/top-level/all-packages.nix`). So the flake would add
  `pkgs.curlFull` (or `curl.override { websocketSupport = true; }`) and link `-lcurl`.
- Ergonomics from Zig: good — plain blocking C calls, `@cImport`-able, TLS/certs handled by
  libcurl (OpenSSL in nixpkgs). Cost: a C dependency + its TLS stack in the binary, and the
  send API is frame-chunk oriented. Ranked as the C safety net.

### 6.2 Network.framework (`nw_connection` + `NWProtocolWebSocket`)

- The WebSocket options **are plain C**, not Swift-only: `ws_options.h` in
  `Network.framework/Headers` (verified in both the CLT macOS 26 SDK and the nix
  `apple-sdk-14.4`), `API_AVAILABLE(macos(10.15))`. Full surface: `nw_ws_create_options`,
  `nw_ws_options_add_additional_header` (→ `Authorization`), `add_subprotocol`,
  `set_auto_reply_ping`, `set_maximum_message_size`, opcodes
  (`nw_ws_opcode_text/binary/ping/pong/close/cont`), `nw_ws_metadata_*`
  (close codes, pong handler), `nw_ws_metadata_copy_server_response`. Apple docs:
  [nw_ws_options_t](https://developer.apple.com/documentation/network/nw-ws-options).
- **The hazard is confirmed: every completion/handler is a C block** (`typedef void
  (^nw_connection_receive_completion_t)(...)` etc. in `connection.h`/`ws_options.h`) and
  connections require a `dispatch_queue_t`. Blocks are a **Clang C extension** (runtime in
  libSystem), not ObjC — so the letter of "no Swift/ObjC shims" survives — but Zig cannot
  express block literals; you'd either hand-assemble the block ABI structs
  (`_NSConcreteStackBlock` etc.) in Zig or compile one small `.c` file with `zig cc
  -fblocks`. Honest read: it's a shim in spirit, plus an inversion of control
  (dispatch-queue callbacks) that fights the simple two-thread design. Ranked last; it is
  the escape hatch if a proxy/VPN-aware or App-Store-friendly stack ever becomes a
  requirement (Network.framework gets system proxy handling for free).

## 7. Recommendation

**Pick: karlseguin/websocket.zig, `dev` branch pinned to commit `2283d22`, with the §3.5
one-line TLS-read fix vendored (fork or vendored checkout) and a PR filed upstream.** TLS is
std's, certs come from macOS system roots with zero configuration, the whole stack is pure
Zig, and — decisive — the exact target flow (`101` on `/v1/realtime`, JSON text events
in both directions, masked client frames, close handling) **ran successfully today with the
flake's compiler**. The library is the only maintained WS client in the ecosystem and has
per-Zig-version branches plus an Autobahn harness.

**Fallback: hand-rolled RFC 6455 client framing directly over `std.crypto.tls.Client`.**
std TLS ↔ api.openai.com is independently proven (§2.1), and type-wave needs only
client-masked text frames + ping/pong + close, so the framing layer is small and fully
under our control if websocket.zig's zig-master chase stalls. Swap in
[ianic/tls.zig](https://github.com/ianic/tls.zig) beneath it if std TLS itself regresses.

**C safety net (distant third): libcurl WS API via nixpkgs `curlFull`** — official API since
8.11.0, trivial to call from Zig, but adds a C TLS stack; the macOS *system* libcurl cannot
do it at all. Network.framework last (blocks/dispatch ergonomics, §6.2).

## 8. Minimal connect-and-use sketch (websocket.zig `dev`, Zig 0.17.0-dev)

Connection/handshake/read-loop/write mechanics below are the exact APIs run successfully in
§2 (echo round-trip, OpenAI 101 + error-event read, two-thread test). The OpenAI event JSON
is from the crib sheet; sending it with a *valid* key was **not** tested (no key used).

```zig
// build.zig.zon:  zig fetch --save git+https://github.com/karlseguin/websocket.zig#dev
// (pins the commit hash; vendor the §3.5 fix until upstreamed)
const std = @import("std");
const websocket = @import("websocket");

const Handler = struct {
    client: *websocket.Client,
    write_mu: *std.Thread.Mutex,

    // Runs on the read-loop thread; `data` is a complete (defragmented) message.
    pub fn serverMessage(self: *Handler, data: []u8) !void {
        _ = self;
        std.debug.print("server event: {s}\n", .{data}); // JSON: session.created, deltas, ...
    }

    // Define this so pongs go through the same lock as every other write (§3.4).
    pub fn serverPing(self: *Handler, data: []u8) !void {
        self.write_mu.lock();
        defer self.write_mu.unlock();
        try self.client.writePong(data);
    }

    pub fn close(self: *Handler) void {
        _ = self;
        std.debug.print("read loop ended\n", .{});
    }
};

pub fn main(init: std.process.Init) !void {
    var client = try websocket.Client.init(init.io, init.gpa, .{
        .host = "api.openai.com",
        .port = 443,
        .tls = true, // std.crypto.tls; roots via Certificate.Bundle.rescan (macOS keychain)
    });
    defer client.deinit();

    // Verified: server answers 101 even before validating the key (§1).
    // Real code: build the header string with the key from the environment.
    try client.handshake("/v1/realtime", .{
        .timeout_ms = 10_000,
        .headers = "Host: api.openai.com\r\nAuthorization: Bearer <OPENAI_API_KEY>",
    });

    var write_mu: std.Thread.Mutex = .{};
    var handler: Handler = .{ .client = &client, .write_mu = &write_mu };
    const read_thread = try client.readLoopInNewThread(&handler);

    // Writer side (Talk-Key/audio thread). NB: write() takes []u8, not []const u8 —
    // the library masks the payload in place, so buffers must be mutable.
    var buf: [8192]u8 = undefined;
    const event = try std.fmt.bufPrint(&buf,
        \\{{"type":"input_audio_buffer.append","audio":"{s}"}}
    , .{"<base64 24kHz mono s16le chunk>"});
    {
        write_mu.lock();
        defer write_mu.unlock();
        try client.write(event); // text frame
    }
    // ... session.update after session.created; input_audio_buffer.commit on key release ...

    {
        write_mu.lock();
        defer write_mu.unlock();
        try client.close(.{});
    }
    read_thread.join();
}
```

Concurrency model recap (§3.4): read-loop thread owns `read`/`done` and delivers JSON events;
exactly one logical writer, with a type-wave-owned mutex around **all** writes (`write*`,
pong replies, `close`) because the library has no internal write lock despite its readme.

## 9. Toolchain note (for the map's "toolchain pinning" fog item)

- The flake (`flake.nix`) uses `zig-overlay.packages.${system}.master` from
  [mitchellh/zig-overlay](https://github.com/mitchellh/zig-overlay); flake.lock pins
  zig-overlay at rev `be62cd684cf34f701cd1b91f2aa0c056c29fafa1` (locked 2026-07-07), which
  resolves to **Zig `0.17.0-dev.1267+300116b02`**. The lock makes the nightly reproducible;
  `nix flake update` will silently bump the compiler.
- websocket.zig support matrix (verified §3.3): `dev` ↔ zig master (works with today's
  nightly, empirically); `master` ↔ Zig 0.16.0; `zig-0.15` ↔ 0.15.x. **Pin the pair**: the
  flake.lock zig nightly and the websocket.zig commit hash in `build.zig.zon` must be bumped
  together; after any `nix flake update`, expect possible std.Io API breakage in the `dev`
  branch until upstream catches up ("may or may not be up to date with zig dev" — its readme).
- De-risking option: switch the flake to zig-overlay's `"0.16.0"` package and websocket.zig
  `master` (the 0.16-targeting branch, which its readme itself calls "not well tested…
  experimental") — **not empirically tested here**.
- Set `minimum_zig_version` in type-wave's build.zig.zon to the locked nightly so version
  drift fails loudly.

## Open questions / unverified

1. **Nothing was tested with a valid API key** — the full `session.update` → append → commit
   → delta flow over this stack is day-one prototype work; only connect/101/event-read is
   proven.
2. **Long-lived stability** (hours of ping/pong, 60-min session expiry + reconnect, network
   flaps, sleep/wake) — untested. The §3.5 class of bug suggests testing reads under bursty
   TLS delivery specifically.
3. **TLS version negotiated with api.openai.com** assumed 1.3 (Cloudflare default); not
   inspected on the wire.
4. **websocket.zig write-path interleaving** was reasoned from source (no lock, two writes
   per frame), not provoked; the mutex advice stands regardless.
5. **KeyUpdate handling on master** verified by reading only; no server at hand sends
   `update_requested`.
6. **`zig-0.16`-pair fallback** (websocket.zig `master` + Zig 0.16.0) not built here.
7. **Upstream fix status**: the §3.5 patch needs an issue/PR against
   karlseguin/websocket.zig; until merged, type-wave carries a one-line fork.
