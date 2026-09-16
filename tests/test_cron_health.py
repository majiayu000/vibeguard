#!/usr/bin/env python3
"""Unmanaged cron diagnostics must inspect commands without executing them."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest


CHECK = Path(__file__).resolve().parents[1] / "scripts/setup/cron_health.sh"
BASH = shutil.which("bash")


class CronHealthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / "checkout with spaces/scripts/gc/gc-scheduled.sh"
        self.target.parent.mkdir(parents=True)
        self.target.write_text("#!/bin/sh\nexit 0\n")
        self.target.chmod(0o600)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.fixture = self.root / "crontab"
        self.fixture.write_text("")
        self.calls = self.root / "calls"
        self.reader_pid = self.root / "reader-pid"
        stub = self.bin / "crontab"
        stub.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$CRON_TEST_CALLS"
printf '%s\\n' "$$" > "$CRON_TEST_READER_PID"
[ "$#" -eq 1 ] && [ "$1" = -l ] || exit 99
case "$CRON_TEST_MODE" in
  absent) printf 'crontab: no crontab for test\\n' >&2; exit 1 ;;
  denied) printf 'permission denied\\n' >&2; exit 1 ;;
  timeout) exec /bin/sleep 30 ;;
esac
cat "$CRON_TEST_FILE"
''')
        stub.chmod(0o700)
        python = self.bin / "python3"
        python.write_text('#!/bin/sh\nprintf "python unexpectedly executed\\n" >&2\nexit 127\n')
        python.chmod(0o700)
        self.env = {
            **os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
            "CRON_TEST_FILE": str(self.fixture), "CRON_TEST_CALLS": str(self.calls),
            "CRON_TEST_READER_PID": str(self.reader_pid),
            "CRON_TEST_MODE": "normal",
        }

    def run_cli(self, mode="normal"):
        result = subprocess.run(
            [BASH, str(CHECK)], env={**self.env, "CRON_TEST_MODE": mode},
            capture_output=True, text=True, timeout=25,
        )
        self.assertTrue(all(line == "-l" for line in self.calls.read_text().splitlines()))
        self.assertNotIn("python unexpectedly executed", result.stdout + result.stderr)
        return result.returncode, result.stdout + result.stderr

    def inspect_entries(self, entries):
        self.fixture.write_text(entries)
        code, output = self.run_cli()
        self.assertEqual(code, 0, output)
        self.assertEqual(self.fixture.read_text(), entries)
        return output.splitlines()

    def test_missing_target_reports_broken_with_line_number(self):
        self.target.unlink()
        rows = self.inspect_entries(f"# header\n0 3 * * 0 /bin/bash {shlex.quote(str(self.target))} --scheduled")
        self.assertEqual(len(rows), 1)
        self.assertIn("[BROKEN] Unmanaged GC cron line 2", rows[0])
        self.assertIn(str(self.target), rows[0])

    def test_interpreted_quoted_target_does_not_need_executable_bit(self):
        rows = self.inspect_entries(f"@weekly /bin/bash {shlex.quote(str(self.target))} --scheduled")
        self.assertEqual(len(rows), 1)
        self.assertIn("[WARN]", rows[0])
        self.assertIn("script exists:", rows[0])
        self.assertIn("user-managed", rows[0])

    def test_direct_target_requires_execute_permission(self):
        entry = f"@reboot {shlex.quote(str(self.target))} --scheduled"
        self.assertIn("not executable", self.inspect_entries(entry)[0])
        self.target.chmod(0o700)
        self.assertIn("script exists:", self.inspect_entries(entry)[0])

    def test_quoted_escaped_paths_and_redirections_are_read_only(self):
        output = self.root / "must-not-be-created.log"
        for target in (shlex.quote(str(self.target)), f'"{self.target}"', str(self.target).replace(" ", "\\ ")):
            with self.subTest(target=target):
                rows = self.inspect_entries(f"0 3 * * 0 /bin/bash {target} --scheduled>{output}")
                self.assertEqual(len(rows), 1)
                self.assertIn("script exists:", rows[0])
                self.assertFalse(output.exists())

    def test_apostrophe_in_quoted_path_is_preserved(self):
        target = self.root / "user's checkout/scripts/gc/gc-scheduled.sh"
        target.parent.mkdir(parents=True)
        target.write_text("exit 0\n")
        rows = self.inspect_entries(f"@weekly /bin/bash {shlex.quote(str(target))}")
        self.assertIn(f"script exists: {target}", rows[0])

    def test_comments_environment_and_unrelated_arguments_are_ignored(self):
        target = shlex.quote(str(self.target))
        entries = f"# 0 3 * * 0 /bin/bash {target}\nMAILTO='gc-scheduled.sh'\n0 3 * * 0 echo {target}\n0 3 * * 0 /bin/true # {target}\n"
        self.assertEqual(self.inspect_entries(entries), [])

    def test_multiple_entries_are_all_reported(self):
        entry = f"0 3 * * 0 /bin/bash {shlex.quote(str(self.target))}"
        self.assertEqual(len(self.inspect_entries(entry + "\n" + entry)), 2)

    def test_shell_expansion_is_not_executed_or_reported_as_missing(self):
        marker = self.root / "must-not-exist"
        target = f'"$(touch {marker})/scripts/gc/gc-scheduled.sh"'
        rows = self.inspect_entries(f"0 3 * * 0 /bin/bash {target}")
        self.assertIn("needs shell resolution", rows[0])
        self.assertFalse(marker.exists())

    def test_unparseable_gc_command_is_visible(self):
        rows = self.inspect_entries("@weekly /bin/bash '/missing/scripts/gc/gc-scheduled.sh")
        self.assertIn("cannot parse script target", rows[0])

    def test_no_crontab_is_normal(self):
        self.assertEqual(self.run_cli("absent"), (0, ""))

    def test_crontab_permission_error_is_not_silenced(self):
        code, output = self.run_cli("denied")
        self.assertEqual(code, 1)
        self.assertIn("Cannot read user crontab", output)

    def test_crontab_timeout_is_not_silenced(self):
        started = time.monotonic()
        code, output = self.run_cli("timeout")
        self.assertEqual(code, 1)
        self.assertIn("timed out after 10s", output)
        self.assertLess(time.monotonic() - started, 25)

    def test_crontab_unavailable_is_optional(self):
        (self.bin / "crontab").unlink()
        result = subprocess.run([BASH, str(CHECK)], env={**self.env, "PATH": str(self.bin)},
                                capture_output=True, text=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_interrupted_check_reaps_its_reader(self):
        process = subprocess.Popen([BASH, str(CHECK)], env={**self.env, "CRON_TEST_MODE": "timeout"},
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not self.reader_pid.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(self.reader_pid.exists())
            reader_pid = int(self.reader_pid.read_text())
            process.terminate()
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143)
            with self.assertRaises(ProcessLookupError):
                os.kill(reader_pid, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
