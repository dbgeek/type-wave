# type-wave

macOS dictation tool: hold a key, speak, and the transcribed text lands at the focused cursor in whatever app you're using.

## Language

**Utterance**:
One hold-to-talk span of speech, from Talk Key press to release. The unit of dictation; yields exactly one Insertion.
_Avoid_: recording, clip

**Talk Key**:
The key held down to capture an Utterance; releasing it ends the Utterance. Which key is the
Talk Key is read from the Settings Snapshot **at the press** — a menu change binds at the next
one — but the release is matched against the **open hold** (`tap.Hold`: the press that was
forwarded and not yet released), never against the live setting, so changing the Talk Key while
the old one is held cannot swallow the edge that stops the microphone (#272).
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

**Signing Identity**:
The leaf certificate a binary's code signature was made with, and the proof the daemon
requires of the Whisper Helper before spawning it (`src/signing_identity.zig`, #284): the
helper must carry the leaf the *running daemon* carries. It is deliberately the signature
and not the receipt's `runtime_sha256` — that digest is recorded at model-install time and
the installer republishes the helper on every upgrade without touching the receipt, so
gating on it would retire the local backend at the next upgrade with no way back short of
re-downloading the model; it is also the weaker claim, since whoever can write the helper
can rewrite the plaintext receipt beside it. **We demand what was demanded of us**: the gate
is exactly as strong as this build's own signing and never stronger, so an unsigned or
ad-hoc dev build gates nothing and says so once at startup. The two sides fail opposite
ways, as the Insertion's Focused Target gate and Undo's do: an unreadable reading of
*ourselves* fails open (an oddity in our own house must not retire the backend), an
unverifiable *candidate* fails closed. Proved at **every** spawn including the recovery
ladder's relaunches — the helper path is a symlink through the `current` pair pointer, so a
proof taken at warm would be a proof about a file a later relaunch need not open. A refusal
skips the Local Provisioner's verify/retry ladder entirely and latches `runtime_failure`:
the Model Installation is not what failed.
_Avoid_: code signature check (that names the mechanism), helper hash, runtime digest
(`runtime_sha256` is the smoke test's witness, not an admission token)

**Insertion**:
Placing a Final Transcript at the cursor of the Focused Target. Every Insertion ends with
a single trailing space, so consecutive Insertions don't run their words together. It is
**gated on its Focused Target** (ADR-0009 amendment): the frontmost app noted at Talk Key
release must not have positively changed by the time the text would land, or the Insertion
refuses and shows the red refuse cue rather than pasting into whatever now owns the cursor.
Where Undo's identical comparison fails *closed*, this one fails **open** — a missing reading
on either side inserts, because refusing on an unreadable frontmost would break dictation
outright, which is far worse than the rare mis-target. A refusal is recoverable: the
transcript is still recorded, so the user re-inserts it from Recent Insertions into the app
they meant.
_Avoid_: typing, pasting (those name mechanisms, not the act)

**Insertion Runner**:
The daemon's one route from a Final Transcript — or a Recent Insertions action — to bytes at
the cursor, and the owner of the cursor policy for all three: the Insertion separator in both
directions, drain-time resolution, and the ring bookkeeping that follows an effect. Its rule
(ADR-0009): **every cursor job resolves on the Insert Worker, beside the effect it authorizes,
and any flag flips only after that effect landed** — ADR-0008's Undo rule, generalized. A
dictation job carries text and reports the bytes it *landed* back through the `.inserted`
reverse edge, which makes the Runner the sole applier of the separator: the Utterance
Coordinator stamps those bytes into the Insertion Record rather than re-deriving them. It also
owns the **Focused Target gate**: the Coordinator notes the frontmost app on the Talk Key
release edge (`noteTarget`) and the Runner re-reads it beside the paste, refusing on a
positive change and reusing that one reading as the record's App Identity hint. A menu
job carries only a capture stamp, queued on one bounded single-producer ring (the main thread
in, the worker out), so a second click during a ~300 ms drain queues rather than silently
overwriting the first. Anything that did nothing — a failed replay, an evicted stamp, a click
past the queue — earns the same red refuse cue an Undo refusal shows (ADR-0007). Holds the
Recent Insertions ring concretely, as the Undo Runner does. Lives in `src/insertion_runner.zig`;
`insert.zig` remains the macOS mechanism module.
_Avoid_: insertion adapter (it is the policy owner behind a seam, not an adapter at one),
paste worker, insert queue

**Insert Worker**:
The single thread the Insertion Runner and the Undo Runner are both drained on
(`insertion_runner.workerLoop`), and the priority between them: dictation first (it is
time-sensitive), then queued Recent Insertions actions, then Undo last. Its
single-threadedness is the whole serialization story for the cursor — it is what keeps a
deletion from landing between an Insertion's paste and its deferred clipboard restore, and
what lets a Copy drain that restore without racing a live dictation. It owns only the
priority; each Runner owns its own policy. Alone among the daemon's cursor-side threads it is
**joined at shutdown**: its loop polls the quit flag only between jobs and every job drains its
own restore, so waiting for it to come around is what keeps a Final Transcript from being left
on the general pasteboard — and the user's clipboard from dying with the process — when a quit
lands inside the ~300 ms restore window (#273).
_Avoid_: insert thread, paste worker (mechanism); insertion worker

**Insertion Record**:
The retained receipt of one Insertion, kept in the in-memory **Recent Insertions** ring
(the last N, newest-first, surfaced under the Status Item menu). One record holds: the
`inserted` text (the with-space bytes actually placed at the cursor, as reported back by the
Insertion Runner that placed them rather than re-derived — post-Rewrite when Backtrack ran,
raw otherwise; its grapheme-cluster count — `graphemeCount`, per #211 —
is what an Undo would delete); `raw`, the
trimmed Final Transcript, present only when it differs from `inserted` (i.e. a Rewrite
changed it); a capture `timestamp`; the `outcome` (`ok` / `degraded` / `failed` / `refused`,
known only at `onInserted` — the last two never reached the cursor, so neither is an Undo
target); and a best-effort **App Identity** hint (`focused_app` — bundle id
+ display name of the frontmost app, nullable, never load-bearing). The record is
deliberately app-level only: the Undo effort (#209) ruled Accessibility field-level
Focused Target capture out of scope and gates on `focused_app` instead, so a record never
names the text field it landed in.

A record can also be **withheld** (#286): an Utterance spoken while **Secure Event Input** was
held at either edge of the hold is recorded with *no transcript bytes at all* — neither
`inserted` nor `raw` — because its words are presumed a secret. What survives is everything
that is not the words: the outcome, the stamp, the App Identity, and the grapheme-cluster
count, which is counted at `record` time (ADR-0006's amendment) precisely so Undo still works
on it. Reveal, Copy and Re-insert have nothing to offer such a record and are disabled.
_Avoid_: history entry, log entry (vague); transcript (that's the Final Transcript, not the receipt); redacted (that's the log's word for a size-only rendering — a withheld record has no text at all)

**App Identity**:
The frontmost application at Insertion time as recorded in an Insertion Record's
`focused_app` hint — bundle id plus display name, read best-effort from `NSWorkspace`. A
hint, not the Focused Target: it names the app, never the text field. Since the Focused
Target gate (ADR-0009 amendment) it is the gate's own reading, taken immediately *before* the
paste rather than after it, so on an Insertion that landed it is proven rather than guessed;
on a refused one it names the app the Utterance was dictated into, never the one that took
focus.

**Recent Insertions View**:
The **text-free, masked projection** of the Recent Insertions ring that rides through the
pure Status Item pipeline (`status_item.project` / `derive` / `present`) for rendering — one
`HistoryEntryView` per entry: `{ char_len, app: AppIdentity, timestamp, outcome, undone,
withheld }`, no
transcript bytes (`undone` marks a record undone by `⌃⌘⌫`, rendered dimmed where a re-insert
redoes it; `withheld` marks one whose text the ring never stored, rendered `not retained` with
no run and no count, and `char_len` stays 0 for it). It is fixed-size and `std.meta.eql`-comparable so the Chrome's
early-out keeps working, and it keeps transcript text out of the projected `Snapshot`
entirely (privacy by construction): the actual `inserted` / `raw` text is fetched from the
authoritative ring on demand only at reveal / copy / re-insert. That rule is why the
Presentation's history rows stay **structural** — `entry` + `revealed` + `hidden`, no label
bytes — and the Status Item Chrome formats each row itself (ADR-0011). Distinct from the Insertion
Record, which is the authoritative, text-bearing entry the ring owns.
_Avoid_: history model, menu record (vague); Insertion Record (that's the text-bearing entry, not this masked view)

**Undo**:
Removing the newest Insertion's text from the Focused Target on the recovery chord `⌃⌘⌫` —
N Backspaces, one per extended grapheme cluster of the Insertion Record's `inserted` bytes,
trailing Insertion space included, so the pre-Insertion state is restored. Gated app-level:
it proceeds only on positive evidence that the frontmost app is unchanged since the
Insertion (bundle id **and** display name both match), fail-closed on either side missing —
the same comparison an Insertion now makes, but the opposite way round on missing evidence,
because Backspaces are destructive where a paste is additive. Only a record whose text
actually reached the cursor is a target: a `failed` or `refused` Insertion is refused, since
deleting its cluster count would eat that much of whatever the user wrote instead.
**Single-shot**: a committed Undo flags its record `undone` and a second chord on that record
refuses rather than eating earlier text; re-inserting it redoes it. Blind and best-effort —
post-Insertion edits can make N over- or under-delete, an accepted limit of the app-level
model. Every outcome shows one HUD cue (ADR-0007): green bloom on a posted deletion, red
bloom + shake on any refusal.
_Avoid_: delete, backspace (those name the mechanism); recovery chord (that names the input,
not the act); revert

**Undo Runner**:
The daemon's one route from the recovery chord to an Undo, and the owner of the whole
sequence — pause/grant gate, newest-record resolution, grapheme count, the fresh
`frontmost()` read, the focus gate, the post, the `undone` flag, the cue. It runs **entirely
on the Insert Worker** (ADR-0008): the gate's read must be fresh and is cross-process, so it
cannot live on the tap's run-loop thread, and everything else therefore sits beside it — the
chord callback only bumps a saturating press counter, one press to one verdict to one cue.
The record is resolved at post time and flagged only *after* a deletion **actually posts**, so
no refusal can dim a record nothing deleted, and every exit — including a degenerate record
with no grapheme clusters — fires its cue rather than swallowing the press. The deletion
mechanism reports how many Backspaces went out and Secure Event Input is probed beside the
frontmost read, so a post of none is a refusal that leaves the record retryable rather than a
green cue over unchanged text, while a burst that stopped partway commits (its Backspaces
already landed, and a retry would eat earlier text) (#244). It gates on its own prerequisites —
not paused, plus the Grant Observer's PostEvent fact — never on the Configuration Phase or the
Supervisor's capture-enable gate. It holds
the Recent Insertions ring concretely (ADR-0006 keeps ownership with the daemon) and reaches
every effect through a six-method seam it is handed, so the whole sequence is exercised by
fed values rather than by a live tap. The gate is re-proved **as the burst runs** (#256): a
verdict is fresh at the instant it is taken but a burst of thousands of Backspaces lasts
seconds, so the deletion goes out in batches of 16 clusters with the same comparison between
them, and a focus change stops the remainder — committing what already landed, as any partway
burst does. Lives in `src/undo.zig`; drained last by the Insert
Worker, which is what serializes a deletion against dictation. Sibling of the Insertion
Runner, which owns the other three cursor paths under the same rule (ADR-0009).
_Avoid_: undo manager, deletion engine, trigger (that named only the discarded run-loop half)

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
the raw Final Transcript. Two distinct bounds apply and neither replaces the other: the
Coordinator's ~3 s **rewrite budget** decides when the *Utterance* stops waiting, and
`openai_rewrite.call_deadline_ms` (5 s) bounds how long one call may occupy the single
**worker** — without it, one endpoint that never answers retires Backtrack until restart.
_Avoid_: edit, fixup, transformation (vague), LLM call (mechanism)

**Focused Target**:
The app and text field that own the cursor at the moment of Insertion.
_Avoid_: active window

**Transcription Session**:
The live connection to the transcription service over which an Utterance's audio streams
out and transcripts stream back (the warm OpenAI Realtime link, `src/session.zig`). It
owns the read-loop dispatch, the outbound-ring sender drain, and the keepalive/reconnect
maintenance — each now a tested surface behind the **Session Transport** seam, so the
whole warm lifecycle is exercised by fed events, not a live socket. Its **deadline** — when
the maintenance thread must cycle the link ahead of the server's cap — is provisional from
the moment `connect` returns, and the `expires_at` the server names in `session.created`
only replaces it after it is *proved* to be a deadline. A value that fails the proof is
ignored, not repaired: the provisional deadline is the degrade, and its cost is at most one
server-forced reconnect. The proof is not defensive politeness — a remote number reaching
unchecked arithmetic is undefined behavior in the ReleaseFast we ship, not a panic.
_Avoid_: websocket (mechanism)

**Session Transport**:
The seam the Transcription Session speaks the wire through: `connect` / `startReadLoop` /
`write` / `writePing` / `writePong` / `writeCloseFrame` / `close`, behind one contract
(`assertTransport`) so `Session(comptime Transport)` is generic over it — the OpenAI twin
of the local backend's Helper seam. The production adapter is `WebsocketTransport` (a thin
wrapper over upstream's `websocket.Client` that also owns the read-loop thread handle); a
`FakeTransport` records writes and drives the read loop synchronously, so `serverMessage`
dispatch, the sender drain, and the pure `maintenanceDecision` are tested off it rather
than against live OpenAI. It carries no policy — the Session decides; the Transport only
moves bytes.
_Avoid_: socket, client (mechanism), connection

**Key Holder**:
The owner of the daemon's *one* plaintext copy of the OpenAI API key (`src/api_key.zig`).
It answers the Configuration Phase's *is a key configured?* fact with the same read that
produces the value the Backend Router connects with, so the two can never disagree, and it
decides when a copy stops existing: exactly one exists at a time, and every copy it
finishes with is zeroed before it is released — `free` alone hands the secret to the next
allocation and to whatever reads that memory later (a crash report, a core dump, a swapped
page). A **hand-off** is the one way a copy legitimately outlives it: a connected
Transcription Session retains its key for the process lifetime, so ownership moves at the
moment `connect` returns and no later refresh can pull it out from under a live holder. Its
`Source` seam is the real env-then-keychain read (config.zig), so the lifetime rule is
driven against counted fake copies rather than against the login keychain. It owns copies in
*memory*; the one durable plaintext copy the daemon ever met — the retired
`~/.config/type-wave/env` file — is the migration's to end (config.zig), and it ends it
rather than telling the user they may.
_Avoid_: key cache, key manager, secret store (that names the keychain item)

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

**Models Layout**:
The single owner of the on-disk path grammar of the models root: `active.receipt` and its
`.tmp` write sibling, `installations/{id}` and the `PROVENANCE` / `MODEL_MANIFEST` files
inside each, the `staging-{id}` and `{id}-repair-{ns}` generation directories and their
`partial.meta`, and the `.operation.lock` / `.runtime.lock` / `.inference.lock` /
`.removal.pending` gate files. Where the Installation Receipt codec owns the *format* of
those bytes, the Models Layout owns *where* they live — pure and allocation-free
(`src/layout.zig`), each accessor writing into a caller buffer and reading no clock or
filesystem, so it is exercised directly by fed values. `Layout.Dir` — the directory-relative
half (`PROVENANCE` / `MODEL_MANIFEST` / `partial.meta`, whatever the directory kind) — is the
one piece shared with the Whisper Helper process, so the file names stay single-homed across
both processes: a rename here cannot silently desync the helper's identity read. model_store
owns every read/write; the Layout owns only the names. Distinct from the Installation Receipt,
which is the record; the Layout is its address.
_Avoid_: paths helper, fs utils (they name a grab-bag, not the single owner)

**Model Operation**:
A user-authorized acquisition, verification, activation, repair, or removal acting on a
Model Installation. An operation may be in progress while the current Model Installation
remains usable. A **removal** publishes its intent (`.removal.pending`) before it takes the
exclusive gates, so selected-local readiness drains before any model bytes disappear — and
because that marker alone makes the installation unreadable to every lease and probe, the
system must converge on it from every interleaving (#276): a marker with no live writer is
**stranded**, proved so by the operation lock every Model Operation takes, and the daemon's
reclaim pass *finishes* the removal it recorded rather than merely discarding the file. A
Model Operation that publishes a receipt retires the marker too — the user's newer answer
wins — which is what makes the Install the Status Item offers actually revive the backend.
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
The microphone audio stream feeding a Transcription Session. It stops on the Talk Key release
edge — and, when that edge is never observed, on the **Capture watchdog**: the Supervisor's
per-tick reading that a hold is open while the key holding it open is physically up
(`CGEventSourceKeyState`, deliberately not anything the tap saw), which feeds the Coordinator
the ordinary `.release` so the Utterance resolves by the usual rules at most one tick late
(#272, ADR-0005 amendment). Hold duration is never a term in that decision: a long dictation
hold is legitimate.
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

**Grant Observer**:
The daemon's one owner of the three macOS TCC grant facts — Microphone, Input Monitoring,
PostEvent — and of the serialized cold-start request ladder that asks for them (#130,
ADR-0010). It wraps a pure `Sequence` (which decides only *when to ask*: one request in
flight at a time, each step advancing on its grant or a 60 s timeout) and adds everything
between that decider and the OS: the six probes behind its seam, the narration, and the two
facts that are **compositions** rather than single reads. Both compositions exist because a
preflight alone lies — Input Monitoring trusts the live Talk Key tap over its stale-after-grant
preflight (#127), and PostEvent latches true on an observed self-tagged post because its
preflight can report `false` for the whole process lifetime (#129). That second fact is what
authorizes an Undo to post destructive Backspaces, which is why it lives behind a seam and is
exercised by fed probe values rather than by a live daemon. Read by the Configuration Phase,
the Supervisor, and the Undo Runner; lives in `src/grants.zig`. Distinct from the Supervisor,
whose own facts the daemon still gathers (ADR-0005).
_Avoid_: permissions manager, TCC helper, grant sequence (that names only the pure half)

**Secure Input Observer**:
The daemon's owner of one session-wide fact: whether **Secure Event Input** is held, and by
whom (#245). While it is held the WindowServer withholds key events from every event tap, so
the recovery chord never reaches the daemon at all — the Undo Runner's own secure-input
refusal covers the case where a press *arrives* and cannot be acted on, and this covers the
strictly upstream case where no press arrives. What makes it worth a module is the asymmetry
it explains: modifier events keep flowing, so the Talk Key keeps working and every other sign
says the tap is healthy while `⌃⌘⌫` is silently dead. Pure, in the Supervisor / Grant Observer
idiom: the daemon polls the flag, the session's holder pid and the holder's name on the
supervisor's existing facts pass, and this decides only *when a reading is worth saying* —
once per hold, again if the holder or its kind changes, once on release. It distinguishes a
**named** holder (quit it) from a **stale** one whose process is gone (only a re-login clears
it) and from an unattributable hold. It observes and narrates; it gates nothing. Lives in
`src/secure_input.zig`; its transitions reach the log with the holder named, and the Status
Item as a row while the condition holds.

It is not the only reading of that flag, and the two must not be confused. This one is
**session-wide and ~3 s old by design**, and answers *what to tell the user about the
condition*. The Coordinator takes its own **fresh, per-Utterance** reading at the press and
release edges (#286), and answers a different question: *is this Utterance's transcript
retained* (see **Insertion Record**'s withheld case). Neither gates dictation.
_Avoid_: secure input guard/gate (it blocks nothing), keyboard lock

**Configuration Phase**:
The daemon's setup-readiness state for the selected Transcription Backend. `configured`
requires the common macOS grants and live Talk Key tap plus that backend's durable
prerequisite: an OpenAI API key or a verified local Model Installation; transient backend
readiness and pause state affect status, but do not define this phase.
_Avoid_: setup state, readiness state, configured flag

**Supervisor**:
The pure per-tick decider of the daemon's self-heal nudges — the Talk Key tap re-arm and
the PostEvent probe (#127/#129) — plus the model-storage reclaim (a superseded Model
Installation, or one an interrupted removal never finished deleting, #276), the
capture-enable gate (the Talk Key press gate: `configured` AND a live backend AND not
paused), and the Capture watchdog (a hold open while its key is up: `hold_open AND
NOT talk_key_down`, #272). Fed a `Facts` snapshot and the Configuration Phase `Outcome`, it returns an
`Actions` bundle the daemon's self-heal loop executes; it reads the Configuration Phase
and sits beside the grant sequence but owns neither — those stay peer machines the daemon
drives. Lives in `src/supervisor.zig`, exercised by fed facts. Pure by choice, not
necessity (ADR-0005): the daemon keeps the impure fact-gathering and runs the effects, so
the async rearm/probe nudges stay visible in the loop.
_Avoid_: manager, controller, self-heal loop (that names the daemon thread, not the decider)

**HUD**:
The transient feedback pill — a 300×22 borderless panel near the bottom of the screen that
shows **no text, ever** (ADR-0002): a scrolling waveform of mic level while an Utterance is
being spoken, three bouncing dots while it resolves, a one-shot amber tint on a degraded
Insertion (ADR-0004), and a single green/red mark for an Undo's confirm or refuse
(ADR-0007). It carries only *in-flight* feedback and never status — that is the Status
Item's job. Off by config or headless, everything falls back to the sound cues. Its
decisions are pure: the `Sequencer` owns the motion (show/hide fades, the bars→dots
crossfade, the pulse and cue envelopes) and the render pump composes one **Frame** per tick
from the published state, both in `src/hud.zig`, driven by a fed clock rather than a live
run loop.
_Avoid_: overlay (that names the on/off setting, not the thing), toast, notification, pill
(fine informally, but the marks are the subject)

**HUD Chrome**:
The seam the HUD paints through: one method, `paint(Frame)`, where a Frame is the complete,
fixed-size, `std.meta.eql`-comparable description of one tick — window op, layer-family
flip, bar heights, dot offsets with the amber blend, or the Undo mark. The production
adapter is `AppKitChrome` (the panel, the CALayers, the `CATransaction` batching, the
CFRunLoopTimer pump, and the headless bail — every ObjC call in the HUD lives there); a
`FakeChrome` records emitted Frames, so the pump's composition rules are asserted as values.
Whether anything is drawn at all is the adapter's business: the daemon leaves the pump
disabled when the Chrome could not be built, which is what makes `isOn` report honestly to
the Feedback Surface. It carries no policy — the Sequencer decides, the pump composes, the
Chrome only draws — and `Hud(Chrome)` asserts the contract itself, unlike the Helper and
Session Transport seams, whose contracts nothing invokes. The **Status Item Chrome** is its
twin one tier up, on the same three-part shape: pure decider, composing pump, drawing-only
adapter.
_Avoid_: renderer, painter (mechanism); view, layer, window (AppKit nouns)

**Feedback Surface**:
The one seam the Utterance Coordinator addresses in lifecycle verbs (`listening`,
`released`, `inserted`, `degraded`, `abandoned`), plus the two Undo cue verbs — and the
single owner of the HUD-vs-sound arbitration: the pill carries start/stop feedback when it
is on, the chimes carry it when it is not, the error cue is *always* audible, and a
resolution takes the pill down whether or not the overlay is enabled. Generic over both
halves it arbitrates (`src/surface.zig`), so the arbitration is exercised against fakes
rather than by running the daemon.
_Avoid_: notifier, feedback manager; HUD (that is one of the two halves, not the arbiter)

**Status Item**:
The daemon's menu-bar presence (icon near the clock): a two-tier icon — normal when
dictation can fire, dimmed when it can't (paused / no key / permission missing) — whose
menu shows the status line and edits every setting live. Recording/processing feedback
stays the HUD's job, never the Status Item's. Its presentation is pure, in three stages
(ADR-0011): the daemon gathers raw readings, `status_item.project` assembles them into a
`Snapshot` (the corrupt override and the Model Operation Runner precedence), `derive` turns
that into the private `Decisions` (headline, `icon_tier`, primary action, allowed Model
Actions), and `present` words those into the **Presentation** — the complete value the menu
renders. The menu (`menu.zig`) is the AppKit adapter behind the Status Item Chrome seam; it
decides no status, and a click routes off the Presentation it last displayed rather than
re-deriving from a fresh read.
_Avoid_: tray icon, menu-bar app (the daemon is one process, not a separate app)

**Presentation**:
The complete, `std.meta.eql`-comparable description of everything the Status Item shows —
the value that crosses the **Status Item Chrome** seam. Per row it carries the *finished
title bytes* (`Row`, a zero-tailed `[512]u8`, so equal titles compare equal and `NSString`
gets its sentinel for free) plus explicit `hidden` / `enabled` / `checked` flags; and
alongside the wording it carries what a click *means* — `primary_action`, `paused`, and each
history row's capture stamp — because routing reads the Presentation that was displayed
(ADR-0011). Assembled by `present(Decisions, SettingsView, RevealSet)`; the one thing it
deliberately omits is Recent Insertions row text, which would put transcript bytes in a
projected value. Distinct from `Decisions`, the private middle stage that answers *what the
state means* before any wording exists.
_Avoid_: view model, render state (vague); Snapshot (that is stage 1, what is true)

**Status Item Chrome**:
The seam the Status Item paints through: one method, `apply(Presentation)`. The production
adapter is `AppKitChrome` (every menu-item handle, every ObjC call, and the `CFRunLoopTimer`
chrome pump that calls back in — the cadence stays with the adapter, exactly as the HUD's
does); a `FakeChrome` records applied Presentations, so every row title is asserted as a
value rather than read out of a running menu. It carries no policy — `present` decides, the
Chrome draws — and `StatusItem(Chrome)` asserts the contract itself, as `Hud(Chrome)` does
and unlike the Helper and Session Transport seams. The pump holds only the last Presentation
applied, which is the whole apply-only-on-change rule: comparing the Presentation rather
than the `Snapshot` it came from means two Snapshots that read identically cost one apply.
The twin of **HUD Chrome**, one tier up: that seam paints in-flight feedback, this one
paints status.
_Avoid_: renderer, painter (mechanism); menu, view, item (AppKit nouns)

**SettingsView**:
The scalar projection of the Settings Snapshot that `present` words the settings-shaped rows
from — which curated option each radio group has selected (null where a hand-edited value
matches no preset, so that group shows no checkmark), the Backtrack and Overlay flags, the
vocabulary term count, and the settings-side backend. It exists because `config.Settings`
holds slices, which no comparable value can carry: reducing them to scalars is what keeps
the Presentation comparable, and therefore what keeps the Chrome's early-out honest. The
radio-group table lives beside it in `status_item.zig` — which option *reads* as selected is
presentation — while `menu.zig` keeps the write path that turns a click into a field.
_Avoid_: settings snapshot (that is the live `Settings` the daemon reads), config view
