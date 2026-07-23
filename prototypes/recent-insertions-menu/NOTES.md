# Prototype — Recent Insertions menu presentation

Throwaway UI mockup for wayfinder map **#182**, ticket **#186** (_Menu presentation of Recent Insertions_).

**Question:** how does the in-memory Recent Insertions ring (N=20, newest-first) present under the Status Item menu — layout, masked-entry label, reveal affordance, per-entry actions, and how the ring data reaches the menu given the pure `project`/`derive` split?

`menu-presentation.html` is a self-contained interactive mockup of the macOS menu-bar dropdown, rendering three layout variants with the masked→reveal interaction and the `.failed` marker live. Open it in a browser, or view the published artifact:

- Artifact: https://claude.ai/code/artifact/1bd95d00-bf1f-4a70-a380-91c7ced3342d

## Verdict (reaction, 2026-07-23)

- **Layout:** Variant 1 — *Entry ▸ actions*. Strictly newest-first; each entry is a submenu carrying **Copy** + **Re-insert here**. No failed-first sectioning (chronological order kept); failed/degraded shown per-entry via status dot + tag.
- **Reveal:** **⌥-click the entry row** toggles that one entry's text inline (deliberate, per-entry). Text is not shown at rest.
- **Pure-split fit:** ring rides **through `status_item.Snapshot` → `project`/`derive` → `Presentation.history`**; `menu.zig` stays a dumb adapter — but as *masked descriptors only* (no transcript bytes in the Snapshot). See the #186 resolution comment for the full contract.

This is throwaway. The validated decision lives on issue #186; only that decision graduates to the hand-off spec.
