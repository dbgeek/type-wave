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
The committed text for a completed Utterance; the only text that is ever inserted.
_Avoid_: result, output

**Insertion**:
Placing a Final Transcript at the cursor of the Focused Target. Every Insertion ends with
a single trailing space, so consecutive Insertions don't run their words together.
_Avoid_: typing, pasting (those name mechanisms, not the act)

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

**Model Installation**:
A verified local copy of the pinned model artifact (currently ggml-large-v3-turbo; see `packaging/share/type-wave/PROVENANCE`) that the local Transcription Backend can use offline. Downloaded credential-free; it exists independently of any Model Operation in progress.
_Avoid_: downloaded model, model cache

**Model Operation**:
A user-authorized acquisition, verification, activation, repair, or removal acting on a Model Installation. An operation may be in progress while the current Model Installation remains usable.
_Avoid_: download state, model task

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

**Status Item**:
The daemon's menu-bar presence (icon near the clock): a two-tier icon — normal when
dictation can fire, dimmed when it can't (paused / no key / permission missing) — whose
menu shows the status line and edits every setting live. Recording/processing feedback
stays the HUD's job, never the Status Item's.
_Avoid_: tray icon, menu-bar app (the daemon is one process, not a separate app)
