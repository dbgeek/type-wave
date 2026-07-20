# Backtrack prompt prototype — the question

**Throwaway prototype** for wayfinder ticket
[#141](https://github.com/dbgeek/type-wave/issues/141) ("Prototype the
Backtrack rewrite prompt against real utterances"). Delete once the surviving
prompt text is in the Backtrack spec.

## Question

Does a real prompt against **gpt-5.4-mini** (Responses API,
`reasoning: {effort: "none"}`, non-streaming — per the
[model-choice resolution](https://github.com/dbgeek/type-wave/issues/137))
actually produce the rewrites we want — and where does it break?

## How to run

    python3 prototypes/backtrack-prompt/run.py

Key comes from `$OPENAI_API_KEY`, else the app's login-keychain item
(`me.ba78.type-wave` / `openai-api-key`). The prompt under test is
`prompt.txt`; the 17 cases are in `run.py`. Raw outputs of the three
iterations are `results-run{1,2,3}.txt`.

## Verdict (round 2, after judging round 1 together)

**Surviving config: `prompt.txt` (v6) + `temperature: 0`** — 27/27 on the
expanded suite, **byte-identical outputs across three consecutive runs**
(temperature 0 is accepted by gpt-5.4-mini with `reasoning: none`, despite the
gpt-5 family's reputation for rejecting it — and it eliminated every wobble).

Round-2 learnings, in order:

- **v4** (restructure rule + "false start must never remain"): fixed the v3
  phrase-scope miss ("Just Kalle is coming"), but dropped the limiter "bara"
  in "ta med kaffe och bullar nej bara kaffe".
- **v5** ("keep every word of the replacement"): fixed "bara" but caused a
  *meaning-changing* regression — "add 20 plus 30 no 35" → "Add 35" —
  reproducible across runs.
- **v6** (narrow-scope rule: a correction replaces only the words it revises):
  both fixed, but at default temperature the two scope cases still wobbled
  run-to-run (1-in-3 "Add 35", grammar slips like "Just Kalle are coming").
- **temperature 0**: wobble gone, fully deterministic, nothing else regressed.
  Hands-off safety held in *every* run of *every* version (~190 calls, zero
  false triggers on legitimate "no"/"nej").

Timeout decision (judged with the human): **raise the budget to ~3 s** (from
#138's 2.5 s). Note the tail is fat and uncorrelated with case difficulty —
isolated 9.8 s and 14.7 s outliers observed; ~10% of calls still exceeded
2.5 s across the full sample.

## What the first three iterations showed

- **v1** (plain rules): 15/17. Broke on a bare "no" between two values with no
  restated verb ("add 20 plus 30 no 35" kept both numbers).
- **v2** (+ bare-no rule with examples): fixed values, but **over-triggered on
  Swedish sentence-initial "nej"** — the answer "nej det tycker jag inte" lost
  its "Nej". Worst failure mode seen: it changes meaning.
- **v3** (+ utterance-initial no/nej is an answer, never a correction;
  + minimal restructuring allowed; + "not/inte" contrast is emphasis): **16/17**,
  no meaning-changing failures. Surviving miss: phrase-scope restructuring
  ("Johan and Kalle are coming no just Kalle" → keeps both, adds a comma) —
  a *conservative* failure: nothing is lost, the reader still sees the intent.

## Latency (51 calls, warm HTTPS connection)

- Warm p50 **~0.8–1.0 s** — matches the research estimate (#137).
- **Tail is worse than estimated**: 5/51 calls (~10%) exceeded the 2.5 s
  timeout budget (2.7–6.0 s), with no correlation to case difficulty. Under
  the decided fallback (raw insert + amber flash), roughly 1 in 10–20
  utterances would degrade. Spec question: accept that rate, or raise the
  timeout toward ~3 s.
