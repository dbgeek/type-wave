#!/usr/bin/env python3
"""A/B benchmark of gpt-live-transcribe biasing levers (wayfinder ticket #313, map #310).

Throwaway harness, sibling of probe.py (whose WS client and session helpers it reuses).
Replays FIXED audio through four arms -- bare / keywords / prompt / both -- so the only
thing that varies between arms is the biasing config, never the utterance. Two phases:

  content  efficacy: six jargon-dense lines, scored on WER and canonical-term recall
  leak     leakage: silence / noise / one-word clips, looking for prompt or keyword
           text emitted when there is nothing to transcribe

Run:  python3 prototypes/openai-biasing-probe/ab.py content [--repeats N] [--out DIR]
      python3 prototypes/openai-biasing-probe/ab.py leak    [--repeats N] [--out DIR]
      python3 prototypes/openai-biasing-probe/ab.py score   --out DIR
      python3 prototypes/openai-biasing-probe/ab.py synth   --voice-dir DIR   (make say clips)

Audio source is pluggable: --audio-dir DIR replays <id>.wav recorded by a human instead
of the `say`-synthesized clips, for the real-voice confirmation pass. Everything else --
arms, ordering, scoring -- is identical, so the two passes are directly comparable.

Raw per-turn results land as JSONL in --out; the verbose wire log lands beside them.
Findings go to docs/research/; this script is evidence-gathering, not the build.
"""

import argparse
import contextlib
import io
import json
import os
import random
import struct
import subprocess
import sys
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe as P  # noqa: E402


# ---- the corpus ---------------------------------------------------------------------
#
# `say` is what gets spoken; `ref` is the canonical written form a human dictating this
# would want back. They differ deliberately: "whisper dot C P P" spoken should land as
# "whisper.cpp" written. Recovering that canonical form is exactly the job we are asking
# the biasing levers to do, so `terms` -- checked as exact strings, case-insensitively --
# is the metric that answers the ticket.

CONTENT = [
    dict(id="L1",
         say="The type wave daemon streams audio to the OpenAI real time endpoint.",
         ref="The type-wave daemon streams audio to the OpenAI Realtime endpoint.",
         terms=["type-wave"]),
    dict(id="L2",
         say="Rebuild whisper dot C P P and then run zig build test.",
         ref="Rebuild whisper.cpp and then run zig build test.",
         terms=["whisper.cpp", "zig build test"]),
    dict(id="L3",
         say="Bjorn edited config dot zon and restarted the launch agent.",
         ref="Bjorn edited config.zon and restarted the LaunchAgent.",
         terms=["Bjorn", "config.zon", "LaunchAgent"]),
    dict(id="L4",
         say="The wayfinder map lists every ticket on the frontier.",
         ref="The wayfinder map lists every ticket on the frontier.",
         terms=["wayfinder"]),
    dict(id="L5",
         say="Secure event input blocked keystroke insertion in ghostty.",
         ref="Secure Event Input blocked keystroke insertion in ghostty.",
         terms=["Secure Event Input", "ghostty"]),
    dict(id="L6",
         say="Core audio captures twenty four kilohertz mono P C M for the segmenter.",
         ref="CoreAudio captures twenty-four kilohertz mono PCM for the segmenter.",
         terms=["CoreAudio", "PCM", "segmenter"]),
]

# Leakage clips: nothing to transcribe, so any words that come back came from the config.
LEAK = [
    dict(id="S3", kind="silence", seconds=3.0),
    dict(id="S8", kind="silence", seconds=8.0),
    dict(id="N3", kind="noise", seconds=3.0, amp=400),    # room-tone level
    dict(id="N3L", kind="noise", seconds=3.0, amp=3000),  # loud hiss
    dict(id="W1", kind="say", say="Yes."),                # very short utterance
    dict(id="W2", kind="say", say="Okay."),
]

# The user's plausible production vocabulary: the canonical forms, plus a few terms that
# are NOT in any clip (real vocabularies always carry unused entries).
VOCAB = [
    "type-wave", "whisper.cpp", "Zig", "Bjorn", "config.zon", "LaunchAgent",
    "wayfinder", "ghostty", "CoreAudio", "Secure Event Input", "PCM", "segmenter",
]

# Scene-setting only -- deliberately NO term list. Whether echoing the vocabulary into
# the prompt helps is a separate, still-fogged question on map #310; keeping the two
# channels carrying different *information* is what makes them distinguishable here.
PROMPT = (
    "This is dictation from a software engineer working on a macOS dictation daemon "
    "written in Zig. The speaker discusses audio capture, websockets, build tooling, "
    "configuration files, and issue tracking. Transcribe technical terms, file names, "
    "and command-line invocations in their canonical written form."
)

ARMS = {
    "bare": {},
    "keywords": {"keywords": VOCAB},
    "prompt": {"prompt": PROMPT},
    "both": {"keywords": VOCAB, "prompt": PROMPT},
}


