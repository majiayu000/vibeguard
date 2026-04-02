#!/usr/bin/env python3
"""VibeGuard Preflight constraint automatic recommender

Automatically generate a first draft of constraints based on project exploration results (language, framework, file schema).
Confidence rating: high (automatically accepted) / medium (prompt for confirmation) / low (needs discussion).

usage:
  python3 constraint-recommender.py <project_dir>
  python3 constraint-recommender.py <project_dir> --json
"""

import json
import os
import re
import sys
from pathlib import Path


def detect_languages(project_dir: str) -> list[dict]:
    """The language and framework used by the detection project"""
    results = []
    p = Path(project_dir)

    # Rust
    if (p / "Cargo.toml").exists():
        workspace = False
        try:
            content = (p / "Cargo.toml").read_text()
            workspace = "[workspace]" in content
        except Exception:
            pass
        results.append({
            "language": "rust",
            "framework": "workspace" if workspace else "crate",
            "config": "Cargo.toml",
        })

    # TypeScript / JavaScript
    if (p / "package.json").exists():
        framework = "node"
        try:
            pkg = json.loads((p / "package.json").read_text())
            deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
            if "next" in deps:
                framework = "next"
            elif "react" in deps:
                framework = "react"
            elif "vue" in deps:
                framework = "vue"
            elif "express" in deps:
                framework = "express"
        except Exception:
            pass
        results.append({
            "language": "typescript" if (p / "tsconfig.json").exists() else "javascript",
            "framework": framework,
            "config": "package.json",
        })

    # Python
    for cfg in ["pyproject.toml", "setup.py", "requirements.txt"]:
        if (p / cfg).exists():
            framework = "python"
            try:
                if cfg == "pyproject.toml":
                    content = (p / cfg).read_text()
                    if "django" in content.lower():
                        framework = "django"
                    elif "fastapi" in content.lower():
                        framework = "fastapi"
                    elif "flask" in content.lower():
                        framework = "flask"
            except Exception:
                pass
            results.append({
                "language": "python",
                "framework": framework,
                "config": cfg,
            })
            break

    # Go
    if (p / "go.mod").exists():
        results.append({
            "language": "go",
            "framework": "go",
            "config": "go.mod",
        })

    return results


def scan_patterns(project_dir: str, languages: list[dict]) -> dict:
    """Common patterns in scan projects"""
    p = Path(project_dir)
    patterns = {
        "has_tests": False,
        "has_ci": False,
        "has_docker": False,
        "has_env_file": False,
        "entry_points": [],
        "db_paths": [],
        "env_vars": [],
    }

    #Detect common directories/files
    patterns["has_tests"] = any(
        (p / d).exists() for d in ["tests", "test", "__tests__", "spec"]
    )
    patterns["has_ci"] = (p / ".github").exists() or (p / ".gitlab-ci.yml").exists()
    patterns["has_docker"] = (p / "Dockerfile").exists() or (p / "docker-compose.yml").exists()
    patterns["has_env_file"] = (p / ".env").exists() or (p / ".env.example").exists()

    # Scan entry points
    lang_set = {l["language"] for l in languages}
    if "rust" in lang_set:
        for main in p.rglob("main.rs"):
            if "target" not in str(main):
                patterns["entry_points"].append(str(main.relative_to(p)))
    if "go" in lang_set:
        for main in p.rglob("main.go"):
            if "vendor" not in str(main):
                patterns["entry_points"].append(str(main.relative_to(p)))
    if "python" in lang_set:
        for candidate in ["app.py", "main.py", "manage.py", "wsgi.py"]:
            if (p / candidate).exists():
                patterns["entry_points"].append(candidate)

    return patterns


