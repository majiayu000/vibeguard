#!/usr/bin/env bash
# VibeGuard Project Init — Generate project-level guard configuration for the current warehouse
#
# Detect language/framework → List activated guards/rules → Generate project-level CLAUDE.md fragment
#
# Usage: bash project-init.sh [project_root]
set -euo pipefail

# Resolve the script before entering the target repository. A relative $0 must
# remain valid after cd, and symlinked entrypoints should resolve consistently
# with setup.sh.
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "${SCRIPT_PATH}" ]]; do
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
  SCRIPT_PATH="$(readlink "${SCRIPT_PATH}")"
  [[ "${SCRIPT_PATH}" == /* ]] || SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_PATH}"
done
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
VIBEGUARD_DIR="${VIBEGUARD_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

PROJECT_ROOT="${1:-$(pwd)}"
cd "$PROJECT_ROOT" || { echo "ERROR: Unable to enter directory $PROJECT_ROOT"; exit 1; }
PROJECT_ROOT_ABS="$(pwd -P)"

if [[ -f "${VIBEGUARD_DIR}/scripts/lib/install-state.sh" ]]; then
  # shellcheck source=scripts/lib/install-state.sh
  source "${VIBEGUARD_DIR}/scripts/lib/install-state.sh"
else
  state_record_project_hook() { return 127; }
fi

echo "=== VibeGuard Project Init ==="
echo "Project: $PROJECT_ROOT"
echo

# --- Language/Framework Detection ---
LANGS=()
FRAMEWORKS=()
BUILD_CMDS=()
TEST_CMDS=()

package_json_string() {
  local path="$1"
  node -e '
const fs = require("fs");
const document = JSON.parse(fs.readFileSync("package.json", "utf8"));
const value = process.argv[1].split(".").reduce(
  (current, key) => current && typeof current === "object" ? current[key] : undefined,
  document,
);
if (typeof value === "string" && value.trim() !== "") process.stdout.write(value.trim());
' "${path}"
}

package_has_dependency() {
  local dependency="$1"
  node -e '
const fs = require("fs");
const document = JSON.parse(fs.readFileSync("package.json", "utf8"));
const name = process.argv[1];
const groups = ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"];
process.exit(groups.some((group) => document[group] && document[group][name] !== undefined) ? 0 : 1);
' "${dependency}"
}

detect_package_manager() {
  local declared manager
  declared="$(package_json_string packageManager)"
  if [[ -n "${declared}" ]]; then
    manager="${declared%%@*}"
    case "${manager}" in
      npm|pnpm|yarn|bun) printf '%s\n' "${manager}"; return 0 ;;
      *)
        echo "ERROR: unsupported packageManager in package.json: ${declared}" >&2
        return 2
        ;;
    esac
  fi
  if [[ -f pnpm-lock.yaml ]]; then
    printf '%s\n' pnpm
  elif [[ -f yarn.lock ]]; then
    printf '%s\n' yarn
  elif [[ -f bun.lock || -f bun.lockb ]]; then
    printf '%s\n' bun
  elif [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
    printf '%s\n' npm
  else
    return 1
  fi
}

append_package_commands() {
  local manager="$1" script
  for script in check typecheck build; do
    if [[ -n "$(package_json_string "scripts.${script}")" ]]; then
      BUILD_CMDS+=("${manager} run ${script}")
    fi
  done
  if [[ -n "$(package_json_string scripts.test)" ]]; then
    if [[ "${manager}" == "bun" ]]; then
      TEST_CMDS+=("bun run test")
    else
      TEST_CMDS+=("${manager} test")
    fi
  fi
}

if [[ -f package.json ]]; then
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: node is required to read project commands from package.json" >&2
    exit 1
  fi
  if ! node -e 'JSON.parse(require("fs").readFileSync("package.json", "utf8"))' 2>/dev/null; then
    echo "ERROR: package.json is malformed; refusing to invent project commands" >&2
    exit 1
  fi
fi

if [[ -f "Cargo.toml" ]]; then
  LANGS+=("rust")
  BUILD_CMDS+=("cargo check")
  TEST_CMDS+=("cargo test")
  if grep -q "actix-web\|axum\|rocket" Cargo.toml 2>/dev/null; then
    FRAMEWORKS+=("rust-web")
  fi
fi

if [[ -f "tsconfig.json" ]]; then
  LANGS+=("typescript")
  if [[ -f "package.json" ]]; then
    package_manager_rc=0
    package_manager="$(detect_package_manager)" || package_manager_rc=$?
    if [[ "${package_manager_rc}" -eq 0 ]]; then
      append_package_commands "${package_manager}"
    elif [[ "${package_manager_rc}" -eq 2 ]]; then
      exit 1
    else
      echo "INFO: package manager not detected; package.json commands were not suggested." >&2
    fi
    if package_has_dependency next; then
      FRAMEWORKS+=("nextjs")
    elif package_has_dependency react; then
      FRAMEWORKS+=("react")
    fi
  fi
elif [[ -f "package.json" ]]; then
  LANGS+=("javascript")
  package_manager_rc=0
  package_manager="$(detect_package_manager)" || package_manager_rc=$?
  if [[ "${package_manager_rc}" -eq 0 ]]; then
    append_package_commands "${package_manager}"
  elif [[ "${package_manager_rc}" -eq 2 ]]; then
    exit 1
  else
    echo "INFO: package manager not detected; package.json commands were not suggested." >&2
  fi
fi

if [[ -f "go.mod" ]]; then
  LANGS+=("go")
  BUILD_CMDS+=("go build ./...")
  TEST_CMDS+=("go test ./...")
fi

if [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then
  LANGS+=("python")
fi

if [[ ${#LANGS[@]} -eq 0 ]]; then
  echo "No known language detected, skipping."
  exit 0
fi

echo "Language detected: ${LANGS[*]}"
[[ ${#FRAMEWORKS[@]} -gt 0 ]] && echo "Frame detected: ${FRAMEWORKS[*]}"
echo

# --- List active guards ---
echo "--- activated guard ---"
GUARDS_DIR="$VIBEGUARD_DIR/guards"
ACTIVE_GUARDS=()

# Universal guard
if [[ -d "$GUARDS_DIR/universal" ]]; then
  for g in "$GUARDS_DIR/universal"/check_*.sh; do
    [[ -f "$g" ]] || continue
    ACTIVE_GUARDS+=("$(basename "$g")")
    echo "[General] $(basename "$g")"
  done
fi

# Language Guard
for lang in "${LANGS[@]}"; do
  LANG_DIR=""
  case "$lang" in
    rust) LANG_DIR="$GUARDS_DIR/rust" ;;
    typescript|javascript) LANG_DIR="$GUARDS_DIR/typescript" ;;
    go) LANG_DIR="$GUARDS_DIR/go" ;;
  esac
  if [[ -n "$LANG_DIR" ]] && [[ -d "$LANG_DIR" ]]; then
    for g in "$LANG_DIR"/check_*.sh; do
      [[ -f "$g" ]] || continue
      ACTIVE_GUARDS+=("$(basename "$g")")
      echo "  [${lang}] $(basename "$g")"
    done
  fi
done
echo "A total of ${#ACTIVE_GUARDS[@]} guards activated"
echo

# --- List activated native rules ---
echo "---Activated native rules ---"
RULES_DIR="$HOME/.claude/rules/vibeguard"
RULE_COUNT=0

if [[ -d "$RULES_DIR/common" ]]; then
  for rf in "$RULES_DIR/common"/*.md; do
    [[ -f "$rf" ]] || continue
    RC=$(grep -cE '^## [A-Z]+-[0-9]+' "$rf" 2>/dev/null || echo "0")
    RULE_COUNT=$((RULE_COUNT + RC))
    echo "[General] $(basename "$rf"): ${RC} rules"
  done
fi

for lang in "${LANGS[@]}"; do
  LANG_RULE_DIR=""
  case "$lang" in
    rust) LANG_RULE_DIR="$RULES_DIR/rust" ;;
    typescript|javascript) LANG_RULE_DIR="$RULES_DIR/typescript" ;;
    go|golang) LANG_RULE_DIR="$RULES_DIR/golang" ;;
    python) LANG_RULE_DIR="$RULES_DIR/python" ;;
  esac
  if [[ -n "$LANG_RULE_DIR" ]] && [[ -d "$LANG_RULE_DIR" ]]; then
    for rf in "$LANG_RULE_DIR"/*.md; do
      [[ -f "$rf" ]] || continue
      RC=$(grep -cE '^## [A-Z]+-[0-9]+' "$rf" 2>/dev/null || echo "0")
      RULE_COUNT=$((RULE_COUNT + RC))
      echo "[${lang}] $(basename "$rf"): ${RC} rules"
    done
  fi
done
echo "A total of ${RULE_COUNT} rules activated"
echo

# --- Check if project-level CLAUDE.md already exists ---
if [[ -f "CLAUDE.md" ]]; then
  echo "The project already has CLAUDE.md, skip generation."
  echo "It is recommended to add the following content manually:"
  echo
else
  echo "The project does not have CLAUDE.md, you can choose to generate it."
  echo
fi

# --- Output suggested CLAUDE.md fragment ---
echo "--- Suggested project CLAUDE.md snippet ---"
echo
echo '```markdown'
echo "# project constraints"
echo
echo "## build command"
if [[ ${#BUILD_CMDS[@]} -eq 0 ]]; then
  echo "- No verified build command detected; add the repository-provided command."
else
  for cmd in "${BUILD_CMDS[@]}"; do
    echo "- \`$cmd\`"
  done
fi
echo
echo "## test command"
if [[ ${#TEST_CMDS[@]} -eq 0 ]]; then
  echo "- No verified test command detected; add the repository-provided command."
else
  for cmd in "${TEST_CMDS[@]}"; do
    echo "- \`$cmd\`"
  done
fi
echo

#monorepo detection
ENTRY_POINTS=$(find . -maxdepth 3 \( -name node_modules -o -name .git -o -name target -o -name vendor -o -name dist \) -prune -o \( -name "main.rs" -o -name "main.go" \) -print 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ENTRY_POINTS" -gt 1 ]]; then
  echo "## Data consistency (Monorepo)"
  echo "Multiple entry projects (${ENTRY_POINTS} entries), pay attention to U-11~U-14 data consistency rules."
  echo
fi

echo "## VibeGuard guard"
echo "${#ACTIVE_GUARDS[@]} guards + ${RULE_COUNT} rules activated"
echo '```'
echo
# --- Automatically install git hooks ---
echo "--- Git Hooks ---"
PRE_COMMIT_WRAPPER="${HOME}/.vibeguard/pre-commit"
PRE_PUSH_WRAPPER="${HOME}/.vibeguard/pre-push"
GIT_HOOKS_DIR=""
if git -C "${PROJECT_ROOT_ABS}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! GIT_HOOKS_DIR="$(git -C "${PROJECT_ROOT_ABS}" rev-parse --path-format=absolute --git-path hooks 2>/dev/null)" \
    || [[ -z "${GIT_HOOKS_DIR}" ]]; then
    echo "ERROR: unable to resolve Git hooks directory for ${PROJECT_ROOT_ABS}" >&2
    exit 1
  fi
fi
record_project_hook_install() {
  local hook_name="$1" hook_path="$2" hook_dir abs_hook_path
  hook_dir="$(dirname "${hook_path}")"
  abs_hook_path="$(cd "${hook_dir}" && pwd -P)/$(basename "${hook_path}")"
  if ! state_record_project_hook "${PROJECT_ROOT_ABS}" "${abs_hook_path}" "${hook_name}"; then
    echo "WARN: failed to record ${hook_name} hook for setup --clean; manual removal may be needed: ${abs_hook_path}" >&2
  fi
}

if [[ -n "${GIT_HOOKS_DIR}" ]] && [[ -f "$PRE_COMMIT_WRAPPER" ]]; then
  mkdir -p "$GIT_HOOKS_DIR"
  if [[ -f "$GIT_HOOKS_DIR/pre-commit" ]]; then
    echo ".git/hooks/pre-commit already exists, skip (manual override: ln -sf $PRE_COMMIT_WRAPPER $GIT_HOOKS_DIR/pre-commit)"
  else
    ln -sf "$PRE_COMMIT_WRAPPER" "$GIT_HOOKS_DIR/pre-commit"
    record_project_hook_install "pre-commit" "${GIT_HOOKS_DIR}/pre-commit"
    echo "pre-commit hook installed"
  fi
  if [[ -f "$PRE_PUSH_WRAPPER" ]]; then
    if [[ -f "$GIT_HOOKS_DIR/pre-push" ]]; then
      echo ".git/hooks/pre-push already exists, skip (manual overwrite: ln -sf $PRE_PUSH_WRAPPER $GIT_HOOKS_DIR/pre-push)"
    else
      ln -sf "$PRE_PUSH_WRAPPER" "$GIT_HOOKS_DIR/pre-push"
      record_project_hook_install "pre-push" "${GIT_HOOKS_DIR}/pre-push"
      echo "pre-push hook installed"
    fi
  else
    echo " ~/.vibeguard/pre-push does not exist, please run setup.sh first"
  fi
elif [[ -z "${GIT_HOOKS_DIR}" ]]; then
  echo "Non-git repository, skip"
elif [[ ! -f "$PRE_COMMIT_WRAPPER" ]]; then
  echo " ~/.vibeguard/pre-commit does not exist, please run setup.sh first"
fi
echo

echo "=== Done ==="
