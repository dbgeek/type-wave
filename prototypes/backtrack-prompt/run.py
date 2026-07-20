#!/usr/bin/env python3
"""PROTOTYPE — wayfinder ticket #141. Throwaway; delete once the prompt is in the spec.

Sends test utterances through gpt-5.4-mini (Responses API, reasoning "none",
non-streaming) with the system prompt in prompt.txt, prints input → output plus
real round-trip latency. One warm HTTPS connection, mirroring the daemon's
keep-the-connection-warm plan.

Run:  python3 prototypes/backtrack-prompt/run.py
Key:  $OPENAI_API_KEY, else the app's login-keychain item (me.ba78.type-wave).
"""

import http.client
import json
import os
import pathlib
import statistics
import subprocess
import sys
import time

MODEL = "gpt-5.4-mini"
HERE = pathlib.Path(__file__).parent
PROMPT = (HERE / "prompt.txt").read_text()

# (label, utterance, what-we-hope-for)
CASES = [
    # Canonical self-corrections (from the ticket)
    ("correction-time", "Book a meeting at 20:00 no 18:00", "Book a meeting at 18:00"),
    ("correction-name", "today I saw person Johan... no his name was Kalle", "Today I saw person Kalle"),
    ("correction-imean", "send the report to Anna I mean to Erik", "Send the report to Erik"),
    ("correction-number", "the budget is 40 no wait 45 thousand", "The budget is 45 thousand"),
    # Filler removal
    ("fillers-en", "um so I think we should uh probably start with the mmm backend", "So I think we should probably start with the backend"),
    ("fillers-aaaa", "aaaa write a summary of the meeting", "Write a summary of the meeting"),
    # Hands-off: legitimate "no" / nothing to fix
    ("handsoff-no-answer", "no I don't think so", "unchanged"),
    ("handsoff-no-quantifier", "there are no meetings tomorrow", "unchanged"),
    ("handsoff-final-no", "the answer is no", "unchanged"),
    ("handsoff-clean", "This sentence is already clean.", "unchanged"),
    ("edge-not-emphasis", "call me at 08:15 not 08:50", "keep 08:15 (emphasis, not a self-correction)"),
    # Numbers and names
    ("numbers", "add 20 plus 30 no 35", "Add 20 plus 35"),
    ("names-scope", "Johan and Kalle are coming no just Kalle", "Just Kalle is coming (scope of 'no' is fuzzy)"),
    # Swedish and mixed
    ("sv-correction", "boka ett möte klockan åtta nej nio", "Boka ett möte klockan nio"),
    ("sv-correction-name", "skicka mailet till Johan eh nej till Kalle", "Skicka mailet till Kalle"),
    ("sv-handsoff-nej", "nej det tycker jag inte", "unchanged"),
    ("mixed-sv-en", "vi kör en quick sync imorgon um typ klockan tio", "Vi kör en quick sync imorgon typ klockan tio"),
]


def api_key():
    key = os.environ.get("OPENAI_API_KEY")
    if key:
        return key.strip()
    out = subprocess.run(
        ["security", "find-generic-password", "-s", "me.ba78.type-wave",
         "-a", "openai-api-key", "-w"],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("no OPENAI_API_KEY and no keychain item me.ba78.type-wave/openai-api-key")
    return out.stdout.strip()


def rewrite(conn, key, utterance):
    body = json.dumps({
        "model": MODEL,
        "instructions": PROMPT,
        "input": utterance,
        "reasoning": {"effort": "none"},
        "max_output_tokens": 1000,
    })
    t0 = time.monotonic()
    conn.request("POST", "/v1/responses", body=body, headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    })
    resp = conn.getresponse()
    raw = resp.read()
    ms = (time.monotonic() - t0) * 1000
    if resp.status != 200:
        return f"<HTTP {resp.status}: {raw[:300].decode(errors='replace')}>", ms
    data = json.loads(raw)
    texts = [c["text"]
             for item in data.get("output", []) if item.get("type") == "message"
             for c in item.get("content", []) if c.get("type") == "output_text"]
    return "".join(texts).strip() or f"<empty output: {json.dumps(data)[:300]}>", ms


def main():
    key = api_key()
    conn = http.client.HTTPSConnection("api.openai.com", timeout=30)
    latencies = []
    print(f"model={MODEL}  reasoning=none  cases={len(CASES)}\n")
    for label, utterance, hope in CASES:
        out, ms = rewrite(conn, key, utterance)
        latencies.append(ms)
        print(f"[{label}]  {ms:6.0f} ms")
        print(f"  in:   {utterance}")
        print(f"  out:  {out}")
        print(f"  hope: {hope}\n")
    warm = latencies[1:] or latencies
    print(f"latency ms — first(cold): {latencies[0]:.0f}  "
          f"warm p50: {statistics.median(warm):.0f}  "
          f"warm max: {max(warm):.0f}")


if __name__ == "__main__":
    main()
