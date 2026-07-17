from __future__ import annotations

import json
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any, Callable
import unittest


HERE = Path(__file__).resolve().parent
GATE = HERE / "gate.py"

# Independent oracle by design: tests pin the externally agreed assertion contract so
# accidentally deleting a production scenario or invariant makes the suite fail.
REQUIRED_FAULT_ASSERTIONS = {
    "successful_lifecycle": ("serialized_phases", "exactly_one_insertion"),
    "empty_capture": ("abandoned", "no_insertion"),
    "empty_final_transcript": ("abandoned", "no_insertion"),
    "helper_loss_during_capture": ("feedback_until_release", "abandoned"),
    "helper_crash": ("abandoned", "restart_scheduled"),
    "malformed_ipc": ("abandoned", "restart_scheduled"),
    "inference_failure": ("abandoned", "restart_scheduled"),
    "restart_backoff_and_latch": ("backoff_1_2_4_seconds", "latched_after_three"),
    "successful_final_resets_failures": ("failure_budget_reset",),
    "cooperative_cancellation": ("cancel_requested_at_9500ms", "abandoned", "no_insertion"),
    "forced_termination": ("terminated_by_10000ms", "abandoned", "no_insertion"),
    "final_timeout_race": ("exactly_one_terminal_winner",),
    "stale_events": ("late_ignored", "duplicate_ignored", "mismatched_id_ignored", "post_cancel_ignored"),
    "non_idle_press": ("press_ignored",),
    "backend_switch": ("lease_stays_pinned", "no_cross_backend_audio", "new_capture_blocked"),
    "prerequisite_loss": ("active_utterance_poisoned", "capture_stopped"),
    "helper_recovery": ("ready_only_after_warmup",),
    "abandonment_has_no_side_effects": ("no_insertion", "no_retry", "no_openai_fallback"),
}
REQUIRED_FAULTS = list(REQUIRED_FAULT_ASSERTIONS)


def manifest() -> dict[str, Any]:
    fixtures: list[dict[str, Any]] = []
    for language in ("en", "sv"):
        for index in range(10):
            duration_class = ("short", "medium", "long")[index % 3]
            fixture_id = f"{language}-{index + 1:02d}"
            if language == "en":
                final_transcript = "Do not delete 42 files!" if index == 0 else f"English fixture number {index + 1}."
                protected = [
                    {"kind": "negation", "text": "not"},
                    {"kind": "number", "text": "42"},
                    {"kind": "command", "text": "delete"},
                ] if index == 0 else []
            else:
                final_transcript = "Kommer du i morgon?" if index == 0 else f"Svenskt exempel nummer {index + 1}."
                protected = []
            fixtures.append({
                "id": fixture_id,
                "audio": f"audio/{fixture_id}.wav",
                "audio_sha256": f"{len(fixtures) + 1:064x}",
                "speaker_id": f"{language}-{1 + index % 2}",
                "language": language,
                "language_modes": [language, "auto"],
                "exact_final_transcript": final_transcript,
                "duration_seconds": {"short": 3.2, "medium": 7.0, "long": 12.0}[duration_class],
                "duration_class": duration_class,
                "punctuation": True,
                "tags": (
                    ["command", "numbers", "negation"] if protected else
                    ["technical-term"] if index == 1 else
                    ["proper-noun"] if index == 2 else
                    ["self-correction"] if index == 3 else
                    ["natural-dictation"]
                ),
                "protected_semantics": protected,
            })
    return {
        "schema_version": 1,
        "corpus": {
            "id": "test-human-corpus-v1",
            "human_speech": True,
            "redistributable": True,
            "license": "CC0-1.0",
        },
        "fixtures": fixtures,
    }


