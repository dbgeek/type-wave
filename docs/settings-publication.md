# Settings Snapshot Publication

Menu edits and file reloads share `src/settings_publication.zig`. This completes the
settings write work deferred by ADR-0011. The Status Item still owns presentation;
its AppKit adapter collects intent and displays the publication outcome.

## Interface and ownership

An edit supplies a field and its typed value. Publication owns clamping, retained copies,
serialization, change detection, snapshot publication, daemon effects, and persistence.
A reload reads the canonical file itself. Callers do not supply serialized text, change
flags, or independently assembled snapshots.

All operations run on the main thread. Accepted snapshots retain their storage for the
process lifetime, as before; a Session holding an older snapshot remains valid. Store
publishes the log-redaction policy before the new pointer. Other daemon effects follow
publication and therefore see the accepted snapshot.

## Outcomes

| Operation | Live snapshot and effects | Disk |
| --- | --- | --- |
| Changed edit | Prepare, publish, then dispatch changed effects | Attempt persistence last |
| Same-value Save | Keep pointer; no effects | Retry persistence |
| Preparation failure | No publication or effects | No write |
| Persistence failure | Accepted edit remains live | Existing file preserved |
| Valid changed reload | Replace live settings and dispatch changed effects | No write |
| Unchanged reload | Keep pointer; no effects | No write |
| Missing, unreadable or malformed reload | Keep live settings | No write |

A valid file wins over unsaved live edits on the next reload. A valid empty settings
value (`.{}`) intentionally resets settings to defaults. Startup separately retains its
existing defaults-on-failure behavior.

Menu edits derive from the current live snapshot. Persistence reads the file afresh and
patches only the edited field, so unrelated hand edits stay on disk until the next reload.
An existing malformed or unpatchable file is never replaced by a complete serialization.
A multiline Vocabulary value can therefore require a manual file edit. A complete file is
created when absent. Successful writes use a temporary sibling and rename.

Explicit edit failures show “Couldn't apply settings” or “Applied, but couldn't save.”
Failed reloads log their reason without interrupting menu-open with an alert.

## Verification

Tests cross the publication interface with real temporary files and a recording daemon
effect adapter. They cover publication/effect/write ordering, allocation failures, failed
persistence and retries, reload authority, hand-edit preservation, retained borrowed data,
and each radio choice through publication, disk and read-back. The pure diff and parser
tests remain useful; the old isolated radio serialization tests are replaced by that
end-to-end route. AppKit alert presentation still requires a manual display check.
