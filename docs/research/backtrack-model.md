# Backtrack rewrite: OpenAI model & API surface (latency-first)

Research for [wayfinder ticket #137](https://github.com/dbgeek/type-wave/issues/137),
part of map [#136](https://github.com/dbgeek/type-wave/issues/136). Researched 2026-07-20.

## Recommendation (TL;DR)

**`gpt-5.4-mini` via the Responses API, `reasoning: { effort: "none" }`, non-streaming,
standard service tier.**

- **Added latency for a ~50-token rewrite: ~0.9–1.0 s p50; budget 2.5 s as the hard
  timeout** (p95 estimated ~1.8–2.5 s — no published percentile data; see §5), after which
  the raw Final Transcript is inserted unchanged.
- `gpt-5.4-nano` is measurably no faster (same ~0.64 s TTFT, ~174 vs ~182 t/s) and only
  ~$0.0001/utterance cheaper; mini buys instruction-following headroom (relevant for the
  map's mixed Swedish/English concern) and is eligible for the 2× **priority** service
  tier as a tail-latency escape hatch, which nano is not. The prototype ticket can A/B
  nano as a cost fallback, but latency is not the differentiator.
- **One-pass cleanup inside the existing transcription session is not possible**: the
  `prompt` field is not supported with `gpt-realtime-whisper` at all, and on the models
  that do accept it, it is a vocabulary/style biasing hint, not an instruction channel
  (§6). A separate rewrite call is the only reliable path.

## 1. Current small/fast model lineup (July 2026)

The gpt-4.1-nano/mini and gpt-5-nano/mini generations named in the ticket have been
superseded and no longer appear on the [pricing page](https://developers.openai.com/api/docs/pricing).
The current lineup relevant to a ~50-token rewrite:

| Model | Input /1M | Cached /1M | Output /1M | Notes |
|---|---|---|---|---|
| `gpt-5.4-nano` | $0.20 | $0.02 | $1.25 | Smallest/cheapest; "speed and cost matter most" tier |
| `gpt-5.4-mini` | $0.75 | $0.075 | $4.50 | Priority tier eligible |
| `gpt-5.6-luna` | $1.00 | $0.10 | $6.00 | Newest small model; no latency benefit found to justify 5× nano input price |
| `gpt-5.4` | $2.50 | $0.25 | $15.00 | Overkill for this task |

Snapshots: `gpt-5.4-nano-2026-03-17` (default `gpt-5.4-nano`); 400k context, 128k max
output, knowledge cutoff 2025-08-31. Reasoning effort options: `none, low, medium, high,
xhigh` ([model page](https://developers.openai.com/api/docs/models/gpt-5.4-nano)).

**Reasoning effort is the dominant latency knob.** These are reasoning models by default;
`effort: "none"` must be set explicitly or TTFT balloons (4.12 s median at xhigh vs
0.64 s non-reasoning, per Artificial Analysis).

## 2. Measured latency (Artificial Analysis, median over trailing 72 h, OpenAI provider)

| Model (non-reasoning mode) | TTFT p50 | Output speed | Source |
|---|---|---|---|
| `gpt-5.4-nano` | 0.64 s | 174.1 t/s | [AA nano (non-reasoning)](https://artificialanalysis.ai/models/gpt-5-4-nano-non-reasoning/providers) |
| `gpt-5.4-mini` | 0.64 s | 181.6 t/s | [AA mini (non-reasoning)](https://artificialanalysis.ai/models/gpt-5-4-mini-non-reasoning) |
| `gpt-5.4-nano` (xhigh, for contrast) | 4.12 s | 171.2 t/s | [AA nano (xhigh)](https://artificialanalysis.ai/models/gpt-5-4-nano) |

Mini and nano are latency-identical within measurement noise; the choice between them is
about quality headroom and priority-tier eligibility, not speed. AA publishes p50 only;
no vendor or third-party p95 figures were found. A [community thread](https://community.openai.com/t/gpt-5-4-nano-priority-service-tier-inconsistent-latency/1377270)
on gpt-5.4-nano reports "every 20th response taking over 1 s" (i.e. rough p95 TTFT > 1 s)
— and documents that nano requests sent with `service_tier: "priority"` were silently
processed as `default`; by late March 2026 `gpt-5.4-mini` gained working priority support
with "seemingly decent latency". The same thread reports `reasoning: "none"` being
honored on the **Responses API** but not on Chat Completions for these models
(community-reported; verify in the prototype).

## 3. Rate limits and cost at low usage tiers

- `gpt-5.4-nano` Tier 1: **500 RPM / 200,000 TPM**; Tier 2: 5,000 RPM / 2M TPM
  ([model page](https://developers.openai.com/api/docs/models/gpt-5.4-nano)). Mini is in
  the same ballpark. Dictation traffic (single user, one request per utterance) is orders
  of magnitude below either — rate limits are a non-issue; no guardrail needed in the
  spec beyond the existing failure-policy fallback.
- **Cost per utterance** (~200 input tokens = system prompt + 1–3 sentence transcript,
  ~50 output): mini ≈ $0.00038, nano ≈ $0.00010. Roughly $0.04 vs $0.01 per 100
  utterances — negligible either way; not a deciding factor.

## 4. API surface

**Responses API — recommended.**
[OpenAI's guidance](https://developers.openai.com/api/docs/guides/migrate-to-responses):
Chat Completions "remains supported" (not deprecated) but "Responses is recommended for
all new projects", with "improved cache utilization (40% to 80% improvement when compared
to Chat Completions in internal tests)". Combined with the community report that
`reasoning: "none"` may only be honored on Responses (§2), Responses is the safe surface.
It is a single HTTPS POST — no session state needed (`store: false` for a one-shot).

**Chat Completions** — works, but no advantage, and risks the reasoning-effort limitation
above.

**Realtime API** — `gpt-5.4-nano` is listed as Realtime-capable, but a persistent
WebSocket session for a one-shot text rewrite buys nothing: the cost is TTFT + generation
either way, and it would add a second long-lived connection to maintain alongside the
Transcription Session. Not worth it.

**Streaming** — Insertion is one-shot, so only time-to-LAST-token matters. Streaming does
not shorten it (the same tokens are generated at the same rate); it only removes the final
response-assembly wait, which is milliseconds at 50 tokens. Use **non-streaming** for a
simpler client. (One optimization that does matter: keep the HTTPS connection warm /
reuse it, since the AA TTFT figures include connection + request overhead.)

**Prompt caching** — [caching applies automatically only to prompts of 1024 tokens or
more](https://developers.openai.com/api/docs/guides/prompt-caching). The Backtrack system
prompt will be well under that, so **caching will not trigger** and offers nothing here.
Padding the prompt past 1024 tokens to force caching is not worth it: 1024 tokens of
uncached input costs ~$0.0002 (nano) and prefill at this size is not the latency
bottleneck. Note for the record: cached input is $0.02/1M (nano) / $0.075/1M (mini), and
on GPT-5.6-era models cache writes cost 1.25× input with `prompt_cache_key` recommended —
irrelevant while the prompt stays short.

**Service tiers** — `service_tier: "priority"` on Responses/Chat Completions promises
"significantly lower and more consistent latency" at **2× per-token price**
([priority processing guide](https://developers.openai.com/api/docs/guides/priority-processing),
[pricing](https://developers.openai.com/api/docs/pricing)). Supported for `gpt-5.4` and
`gpt-5.4-mini`, **not** `gpt-5.4-nano`. At Backtrack's volumes, 2× of a negligible cost is
still negligible — a reasonable p95-tightening lever if the prototype finds the standard
tier's tail too spiky. `flex` (50% discount, higher latency) is the wrong direction.

## 5. End-to-end added-latency estimate (for the timeout budget)

For a ~50-token rewrite, mini/nano non-reasoning, standard tier, warm connection:

| | Estimate | Basis |
|---|---|---|
| p50 | **~0.9–1.0 s** | 0.64 s TTFT + 50 t ÷ ~180 t/s ≈ 0.28 s |
| p95 | **~1.8–2.5 s** (estimate — no published percentiles) | community-reported TTFT tail >1 s at roughly 1-in-20; generation-speed variance |
| Suggested timeout budget | **2.5 s hard timeout**, then insert the raw Final Transcript unchanged | keeps p95 inside the budget with margin; the failure-policy ticket owns the fallback UX |

Caveats: AA measures from US infrastructure; from Sweden add ~50–100 ms RTT unless the
request terminates at a nearby edge. Cold TLS setup adds ~100–300 ms — keep-alive or a
pre-warmed connection is the cheapest real optimization available. These numbers should
be validated by the prototype ticket with on-machine measurements.

## 6. One-pass option: can the Transcription Session do the cleanup itself?

Facts only (the cleanup-coupling decision is a separate ticket):

- type-wave's Transcription Session (`src/session.zig`) runs **`gpt-realtime-whisper`**
  over a Realtime API transcription session. Per this repo's earlier research
  ([docs/research/openai-realtime-transcription.md](openai-realtime-transcription.md), §5,
  quoting OpenAI's docs): "**Prompt is not supported with `gpt-realtime-whisper` in GA
  Realtime sessions.**" There is no instruction channel at all on the current backend.
- The models that do accept `prompt` in a transcription config (`gpt-4o-transcribe`,
  `gpt-4o-mini-transcribe`) take it as **free text for vocabulary/spelling/style biasing**
  ("expect words related to technology"), with OpenAI's guidance to keep prompts short and
  vocabulary-focused rather than long instructions. It is a biasing hint, not an
  instruction-following surface — asking it to "apply self-corrections and delete fillers"
  is off-label and has no reliability guarantee; transcription models are trained to
  transcribe what was said, including the "no 18:00" correction phrase itself.
- Switching backends to `gpt-4o-transcribe` to gain `prompt` would also sacrifice native
  streaming deltas (the models are positioned for "workflows where streaming isn't
  required"), regressing the live-transcript HUD.

**Conclusion of fact: there is no reliable one-pass path with the current (or any
documented) transcription configuration; a separate rewrite call is the only reliable
mechanism.**

## Sources

- [OpenAI API pricing](https://developers.openai.com/api/docs/pricing)
- [gpt-5.4-nano model page](https://developers.openai.com/api/docs/models/gpt-5.4-nano)
- [Priority processing guide](https://developers.openai.com/api/docs/guides/priority-processing)
- [Prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
- [Migrate to Responses guide](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [Artificial Analysis: GPT-5.4 nano (non-reasoning) providers](https://artificialanalysis.ai/models/gpt-5-4-nano-non-reasoning/providers)
- [Artificial Analysis: GPT-5.4 mini (non-reasoning)](https://artificialanalysis.ai/models/gpt-5-4-mini-non-reasoning)
- [Artificial Analysis: GPT-5.4 nano (xhigh)](https://artificialanalysis.ai/models/gpt-5-4-nano)
- [OpenAI community: gpt-5.4-nano priority tier latency thread](https://community.openai.com/t/gpt-5-4-nano-priority-service-tier-inconsistent-latency/1377270)
- Repo: [docs/research/openai-realtime-transcription.md](openai-realtime-transcription.md) (§5, prompt support matrix)
