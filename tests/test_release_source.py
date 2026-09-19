from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/verify_release_source.sh"


class ReleaseSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vibeguard-release-source-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release@example.invalid")
        self.git("config", "core.hooksPath", str(self.repo / "no-hooks"))
        self.git("commit", "--allow-empty", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("commit", "--allow-empty", "-qm", "main tip")
        self.tip = self.git("rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/main", self.tip)
        self.git("tag", "release")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env,
                              text=True, capture_output=True, check=True).stdout.strip()

    def verify(self, ref, tag="release"):
        return subprocess.run(["bash", str(SCRIPT), ref, tag], cwd=self.repo, env=self.env,
                              text=True, capture_output=True, check=False)

    def test_main_commit_and_ancestor_tags_pass(self):
        self.assertEqual(self.verify(self.tip).returncode, 0)
        self.git("tag", "light", self.base)
        self.git("tag", "-am", "annotated", "annotated", self.base)
        self.git("checkout", "--detach", self.base)
        self.git("tag", "-f", "release", self.base)
        for ref in (self.base, "refs/tags/light", "refs/tags/annotated"):
            with self.subTest(ref=ref):
                result = self.verify(ref, ref.removeprefix("refs/tags/") if ref.startswith("refs/tags/") else "release")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_unmerged_commit_and_tags_fail(self):
        self.git("checkout", "--detach", self.base)
        self.git("commit", "--allow-empty", "-qm", "unmerged")
        self.git("tag", "light")
        self.git("tag", "-am", "annotated", "annotated")
        self.git("tag", "-f", "release")
        for ref in ("HEAD", "refs/tags/light", "refs/tags/annotated"):
            with self.subTest(ref=ref):
                result = self.verify(ref, ref.removeprefix("refs/tags/") if ref.startswith("refs/tags/") else "release")
                self.assertEqual(result.returncode, 1)
                self.assertIn("not reachable", result.stderr)

    def test_mismatched_checkout_fails(self):
        result = self.verify(self.base)
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match", result.stderr)

    def test_missing_history_fails(self):
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        result = self.verify(self.tip)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not verify", result.stderr)

    def test_moved_tag_fails_even_when_both_commits_are_on_main(self):
        self.git("tag", "-f", "release", self.base)
        result = self.verify(self.tip)
        self.assertEqual(result.returncode, 1)
        self.assertIn("tag does not match", result.stderr)

    def test_missing_and_non_commit_tags_fail(self):
        self.git("tag", "-d", "release")
        self.assertNotEqual(self.verify(self.tip).returncode, 0)
        tree = self.git("rev-parse", "HEAD^{tree}")
        self.git("tag", "release", tree)
        self.assertNotEqual(self.verify(self.tip).returncode, 0)

    def test_refresh_detects_a_tag_moved_during_build(self):
        remote = self.repo / "origin.git"
        self.git("clone", "--bare", str(self.repo), str(remote))
        self.git("remote", "add", "origin", str(remote))
        self.git("--git-dir", str(remote), "update-ref", "refs/tags/release", self.base)
        self.assertEqual(self.verify(self.tip).returncode, 0)
        self.git("fetch", "--no-tags", "origin",
                 "+refs/heads/main:refs/remotes/origin/main",
                 "+refs/tags/release:refs/tags/release")
        result = self.verify(self.tip)
        self.assertEqual(result.returncode, 1)
        self.assertIn("tag does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