def evidence() -> dict[str, Any]:
    manifest_data = manifest()
    return {
        "schema_version": 1,
        "candidate": {
            "model_revision": "3564d61a42fc210ceaa55a22a96dd64478959c78",
            "model_sha256": "de6911330cbdc131362f7a955682b65c8a5a2394caba73e7ea821a9822efb8c6",
            "model_bytes": 487601984,
            "runtime": "whisper.cpp-v1.9.1",
            "runtime_source_sha256": "147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447",
        },
        "transcription_runs": [
            {
                "fixture_id": fixture["id"],
                "mode": mode,
                "final_transcript": fixture["exact_final_transcript"],
                "meaning_changing_errors": [],
                "latency_ms": [800, 820, 810],
            }
            for fixture in manifest_data["fixtures"]
            for mode in fixture["language_modes"]
        ],
        "performance": {
            "machine": {"chip": "Apple M1", "memory_gib": 8},
            "cached_ready_ms": 420,
            "first_metal_ready_ms": 10830,
            "first_metal_visible_preparing": True,
            "first_metal_capture_accepted": False,
            "idle_rss_mib": 516,
            "peak_rss_mib": 540,
            "timeout": {
                "cooperative_cancel_requested_ms": 9500,
                "helper_terminated_ms": 10000,
                "utterance_abandoned": True,
                "insertions": 0,
            },
        },
        "privacy": {
            "credentials_available": {"openai": False, "hugging_face": False},
            "network_disabled": True,
            "ready_offline": True,
            "corpus_completed": True,
            "helper_socket_attempts": 0,
            "daemon_network_requests": 0,
            "default_log_contains_pcm": False,
            "default_log_contains_transcript": False,
            "default_log_contains_operational_metadata": True,
            "model_operation": {
                "artifact_requests": 1,
                "contains_pcm": False,
                "contains_transcript": False,
            },
        },
        "fault_probes": [{"name": name, "passed": True} for name in REQUIRED_FAULTS],
    }


