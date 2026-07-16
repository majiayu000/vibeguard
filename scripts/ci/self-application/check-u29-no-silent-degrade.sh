#!/usr/bin/env bash
# U-29 self-application: security-sensitive degradation must be visible.
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

python3 - <<'PY' "${REPO_DIR}"
import ast
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
errors: list[str] = []

EXCLUDED_PY = {
    Path("eval/samples.py"),  # intentionally contains bad-code samples
}
EXCLUDED_DIR_PARTS = {
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    "__pycache__",
    "target",
    "node_modules",
    "dist",
    "mcp-server",
}

def is_excluded(path: Path) -> bool:
    rel = path.relative_to(repo)
    return rel in EXCLUDED_PY or any(part in EXCLUDED_DIR_PARTS for part in rel.parts)

def except_type_name(handler: ast.ExceptHandler) -> str:
    if handler.type is None:
        return "bare"
    if isinstance(handler.type, ast.Name):
        return handler.type.id
    if isinstance(handler.type, ast.Attribute):
        return handler.type.attr
    return ast.unparse(handler.type) if hasattr(ast, "unparse") else "<expr>"

for path in sorted(repo.rglob("*.py")):
    if is_excluded(path):
        continue
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError:
        # Syntax is validated elsewhere; avoid duplicate noise here.
        continue
    for node in ast.walk(tree):
        if not isinstance(node, ast.ExceptHandler):
            continue
        type_name = except_type_name(node)
        if type_name not in {"Exception", "BaseException", "bare"}:
            continue
        body = [stmt for stmt in node.body if not isinstance(stmt, ast.Expr) or not isinstance(stmt.value, ast.Constant)]
        if len(body) == 1 and isinstance(body[0], ast.Pass):
            rel = path.relative_to(repo)
            errors.append(f"{rel}:{node.lineno}: silent {type_name} handler with only pass")

precommit = repo / "hooks/pre-commit-guard.sh"
if precommit.exists():
    text = precommit.read_text(encoding="utf-8")
    if re.search(r"code\s+-eq\s+124[^\n;]*[;&|]\s*return\s+0", text):
        errors.append("hooks/pre-commit-guard.sh: timeout 124 appears to return success")
    if '"block" "guard timeout' not in text:
        errors.append("hooks/pre-commit-guard.sh: missing visible timeout block log")
    if "VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR" not in text:
        errors.append("hooks/pre-commit-guard.sh: missing explicit timeout downgrade knob")

prebash = repo / "hooks/pre-bash-guard.sh"
if prebash.exists():
    text = prebash.read_text(encoding="utf-8")
    runtime_owned = re.search(r"\bhook\s+pre-bash\b", text) is not None
    if runtime_owned:
        classifier = repo / "vibeguard-runtime/src/hook_checks_bash.rs"
        orchestrator = repo / "vibeguard-runtime/src/hook_orchestrator_pre_bash.rs"
        classifier_text = classifier.read_text(encoding="utf-8") if classifier.exists() else ""
        orchestrator_text = orchestrator.read_text(encoding="utf-8") if orchestrator.exists() else ""
        if "evaluate_pre_bash_input" not in classifier_text:
            errors.append("vibeguard-runtime/src/hook_checks_bash.rs: Bash command extraction is not runtime fail-closed")
        if "invalid Bash hook input JSON; fail-closed" not in classifier_text:
            errors.append("vibeguard-runtime/src/hook_checks_bash.rs: missing fail-closed parse warning")
        if "evaluate_pre_bash_input(input, &vibeguard_root)" not in orchestrator_text:
            errors.append("vibeguard-runtime/src/hook_orchestrator_pre_bash.rs: pre-bash hook does not use runtime classifier")
    else:
        if "pre-bash-check" not in text:
            errors.append("hooks/pre-bash-guard.sh: Bash command extraction is not runtime fail-closed")
        if "invalid Bash hook input JSON; fail-closed" not in text:
            errors.append("hooks/pre-bash-guard.sh: missing fail-closed parse warning")

runtime_python_fallbacks = {
    "hooks/pre-bash-guard.sh": "_lib/pkg_rewrite.py",
    "hooks/learn-evaluator.sh": "_lib/session_metrics.py",
    "hooks/_lib/log_json.sh": "python3 -c",
}
for rel, fallback_ref in runtime_python_fallbacks.items():
    path = repo / rel
    if path.exists() and fallback_ref in path.read_text(encoding="utf-8"):
        errors.append(f"{rel}: runtime Python fallback reference remains ({fallback_ref})")

eval_runner = repo / "eval/run_eval.py"
if eval_runner.exists():
    text = eval_runner.read_text(encoding="utf-8")
    if '"skipped": True' not in text:
        errors.append("eval/run_eval.py: API exceptions must produce skipped=True")
    if "EVAL_MAX_API_FAILURES" not in text:
        errors.append("eval/run_eval.py: missing API failure threshold knob")

for rel in ("scripts/setup/install.sh", "scripts/setup/runtime-install.sh"):
    setup_install = repo / rel
    if not setup_install.exists():
        continue
    text = setup_install.read_text(encoding="utf-8")
    for phrase in ("falls back to Python", "falling back to Python", "using Python fallback"):
        if phrase in text:
            errors.append(f"{rel}: helper build must not advertise {phrase!r}")
    for phrase in ("VIBEGUARD_ALLOW_NO_RUNTIME", "explicit degraded mode", "degraded install without"):
        if phrase in text:
            errors.append(f"{rel}: no-runtime compatibility path remains ({phrase!r})")

if errors:
    print("FAIL: U-29 silent-degradation checks failed")
    for error in errors:
        print(error)
    raise SystemExit(1)

print("OK: no targeted silent-degradation regressions found")
PY