def generate_constraints(
    languages: list[dict], patterns: dict
) -> list[dict]:
    """Generate constrained recommendations"""
    constraints = []
    c_id = 1

    lang_set = {l["language"] for l in languages}

    # --- High confidence constraints (automatically accepted) ---

    # Error handling constraints
    if "rust" in lang_set:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "Error handling",
            "description": "Unwrap() is prohibited in non-test code, use ? or map_err",
            "confidence": "high",
            "source": "Rust project detection",
            "verify": "guards/rust/check_unwrap_in_prod.sh",
        })
        c_id += 1

    if "go" in lang_set:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "Error handling",
            "description": "The error return value must be checked and assignment to _ is prohibited,"
            "confidence": "high",
            "source": "Go project detection",
            "verify": "guards/go/check_error_handling.sh",
        })
        c_id += 1

    if "typescript" in lang_set or "javascript" in lang_set:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "type safety",
            "description": "It is forbidden to use as any and @ts-ignore to bypass type checking",
            "confidence": "high",
            "source": "TypeScript project detection",
            "verify": "guards/typescript/check_any_abuse.sh",
        })
        c_id += 1

    # Naming constraints
    constraints.append({
        "id": f"C-{c_id:02d}",
        "category": "Name consistent",
        "description": "snake_case naming (API boundary camelCase)",
        "confidence": "high",
        "source": "VibeGuard General Specification",
        "verify": "guards/python/check_naming_convention.py",
    })
    c_id += 1

    # Type is unique
    if "rust" in lang_set:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "Type unique",
            "description": "Do not add pub struct/enum definitions with the same name as existing types",
            "confidence": "high",
            "source": "Rust workspace detection",
            "verify": "guards/rust/check_duplicate_types.sh",
        })
        c_id += 1

    if "python" in lang_set:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "Type unique",
            "description": "Do not add duplicate Protocol/class definitions",
            "confidence": "high",
            "source": "Python project detection",
            "verify": "guards/python/check_duplicates.py",
        })
        c_id += 1

    # --- Medium confidence constraint (prompt for confirmation) ---

    # Data convergence
    if len(patterns["entry_points"]) > 1:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "Data Convergence",
            "description": "The data paths of all entries must be obtained through public functions",
            "confidence": "medium",
            "source": f"{len(patterns['entry_points'])} entry points detected",
            "verify": "Manually check data path consistency",
        })
        c_id += 1

    # Test constraints
    if patterns["has_tests"]:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "test coverage",
            "description": "New features must be accompanied by corresponding tests",
            "confidence": "medium",
            "source": "tests/ directory detected",
            "verify": "Run the project test suite",
        })
        c_id += 1

    #Environment variables
    if patterns["has_env_file"]:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "Configuration Security",
            "description": "Modification of .env files is prohibited. New environment variables need to be updated. .env.example",
            "confidence": "medium",
            "source": ".env file detected",
            "verify": "git diff --name-only check",
        })
        c_id += 1

    # Docker
    if patterns["has_docker"]:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "Deployment consistent",
            "description": "Synchronously update the Dockerfile when modifying dependencies",
            "confidence": "medium",
            "source": "Dockerfile detected",
            "verify": "docker build verification",
        })
        c_id += 1

    # --- Low confidence constraints (needs discussion) ---

    # Security constraints
    constraints.append({
        "id": f"C-{c_id:02d}",
        "category": "security",
        "description": "New API endpoints must have authentication/authorization checks",
        "confidence": "low",
        "source": "VibeGuard Security Specification (SEC-04)",
        "verify": "code review",
    })
    c_id += 1

    return constraints


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 constraint-recommender.py <project_dir> [--json]")
        sys.exit(1)

    project_dir = sys.argv[1]
    json_output = "--json" in sys.argv

    if not os.path.isdir(project_dir):
        print(f"Directory does not exist: {project_dir}")
        sys.exit(1)

    languages = detect_languages(project_dir)
    patterns = scan_patterns(project_dir, languages)
    constraints = generate_constraints(languages, patterns)

    if json_output:
        result = {
            "languages": languages,
            "patterns": {
                k: v for k, v in patterns.items()
                if not isinstance(v, list) or v
            },
            "constraints": constraints,
        }
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    # Format output
    print(f"\nVibeGuard constraint recommendation")
    print("=" * 40)

    print(f"\nDetected language/framework:")
    for lang in languages:
        print(f"  {lang['language']} ({lang['framework']}) — {lang['config']}")

    if patterns["entry_points"]:
        print(f"\nEntry point:")
        for ep in patterns["entry_points"]:
            print(f"  {ep}")

    #Group output by confidence level
    for level, label in [("high", "automatically accepted"), ("medium", "recommend confirmation"), ("low", "needs discussion")]:
        group = [c for c in constraints if c["confidence"] == level]
        if not group:
            continue
        print(f"\n{label} ({level}):")
        for c in group:
            print(f"  [{c['id']}] {c['category']}: {c['description']}")
            print(f" source: {c['source']}")
            print(f" Verification: {c['verify']}")

    print(f"\nTotal {len(constraints)} constraint recommendations")
    high = sum(1 for c in constraints if c["confidence"] == "high")
    medium = sum(1 for c in constraints if c["confidence"] == "medium")
    low = sum(1 for c in constraints if c["confidence"] == "low")
    print(f"  high: {high}, medium: {medium}, low: {low}")
    print()


if __name__ == "__main__":
    main()
