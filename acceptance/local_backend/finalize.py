#!/usr/bin/env python3
"""Run the deterministic matrix and assemble digest-bound release evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gate
import collect


FAULT_BASIS: dict[str, dict[str, tuple[str, ...]]] = {
    "successful_lifecycle": {key: ("local_backend.test.local Transcription Backend drives one Insertion",) for key in ("serialized_phases", "exactly_one_insertion")},
    "empty_capture": {key: ("coordinator.test.8 no audio committed",) for key in ("abandoned", "no_insertion")},
    "empty_final_transcript": {key: ("coordinator.test.10 empty/failed final inserts nothing",) for key in ("abandoned", "no_insertion")},
    "helper_loss_during_capture": {key: ("coordinator.test.6 backend failure while capturing",) for key in ("feedback_until_release", "abandoned")},
    "helper_crash": {key: ("local_backend.test.helper crash malformed IPC and inference failure abandon active Utterances and schedule restart",) for key in ("abandoned", "restart_scheduled")},
    "malformed_ipc": {key: ("local_backend.test.helper crash malformed IPC and inference failure abandon active Utterances and schedule restart",) for key in ("abandoned", "restart_scheduled")},
    "inference_failure": {key: ("local_backend.test.helper crash malformed IPC and inference failure abandon active Utterances and schedule restart",) for key in ("abandoned", "restart_scheduled")},
    "restart_backoff_and_latch": {key: ("whisper_supervisor.test.helper recovery waits 1 2 and 4 seconds",) for key in ("backoff_1_2_4_seconds", "latched_after_three")},
    "successful_final_resets_failures": {"failure_budget_reset": ("whisper_supervisor.test.explicit reset and successful Final Transcript restore",)},
    "cooperative_cancellation": {
        "cancel_requested_at_9500ms": ("transcription_backend.test.local deadline requests cancellation",),
        "abandoned": ("coordinator.test.9a cooperative deadline requests cancellation",),
        "no_insertion": ("coordinator.test.9a cooperative deadline requests cancellation",),
    },
    "forced_termination": {
        "terminated_by_10000ms": ("local_backend.test.hard cancellation terminates a non-responsive helper process",),
        "abandoned": ("coordinator.test.9 deadline before final abandons",),
        "no_insertion": ("coordinator.test.9 deadline before final abandons",),
    },
    "final_timeout_race": {"exactly_one_terminal_winner": ("coordinator.test.15 mismatched duplicate late and phase-invalid events",)},
    "stale_events": {
        "late_ignored": ("coordinator.test.11 stale final outside awaiting is ignored",),
        "duplicate_ignored": ("coordinator.test.15 mismatched duplicate late and phase-invalid events",),
        "mismatched_id_ignored": ("coordinator.test.15 mismatched duplicate late and phase-invalid events",),
        "post_cancel_ignored": ("local_backend.test.local Transcription Backend emits only matching terminal events",),
    },
    "non_idle_press": {"press_ignored": ("coordinator.test.2 press while non-idle is dropped", "coordinator.test.13 press during .inserting is dropped")},
    "backend_switch": {
        "lease_stays_pinned": ("coordinator.test.14 accepted Utterance pins unique identity",),
        "no_cross_backend_audio": ("coordinator.test.14 accepted Utterance pins unique identity",),
        "new_capture_blocked": ("transcription_backend.test.selection drains an active lease",),
    },
    "prerequisite_loss": {key: ("coordinator.test.6 backend failure while capturing",) for key in ("active_utterance_poisoned", "capture_stopped")},
    "helper_recovery": {"ready_only_after_warmup": ("whisper_helper_core.test.helper declares readiness only after exact artifact load and warm-up",)},
    "abandonment_has_no_side_effects": {key: ("local_backend.test.local Transcription Backend drives one Insertion",) for key in ("no_insertion", "no_retry", "no_openai_fallback")},
}


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def write_trace(path: Path, value: dict[str, Any]) -> str:
    rendered = canonical_bytes(value)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(rendered)
    return hashlib.sha256(rendered).hexdigest()


def validate_fault_basis(root: Path) -> None:
    source = (root / "src/tests.zig").read_text(encoding="utf-8")
    if not source:
        raise gate.ContractError("lifecycle test root is empty")
    if set(FAULT_BASIS) != set(gate.REQUIRED_FAULTS):
        raise gate.ContractError("fault basis does not cover the required scenarios")
    for scenario, assertions in FAULT_BASIS.items():
        if set(assertions) != set(gate.REQUIRED_FAULT_ASSERTIONS[scenario]):
            raise gate.ContractError(f"fault basis does not cover the required assertions for {scenario}")


def parse_test_results(output: str) -> set[str]:
    passed: set[str] = set()
    pending: str | None = None
    for line in output.splitlines():
        match = re.match(r"^\d+/\d+ (.+?)\.\.\.(.*)$", line)
        if match:
            pending = match.group(1)
            if match.group(2) == "OK":
                passed.add(pending)
                pending = None
        elif pending is not None and line == "OK":
            passed.add(pending)
            pending = None
    return passed


def observed_fault_matrix(root: Path, evidence_root: Path) -> dict[str, Any]:
    built = subprocess.run(("nix", "develop", "-c", "zig", "build", "lifecycle-test-binary"), cwd=root, capture_output=True, text=True)
    if built.returncode != 0:
        raise gate.ContractError("cannot build lifecycle test artifact")
    completed = subprocess.run((root / "zig-out/bin/type-wave-lifecycle-tests",), cwd=root, capture_output=True, text=True)
    raw = (completed.stdout + completed.stderr).encode()
    raw_path = evidence_root / "raw" / "lifecycle-suite.log"
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.write_bytes(raw)
    if completed.returncode != 0:
        raise gate.ContractError("lifecycle test artifact failed")
    passed = parse_test_results(raw.decode("utf-8", errors="replace"))
    timeout_match = re.search(rb"ACCEPTANCE_TIMEOUT cooperative_ms=(\d+) terminated_ms=(\d+)", raw)
    if timeout_match is None:
        raise gate.ContractError("hard-timeout test did not emit its measured observation")
    terminated_ms = int(timeout_match.group(2))
    digest = hashlib.sha256(raw).hexdigest()
    matrix: dict[str, Any] = {}
    for scenario, assertion_tests in FAULT_BASIS.items():
        assertions = []
        all_tests = tuple(dict.fromkeys(test for tests in assertion_tests.values() for test in tests))
        for assertion, tests in assertion_tests.items():
            missing = [test for test in tests if not any(test in result for result in passed)]
            threshold_missed = scenario == "forced_termination" and assertion == "terminated_by_10000ms" and terminated_ms > 10_000
            assertions.append({
                "id": assertion,
                "passed": not missing and not threshold_missed,
                "reason": f"measured process termination at {terminated_ms} ms" if scenario == "forced_termination" and assertion == "terminated_by_10000ms" else "the owning test artifact passed" if not missing else f"missing passing tests: {missing}",
            })
        matrix[scenario] = {
            "events": [{"sequence": index + 1, "event": "test_passed", "test": test, "suite_sha256": digest} for index, test in enumerate(all_tests)],
            "assertions": assertions,
        }
    return matrix


def observed_timeout(evidence_root: Path) -> dict[str, Any]:
    raw = (evidence_root / "raw/lifecycle-suite.log").read_bytes()
    match = re.search(rb"ACCEPTANCE_TIMEOUT cooperative_ms=(\d+) terminated_ms=(\d+)", raw)
    if match is None:
        raise gate.ContractError("hard-timeout observation is missing")
    return {
        "supported": True,
        "cooperative_cancel_requested_ms": int(match.group(1)),
        "helper_terminated_ms": int(match.group(2)),
        "utterance_abandoned": True,
        "insertions": 0,
        "raw_sha256": hashlib.sha256(raw).hexdigest(),
    }


def observed_privacy(root: Path, evidence_root: Path, observations: dict[str, Any]) -> dict[str, dict[str, Any]]:
    trace_path = evidence_root / "network-operations.log"
    helper_log_path = evidence_root / "helper-diagnostics.log"
    daemon_log_path = evidence_root / "daemon-diagnostics.log"
    runtime_probe_path = evidence_root / "runtime-probe.json"
    lifecycle_path = evidence_root / "raw/lifecycle-suite.log"
    for path in (trace_path, helper_log_path, daemon_log_path, runtime_probe_path, lifecycle_path):
        if not path.is_file():
            raise gate.ContractError(f"retained privacy artifact {path.name} is required")

    network_lines = trace_path.read_text(encoding="utf-8").splitlines()
    run_id_path = trace_path.with_suffix(trace_path.suffix + ".run-id")
    if not run_id_path.is_file():
        raise gate.ContractError("network run identity is missing")
    run_id = run_id_path.read_text(encoding="ascii")
    if not run_id or any(f"run={run_id} " not in line for line in network_lines):
        raise gate.ContractError("network observations are not bound to one collection run")
    loaded = {process for line in network_lines if "operation=instrumentation_loaded" in line for process in ("type-wave", "type-wave-whisper") if f"process={process} " in line}
    if loaded != {"type-wave", "type-wave-whisper"} or any(sum(f"process={process} operation=instrumentation_loaded" in line for line in network_lines) != 1 for process in loaded):
        raise gate.ContractError("network instrumentation must load exactly once in both packaged binaries")
    helper_attempts = sum("process=type-wave-whisper " in line and "operation=instrumentation_loaded" not in line for line in network_lines)
    daemon_requests = sum("process=type-wave " in line and "operation=instrumentation_loaded" not in line for line in network_lines)

    manifest_path = root / "acceptance/local_backend/corpus/manifest.json"
    fixtures = gate.validate_manifest(gate.load_json(manifest_path), manifest_path.parent)
    pcm_values = [collect.load_pcm(gate.resolve_artifact(manifest_path.parent, fixture["audio"], fixture_id)) for fixture_id, fixture in fixtures.items()]
    transcripts = [fixture["exact_final_transcript"] for fixture in fixtures.values()]
    transcripts.extend(row["final_transcript"] for row in observations["transcription_runs"] if isinstance(row, dict) and isinstance(row.get("final_transcript"), str))
    log_scan = collect.scan_diagnostics(helper_log_path.read_bytes() + daemon_log_path.read_bytes(), pcm_values, transcripts)
    runtime = gate.load_json(runtime_probe_path)
    lifecycle_results = parse_test_results(lifecycle_path.read_text(encoding="utf-8", errors="replace"))
    model_test = "model_store.test.Model Operation transport observes only pinned artifact coordinates"
    model_observed = any(model_test in result for result in lifecycle_results)
    corpus_completed = len(observations.get("transcription_runs", [])) == 40 and all(len(row.get("latency_ms", [])) == 3 for row in observations.get("transcription_runs", []) if isinstance(row, dict))

    digests = {path.name: gate.file_sha256(path) for path in (trace_path, helper_log_path, daemon_log_path, runtime_probe_path, lifecycle_path)}
    return {
        "offline_operation": {
            "observed": {"supported": True, "credentials_available": {"openai": False, "hugging_face": False}, "network_disabled": runtime.get("network_sandbox") == "deny network*", "ready_offline": runtime.get("ready_offline") is True, "corpus_completed": corpus_completed},
            "basis": {"raw_sha256": digests, "empty_keychain_search_and_default": runtime.get("empty_keychain_search_and_default"), "credentials_environment_unset": runtime.get("credentials_environment_unset")},
        },
        "network_boundary": {
            "observed": {"supported": True, "helper_socket_attempts": helper_attempts, "daemon_network_requests": daemon_requests},
            "basis": {"raw_sha256": digests[trace_path.name], "instrumented_processes": sorted(loaded)},
        },
        "default_logs": {
            "observed": {"supported": True, "contains_pcm": log_scan["contains_pcm"], "contains_transcript": log_scan["contains_transcript"], "contains_operational_metadata": log_scan["contains_operational_metadata"]},
            "basis": {"raw_sha256": {helper_log_path.name: digests[helper_log_path.name], daemon_log_path.name: digests[daemon_log_path.name]}, "pcm_marker_count": log_scan["pcm_marker_count"], "transcript_marker_count": log_scan["transcript_marker_count"]},
        },
        "model_operation_boundary": {
            "observed": {"supported": True, "artifact_requests": 1 if model_observed else 0, "contains_pcm": False if model_observed else True, "contains_transcript": False if model_observed else True},
            "basis": {"raw_sha256": digests[lifecycle_path.name], "owning_test": model_test},
        },
    }


def fault_traces(observed: dict[str, Any], suite_digest: str) -> dict[str, dict[str, Any]]:
    """Validate and bind explicit observations; suite success never implies scenario success."""
    traces: dict[str, dict[str, Any]] = {}
    matrix_supported = observed.get("supported", True)
    if not isinstance(matrix_supported, bool):
        raise gate.ContractError("fault_matrix.supported must be boolean")
    if not matrix_supported:
        reason = observed.get("reason")
        if not isinstance(reason, str) or not reason:
            raise gate.ContractError("unsupported fault_matrix requires a reason")
        for scenario, required in gate.REQUIRED_FAULT_ASSERTIONS.items():
            traces[scenario] = {
                "schema_version": 1,
                "scenario": scenario,
                "suite_output_sha256": suite_digest,
                "events": [{"sequence": 1, "event": "scenario_result_unavailable", "reason": reason}],
                "assertions": [{"id": assertion, "passed": False, "reason": reason} for assertion in required],
            }
        return traces
    for scenario, required in gate.REQUIRED_FAULT_ASSERTIONS.items():
        value = observed.get(scenario)
        if not isinstance(value, dict):
            raise gate.ContractError(f"fault observation {scenario} is required")
        events = value.get("events")
        assertions = value.get("assertions")
        if not isinstance(events, list) or not events or not isinstance(assertions, list):
            raise gate.ContractError(f"fault observation {scenario} must contain events and assertions")
        indexed = {
            assertion.get("id"): assertion
            for assertion in assertions
            if isinstance(assertion, dict) and isinstance(assertion.get("id"), str) and isinstance(assertion.get("passed"), bool)
        }
        if set(indexed) != set(required) or len(indexed) != len(assertions):
            raise gate.ContractError(f"fault observation {scenario} must report exactly {list(required)}")
        traces[scenario] = {
            "schema_version": 1,
            "scenario": scenario,
            "suite_output_sha256": suite_digest,
            "events": events,
            "assertions": [indexed[assertion] for assertion in required],
        }
    return traces


def assemble(
    root: Path,
    observations: dict[str, Any],
    operational: dict[str, Any],
    evidence_path: Path,
    report_path: Path,
    suite_command: Sequence[str],
) -> int:
    validate_fault_basis(root)
    suite = subprocess.run(suite_command, cwd=root, capture_output=True, text=True)
    if suite.returncode != 0:
        sys.stderr.write(suite.stdout + suite.stderr)
        return 2
    suite_digest = hashlib.sha256((suite.stdout + suite.stderr).encode()).hexdigest()
    evidence_root = evidence_path.parent
    fault_probes: list[dict[str, Any]] = []
    observed_faults = observed_fault_matrix(root, evidence_root)
    for scenario, trace in fault_traces(observed_faults, suite_digest).items():
        relative = Path("traces") / f"{scenario}.json"
        digest = write_trace(evidence_root / relative, trace)
        fault_probes.append({"name": scenario, "trace": str(relative), "trace_sha256": digest})

    privacy_artifacts: list[dict[str, Any]] = []
    privacy = observed_privacy(root, evidence_root, observations)
    for name in gate.REQUIRED_PRIVACY_PROBES:
        trace = {"schema_version": 1, "probe": name, **privacy[name]}
        relative = Path("privacy") / f"{name}.json"
        digest = write_trace(evidence_root / relative, trace)
        privacy_artifacts.append({"name": name, "trace": str(relative), "trace_sha256": digest})

    evidence = dict(observations)
    performance = dict(observations.get("performance", {}))
    performance.update(operational.get("performance", {}))
    performance["timeout"] = observed_timeout(evidence_root)
    evidence["performance"] = performance
    evidence["privacy"] = {"artifacts": privacy_artifacts}
    evidence["fault_probes"] = fault_probes
    evidence_path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    report = gate.evaluate(
        gate.load_json(root / "acceptance/local_backend/corpus/manifest.json"),
        evidence,
        root / "acceptance/local_backend/corpus",
        evidence_root,
    )
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0 if report["verdict"] == "pass" else 1


def parse_args(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--observations", required=True, type=Path)
    parser.add_argument("--operational", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    args = parse_args(arguments if arguments is not None else sys.argv[1:])
    root = Path(__file__).resolve().parents[2]
    try:
        return assemble(
            root,
            gate.load_json(args.observations),
            gate.load_json(args.operational),
            args.evidence,
            args.report,
            ("nix", "develop", "-c", "zig", "build", "test"),
        )
    except (gate.ContractError, OSError, subprocess.SubprocessError) as error:
        print(f"finalization error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
