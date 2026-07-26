from __future__ import annotations

from collections.abc import Iterator
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALLER = REPO_ROOT / "packaging" / "install.sh"

# Build products and VCS internals are not "the tree" for any question this suite asks of it.
# `zig-pkg` in particular is where the package manager unpacks the *pinned* dependency — the
# opposite of the unpinned second copy the websocket test hunts for.
_NOT_THE_TREE = frozenset({".git", ".zig-cache", "zig-out", "zig-pkg", "__pycache__"})


def _repo_files() -> Iterator[Path]:
    """Every committed-ish file in the repo, with build products pruned as we walk."""
    for directory, subdirectories, names in os.walk(REPO_ROOT):
        subdirectories[:] = [name for name in subdirectories if name not in _NOT_THE_TREE]
        for name in sorted(names):
            yield Path(directory) / name


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
        # The daemon statically links websocket.zig, so its MIT text ships too — it cannot
        # ride along in the fetched package, whose upstream `.paths` omits LICENSE (#290).
        self.assertIn(
            "Karl Seguin",
            (installed_data / "LICENSES/websocket.zig-MIT.txt").read_text(),
        )

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

    # Finding 21 of the security review (#290): the client carrying the API key and every
    # Utterance's audio was the one dependency with no integrity identity, in two
    # independently-editable copies. The url+hash pin is what the package manager verifies —
    # this guards the other half, that there is nothing else for it to drift against.
    def test_the_websocket_client_is_pinned_by_hash_in_exactly_one_place(self) -> None:
        pins: set[tuple[str, str]] = set()
        vendored: list[Path] = []
        for path in _repo_files():
            if path.name == "client.zig" and "websocket.zig" in path.parts:
                vendored.append(path.relative_to(REPO_ROOT))
            if path.name != "build.zig.zon":
                continue
            text = path.read_text()
            if ".websocket = " not in text:
                continue
            where = path.relative_to(REPO_ROOT)
            # Just this dependency's declaration — up to the brace that closes it, so a
            # sibling dependency's url can never be read as the websocket pin.
            declaration = text.split(".websocket = ", maxsplit=1)[1].split("},", maxsplit=1)[0]
            self.assertNotIn(
                ".path",
                declaration,
                f"{where} vendors the websocket client instead of pinning it by hash",
            )
            url = re.search(r'\.url = "([^"]+)"', declaration)
            digest = re.search(r'\.hash = "([^"]+)"', declaration)
            self.assertIsNotNone(url, f"{where} declares websocket without a .url")
            self.assertIsNotNone(digest, f"{where} declares websocket without a .hash")
            assert url is not None and digest is not None  # narrowed for --strict
            # A short sha resolves today and is ambiguous later; the pin records the whole one.
            self.assertRegex(
                url.group(1),
                r"/archive/[0-9a-f]{40}\.tar\.gz$",
                f"{where} pins websocket at something other than a full commit archive",
            )
            pins.add((url.group(1), digest.group(1)))

        self.assertEqual(len(pins), 1, f"the repo carries {len(pins)} different websocket pins")
        self.assertEqual(vendored, [], "a second, unpinned copy of the websocket client is in the tree")

    # The CI gate switch skips Markdown as inert, which is true of every doc except the ones
    # this suite asserts on: those are test inputs, and a PR editing one has to run the gate.
    # ci.yml carves them out by name; this keeps that carve-out honest from the other end, so
    # a new doc read here fails until the workflow knows about it.
    def test_gate_covers_the_docs_this_suite_reads(self) -> None:
        read_docs = set(re.findall(r'REPO_ROOT / "(docs/[^"]+)"', Path(__file__).read_text()))
        self.assertTrue(read_docs, "expected this suite to read at least one repository doc")

        workflow = (REPO_ROOT / ".github/workflows/ci.yml").read_text()
        carve_out = [line for line in workflow.splitlines() if line.strip().startswith("GATE_INPUT_DOCS=")]
        self.assertEqual(len(carve_out), 1, "expected exactly one GATE_INPUT_DOCS line in ci.yml")

        # The carve-out is a grep -E pattern; drop the escapes and compare literal paths.
        covered = carve_out[0].replace("\\", "")
        for doc in sorted(read_docs):
            self.assertIn(doc, covered, f"{doc} is a gate input but ci.yml would skip PRs touching it")


if __name__ == "__main__":
    unittest.main()
