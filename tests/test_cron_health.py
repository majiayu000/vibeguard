#!/usr/bin/env python3
"""Unmanaged cron diagnostics must inspect commands without executing them."""

import contextlib
import importlib.util
import io
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "cron_health", Path(__file__).resolve().parents[1] / "scripts/setup/cron_health.py"
)
cron_health = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cron_health)


class CronHealthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.target = Path(self.temp.name) / "checkout with spaces/scripts/gc/gc-scheduled.sh"
        self.target.parent.mkdir(parents=True)
        self.target.write_text("#!/bin/sh\nexit 0\n")
        self.target.chmod(0o600)

    def test_missing_target_reports_broken_with_line_number(self):
        self.target.unlink()
        rows = cron_health.inspect_entries(f"# header\n0 3 * * 0 /bin/bash {shlex.quote(str(self.target))} --scheduled")
        self.assertEqual(len(rows), 1)
        self.assertIn("[BROKEN] Unmanaged GC cron line 2", rows[0])
        self.assertIn(str(self.target), rows[0])

    def test_interpreted_quoted_target_does_not_need_executable_bit(self):
        rows = cron_health.inspect_entries(f"@weekly /bin/bash {shlex.quote(str(self.target))} --scheduled")
        self.assertEqual(len(rows), 1)
        self.assertIn("[WARN]", rows[0])
        self.assertIn("script exists:", rows[0])
        self.assertIn("user-managed", rows[0])

    def test_direct_target_requires_execute_permission(self):
        entry = f"@reboot {shlex.quote(str(self.target))} --scheduled"
        self.assertIn("not executable", cron_health.inspect_entries(entry)[0])
        self.target.chmod(0o700)
        self.assertIn("script exists:", cron_health.inspect_entries(entry)[0])

    def test_comments_environment_and_unrelated_arguments_are_ignored(self):
        target = shlex.quote(str(self.target))
        entries = f"# 0 3 * * 0 /bin/bash {target}\nMAILTO='gc-scheduled.sh'\n0 3 * * 0 echo {target}\n0 3 * * 0 /bin/true # {target}\n"
        self.assertEqual(cron_health.inspect_entries(entries), [])

    def test_multiple_entries_are_all_reported(self):
        entry = f"0 3 * * 0 /bin/bash {shlex.quote(str(self.target))}"
        self.assertEqual(len(cron_health.inspect_entries(entry + "\n" + entry)), 2)

    def test_shell_expansion_is_not_executed_or_reported_as_missing(self):
        marker = Path(self.temp.name) / "must-not-exist"
        target = f'"$(touch {marker})/scripts/gc/gc-scheduled.sh"'
        rows = cron_health.inspect_entries(f"0 3 * * 0 /bin/bash {target}")
        self.assertIn("needs shell resolution", rows[0])
        self.assertFalse(marker.exists())

    def test_unparseable_gc_command_is_visible(self):
        rows = cron_health.inspect_entries("@weekly /bin/bash '/missing/scripts/gc/gc-scheduled.sh")
        self.assertIn("cannot parse script target", rows[0])

    def run_cli(self, *, result=None, error=None):
        output = io.StringIO()
        with mock.patch.object(cron_health.shutil, "which", return_value="/usr/bin/crontab"), \
             mock.patch.object(cron_health.subprocess, "run", return_value=result, side_effect=error) as run, \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = cron_health.main()
        self.assertEqual(run.call_args.args[0], ["/usr/bin/crontab", "-l"])
        self.assertFalse(run.call_args.kwargs.get("shell", False))
        return code, output.getvalue()

    def test_no_crontab_is_normal(self):
        code, output = self.run_cli(result=subprocess.CompletedProcess([], 1, "", "crontab: no crontab for test"))
        self.assertEqual((code, output), (0, ""))

    def test_crontab_permission_error_is_not_silenced(self):
        code, output = self.run_cli(result=subprocess.CompletedProcess([], 1, "", "permission denied"))
        self.assertEqual(code, 1)
        self.assertIn("Cannot read user crontab", output)

    def test_crontab_timeout_is_not_silenced(self):
        code, output = self.run_cli(error=subprocess.TimeoutExpired(["crontab", "-l"], 10))
        self.assertEqual(code, 1)
        self.assertIn("TimeoutExpired", output)

    def test_crontab_unavailable_is_optional(self):
        with mock.patch.object(cron_health.shutil, "which", return_value=None):
            self.assertEqual(cron_health.main(), 0)


if __name__ == "__main__":
    unittest.main()
