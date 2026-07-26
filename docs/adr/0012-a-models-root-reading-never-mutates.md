# ADR 0012 — A Models Root Reading never mutates

- Status: accepted (2026-07-26; candidate 1 of the 2026-07-26 architecture review)
- Supersedes: the public `recoveryState` / `activeArtifact` / `activeInstallationIdentity` /
  `updateAvailable` read surface, and the eight-arm `OperationPhase` map in
  `daemon.menuStatus`

## Context

`daemon.menuStatus` is the Status Item's gather. It runs on the **main run loop**, driven by
`menu.zig`'s ~2 s chrome pump — the same run loop the Talk Key tap callback lives on, where
`daemon.zig`'s own module doc warns that "a slow tap callback makes the OS disable the tap."

Every tick it made five `model_store` calls:

```zig
if (model_store.activeArtifact(self.io, root) catch null) |identity| {
    _ = identity;                       // read, then discarded — a bare existence probe
    installation_identity = model_store.activeInstallationIdentity(self.io, root) catch null;
    installation = if (model_store.updateAvailable(self.io, root, ...) catch false) ...
}
const recovery = model_store.recoveryState(self.io, root, ...) catch null;
```

Three of those re-opened and re-parsed the *same* `active.receipt` file, and a fourth
(`activeModelPath`, reached from inside each of them) read it again. The first call's result
was thrown away entirely.

The fifth was not a read at all. `recoveryState`:

1. `createDirPath(root)` — **created** `~/Library/Application Support/type-wave/models`, so
   merely having the menu bar present conjured a models root on a machine that had never
   installed a model;
2. took `.operation.lock` **exclusively**, non-blocking;
3. called `discardStaleStages` → `deleteTree` on staging directories from a superseded
   manifest;
4. called `recoverPartial` → `loadPartial`, which `discardStage`s a partial whose
   `partial.meta` is missing or unparseable.

The daemon believed otherwise. `reclaimModelStorage`'s own doc comment, justifying why the
destructive reclaim jobs share one effect, said they do so:

> rather than sitting on the **read-only** `recoveryState` probe the menu calls.

The instinct was exactly right and the belief about `recoveryState` was wrong. The exclusive
lock did prevent the probe from racing a live Model Operation — there was never a corruption
hazard — but it left three real costs: blocking filesystem work on the tap's run loop every
~2 s, a status read with destructive side effects, and an interface that lied about being one.

Two further facts made the shape wrong rather than merely slow. `recoveryState` can only ever
return **three** of `OperationPhase`'s eight variants (`.idle`, `.paused`, and `.downloading`
on `WouldBlock`); the daemon's eight-arm map therefore carried five unreachable arms, in a
file with no test blocks. And "is the installation live?" was answered three different ways —
`model_store.activeInstallationPresent` (path + manifest match),
`daemon.installationProbe` (removal marker + path, no manifest check), and
`local_backend.usesActiveInstallation` (marker + path + `helper.usesModel`).

## Decision

**A reading of the models root answers questions and changes nothing.**

`model_store.observe(io, root, desired) Reading` — a **Models Root Reading** — replaces the
four public reads with one value assembled from a single `active.receipt` read. It **cannot
fail** and **cannot mutate**: no `mkdir`, no exclusive gate, no `deleteTree`, no `discardStage`.

- **Total, not fallible.** An unreadable root reads as an absent one. This is exactly
  behaviour-preserving: every former caller already swallowed its error into that state
  (`catch null`, `catch false`, `else |_| {}`), six times over. Six catch sites are gone.
- **The artifact path rides along**, as an owned buffer with a `modelPath()` accessor — the
  idiom `daemon.zig`'s `Install` already used. It has to: `activeModelPath` reads and parses
  the receipt itself, so leaving it out would have reintroduced the duplicate read.
- **`Work` is three-valued** — `none` / `paused` / `foreign` — because that is all a reading of
  disk can distinguish. `OperationPhase`'s five unreachable variants and the daemon's five dead
  switch arms are deleted. Every richer phase the Status Item shows comes from the Model
  Operation Runner's live observation of its own child, which `status_item.project` already
  gives precedence to.
- **The foreign-operation probe is shared and non-creating.** `operationInProgress` *opens*
  the lock file — never creates it — and takes a **shared**, non-blocking lock. `FileNotFound`
  means no operation has ever run here. It excludes nothing, so two readings never contend
  with each other and neither can stall a real operation; `WouldBlock` is the whole signal.
