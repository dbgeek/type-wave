# type-wave

macOS dictation tool: hold a key, speak, and the transcribed text lands at the focused cursor in whatever app you're using.

## Language

**Utterance**:
One hold-to-talk span of speech, from Talk Key press to release. The unit of dictation; yields exactly one Insertion.
_Avoid_: recording, clip

**Talk Key**:
The key held down to capture an Utterance; releasing it ends the Utterance.
_Avoid_: hotkey, PTT key

**Partial Transcript**:
Provisional text emitted while an Utterance is still being spoken. Logged, may be revised, never shown in the HUD, never inserted.
_Avoid_: delta, interim result

**Final Transcript**:
The committed text for a completed Utterance; the only text that is ever inserted. For a
multi-Segment Utterance it is the ordered concatenation of that Utterance's Segment
Transcripts; a short single-Segment Utterance yields it directly.
_Avoid_: result, output

**Segment**:
A contiguous span of one Utterance's Capture, transcribed on its own. The local Backend
cuts a long Utterance into Segments at silences — a 15 s soft floor, then the next
≥400 ms pause, with a 25 s hard-max force-cut — so it can transcribe them in the
background while the Utterance is still being spoken. A short Utterance is a single
Segment, identical to pre-segmentation behaviour. OpenAI never segments; it streams. See
ADR-0003.
_Avoid_: chunk (that names the 50 ms Capture buffer), clip

**Segment Transcript**:
The committed text of one Segment. Segment Transcripts concatenate in spoken order into
their Utterance's Final Transcript. Unlike a Partial Transcript it is not revisable, and —
as part of the Final Transcript — it is inserted.
_Avoid_: partial (a Partial Transcript is the revisable OpenAI delta)

**Segmenter**:
The pure state machine that owns the silence-cut policy (ADR-0003): it accumulates one
Utterance's Capture and decides where each Segment ends — the 15 s soft floor, the next
≥400 ms pause, the 25 s hard-max force-cut. A Capture buffer and its RMS level go in; an
owned Segment's PCM comes out at each cut. It holds no queue, lease, or IPC — the local
Transcription Backend's adapter drives it under its own lock and owns everything past the
cut. Lives in `src/segmenter.zig`, exercised by fed (rms, pcm) pairs, not real audio.
_Avoid_: chunker, splitter, VAD (it is not a general voice-activity detector)

**Whisper Helper**:
The warm, private child process that transcribes a Segment's PCM off the daemon's main
process — the "warm helper" the Backend Router and Local Provisioner keep alive. Its
parent-side owner (`ProcessHelper`, `src/whisper_process_helper.zig`) holds the pipe
protocol, the single-slot reservation, the two-lock write discipline, and the crash →
fail-active → backoff → relaunch recovery ladder, surfacing only identity-tagged terminal
events. The local Transcription Backend's Segmenting adapter drives it across the **Helper
seam** — `reserveUtterance` / `submit` / `requestCancel` / `cancel` and the `final` / `failed`
reverse edge — whose contract lives with that adapter (`local_backend.assertHelper`), so the
adapter is exercised against a `FakeHelper` rather than a real subprocess.
_Avoid_: whisper server, worker, subprocess (that names the mechanism, not the role)

**Insertion**:
Placing a Final Transcript at the cursor of the Focused Target. Every Insertion ends with
a single trailing space, so consecutive Insertions don't run their words together.
_Avoid_: typing, pasting (those name mechanisms, not the act)

**Backtrack**:
The opt-in rewrite pass between an Utterance's Final Transcript and its Insertion
(docs/backtrack-spec.md): one OpenAI call applies spoken self-corrections ("at 20:00 no
18:00" → "at 18:00") and removes disfluencies. Enablement is read from the Settings
Snapshot at Talk Key press and pinned with the backend Lease; it applies only when the
pinned backend is OpenAI, and whenever it cannot run the raw Final Transcript inserts
unchanged — dictation never breaks.
_Avoid_: cleanup, post-processing (both name only half the pass), correction mode

**Rewrite**:
Backtrack's one transformation of a Final Transcript, driven by the Utterance
Coordinator's `.rewriting` phase through the Rewrite seam: a worker thread makes the
OpenAI Responses call off-mutex (`rewrite_adapter.zig`, `openai_rewrite.zig`) and the
`.rewritten` reverse edge hands the text to Insertion. A failed Rewrite falls back to
the raw Final Transcript.
_Avoid_: edit, fixup, transformation (vague), LLM call (mechanism)

**Focused Target**:
The app and text field that own the cursor at the moment of Insertion.
_Avoid_: active window

**Transcription Session**:
The live connection to the transcription service over which an Utterance's audio streams out and transcripts stream back.
_Avoid_: websocket (mechanism)

**Transcription Backend**:
The selected source of a Final Transcript for an Utterance; it may also emit Partial Transcripts. OpenAI is the default backend; the local Whisper backend is an offline alternative.
_Avoid_: transcription provider, engine

**Backend Router**:
The daemon's one route from an accepted Utterance to the selected Transcription Backend,
and the owner of the drain-then-switch policy: an accepted Utterance pins its backend
through Insertion or abandonment; a backend switch — or a Model Installation activating
under the warm helper — drains first, then tears down the obsolete resource and warms a
generation-tagged replacement. It reaches every effect (connect, warm, narrate) through
a dependency seam it is handed, so it is exercised by scripted events, not hardware.
_Avoid_: transcription adapter, backend manager

**Local Provisioner**:
The daemon's one route that warms the local Transcription Backend from its Model
Installation — behind the Backend Router's local `warm` effect. It owns the load-verify →
spawn → recovery latch: on a load failure it verifies the Model Installation offline once
(distinguishing corruption from a runtime load failure), and a verified-load failure then
latches until a SIGHUP retry. It owns the corruption/runtime-failure decision state and the
cross-thread failure the Status Item reads, and reaches every effect (resolve, verify,
spawn, build the adapter, cleanup) through a dependency seam it is handed, so its recovery
ordering is exercised by scripted verify/load outcomes, not real subprocesses. Lives in
`src/local_provisioner.zig`; distinct from the Model Operation Runner, which runs
user-authorized Model Operations rather than warming the runtime.
_Avoid_: local backend manager, warmer, model runner

**Model Installation**:
A verified local copy of the pinned model artifact (currently ggml-large-v3-turbo; see `packaging/share/type-wave/PROVENANCE`) that the local Transcription Backend can use offline. Downloaded credential-free; it exists independently of any Model Operation in progress.
_Avoid_: downloaded model, model cache

**Installation Receipt**:
The verified on-disk identity-and-provenance record of a Model Installation — repository,
revision, runtime, artifact, size, and sha256 — serialized as `active.receipt` at the models
root and mirrored byte-for-byte in each installation's `PROVENANCE`. `MODEL_MANIFEST` (the
bare size/sha256 file) and `partial.meta` (the download-resume record) are sibling
serializations of the same identity. The Installation Receipt codec (`src/receipt.zig`) is
the one place that knows those formats: pure, allocation-free `encode`/`parse`/`matches` over
the shared `key=value` line grammar, exercised directly rather than through a download. It
holds no I/O and no trust policy — model_store owns every read/write and decides *which*
trusted Manifest a receipt authenticates against.
_Avoid_: manifest (that names the trusted pin, not the on-disk record), provenance (that
names the mirror copy, not the concept)

