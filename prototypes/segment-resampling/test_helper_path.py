from __future__ import annotations

import unittest
import struct

from helper_path import encode_transcribe, fixture_modes, percentile_nearest_rank


class HelperPathStatisticsTests(unittest.TestCase):
    def test_nearest_rank_reports_median_and_tail_from_observations(self) -> None:
        observations = [900, 100, 500, 300, 700]

        self.assertEqual(500, percentile_nearest_rank(observations, 50))
        self.assertEqual(900, percentile_nearest_rank(observations, 95))
        self.assertEqual(900, percentile_nearest_rank(observations, 99))

    def test_transcribe_frame_matches_version_two_prompt_aware_layout(self) -> None:
        frame = encode_transcribe(7, "en", b"\x01\x02")

        magic, version, kind, payload_length = struct.unpack("<4sHHI", frame[:12])
        self.assertEqual((b"TWW1", 2, 3, 17), (magic, version, kind, payload_length))
        self.assertEqual(7, struct.unpack("<Q", frame[12:20])[0])
        self.assertEqual(1, frame[20])
        self.assertEqual(0, struct.unpack("<H", frame[21:23])[0])
        self.assertEqual(2, struct.unpack("<I", frame[23:27])[0])
        self.assertEqual(b"\x01\x02", frame[27:])

    def test_fixture_modes_cover_explicit_language_and_auto_detect(self) -> None:
        fixture: dict[str, object] = {"language_modes": ["sv", "auto"]}

        self.assertEqual(["sv", "auto"], fixture_modes(fixture))


if __name__ == "__main__":
    unittest.main()