- **The destructive half moved to the Supervisor's reclaim pass.** `discardSupersededStages`
  joins `completeStrandedRemoval` and `removeInactiveInstallations` in `reclaimModelStorage`
  — all three destructive, drain-gated, off the run loop, retried next tick when the lock is
  busy. It keeps `completeStrandedRemoval`'s cheap pre-check idiom, so the common case (nothing
  staged) costs one directory scan, no lock churn, and still no models root created.
- **One resumability rule.** `readPartial` decides what counts as resumable and discards
  nothing; `loadPartial` is that plus the discard on null. The menu and a Model Operation
  cannot drift on what a resume point is, because there is one rule.
- **One definition of live.** `Reading.installationLive()` — present and no removal pending —
  is the daemon's. `installationProbe` and `resolveInstall` both use it.
- **`recoveryState` is private**, the operation-internal mutating recover it always was; its
  only caller is `Operation.recover`, which already holds the gate and is entitled to mutate.
  `activeInstallationPresent` is private too.

The public read surface goes from **six functions to two**: `observe` and `activeModelPath`.

Separately, `status_item.Readings` now takes the Local Provisioner's `recovery_state` **raw**,
and `project` derives the corrupt override, `local_runtime_failure`, and
`terminal_backend_failure` from it. Those last two were computed in `menuStatus`, where no
test could reach them; they are now asserted as values, in the pattern ADR-0005 set — pure
decider, impure gathering stays in the daemon.

## Consequences

- **The run loop stops doing filesystem work behind a lock.** One receipt read per chrome
  tick, no gate, no directory mutation.
- **Looking no longer creates.** A machine that never installed a model is not given a models
  root by opening the menu.
- **`menuStatus` goes 78 → 69 lines**: five `model_store` calls become one, the eight-arm map
  becomes three, and two derived predicates leave. The gather block itself roughly halves; the
  function stays long because most of it was never the models root — it is the ring snapshot,
  the masking loop, and the 13-field `Readings` literal. It is still untested, because it is
  still in `daemon.zig`; what left it is now covered.
- **Six new `model_store` tests**, in the file's established `tmpDir` idiom, including two
  that assert the *absence* of an effect: that a reading of an absent root leaves it absent,
  and that a superseded staging directory survives a reading and dies to the reclaim pass.
  Plus two new `status_item` tests for the moved derivations, and one rewritten to feed
  `recovery_state` where it fed `recovery_is_corrupt`.
- **`local_backend.usesActiveInstallation` keeps its own definition.** It additionally needs
  `helper.usesModel(path)` — a question about the warm helper, not about disk — so it was left
  out of scope. Two of the three definitions collapsed, not three.
- **One behavioural change, deliberate.** Stale staging directories are now discarded on the
  Supervisor's ~3 s reclaim pass instead of the menu's ~2 s probe, and only when something is
  actually staged. Nothing else observes them.

## Alternatives considered

- **A read-only variant beside `recoveryState`.** Rejected: the minimal fix and the deepening
  are the same code, and a sixth function would widen the very surface being narrowed.
- **A filesystem seam for `model_store`.** Rejected for now: one production adapter and no
  second implementation is a hypothetical seam, and 36 of the file's 41 tests already run
  against `tmpDir` fixtures that give better fidelity for gate and directory behaviour than a
  fake would. Worth revisiting if a second adapter ever appears.
- **Extracting the reads into their own module**, as `layout.zig` and `receipt.zig` were.
  Rejected: both of those are *pure*, and both cite the rule that model_store owns every
  read/write. A second I/O owner would break it. `observe` shrinks `model_store.zig` by
  replacing four functions rather than by moving them.
- **Keeping `OperationPhase`'s eight variants** for future on-disk states. Rejected: five were
  unreachable, and unreachable arms in an untested function read as though they matter.
- **A non-blocking *exclusive* probe that does no work inside.** Rejected: it still creates the
  models root and the lock file, which is one of the three things being fixed.
- **Dropping the foreign-operation probe** and relying on the Model Operation Runner's
  observation. Rejected: the Runner only sees children it launched, so a `--install-model` run
  from another terminal would go unreported in the Status Item.
