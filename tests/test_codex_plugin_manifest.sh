#!/usr/bin/env bash
# Validate the repo-local Codex App plugin package.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="${REPO_DIR}/plugins/vibeguard"
PLUGIN_JSON="${PLUGIN_DIR}/.codex-plugin/plugin.json"
MARKETPLACE_JSON="${REPO_DIR}/.agents/plugins/marketplace.json"
SKILL_VALIDATOR="${REPO_DIR}/scripts/ci/validate-skill-format.py"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit code: $?)"
    FAIL=$((FAIL + 1))
  fi
}

header "codex plugin files"
assert_cmd "plugin manifest exists" test -f "${PLUGIN_JSON}"
assert_cmd "marketplace manifest exists" test -f "${MARKETPLACE_JSON}"
assert_cmd "plugin bridge script has valid syntax" bash -n "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"
assert_cmd "plugin bridge resolves repo checkout" \
  bash "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh" repo-dir
assert_cmd "plugin bridge rejects invalid pinned repo checkout" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  VIBEGUARD_REPO_DIR="${tmp_dir}/missing" bash "$1" repo-dir 2>"${tmp_dir}/stderr" && exit 1
  grep -q "VIBEGUARD_REPO_DIR is not a VibeGuard repository checkout" "${tmp_dir}/stderr"
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"
assert_cmd "plugin dashboard generator writes local HTML" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  VIBEGUARD_REPO_DIR="$2" bash "$1" dashboard --no-open --output "${tmp_dir}/dashboard.html" --log-file /dev/null >/dev/null
  test -f "${tmp_dir}/dashboard.html"
  grep -q "VibeGuard Observability" "${tmp_dir}/dashboard.html"
  ! LC_ALL=C grep -q "$(printf "\033")" "${tmp_dir}/dashboard.html"
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh" "${REPO_DIR}"
assert_cmd "plugin dashboard generator renders command failures" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  fake_repo="${tmp_dir}/fake-repo"
  mkdir -p "${fake_repo}/hooks" "${fake_repo}/skills" "${fake_repo}/scripts" "${fake_repo}/vibeguard-runtime"
  touch "${fake_repo}/vibeguard-runtime/Cargo.toml"
  cat > "${fake_repo}/setup.sh" <<SH
#!/usr/bin/env bash
printf "%s\n" "fake setup unavailable" >&2
exit 127
SH
  cat > "${fake_repo}/scripts/stats.sh" <<SH
#!/usr/bin/env bash
printf "%s\n" "fake stats unavailable" >&2
exit 127
SH
  cat > "${fake_repo}/scripts/hook-health.sh" <<SH
#!/usr/bin/env bash
printf "%s\n" "fake health unavailable" >&2
exit 127
SH
  chmod +x "${fake_repo}/setup.sh" "${fake_repo}/scripts/stats.sh" "${fake_repo}/scripts/hook-health.sh"
  VIBEGUARD_REPO_DIR="${fake_repo}" bash "$1" dashboard --no-open --output "${tmp_dir}/dashboard.html" --log-file /dev/null >/dev/null
  grep -q "COMMAND FAILED" "${tmp_dir}/dashboard.html"
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"
assert_cmd "plugin health bridge runs against fake runtime" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  runtime="${tmp_dir}/vibeguard-runtime"
  cat > "${runtime}" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "observe" && "\${2:-}" == "health" ]]; then
  printf "%s\n" "fake health"
  exit 0
fi
printf "unexpected runtime command:" >&2
printf " %q" "\$@" >&2
printf "\n" >&2
exit 2
SH
  chmod +x "${runtime}"
  VIBEGUARD_RUNTIME="${runtime}" bash "$1" health --log-file /dev/null 24
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"
assert_cmd "plugin stats bridge runs against fake runtime" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  runtime="${tmp_dir}/vibeguard-runtime"
  cat > "${runtime}" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "observe" && "\${2:-}" == "summary" ]]; then
  printf "%s\n" "fake stats"
  exit 0
fi
printf "unexpected runtime command:" >&2
printf " %q" "\$@" >&2
printf "\n" >&2
exit 2
SH
  chmod +x "${runtime}"
  VIBEGUARD_RUNTIME="${runtime}" bash "$1" stats --log-file /dev/null all
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"

