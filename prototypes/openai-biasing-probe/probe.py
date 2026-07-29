#!/usr/bin/env python3
"""Live probe of gpt-live-transcribe biasing limits (wayfinder ticket #312, map #310).

Throwaway harness: a stdlib-only websocket client speaking the transcription-session
grammar (crib sheet docs/research/openai-realtime-transcription.md), probing what the
server actually accepts for `keywords` and `prompt` — none of which is documented.
Findings land in docs/research/ as a research note; this script is evidence-gathering,
not the build.

Run:  python3 prototypes/openai-biasing-probe/probe.py <phase> [args]
Phases: echo, prompt-len, kw-count, kw-itemlen, kw-budget, malformed, reupdate, boundary
Key:  $OPENAI_API_KEY, else the app's login-keychain item (me.ba78.type-wave).

Every server event is printed raw as `<< {json}` with a monotonic timestamp so the
run transcript is the raw log.
"""

import base64
import json
import os
import secrets
import socket
import ssl
import subprocess
import sys
import time
import wave

HOST = "api.openai.com"
PATH = "/v1/realtime?intent=transcription"
MODEL = "gpt-live-transcribe"

T0 = time.monotonic()


def ts():
    return f"{time.monotonic() - T0:8.3f}"


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


# ---- minimal RFC6455 client (text frames only, client-masked) -----------------------

class WS:
    def __init__(self, key):
        raw = socket.create_connection((HOST, 443), timeout=15)
        ctx = ssl.create_default_context()
        self.sock = ctx.wrap_socket(raw, server_hostname=HOST)
        nonce = base64.b64encode(secrets.token_bytes(16)).decode()
        req = (f"GET {PATH} HTTP/1.1\r\nHost: {HOST}\r\n"
               f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {nonce}\r\nSec-WebSocket-Version: 13\r\n"
               f"Authorization: Bearer {key}\r\n\r\n")
        self.sock.sendall(req.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("handshake: connection closed")
            resp += chunk
        head, _, rest = resp.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0].decode()
        if " 101 " not in status:
            raise RuntimeError(f"handshake failed: {status}\n{head.decode(errors='replace')}")
        self.buf = rest
        self.frag = b""

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send_text(self, payload):
        data = payload.encode()
        mask = secrets.token_bytes(4)
        n = len(data)
        if n < 126:
            head = bytes([0x81, 0x80 | n])
        elif n < 65536:
            head = bytes([0x81, 0x80 | 126]) + n.to_bytes(2, "big")
        else:
            head = bytes([0x81, 0x80 | 127]) + n.to_bytes(8, "big")
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(head + mask + masked)

    def _send_control(self, opcode, data=b""):
        mask = secrets.token_bytes(4)
        head = bytes([0x80 | opcode, 0x80 | len(data)])
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(head + mask + masked)

    def recv_text(self, timeout=10.0):
        """Next complete text message, or None on timeout. Answers pings; raises on close."""
        deadline = time.monotonic() + timeout
        while True:
            self.sock.settimeout(max(0.05, deadline - time.monotonic()))
            try:
                b0, b1 = self._read(2)
            except (socket.timeout, ssl.SSLError):
                return None
            fin, opcode = b0 & 0x80, b0 & 0x0F
            n = b1 & 0x7F
            if n == 126:
                n = int.from_bytes(self._read(2), "big")
            elif n == 127:
                n = int.from_bytes(self._read(8), "big")
            data = self._read(n) if n else b""
            if opcode == 8:
                raise RuntimeError(f"server close: {data[2:].decode(errors='replace')!r} code={int.from_bytes(data[:2],'big') if len(data)>=2 else '?'}")
            if opcode == 9:
                self._send_control(0xA, data)
                continue
            if opcode == 0xA:
                continue
            self.frag += data
            if fin:
                msg, self.frag = self.frag, b""
                return msg.decode()

    def close(self):
        try:
            self._send_control(8, (1000).to_bytes(2, "big"))
            self.sock.close()
        except OSError:
            pass


# ---- session helpers ----------------------------------------------------------------

