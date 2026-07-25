# ADR 0011 — The Presentation is complete, and a click routes off the displayed one

- Status: accepted (2026-07-25; candidate 1 of the 2026-07-25 architecture review)

## Context

`status_item.zig` was already a pure pipeline with 38 test blocks: `project` assembled a
`Snapshot` from the daemon's readings, `derive` turned it into a `Presentation`, and CONTEXT.md
said of the menu that "it decides no status."

It decided thirteen things. `refreshChrome` (`menu.zig`, 116 lines) and its neighbours held:

1. `statusText` re-splitting the headline on the raw `selected_backend` — three of nine arms —
   after `derive` had deliberately collapsed OpenAI and Local into one `Headline`.
2. `setHidden:` / `setEnabled:` computed from `primary_action` at the call site, because
   `Presentation` had no `hidden` or `enabled` field.
3. The byte-progress rule hand-rolled from the raw `Snapshot` — while
   `status_item.Operation.reportsByteProgress` existed, encoding exactly that rule, and `derive`
   never consulted it. Only `model_operation.zig` used it.
4. A four-arm switch over `snapshot.installation` for the Model Installation row's title.
5. `@tagName(snapshot.operation)` as user-visible copy.
6. The failure remedy decided twice — a `recovery` switch beside a parallel five-arm fallback
   switch over the same `model_failure`.
7. The identity- and Secure-Input-row visibility from raw `Snapshot` axes.
8. The empty Recent Insertions state: title, enablement, and detaching the submenu.
9. `backtrackLine2` and `vocabularyTitle` deriving state-dependent wording straight from
   `config.Settings` — a second status-derivation path that bypassed `project` / `derive`
   entirely.
10. The radio checkmarks (`currentOption` / `syncGroup`), likewise outside the pipeline.
11. `onPrimary:` re-running `derive` on a **fresh** `Host.status` read and re-switching the same
    enum the display had already decided — a second mapping, and a time-of-check/time-of-use
    gap: the action fired could differ from the one on the label the user clicked.
12. `onPause:` calling `Host.status` — four `model_store` filesystem reads plus a ring snapshot,
    on the main thread — to read one bool.
13. Four byte-identical `status_item.derive(...).history` re-derivations to turn a clicked row
    index back into a capture stamp.

Roughly 1370 of `menu.zig`'s 1602 lines were unreachable from `zig build test`: no test
constructs a `Menu`, nothing sets `g_menu`, no fake `Host` exists, and `init` bails when
`mainScreen()` is null, so `refreshChrome` cannot even run headlessly. Every one of the
thirteen lived there.

The repo had already solved this shape once. Commit `864023b` lifted the **HUD Chrome** seam:
one method `paint(Frame)`, a `Frame` that is the complete, fixed-size, `std.meta.eql`-comparable
description of one tick, `assertChrome` invoked by `Hud(Chrome)` itself, and a `FakeChrome` that
records emitted Frames — and the render pump became testable. The Status Item is the same shape
with the same problem.

## Decision

**Two rules, and the first is what makes the second possible.**

### 1. The Presentation is complete; the Chrome decides nothing

`status_item.zig` becomes three stages instead of two:

```
project(Readings)                                   -> Snapshot
derive(Snapshot)                                    -> Decisions      (private)
present(Decisions, SettingsView, RevealSet, *out)   -> Presentation   (complete)
```

`Presentation` carries, per row, the **finished title bytes** plus explicit `hidden` /
`enabled` / `checked` flags. `AppKitChrome.apply(Presentation)` is a straight run of
`setTitle:` / `setHidden:` / `setEnabled:` / `setState:` with no branch of its own.

- The old `Presentation` is renamed `Decisions` and **loses its `pub`**. Its 33 tests keep
  their call sites — Zig tests reach same-file declarations — and the module's interface
  narrows by one type while its implementation absorbs a stage. That narrowing *is* the
  decision, stated in the type system.
- `Row` holds `[512]u8` with a **total zero tail**: every byte past `len` is 0, so equal titles
  compare equal under `std.meta.eql` and `title()` hands `NSString` its sentinel without a
  copy. `present` fills an out-param rather than returning by value.
- `StatusItem(Chrome)` is the pump, holding only `last`. The **cadence stays with the adapter**
  — a `CFRunLoopTimer` is main-thread by necessity — exactly as `AppKitChrome` owns the HUD's.
  `assertChrome` is invoked by the generic type itself.
- The early-out compares the **Presentation**, not the `Snapshot`. This is strictly better: the
  ring's history array is fixed-size, so two Snapshots differing only in stale slots past
  `history_count` used to force a redundant apply and no longer do.

Two inputs join the Snapshot, and both are forced rather than chosen:

- **`SettingsView`** — a scalar projection of the live Settings Snapshot. `config.Settings`
  holds slices (`model`, `language`, `delay`, `vocabulary`), which no `std.meta.eql`-comparable
  value can carry. Reducing them to "which curated option is selected" and "how many terms" is
  what keeps the Presentation comparable, and therefore what keeps the early-out honest. The
  radio-group table moves to `status_item.zig` with it, because which option reads as selected
  is presentation; `menu.zig` keeps the write path and reads `field` / `zon` from there.
