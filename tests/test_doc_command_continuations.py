"""Static documentation fixtures; none of their shell commands are executed."""

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "scripts/ci/validate_docs.py"
SPEC = importlib.util.spec_from_file_location("doc_command_validator", SOURCE)
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


class DocCommandContinuationTests(unittest.TestCase):
    def fixture(self, command, filename="README.md"):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "scripts").mkdir()
        (root / "eval").mkdir()
        (root / "scripts/present.sh").write_text("# Inert fixture, never executed.\n")
        path = root / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"\x60\x60\x60bash\n{command}\n\x60\x60\x60\n")
        return root

    def test_wrapped_literal_commands_report_the_same_missing_path(self):
        commands = [
            "bash scripts/missing.sh",
            "bash " + "\\" + "\n scripts/missing.sh",
            "bash scripts/" + "\\" + "\nmissing.sh",
            "python3 " + "\\" + "\n eval/missing.py",
            "pyth" + "\\" + "\non3 eval/missing.py",
        ]
        for command in commands:
            with self.subTest(command=command), patch.object(validator, "ROOT", self.fixture(command)):
                errors = validator.errors("commands")
                self.assertEqual(len(errors), 1)
                self.assertIn("missing command", errors[0])
                with patch.object(sys, "argv", [str(SOURCE), "commands"]), \
                        contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as status:
                    validator.main()
                self.assertEqual(status.exception.code, 1)

    def test_existing_targets_and_existing_scope_exclusions_are_preserved(self):
        controls = [
            ("bash " + "\\" + "\n scripts/present.sh", "README.md"),
            ("bash scripts/" + "\\" + "\npresent.sh", "README.md"),
            ("bash scripts/<SCRIPT>.sh", "README.md"),
            ("bash scripts/${SCRIPT}.sh", "README.md"),
            ('bash "scripts/missing.sh"', "README.md"),
            ("sh scripts/missing.sh", "README.md"),
            ("bash " + "\\" + "\n scripts/missing.sh", "plan/example.md"),
        ]
        for command, filename in controls:
            with self.subTest(command=command, filename=filename), \
                    patch.object(validator, "ROOT", self.fixture(command, filename)):
                self.assertEqual(validator.errors("commands"), [])

    def test_link_checks_do_not_unfold_command_text(self):
        root = self.fixture("bash " + "\\" + "\n scripts/missing.sh")
        with patch.object(validator, "ROOT", root):
            self.assertEqual(validator.errors("links"), [])


if __name__ == "__main__":
    unittest.main()
