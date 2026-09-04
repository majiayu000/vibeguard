#!/usr/bin/env bash
# VibeGuard Project Init — Inspect a project and attach VibeGuard protection
#
# Detect language/framework → List available guards/rules → Print agent guidance → Install Git hooks
#
# Usage: bash project-init.sh [--no-hooks] [project_root]
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

usage() {
  printf '%s\n' \
    'Usage: project-init.sh [--no-hooks] [project_root]' \
    '' \
    'Detect the project stack, print available checks versus attachable' \
    'git-hook protection, and attach the shared pre-commit and pre-push' \
    'hooks when they are installed. Unknown-language repositories still' \
    'get git-hook protection; only language-specific guards are omitted.' \
    '' \
    'Options:' \
    '  --no-hooks  Inspect and print guidance without modifying Git hooks.' \
    '  -h, --help  Show this help.' \
    '' \
    'No AGENTS.md or CLAUDE.md file is modified.'
}

INSTALL_HOOKS=1
PROJECT_ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-hooks)
      INSTALL_HOOKS=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      if [[ $# -gt 0 ]]; then
        PROJECT_ROOT="$1"
        shift
      fi
      if [[ $# -gt 0 ]]; then
        echo "ERROR: project-init accepts at most one project_root" >&2
        usage >&2
        exit 2
      fi
      break
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "${PROJECT_ROOT}" ]]; then
        echo "ERROR: project-init accepts at most one project_root" >&2
        usage >&2
        exit 2
      fi
      PROJECT_ROOT="$1"
      ;;
  esac
  shift
done

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
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
  echo "No known language marker detected."
  echo "Looked for: Cargo.toml, tsconfig.json, package.json, go.mod, pyproject.toml, requirements.txt"
  echo "Language-specific guards and repository build/test commands were not suggested."
  echo "Universal guards and git-hook protection can still be attached."
else
  echo "Language detected: ${LANGS[*]}"
  [[ ${#FRAMEWORKS[@]} -gt 0 ]] && echo "Framework detected: ${FRAMEWORKS[*]}"
fi
echo

# --- List available static guards ---
echo "--- Available static guards ---"
GUARDS_DIR="$VIBEGUARD_DIR/guards"
AVAILABLE_GUARDS=()

append_available_guards() {
  local guard_dir="$1" label="$2" guard_file
  [[ -d "${guard_dir}" ]] || return 0
  for guard_file in "${guard_dir}"/check_*.sh "${guard_dir}"/check_*.py; do
    [[ -f "${guard_file}" ]] || continue
    AVAILABLE_GUARDS+=("$(basename "${guard_file}")")
    echo "[${label}] $(basename "${guard_file}")"
  done
}

# Universal guard
append_available_guards "${GUARDS_DIR}/universal" universal

# Language Guard
if [[ ${#LANGS[@]} -gt 0 ]]; then
  for lang in "${LANGS[@]}"; do
    LANG_DIR=""
    case "$lang" in
      rust) LANG_DIR="$GUARDS_DIR/rust" ;;
      typescript|javascript) LANG_DIR="$GUARDS_DIR/typescript" ;;
      go) LANG_DIR="$GUARDS_DIR/go" ;;
      python) LANG_DIR="$GUARDS_DIR/python" ;;
    esac
    [[ -n "${LANG_DIR}" ]] && append_available_guards "${LANG_DIR}" "${lang}"
  done
fi
echo "${#AVAILABLE_GUARDS[@]} static guards available"
echo "Available checks are files in the VibeGuard checkout, not proof this project is protected."
echo

# --- List installed Claude Code native rules ---
echo "--- Installed Claude Code rules ---"
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

if [[ ${#LANGS[@]} -gt 0 ]]; then
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
fi
echo "${RULE_COUNT} Claude Code rule markers found in this home"
echo "Rule files are not the same as active host protection."
echo

# --- Report existing project guidance without modifying it ---
GUIDANCE_FILES=()
for guidance_file in AGENTS.md CLAUDE.md; do
  [[ -f "${guidance_file}" ]] && GUIDANCE_FILES+=("${guidance_file}")
done
if [[ ${#GUIDANCE_FILES[@]} -gt 0 ]]; then
  echo "Existing agent guidance: ${GUIDANCE_FILES[*]}"
else
  echo "No AGENTS.md or CLAUDE.md file found."
fi
echo "No guidance file was modified."
echo

# --- Output suggested agent-guidance fragment ---
echo "--- Suggested agent guidance snippet ---"
echo
echo '```markdown'
echo "# Project constraints"
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

echo "## VibeGuard coverage"
echo "- Available static guards: ${#AVAILABLE_GUARDS[@]} (checkout inventory, not live enforcement)"
echo "- Claude Code rule markers found in this home: ${RULE_COUNT}"
echo "- Project git-hook attachment is reported by project-init after this snippet"
echo '```'
echo "Review and save this snippet in AGENTS.md or CLAUDE.md for the agent host you use."
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

usable_hook_wrapper() {
  [[ -f "$1" && -x "$1" ]]
}

project_hook_state() {
  local hook_path="$1" expected_target="$2" actual_target=""
  if [[ ! -x "${hook_path}" ]]; then
    printf '%s\n' "inactive (existing hook is not executable)"
  elif [[ ! -L "${hook_path}" ]]; then
    printf '%s\n' "unverified (existing hook is not VibeGuard-owned)"
  else
    actual_target="$(readlink "${hook_path}" 2>/dev/null || true)"
    if [[ "${actual_target}" != "${expected_target}" ]]; then
      printf '%s\n' "unverified (existing hook is not VibeGuard-owned)"
    elif ! usable_hook_wrapper "${expected_target}"; then
      printf '%s\n' "inactive (wrapper is not an executable file)"
    else
      printf '%s\n' "attached (already present)"
    fi
  fi
}

existing_hook_state() {
  local hook_path="$1" expected_target="$2"
  if [[ -e "${hook_path}" || -L "${hook_path}" ]]; then
    project_hook_state "${hook_path}" "${expected_target}"
  else
    printf '%s\n' "not-attached"
  fi
}

sync_project_hook() {
  local hook_name="$1" wrapper="$2" hook_path="$3" state=""
  if ! usable_hook_wrapper "${wrapper}"; then
    echo " ~/.vibeguard/${hook_name} is missing, not a file, or not executable; run setup.sh first"
    if [[ -e "${hook_path}" || -L "${hook_path}" ]]; then
      state="$(project_hook_state "${hook_path}" "${wrapper}")"
    else
      state="unavailable (run setup.sh first)"
    fi
  elif [[ -e "${hook_path}" || -L "${hook_path}" ]]; then
    if [[ "${hook_name}" == "pre-commit" ]]; then
      echo ".git/hooks/pre-commit already exists, skip (manual override: ln -sf ${wrapper} ${hook_path})"
    else
      echo ".git/hooks/pre-push already exists, skip (manual overwrite: ln -sf ${wrapper} ${hook_path})"
    fi
    state="$(project_hook_state "${hook_path}" "${wrapper}")"
  else
    ln -sf "${wrapper}" "${hook_path}"
    record_project_hook_install "${hook_name}" "${hook_path}"
    echo "${hook_name} hook installed"
    state="attached"
  fi
  case "${hook_name}" in
    pre-commit) PRE_COMMIT_STATE="${state}" ;;
    pre-push) PRE_PUSH_STATE="${state}" ;;
  esac
}

PRE_COMMIT_STATE="not-attached"
PRE_PUSH_STATE="not-attached"
if [[ "${INSTALL_HOOKS}" -eq 0 ]]; then
  echo "Git hook installation skipped (--no-hooks)"
  if [[ -z "${GIT_HOOKS_DIR}" ]]; then
    PRE_COMMIT_STATE="unavailable (not a git repository)"
    PRE_PUSH_STATE="unavailable (not a git repository)"
  else
    PRE_COMMIT_STATE="$(existing_hook_state "$GIT_HOOKS_DIR/pre-commit" "$PRE_COMMIT_WRAPPER")"
    PRE_PUSH_STATE="$(existing_hook_state "$GIT_HOOKS_DIR/pre-push" "$PRE_PUSH_WRAPPER")"
  fi
elif [[ -z "${GIT_HOOKS_DIR}" ]]; then
  echo "Non-git repository, skip"
  PRE_COMMIT_STATE="unavailable (not a git repository)"
  PRE_PUSH_STATE="unavailable (not a git repository)"
else
  mkdir -p "$GIT_HOOKS_DIR"
  sync_project_hook "pre-commit" "$PRE_COMMIT_WRAPPER" "$GIT_HOOKS_DIR/pre-commit"
  sync_project_hook "pre-push" "$PRE_PUSH_WRAPPER" "$GIT_HOOKS_DIR/pre-push"
fi
echo

echo "--- Active project protection ---"
echo "Git pre-commit: ${PRE_COMMIT_STATE}"
echo "Git pre-push: ${PRE_PUSH_STATE}"
echo "Agent-host hooks are not claimed here. Inspect live install state with: bash \"${VIBEGUARD_DIR}/setup.sh\" doctor"
echo

echo "--- Next steps ---"
echo "1. Save the reviewed guidance snippet in AGENTS.md or CLAUDE.md."
echo "2. Verify this project: (cd \"${PROJECT_ROOT_ABS}\" && bash \"${VIBEGUARD_DIR}/setup.sh\" verify-project)"
echo "3. Prove interception: bash \"${VIBEGUARD_DIR}/setup.sh\" demo safe-bash"
echo

echo "=== Done ==="
