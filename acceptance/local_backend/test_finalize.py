from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from acceptance.local_backend import finalize


ROOT = Path(__file__).resolve().parents[2]


class FinalizeTests(unittest.TestCase):
    def test_every_fault_trace_is_bound_to_a_checked_in_test(self) -> None:
        finalize.validate_fault_basis(ROOT)
        self.assertEqual(set(finalize.gate.REQUIRED_FAULTS), set(finalize.FAULT_BASIS))

    def test_trace_rendering_is_canonical_and_digest_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "trace.json"
            first = {"schema_version": 1, "observed": {"ready": True, "requests": 0}}
            digest = finalize.write_trace(path, first)

            self.assertEqual(finalize.hashlib.sha256(path.read_bytes()).hexdigest(), digest)
            self.assertEqual(first, json.loads(path.read_text(encoding="utf-8")))

    def test_fault_traces_preserve_observed_results_instead_of_promoting_suite_success(self) -> None:
        observed = {
            scenario: {
                "events": [{"sequence": 1, "event": "not_individually_observed"}],
                "assertions": [
                    {"id": assertion, "passed": False, "reason": "aggregate suite output has no per-test result"}
                    for assertion in assertions
                ],
            }
            for scenario, assertions in finalize.gate.REQUIRED_FAULT_ASSERTIONS.items()
        }
        traces = finalize.fault_traces(observed, "abc123")

        self.assertFalse(traces["forced_termination"]["assertions"][0]["passed"])
        self.assertEqual("abc123", traces["forced_termination"]["suite_output_sha256"])

    def test_fault_traces_require_every_assertion_as_an_observation(self) -> None:
        with self.assertRaisesRegex(finalize.gate.ContractError, "successful_lifecycle"):
            finalize.fault_traces({}, "abc123")

    def test_explicitly_unsupported_matrix_fails_every_assertion(self) -> None:
        traces = finalize.fault_traces(
            {"supported": False, "reason": "runner retained only aggregate success"}, "abc123"
        )

        self.assertTrue(all(
            not assertion["passed"]
            for trace in traces.values()
            for assertion in trace["assertions"]
        ))


if __name__ == "__main__":
    unittest.main()
