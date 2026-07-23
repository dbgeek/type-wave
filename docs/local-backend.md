# Local Transcription Backend specification

Status: released design (Whisper Large v3 Turbo)

Source: [Specify a local KB Whisper transcription backend](https://github.com/dbgeek/type-wave/issues/56),
superseded on the model and credential axes by
[Local backend: switch to ggml-large-v3-turbo](https://github.com/dbgeek/type-wave/issues/85)

Canonical model: `ggml-large-v3-turbo.bin` (F16) from `ggerganov/whisper.cpp` at revision
`98aa99a0a9db05ae2342309f5096248665f7cba3` — display name "Local — Whisper Large v3 Turbo"

This file was `docs/local-kb-whisper-backend.md` while the pinned model was
`KBLab/kb-whisper-small`; that candidate failed its release gate (see
`acceptance/local_backend/evidence/3564d61a42fc-f16/`) and map #85 replaced it. Requirement
identifiers are stable across the switch: `MODEL-1`–`MODEL-5` (the Hugging Face credential
contract) are **retired**, not renumbered.

This is the self-contained normative specification for adding a selectable local
Transcription Backend alongside the existing OpenAI backend. Linked issues explain why
the contracts were chosen; an implementer should not need them to discover what to build.

## 1. Scope and fixed invariants

The default remains OpenAI. Local mode processes one complete Utterance after Talk Key
release, emits only a Final Transcript, and can operate without credentials or network
access once its Model Installation is ready. This specification does not support arbitrary
Hugging Face repositories, user-supplied model paths, Intel Macs, non-macOS platforms,
automatic model updates, fine-tuning, learned vocabulary, or fallback between backends.

- **CORE-1:** The selected Transcription Backend must be either `openai` or `local`, with
  `openai` as the default for an existing or newly generated configuration.
- **CORE-2:** An Utterance accepted by one backend must remain pinned to that backend until
  Insertion or abandonment; its PCM must never be submitted to another backend.
- **CORE-3:** A backend failure, timeout, missing prerequisite, or empty Final Transcript
  must abandon the Utterance without retry, Insertion, or cross-backend fallback.
- **CORE-4:** ADR 0001's serialized lifecycle must remain
  `idle -> capturing -> awaiting_final -> inserting -> idle`; no backend may queue a second
  Utterance.
- **CORE-5:** English, Swedish, and auto-detect must keep their current user-facing
  semantics for both backends.
- **CORE-6:** PCM and transcript text must be absent from default logs and diagnostics.
  A separately named diagnostic setting may enable transcript-content logging only after
  presenting a privacy warning.

## 2. Target component boundaries

The names below fix ownership and public seams, not private helper functions.

| Component | Target module | Ownership |
| --- | --- | --- |
| Utterance lifecycle | `src/coordinator.zig` | Utterance identity, phase, poison/abandon policy, deadline, terminal-event arbitration |
| Backend contract and selection | new `src/transcription_backend.zig` | Backend lease, neutral command/event vocabulary, selected adapter routing |
| OpenAI adapter | new `src/openai_backend.zig`, using `src/session.zig` | Map the neutral seam to the existing streaming Transcription Session |
| Local adapter | new `src/local_backend.zig` | Capture buffering + silence-cut Segmentation (ADR-0003), helper supervision, IPC request mapping |
| Helper executable | new `src/whisper_helper.zig` plus narrow runtime bindings | Model load/warm, 24 kHz-to-16 kHz conversion, whisper.cpp inference, cooperative cancellation |
| IPC codec | new `src/whisper_ipc.zig` | Framing, validation, limits, structured failures |
| Model lifecycle | new `src/model_store.zig` | Model Installation, Model Operation, receipt, staging, verification, activation, removal |
| Readiness reconciliation | new `src/backend_supervisor.zig`, extending `src/configuration_phase.zig` | Independent configuration, selected-backend readiness, operation, pause, and recovery axes |
| Credentials | extend `src/keychain.zig` and `src/config.zig` | OpenAI key only; the local backend needs no credential |
| User interface | extend `src/menu.zig` | Backend chooser, relevant primary action, Local Model submenu, secure prompts |
| Process composition | `src/daemon.zig` | Construct components and connect events only; it must not absorb their state machines |
| Build and install | `build.zig`, `packaging/install.sh`, `docs/packaging.md` | Pinned runtime build, paired installation/signing, attribution |
| Acceptance tooling | new `tests/local_backend/` and checked-in corpus | Corpus manifest, scoring, benchmarks, network/privacy probes, fault injection |

### 2.1 Backend-neutral seam

The Zig API may use comptime-generic dependencies like the existing Coordinator. Its
observable contract is equivalent to:

```zig
const BackendId = enum { openai, local };
const Language = enum { english, swedish, auto_detect };

const Lease = struct {
    backend: BackendId,
    language: Language,
    final_deadline_ms: u32,
};

const Backend = struct {
    fn acquire(language: Language) !Lease;
    fn begin(lease: Lease, utterance_id: u64) !void;
    fn appendAudio(utterance_id: u64, pcm_24khz_mono_s16le: []const u8) !void;
    fn release(utterance_id: u64) !void;
    fn cancel(utterance_id: u64) void;
};

const BackendEvent = union(enum) {
    final: struct { utterance_id: u64, text: []const u8 },
    failed: struct { utterance_id: u64, reason: Failure },
};
```

- **LIFE-1:** On an accepted Talk Key press, the Coordinator must allocate a monotonically
  increasing process-local Utterance ID and acquire an immutable lease containing backend,
  language, and deadline policy before Capture starts.
- **LIFE-2:** If no ready lease exists or `begin` fails synchronously, Capture must not
  start and the Utterance must be abandoned from `idle`.
- **LIFE-3:** `appendAudio` must consume or copy its borrowed PCM before returning. Capture
  must stop synchronously before `release`, so all tail audio precedes release.
- **LIFE-4:** The Coordinator must not retain PCM. OpenAI must stream each chunk; local
  buffers behind its adapter and inserts one Final Transcript on `release`. _(Superseded in
  part by ADR-0003: a long local Utterance is now cut into background **Segments** submitted
  mid-Utterance, still assembled into one Insertion on release; a short Utterance is one
  Segment submitted on release, as before.)_
- **LIFE-5:** Backends must emit only ID-tagged `final` or `failed` lifecycle events to the
  Coordinator. OpenAI Partial Transcripts remain optional backend diagnostics and local
  must not synthesize them.
- **LIFE-6:** Backend callbacks must run only after the initiating command returns and
  never while a backend lock is held.
- **LIFE-7:** The Coordinator must accept a terminal backend event only when its ID and
  expected phase match. It must ignore late, duplicate, mismatched, and post-cancellation
  events.
- **LIFE-8:** Loss during Capture must poison the Utterance, cancel backend work, and stop
  forwarding PCM while leaving Capture and feedback active until release. Release must
  then stop Capture and abandon without calling backend `release`.
- **LIFE-9:** Empty Capture must call `cancel` and abandon. An empty Final Transcript,
  backend failure while awaiting final, or deadline must cancel and abandon immediately.
- **LIFE-10:** A non-empty Final Transcript must be copied synchronously into the Insertion
  job under Coordinator serialization. Only the matching insertion completion may return
  the lifecycle to `idle`.
- **LIFE-11:** Final Transcript, failure, and deadline races must be serialized; the first
  matching terminal event wins exactly once.
- **LIFE-12:** Changing backend selection must persist immediately but use drain-then-switch
  behavior: finish the active lease, reject new Capture during reconciliation, then prepare
  only the latest selection.
- **LIFE-13:** OpenAI must retain its 15-second release-anchored deadline. Local must request
  cooperative cancellation at 9.5 seconds and forcibly terminate the helper by the
  10-second hard deadline.

## 3. Local runtime and helper process

### 3.1 Pinned dependency and artifact

- **RUNTIME-1:** Build whisper.cpp v1.9.1 from the verified upstream source archive with
  SHA-256 `147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447` and Metal enabled.
- **RUNTIME-2:** Statically link the runtime into a private executable named
  `type-wave-whisper`; users must not need runtime libraries or a package manager.
- **RUNTIME-3:** Use only the official F16 `ggml-large-v3-turbo.bin` from the pinned
  `ggerganov/whisper.cpp` revision. Its size must be 1,624,555,275 bytes and SHA-256 must be
  `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`. The artifact downloads
  credential-free; no Hugging Face account or token is involved.
- **RUNTIME-4:** The helper must accept 24 kHz mono signed 16-bit little-endian PCM and own
  deterministic conversion to whisper.cpp's required 16 kHz input. It must reject malformed,
  oversized, odd-length, or unsupported audio rather than infer over it.
- **RUNTIME-5:** The helper must load one model context and keep it warm for its process
  lifetime. It must execute at most one inference request at a time.
- **RUNTIME-6:** Initial model/Metal preparation must complete before local readiness.
  Capture must not be accepted while the helper is loading or warming.
- **RUNTIME-7:** The helper must receive only its verified Model Installation path, PCM,
  language mode, and request ID. It must receive no OpenAI key, Hugging Face token, signed
  URL, or model-management responsibility and must make no network calls.

Do not substitute Q5_0 merely to reduce disk or memory use. A different model, artifact,
revision, runtime version, or quantization requires a new decision effort and a complete
acceptance rerun.

### 3.2 Installation and process boundary

- **HELPER-1:** Install the helper at
  `~/.local/libexec/type-wave/type-wave-whisper`, outside `PATH`, and sign it through the
  same installation workflow and identity as the daemon.
- **HELPER-2:** The daemon and helper must be installed/upgraded as one compatible unit.
  A protocol-version mismatch must make local unavailable, never attempt compatibility
  guessing, and expose diagnostics.
- **HELPER-3:** Launch and warm the helper when local becomes the selected configured
  backend. Terminate it after switching to OpenAI and release its warmed memory.
- **HELPER-4:** Communicate only over private stdin/stdout pipes. Stderr is diagnostic and
  must obey **CORE-6**.
- **HELPER-5:** Unexpected exit, broken pipes, malformed frames, runtime failure, or hard
  timeout must abandon the active Utterance. The daemon must reject all remaining bytes
  from that helper instance before starting another.

### 3.3 Version 2 IPC

Each frame has a 12-byte little-endian header: ASCII magic `TWW1`, `u16 version` (value
`2`), `u16 kind`, and `u32 payload_length`, followed by exactly that many payload bytes.
The maximum payload is 2 MiB. Invalid UTF-8, inconsistent lengths, trailing bytes, and
frames over the limit are protocol failures. Version 2 added the `transcribe` frame's
length-prefixed vocabulary prompt region (docs/vocab-biasing-spec.md §5), consuming the
former reserved bytes; a daemon only ever talks to a helper it spawned from the current
on-disk binary, so a partial upgrade surfaces as a transient helper-startup failure via
the existing `UnsupportedVersion` rejection, not a live cross-version pipe.

| Kind | Direction | Payload |
| --- | --- | --- |
| `ready` | helper -> daemon | 32-byte model digest after successful warm-up |
| `startup_failed` | helper -> daemon | `u16 code`, `u32 message_len`, UTF-8 diagnostic |
| `transcribe` | daemon -> helper | `u64 id`, `u8 language`, `u16 prompt_len`, UTF-8 vocabulary prompt, `u32 pcm_len`, PCM |
| `cancel` | daemon -> helper | `u64 id` |
| `final` | helper -> daemon | `u64 id`, `u32 text_len`, UTF-8 Final Transcript |
| `failed` | helper -> daemon | `u64 id`, `u16 code`, `u32 message_len`, UTF-8 diagnostic |

- **IPC-1:** The daemon must validate `ready` against the active receipt's model digest
  before declaring the helper warm.
- **IPC-2:** While inference runs, the helper must continue reading commands so a matching
  `cancel` can trip whisper.cpp's abort callback. A mismatched or repeated cancel must not
  affect another request.
- **IPC-3:** The helper must emit exactly one `final` or `failed` response for a normally
  completed request. After forced process termination, absence of a response is expected.
- **IPC-4:** Diagnostics must be bounded and must not echo PCM or Final Transcript content.

## 4. Model Installation and Model Operation

Type-wave owns its model data under
`~/Library/Application Support/type-wave/models/`; it must neither use nor mutate the
shared Hugging Face cache.

### 4.1 Credential contract (retired)

- **MODEL-1** through **MODEL-5** governed Hugging Face token storage, capture, validation,
  and forgetting. The pinned artifact downloads credential-free, so these requirements are
  retired with the model switch (#90): the daemon stores no Hugging Face credential, exposes
  no token capture or forget action, and sends no `Authorization` header for a Model
  Operation. The OpenAI API key remains the only stored credential and is unrelated to the
  local backend.

### 4.2 Acquisition, staging, and activation

- **MODEL-6:** Embed the desired immutable revision, runtime-artifact identity, exact size,
  and SHA-256 manifest in each type-wave release. Any difference in that complete identity
  is an available update.
- **MODEL-7:** Install and update only after explicit user action. Startup and ordinary
  status checks must not perform network requests, update checks, or automatic downloads.
- **MODEL-8:** Send no authentication with artifact requests. Follow fresh signed
  cross-origin redirects. Resume only from a validated `206` tied to the matching revision
  and validators.
- **MODEL-9:** Stage on the same filesystem as the installation. Preflight space for the
  full stage plus overhead while retaining the working installation.
- **MODEL-10:** Serialize download, update, verify, repair, activation, and removal with one
  in-process Model Operation and a cross-process filesystem lock. Inference may keep using
  the active revision during staging; activation and removal must wait for it to become idle.
- **MODEL-11:** Retry transient transport/server failures during a user-started operation
  with bounded exponential backoff and visible retry state. Authentication failure,
  manifest mismatch, insufficient space, or exhausted retries must require explicit action.
- **MODEL-12:** Cancellation must be cooperative during download, hashing, and smoke test.
  Atomic activation is non-cancellable. Preserve partial files only when their identity and
  validators still prove them resumable.
- **MODEL-13:** Restart must never resume network activity automatically. Expose one valid
  partial for the desired identity as paused; allow explicit resume or discard; discard
  invalid or incompatible partial data automatically.
- **MODEL-14:** Report byte-accurate download and hashing progress separately. Name smoke
  test and activation as indeterminate stages; downloaded bytes alone must not be presented
  as an installed model.
- **MODEL-15:** After full size/digest verification and a runtime load/smoke test, atomically
  replace a small active receipt. Keep the old installation active until the replacement is
  published and unused, then remove it.
- **MODEL-16:** The versioned receipt must contain repository, revision, runtime-artifact
  identity, exact manifest, model digest, and installing type-wave version. Staging metadata
  alone may contain validators and offsets. Neither may contain credentials or signed URLs.
- **MODEL-17:** Ordinary offline startup may trust a verified receipt only while paths,
  sizes, and file metadata are unchanged. Re-run SHA-256 after acquisition/update, metadata
  change, interrupted installation, load failure, or explicit Verify/Repair.
- **MODEL-18:** Corruption or unloadability must make local unavailable without fallback or
  automatic download. Repair must verify first and, after confirmation, fetch only missing
  or invalid data under an explicitly network-allowed operation.
- **MODEL-19:** Confirmed removal must reject new local Utterances, allow an active local
  lease to resolve, unload the helper, and remove installed and staged data. It must leave
  local selected but unavailable.
- **MODEL-20:** Ship the OpenAI Whisper MIT license text and GGML-conversion attribution
  with type-wave and place a non-secret provenance notice beside every installation.

The public state is two independent axes:

```text
Model Installation = absent | ready(identity) | unusable(reason)
Model Operation    = idle | downloading | paused | verifying | smoke_testing |
                     activating | removing | failed(reason)
```

`update_available` is derived by comparing a ready identity with the embedded desired
identity; it is not another installation state.

## 5. Configuration, readiness, recovery, and privacy

### 5.1 State axes and prerequisites

- **READY-1:** Keep Configuration Phase, selected-backend readiness, Model Operation, and
  pause as independent axes.
- **READY-2:** Common durable prerequisites are Microphone, Input Monitoring, and
  Accessibility/PostEvent permission plus a live Talk Key tap. OpenAI additionally needs a
  readable OpenAI API key; local additionally needs a verified Model Installation.
- **READY-3:** Configuration Phase must be `configured` exactly when common prerequisites
  and the selected backend's durable prerequisite are present. Connectivity, helper warm-up,
  Model Operations, update availability, and pause must not define the phase.
- **READY-4:** Selected-backend readiness must be `unavailable(reason)`,
  `preparing(stage)`, or `ready`. Pause must reject Capture without changing configuration
  or readiness.
- **READY-5:** Derive the Status Item headline in this priority: paused, missing common
  prerequisite, missing selected-backend prerequisite, terminal backend failure, selected
  backend preparing, ready.
- **READY-6:** A staged update beside a working installation must leave local ready. Update
  availability must be informational, not readiness failure.

### 5.2 Reconciliation and failure recovery

- **READY-7:** Startup and selection changes must use one reconciliation path. A selection
  is authoritative immediately; rapid changes must converge on the latest value.
- **READY-8:** OpenAI network loss must leave OpenAI configured but unavailable/reconnecting,
  abandon an active Utterance, and reconnect with bounded backoff. Proven invalid credentials
  must latch failure until the key changes.
- **READY-9:** Explicit OpenAI-key removal must reject new OpenAI Utterances immediately but
  allow an authenticated active lease to finish, then close the session and make OpenAI
  not-configured. Temporary Keychain unavailability must preserve a healthy session and retry.
- **READY-10:** With local selected and a valid receipt, startup must read no credential
  and make no network request. It must verify the offline-startup contract, launch/warm the
  helper, and then report `Ready offline`.
- **READY-11:** A helper load failure must trigger offline integrity verification. Failed
  verification means unusable installation with Repair/Remove actions. Successful verification
  followed by another load failure means configured-but-unavailable runtime failure with Retry
  and diagnostics; it must not download or repair automatically.
- **READY-12:** Timeout, exit, broken IPC, or malformed output must move readiness to
  preparing/restarting and launch a fresh helper after 1-, 2-, then 4-second backoff. Three
  consecutive failed launches or inference-ending helper failures must latch runtime failure.
  Explicit Retry or switching away and back resets the budget; a successful Final Transcript
  resets it.
- **READY-13:** Loss of a common prerequisite must immediately reject new Capture and poison
  an active Utterance. Loss of the Talk Key tap must also stop Capture without waiting for a
  release that cannot arrive. Restoration must automatically reconcile without repeated prompts.

### 5.3 Privacy boundary

- **PRIV-1:** While local is selected, no Capture PCM or transcript may enter a
  network-capable component.
- **PRIV-2:** The daemon may use the network in local mode only during an explicit Model
  Operation. Artifact requests must contain no Capture PCM or transcript content.
- **PRIV-3:** Credential access must be demand-scoped: OpenAI credentials only while OpenAI
  is selected. The local backend and its Model Operations read no credential at all.
- **PRIV-4:** Logs may contain backend identity, timings, language, byte counts, lifecycle
  stages, HTTP status, retry timing, and digest mismatch facts. They must never contain tokens,
  authorization headers, signed redirect URLs/query strings, PCM, or transcript text by default.

## 6. Settings and Status Item behavior

Add a closed settings field equivalent to:

```zig
transcription_backend: enum { openai, local } = .openai,
```

`language` remains shared. Existing `model`, `delay`, and `noise_reduction` settings are
OpenAI-specific and must remain intact when local is selected. The local model identity is
release-pinned and is not a free-form setting.

- **UX-1:** The main menu must show, in order of hierarchy, the derived readiness headline,
  Transcription Backend chooser, only the relevant primary action or operation progress,
  and the relevant privacy cue.
- **UX-2:** Local ready state must say `Audio stays on this Mac`. An active Model Operation
  must add `Network used only for this model operation` without weakening the audio claim.
- **UX-3:** The relevant primary actions must be: Install when absent, Update when available,
  named progress/retry/resume during an operation, Repair when corrupt, Retry for runtime
  failure, and Set OpenAI API key when that selected backend lacks its credential.
- **UX-4:** A `Local Model` submenu must remain available under either selected backend. It
  must show exact installation/operation identity and secondary actions: cancel/discard
  partial, Verify/Repair, Remove, Retry, and diagnostics.
- **UX-5:** OpenAI model and credential controls must appear only in OpenAI context. There
  must be no backend-neutral `Model` row.
- **UX-6:** Destructive confirmations must say whether the active Utterance may finish,
  distinguish staged data from the working Model Installation, and state that there is no
  fallback.
- **UX-7:** *(retired with MODEL-1–MODEL-5: there is no Hugging Face prompt.)*
- **UX-8:** Progress must use byte-accurate transfer text and named verification, smoke-test,
  and activation stages. It must distinguish a staged update from the working installation.
- **UX-9:** Backend selection and all menu actions must publish complete Settings Snapshots
  or send commands to the owning component; `menu.zig` must not directly mutate backend,
  helper, or Model Operation state.

## 7. Packaging and provenance

- **PACK-1:** `zig build` must build both compatible executables and tests from the pinned
  whisper.cpp source without requiring a preinstalled runtime.
- **PACK-2:** `zig build install-agent` must sign and atomically install the daemon and helper
  at their fixed paths before reloading either. A partial pair must not replace a working pair.
- **PACK-3:** The helper must share the daemon's stable signing workflow. Distribution
  notarization remains outside this specification.
- **PACK-4:** The installed documentation/data must include the OpenAI Whisper MIT license
  text, GGML-conversion attribution, pinned revision, artifact digest, and whisper.cpp
  version/source digest.
- **PACK-5:** Uninstall guidance must separately identify daemon/helper files, Model
  Installation data, the OpenAI Keychain item, and TCC grants; model data and credentials
  must not be silently removed merely because binaries are upgraded.

## 8. Implementation sequence

Each increment must leave the existing OpenAI path working and its tests green.

1. **Acceptance assets first.** Check in the licensed corpus, exact references and tags,
   scoring, base-M1 measurement harness, network/privacy probes, and deterministic fault
   injection before tuning local inference.
2. **Neutral seam without behavior change.** Add Utterance IDs, leases, the backend contract,
   and an OpenAI adapter. Move existing Coordinator tests to the neutral events and prove
   OpenAI semantics and ADR 0001 are unchanged.
3. **Thin local path.** Build the pinned helper and IPC, then run the local adapter against a
   manually provisioned verified artifact. Prove warm inference, language modes, cancellation,
   forced termination, crash containment, and stale-result rejection.
4. **Readiness and selection.** Add supervisor axes, persisted backend choice,
   drain-then-switch, offline startup, helper warm/restart/latch policy, and privacy assertions.
5. **Managed installation.** Add credential-free acquisition, staging, resume/cancel,
   verification, receipt, atomic activation, repair, update, and removal.
6. **Status Item.** Graduate the accepted compact hierarchy and dialogs, keeping state
   ownership in the supervisor/model store.
7. **Packaging and release pass.** Pair-install/sign the helper, ship provenance, run every
   automated and observed gate on the base M1, and record the results without changing pins
   or thresholds.

## 9. Verification contracts

### 9.1 Authoritative quality corpus

- **ACCEPT-1:** Check in a versioned, redistributable human-speech corpus with two English
  and two Swedish speakers, 10 Utterances per language, balanced short/medium/10-15-second
  lengths, and natural dictation including punctuation, technical terms, proper nouns,
  numbers, self-corrections, negation, and commands.
- **ACCEPT-2:** Store exact reference Final Transcripts and per-fixture tags. Run explicit
  English, explicit Swedish, and auto-detect over the same relevant audio. Synthetic audio
  may diagnose but must not determine release acceptance.
- **ACCEPT-3:** Report corpus-wide micro-averaged WER after case-folding and punctuation
  removal, separately for explicit English, explicit Swedish, and each language in auto mode;
  also report per-Utterance WER.
- **ACCEPT-4:** Release requires explicit-English WER <=12%, explicit-Swedish WER <=20%,
  auto-detect WER <=12% for English and <=26% for Swedish, no Utterance above 40% WER
  except the pinned waivers (`sv-b-02` in both modes and `sv-b-01` in auto, each <=80%),
  punctuation-mark F1 >=0.72 for `. , ? ! : ;`, and zero meaning-changing errors in
  protected fixtures. Thresholds are per-model calibration against the benchmarked
  turbo candidate (#87, #88), asserting "no worse than the turbo we qualified"; the
  zero-protected-errors rule is product law.

### 9.2 Base-M1 performance and resources

- **ACCEPT-5:** On a base Apple M1 with 8 GB RAM, run each corpus Utterance three times after
  warm-up. Every <=15-second Utterance must produce its Final Transcript within 2.6 seconds
  after Talk Key release in explicit-language mode and 4.8 seconds in auto-detect mode
  (auto pays a language-detection pass); report median and worst case and gate on the
  worst case per mode.
- **ACCEPT-6:** Cached helper launch plus warm-up must reach ready within 4.0 seconds
  (readiness is hash-bound: the full 1.6 GiB artifact is re-hashed before READY). First
  Metal preparation may take up to 15 seconds while visibly preparing and rejecting
  Capture (a cold system Metal cache compiles the embedded pipeline library:
  ~11.9 seconds measured on the base M1).
- **ACCEPT-7:** Peak helper RSS during inference must be <=500 MiB and warmed idle RSS
  <=300 MiB. RSS cannot observe mmap'd weights or Metal memory, so these bars detect
  helper-process leaks and accidental heap copies of the model, not model footprint.
- **ACCEPT-8:** A forced overrun must request cooperative cancellation at 9.5 seconds,
  terminate the helper by 10.0 seconds, abandon the Utterance, and produce no Insertion.
  Both actions are timer-driven at their exact deadlines; the retained wall-clock
  observation may carry bounded scheduling overshoot (≤250 ms, never an early firing).

### 9.3 Offline, privacy, and lifecycle

- **ACCEPT-9:** With local selected, remove access to every stored credential, disable
  networking, restart, reach `Ready offline`, and complete the corpus.
- **ACCEPT-10:** Deny helper networking and instrument the daemon network boundary. Any
  helper socket attempt or daemon request during local startup, warm-up, Capture,
  transcription, or Insertion fails release.
- **ACCEPT-11:** Scan default logs/diagnostics after corpus execution and prove PCM and Final
  Transcript content absent while operational metadata remains. Separately prove explicit
  Model Operation traffic contains neither.
- **ACCEPT-12:** Deterministic tests must cover success; empty Capture/transcript; loss during
  Capture; crash, malformed IPC, and inference failure; restart/latch/reset; cooperative and
  forced cancellation; terminal races; stale IDs; non-idle presses; switching during an
  Utterance; prerequisite loss; recovery; and no Insertion, retry, or fallback on abandonment.
- **ACCEPT-13:** Every acceptance category is release-blocking and cannot compensate for
  another. Thresholds must not be waived after results are known.
- **ACCEPT-14:** A miss permits optimization only with the model, artifact, runtime, corpus,
  and thresholds unchanged, followed by a complete rerun. A remaining miss is a no-go or a
  new wayfinder effort; it must not cause silent quantization, model substitution, fallback,
  or experimental release.

## 10. Completion checklists

### Implementation-complete

- [ ] Every `CORE`, `LIFE`, `RUNTIME`, `HELPER`, `IPC`, `MODEL`, `READY`, `PRIV`, `UX`, and
      `PACK` requirement is implemented and has automated coverage where deterministic.
- [ ] Existing OpenAI behavior and ADR 0001 lifecycle tests pass through the neutral seam.
- [ ] The local happy path and every specified fault path pass with a manually provisioned
      and a type-wave-managed Model Installation.
- [ ] Settings round-trip with OpenAI as the backward-compatible default and preserve
      backend-specific settings across selection changes.
- [ ] Daemon/helper pair installation, upgrade, protocol mismatch, and uninstall guidance
      have been exercised.
- [ ] The accepted compact Status Item hierarchy and destructive/credential dialogs have
      received a final human reaction pass in the deployed daemon.

### Release-ready

- [ ] `ACCEPT-1` through `ACCEPT-4`: checked-in human corpus and every quality/severity
      threshold pass without changed fixtures or thresholds.
- [ ] `ACCEPT-5` through `ACCEPT-8`: every base-M1 latency, readiness, memory, and timeout
      threshold passes.
- [ ] `ACCEPT-9` through `ACCEPT-11`: offline, socket-boundary, credential-independence,
      and log-content checks pass.
- [ ] `ACCEPT-12`: the full deterministic lifecycle/failure matrix passes.
- [ ] Shipped manifests, source/runtime digests, license, attribution, model receipt, and
      recorded acceptance results identify the exact same pinned design.
- [ ] Any miss has followed `ACCEPT-13` and `ACCEPT-14`; no waiver or unplanned substitution
      has entered the release.

## 11. Decision traceability

| Requirements | Responsible component | Originating decision | Primary verification |
| --- | --- | --- | --- |
| `CORE-1`-`CORE-6` | backend selection, Coordinator, logging | [backend lifecycle](https://github.com/dbgeek/type-wave/issues/61), [readiness/privacy](https://github.com/dbgeek/type-wave/issues/62) | neutral-seam, privacy, and regression suites |
| `LIFE-1`-`LIFE-13` | Coordinator and backend adapters | [Design the backend-neutral transcription lifecycle](https://github.com/dbgeek/type-wave/issues/61) | deterministic Coordinator matrix and adapter contract tests |
| `RUNTIME-1`-`RUNTIME-7` | helper/runtime build | [model pin](https://github.com/dbgeek/type-wave/issues/66), [base-M1 prototype](https://github.com/dbgeek/type-wave/issues/65), [runtime boundary](https://github.com/dbgeek/type-wave/issues/60) | manifest verification, helper integration, base-M1 gates |
| `HELPER-1`-`HELPER-5`, `IPC-1`-`IPC-4` | helper supervisor and IPC codec | [Choose the local inference runtime and isolation boundary](https://github.com/dbgeek/type-wave/issues/60) | codec fuzz/limit tests, crash/cancel/protocol tests |
| `MODEL-1`-`MODEL-20` | Keychain and model store | [artifact contract](https://github.com/dbgeek/type-wave/issues/58), [authenticated model management](https://github.com/dbgeek/type-wave/issues/64) | HTTP fixture server, filesystem fault injection, offline restart tests |
| `READY-1`-`READY-13`, `PRIV-1`-`PRIV-4` | configuration phase and backend supervisor | [Specify backend-specific readiness and privacy behavior](https://github.com/dbgeek/type-wave/issues/62) | state-table, recovery, network-boundary, and log scans |
| `UX-1`-`UX-9` | Status Item and settings | [Prototype local-model management in the Status Item](https://github.com/dbgeek/type-wave/issues/57) | native menu state matrix and human reaction pass |
| `PACK-1`-`PACK-5` | build/install workflow | [runtime boundary](https://github.com/dbgeek/type-wave/issues/60), [model management](https://github.com/dbgeek/type-wave/issues/64) | clean paired install/upgrade and provenance inspection |
| `ACCEPT-1`-`ACCEPT-14` | acceptance tooling and release owner | [Define local-transcription acceptance and release gates](https://github.com/dbgeek/type-wave/issues/63) | checked-in reports from the exact pinned release candidate |

## 12. Source impact summary

The Coordinator remains the single owner of an Utterance lifecycle; the backend seam
replaces its current OpenAI-specific transcription dependency without moving lifecycle
policy into adapters. `session.zig` remains the OpenAI protocol implementation. The local
adapter owns its PCM buffer and helper instance. The model store owns disk/network/receipt
state. The backend supervisor owns reconciliation and readiness. The Status Item renders
those states and sends commands. `daemon.zig` wires these owners together.

This separation is an acceptance condition of the handoff: implementation must not create
a second lifecycle authority, allow menu code to mutate service state directly, give the
helper network or credential capability, or make the Model Operation determine whether an
already-installed local backend is ready.
