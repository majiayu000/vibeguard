#!/usr/bin/env bash
# VibeGuard Rust Guard: Detect workspace cross-entry configuration consistency (RS-06)
#
# Scan all entries (bin crates) in the Cargo workspace and report:
# 1. The environment variable name used by each entry (env::var / env::var_os / option_env!)
# 2. Hardcoded path suffix of each entry (.db / .sqlite / .json, etc.)
# 3. Whether the core library vs. each entry shares path construction logic
#
#Purpose: To prevent multiple binaries from using different paths/env var, causing data splitting
#
# Usage:
#   bash check_workspace_consistency.sh [workspace_dir]
#   bash check_workspace_consistency.sh --strict [workspace_dir]

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

CARGO_TOML="${TARGET_DIR}/Cargo.toml"
if [[ ! -f "${CARGO_TOML}" ]]; then
  echo "Not a Cargo workspace: ${CARGO_TOML} not found."
  exit 0
fi

# Check if it is a workspace (there is [workspace] or workspace.members)
if ! grep -qE '^\[workspace\]|^workspace\.members' "${CARGO_TOML}" 2>/dev/null; then
  echo "Not a Cargo workspace (no [workspace] section). Skipping."
  exit 0
fi

echo "======================================"
echo "VibeGuard RS-06: Workspace Consistency"
echo "Workspace: ${TARGET_DIR}"
echo "======================================"
echo