- **`RevealSet`** — the type moves to `status_item.zig` because `status_item` does not import
  `menu`, and a typed parameter needs the type on the callee's side. The **instance** stays with
  the adapter as menu-session state. The adapter holding state while deciding nothing is the
  same split as `AppKitChrome` holding CALayers.

One thing the Presentation deliberately does **not** carry: Recent Insertions row text. A
history row is structural — `entry` + `revealed` + `hidden` — and the adapter formats it with
the already-tested `historyLabel` / `historyRevealedLabel`, fetching the `inserted` bytes on
demand from the authoritative ring. Putting them in the value would break the rule the
`Snapshot` already follows: transcript bytes never ride a projected value.

### 2. A click routes off the Presentation that was displayed

`onPause:`, `onPrimary:`, and the three Recent Insertions callbacks read `pump.displayed()` —
the value last applied — instead of pulling a fresh `Host.status` and re-deriving.

The Presentation therefore carries the routing identity alongside the wording: `primary_action`,
`paused`, and each history row's `entry.timestamp`. A click before the first apply is a no-op.

This is a real trade, and it is the reason this half is recorded rather than left implicit:
**intent can be up to ~2 s stale**, bounded by the pump tick (and `menuWillOpen:` applies
unconditionally). We accept that because the alternative is worse in both directions — it fires
an action the label never offered, and it pays four filesystem reads to answer a question the
displayed value already answered. What the user clicked is what they saw.

## Consequences

- `refreshChrome`, `rebuildHistory`, `syncGroup`, `syncBacktrack`, `syncVocabulary` and the
  overlay/backtrack state pokes collapse into one `apply`. All five decision sites 9–13 are
  deleted, along with both gratuitous status pulls and the four duplicated re-derivations.
- Every title the menu used to build where no test could reach it is now pinned as an exact
  string in `FakeChrome` tests — including the identity rows, the operation and failure lines,
  the byte-progress suffix, and every headline arm.
- `currentOption`'s slice comparison becomes tested, `gi == 2` (the single curated `model`
  option, matched by string rather than index) included.
- `menu.zig` sheds the `readiness`, `secure_input`, `transcription_backend`, `tap` and `insert`
  imports, and the dead `menu.Status` / `menu.Health` re-exports go with them.
- A settings write re-applies from the cached `Snapshot` rather than re-reading it: a menu write
  cannot move a daemon-side axis, so this preserves the pre-existing cost profile, where the
  per-callback sync helpers never touched `Host.status`. As before, anything that *follows* from
  a backend switch on the daemon side (the `openai_only` groups' visibility) lands on the next
  pump tick rather than instantly.
- The Recent Insertions rows are rebuilt on every apply rather than only on menu-open and
  reveal. Passage of time alone cannot trigger one — the Presentation carries no clock, which is
  the point — so this only costs the 20 label formats (and a ring read per *revealed* row) when
  something else already changed. In exchange the relative times are fresh whenever anything
  moved, not only when the menu was opened.
- The `Model Operation — {tag}` row still shows `@tagName`. This ADR moved the decision without
  rewording it; the port was verified against the old lines byte-for-byte, so rewording was
  explicitly out of scope. It is now a one-line change in a tested function rather than a string
  buried in ObjC.
- `AppKitChrome` remains unreachable from tests — it is the ObjC half, and that is the point.
  What a test now covers is that a Presentation reaching it is complete and correct; what no
  test covers is that each `setTitle:` lands on the right item handle. A swapped handle would
  pass every test, which is why the port carried a manual pass over the reachable states.

## Alternatives considered

- **Widen `derive` to return the complete value (two stages).** Rejected: headline priority,
  icon tier, `model_actions` and `model_failure` precedence are four genuinely separable
  decisions, and folding them into layout would make 33 tests assert wording to reach them.
- **No title bytes; the adapter calls out-buffer formatters per row** (the Models Layout idiom).
  Rejected: the adapter would choose *which* formatter, which is a decision, and there would be
  no whole-value comparison for the early-out. History rows are the one place this idiom is
  right, and there it is required by the privacy rule.
- **Fully inline, history text included, one value.** Rejected: 20 × 1024 bytes of revealed
  snippets inside a projected value, which is exactly the invariant CONTEXT.md calls privacy by
  construction.
- **A stateless `present` with the menu holding `last`.** Rejected: the apply-only-on-change
  rule would stay in the adapter where no test reaches it.
- **The settings *write* path.** Deliberately out of scope. `commitSettings` calls
  `host.selectBackend` unconditionally, `setOverlay` sits outside it, and `onMenuWillOpen:`
  bypasses it with its own `create` + `swap` — five distinct snapshot-build sites with
  asymmetric fan-out. That is a separate defect about writing, not about reflection, and folding
  it in would have roughly doubled the change.
