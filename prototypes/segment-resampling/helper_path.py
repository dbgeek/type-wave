#!/usr/bin/env python3
"""Measure the production Whisper Helper path on the accepted local-backend corpus."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import resource
import statistics
import struct
import subprocess
import sys
import time
from typing import IO
import wave


MAGIC = b"TWW1"
VERSION = 2
READY = 1
STARTUP_FAILED = 2
TRANSCRIBE = 3
FINAL = 5
FAILED = 6
MAX_FRAME_BYTES = 2 * 1024 * 1024
LANGUAGE = {"en": 1, "sv": 2, "auto": 3}
PINNED_MODEL_SHA256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
ACCEPTED_CORPUS_ID = "type-wave-common-voice-17-en-sv-v1"


def percentile_nearest_rank(observations: list[float] | list[int], percentile: int) -> float | int:
    if not observations:
        raise ValueError("at least one observation is required")
    ordered = sorted(observations)
    rank = max(1, math.ceil(len(ordered) * percentile / 100))
    return ordered[rank - 1]


def read_exact(stream: IO[bytes], length: int) -> bytes:
    data = stream.read(length)
    if len(data) != length:
        raise RuntimeError(f"unexpected EOF: wanted {length} bytes, received {len(data)}")
    return data


def read_frame(stream: IO[bytes]) -> tuple[int, bytes]:
    magic, version, kind, payload_length = struct.unpack("<4sHHI", read_exact(stream, 12))
    if magic != MAGIC or version != VERSION or payload_length > MAX_FRAME_BYTES:
        raise RuntimeError("invalid helper frame header")
    return kind, read_exact(stream, payload_length)


def read_pcm(path: Path) -> bytes:
    with wave.open(str(path), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 24_000):
            raise RuntimeError(f"{path}: WAV must be mono 24 kHz signed 16-bit PCM")
        return source.readframes(source.getnframes())


def fixture_modes(fixture: dict[str, object]) -> list[str]:
    raw_modes = fixture.get("language_modes")
    if not isinstance(raw_modes, list) or not all(isinstance(mode, str) for mode in raw_modes):
        raise RuntimeError("fixture language_modes must be a string list")
    modes = [mode for mode in raw_modes if isinstance(mode, str)]
    if any(mode not in LANGUAGE for mode in modes):
        raise RuntimeError(f"unsupported fixture language mode in {modes!r}")
    return modes


def encode_transcribe(request_id: int, language: str, pcm: bytes) -> bytes:
    prompt = b""
    payload = (
        struct.pack("<QBH", request_id, LANGUAGE[language], len(prompt))
        + prompt
        + struct.pack("<I", len(pcm))
        + pcm
    )
    return struct.pack("<4sHHI", MAGIC, VERSION, TRANSCRIBE, len(payload)) + payload


def transcribe(
    stdin: IO[bytes],
    stdout: IO[bytes],
    request_id: int,
    language: str,
    pcm: bytes,
) -> float:
    frame = encode_transcribe(request_id, language, pcm)
    started = time.perf_counter_ns()
    stdin.write(frame)
    stdin.flush()
    kind, response = read_frame(stdout)
    elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000

    response_id = struct.unpack("<Q", response[:8])[0]
    if response_id != request_id:
        raise RuntimeError(f"mismatched response identity {response_id}; expected {request_id}")
    if kind == FAILED:
        code, message_length = struct.unpack("<HI", response[8:14])
        message = response[14:]
        if len(message) != message_length:
            raise RuntimeError("inconsistent helper failure length")
        raise RuntimeError(f"inference failed ({code}): {message.decode('utf-8')}")
    if kind != FINAL:
        raise RuntimeError(f"unexpected response kind {kind}")
    text_length = struct.unpack("<I", response[8:12])[0]
    if len(response[12:]) != text_length:
        raise RuntimeError("inconsistent Final Transcript length")
    response[12:].decode("utf-8")
    return elapsed_ms


def cpu_seconds(usage: resource.struct_rusage) -> float:
    return usage.ru_utime + usage.ru_stime


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("helper", type=Path, help="ReleaseFast type-wave-whisper executable")
    parser.add_argument("model", type=Path, help="pinned ggml-large-v3-turbo.bin")
    parser.add_argument(
        "--corpus",
        type=Path,
        default=Path("acceptance/local_backend/corpus"),
        help="accepted corpus directory",
    )
    parser.add_argument("--runs", type=int, default=3, help="runs per fixture")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")

    manifest_path = args.corpus / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest["corpus"]["id"] != ACCEPTED_CORPUS_ID:
        raise RuntimeError(f"unexpected corpus id {manifest['corpus']['id']!r}")
    before_cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
    process = subprocess.Popen(
        [str(args.helper), str(args.model)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
    )
    assert process.stdin is not None and process.stdout is not None
    kind, payload = read_frame(process.stdout)
    if kind == STARTUP_FAILED:
        code, message_length = struct.unpack("<HI", payload[:6])
        message = payload[6:]
        raise RuntimeError(f"helper startup failed ({code}): {message[:message_length].decode('utf-8')}")
    if kind != READY or len(payload) != 32:
        raise RuntimeError(f"helper did not become ready (kind={kind})")
    if payload.hex() != PINNED_MODEL_SHA256:
        raise RuntimeError(f"helper read unexpected model digest {payload.hex()}")

    observations: list[dict[str, object]] = []
    all_latency_ms: list[float] = []
    request_id = 1
    measured_started = time.perf_counter_ns()
    try:
        for fixture in manifest["fixtures"]:
            pcm = read_pcm(args.corpus / fixture["audio"])
            for mode in fixture_modes(fixture):
                fixture_latency_ms: list[float] = []
                for _ in range(args.runs):
                    latency_ms = transcribe(
                        process.stdin,
                        process.stdout,
                        request_id,
                        mode,
                        pcm,
                    )
                    request_id += 1
                    fixture_latency_ms.append(latency_ms)
                    all_latency_ms.append(latency_ms)
                observations.append(
                    {
                        "fixture_id": fixture["id"],
                        "mode": mode,
                        "duration_seconds": fixture["duration_seconds"],
                        "latency_ms": fixture_latency_ms,
                        "median_ms": statistics.median(fixture_latency_ms),
                        "p95_ms": percentile_nearest_rank(fixture_latency_ms, 95),
                        "p99_ms": percentile_nearest_rank(fixture_latency_ms, 99),
                    }
                )
    finally:
        process.stdin.close()
        returncode = process.wait(timeout=10)
    measured_wall_seconds = (time.perf_counter_ns() - measured_started) / 1_000_000_000
    after_cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
    helper_cpu_seconds = cpu_seconds(after_cpu) - cpu_seconds(before_cpu)
    if returncode != 0:
        raise RuntimeError(f"helper exited with status {returncode}")

    report = {
        "schema_version": 1,
        "boundary": "helper IPC write through scalar conversion and Whisper inference to terminal response",
        "model_ready_sha256": payload.hex(),
        "corpus_id": manifest["corpus"]["id"],
        "runs_per_fixture": args.runs,
        "fixture_count": len(manifest["fixtures"]),
        "mode_case_count": len(observations),
        "request_count": len(all_latency_ms),
        "summary": {
            "median_ms": statistics.median(all_latency_ms),
            "p95_ms": percentile_nearest_rank(all_latency_ms, 95),
            "p99_ms": percentile_nearest_rank(all_latency_ms, 99),
            "worst_ms": max(all_latency_ms),
            "measured_wall_seconds": measured_wall_seconds,
            "helper_process_cpu_seconds_including_startup": helper_cpu_seconds,
        },
        "fixtures": observations,
    }
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