# ---- audio --------------------------------------------------------------------------

def wav_pcm(path):
    w = wave.open(path)
    assert w.getnchannels() == 1 and w.getframerate() == 24000 and w.getsampwidth() == 2, \
        f"{path}: need mono 24000Hz 16-bit, got {w.getnchannels()}ch {w.getframerate()}Hz {w.getsampwidth()*8}bit"
    pcm = w.readframes(w.getnframes())
    w.close()
    return pcm


def write_wav(path, pcm):
    w = wave.open(path, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(24000)
    w.writeframes(pcm)
    w.close()


def silence(seconds):
    return b"\x00\x00" * int(24000 * seconds)


def noise(seconds, amp, seed=1234):
    rng = random.Random(seed)
    n = int(24000 * seconds)
    return struct.pack(f"<{n}h", *(rng.randint(-amp, amp) for _ in range(n)))


VOICE = "Samantha"  # pinned en_US: the machine default renders "wayfinder" unintelligibly


def say_clip(path, text, voice):
    cmd = ["say", "-o", path, "--data-format=LEI16@24000"]
    if voice:
        cmd += ["-v", voice]
    subprocess.run(cmd + [text], check=True)


def build_clips(phase, cache, audio_dir=None, voice=VOICE):
    """Return {id: pcm}. With --audio-dir, content clips come from <id>.wav there."""
    os.makedirs(cache, exist_ok=True)
    clips = {}
    if phase == "content":
        for line in CONTENT:
            if audio_dir:
                clips[line["id"]] = wav_pcm(os.path.join(audio_dir, line["id"] + ".wav"))
            else:
                path = os.path.join(cache, line["id"] + ".wav")
                if not os.path.exists(path):
                    say_clip(path, line["say"], voice)
                clips[line["id"]] = wav_pcm(path)
    else:
        for c in LEAK:
            path = os.path.join(cache, c["id"] + ".wav")
            if c["kind"] == "say":
                if audio_dir and os.path.exists(os.path.join(audio_dir, c["id"] + ".wav")):
                    clips[c["id"]] = wav_pcm(os.path.join(audio_dir, c["id"] + ".wav"))
                    continue
                if not os.path.exists(path):
                    say_clip(path, c["say"], voice)
                clips[c["id"]] = wav_pcm(path)
            else:
                pcm = silence(c["seconds"]) if c["kind"] == "silence" \
                    else noise(c["seconds"], c["amp"])
                write_wav(path, pcm)
                clips[c["id"]] = pcm
    return clips


# ---- running ------------------------------------------------------------------------

def run_arm(key, arm, clips, order, log):
    """One fresh connection per (arm, repeat). Config set once; every clip committed as
    its own turn, in a fixed order shared by all arms so any cross-turn priming is a
    confound the arms carry equally."""
    rows = []
    with contextlib.redirect_stdout(log):
        ws = P.connect(key)
        try:
            P.session_update(ws, P.baseline_transcription(**ARMS[arm]),
                             event_id=f"ab-{arm}", quiet_payload=True)
            verdict, ev = P.wait_ack(ws)
            if verdict != "updated":
                raise RuntimeError(f"arm {arm}: session.update {verdict}")
            echo = P.summarize_echo(ev)
            for cid in order:
                t0 = time.monotonic()
                P.append_audio(ws, clips[cid])
                final = P.commit_and_final(ws)
                rows.append(dict(arm=arm, clip=cid, transcript=final,
                                 ms=int((time.monotonic() - t0) * 1000)))
        finally:
            with contextlib.suppress(Exception):
                ws.close()
    return rows, echo


def phase_run(args, phase):
    key = P.api_key()
    cache = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clips",
                         "voice" if args.audio_dir else f"say-{args.voice or 'default'}")
    clips = build_clips(phase, cache, args.audio_dir, args.voice)
    order = [c["id"] for c in (CONTENT if phase == "content" else LEAK)]
    os.makedirs(args.out, exist_ok=True)
    src = "voice" if args.audio_dir else "say"
    jsonl = os.path.join(args.out, f"{phase}-{src}.jsonl")
    logpath = os.path.join(args.out, f"{phase}-{src}.log")

    total = len(ARMS) * args.repeats
    done = 0
    with open(logpath, "w") as log, open(jsonl, "w") as out:
        for rep in range(args.repeats):
            for arm in ARMS:
                done += 1
                print(f"[{done}/{total}] {phase} arm={arm} rep={rep}", file=sys.stderr, flush=True)
                for attempt in range(3):
                    try:
                        rows, echo = run_arm(key, arm, clips, order, log)
                        break
                    except Exception as exc:  # transient websocket/API failures
                        print(f"    retry {attempt+1}: {exc}", file=sys.stderr, flush=True)
                        rows, echo = [], f"failed: {exc}"
                        time.sleep(2)
                print(f"    {echo}", file=sys.stderr, flush=True)
                for r in rows:
                    r.update(rep=rep, source=src, phase=phase)
                    out.write(json.dumps(r) + "\n")
                    print(f"    {r['clip']}: {r['transcript']!r}", file=sys.stderr, flush=True)
                out.flush()
    print(f"\nwrote {jsonl}\n      {logpath}", file=sys.stderr)


