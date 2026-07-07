# Issue tracker

This repo uses **GitHub Issues** on `dbgeek/type-wave`, operated via the `gh` CLI.

## Wayfinding operations

- **The map** is the issue labelled `wayfinder:map` (currently [#1](https://github.com/dbgeek/type-wave/issues/1)). Find it with:

  ```sh
  gh issue list --label "wayfinder:map" --state open
  ```

- **Tickets** are issues carrying one `wayfinder:<type>` label (`research`, `prototype`, `grilling`, `task`) and a `_Part of map #1_` line in the body. The issue title is the ticket's **name** — refer to tickets by name (linking the issue), never by bare number.
- **Claiming**: add the `wayfinder:claimed` label *before* doing any work:

  ```sh
  gh issue edit <n> --add-label "wayfinder:claimed"
  ```

- **Blocking**: a blocked ticket carries a `**Blocked by:** #a, #b` line at the top of its body. A ticket is **unblocked** when every issue listed there is closed. (Plain-body convention — no Projects dependency graph.)
- **Frontier query** (open + unclaimed; then discard hits whose `Blocked by:` issues aren't all closed):

  ```sh
  gh issue list --state open \
    --label "wayfinder:research" --label "wayfinder:prototype" \
    --label "wayfinder:grilling" --label "wayfinder:task" \
    --json number,title,labels,body \
    --jq '.[] | select([.labels[].name] | index("wayfinder:claimed") | not)'
  ```

  (`gh issue list` with multiple `--label` flags ORs the wayfinder type labels.)
- **Closing / resolution**: post the answer as a comment, close the issue, then edit the map's *Decisions so far* section to append one line: `- [<ticket title>](<issue url>) — <one-line gist>`.

  ```sh
  gh issue comment <n> --body-file <resolution.md>
  gh issue close <n>
  gh issue view 1 --json body   # then gh issue edit 1 --body-file <updated-map.md>
  ```

- **New tickets**: create with `gh issue create --label "wayfinder:<type>"` including the `_Part of map #1_` footer, then wire `Blocked by:` lines in a second pass once numbers exist.
- **Assets** produced while resolving a ticket live in the repo (research notes in `docs/research/`, prototypes in `prototypes/`) and are linked from the issue, not pasted into it.
