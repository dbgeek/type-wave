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