# ---- scoring ------------------------------------------------------------------------

def norm(s):
    """#36 / #298 normalization: lowercase, hyphens split, punctuation stripped."""
    s = (s or "").lower().replace("-", " ").replace("_", " ")
    keep = [c if (c.isalnum() or c.isspace()) else " " for c in s]
    return "".join(keep).split()


def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    if not r:
        return 0.0 if not h else 1.0
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev = cur
    return d[len(h)] / len(r)


def term_hit(term, transcript):
    """Exact canonical form, case-insensitive. 'type-wave' must come back hyphenated;
    'type wave' and 'typewave' are misses -- that is the whole point of the metric."""
    return term.lower() in (transcript or "").lower()


def leak_words(transcript):
    """Words in a no-speech transcript that plausibly came from the biasing config."""
    t = (transcript or "").lower()
    hits = [v for v in VOCAB if v.lower() in t]
    prompt_words = {w for w in norm(PROMPT) if len(w) > 4}
    overlap = sorted(prompt_words.intersection(norm(t)))
    return hits, overlap


def phase_score(args):
    src = "voice" if args.audio_dir else "say"
    lines = {c["id"]: c for c in CONTENT}
    for phase in ("content", "leak"):
        path = os.path.join(args.out, f"{phase}-{src}.jsonl")
        if not os.path.exists(path):
            continue
        rows = [json.loads(l) for l in open(path)]
        print(f"\n=== {phase} ({src}, {len(rows)} turns) ===")
        if phase == "content":
            print(f"\n{'arm':10} {'WER':>7} {'term recall':>12}   missed terms")
            for arm in ARMS:
                a = [r for r in rows if r["arm"] == arm]
                if not a:
                    continue
                wers = [wer(lines[r["clip"]]["ref"], r["transcript"]) for r in a]
                hits = miss = 0
                missed = {}
                for r in a:
                    for term in lines[r["clip"]]["terms"]:
                        if term_hit(term, r["transcript"]):
                            hits += 1
                        else:
                            miss += 1
                            missed[term] = missed.get(term, 0) + 1
                tot = hits + miss
                worst = sorted(missed.items(), key=lambda kv: -kv[1])[:5]
                print(f"{arm:10} {sum(wers)/len(wers):7.3f} {hits}/{tot:<3} ({hits/tot:5.1%})   "
                      + ", ".join(f"{k}×{v}" for k, v in worst))
            print(f"\nper-term recall (hits / attempts):\n")
            terms = sorted({t for c in CONTENT for t in c["terms"]})
            print(f"{'term':22}" + "".join(f"{a:>11}" for a in ARMS))
            for term in terms:
                cells = []
                for arm in ARMS:
                    a = [r for r in rows if r["arm"] == arm
                         and term in lines[r["clip"]]["terms"]]
                    h = sum(1 for r in a if term_hit(term, r["transcript"]))
                    cells.append(f"{h}/{len(a)}" if a else "-")
                print(f"{term:22}" + "".join(f"{c:>11}" for c in cells))
        else:
            print(f"\n{'arm':10} {'non-empty':>10} {'vocab leak':>11} {'prompt-word leak':>17}")
            for arm in ARMS:
                a = [r for r in rows if r["arm"] == arm]
                if not a:
                    continue
                nonempty = [r for r in a if (r["transcript"] or "").strip()]
                v = p = 0
                for r in a:
                    hits, overlap = leak_words(r["transcript"])
                    v += bool(hits)
                    p += bool(overlap)
                print(f"{arm:10} {len(nonempty)}/{len(a):<6} {v:>11} {p:>17}")
            print("\nnon-empty no-speech transcripts:")
            for r in rows:
                if (r["transcript"] or "").strip():
                    print(f"  {r['arm']:9} {r['clip']:4} {r['transcript']!r}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("phase", choices=["content", "leak", "score", "synth", "corpus"])
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--out", default="ab-results")
    ap.add_argument("--audio-dir", default=None,
                    help="replay human-recorded <id>.wav from here instead of `say` clips")
    ap.add_argument("--voice", default=VOICE, help="`say` voice; empty string = machine default")
    args = ap.parse_args()
    if args.phase == "corpus":
        json.dump([{"id": c["id"], "say": c["say"]} for c in CONTENT], sys.stdout, indent=1)
    elif args.phase == "score":
        phase_score(args)
    elif args.phase == "synth":
        cache = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clips",
                             f"say-{args.voice or 'default'}")
        build_clips("content", cache, voice=args.voice)
        build_clips("leak", cache, voice=args.voice)
        print(f"clips in {cache}")
    else:
        phase_run(args, args.phase)


if __name__ == "__main__":
    main()
