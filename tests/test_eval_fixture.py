import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepare_eval", ROOT / "eval/prepare.py")
prepare_eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_eval)


class EvalFixtureTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cargo"), "Rust toolchain required for fixture behavior checks")
    def test_propagation_acceptance_passes_a_real_caller_and_rejects_fallback(self):
        for body, accepted in (("parse_limit(input)", True),
                               ("Ok(parse_limit(input).unwrap_or(0))", False)):
            with self.subTest(body=body), tempfile.TemporaryDirectory() as temp:
                project = Path(temp) / "task"
                prepare_eval.prepare(project, "error-propagation")
                with (project / "src/lib.rs").open("a") as source:
                    source.write("\npub fn read_limit(input: Option<&str>) -> Result<u32, String> { "
                                 + body + " }\n")
                (project / "tests").mkdir()
                shutil.copyfile(ROOT / "eval/propagation_acceptance.rs",
                                project / "tests/propagation.rs")
                environment = os.environ.copy()
                environment["CARGO_TARGET_DIR"] = str(project / "target")
                result = subprocess.run(["cargo", "test", "--offline", "--quiet"], cwd=project,
                                        env=environment, text=True, capture_output=True, timeout=60)
                self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
                if not accepted:
                    self.assertIn("caller_preserves_valid_values_and_errors", result.stdout)
                    self.assertIn("test result: FAILED", result.stdout)

    def test_task_variants_are_independent_and_existing_destination_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            baseline, propagation = Path(temp) / "baseline", Path(temp) / "propagation"
            prepare_eval.prepare(baseline)
            prepare_eval.prepare(propagation, "error-propagation")
            self.assertIn("Known defect", (baseline / "README.md").read_text())
            self.assertNotIn("Known defect", (propagation / "README.md").read_text())
            for project in (baseline, propagation):
                note = project / "USER_NOTE.txt"
                note.write_text("preserve this edit")
                with self.assertRaises(FileExistsError):
                    prepare_eval.prepare(project)
                self.assertEqual(note.read_text(), "preserve this edit")


if __name__ == "__main__":
    unittest.main()
