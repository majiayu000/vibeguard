#!/usr/bin/env python3
"""Helpers for reading and validating the VibeGuard manifest contract."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

from hooks_manifest import disableable_hook_names, load_manifest as load_hooks_manifest
from project_schema_contract import (
    gc_config_keys,
    manifest_languages,
    project_schema_contract_errors,
)


ROOT = Path(__file__).resolve().parents[2]
MANIFEST_FILE = ROOT / "schemas" / "install-modules.json"
PROJECT_SCHEMA_FILE = ROOT / "schemas" / "vibeguard-project.schema.json"
HOOKS_MANIFEST_FILE = ROOT / "hooks" / "manifest.json"
PROMPT_CONTRACT_SCHEMA_FILE = ROOT / "schemas" / "prompt-contract.schema.json"
DEFAULT_PROMPT_TARGET = ROOT / "templates" / "AGENTS.md"
CANONICAL_RULES_DIR = ROOT / "rules" / "claude-rules"
REFERENCE_DOC = ROOT / "docs" / "rule-reference.md"
HOOKS_DIR = ROOT / "hooks"
GUARDS_DIR = ROOT / "guards"

PROMPT_HEADING_RE = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)
PROMPT_FRONTMATTER_KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*:")

RULE_ID_HEADING_RE = re.compile(r"^##\s+((?:RS|GO|TS|PY|U|SEC|W|TASTE)-[A-Za-z0-9-]+)\b", re.MULTILINE)
RULE_ID_TABLE_RE = re.compile(r"^\|\s*((?:RS|GO|TS|PY|U|SEC|W|TASTE)-[A-Za-z0-9-]+)\s*\|", re.MULTILINE)
GUARD_RULE_RE = re.compile(r"\b(?:RS|GO|TS|PY|U|SEC|W|TASTE)-[A-Za-z0-9-]+\b")

def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def load_manifest(path: Path | None = None) -> dict[str, Any]:
    manifest_path = path or MANIFEST_FILE
    data = load_json(manifest_path)
    if not isinstance(data, dict):
        raise ValueError("manifest root must be an object")
    return data


def rule_ids_from_tree(root: Path) -> list[str]:
    ids: set[str] = set()
    for file in sorted(root.rglob("*.md")):
        try:
            text = file.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        ids.update(RULE_ID_HEADING_RE.findall(text))
    return sorted(ids)


def canonical_rule_ids(scope: str = "all") -> list[str]:
    base = CANONICAL_RULES_DIR
    if scope == "common":
        return rule_ids_from_tree(base / "common")
    return rule_ids_from_tree(base)


def reference_rule_ids() -> list[str]:
    text = REFERENCE_DOC.read_text(encoding="utf-8")
    return sorted(set(RULE_ID_TABLE_RE.findall(text)))


def guard_rule_ids() -> list[str]:
    ids: set[str] = set()
    for file in sorted(GUARDS_DIR.rglob("*")):
        if not file.is_file():
            continue
        try:
            text = file.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        ids.update(GUARD_RULE_RE.findall(text))
    for file in sorted(HOOKS_DIR.glob("*.sh")):
        try:
            text = file.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        ids.update(GUARD_RULE_RE.findall(text))
    filtered = {
        rule_id
        for rule_id in ids
        if not rule_id.endswith("-XX") and rule_id not in {"U-HARDCODE", "TASTE-FOLD"}
    }
    return sorted(filtered)


def hook_names() -> list[str]:
    return disableable_hook_names(load_hooks_manifest(HOOKS_MANIFEST_FILE))


def guard_names() -> list[str]:
    names: list[str] = []
    for file in sorted(GUARDS_DIR.rglob("*")):
        if file.is_file() and file.name.startswith("check_") and file.suffix in {".sh", ".py"}:
            names.append(file.stem)
    return sorted(names)


def normalize_language(value: str) -> str:
    language = value.strip().lower()
    if language == "golang":
        return "go"
    return language


def language_filter(languages: str | None) -> set[str]:
    if not languages:
        return set()
    return {
        normalize_language(part)
        for part in languages.split(",")
        if normalize_language(part)
    }


def _module_languages(module: dict[str, Any], module_id: str) -> set[str]:
    languages = module.get("languages", [])
    if not isinstance(languages, list):
        raise ValueError(f"module {module_id}: languages must be a list")
    normalized: set[str] = set()
    for item in languages:
        if not isinstance(item, str):
            raise ValueError(f"module {module_id}: non-string language entry")
        language = normalize_language(item)
        if language:
            normalized.add(language)
    return normalized


def normalize_skill_source(path_str: str, module_id: str) -> str:
    source = path_str.rstrip("/")
    if not source:
        raise ValueError(f"module {module_id}: skill path must name a skill directory: {path_str}")
    if "\\" in source:
        raise ValueError(f"module {module_id}: skill path must use forward slashes: {path_str}")
    path = PurePosixPath(source)
    if path.is_absolute():
        raise ValueError(f"module {module_id}: skill path must be repo-relative: {path_str}")
    if ".." in path.parts:
        raise ValueError(f"module {module_id}: skill path must not contain '..': {path_str}")
    normalized = path.as_posix()
    if normalized in {"", "."} or not PurePosixPath(normalized).name:
        raise ValueError(f"module {module_id}: skill path must name a skill directory: {path_str}")
    return normalized


def normalize_rule_source(path_str: str, module_id: str) -> tuple[str, str, str]:
    source = path_str.rstrip("/")
    if not source:
        raise ValueError(f"module {module_id}: rule path must name a Markdown file: {path_str}")
    if "\\" in source:
        raise ValueError(f"module {module_id}: rule path must use forward slashes: {path_str}")
    path = PurePosixPath(source)
    if path.is_absolute():
        raise ValueError(f"module {module_id}: rule path must be repo-relative: {path_str}")
    if ".." in path.parts:
        raise ValueError(f"module {module_id}: rule path must not contain '..': {path_str}")
    if path.suffix != ".md":
        raise ValueError(f"module {module_id}: rule path must be a Markdown file: {path_str}")

    rules_root = PurePosixPath("rules/claude-rules")
    try:
        dest_rel_path = path.relative_to(rules_root)
    except ValueError as exc:
        raise ValueError(
            f"module {module_id}: rule path must live under rules/claude-rules/: {path_str}"
        ) from exc
    if not dest_rel_path.parts:
        raise ValueError(f"module {module_id}: rule path must include a rule subdirectory: {path_str}")

    normalized = path.as_posix()
    if not (ROOT / normalized).is_file():
        raise ValueError(f"module {module_id}: missing rule path {normalized}")
    return normalized, dest_rel_path.as_posix(), dest_rel_path.parts[0]


def rule_links(
    manifest: dict[str, Any],
    languages: str | None = None,
) -> list[tuple[str, str, str]]:
    selected_languages = language_filter(languages)
    links: list[tuple[str, str, str]] = []
    modules = manifest.get("modules", [])
    if not isinstance(modules, list):
        raise ValueError("manifest modules must be a list")
    for module in modules:
        if not isinstance(module, dict):
            raise ValueError("manifest module entry is not an object")
        if module.get("kind") != "rules":
            continue
        module_id = str(module.get("id", "<unknown>"))
        module_languages = _module_languages(module, module_id)
        if selected_languages and module_languages and selected_languages.isdisjoint(module_languages):
            continue
        paths = module.get("paths", [])
        if not isinstance(paths, list):
            raise ValueError(f"module {module_id}: paths must be a list")
        for path_str in paths:
            if not isinstance(path_str, str):
                raise ValueError(f"module {module_id}: non-string rule path")
            links.append(normalize_rule_source(path_str, module_id))
    return links


def rule_labels(manifest: dict[str, Any], languages: str | None = None) -> list[str]:
    labels: list[str] = []
    seen: set[str] = set()
    for _source, _dest_rel, label in rule_links(manifest, languages):
        if label not in seen:
            labels.append(label)
            seen.add(label)
    return labels


def skill_links(manifest: dict[str, Any], target: str) -> list[tuple[str, str]]:
    links: list[tuple[str, str]] = []
    modules = manifest.get("modules", [])
    if not isinstance(modules, list):
        raise ValueError("manifest modules must be a list")
    for module in modules:
        if not isinstance(module, dict):
            raise ValueError("manifest module entry is not an object")
        if module.get("kind") != "skills" or module.get("target") != target:
            continue
        paths = module.get("paths", [])
        if not isinstance(paths, list):
            module_id = str(module.get("id", "<unknown>"))
            raise ValueError(f"module {module_id}: paths must be a list")
        for path_str in paths:
            if not isinstance(path_str, str):
                module_id = str(module.get("id", "<unknown>"))
                raise ValueError(f"module {module_id}: non-string path entry")
            module_id = str(module.get("id", "<unknown>"))
            source = normalize_skill_source(path_str, module_id)
            if source:
                links.append((source, PurePosixPath(source).name))
    return links


def profile_names(manifest: dict[str, Any]) -> list[str]:
    profiles = manifest.get("profiles", {})
    if not isinstance(profiles, dict):
        raise ValueError("manifest profiles must be an object")
    return list(profiles.keys())


def _module_ids(manifest: dict[str, Any]) -> list[str]:
    modules = manifest.get("modules", [])
    if not isinstance(modules, list):
        raise ValueError("manifest modules must be a list")
    return [str(module.get("id", "")) for module in modules if isinstance(module, dict)]


def _validate_paths(manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    for module in manifest.get("modules", []):
        if not isinstance(module, dict):
            errors.append("manifest module entry is not an object")
            continue
        module_id = str(module.get("id", "<unknown>"))
        paths = module.get("paths", [])
        if not isinstance(paths, list):
            errors.append(f"module {module_id}: paths must be a list")
            continue
        for path_str in paths:
            if not isinstance(path_str, str):
                errors.append(f"module {module_id}: non-string path entry")
                continue
            path = ROOT / path_str
            if not path.exists():
                errors.append(f"module {module_id}: missing path {path_str}")
    return errors


def _validate_rule_paths(manifest: dict[str, Any]) -> list[str]:
    modules = manifest.get("modules", [])
    if not isinstance(modules, list):
        return []

    actual: set[str] = set()
    for module in modules:
        if not isinstance(module, dict) or module.get("kind") != "rules":
            continue
        paths = module.get("paths", [])
        if not isinstance(paths, list):
            continue
        for path in paths:
            if isinstance(path, str):
                actual.add(path.rstrip("/"))

    expected = {
        path.relative_to(ROOT).as_posix()
        for path in sorted(CANONICAL_RULES_DIR.rglob("*.md"))
    }
    if actual == expected:
        return []

    return [
        "rule install path drift: "
        f"manifest_missing={sorted(expected - actual)} "
        f"manifest_extra={sorted(actual - expected)}"
    ]


def _validate_profiles(manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    modules = set(_module_ids(manifest))
    profiles = manifest.get("profiles", {})
    if not isinstance(profiles, dict):
        return ["manifest profiles must be an object"]

    visiting: set[str] = set()
    visited: set[str] = set()

    def walk(name: str) -> None:
        if name in visited:
            return
        if name in visiting:
            errors.append(f"profile cycle detected at {name}")
            return
        profile = profiles.get(name)
        if not isinstance(profile, dict):
            errors.append(f"profile {name} is not an object")
            return
        visiting.add(name)
        extends = profile.get("extends")
        if extends is not None:
            if not isinstance(extends, str) or extends not in profiles:
                errors.append(f"profile {name}: unknown extends target {extends!r}")
            else:
                walk(extends)
        module_refs = profile.get("modules", [])
        if not isinstance(module_refs, list):
            errors.append(f"profile {name}: modules must be a list")
        else:
            for module_id in module_refs:
                if module_id not in modules:
                    errors.append(f"profile {name}: unknown module {module_id!r}")
        visiting.remove(name)
        visited.add(name)

    for name in profiles:
        walk(name)
    return errors


def _validate_project_schema(
    manifest: dict[str, Any],
    project_schema: dict[str, Any],
    hooks_manifest: dict[str, Any],
) -> list[str]:
    try:
        expected_languages = manifest_languages(manifest)
    except ValueError as exc:
        return [str(exc)]

    return project_schema_contract_errors(
        project_schema,
        manifest_profiles=sorted(profile_names(manifest)),
        manifest_languages=expected_languages,
        disabled_hooks=disableable_hook_names(hooks_manifest),
        disabled_guards=guard_names(),
        gc_keys=gc_config_keys(ROOT),
    )


def _hook_modules(manifest: dict[str, Any]) -> tuple[dict[str, set[str]], list[str]]:
    modules: dict[str, set[str]] = {}
    errors: list[str] = []
    for module in manifest.get("modules", []):
        if not isinstance(module, dict) or module.get("kind") != "hooks":
            continue
        module_id = str(module.get("id", ""))
        paths = module.get("paths", [])
        if not module_id:
            errors.append("hook module has empty id")
            continue
        if not isinstance(paths, list):
            errors.append(f"module {module_id}: paths must be a list")
            continue
        module_paths: set[str] = set()
        for path in paths:
            if not isinstance(path, str):
                errors.append(f"module {module_id}: non-string hook path")
                continue
            module_paths.add(path)
        modules[module_id] = module_paths
    return modules, errors


def _validate_hook_install_targets(
    manifest: dict[str, Any],
    hooks_manifest: dict[str, Any],
) -> list[str]:
    modules, errors = _hook_modules(manifest)
    expected = {module_id: set() for module_id in modules}

    for index, item in enumerate(hooks_manifest.get("hooks", [])):
        if not isinstance(item, dict):
            errors.append(f"hooks[{index}] is not an object")
            continue
        script = item.get("script")
        targets = item.get("install_targets", [])
        if targets is None:
            targets = []
        if not isinstance(targets, list):
            errors.append(f"hooks[{index}].install_targets must be a list")
            continue
        if not targets:
            continue
        if not isinstance(script, str):
            errors.append(f"hooks[{index}].script must be a string for install_targets")
            continue
        hook_path = f"hooks/{script}"
        for target in targets:
            if target not in modules:
                errors.append(f"hook {script}: unknown install target {target!r}")
                continue
            expected[target].add(hook_path)

    for module_id, actual_paths in sorted(modules.items()):
        expected_paths = expected.get(module_id, set())
        if actual_paths == expected_paths:
            continue
        manifest_only = sorted(expected_paths - actual_paths)
        install_only = sorted(actual_paths - expected_paths)
        errors.append(
            f"hook install target drift for {module_id}: "
            f"manifest_only={manifest_only} install_only={install_only}"
        )
    return errors


def _validate_skill_links(manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    seen: dict[tuple[str, str], str] = {}
    for module in manifest.get("modules", []):
        if not isinstance(module, dict) or module.get("kind") != "skills":
            continue
        target = str(module.get("target", ""))
        module_id = str(module.get("id", "<unknown>"))
        try:
            links = skill_links({"modules": [module]}, target)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        for source, name in links:
            key = (target, name)
            previous = seen.get(key)
            if previous is not None:
                errors.append(
                    f"duplicate skill target {target}/{name}: {previous} and {module_id}:{source}"
                )
            else:
                seen[key] = f"{module_id}:{source}"
    return errors


def _prompt_section_body(text: str, heading_text: str) -> str:
    pattern = re.compile(
        rf"^##\s+{re.escape(heading_text)}\s*$(.*?)(?=^##\s|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(text)
    return match.group(1) if match else ""


def _prompt_frontmatter_keys(text: str) -> set[str]:
    if not text.startswith("---\n"):
        return set()
    end = text.find("\n---\n", 4)
    if end < 0:
        end = text.find("\n---", 4)
        if end < 0:
            return set()
    block = text[4:end]
    keys: set[str] = set()
    for raw in block.split("\n"):
        line = raw.rstrip()
        if not line or line.startswith("#") or line.startswith(" ") or line.startswith("\t"):
            continue
        match = PROMPT_FRONTMATTER_KEY_RE.match(line)
        if match:
            keys.add(match.group(1))
    return keys


def validate_prompt_contract(
    target: Path,
    schema: dict[str, Any],
    *,
    strict: bool = False,
) -> tuple[list[str], list[str]]:
    """Return (errors, warnings) after validating ``target`` against the prompt contract."""
    errors: list[str] = []
    warnings: list[str] = []

    if not target.exists():
        return [f"target file not found: {target}"], []

    schema_version = schema.get("version")
    if schema_version != 1:
        return [f"unsupported prompt contract schema version: {schema_version!r}"], []

    text = target.read_text(encoding="utf-8")
    line_count = text.count("\n") + (0 if text.endswith("\n") else 1)

    try:
        rel_parts = target.resolve().relative_to(ROOT).parts
        is_role_prompt = bool(rel_parts) and rel_parts[0] == "agents"
    except ValueError:
        # Target lives outside the repository root (test fixtures, ad-hoc
        # validation against an external file). Fall back to the immediate
        # parent dir name; this avoids treating an unrelated checkout under
        # an ancestor directory named "agents" as a role prompt.
        is_role_prompt = target.parent.name == "agents"

    if is_role_prompt:
        # Role prompts use frontmatter for identity; the body is freeform per role.
        # Required sections apply only to root AGENTS.md.
        frontmatter = _prompt_frontmatter_keys(text)
        for key in schema.get("role_prompt", {}).get("frontmatter_required", []):
            if key not in frontmatter:
                errors.append(f"role prompt missing frontmatter key: {key}")
    else:
        headings = [match.group(1).strip() for match in PROMPT_HEADING_RE.finditer(text)]
        required = schema.get("required_sections", [])
        optional = schema.get("optional_sections", [])
        known = {section["heading_text"] for section in required}
        known.update(section["heading_text"] for section in optional)

        for section in required:
            heading_text = section["heading_text"]
            if heading_text not in headings:
                errors.append(f"missing required section: ## {heading_text}")
                continue
            body = _prompt_section_body(text, heading_text)
            body_lower = body.lower()
            for token in section.get("must_mention", []):
                if token.lower() not in body_lower:
                    errors.append(
                        f"section '## {heading_text}' missing required mention: {token!r}"
                    )

        for heading in headings:
            if heading not in known:
                warnings.append(f"unknown section heading: ## {heading}")

    budgets = schema.get("budgets", {})
    if is_role_prompt:
        max_lines = budgets.get("role_prompt_max_lines")
        if max_lines and line_count > max_lines:
            message = f"line count {line_count} exceeds role_prompt_max_lines {max_lines}"
            (errors if strict else warnings).append(message)
    else:
        max_lines = budgets.get("root_agents_md_max_lines")
        warn_lines = budgets.get("root_agents_md_warn_lines")
        if max_lines and line_count > max_lines:
            message = f"line count {line_count} exceeds root_agents_md_max_lines {max_lines}"
            (errors if strict else warnings).append(message)
        elif warn_lines and line_count > warn_lines:
            warnings.append(
                f"line count {line_count} exceeds root_agents_md_warn_lines {warn_lines}"
            )

    return errors, warnings


def validate_contract(
    manifest_path: Path,
    project_schema_path: Path,
    hooks_manifest_path: Path,
) -> list[str]:
    manifest = load_manifest(manifest_path)
    project_schema = load_json(project_schema_path)
    hooks_manifest = load_hooks_manifest(hooks_manifest_path)

    errors: list[str] = []
    module_ids = _module_ids(manifest)
    if len(module_ids) != len(set(module_ids)):
        errors.append("duplicate module ids detected in manifest")
    errors.extend(_validate_paths(manifest))
    errors.extend(_validate_rule_paths(manifest))
    errors.extend(_validate_profiles(manifest))
    errors.extend(_validate_project_schema(manifest, project_schema, hooks_manifest))
    errors.extend(_validate_hook_install_targets(manifest, hooks_manifest))
    errors.extend(_validate_skill_links(manifest))
    return errors


def print_lines(items: Iterable[str]) -> None:
    for item in items:
        print(item)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="VibeGuard manifest helper")
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate", help="Validate manifest/profile/schema contract")
    validate.add_argument("--manifest-file", default=str(MANIFEST_FILE))
    validate.add_argument("--project-schema", default=str(PROJECT_SCHEMA_FILE))
    validate.add_argument("--hooks-manifest", default=str(HOOKS_MANIFEST_FILE))

    profiles = sub.add_parser("profile-names", help="List canonical profile names")
    profiles.add_argument("--manifest-file", default=str(MANIFEST_FILE))

    rule_ids = sub.add_parser("rule-ids", help="List rule ids from canonical or reference sources")
    rule_ids.add_argument("--source", choices=["canonical", "reference", "mechanical"], default="canonical")
    rule_ids.add_argument("--scope", choices=["all", "common"], default="all")

    sub.add_parser("hook-names", help="List user-disableable hook names")
    sub.add_parser("guard-names", help="List known guard names")
    rule_link = sub.add_parser("rule-links", help="List installable rule files")
    rule_link.add_argument("--languages", default="")
    rule_link.add_argument("--manifest-file", default=str(MANIFEST_FILE))
    rule_label = sub.add_parser("rule-labels", help="List installable rule labels")
    rule_label.add_argument("--languages", default="")
    rule_label.add_argument("--manifest-file", default=str(MANIFEST_FILE))
    skill = sub.add_parser("skill-links", help="List installable skill links for a target")
    skill.add_argument("--target", required=True)
    skill.add_argument("--manifest-file", default=str(MANIFEST_FILE))

    prompt = sub.add_parser(
        "validate-prompt-contract",
        help="Validate AGENTS.md or a role prompt against the prompt contract schema",
    )
    prompt.add_argument("--target", default=str(DEFAULT_PROMPT_TARGET))
    prompt.add_argument("--schema", default=str(PROMPT_CONTRACT_SCHEMA_FILE))
    prompt.add_argument("--strict", action="store_true")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "validate":
        errors = validate_contract(
            Path(args.manifest_file),
            Path(args.project_schema),
            Path(args.hooks_manifest),
        )
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        print("OK")
        return 0

    if args.command == "profile-names":
        manifest = load_manifest(Path(args.manifest_file))
        print_lines(profile_names(manifest))
        return 0

    if args.command == "rule-ids":
        if args.source == "canonical":
            print_lines(canonical_rule_ids(args.scope))
        elif args.source == "reference":
            print_lines(reference_rule_ids())
        else:
            print_lines(guard_rule_ids())
        return 0

    if args.command == "hook-names":
        print_lines(hook_names())
        return 0

    if args.command == "guard-names":
        print_lines(guard_names())
        return 0

    if args.command == "rule-links":
        manifest = load_manifest(Path(args.manifest_file))
        for source, dest_rel, label in rule_links(manifest, args.languages):
            print(f"{source}\t{dest_rel}\t{label}")
        return 0

    if args.command == "rule-labels":
        manifest = load_manifest(Path(args.manifest_file))
        print_lines(rule_labels(manifest, args.languages))
        return 0

    if args.command == "skill-links":
        manifest = load_manifest(Path(args.manifest_file))
        for source, name in skill_links(manifest, args.target):
            print(f"{source}\t{name}")
        return 0

    if args.command == "validate-prompt-contract":
        schema = load_json(Path(args.schema))
        errors, warnings = validate_prompt_contract(
            Path(args.target), schema, strict=args.strict
        )
        for warning in warnings:
            print(f"WARN: {warning}", file=sys.stderr)
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        print("OK")
        return 0

    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
