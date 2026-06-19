"""Project-config schema drift checks for VibeGuard install contracts."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any


GC_CONFIG_RE = re.compile(r"\bvg_config_positive_int\s+\S+\s+gc\.([A-Za-z0-9_]+)\b")


def _normalize_language(value: str) -> str:
    language = value.strip().lower()
    if language == "golang":
        return "go"
    return language


def manifest_languages(manifest: dict[str, Any]) -> list[str]:
    languages: set[str] = set()
    modules = manifest.get("modules", [])
    if not isinstance(modules, list):
        raise ValueError("manifest modules must be a list")
    for module in modules:
        if not isinstance(module, dict):
            raise ValueError("manifest module entry is not an object")
        module_id = str(module.get("id", "<unknown>"))
        languages.update(_module_languages(module, module_id))
    return sorted(languages)


def gc_config_keys(root: Path) -> list[str]:
    keys: set[str] = set()
    for file in sorted((root / "scripts" / "gc").glob("*.sh")):
        text = file.read_text(encoding="utf-8")
        keys.update(GC_CONFIG_RE.findall(text))
    return sorted(keys)


def project_schema_contract_errors(
    project_schema: dict[str, Any],
    *,
    manifest_profiles: list[str],
    manifest_languages: list[str],
    disabled_hooks: list[str],
    disabled_guards: list[str],
    gc_keys: list[str],
) -> list[str]:
    errors: list[str] = []

    profile_enum, enum_error = _project_schema_enum(project_schema, "profile")
    if enum_error:
        errors.append(enum_error)
        profile_enum = []
    if profile_enum != manifest_profiles:
        errors.append(
            "project schema profile enum drift: "
            f"manifest={manifest_profiles} schema={profile_enum}"
        )

    enforcement_enum, enum_error = _project_schema_enum(project_schema, "enforcement")
    if enum_error:
        errors.append(enum_error)
    elif not enforcement_enum:
        errors.append("project schema enforcement enum must not be empty")

    language_enum, enum_error = _project_schema_enum(
        project_schema,
        "languages",
        array_items=True,
    )
    if enum_error:
        errors.append(enum_error)
        language_enum = []
    if language_enum != manifest_languages:
        errors.append(
            "project schema languages enum drift: "
            f"manifest={manifest_languages} schema={language_enum}"
        )

    disabled_hook_enum, enum_error = _project_schema_enum(
        project_schema,
        "disabled_hooks",
        array_items=True,
    )
    if enum_error:
        errors.append(enum_error)
        disabled_hook_enum = []
    if disabled_hook_enum != disabled_hooks:
        errors.append(
            "project schema disabled_hooks enum drift: "
            f"manifest={disabled_hooks} schema={disabled_hook_enum}"
        )

    disabled_guard_enum, enum_error = _project_schema_enum(
        project_schema,
        "disabled_guards",
        array_items=True,
    )
    if enum_error:
        errors.append(enum_error)
        disabled_guard_enum = []
    if disabled_guard_enum != disabled_guards:
        errors.append(
            "project schema disabled_guards enum drift: "
            f"guards={disabled_guards} schema={disabled_guard_enum}"
        )

    schema_gc_keys, gc_error = _project_schema_gc_keys(project_schema)
    if gc_error:
        errors.append(gc_error)
        schema_gc_keys = []
    if schema_gc_keys != gc_keys:
        errors.append(
            "project schema gc key drift: "
            f"scripts={gc_keys} schema={schema_gc_keys}"
        )

    return errors


def _module_languages(module: dict[str, Any], module_id: str) -> set[str]:
    languages = module.get("languages", [])
    if not isinstance(languages, list):
        raise ValueError(f"module {module_id}: languages must be a list")
    normalized: set[str] = set()
    for item in languages:
        if not isinstance(item, str):
            raise ValueError(f"module {module_id}: non-string language entry")
        language = _normalize_language(item)
        if language:
            normalized.add(language)
    return normalized


def _project_schema_enum(
    project_schema: dict[str, Any],
    field: str,
    *,
    array_items: bool = False,
) -> tuple[list[str], str | None]:
    properties = project_schema.get("properties", {})
    if not isinstance(properties, dict):
        return [], "project schema properties must be an object"
    node = properties.get(field)
    if not isinstance(node, dict):
        return [], f"project schema {field} property missing"
    if array_items:
        node = node.get("items", {})
        if not isinstance(node, dict):
            return [], f"project schema {field}.items must be an object"
    values = node.get("enum", [])
    if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
        return [], f"project schema {field} enum must be a string array"
    return sorted(values), None


def _project_schema_gc_keys(project_schema: dict[str, Any]) -> tuple[list[str], str | None]:
    properties = project_schema.get("properties", {})
    if not isinstance(properties, dict):
        return [], "project schema properties must be an object"
    gc_node = properties.get("gc", {})
    if not isinstance(gc_node, dict):
        return [], "project schema gc property missing"
    gc_properties = gc_node.get("properties", {})
    if not isinstance(gc_properties, dict):
        return [], "project schema gc.properties must be an object"
    return sorted(gc_properties.keys()), None
