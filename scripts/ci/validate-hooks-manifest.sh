#!/usr/bin/env bash
# Validate hooks/manifest.json and generated hook documentation.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

python3 -m py_compile "${REPO_DIR}/scripts/lib/hooks_manifest.py"
python3 "${REPO_DIR}/scripts/lib/hooks_manifest.py" validate
python3 - <<'PY' "${REPO_DIR}"
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
for path in (
    repo / "hooks/manifest.json",
    repo / "schemas/hooks-manifest.schema.json",
):
    with path.open("r", encoding="utf-8") as f:
        json.load(f)
print("OK: hook manifest JSON files parse")

manifest = json.loads((repo / "hooks/manifest.json").read_text(encoding="utf-8"))
manifest_scripts = {item["script"] for item in manifest["hooks"]}
install = json.loads((repo / "schemas/install-modules.json").read_text(encoding="utf-8"))
errors = []
for module in install.get("modules", []):
    if module.get("kind") != "hooks":
        continue
    for path in module.get("paths", []):
        hook_name = Path(path).name
        if hook_name not in manifest_scripts:
            errors.append(f"{module.get('id')}: {path} missing from hooks/manifest.json")
if errors:
    for error in errors:
        print(f"FAIL: {error}")
    raise SystemExit(1)
print("OK: install hook modules are covered by hooks manifest")
PY
bash "${REPO_DIR}/scripts/setup/regenerate-hooks-from-manifest.sh" --check
