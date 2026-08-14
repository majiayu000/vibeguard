#!/usr/bin/env python3
"""Focused regression tests for compact rule generation (GH-626)."""

from __future__ import annotations

import dataclasses
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = ROOT / "scripts" / "generate_rule_docs.py"
SPEC = importlib.util.spec_from_file_location("generate_rule_docs", GENERATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load generator module: {GENERATOR_PATH}")
generate_rule_docs = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = generate_rule_docs
SPEC.loader.exec_module(generate_rule_docs)


EXPECTED_COMPACT_TABLE = """| ID | Severity | Rule |
|----|----------|------|
| U-17 | Strict | Handle errors completely. Do not swallow exceptions silently. |
| U-26 | Strict | Declaration-execution completeness: declared Config / Trait / persistence layers must be wired into startup. |
| U-29 | Strict | No silent degradation: errors causing user-visible missing data or wrong output must `error` or raise, not `warning` + fallback. |
| W-02 | Strict | After 3 consecutive failed fixes on the same problem, stop and challenge the hypothesis or architecture. |
| W-03 | Strict | Verify before claiming completion: produce fresh command output proving the claim. |
| W-12 | Strict | Protect test integrity: fix production code, never weaken assertions or tamper with test infrastructure. |
| W-16 | Strict | Verification commands must come from this session. "Earlier passed" / "should work" do not count. |
| SEC-01 | Critical | No SQL / NoSQL / OS command injection: use parameterized queries and array argument lists. |
| SEC-02 | Critical | No hardcoded keys, credentials, or API tokens. Load from env / secret manager. |
| SEC-11 | Strict | AI-generated code carries higher security risk; mandatory human review for auth, payments, secrets, `innerHTML` / `eval` / `exec`. |
| SEC-13 | Strict | High-context files (`AGENTS.md`, `CLAUDE.md`, `.claude/settings*.json`, hooks) must not be silently modified by dependencies or generators. |"""


def canonical_rule(
    rule_id: str,
    guidance: str | None,
    *,
    severity: str = "strict",
    body: str = "Canonical body.",
) -> str:
    guidance_line = "" if guidance is None else f"**Compact guidance:** {guidance}\n"
    return f"## {rule_id}: Example rule ({severity})\n{guidance_line}{body}\n"


class CompactRuleGenerationTests(unittest.TestCase):
    def parse_fixture(self, text: str) -> list[object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "rules.md").write_text(text, encoding="utf-8")
            return generate_rule_docs.parse_rules(root)

    def test_current_compact_rows_migrate_without_semantic_changes(self) -> None:
        rules = generate_rule_docs.parse_rules()
        actual = generate_rule_docs.render_compact_table(rules)
        self.assertEqual(actual, EXPECTED_COMPACT_TABLE)
        for rule_id in ("U-17", "SEC-01", "SEC-02", "SEC-13"):
            expected_row = next(
                line for line in EXPECTED_COMPACT_TABLE.splitlines() if line.startswith(f"| {rule_id} ")
            )
            self.assertIn(expected_row, actual)

    def test_unselected_rules_do_not_expand_compact_table(self) -> None:
        rules = self.parse_fixture(
            canonical_rule("U-16", "Selected guidance.")
            + canonical_rule("U-99", "Unselected guidance.")
        )
        actual = generate_rule_docs.render_compact_table(rules, ("U-16",))
        self.assertIn("Selected guidance.", actual)
        self.assertNotIn("U-99", actual)
        self.assertNotIn("Unselected guidance.", actual)

    def test_duplicate_selection_id_fails_visibly(self) -> None:
        rules = self.parse_fixture(canonical_rule("U-16", "Guidance."))
        with self.assertRaisesRegex(ValueError, "duplicate.*U-16"):
            generate_rule_docs.render_compact_table(rules, ("U-16", "U-16"))

    def test_missing_selected_id_fails_visibly(self) -> None:
        rules = self.parse_fixture(canonical_rule("U-16", "Guidance."))
        with self.assertRaisesRegex(ValueError, "missing.*U-17"):
            generate_rule_docs.render_compact_table(rules, ("U-17",))

    def test_duplicate_selected_canonical_id_fails_visibly(self) -> None:
        rules = self.parse_fixture(
            canonical_rule("U-16", "First guidance.")
            + canonical_rule("U-16", "Second guidance.")
        )
        with self.assertRaisesRegex(ValueError, r"duplicate canonical.*U-16.*rules\.md"):
            generate_rule_docs.render_compact_table(rules, ("U-16",))

    def test_missing_or_empty_guidance_never_falls_back_to_summary(self) -> None:
        for guidance in (None, ""):
            with self.subTest(guidance=guidance):
                rules = self.parse_fixture(
                    canonical_rule(
                        "U-16",
                        guidance,
                        body="This first sentence must not become compact guidance.",
                    )
                )
                with self.assertRaisesRegex(ValueError, r"compact guidance.*U-16.*rules\.md"):
                    generate_rule_docs.render_compact_table(rules, ("U-16",))

    def test_duplicate_guidance_field_fails_with_rule_and_file(self) -> None:
        text = canonical_rule(
            "U-16",
            "First guidance.",
            body="**Compact guidance:** Second guidance.\nCanonical body.",
        )
        with self.assertRaisesRegex(ValueError, r"U-16.*rules\.md"):
            self.parse_fixture(text)

    def test_invalid_severity_fails_with_rule_and_file(self) -> None:
        with self.assertRaisesRegex(ValueError, r"U-16.*rules\.md.*Unknown severity"):
            self.parse_fixture(canonical_rule("U-16", "Guidance.", severity="invalid"))

    def test_malformed_rule_heading_fails_with_id_file_and_line(self) -> None:
        malformed_selected = "## U-16: Example rule strict\nCanonical body.\n"
        malformed_unselected = "## U-99: Example rule strict\nCanonical body.\n"
        valid = canonical_rule("U-16", "Guidance.")
        cases = {
            "selected only": malformed_selected,
            "unselected before valid": malformed_unselected + valid,
            "unselected after valid": valid + malformed_unselected,
        }
        for label, text in cases.items():
            with self.subTest(label=label):
                with self.assertRaisesRegex(ValueError, r"U-(?:16|99).*rules\.md:\d+"):
                    self.parse_fixture(text)

    def test_rule_like_heading_inside_fence_is_not_canonical_input(self) -> None:
        rules = self.parse_fixture(
            "```markdown\n## U-99: Example rule strict\n```\n"
            + canonical_rule("U-16", "Guidance.")
        )
        self.assertEqual([rule.id for rule in rules], ["U-16"])

    def test_main_returns_nonzero_for_canonical_parse_failure(self) -> None:
        error = ValueError("Malformed rule heading U-16 in rules.md:1")
        stderr = io.StringIO()
        with (
            mock.patch.object(generate_rule_docs, "parse_rules", side_effect=error),
            mock.patch.object(sys, "argv", [str(GENERATOR_PATH), "--check"]),
            redirect_stderr(stderr),
        ):
            self.assertEqual(generate_rule_docs.main(), 1)
        self.assertIn(str(error), stderr.getvalue())

    def test_generated_region_preserves_bytes_outside_inner_markers(self) -> None:
        start = generate_rule_docs.COMPACT_START_MARKER
        end = generate_rule_docs.COMPACT_END_MARKER
        prefix = "before\n\n" + start + "\n"
        suffix = end + "\n\nafter\n"
        actual = generate_rule_docs.replace_compact_region(
            prefix + "stale table\n" + suffix,
            "fresh table",
        )
        self.assertEqual(actual, prefix + "fresh table\n" + suffix)
        self.assertTrue(actual.startswith(prefix))
        self.assertTrue(actual.endswith(suffix))

    def test_generated_region_rejects_missing_duplicate_and_misordered_markers(self) -> None:
        start = generate_rule_docs.COMPACT_START_MARKER
        end = generate_rule_docs.COMPACT_END_MARKER
        cases = {
            "missing start": f"before\n{end}\nafter\n",
            "missing end": f"before\n{start}\nafter\n",
            "duplicate start": f"{start}\n{start}\n{end}\n",
            "duplicate end": f"{start}\n{end}\n{end}\n",
            "misordered": f"{end}\n{start}\n",
        }
        for label, document in cases.items():
            with self.subTest(label=label):
                with self.assertRaisesRegex(ValueError, "compact rule marker"):
                    generate_rule_docs.replace_compact_region(document, "table")

    def test_rendering_is_deterministic(self) -> None:
        rules = self.parse_fixture(canonical_rule("U-16", "Guidance.", severity="guideline"))
        first = generate_rule_docs.render_compact_table(rules, ("U-16",))
        second = generate_rule_docs.render_compact_table(rules, ("U-16",))
        self.assertEqual(first, second)

    def test_host_guidance_is_composed_inside_the_managed_block(self) -> None:
        shared = "<!-- vibeguard-start -->\n# Shared\n<!-- vibeguard-end -->\n"
        actual = generate_rule_docs.compose_host_rules(shared, "## Codex host\n\nHost rule.\n")
        self.assertEqual(
            actual,
            "<!-- vibeguard-start -->\n# Shared\n\n"
            "## Codex host\n\nHost rule.\n<!-- vibeguard-end -->\n",
        )

    def test_shared_guidance_uses_host_neutral_project_instruction_wording(self) -> None:
        shared = generate_rule_docs.COMPACT_RULES_PATH.read_text(encoding="utf-8")
        self.assertIn("nearest applicable repository instructions", shared)
        self.assertNotIn("repository-level `AGENTS.md` or `CLAUDE.md`", shared)

    def test_codex_host_guidance_respects_configured_home(self) -> None:
        codex_host = generate_rule_docs.CODEX_HOST_RULES_PATH.read_text(encoding="utf-8")
        self.assertIn("When managed VibeGuard skills are installed", codex_host)
        self.assertIn("$CODEX_HOME/skills/", codex_host)
        self.assertIn("defaulting to `~/.codex/skills/`", codex_host)

    def test_codex_host_guidance_matches_profile_hook_contract(self) -> None:
        codex_host = generate_rule_docs.CODEX_HOST_RULES_PATH.read_text(encoding="utf-8")
        self.assertIn(
            "Codex hook installation follows the selected setup profile",
            codex_host,
        )
        self.assertIn(
            "every profile covers native Bash and `apply_patch` gates; `full` and `strict` "
            "additionally install `post-build-check` and `Stop` hooks",
            codex_host,
        )

        manifest = json.loads((ROOT / "hooks" / "manifest.json").read_text(encoding="utf-8"))
        all_profiles = set(manifest["profiles"])
        hooks = {hook["name"]: hook for hook in manifest["hooks"]}
        for name in (
            "pre-bash-guard",
            "pre-edit-guard",
            "pre-write-guard",
            "post-edit-guard",
            "post-write-guard",
        ):
            with self.subTest(hook=name):
                self.assertTrue(hooks[name]["codex"]["enabled"])
                self.assertEqual(set(hooks[name]["claude"]["profiles"]), all_profiles)
        for name in ("post-build-check", "stop-guard", "learn-evaluator"):
            with self.subTest(hook=name):
                self.assertTrue(hooks[name]["codex"]["enabled"])
                self.assertEqual(set(hooks[name]["claude"]["profiles"]), {"full", "strict"})

        codex_setup = (ROOT / "scripts" / "setup" / "targets" / "codex-home.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("setup-codex-hooks-upsert", codex_setup)
        self.assertIn('"${wrapper}" "${PROFILE:-core}"', codex_setup)

        for path in (ROOT / "README.md", ROOT / "docs" / "README_CN.md"):
            minimal_row = next(
                line
                for line in path.read_text(encoding="utf-8").splitlines()
                if line.startswith("| `minimal` |")
            )
            with self.subTest(path=path):
                self.assertIn("post-edit", minimal_row)
                self.assertIn("post-write", minimal_row)

    def test_host_guidance_rejects_empty_or_managed_marker_content(self) -> None:
        shared = "<!-- vibeguard-start -->\nshared\n<!-- vibeguard-end -->\n"
        for host in ("", "<!-- vibeguard-start -->\nhost", "host\n<!-- vibeguard-end -->"):
            with self.subTest(host=host):
                with self.assertRaisesRegex(ValueError, "host guidance"):
                    generate_rule_docs.compose_host_rules(shared, host)

    def test_host_composition_rejects_unmanaged_shared_content_and_inline_markers(self) -> None:
        cases = {
            "content before": (
                "outside-before\n<!-- vibeguard-start -->\nshared\n<!-- vibeguard-end -->\n",
                "outside managed markers",
            ),
            "content after": (
                "<!-- vibeguard-start -->\nshared\n<!-- vibeguard-end -->\noutside-after\n",
                "outside managed markers",
            ),
            "inline start": (
                "prefix <!-- vibeguard-start -->\nshared\n<!-- vibeguard-end -->\n",
                "own line",
            ),
            "inline end": (
                "<!-- vibeguard-start -->\nshared <!-- vibeguard-end -->\n",
                "own line",
            ),
        }
        for label, (shared, message) in cases.items():
            with self.subTest(label=label), self.assertRaisesRegex(ValueError, message):
                generate_rule_docs.compose_host_rules(shared, "## Host\n")

    def test_render_all_attributes_invalid_host_guidance_to_host_source(self) -> None:
        rules = generate_rule_docs.parse_rules()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            claude_host = root / "vibeguard-claude.md"
            codex_host = root / "vibeguard-codex.md"
            valid_host = "## Host guidance\n"
            for label, invalid_path in (("claude", claude_host), ("codex", codex_host)):
                with self.subTest(host=label):
                    claude_host.write_text(valid_host, encoding="utf-8")
                    codex_host.write_text(valid_host, encoding="utf-8")
                    invalid_path.write_text("", encoding="utf-8")
                    with (
                        mock.patch.object(generate_rule_docs, "CLAUDE_HOST_RULES_PATH", claude_host),
                        mock.patch.object(generate_rule_docs, "CODEX_HOST_RULES_PATH", codex_host),
                        self.assertRaisesRegex(ValueError, rf"{re.escape(str(invalid_path))}: host guidance"),
                    ):
                        generate_rule_docs.render_all(rules)

    def test_compact_input_changes_make_snapshot_stale(self) -> None:
        rules = generate_rule_docs.parse_rules()
        current_document = generate_rule_docs.COMPACT_RULES_PATH.read_text(encoding="utf-8")
        selected_ids = generate_rule_docs.COMPACT_RULE_IDS
        selected_rule = next(rule for rule in rules if rule.id == selected_ids[0])
        variants = {
            "guidance": (
                [
                    dataclasses.replace(rule, compact_guidance="Changed guidance.")
                    if rule is selected_rule
                    else rule
                    for rule in rules
                ],
                selected_ids,
            ),
            "severity": (
                [
                    dataclasses.replace(
                        rule,
                        severity="Guideline" if selected_rule.severity != "Guideline" else "Strict",
                    )
                    if rule is selected_rule
                    else rule
                    for rule in rules
                ],
                selected_ids,
            ),
            "selection order": (rules, (selected_ids[1], selected_ids[0], *selected_ids[2:])),
        }
        for label, (variant_rules, selection) in variants.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp_dir:
                table = generate_rule_docs.render_compact_table(variant_rules, selection)
                expected = generate_rule_docs.replace_compact_region(current_document, table)
                self.assertNotEqual(expected, current_document)
                output = Path(temp_dir) / "compact.md"
                output.write_text(current_document, encoding="utf-8")
                with redirect_stderr(io.StringIO()):
                    self.assertEqual(generate_rule_docs.check_mode({output: expected}), 1)

    def test_check_mode_fails_on_stale_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output = Path(temp_dir) / "compact.md"
            output.write_text("stale\n", encoding="utf-8")
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                status = generate_rule_docs.check_mode({output: "expected\n"})
            self.assertEqual(status, 1)
            self.assertIn("Generated file drift detected", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