# Extract workspace members (simple parsing, processing "members = [...]" format)
MEMBERS=()
in_members=false
while IFS= read -r line; do
  # Skip comments
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue

  if [[ "${line}" =~ members[[:space:]]*= ]]; then
    in_members=true
  fi

  if [[ "${in_members}" == true ]]; then
    #Extract the path in quotes
    while [[ "${line}" =~ \"([^\"]+)\" ]]; do
      MEMBERS+=("${BASH_REMATCH[1]}")
      line="${line#*\"${BASH_REMATCH[1]}\"}"
    done
    # Check if the end of the array is reached
    if [[ "${line}" =~ \] ]]; then
      in_members=false
    fi
  fi
done < "${CARGO_TOML}"

# Expand glob patterns (such as "crates/*" → crates/foo, crates/bar)
EXPANDED=()
for member in "${MEMBERS[@]}"; do
  if [[ "${member}" == *"*"* || "${member}" == *"?"* ]]; then
    for expanded in ${TARGET_DIR}/${member}; do
      if [[ -d "${expanded}" && -f "${expanded}/Cargo.toml" ]]; then
        EXPANDED+=("${expanded#${TARGET_DIR}/}")
      fi
    done
  else
    EXPANDED+=("${member}")
  fi
done
MEMBERS=("${EXPANDED[@]}")

if [[ ${#MEMBERS[@]} -eq 0 ]]; then
  echo "No workspace members found."
  exit 0
fi

echo "Workspace members: ${MEMBERS[*]}"
echo

FOUND=0

# --- Check 1: Environment variable usage ---
echo "--- Environment Variables ---"
echo

for member in "${MEMBERS[@]}"; do
  member_dir="${TARGET_DIR}/${member}"
  [[ -d "${member_dir}/src" ]] || continue

  member_name=$(basename "${member}")
  envvars=$(grep -rnoE '(env::var|env::var_os|option_env!)\s*\(\s*"([^"]*)"' "${member_dir}/src/" 2>/dev/null \
    | sed -E 's/.*"([^"]*)".*/\1/' \
    | sort -u) || true

  if [[ -n "${envvars}" ]]; then
    echo "  [${member_name}]"
    while IFS= read -r var; do
      echo "    - ${var}"
    done <<< "${envvars}"
    echo
  fi
done

# --- Check 2: Hardcoded file path ---
echo "--- Hardcoded File Paths ---"
echo

for member in "${MEMBERS[@]}"; do
  member_dir="${TARGET_DIR}/${member}"
  [[ -d "${member_dir}/src" ]] || continue

  member_name=$(basename "${member}")
  # Fix RS-06: exclude comment lines (// ...) and const/static definitions which
  # are intentional named constants, not hardcoded paths.
  # Use -n (no -o) so the full source line is available for the downstream filters;
  # -o would strip context and make the const/static/comment exclusions ineffective.
  paths=$(grep -rnE '"[^"]*\.(db|sqlite|json|toml|yaml|yml|log)"' "${member_dir}/src/" 2>/dev/null \
    | { grep -vE '(/tests/|/test_|_test\.rs:|^\s*//|:[[:space:]]*//)' || true; } \
    | { grep -vE '(const[[:space:]]|static[[:space:]])' || true; }) || true

  if [[ -n "${paths}" ]]; then
    echo "  [${member_name}]"
    while IFS= read -r p; do
      echo "    ${p}"
    done <<< "${paths}"
    echo
  fi
done

# --- Check 3: Data directory construction method ---
echo "--- Data Directory Construction ---"
echo

for member in "${MEMBERS[@]}"; do
  member_dir="${TARGET_DIR}/${member}"
  [[ -d "${member_dir}/src" ]] || continue

  member_name=$(basename "${member}")
  dir_calls=$(grep -rnoE '(data_local_dir|data_dir|home_dir|config_dir|config_local_dir)\s*\(' "${member_dir}/src/" 2>/dev/null \
    | { grep -v '/tests/' || true; }) || true

  if [[ -n "${dir_calls}" ]]; then
    echo "  [${member_name}]"
    while IFS= read -r d; do
      echo "    ${d}"
    done <<< "${dir_calls}"
    echo
  fi
done

# --- Check 4: Cross-entry consistency analysis ---
echo "--- Consistency Analysis ---"
echo

# Collect env var of all entries
declare -A ENV_VAR_MEMBERS
for member in "${MEMBERS[@]}"; do
  member_dir="${TARGET_DIR}/${member}"
  [[ -d "${member_dir}/src" ]] || continue

  member_name=$(basename "${member}")
  envvars=$(grep -rhoE '(env::var|env::var_os|option_env!)\s*\(\s*"([^"]*)"' "${member_dir}/src/" 2>/dev/null \
    | sed -E 's/.*"([^"]*)".*/\1/' \
    | sort -u) || true

  while IFS= read -r var; do
    [[ -z "${var}" ]] && continue
    if [[ -n "${ENV_VAR_MEMBERS[${var}]+x}" ]]; then
      ENV_VAR_MEMBERS["${var}"]="${ENV_VAR_MEMBERS[${var}]}, ${member_name}"
    else
      ENV_VAR_MEMBERS["${var}"]="${member_name}"
    fi
  done <<< "${envvars}"
done

# Find env vars with similar semantics but different names (such as *_DB_PATH, *_DATABASE_URL)
db_vars=()
port_vars=()
host_vars=()
for var in "${!ENV_VAR_MEMBERS[@]}"; do
  lower_var=$(echo "${var}" | tr '[:upper:]' '[:lower:]')
  if [[ "${lower_var}" =~ (db|database|sqlite|storage) ]]; then
    db_vars+=("${var} (${ENV_VAR_MEMBERS[${var}]})")
  elif [[ "${lower_var}" =~ (port|listen) ]]; then
    port_vars+=("${var} (${ENV_VAR_MEMBERS[${var}]})")
  elif [[ "${lower_var}" =~ (host|addr|bind|url) ]]; then
    host_vars+=("${var} (${ENV_VAR_MEMBERS[${var}]})")
  fi
done

if [[ ${#db_vars[@]} -gt 1 ]]; then
  echo "[RS-06] Multiple database-related env vars detected:"
  for v in "${db_vars[@]}"; do
    echo "  - ${v}"
  done
  echo "Repair: Unify to a single env var (such as APP_DB_PATH), provide the resolve_db_path() public function in the core layer, and call this function at all entrances."
  echo
  FOUND=$((FOUND + 1))
fi

if [[ ${#port_vars[@]} -gt 1 ]]; then
  echo "[RS-06] Multiple port-related env vars detected:"
  for v in "${port_vars[@]}"; do
    echo "  - ${v}"
  done
  echo
  FOUND=$((FOUND + 1))
fi

if [[ ${#host_vars[@]} -gt 1 ]]; then
  echo "[RS-06] Multiple host/addr-related env vars detected:"
  for v in "${host_vars[@]}"; do
    echo "  - ${v}"
  done
  echo
  FOUND=$((FOUND + 1))
fi

# Check whether the hardcoded database file names are consistent
declare -A DB_FILE_MEMBERS
for member in "${MEMBERS[@]}"; do
  member_dir="${TARGET_DIR}/${member}"
  [[ -d "${member_dir}/src" ]] || continue

  member_name=$(basename "${member}")
  # Fix RS-06: also exclude comment lines and const/static definitions.
  # Filter on full source lines (no -o), then extract the string literal value.
  # Using -o before filtering discards the line context that the exclusion
  # patterns (const/static/comments) rely on, making those filters ineffective.
  db_files=$(grep -rnE '"[^"]*\.(db|sqlite)"' "${member_dir}/src/" 2>/dev/null \
    | { grep -vE '(/tests/|:[[:space:]]*//)' || true; } \
    | { grep -vE '(const[[:space:]]|static[[:space:]])' || true; } \
    | grep -oE '"[^"]*\.(db|sqlite)"' \
    | tr -d '"' \
    | sort -u) || true

  while IFS= read -r dbf; do
    [[ -z "${dbf}" ]] && continue
    if [[ -n "${DB_FILE_MEMBERS[${dbf}]+x}" ]]; then
      DB_FILE_MEMBERS["${dbf}"]="${DB_FILE_MEMBERS[${dbf}]}, ${member_name}"
    else
      DB_FILE_MEMBERS["${dbf}"]="${member_name}"
    fi
  done <<< "${db_files}"
done

if [[ ${#DB_FILE_MEMBERS[@]} -gt 1 ]]; then
  echo "[RS-06] Multiple database file names detected across members:"
  for dbf in "${!DB_FILE_MEMBERS[@]}"; do
    echo "  - ${dbf} → ${DB_FILE_MEMBERS[${dbf}]}"
  done
  echo "Risk: Different binaries create their own database files, resulting in data fragmentation."
  echo "Repair: Define default_db_path() in the core layer to return a unique path and call it uniformly for all entries. Refer to vibeguard/rules/universal.md U-11."
  echo
  FOUND=$((FOUND + 1))
fi

# --- Summarize ---
echo "======================================"
if [[ ${FOUND} -eq 0 ]]; then
  echo "No cross-entry consistency issues detected."
else
  echo "Found ${FOUND} potential consistency issue(s)."
  echo ""
  echo "Overall repair strategy: Create a unified configuration/path parsing function in core/shared library, and all entries call the same function."
  echo "Environment variables use a unified prefix (such as APP_), and data paths use dirs::data_local_dir() to unify the base directory."
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
