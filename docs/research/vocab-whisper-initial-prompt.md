# Research: whisper.cpp `initial_prompt` semantics and token budget

Ticket: [#162](https://github.com/dbgeek/type-wave/issues/162). Investigates how
`whisper_full_params.initial_prompt` biases transcription, its token budget,
overflow behaviour, and its usefulness for biasing proper-noun / code-identifier
spellings — with a view to feeding a user vocabulary/glossary into the local
whisper.cpp backend.

Primary source: the whisper.cpp **v1.9.1** source that this repo pins and links
(`build.zig` acquires `whisper-cpp-v1.9.1`; header/source read from the Zig cache
copy `.zig-cache/.../whisper-cpp-v1.9.1/source/{include/whisper.h,src/whisper.cpp}`).
Line numbers below are from that vendored v1.9.1 checkout. Note that v1.9.1
refactored the prompt path (`prompt_past0` / `prompt_past1`, `carry_initial_prompt`)
relative to the older single-`prompt_past` code most blog posts describe — the
budget math and truncation semantics are unchanged, but the details below are
verified against the version we actually link.

## Bottom line for the spec

- **Token budget: 224 tokens** (`whisper_n_text_ctx(ctx)/2` = 448/2). In the
  default (non-carry) path an extra slot is spent on the `<|startofprev|>` marker,
  so the effective usable count is **223 prompt tokens** per decode window.
- **These are whisper BPE tokens, not words or characters** — 223 tokens is
  roughly 120–180 English words, and *fewer* for unusual proper nouns / code
  identifiers, which fragment into many sub-word tokens. Budget for far fewer
  than 223 "terms".
- **Overflow = silent tail truncation.** The tokens are stored, then only the
  **last** `min(223, n)` are used; earlier tokens are dropped with *no* warning
  in the default path (a `WHISPER_LOG_WARN` only fires on the
  `carry_initial_prompt` branch, which type-wave will not use). No error, no
  degraded output — just a shorter effective prompt.
- **Recommended truncation policy:** pre-flight the prompt with
  `whisper_token_count(ctx, text)` (returns the positive token count) and cap it
  to **≤ ~200 tokens** (leave headroom below 223). If a user glossary exceeds the
  budget, truncate from the **front** and keep the **tail**, and place the
  highest-value / most-recently-relevant terms **last** — both because the model
  keeps the tail on overflow and because late tokens carry more attention weight.
- **For type-wave specifically:** set `params.initial_prompt` in
  `parameters()` (`src/whisper_bridge.cpp:61`). Leave `carry_initial_prompt`
  at its default `false`. Because type-wave runs `single_segment = true` on short
  utterances there is exactly one decode window, so the prompt is applied in full
  to the only segment — the classic "prompt only conditions the first 30 s"
  limitation does not bite us.

## How `initial_prompt` is fed to the decoder

1. **Tokenization.** In `whisper_full_with_state`, if `prompt_tokens` is null and
   `initial_prompt` is set, the string is tokenized with `whisper_tokenize`
   (`src/whisper.cpp:6934-6943`). A 1024-token scratch buffer is used and grown
   if the text needs more (`n_needed < 0` → resize → retry, lines 6935-6940), so
   tokenization itself never truncates. `whisper_tokenize` is a plain BPE encode
   over the model vocab (`src/whisper.cpp:3971`, calling `tokenize(ctx->vocab, …)`)
   — the *same* vocabulary the model emits — and adds **no** special tokens.

2. **Where the tokens go.** With the default `carry_initial_prompt = false`, the
   prompt tokens are pushed into the **dynamic** rolling context `prompt_past1`
   (`src/whisper.cpp:6958-6962`). (`no_context` clears `prompt_past0`/`prompt_past1`
   *first*, at 6920-6923, so the prompt survives; see below.)

3. **Prompt assembly per decode window** (`src/whisper.cpp:7113-7132`). For each
   window the decoder input is built as:

   ```
   [ <|startofprev|> ]  (prompt_past0 if carry)  (tail of prompt_past1, budget-limited)
   [ <|startoftranscript|> ] [ <|lang|> ] [ <|transcribe|> ] ( [ <|notimestamps|> ] )
   ```

   i.e. the initial-prompt tokens are literally **prepended to the decoder
   context**, sitting after the `<|startofprev|>` (`whisper_token_prev`) marker and
   before the start-of-transcript / language / task tokens (`prompt_init`,
   assembled at ~6980-6999). This whole `prompt` vector is fed through
   `whisper_decode_internal` (7164), so the prompt is real KV-cache context that
   conditions every generated token. This is standard OpenAI-Whisper prompting:
   text after `<|startofprev|>` biases the transcript that follows.

4. **Budget & truncation** (`src/whisper.cpp:6927`, `7127`). The cap is
   `max_prompt_ctx = min(params.n_max_text_ctx, whisper_n_text_ctx(ctx)/2)`.
   Default `n_max_text_ctx = 16384` (`src/whisper.cpp:5934`), so the effective cap
   is `whisper_n_text_ctx(ctx)/2`. `n_text_ctx` for all standard models is **448**
   (`src/whisper.cpp:596`, an hparam read from the model), giving **224**. When the
   window is assembled, the dynamic take is
   `n_take1 = min(max_prompt_ctx - n_take0 - 1, prompt_past1.size())` with
   `n_take0 = 0` in the non-carry path, i.e. `min(223, size)`, and it copies the
   **last** `n_take1` tokens (`prompt_past1.end() - n_take1 … end()`, line 7128).
   So overflow silently keeps the **tail** of the prompt. The header comment
   confirms the contract: "*maximum of whisper_n_text_ctx()/2 tokens are used
   (typically 224)*" (`include/whisper.h:526`).

5. **Only used at low temperature.** The prompt is applied only while
   `t_cur < WHISPER_HISTORY_CONDITIONING_TEMP_CUTOFF` (0.5f)
   (`src/whisper.cpp:145`, guard at `7111`). type-wave decodes greedily starting at
   `temperature = 0.0` (default), so the prompt is applied on the primary pass. Be
   aware: if a decode fails and whisper falls back up the temperature ladder
   (`temperature_inc = 0.2`), once `t_cur >= 0.5` the conditioning prompt is
   **dropped** for that retry. A minor edge case, not a blocker.

## Interaction with the params type-wave already sets

Current params (`src/whisper_bridge.cpp:61-76`): `whisper_full_default_params`,
`language`, `no_context = true`, `single_segment = true`, `no_timestamps = true`,
greedy `best_of = 1`.

- **`no_context = true`** — clears `prompt_past0`/`prompt_past1` at the top of
  `whisper_full_with_state` (`src/whisper.cpp:6920-6923`), which only wipes
  carryover from a *previous* `whisper_full` call. The `initial_prompt` is
  tokenized and injected **after** that clear (6929+), so **`no_context` does not
  disable `initial_prompt`** — it just guarantees each call starts from your
  prompt and nothing else. This is exactly what we want for per-utterance
  dictation.

- **`single_segment = true`** — forces one output segment and does not touch the
  prompt mechanism. It suppresses the mid-audio segment split (`!params.single_segment`
  guard at ~7645) and, combined with type-wave's short (< 30 s) utterances, means
  there is a single decode window: the prompt conditions the *entire* transcription.
  Multi-window audio would only see the prompt on the first 30 s window unless
  `carry_initial_prompt = true` — not our case.

- **`carry_initial_prompt`** (default `false`, `src/whisper.cpp:5962`) — when true,
  the prompt is pinned in the static `prompt_past0` slot and re-prepended to
  *every* window (`7112-7123`), at the cost of budget for rolling context. Only
  relevant for long multi-window audio; leave it `false`.

## Biasing strength for proper nouns / code identifiers — and limits

`initial_prompt` is a **soft** bias (it shifts decoder priors), not a hard
constraint or a decode-time lexicon. Findings, cross-checked against OpenAI's own
cookbook and community reports:

- It **does** reliably nudge *preferred spellings / casing* of names the model
  already "knows" phonetically — the canonical use is passing a comma-separated
  glossary of product/company/person names so Whisper emits the official spelling
  (OpenAI cookbook, "Addressing transcription misspellings: prompt vs
  post-processing").
- It is **weakest** exactly where we'd want it most: genuinely novel tokens —
  rare jargon, invented product names, and code identifiers like `snake_case` /
  `camelCase` / symbols — often still come out wrong, because the prompt only
  reweights; it cannot force output of a token sequence the acoustic model does
  not support. The cookbook notes prompting "often fails to resolve proper noun or
  jargon errors," recommending post-processing (a correction pass) for high
  reliability.
- **Not instruction-following.** Whisper is not an LLM; directives like "capitalize
  all proper nouns" or "use British spelling" are largely ignored. Bias comes from
  the *presence of the target words themselves* in the prompt, not from commands
  about them.
- **Late tokens dominate.** Attention weights later prompt tokens more heavily, so
  a long list dilutes early entries. Keep the prompt compact and put the
  highest-value terms near the end (community + arXiv "rare-word recognition"
  reports).

### Glossary/word-list vs natural-sentence framing

Reported experience is split and use-case-dependent; there is no whisper.cpp code
difference — both are just token streams:

- **Glossary / comma-separated list** (e.g. `"type-wave, whisper.cpp, Zig, CoreAudio"`)
  is the widely recommended pattern *for pure spelling/vocabulary biasing of proper
  nouns*, and is what the OpenAI misspelling cookbook uses. It packs the most target
  terms per token, which matters against the 223-token budget.
- **Natural-sentence framing** (embedding the terms in a plausible sentence)
  additionally conditions register, grammar, and punctuation/casing, and can
  disambiguate homophones by context — the remskill/ailia prompting guides argue
  sentences beat bare lists because Whisper "understands context and grammar."
- **Recommendation for type-wave:** for a user-supplied vocabulary of names /
  identifiers, use a **compact comma-separated glossary** (maximises terms per
  token, directly targets spelling). If the goal also includes tone/formatting,
  wrap the terms in one short natural sentence. Either way, cap to the budget and
  keep the most important terms last. Treat the feature as best-effort: pair it
  with post-processing if exact identifier spelling must be guaranteed.

## Actionable API notes for implementation

- `whisper_token_count(ctx, text)` (`src/whisper.cpp:3986`) returns the positive
  BPE token count for a string (it calls `whisper_tokenize(…, NULL, 0)` and negates
  the result) — safe to use for pre-flight budgeting without allocating.
- Set `params.initial_prompt = <c-string>` in `parameters()`; the string must
  outlive the `whisper_full` call (whisper.cpp tokenizes it internally, no copy of
  the char buffer is retained past that call, but it is read during it).
- Leave `prompt_tokens` / `prompt_n_tokens` null (they are the pre-tokenized
  alternative to `initial_prompt`); if we ever want to enforce our own truncation
  policy exactly, tokenize ourselves and pass `prompt_tokens` instead.

## Sources

Primary (vendored whisper.cpp v1.9.1, this repo):

- `include/whisper.h:485-530` — `whisper_full_params` struct, `n_max_text_ctx`,
  `initial_prompt`, `carry_initial_prompt`, `prompt_tokens`; budget comment at :526.
- `src/whisper.cpp:6920-6962` — `no_context` clear, initial-prompt tokenization,
  routing into `prompt_past0`/`prompt_past1`.
- `src/whisper.cpp:6927` — `max_prompt_ctx = min(n_max_text_ctx, n_text_ctx/2)`.
- `src/whisper.cpp:7111-7132` — per-window prompt assembly, `<|startofprev|>` marker,
  tail truncation (`n_take1 = min(max_prompt_ctx-1, size)`).
- `src/whisper.cpp:596`, `4195-4196` — `n_text_ctx = 448` (→ budget 224).
- `src/whisper.cpp:5929-5990` — default params (`n_max_text_ctx=16384`,
  `carry_initial_prompt=false`, `temperature=0.0`, `temperature_inc=0.2`).
- `src/whisper.cpp:3971-3990` — `whisper_tokenize` / `whisper_token_count`.
- `src/whisper.cpp:145`, `7111` — `WHISPER_HISTORY_CONDITIONING_TEMP_CUTOFF = 0.5`.
- `src/whisper_bridge.cpp:61-76` — type-wave's current `parameters()`.

Secondary (corroboration on the 224-token limit, tail truncation, and
glossary-vs-sentence bias):

- OpenAI cookbook — Whisper prompting guide: <https://cookbook.openai.com/examples/whisper_prompting_guide>
- OpenAI cookbook — Addressing transcription misspellings (prompt vs post-processing): <https://cookbook.openai.com/examples/whisper_correct_misspelling>
- openai/whisper Discussion #1824 — prompt length 224 tokens (not characters): <https://github.com/openai/whisper/discussions/1824>
- ggml-org/whisper.cpp Issue #1979 — hotwords / biasing transcription: <https://github.com/ggml-org/whisper.cpp/issues/1979>
- arXiv 2502.11572 — Improving rare-word recognition of Whisper (late-token weighting, prompt limits): <https://arxiv.org/html/2502.11572v1>