def log_event(raw, clip_audio=True):
    """Print one server event; clip nothing except huge deltas' audio noise."""
    print(f"{ts()} << {raw if len(raw) < 20000 else raw[:20000] + f'…[{len(raw)} bytes total]'}")


def session_update(ws, transcription, event_id=None, quiet_payload=False):
    """Send a session.update mirroring formatSessionUpdate's envelope; return sent json."""
    session = {
        "type": "transcription",
        "audio": {
            "input": {
                "format": {"type": "audio/pcm", "rate": 24000},
                "transcription": transcription,
                "turn_detection": None,
                "noise_reduction": None,
            }
        },
    }
    msg = {"type": "session.update", "session": session}
    if event_id:
        msg["event_id"] = event_id
    payload = json.dumps(msg)
    shown = payload if not quiet_payload and len(payload) < 2000 else f"[session.update, {len(payload)} bytes, event_id={event_id}]"
    print(f"{ts()} >> {shown}")
    ws.send_text(payload)
    return payload


def wait_ack(ws, timeout=10.0):
    """Collect events until session.updated or error; return (verdict, event_dict)."""
    while True:
        raw = ws.recv_text(timeout)
        if raw is None:
            return "timeout", None
        log_event(raw)
        ev = json.loads(raw)
        if ev.get("type") == "session.updated":
            return "updated", ev
        if ev.get("type") == "error":
            return "error", ev


def connect(key):
    ws = WS(key)
    # session.created arrives unprompted
    raw = ws.recv_text(10)
    if raw:
        log_event(raw)
    return ws


def baseline_transcription(**extra):
    t = {"model": MODEL, "languages": ["en"], "delay": "low"}
    t.update(extra)
    return t


def echoed_transcription(ev):
    """Pull audio.input.transcription out of a session.updated event."""
    try:
        return ev["session"]["audio"]["input"]["transcription"]
    except (KeyError, TypeError):
        return None


def summarize_echo(ev):
    t = echoed_transcription(ev)
    if t is None:
        return "no transcription object in echo"
    kw = t.get("keywords")
    pr = t.get("prompt")
    return (f"echo: keys={sorted(t.keys())} keywords={'absent' if kw is None else f'{len(kw)} items'} "
            f"prompt={'absent' if pr is None else f'{len(pr)} chars'}")


# ---- audio --------------------------------------------------------------------------

def synth(text, path):
    subprocess.run(["say", "-o", path, "--data-format=LEI16@24000", text], check=True)
    w = wave.open(path)
    assert w.getnchannels() == 1 and w.getframerate() == 24000 and w.getsampwidth() == 2
    pcm = w.readframes(w.getnframes())
    w.close()
    return pcm


def append_audio(ws, pcm, chunk=96000):
    for i in range(0, len(pcm), chunk):
        b64 = base64.b64encode(pcm[i:i + chunk]).decode()
        ws.send_text(json.dumps({"type": "input_audio_buffer.append", "audio": b64}))
    print(f"{ts()} >> [appended {len(pcm)} pcm bytes]")


def commit_and_final(ws, timeout=30.0):
    """Commit the buffer, drain events until the final transcript; return it."""
    ws.send_text(json.dumps({"type": "input_audio_buffer.commit"}))
    print(f"{ts()} >> {{\"type\":\"input_audio_buffer.commit\"}}")
    deadline = time.monotonic() + timeout
    final = None
    while time.monotonic() < deadline:
        raw = ws.recv_text(deadline - time.monotonic())
        if raw is None:
            break
        ev = json.loads(raw)
        t = ev.get("type", "")
        if t == "conversation.item.input_audio_transcription.delta":
            print(f"{ts()} << [delta] {ev.get('delta','')!r}")
        else:
            log_event(raw)
        if t == "conversation.item.input_audio_transcription.completed":
            final = ev.get("transcript")
            break
        if t in ("conversation.item.input_audio_transcription.failed", "error"):
            break
    return final


# ---- phases -------------------------------------------------------------------------

