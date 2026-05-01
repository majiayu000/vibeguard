#!/usr/bin/env python3
"""Tests for the constraint recommender diagnostics contract."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).with_name("constraint-recommender.py")
SPEC = importlib.util.spec_from_file_location("constraint_recommender", SCRIPT_PATH)
assert SPEC and SPEC.loader
constraint_recommender = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(constraint_recommender)


class ConstraintRecommenderDiagnosticsTest(unittest.TestCase):
    def test_package_parse_failure_records_diagnostic(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / "package.json").write_text("{not valid json", encoding="utf-8")

            diagnostics: list[dict] = []
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                languages = constraint_recommender.detect_languages(
                    str(project),
                    diagnostics,
                )

            self.assertEqual(
                languages,
                [{"language": "javascript", "framework": "node", "config": "package.json"}],
            )
            self.assertEqual(len(diagnostics), 1)
            self.assertEqual(diagnostics[0]["stage"], "parse package.json")
            self.assertIn("JSONDecodeError", diagnostics[0]["error"])
            self.assertIn("warning: parse package.json failed", stderr.getvalue())

    def test_json_output_includes_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / "package.json").write_text("{not valid json", encoding="utf-8")

            old_argv = sys.argv
            stdout = io.StringIO()
            stderr = io.StringIO()
            try:
                sys.argv = ["constraint-recommender.py", str(project), "--json"]
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    constraint_recommender.main()
            finally:
                sys.argv = old_argv

            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["diagnostics"][0]["stage"], "parse package.json")
            self.assertIn("warning: parse package.json failed", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
