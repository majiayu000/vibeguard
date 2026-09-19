import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("generator", ROOT / "scripts/generate_rule_docs.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)

class RuleGenerationTests(unittest.TestCase):
    def parse(self, texts):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for name, text in texts.items():
                (directory / name).write_text(text, encoding="utf-8")
            with patch.object(generator, "CANONICAL", directory):
                return generator.parse_rules()

    def test_duplicate_ids_rejected_across_files(self):
        rule = "## U-01: Real rule (review)\nPreserve behavior.\n"
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.parse({"one.md": rule, "two.md": rule})

    def test_empty_and_malformed_rules_fail(self):
        for text in ("## U-01: Topic (review)\n", "## Missing ID\nbody", "# Empty library\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.parse({"one.md": text})

    def test_code_example_is_not_another_rule(self):
        text = "## U-01: Topic (review)\nExplanation.\n```markdown\n## X-99: Example (review)\n```\n"
        rules = self.parse({"one.md": text})
        self.assertEqual([r["id"] for r in rules], ["U-01"])
        self.assertIn("X-99", rules[0]["body"])

    def test_checked_in_outputs_match_canonical_text(self):
        for path, expected in generator.generated_files(generator.parse_rules()).items():
            self.assertEqual(path.read_text(encoding="utf-8"), expected, str(path))

    def test_core_requires_a_real_source_topic(self):
        with self.assertRaises(KeyError):
            generator.generated_files([{"id": "U-01", "body": "Only one."}])

if __name__ == "__main__":
    unittest.main()