**Model Operation**:
A user-authorized acquisition, verification, activation, repair, or removal acting on a Model Installation. An operation may be in progress while the current Model Installation remains usable.
_Avoid_: download state, model task

**Model Operation Runner**:
The daemon's one route from a Status Item action to a Model Operation child process, and
the owner of that operation's observation — the phase and byte progress the Status Item
reflects. It drives one operation from launch to a terminal outcome (success / cancelled /
failed), reaching every effect (spawn, cancel-kill, log) through a dependency seam it is
handed, so it is exercised by fed operation-channel events, not real subprocesses. It
consumes the operation-channel wire; it does not warm the local helper — that is the
Backend Router's path. Lives in `src/model_operation.zig`.
_Avoid_: model manager, operation orchestrator, download manager

**Capture**:
The microphone audio stream feeding a Transcription Session.
_Avoid_: recording

**Utterance Coordinator**:
The state machine that drives one Utterance from Talk Key press to a resolved
Insertion, across the Capture / Transcription / Insertion / Feedback seams. It owns
the lifecycle policy (the overlap guard, poison abandonment, the release-anchored
deadline, empty/failed handling) and nothing else — it reaches every side effect
through a seam it is handed, so it is exercised by feeding it events, not hardware.
_Avoid_: controller, manager, orchestrator

**Settings Snapshot**:
An immutable `Settings` value the daemon reads at any moment. The menu bar — the sole
writer, on the main thread — swaps in a complete fresh snapshot per change; readers
acquire-load once and see a coherent whole. Old snapshots leak by design, so a holder
(e.g. a connected Transcription Session) is never invalidated. `config.zon` stays the
canonical hand-editable form of the same settings.
_Avoid_: mutable config, live config object

**Configuration Phase**:
The daemon's setup-readiness state for the selected Transcription Backend. `configured`
requires the common macOS grants and live Talk Key tap plus that backend's durable
prerequisite: an OpenAI API key or a verified local Model Installation; transient backend
readiness and pause state affect status, but do not define this phase.
_Avoid_: setup state, readiness state, configured flag

**Supervisor**:
The pure per-tick decider of the daemon's self-heal nudges — the Talk Key tap re-arm and
the PostEvent probe (#127/#129) — plus the superseded-Model-Installation cleanup and the
capture-enable gate (the Talk Key press gate: `configured` AND a live backend AND not
paused). Fed a `Facts` snapshot and the Configuration Phase `Outcome`, it returns an
`Actions` bundle the daemon's self-heal loop executes; it reads the Configuration Phase
and sits beside the grant sequence but owns neither — those stay peer machines the daemon
drives. Lives in `src/supervisor.zig`, exercised by fed facts. Pure by choice, not
necessity (ADR-0005): the daemon keeps the impure fact-gathering and runs the effects, so
the async rearm/probe nudges stay visible in the loop.
_Avoid_: manager, controller, self-heal loop (that names the daemon thread, not the decider)

**Status Item**:
The daemon's menu-bar presence (icon near the clock): a two-tier icon — normal when
dictation can fire, dimmed when it can't (paused / no key / permission missing) — whose
menu shows the status line and edits every setting live. Recording/processing feedback
stays the HUD's job, never the Status Item's. Its presentation is pure: the daemon gathers
raw readings, `status_item.project` assembles them into a `Snapshot` (the corrupt override
and the Model Operation Runner precedence), and `status_item.derive` turns that into the
`Presentation` the menu renders — including the two-tier icon as its `icon_tier`. The menu
(`menu.zig`) is the AppKit adapter that reads that `Presentation`; it decides no status.
_Avoid_: tray icon, menu-bar app (the daemon is one process, not a separate app)