class GateCliTests(unittest.TestCase):
    def run_gate(self, manifest_data: dict[str, Any], evidence_data: dict[str, Any], tamper_audio_id: str | None = None, tamper_fault_id: str | None = None, tamper_privacy_id: str | None = None) -> tuple[subprocess.CompletedProcess[str], dict[str, Any]]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            evidence_path = root / "evidence.json"
            report_path = root / "report.json"
            materialized_manifest = json.loads(json.dumps(manifest_data))
            materialized_evidence = json.loads(json.dumps(evidence_data))
            for fixture in materialized_manifest["fixtures"]:
                audio_path = root / fixture["audio"]
                audio_path.parent.mkdir(parents=True, exist_ok=True)
                audio = f"test audio for {fixture['id']}".encode()
                audio_path.write_bytes(audio)
                fixture["audio_sha256"] = hashlib.sha256(audio).hexdigest()
                if fixture["id"] == tamper_audio_id:
                    audio_path.write_bytes(b"tampered")
            for probe in materialized_evidence["fault_probes"]:
                trace_path = root / "traces" / f"{probe['name']}.json"
                trace_path.parent.mkdir(parents=True, exist_ok=True)
                trace = {
                    "schema_version": 1,
                    "scenario": probe["name"],
                    "events": [{"sequence": 1, "event": "probe_completed"}],
                    "assertions": [
                        {"id": assertion_id, "passed": probe["passed"] or index > 0}
                        for index, assertion_id in enumerate(REQUIRED_FAULT_ASSERTIONS[probe["name"]])
                    ],
                }
                if probe.pop("extra_failed", False):
                    trace["assertions"].append({"id": "unexpected_invariant", "passed": False})
                probe.pop("passed")
                rendered_trace = json.dumps(trace, sort_keys=True, separators=(",", ":")).encode()
                trace_path.write_bytes(rendered_trace)
                probe["trace"] = str(trace_path.relative_to(root))
                probe["trace_sha256"] = hashlib.sha256(rendered_trace).hexdigest()
                if probe["name"] == tamper_fault_id:
                    trace_path.write_bytes(b"tampered")
            privacy = materialized_evidence["privacy"]
            privacy_observations = {
                "offline_operation": {
                    "credentials_available": privacy["credentials_available"],
                    "network_disabled": privacy["network_disabled"],
                    "ready_offline": privacy["ready_offline"],
                    "corpus_completed": privacy["corpus_completed"],
                },
                "network_boundary": {
                    "helper_socket_attempts": privacy["helper_socket_attempts"],
                    "daemon_network_requests": privacy["daemon_network_requests"],
                },
                "default_logs": {
                    "contains_pcm": privacy["default_log_contains_pcm"],
                    "contains_transcript": privacy["default_log_contains_transcript"],
                    "contains_operational_metadata": privacy["default_log_contains_operational_metadata"],
                },
                "model_operation_boundary": privacy["model_operation"],
            }
            privacy_artifacts = []
            for name, observed in privacy_observations.items():
                trace_path = root / "privacy" / f"{name}.json"
                trace_path.parent.mkdir(parents=True, exist_ok=True)
                trace = {"schema_version": 1, "probe": name, "observed": observed}
                rendered_trace = json.dumps(trace, sort_keys=True, separators=(",", ":")).encode()
                trace_path.write_bytes(rendered_trace)
                privacy_artifacts.append({
                    "name": name,
                    "trace": str(trace_path.relative_to(root)),
                    "trace_sha256": hashlib.sha256(rendered_trace).hexdigest(),
                })
                if name == tamper_privacy_id:
                    trace_path.write_bytes(b"tampered")
            materialized_evidence["privacy"] = {"artifacts": privacy_artifacts}
            manifest_path.write_text(json.dumps(materialized_manifest), encoding="utf-8")
            evidence_path.write_text(json.dumps(materialized_evidence), encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, str(GATE), "--manifest", str(manifest_path), "--evidence", str(evidence_path), "--report", str(report_path)],
                text=True,
                capture_output=True,
                check=False,
            )
            report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.exists() else {}
            return completed, report

    def failed_checks(self, changed: dict[str, Any]) -> set[str]:
        completed, report = self.run_gate(manifest(), changed)
        self.assertEqual(1, completed.returncode)
        return {check["id"] for check in report["checks"] if not check["passed"]}

    def set_nested(self, data: dict[str, Any], path: tuple[str, ...], value: Any) -> None:
        target = data
        for component in path[:-1]:
            target = target[component]
        target[path[-1]] = value

    def change_runs(self, data: dict[str, Any], predicate: Callable[[dict[str, Any]], bool], transform: Callable[[str], str]) -> None:
        for run in data["transcription_runs"]:
            if predicate(run):
                run["final_transcript"] = transform(run["final_transcript"])

    def test_passing_evidence_emits_reproducible_release_report(self) -> None:
        first, first_report = self.run_gate(manifest(), evidence())
        second, second_report = self.run_gate(manifest(), evidence())

        self.assertEqual(0, first.returncode, first.stderr)
        self.assertEqual("pass", first_report["verdict"])
        self.assertTrue(all(check["passed"] for check in first_report["checks"]))
        checks = {check["id"]: check for check in first_report["checks"]}
        self.assertEqual(0.0, checks["quality.wer.en"]["observed"])
        self.assertEqual(1.0, checks["quality.punctuation_f1"]["observed"])
        self.assertEqual(40, len(first_report["utterances"]))
        self.assertEqual(64, len(first_report["corpus"]["manifest_sha256"]))
        self.assertEqual(first_report, second_report)
        self.assertEqual(first.stdout, second.stdout)
        self.assertNotIn("Do not delete", json.dumps(first_report))

    def test_different_pinned_candidate_fails_its_own_gate(self) -> None:
        changed = evidence()
        changed["candidate"]["runtime"] = "whisper.cpp-v1.9.2"

        completed, report = self.run_gate(manifest(), changed)

        self.assertEqual(1, completed.returncode)
        failed = [check["id"] for check in report["checks"] if not check["passed"]]
        self.assertEqual(["candidate.pinned_design"], failed)

    def test_incomplete_corpus_fails_its_own_gate(self) -> None:
        incomplete = manifest()
        incomplete["fixtures"] = incomplete["fixtures"][:-1]
        matching_evidence = evidence()
        matching_evidence["transcription_runs"] = [row for row in matching_evidence["transcription_runs"] if row["fixture_id"] != "sv-10"]

        completed, report = self.run_gate(incomplete, matching_evidence)

        self.assertEqual(1, completed.returncode)
        failed = [check["id"] for check in report["checks"] if not check["passed"]]
        self.assertEqual(["corpus.authoritative_shape"], failed)

    def test_each_quality_threshold_fails_independently(self) -> None:
        cases: list[tuple[str, object]] = [
            ("quality.wer.en", lambda data: self.change_runs(data, lambda run: run["mode"] == "en", lambda _: "wrong words here now")),
            ("quality.wer.sv", lambda data: self.change_runs(data, lambda run: run["mode"] == "sv", lambda _: "helt fel text nu")),
            ("quality.wer.auto:en", lambda data: self.change_runs(data, lambda run: run["mode"] == "auto" and run["fixture_id"].startswith("en-"), lambda _: "wrong words here now")),
            ("quality.wer.auto:sv", lambda data: self.change_runs(data, lambda run: run["mode"] == "auto" and run["fixture_id"].startswith("sv-"), lambda _: "helt fel text nu")),
            ("quality.per_utterance_wer", lambda data: self.change_runs(data, lambda run: run["fixture_id"] == "en-02" and run["mode"] == "en", lambda _: "English fixture wrong words.")),
            ("quality.punctuation_f1", lambda data: self.change_runs(data, lambda _: True, lambda value: value.rstrip(".?!:;,"))),
            ("quality.protected_semantics", lambda data: next(run for run in data["transcription_runs"] if run["fixture_id"] == "en-01").update(meaning_changing_errors=["negation"])),
        ]
        for expected, mutate in cases:
            with self.subTest(expected):
                changed = evidence()
                mutate(changed)
                self.assertIn(expected, self.failed_checks(changed))

    def test_each_performance_threshold_fails_independently(self) -> None:
        cases = [
            ("performance.base_m1", ("machine", "chip"), "Apple M2"),
            ("performance.cached_ready", ("cached_ready_ms",), 2001),
            ("performance.first_metal_preparation", ("first_metal_ready_ms",), 15001),
            ("performance.idle_rss", ("idle_rss_mib",), 601),
            ("performance.peak_rss", ("peak_rss_mib",), 751),
            ("performance.hard_timeout", ("timeout", "helper_terminated_ms"), 10001),
        ]
        for expected, path, value in cases:
            with self.subTest(expected):
                changed = evidence()
                self.set_nested(changed["performance"], path, value)
                self.assertIn(expected, self.failed_checks(changed))

        changed = evidence()
        changed["transcription_runs"][0]["latency_ms"] = [1999, 2000, 2001]
        self.assertIn("performance.transcription_latency", self.failed_checks(changed))

    def test_each_privacy_threshold_fails_independently(self) -> None:
        cases = [
            ("privacy.offline_operation", ("ready_offline",), False),
            ("privacy.network_boundary", ("helper_socket_attempts",), 1),
            ("privacy.default_logs", ("default_log_contains_transcript",), True),
            ("privacy.model_operation_boundary", ("model_operation", "contains_pcm"), True),
        ]
        for expected, path, value in cases:
            with self.subTest(expected):
                changed = evidence()
                self.set_nested(changed["privacy"], path, value)
                self.assertEqual({expected}, self.failed_checks(changed))

    def test_missing_or_failed_fault_probe_fails_lifecycle_gate(self) -> None:
        missing = evidence()
        missing["fault_probes"] = missing["fault_probes"][:-1]
        self.assertEqual({"lifecycle.deterministic_fault_matrix"}, self.failed_checks(missing))

        failed = evidence()
        failed["fault_probes"][0]["passed"] = False
        self.assertEqual({"lifecycle.deterministic_fault_matrix"}, self.failed_checks(failed))

        extra_failure = evidence()
        extra_failure["fault_probes"][0]["extra_failed"] = True
        self.assertEqual({"lifecycle.deterministic_fault_matrix"}, self.failed_checks(extra_failure))

    def test_tampered_audio_is_rejected_before_scoring(self) -> None:
        completed, report = self.run_gate(manifest(), evidence(), tamper_audio_id="en-01")

        self.assertEqual(2, completed.returncode)
        self.assertEqual({}, report)
        self.assertIn("audio digest does not match", completed.stderr)

    def test_tampered_fault_trace_is_rejected_before_scoring(self) -> None:
        completed, report = self.run_gate(manifest(), evidence(), tamper_fault_id="helper_crash")

        self.assertEqual(2, completed.returncode)
        self.assertEqual({}, report)
        self.assertIn("fault trace digest does not match", completed.stderr)

    def test_tampered_privacy_trace_is_rejected_before_scoring(self) -> None:
        completed, report = self.run_gate(manifest(), evidence(), tamper_privacy_id="default_logs")

        self.assertEqual(2, completed.returncode)
        self.assertEqual({}, report)
        self.assertIn("privacy trace digest does not match", completed.stderr)

    def test_impossible_performance_measurement_is_rejected(self) -> None:
        changed = evidence()
        changed["transcription_runs"][0]["latency_ms"] = [False, 10, 20]

        completed, report = self.run_gate(manifest(), changed)

        self.assertEqual(2, completed.returncode)
        self.assertEqual({}, report)
        self.assertIn("finite non-negative latency", completed.stderr)


if __name__ == "__main__":
    unittest.main()