header "plugin manifest contract"
assert_cmd "plugin manifest validates local contract" python3 - "${PLUGIN_JSON}" "${PLUGIN_DIR}" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
plugin_dir = Path(sys.argv[2])
payload = json.loads(manifest_path.read_text(encoding="utf-8"))

def fail(message: str) -> None:
    raise SystemExit(message)

raw = manifest_path.read_text(encoding="utf-8")
if "[TODO:" in raw:
    fail("plugin manifest must not contain TODO placeholders")

if payload.get("name") != "vibeguard":
    fail("plugin name must be vibeguard")
if not re.fullmatch(r"\d+\.\d+\.\d+", payload.get("version", "")):
    fail("plugin version must be strict semver")
if payload.get("skills") != "./skills/":
    fail("plugin skills path must be ./skills/")
if not (plugin_dir / "skills").is_dir():
    fail("plugin skills directory is missing")
if "hooks" in payload:
    fail("plugin manifest must not declare hooks; setup installs hooks explicitly")
for optional_path_field in ("mcpServers", "apps"):
    if optional_path_field in payload:
        rel = payload[optional_path_field]
        if not rel.startswith("./"):
            fail(f"{optional_path_field} must be relative")
        if not (plugin_dir / rel.removeprefix("./")).exists():
            fail(f"{optional_path_field} points at a missing file")

interface = payload.get("interface")
if not isinstance(interface, dict):
    fail("interface must be an object")
for field in ("displayName", "shortDescription", "longDescription", "developerName", "category"):
    if not interface.get(field):
        fail(f"interface.{field} is required")
for asset_field in ("composerIcon", "logo"):
    if asset_field in interface:
        rel = interface[asset_field]
        if not rel.startswith("./"):
            fail(f"interface.{asset_field} must be relative")
        if not (plugin_dir / rel.removeprefix("./")).is_file():
            fail(f"interface.{asset_field} points at a missing file")
prompts = interface.get("defaultPrompt")
if not isinstance(prompts, list) or len(prompts) > 3:
    fail("interface.defaultPrompt must be a list of at most three prompts")
for prompt in prompts:
    if len(prompt) > 128:
        fail("interface.defaultPrompt entries must be 128 chars or shorter")
print("OK")
PY

header "marketplace contract"
assert_cmd "marketplace manifest validates local contract" python3 - "${MARKETPLACE_JSON}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if "[TODO:" in Path(sys.argv[1]).read_text(encoding="utf-8"):
    raise SystemExit("marketplace manifest must not contain TODO placeholders")
if payload.get("name") != "vibeguard-local":
    raise SystemExit("marketplace name must be vibeguard-local")
plugins = payload.get("plugins")
if not isinstance(plugins, list):
    raise SystemExit("plugins must be a list")
matches = [entry for entry in plugins if isinstance(entry, dict) and entry.get("name") == "vibeguard"]
if len(matches) != 1:
    raise SystemExit("marketplace must contain exactly one vibeguard entry")
entry = matches[0]
if entry.get("source") != {"source": "local", "path": "./plugins/vibeguard"}:
    raise SystemExit("vibeguard marketplace source path drifted")
if entry.get("policy", {}).get("installation") != "AVAILABLE":
    raise SystemExit("vibeguard install policy must be AVAILABLE")
if entry.get("policy", {}).get("authentication") != "ON_INSTALL":
    raise SystemExit("vibeguard auth policy must be ON_INSTALL")
if entry.get("category") != "Developer Tools":
    raise SystemExit("vibeguard marketplace category must be Developer Tools")
print("OK")
PY

header "plugin skills"
while IFS= read -r skill_file; do
  assert_cmd "skill format: ${skill_file#${REPO_DIR}/}" \
    python3 "${SKILL_VALIDATOR}" "${skill_file}"
done < <(find "${PLUGIN_DIR}/skills" -name SKILL.md -type f | sort)

echo ""
echo "==========================="
if [[ "${FAIL}" -eq 0 ]]; then
  echo "All checks passed."
else
  echo "FAILED checks (${FAIL})"
fi
echo "==========================="
echo ""

exit $((FAIL > 0 ? 1 : 0))
