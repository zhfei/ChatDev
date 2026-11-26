"""Exercise publishing without real SSH, credentials, or image builds.

Run: python3 -m unittest discover -s deploy/tests -v
Set CHATDEV_TEST_BASH to an alternate Bash executable/wrapper to test older Bash.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="chatdev-publish-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        source = Path(__file__).resolve().parents[1]
        shutil.copytree(source, self.repo / "deploy")
        shutil.copy(source.parent / ".dockerignore", self.repo / ".dockerignore")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.remote = self.root / "remote"
        self.log = self.root / "calls"
        self.executable("docker", '''echo "$1" >> "$CALLS"
if [[ "$1" == build && "${FAIL_BUILD:-}" == 1 ]]; then exit 42; fi
if [[ "$1" == save ]]; then printf 'test-image'; fi
''')
        self.executable("ssh", '''echo ssh >> "$CALLS"
bash -c "${!#}"
''')
        self.executable("git", "printf 'test-commit\\n'\n")
        (self.repo / ".env").write_text(
            f"DEPLOY_HOST=example.test\nDEPLOY_USER=tester\nDEPLOY_PATH={self.remote}\n"
            "DEPLOY_VERSION=test-release\nBASE_URL=https://example.test/v1\n"
            "API_KEY='test-$literal#key'\n"
        )
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"],
                        CALLS=str(self.log))

    def executable(self, name, script):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + script)
        path.chmod(0o755)

    def publish(self, **env):
        return subprocess.run(
            [os.environ.get("CHATDEV_TEST_BASH", "bash"), "deploy/publish.sh"],
            cwd=self.repo, env=dict(self.env, **env), capture_output=True, text=True,
        )

    def test_success_preserves_literal_secret_and_filters_settings(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.remote / ".env").read_text(),
                         "BASE_URL='https://example.test/v1'\n"
                         "API_KEY='test-$literal#key'\nMAC_ALLOW_UNSAFE_CODE_EXECUTION='0'\n")
        self.assertEqual((self.remote / ".env").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.remote / "VERSION").read_text().strip(), "test-release")
        self.assertFalse(list(self.remote.glob(".upload.*")))
        self.assertNotIn("test-$literal#key", result.stdout + result.stderr)

    def assert_no_upload(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text().splitlines().count("ssh"), 1)
        self.assertFalse((self.remote / "VERSION").exists())

    def test_failed_build_never_uploads(self):
        result = self.publish(FAIL_BUILD="1")
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assert_no_upload(result)

    def test_successful_exit_without_artifacts_never_uploads(self):
        (self.repo / "deploy/build.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
        result = self.publish()
        self.assert_no_upload(result)
        self.assertIn("Build output missing", result.stderr)

    def test_corrupt_archive_never_uploads(self):
        (self.repo / "deploy/build.sh").write_text('''#!/usr/bin/env bash
printf '%s\\n' "$1" > "$2/VERSION"
for name in compose.yaml deploy.sh images.tar.gz; do printf broken > "$2/$name"; done
''')
        result = self.publish()
        self.assert_no_upload(result)
        self.assertIn("Invalid image archive", result.stderr)


if __name__ == "__main__":
    unittest.main()
