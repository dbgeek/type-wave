from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALLER = REPO_ROOT / "packaging" / "install.sh"


class PackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.fake_bin = self.root / "fake-bin"
        self.home.mkdir()
        self.fake_bin.mkdir()
        self.codesign_log = self.root / "codesign.log"

        self._write_tool(
            "security",
            "#!/bin/sh\nprintf '%s\\n' '1) FEEDFACE \"type-wave dev\"'\n",
        )
        self._write_tool(
            "codesign",
            """#!/bin/sh
target=""
for argument in "$@"; do target="$argument"; done
printf '%s\n' "$*" >> "$TYPE_WAVE_TEST_CODESIGN_LOG"
if [ "${TYPE_WAVE_TEST_FAIL_SIGNING_CONTENT:-}" != "" ] &&
   grep -q "$TYPE_WAVE_TEST_FAIL_SIGNING_CONTENT" "$target" 2>/dev/null; then
  exit 42
fi
if [ "${TYPE_WAVE_TEST_FAIL_VERIFY_PATH:-}" = "$target" ]; then
  case " $* " in
    *" --verify "*) exit 43 ;;
  esac
fi
exit 0
""",
        )
        self._write_tool("plutil", "#!/bin/sh\nexit 0\n")

    def _write_tool(self, name: str, body: str) -> None:
        path = self.fake_bin / name
        path.write_text(body)
        path.chmod(0o755)

    def _artifact(self, name: str, contents: str) -> Path:
        path = self.root / name
        path.write_text(contents)
        path.chmod(0o755)
        return path

    @property
    def installed_daemon(self) -> Path:
        return self.home / ".local/bin/type-wave"

    @property
    def installed_helper(self) -> Path:
        return self.home / ".local/libexec/type-wave/type-wave-whisper"

    def _seed_installed_pair(self) -> None:
        self.installed_daemon.parent.mkdir(parents=True)
        self.installed_helper.parent.mkdir(parents=True)
        self.installed_daemon.write_text("OLD_DAEMON")
        self.installed_helper.write_text("OLD_HELPER")

    def _assert_installed_pair(self, daemon: str, helper: str) -> None:
        self.assertEqual(self.installed_daemon.read_text(), daemon)
        self.assertEqual(self.installed_helper.read_text(), helper)

    def _run_installer(
        self,
        daemon: Path,
        helper: Path,
        *,
        fail_signing_content: str | None = None,
        fail_verify_path: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.home),
                "PATH": f"{self.fake_bin}:/usr/bin:/bin",
                "TYPE_WAVE_TEST_CODESIGN_LOG": str(self.codesign_log),
            }
        )
        if fail_signing_content is not None:
            env["TYPE_WAVE_TEST_FAIL_SIGNING_CONTENT"] = fail_signing_content
        if fail_verify_path is not None:
            env["TYPE_WAVE_TEST_FAIL_VERIFY_PATH"] = str(fail_verify_path)
        return subprocess.run(
            ["bash", str(INSTALLER), str(daemon), str(helper)],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_installs_and_signs_daemon_helper_and_provenance_as_one_pair(self) -> None:
        daemon = self._artifact("type-wave", "NEW_DAEMON")
        helper = self._artifact("type-wave-whisper", "NEW_HELPER")

        result = self._run_installer(daemon, helper)

        self.assertEqual(result.returncode, 0, result.stderr)
        self._assert_installed_pair("NEW_DAEMON", "NEW_HELPER")
        self.assertTrue(self.installed_daemon.is_symlink())
        self.assertTrue(self.installed_helper.is_symlink())
        self.assertEqual(
            self.installed_daemon.resolve().parent,
            self.installed_helper.resolve().parent,
        )
        signing = self.codesign_log.read_text()
        self.assertIn("type-wave", signing)
        self.assertIn("type-wave-whisper", signing)

        installed_data = self.home / ".local/share/type-wave"
        self.assertIn("MIT License", (installed_data / "LICENSES/OpenAI-Whisper-MIT.txt").read_text())
        provenance = (installed_data / "PROVENANCE").read_text()
        self.assertIn("ggerganov/whisper.cpp", provenance)
        self.assertIn("ggml-large-v3-turbo.bin", provenance)
        self.assertIn("98aa99a0a9db05ae2342309f5096248665f7cba3", provenance)
        self.assertIn("1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", provenance)
        self.assertIn("whisper.cpp v1.9.1", provenance)
        self.assertIn("147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447", provenance)

    def test_signing_failure_cannot_displace_an_existing_pair(self) -> None:
        self._seed_installed_pair()

        daemon = self._artifact("type-wave", "NEW_DAEMON")
        helper = self._artifact("type-wave-whisper", "NEW_HELPER")
        result = self._run_installer(
            daemon, helper, fail_signing_content="NEW_HELPER"
        )

        self.assertNotEqual(result.returncode, 0)
        self._assert_installed_pair("OLD_DAEMON", "OLD_HELPER")

    def test_upgrade_switches_both_fixed_paths_to_one_new_pair(self) -> None:
        first = self._run_installer(
            self._artifact("type-wave-v1", "DAEMON_V1"),
            self._artifact("type-wave-whisper-v1", "HELPER_V1"),
        )
        self.assertEqual(first.returncode, 0, first.stderr)
        first_pair = self.installed_daemon.resolve().parent

        second = self._run_installer(
            self._artifact("type-wave-v2", "DAEMON_V2"),
            self._artifact("type-wave-whisper-v2", "HELPER_V2"),
        )

        self.assertEqual(second.returncode, 0, second.stderr)
        self._assert_installed_pair("DAEMON_V2", "HELPER_V2")
        self.assertEqual(
            self.installed_daemon.resolve().parent,
            self.installed_helper.resolve().parent,
        )
        self.assertNotEqual(self.installed_daemon.resolve().parent, first_pair)
        self.assertFalse(first_pair.exists())

    def test_published_pair_verification_failure_restores_existing_pair(self) -> None:
        self._seed_installed_pair()

        daemon = self._artifact("type-wave", "NEW_DAEMON")
        helper = self._artifact("type-wave-whisper", "NEW_HELPER")
        result = self._run_installer(
            daemon,
            helper,
            fail_verify_path=self.installed_helper,
        )

        self.assertNotEqual(result.returncode, 0)
        self._assert_installed_pair("OLD_DAEMON", "OLD_HELPER")

    def test_uninstall_guidance_keeps_four_resource_classes_separate(self) -> None:
        guidance = (REPO_ROOT / "docs/packaging.md").read_text()
        uninstall = guidance.split("## Uninstall", maxsplit=1)[1]

        self.assertIn("type-wave-whisper", uninstall)
        self.assertIn("Application Support/type-wave/models", uninstall)
        self.assertIn("openai-api-key", uninstall)
        self.assertIn("Privacy & Security", uninstall)
        self.assertNotIn("huggingface-token", uninstall)
        self.assertNotIn("Hugging Face", uninstall)


if __name__ == "__main__":
    unittest.main()
