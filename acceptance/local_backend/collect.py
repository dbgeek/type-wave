#!/usr/bin/env python3
"""Collect release-gate transcription observations from the packaged helper."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import select
import secrets
import struct
import subprocess
import sys
import threading
import time
from typing import Any, Callable, IO, Sequence
import wave

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gate


MAGIC = b"TWW1"
VERSION = 2
READY = 1
TRANSCRIBE = 3
FINAL = 5
FAILED = 6
READY_TIMEOUT_SECONDS = 20.0
INFERENCE_TIMEOUT_SECONDS = 12.0
MAX_STDERR_BYTES = 256 * 1024


class CollectionError(RuntimeError):
    """The packaged helper did not satisfy its public collection contract."""


def scan_diagnostics(diagnostics: bytes, pcm_values: Sequence[bytes], transcripts: Sequence[str]) -> dict[str, Any]:
    """Scan retained diagnostics for raw/encoded audio and partial transcript disclosure.

    Transcript markers are the exact folded transcript plus word-boundary three-word
    phrases. Shorter runs are deliberately not markers: operational metadata legitimately
    contains natural-language words and function-word pairs (whisper.cpp prints
    `auto-detected language: is` for Icelandic; daemon prose contains "for the" and
    "on the"), so those matches evidence nothing, while any real echo of transcript
    content discloses three or more consecutive words and is still caught.
    """
    pcm_markers: list[bytes] = []
    for pcm in pcm_values:
        for offset in range(0, max(1, len(pcm) - 63), 64):
            chunk = pcm[offset : offset + 64]
            if len(chunk) == 64:
                pcm_markers.extend((chunk, chunk.hex().encode(), base64.b64encode(chunk)))
    exact_markers: set[str] = set()
    phrase_patterns: set[str] = set()
    for transcript in transcripts:
        folded = transcript.casefold()
        if folded:
            exact_markers.add(folded)
        words = gate.wer_tokens(transcript)
        for index in range(max(0, len(words) - 2)):
            gram = words[index : index + 3]
            phrase_patterns.add(r"(?<!\w)" + r"\W+".join(re.escape(word) for word in gram) + r"(?!\w)")
    folded_diagnostics = diagnostics.decode("utf-8", errors="replace").casefold()
    contains_transcript = any(marker in folded_diagnostics for marker in exact_markers) or any(
        re.search(pattern, folded_diagnostics) for pattern in phrase_patterns
    )
    return {
        "sha256": hashlib.sha256(diagnostics).hexdigest(),
        "bytes": len(diagnostics),
        "contains_pcm": any(marker in diagnostics for marker in pcm_markers),
        "contains_transcript": contains_transcript,
        "contains_operational_metadata": bool(diagnostics),
        "pcm_marker_count": len(pcm_markers),
        "transcript_marker_count": len(exact_markers) + len(phrase_patterns),
    }


def read_exact(
    stream: IO[bytes],
    length: int,
    deadline: float | None = None,
    on_wait: Callable[[], None] | None = None,
) -> bytes:
    chunks: list[bytes] = []
    received = 0
    while received < length:
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CollectionError(f"helper response timed out after receiving {received} of {length} bytes")
            if not select.select([stream], [], [], min(remaining, 0.01))[0]:
                if on_wait is not None:
                    on_wait()
                continue
        chunk = os.read(stream.fileno(), length - received)
        if not chunk:
            raise CollectionError(f"unexpected helper EOF: wanted {length} bytes, received {received}")
        chunks.append(chunk)
        received += len(chunk)
    return b"".join(chunks)


def read_frame(
    stream: IO[bytes],
    timeout_seconds: float | None = None,
    on_wait: Callable[[], None] | None = None,
) -> tuple[int, bytes]:
    deadline = time.monotonic() + timeout_seconds if timeout_seconds is not None else None
    header = read_exact(stream, 12, deadline, on_wait)
    magic, version, kind, payload_length = struct.unpack("<4sHHI", header)
    if magic != MAGIC or version != VERSION or payload_length > 2 * 1024 * 1024:
        raise CollectionError("invalid helper frame header")
    return kind, read_exact(stream, payload_length, deadline, on_wait)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def properties(path: Path) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            parsed[key] = value
    return parsed


def signature(path: Path) -> dict[str, Any]:
    verified = subprocess.run(["codesign", "--verify", "--strict", str(path)], capture_output=True).returncode == 0
    described = subprocess.run(["codesign", "-dvvv", str(path)], capture_output=True, text=True)
    full_hash = next((line.split("=", 1)[1] for line in described.stderr.splitlines() if line.startswith("CandidateCDHashFull sha256=")), None)
    identifier = next((line.split("=", 1)[1] for line in described.stderr.splitlines() if line.startswith("Identifier=")), None)
    if described.returncode != 0 or full_hash is None or identifier is None:
        raise CollectionError(f"cannot read code signature for {path.name}")
    return {"verified": verified, "identifier": identifier, "cdhash_sha256": full_hash}


def collect_identity(helper: Path, daemon: Path, model: Path, receipt: Path, provenance: Path) -> dict[str, Any]:
    resolved_helper = helper.resolve()
    resolved_daemon = daemon.resolve()
    if resolved_helper.parent != resolved_daemon.parent:
        raise CollectionError("daemon and helper are not members of the same packaged pair")
    model_size = model.stat().st_size
    model_digest = file_sha256(model)
    if model_size != gate.PINNED_CANDIDATE["model_bytes"] or model_digest != gate.PINNED_CANDIDATE["model_sha256"]:
        raise CollectionError("model bytes do not match the pinned candidate")
    receipt_values = properties(receipt)
    provenance_values = properties(provenance)
    expected = gate.PINNED_CANDIDATE
    if any((
        receipt_values.get("revision") != expected["model_revision"],
        receipt_values.get("runtime") != expected["runtime"],
        receipt_values.get("size") != str(expected["model_bytes"]),
        receipt_values.get("sha256") != expected["model_sha256"],
        provenance_values.get("revision") != expected["model_revision"],
        provenance_values.get("source_sha256") != expected["runtime_source_sha256"],
    )):
        raise CollectionError("receipt or packaged provenance does not match the pinned design")
    helper_digest = file_sha256(resolved_helper)
    return {
        "same_packaged_pair": True,
        "daemon": {"sha256": file_sha256(resolved_daemon), "signature": signature(resolved_daemon)},
        "helper": {"sha256": helper_digest, "signature": signature(resolved_helper)},
        "model": {"bytes": model_size, "sha256": model_digest},
        "receipt": {
            "sha256": file_sha256(receipt),
            "model_revision": receipt_values.get("revision"),
            "model_sha256": receipt_values.get("sha256"),
            "model_bytes": int(receipt_values["size"]),
            "runtime": receipt_values.get("runtime"),
            "runtime_sha256": receipt_values.get("runtime_sha256"),
            "matches_helper": receipt_values.get("runtime_sha256") == helper_digest,
        },
        "provenance": {
            "sha256": file_sha256(provenance),
            "model_revision": provenance_values.get("revision"),
            "runtime_source_sha256": provenance_values.get("source_sha256"),
        },
    }


def semantic_reviews(path: Path, expected: set[tuple[str, str]]) -> tuple[dict[tuple[str, str], list[str]], str]:
    document = gate.load_json(path)
    if document.get("schema_version") != 1 or document.get("review_method") != "manual_reference_comparison":
        raise CollectionError("semantic review has an invalid identity")
    rows = document.get("reviews")
    if not isinstance(rows, list):
        raise CollectionError("semantic review rows must be an array")
    indexed: dict[tuple[str, str], list[str]] = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("fixture_id"), str) or not isinstance(row.get("mode"), str):
            raise CollectionError("semantic review row is invalid")
        errors = row.get("meaning_changing_errors")
        if not isinstance(errors, list) or not all(isinstance(error, str) and error for error in errors):
            raise CollectionError("semantic review errors must be non-empty strings")
        key = (row["fixture_id"], row["mode"])
        if key in indexed:
            raise CollectionError(f"duplicate semantic review for {key[0]}/{key[1]}")
        indexed[key] = errors
    if set(indexed) != expected:
        raise CollectionError("semantic review does not cover the exact fixture/mode set")
    return indexed, file_sha256(path)


def load_pcm(path: Path) -> bytes:
    try:
        with wave.open(str(path), "rb") as source:
            actual = (source.getnchannels(), source.getsampwidth(), source.getframerate())
            if actual != (1, 2, 24_000):
                raise CollectionError(f"{path.name}: expected mono 24 kHz signed-16 WAV, got {actual}")
            return source.readframes(source.getnframes())
    except (OSError, wave.Error) as error:
        raise CollectionError(f"{path.name}: cannot read WAV: {error}") from error


def rss_mib(pid: int) -> float:
    completed = subprocess.run(
        # /bin/ps explicitly: nix's procps ps lacks the rss keyword on macOS
        ["/bin/ps", "-o", "rss=", "-p", str(pid)],
        check=True,
        capture_output=True,
        text=True,
    )
    return int(completed.stdout.strip()) / 1024


class Helper:
    def __init__(self, executable: Path, model: Path, deny_network: bool = False) -> None:
        started = time.monotonic_ns()
        command = [str(executable), str(model)]
        if deny_network:
            traced_environment = [
                f"{name}={os.environ[name]}"
                for name in ("TYPE_WAVE_NETWORK_TRACE", "TYPE_WAVE_NETWORK_RUN_ID", "DYLD_INSERT_LIBRARIES")
                if name in os.environ
            ]
            command = [
                "sandbox-exec",
                "-p",
                "(version 1) (allow default) (deny network*)",
                "/usr/bin/env",
            ] + traced_environment + command
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        assert self.process.stdin is not None and self.process.stdout is not None and self.process.stderr is not None
        self.stderr = bytearray()
        self.stderr_overflow = False
        self.stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self.stderr_thread.start()
        try:
            kind, payload = read_frame(self.process.stdout, READY_TIMEOUT_SECONDS)
        except CollectionError:
            self.process.kill()
            self.process.wait(timeout=5)
            self.stderr_thread.join(timeout=1)
            self.process.stdin.close()
            self.process.stdout.close()
            self.process.stderr.close()
            raise
        self.ready_ms = round((time.monotonic_ns() - started) / 1_000_000, 3)
        if kind != READY or payload.hex() != gate.PINNED_CANDIDATE["model_sha256"]:
            self.close()
            raise CollectionError("helper readiness did not identify the pinned model")
        # ACCEPT-7 gates peak RSS *during inference*; the post-READY load/hash residual
        # is legitimate mmap residency that pages out, so peak tracking starts at the
        # first transcribe rather than here.
        self.peak_rss_mib = 0.0
        self.next_id = 1

    def _drain_stderr(self) -> None:
        assert self.process.stderr is not None
        while chunk := self.process.stderr.read(4096):
            remaining = MAX_STDERR_BYTES - len(self.stderr)
            if remaining > 0:
                self.stderr.extend(chunk[:remaining])
            if len(chunk) > remaining:
                self.stderr_overflow = True

    def close(self) -> None:
        if self.process.stdin is not None and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.stderr_thread.join(timeout=1)
        if self.process.stdout is not None:
            self.process.stdout.close()
        if self.process.stderr is not None:
            self.process.stderr.close()
        if self.process.returncode != 0:
            stderr = self.stderr.decode("utf-8", errors="replace")
            raise CollectionError(f"helper exited {self.process.returncode}: {stderr.strip()}")
        if self.stderr_overflow:
            raise CollectionError(f"helper diagnostics exceeded the {MAX_STDERR_BYTES}-byte retention limit")

    def transcribe(self, pcm: bytes, language: str) -> tuple[str, float]:
        request_id = self.next_id
        self.next_id += 1
        language_id = {"en": 1, "sv": 2, "auto": 3}[language]
        # v2 Transcribe layout: id(Q) language(B) prompt_len(H) prompt(N) pcm_len(I) pcm.
        # The acceptance driver never biases, so the prompt region is empty (prompt_len 0).
        payload = struct.pack("<QBH", request_id, language_id, 0) + struct.pack("<I", len(pcm)) + pcm
        assert self.process.stdin is not None and self.process.stdout is not None
        started = time.monotonic_ns()
        self.process.stdin.write(struct.pack("<4sHHI", MAGIC, VERSION, TRANSCRIBE, len(payload)) + payload)
        self.process.stdin.flush()
        def sample_rss() -> None:
            self.peak_rss_mib = max(self.peak_rss_mib, rss_mib(self.process.pid))

        kind, response_payload = read_frame(self.process.stdout, INFERENCE_TIMEOUT_SECONDS, sample_rss)
        sample_rss()
        latency_ms = round((time.monotonic_ns() - started) / 1_000_000, 3)
        if len(response_payload) < 8:
            raise CollectionError("helper returned a response without a request identity")
        response_id = struct.unpack("<Q", response_payload[:8])[0]
        if response_id != request_id:
            raise CollectionError(f"helper returned mismatched request identity {response_id}")
        if kind == FAILED:
            if len(response_payload) < 14:
                raise CollectionError("helper returned a truncated failure frame")
            code, message_length = struct.unpack("<HI", response_payload[8:14])
            message = response_payload[14:]
            if len(message) != message_length:
                raise CollectionError("helper returned an invalid failure frame")
            raise CollectionError(f"helper inference failed ({code}): {message.decode('utf-8', errors='replace')}")
        if kind != FINAL or len(response_payload) < 12:
            raise CollectionError(f"helper returned unexpected frame kind {kind}")
        text_length = struct.unpack("<I", response_payload[8:12])[0]
        text = response_payload[12:]
        if len(text) != text_length:
            raise CollectionError("helper returned an invalid Final Transcript frame")
        try:
            return text.decode("utf-8"), latency_ms
        except UnicodeDecodeError as error:
            raise CollectionError("helper returned a non-UTF-8 Final Transcript") from error


def collect(
    manifest_path: Path,
    helper_path: Path,
    daemon_path: Path,
    model_path: Path,
    receipt_path: Path,
    provenance_path: Path,
    semantic_review_path: Path,
    deny_helper_network: bool = False,
    diagnostics_output: Path | None = None,
) -> dict[str, Any]:
    manifest = gate.load_json(manifest_path)
    fixtures = gate.validate_manifest(manifest, manifest_path.parent)
    expected_reviews = {(fixture_id, mode) for fixture_id, fixture in fixtures.items() for mode in fixture["language_modes"]}
    reviews, review_digest = semantic_reviews(semantic_review_path, expected_reviews)
    identity = collect_identity(helper_path, daemon_path, model_path, receipt_path, provenance_path)
    if network_trace := os.environ.get("TYPE_WAVE_NETWORK_TRACE"):
        trace_path = Path(network_trace)
        trace_path.unlink(missing_ok=True)
        run_id = secrets.token_hex(16)
        os.environ["TYPE_WAVE_NETWORK_RUN_ID"] = run_id
        trace_path.with_suffix(trace_path.suffix + ".run-id").write_text(run_id, encoding="ascii")
    helper = Helper(helper_path, model_path, deny_helper_network)
    pcm_values: list[bytes] = []
    transcripts_for_scan: list[str] = []
    result: dict[str, Any] | None = None
    try:
        rows: list[dict[str, Any]] = []
        for fixture_id, fixture in sorted(fixtures.items()):
            pcm = load_pcm(gate.resolve_artifact(manifest_path.parent, fixture["audio"], fixture_id))
            pcm_values.append(pcm)
            transcripts_for_scan.append(fixture["exact_final_transcript"])
            for mode in fixture["language_modes"]:
                transcripts: list[str] = []
                latencies: list[float] = []
                for _ in range(3):
                    transcript, latency = helper.transcribe(pcm, mode)
                    transcripts.append(transcript)
                    transcripts_for_scan.append(transcript)
                    latencies.append(latency)
                rows.append({
                    "fixture_id": fixture_id,
                    "mode": mode,
                    "final_transcript": transcripts[0],
                    "final_transcript_runs": transcripts,
                    "meaning_changing_errors": reviews[(fixture_id, mode)],
                    "latency_ms": latencies,
                })
        # ACCEPT-7's idle bar is *warmed* idle: sampled after the corpus completes,
        # once the load/hash residency has paged out and only the persistent working
        # set remains.
        idle_rss_mib = rss_mib(helper.process.pid)
        result = {
            "schema_version": 1,
            "candidate": gate.PINNED_CANDIDATE,
            "artifact_identity": identity,
            "semantic_review_sha256": review_digest,
            "transcription_runs": rows,
            "performance": {
                "cached_ready_ms": helper.ready_ms,
                "idle_rss_mib": round(idle_rss_mib, 3),
                "peak_rss_mib": round(helper.peak_rss_mib, 3),
            },
        }
    finally:
        helper.close()
    assert result is not None
    diagnostics = bytes(helper.stderr)
    if diagnostics_output is not None:
        diagnostics_output.parent.mkdir(parents=True, exist_ok=True)
        diagnostics_output.write_bytes(diagnostics)
    result["default_diagnostics_scan"] = scan_diagnostics(diagnostics, pcm_values, transcripts_for_scan)
    if diagnostics_output is not None:
        result["default_diagnostics_scan"]["artifact"] = str(diagnostics_output)
    return result


def parse_args(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--daemon", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--provenance", required=True, type=Path)
    parser.add_argument("--semantic-review", required=True, type=Path)
    parser.add_argument("--deny-helper-network", action="store_true")
    parser.add_argument("--diagnostics-output", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    args = parse_args(arguments if arguments is not None else sys.argv[1:])
    try:
        observations = collect(
            args.manifest,
            args.helper,
            args.daemon,
            args.model,
            args.receipt,
            args.provenance,
            args.semantic_review,
            args.deny_helper_network,
            args.diagnostics_output,
        )
        args.output.write_text(json.dumps(observations, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    except (CollectionError, gate.ContractError, OSError, subprocess.SubprocessError) as error:
        print(f"collection error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
