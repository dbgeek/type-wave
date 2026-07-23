from __future__ import annotations

import hashlib
import json
from pathlib import Path
import stat
import tempfile
import textwrap
from unittest import mock
import unittest
import wave

from acceptance.local_backend import collect

class CollectTests(unittest.TestCase):
    def test_cli_collects_three_runs_per_fixture_through_helper_protocol(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "fixture.wav"
            with wave.open(str(audio), "wb") as destination:
                destination.setparams((1, 2, 24_000, 0, "NONE", "not compressed"))
                destination.writeframes(b"\0\0" * 240)
            digest = hashlib.sha256(audio.read_bytes()).hexdigest()
            fixtures = []
            for language in ("en", "sv"):
                for index in range(10):
                    duration_class, duration = (("short", 1), ("medium", 6), ("long", 11))[index % 3]
                    fixtures.append({
                        "id": f"{language}-{index:02d}",
                        "audio": audio.name,
                        "audio_sha256": digest,
                        "speaker_id": f"{language}-{index % 2}",
                        "language": language,
                        "language_modes": [language, "auto"],
                        "exact_final_transcript": "Do not delete three files!",
                        "duration_seconds": duration,
                        "duration_class": duration_class,
                        "punctuation": True,
                        "tags": ["natural-dictation", "technical-term", "proper-noun", "numbers", "self-correction", "negation", "command"],
                        "protected_semantics": [
                            {"kind": "negation", "text": "not"},
                            {"kind": "number", "text": "three"},
                            {"kind": "command", "text": "delete"},
                        ],
                    })
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({
                "schema_version": 1,
                "corpus": {"id": "collector-test", "human_speech": True, "redistributable": True, "license": "CC0-1.0"},
                "fixtures": fixtures,
            }), encoding="utf-8")
            fake_helper = root / "fake-helper.py"
            fake_helper.write_text(textwrap.dedent("""\
                #!/usr/bin/env python3
                import struct, sys
                digest = bytes.fromhex("1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
                sys.stdout.buffer.write(struct.pack("<4sHHI", b"TWW1", 2, 1, len(digest)) + digest)
                sys.stdout.buffer.flush()
                count = 0
                while True:
                    header = sys.stdin.buffer.read(12)
                    if not header:
                        break
                    _, _, kind, length = struct.unpack("<4sHHI", header)
                    payload = sys.stdin.buffer.read(length)
                    assert kind == 3
                    request_id = struct.unpack("<Q", payload[:8])[0]
                    text = (b"Do not delete three files!" if count % 2 == 0 else b"Do not delete three files.")
                    count += 1
                    response = struct.pack("<QI", request_id, len(text)) + text
                    sys.stdout.buffer.write(struct.pack("<4sHHI", b"TWW1", 2, 5, len(response)) + response)
                    sys.stdout.buffer.flush()
                """), encoding="utf-8")
            fake_helper.chmod(fake_helper.stat().st_mode | stat.S_IXUSR)
            review = root / "review.json"
            review.write_text(json.dumps({
                "schema_version": 1,
                "review_method": "manual_reference_comparison",
                "reviews": [
                    {"fixture_id": fixture["id"], "mode": mode, "meaning_changing_errors": []}
                    for fixture in fixtures for mode in fixture["language_modes"]
                ],
            }), encoding="utf-8")
            with mock.patch.object(collect, "collect_identity", return_value={"same_packaged_pair": True}):
                observed = collect.collect(
                    manifest,
                    fake_helper,
                    root / "unused-daemon",
                    root / "unused-model",
                    root / "unused-receipt",
                    root / "unused-provenance",
                    review,
                )
            self.assertEqual(40, len(observed["transcription_runs"]))
            self.assertTrue(all(len(row["latency_ms"]) == 3 for row in observed["transcription_runs"]))
            self.assertEqual(
                ["Do not delete three files!", "Do not delete three files.", "Do not delete three files!"],
                observed["transcription_runs"][0]["final_transcript_runs"],
            )
            self.assertEqual("whisper.cpp-v1.9.1", observed["candidate"]["runtime"])
            self.assertGreater(observed["performance"]["peak_rss_mib"], 0)
            self.assertFalse(observed["default_diagnostics_scan"]["contains_transcript"])

    def test_diagnostics_scan_checks_encoded_and_partial_corpus_content(self) -> None:
        pcm = bytes(range(128))
        references = ["Do not delete three files!"]

        encoded_pcm = __import__("base64").b64encode(pcm[64:128])
        scan = collect.scan_diagnostics(encoded_pcm + b" delete three files ", [pcm], references)

        self.assertTrue(scan["contains_pcm"])
        self.assertTrue(scan["contains_transcript"])

        swedish = collect.scan_diagnostics(" VIKTIG  ÄNDRING  KOMMER ".encode(), [], ["En viktig ändring kommer"])
        self.assertTrue(swedish["contains_transcript"])

        word_pair = collect.scan_diagnostics(" VIKTIG ÄNDRING ".encode(), [], ["En viktig ändring kommer"])
        self.assertFalse(word_pair["contains_transcript"])

        operational = collect.scan_diagnostics(b"auto-detected language: is (p = 0.98) for the run", [], ["There is a plan for the party"])
        self.assertFalse(operational["contains_transcript"])

    def test_helper_rejects_diagnostics_that_cannot_be_fully_retained(self) -> None:
        helper = object.__new__(collect.Helper)
        helper.stderr = bytearray()
        helper.stderr_overflow = False
        helper.process = mock.Mock()
        helper.process.stderr = __import__("io").BytesIO(b"x" * (collect.MAX_STDERR_BYTES + 1))

        helper._drain_stderr()

        self.assertTrue(helper.stderr_overflow)

    def test_helper_rejects_truncated_and_non_utf8_final_frames(self) -> None:
        for response_expression, expected in (
            ("b'bad'", "without a request identity"),
            ("struct.pack('<QI', request_id, 1) + b'\\xff'", "non-UTF-8"),
        ):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fake_helper = root / "fake-helper.py"
                fake_helper.write_text(textwrap.dedent(f"""\
                    #!/usr/bin/env python3
                    import struct, sys
                    digest = bytes.fromhex("1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
                    sys.stdout.buffer.write(struct.pack("<4sHHI", b"TWW1", 2, 1, len(digest)) + digest)
                    sys.stdout.buffer.flush()
                    header = sys.stdin.buffer.read(12)
                    _, _, _, length = struct.unpack("<4sHHI", header)
                    payload = sys.stdin.buffer.read(length)
                    request_id = struct.unpack("<Q", payload[:8])[0]
                    response = {response_expression}
                    sys.stdout.buffer.write(struct.pack("<4sHHI", b"TWW1", 2, 5, len(response)) + response)
                    sys.stdout.buffer.flush()
                    """), encoding="utf-8")
                fake_helper.chmod(fake_helper.stat().st_mode | stat.S_IXUSR)
                helper = collect.Helper(fake_helper, root / "unused-model")
                with self.assertRaisesRegex(collect.CollectionError, expected):
                    helper.transcribe(b"\0\0", "en")
                helper.close()

    def test_helper_bounds_inference_wait(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_helper = root / "fake-helper.py"
            fake_helper.write_text(textwrap.dedent("""\
                #!/usr/bin/env python3
                import struct, sys, time
                digest = bytes.fromhex("1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
                sys.stdout.buffer.write(struct.pack("<4sHHI", b"TWW1", 2, 1, len(digest)) + digest)
                sys.stdout.buffer.flush()
                header = sys.stdin.buffer.read(12)
                _, _, _, length = struct.unpack("<4sHHI", header)
                sys.stdin.buffer.read(length)
                time.sleep(1)
                """), encoding="utf-8")
            fake_helper.chmod(fake_helper.stat().st_mode | stat.S_IXUSR)
            helper = collect.Helper(fake_helper, root / "unused-model")
            with mock.patch.object(collect, "INFERENCE_TIMEOUT_SECONDS", 0.05):
                with self.assertRaisesRegex(collect.CollectionError, "timed out"):
                    helper.transcribe(b"\0\0", "en")
            helper.close()


if __name__ == "__main__":
    unittest.main()
