from pathlib import Path
import hashlib
import os
import platform
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {
    ("Darwin", "arm64"): "aarch64-apple-darwin",
    ("Darwin", "x86_64"): "x86_64-apple-darwin",
    ("Linux", "x86_64"): "x86_64-unknown-linux-musl",
    ("Linux", "aarch64"): "aarch64-unknown-linux-musl",
}


@unittest.skipUnless((platform.system(), platform.machine()) in TARGETS, "no release target for this platform")
class InstallScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vibeguard-install-")
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.log = self.dir / "runtime-args"
        self.asset = f"vibeguard-{TARGETS[(platform.system(), platform.machine())]}.tar.gz"
        runtime = self.dir / "vibeguard-runtime"
        runtime.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{self.log}"\n')
        runtime.chmod(0o755)
        self.archive = self.dir / self.asset
        with tarfile.open(self.archive, "w:gz") as tar:
            tar.add(runtime, arcname="vibeguard-runtime")

    def publish(self, folder, checksum=None):
        folder.mkdir(parents=True)
        (folder / self.asset).write_bytes(self.archive.read_bytes())
        digest = checksum or hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (folder / "SHA256SUMS").write_text(f"{digest}  {self.asset}\n")

    def run_install(self, *args, **env):
        env = dict(os.environ, VIBEGUARD_RELEASES_URL=f"file://{self.dir / 'releases'}", **env)
        return subprocess.run(["bash", str(ROOT / "install.sh"), *args], env=env,
                              text=True, capture_output=True, check=False)

    def test_latest_release_runs_install_with_forwarded_arguments(self):
        self.publish(self.dir / "releases/latest/download")
        result = self.run_install("claude", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().split(), ["install", "claude", "--dry-run"])

    def test_pinned_version_uses_tagged_release(self):
        self.publish(self.dir / "releases/download/v9.9.9")
        result = self.run_install("codex", VIBEGUARD_VERSION="v9.9.9")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().split(), ["install", "codex"])

    def test_checksum_mismatch_stops_before_running(self):
        self.publish(self.dir / "releases/latest/download", checksum="0" * 64)
        result = self.run_install("claude")
        self.assertEqual(result.returncode, 1)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse(self.log.exists())

    def test_missing_host_prints_usage(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage: install.sh", result.stderr)


class SetupWithoutCargoTests(unittest.TestCase):
    def test_points_to_release_installer(self):
        result = subprocess.run(["/bin/bash", str(ROOT / "setup.sh"), "install", "claude"],
                                env={"PATH": "/usr/bin:/bin", "HOME": os.devnull},
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("cargo", result.stderr)
        self.assertIn(f'bash "{ROOT}/install.sh"', result.stderr)


if __name__ == "__main__":
    unittest.main()
