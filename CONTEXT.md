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
Placing a Final Transcript at the cursor of the Focused Target.
_Avoid_: typing, pasting (those name mechanisms, not the act)

**Focused Target**:
The app and text field that own the cursor at the moment of Insertion.
_Avoid_: active window

**Transcription Session**:
The live connection to the transcription service over which an Utterance's audio streams out and transcripts stream back.
_Avoid_: websocket (mechanism)

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

**Status Item**:
The daemon's menu-bar presence (icon near the clock): a two-tier icon — normal when
dictation can fire, dimmed when it can't (paused / no key / permission missing) — whose
menu shows the status line and edits every setting live. Recording/processing feedback
stays the HUD's job, never the Status Item's.
_Avoid_: tray icon, menu-bar app (the daemon is one process, not a separate app)