def phase_echo(key):
    """Baseline: does session.updated echo keywords/prompt, and in what shape?"""
    ws = connect(key)
    session_update(ws, baseline_transcription(
        keywords=["type-wave", "Zig", "whisper.cpp"],
        prompt="Dictation about the type-wave macOS dictation daemon."), event_id="probe-echo-1")
    verdict, ev = wait_ack(ws)
    print(f"{ts()} -- baseline update: {verdict}; {summarize_echo(ev) if ev else ''}")
    ws.close()


def phase_prompt_len(key):
    """Ascending prompt sizes on one connection until rejection; then bisect."""
    ws = connect(key)
    filler = ("Context for dictation: the speaker discusses software, audio pipelines, "
              "and project vocabulary. ")

    def make(n):
        s = (filler * (n // len(filler) + 1))[:n]
        return s

    def try_len(n):
        session_update(ws, baseline_transcription(prompt=make(n)),
                       event_id=f"probe-plen-{n}", quiet_payload=True)
        verdict, ev = wait_ack(ws)
        detail = ""
        if verdict == "updated":
            t = echoed_transcription(ev) or {}
            got = t.get("prompt")
            detail = f"echo prompt len={'absent' if got is None else len(got)}"
        elif verdict == "error":
            detail = json.dumps(ev.get("error", ev))
        print(f"{ts()} -- prompt len {n}: {verdict} {detail}")
        return verdict == "updated"

    sizes = [256, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    last_ok, first_bad = 0, None
    for n in sizes:
        if try_len(n):
            last_ok = n
        else:
            first_bad = n
            break
    if first_bad:
        lo, hi = last_ok, first_bad
        while hi - lo > 16:
            mid = (lo + hi) // 2
            if try_len(mid):
                lo = mid
            else:
                hi = mid
        print(f"{ts()} == prompt limit: accepted {lo}, rejected {hi}")
    else:
        print(f"{ts()} == prompt limit: none found up to {last_ok}")
    ws.close()


def phase_kw_count(key):
    """Ascending keyword counts (fixed short items) until rejection; then bisect."""
    ws = connect(key)

    def try_count(n):
        kws = [f"term{i:04d}" for i in range(n)]
        session_update(ws, baseline_transcription(keywords=kws),
                       event_id=f"probe-kwn-{n}", quiet_payload=True)
        verdict, ev = wait_ack(ws)
        detail = ""
        if verdict == "updated":
            t = echoed_transcription(ev) or {}
            got = t.get("keywords")
            detail = f"echo keywords={'absent' if got is None else len(got)} items"
        elif verdict == "error":
            detail = json.dumps(ev.get("error", ev))
        print(f"{ts()} -- kw count {n}: {verdict} {detail}")
        return verdict == "updated"

    sizes = [16, 64, 100, 128, 256, 512, 1024]
    last_ok, first_bad = 0, None
    for n in sizes:
        if try_count(n):
            last_ok = n
        else:
            first_bad = n
            break
    if first_bad:
        lo, hi = last_ok, first_bad
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if try_count(mid):
                lo = mid
            else:
                hi = mid
        print(f"{ts()} == keyword count limit: accepted {lo}, rejected {hi}")
    else:
        print(f"{ts()} == keyword count limit: none found up to {last_ok}")
    ws.close()


def phase_kw_itemlen(key):
    """Single keyword of ascending length until rejection; then bisect."""
    ws = connect(key)

    def try_len(n):
        session_update(ws, baseline_transcription(keywords=["k" * n]),
                       event_id=f"probe-kwl-{n}", quiet_payload=True)
        verdict, ev = wait_ack(ws)
        detail = "" if verdict == "updated" else json.dumps((ev or {}).get("error", ev))
        print(f"{ts()} -- kw item len {n}: {verdict} {detail}")
        return verdict == "updated"

    sizes = [16, 32, 64, 128, 256, 512, 1024]
    last_ok, first_bad = 0, None
    for n in sizes:
        if try_len(n):
            last_ok = n
        else:
            first_bad = n
            break
    if first_bad:
        lo, hi = last_ok, first_bad
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if try_len(mid):
                lo = mid
            else:
                hi = mid
        print(f"{ts()} == keyword item-length limit: accepted {lo}, rejected {hi}")
    else:
        print(f"{ts()} == keyword item-length limit: none found up to {last_ok}")
    ws.close()


def phase_kw_budget(key, count, itemlen):
    """Max-count list at a given item length — does a *total* budget bind before count does?"""
    ws = connect(key)
    kws = [f"{'x' * (itemlen - 4)}{i:04d}" for i in range(count)]
    session_update(ws, baseline_transcription(keywords=kws),
                   event_id=f"probe-kwb-{count}x{itemlen}", quiet_payload=True)
    verdict, ev = wait_ack(ws, timeout=15)
    detail = ""
    if verdict == "updated":
        t = echoed_transcription(ev) or {}
        got = t.get("keywords")
        detail = f"echo keywords={'absent' if got is None else len(got)} items"
    elif verdict == "error":
        detail = json.dumps(ev.get("error", ev))
    print(f"{ts()} == budget {count} items x {itemlen} chars (~{count*itemlen} chars total): {verdict} {detail}")
    ws.close()


def phase_malformed(key):
    """Banned characters, event_id echo on error, and session survival after rejection."""
    ws = connect(key)
    cases = [
        ("angle-lt", ["good", "bad<tag"]),
        ("angle-gt", ["good", "bad>tag"]),
        ("cr", ["good", "bad\rterm"]),
        ("lf", ["good", "bad\nterm"]),
        ("empty-item", ["good", ""]),
        ("non-string", ["good", 42]),
    ]
    for name, kws in cases:
        session_update(ws, baseline_transcription(keywords=kws), event_id=f"probe-mal-{name}")
        verdict, ev = wait_ack(ws)
        eid = (ev or {}).get("error", {}).get("event_id") if verdict == "error" else None
        print(f"{ts()} -- malformed/{name}: {verdict} error.event_id={eid}")
    # survival: benign update must still ack on the same connection
    session_update(ws, baseline_transcription(keywords=["still-alive"]), event_id="probe-mal-survive")
    verdict, ev = wait_ack(ws)
    print(f"{ts()} == post-rejection benign update: {verdict}; {summarize_echo(ev) if ev else ''} (session survived: {verdict == 'updated'})")
    ws.close()


SCRATCH = os.environ.get("PROBE_SCRATCH", "/tmp")
CLIP_TEXT = "The klarvex module streams audio to the daemon."


def phase_reupdate(key):
    """Same audio, three committed turns on ONE connection:
    turn 1 no keywords, turn 2 after re-update adding 'Klarvex',
    turn 3 after a REJECTED update (old config should still bias)."""
    clip = os.path.join(SCRATCH, "probe-klarvex.wav")
    pcm = synth(CLIP_TEXT, clip)
    ws = connect(key)

    session_update(ws, baseline_transcription(keywords=[]), event_id="probe-re-1")
    print(f"{ts()} -- turn1 setup: {wait_ack(ws)[0]}")
    append_audio(ws, pcm)
    t1 = commit_and_final(ws)
    print(f"{ts()} == turn1 (no keywords): {t1!r}")

    session_update(ws, baseline_transcription(keywords=["Klarvex"]), event_id="probe-re-2")
    print(f"{ts()} -- turn2 re-update: {wait_ack(ws)[0]}")
    append_audio(ws, pcm)
    t2 = commit_and_final(ws)
    print(f"{ts()} == turn2 (keywords=[Klarvex] via mid-session re-update): {t2!r}")

    session_update(ws, baseline_transcription(keywords=["ok", "bad<tag"]), event_id="probe-re-3")
    print(f"{ts()} -- turn3 rejected update: {wait_ack(ws)[0]} (expect error)")
    append_audio(ws, pcm)
    t3 = commit_and_final(ws)
    print(f"{ts()} == turn3 (after rejected update — old config should hold): {t3!r}")
    ws.close()


def phase_boundary(key, late=False):
    """Apply-boundary: append half the audio, re-update keywords, append the rest,
    commit — which config wins for that turn? With late=True the invented term sits
    in the SECOND half, i.e. in audio appended after the update was acked."""
    if late:
        clip = os.path.join(SCRATCH, "probe-klarvex-late.wav")
        pcm = synth("The daemon streams audio onward through the klarvex module.", clip)
    else:
        clip = os.path.join(SCRATCH, "probe-klarvex.wav")
        pcm = synth(CLIP_TEXT, clip)
    ws = connect(key)
    session_update(ws, baseline_transcription(keywords=[]), event_id="probe-bnd-1")
    print(f"{ts()} -- setup: {wait_ack(ws)[0]}")
    half = len(pcm) // 2 // 2 * 2
    append_audio(ws, pcm[:half])
    session_update(ws, baseline_transcription(keywords=["Klarvex"]), event_id="probe-bnd-2")
    print(f"{ts()} -- mid-append re-update: {wait_ack(ws)[0]}")
    append_audio(ws, pcm[half:])
    t = commit_and_final(ws)
    print(f"{ts()} == mid-append turn (update between halves): {t!r}")
    ws.close()


def phase_late_control(key):
    """Controls for boundary-late: the late-term clip with (1) no keywords and
    (2) keywords set before any audio — brackets the mid-append result."""
    clip = os.path.join(SCRATCH, "probe-klarvex-late.wav")
    pcm = synth("The daemon streams audio onward through the klarvex module.", clip)
    ws = connect(key)
    session_update(ws, baseline_transcription(keywords=[]), event_id="probe-lc-1")
    print(f"{ts()} -- control setup (no keywords): {wait_ack(ws)[0]}")
    append_audio(ws, pcm)
    t1 = commit_and_final(ws)
    print(f"{ts()} == late clip, no keywords: {t1!r}")
    session_update(ws, baseline_transcription(keywords=["Klarvex"]), event_id="probe-lc-2")
    print(f"{ts()} -- keywords set before append: {wait_ack(ws)[0]}")
    append_audio(ws, pcm)
    t2 = commit_and_final(ws)
    print(f"{ts()} == late clip, keywords pre-set: {t2!r}")
    ws.close()


def phase_prompt_misc(key):
    """Prompt content rules: newlines/angle brackets (keyword ban — does it apply to
    prompt?), and whether the 1024 limit counts characters or bytes (multibyte test)."""
    ws = connect(key)
    cases = [
        ("newline", "Line one.\nLine two."),
        ("cr", "Line one.\rLine two."),
        ("angles", "Vocabulary: <type-wave> and <Zig>."),
        ("multibyte-600", "é" * 600),           # 600 chars, 1200 utf-8 bytes
        ("multibyte-1024", "é" * 1024),         # 1024 chars, 2048 utf-8 bytes
        ("emoji-600", "🎤" * 600),               # 600 code points, 2400 bytes
    ]
    for name, prompt in cases:
        session_update(ws, baseline_transcription(prompt=prompt),
                       event_id=f"probe-pm-{name}", quiet_payload=True)
        verdict, ev = wait_ack(ws)
        detail = ""
        if verdict == "updated":
            t = echoed_transcription(ev) or {}
            got = t.get("prompt")
            detail = f"echo prompt len={'absent' if got is None else len(got)}"
        elif verdict == "error":
            detail = json.dumps(ev.get("error", ev))
        print(f"{ts()} -- prompt-misc/{name}: {verdict} {detail}")
    ws.close()


PHASES = {
    "echo": phase_echo,
    "prompt-len": phase_prompt_len,
    "kw-count": phase_kw_count,
    "kw-itemlen": phase_kw_itemlen,
    "malformed": phase_malformed,
    "reupdate": phase_reupdate,
    "boundary": phase_boundary,
    "boundary-late": lambda key: phase_boundary(key, late=True),
    "late-control": phase_late_control,
    "prompt-misc": phase_prompt_misc,
}


def main():
    if len(sys.argv) < 2:
        sys.exit(f"usage: probe.py <{'|'.join(PHASES)}|kw-budget COUNT ITEMLEN>")
    key = api_key()
    name = sys.argv[1]
    if name == "kw-budget":
        phase_kw_budget(key, int(sys.argv[2]), int(sys.argv[3]))
        return
    if name not in PHASES:
        sys.exit(f"unknown phase {name}")
    PHASES[name](key)


if __name__ == "__main__":
    main()
