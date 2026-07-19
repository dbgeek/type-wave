# Contributing to type-wave

Thanks for your interest! A few things to set expectations first.

type-wave is an **experimental research project** maintained by one person in
their spare time. It is provided as-is: there is **no support and no SLA**, and
not every contribution will be merged. Public visibility is mainly so you can
read, learn from, and fork the code.

## Bug reports

Bug reports are welcome. Open an issue with the **Bug report** template and
include your macOS version, confirmation that you are on Apple Silicon, which
transcription backend you were using (OpenAI or local Whisper), and a relevant
excerpt from `~/Library/Logs/type-wave.log`.

## Pull requests

- **Small, focused fixes** (typos, docs, clear bugs) are welcome — just open a PR.
- **Larger changes** — open an issue to discuss first. Unsolicited large PRs may
  not be merged, and it is kinder to learn that before you invest the time.
- Keep each PR to a single concern.

## Commit and PR conventions

Releases are automated from commit history, so the **PR title matters**.

- **We merge squash-only.** Each PR lands on `main` as exactly one commit whose
  subject is the **PR title** — so your branch commits can be as messy as you
  like, but the title must be right. (Merge-commit and rebase merges are off.)
- **The PR title must be a [Conventional Commit](https://www.conventionalcommits.org/):**
  `<type>[optional scope]: <description>` — e.g. `feat: add local backend picker`
  or `fix(hud): stop capsule flicker on handover`. A CI check (`PR title lint`)
  blocks the merge if it isn't.
- **Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
  `build`, `ci`, `chore`, `revert`. Only `feat` and `fix` produce a release;
  `feat` → new features, `fix` → bug fixes. **Scope is optional** — add one when
  it helps (`feat(backends): …`), skip it otherwise.
- **Breaking changes:** put a `!` after the type — `feat!:` or `refactor!:`.
  While we are pre-1.0 a breaking change bumps the **minor** version (`0.3.x →
  0.4.0`); ordinary `feat`/`fix` bump the **patch**.

## Working on the code

type-wave is a Zig daemon for Apple Silicon macOS. See the
[README](./README.md) for full setup; the short version is:

```sh
nix develop --command zig build
nix develop --command zig build test
```

Before changing anything non-trivial, please read:

- [CONTEXT.md](./CONTEXT.md) — the project's ubiquitous language. PRs are
  expected to use this vocabulary in names and comments.
- [docs/adr](./docs/adr) — architecture decisions and their rationale.

Match the style and comment density of the surrounding code.

## Conduct

Be kind and assume good faith. This project follows a
[Code of Conduct](./CODE_OF_CONDUCT.md).
