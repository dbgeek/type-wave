#!/usr/bin/env python3
"""Retain daemon diagnostics and socket-attempt instrumentation for qualification."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import tempfile
from typing import Sequence


def run_daemon(daemon: Path, interposer: Path, trace: Path, diagnostics: Path, timeout_seconds: float) -> int:
    prior = trace.read_text(encoding="utf-8").splitlines() if trace.exists() else []
    run_id = trace.with_suffix(trace.suffix + ".run-id").read_text(encoding="ascii")
    if not run_id or any(f"run={run_id} " not in line for line in prior):
        raise RuntimeError("helper network trace is not bound to the current collection run")
    if sum("process=type-wave-whisper operation=instrumentation_loaded" in line for line in prior) != 1 or any("process=type-wave operation=" in line for line in prior):
        raise RuntimeError("network trace must contain exactly one helper load and no prior daemon run")
    command = [
        "sandbox-exec", "-p", "(version 1) (allow default) (deny network*)", "/usr/bin/env",
        f"TYPE_WAVE_NETWORK_TRACE={trace}", f"TYPE_WAVE_NETWORK_RUN_ID={run_id}", f"DYLD_INSERT_LIBRARIES={interposer}", str(daemon),
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
    diagnostics.parent.mkdir(parents=True, exist_ok=True)
    diagnostics.write_bytes(stdout + stderr)
    current = trace.read_text(encoding="utf-8").splitlines()
    if any(f"run={run_id} " not in line for line in current):
        raise RuntimeError("daemon network trace is not bound to the current collection run")
    if sum("process=type-wave operation=instrumentation_loaded" in line for line in current) != 1:
        raise RuntimeError("network instrumentation did not load exactly once in the daemon")
    return process.returncode or 0


def isolated_keychain_run(daemon: Path, interposer: Path, trace: Path, diagnostics: Path, timeout_seconds: float) -> int:
    original_search = shlex.split(subprocess.check_output(("security", "list-keychains", "-d", "user"), text=True))
    original_default = shlex.split(subprocess.check_output(("security", "default-keychain", "-d", "user"), text=True))[0]
    with tempfile.TemporaryDirectory(prefix="type-wave-acceptance-") as temporary:
        keychain = Path(temporary) / "empty.keychain-db"
        subprocess.run(("security", "create-keychain", "-p", "", str(keychain)), check=True)
        try:
            subprocess.run(("security", "list-keychains", "-d", "user", "-s", str(keychain)), check=True)
            subprocess.run(("security", "default-keychain", "-d", "user", "-s", str(keychain)), check=True)
            return run_daemon(daemon, interposer, trace, diagnostics, timeout_seconds)
        finally:
            subprocess.run(("security", "list-keychains", "-d", "user", "-s", *original_search), check=True)
            subprocess.run(("security", "default-keychain", "-d", "user", "-s", original_default), check=True)
            subprocess.run(("security", "delete-keychain", str(keychain)), check=False)


def main(arguments: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daemon", required=True, type=Path)
    parser.add_argument("--interposer", required=True, type=Path)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--diagnostics", required=True, type=Path)
    parser.add_argument("--observation", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=float, default=15)
    parser.add_argument("--isolate-keychain", action="store_true")
    args = parser.parse_args(arguments)
    runner = isolated_keychain_run if args.isolate_keychain else run_daemon
    result = runner(args.daemon, args.interposer, args.trace, args.diagnostics, args.timeout_seconds)
    raw = args.diagnostics.read_bytes()
    observation = {
        "schema_version": 1,
        "daemon_returncode": result,
        "empty_keychain_search_and_default": args.isolate_keychain,
        "credentials_environment_unset": not os.environ.get("OPENAI_API_KEY") and not os.environ.get("HF_TOKEN"),
        "network_sandbox": "deny network*",
        "diagnostics_sha256": hashlib.sha256(raw).hexdigest(),
        "ready_offline": b"READY" in raw and b"local KB Whisper helper warm" in raw,
    }
    args.observation.parent.mkdir(parents=True, exist_ok=True)
    args.observation.write_text(json.dumps(observation, sort_keys=True, separators=(",", ":")), encoding="utf-8")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
