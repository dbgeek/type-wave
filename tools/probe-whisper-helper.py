#!/usr/bin/env python3
"""Exercise the private helper against a manually provisioned verified model."""

from __future__ import annotations

import argparse
from pathlib import Path
import struct
import subprocess
import sys
from typing import IO
import wave


MAGIC = b"TWW1"
VERSION = 1
READY = 1
TRANSCRIBE = 3
FINAL = 5
FAILED = 6


def read_exact(stream: IO[bytes], length: int) -> bytes:
    data = stream.read(length)
    if len(data) != length:
        raise RuntimeError(f"unexpected EOF: wanted {length} bytes, received {len(data)}")
    return data


def read_frame(stream: IO[bytes]) -> tuple[int, bytes]:
    header = read_exact(stream, 12)
    magic, version, kind, payload_length = struct.unpack("<4sHHI", header)
    if magic != MAGIC or version != VERSION or payload_length > 2 * 1024 * 1024:
        raise RuntimeError("invalid helper frame header")
    return kind, read_exact(stream, payload_length)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("helper", type=Path)
    parser.add_argument("model", type=Path)
    parser.add_argument("--wav", type=Path, help="optional mono 24 kHz signed-16 WAV")
    parser.add_argument("--language", choices=("en", "sv", "auto"), default="auto")
    args = parser.parse_args()

    process = subprocess.Popen(
        [str(args.helper), str(args.model)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
    )
    assert process.stdin is not None and process.stdout is not None
    kind, payload = read_frame(process.stdout)
    if kind != READY or len(payload) != 32:
        raise RuntimeError(f"helper did not become ready (kind={kind})")
    print(f"ready model_sha256={payload.hex()}")

    if args.wav is not None:
        with wave.open(str(args.wav), "rb") as source:
            if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 24_000):
                raise RuntimeError("WAV must be mono 24 kHz signed 16-bit PCM")
            pcm = source.readframes(source.getnframes())
        language = {"en": 1, "sv": 2, "auto": 3}[args.language]
        request_id = 1
        request = struct.pack("<QB7xI", request_id, language, len(pcm)) + pcm
        process.stdin.write(struct.pack("<4sHHI", MAGIC, VERSION, TRANSCRIBE, len(request)) + request)
        process.stdin.flush()
        kind, payload = read_frame(process.stdout)
        response_id = struct.unpack("<Q", payload[:8])[0]
        if response_id != request_id:
            raise RuntimeError(f"mismatched response identity {response_id}")
        if kind == FINAL:
            text_length = struct.unpack("<I", payload[8:12])[0]
            text = payload[12:]
            if text_length != len(text):
                raise RuntimeError("inconsistent Final Transcript length")
            print(f"final id={response_id} text={text.decode('utf-8')!r}")
        elif kind == FAILED:
            code, message_length = struct.unpack("<HI", payload[8:14])
            message = payload[14:]
            if message_length != len(message):
                raise RuntimeError("inconsistent failure length")
            raise RuntimeError(f"inference failed ({code}): {message.decode('utf-8')}")
        else:
            raise RuntimeError(f"unexpected response kind {kind}")

    process.stdin.close()
    return process.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
