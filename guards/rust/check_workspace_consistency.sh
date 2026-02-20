#!/usr/bin/env bash
# VibeGuard Rust Guard: 检测 workspace 跨入口配置一致性 (RS-06)
#
# 扫描 Cargo workspace 中所有入口 (bin crate)，报告：
# 1. 各入口使用的环境变量名（env::var / env::var_os / option_env!）
# 2. 各入口的硬编码路径后缀（.db / .sqlite / .json 等）
# 3. 核心库 vs 各入口是否共享路径构建逻辑
#
# 目的：防止多个 binary 使用不同的路径/env var 导致数据分裂
#
# 用法:
#   bash check_workspace_consistency.sh [workspace_dir]
#   bash check_workspace_consistency.sh --strict [workspace_dir]

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

CARGO_TOML="${TARGET_DIR}/Cargo.toml"
if [[ ! -f "${CARGO_TOML}" ]]; then
  echo "Not a Cargo workspace: ${CARGO_TOML} not found."
  exit 0
fi

# 检查是否是 workspace（有 [workspace] 或 workspace.members）
if ! grep -qE '^\[workspace\]|^workspace\.members' "${CARGO_TOML}" 2>/dev/null; then
  echo "Not a Cargo workspace (no [workspace] section). Skipping."
  exit 0
fi

echo "======================================"
echo "VibeGuard RS-06: Workspace Consistency"
echo "Workspace: ${TARGET_DIR}"
echo "======================================"
echo

# 提取 workspace members（简单解析，处理 "members = [...]" 格式）
MEMBERS=()
in_members=false
while IFS= read -r line; do
  # 跳过注释
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue

  if [[ "${line}" =~ members[[:space:]]*= ]]; then
    in_members=true
  fi

  if [[ "${in_members}" == true ]]; then
    # 提取引号中的路径
    while [[ "${line}" =~ \"([^\"]+)\" ]]; do
      MEMBERS+=("${BASH_REMATCH[1]}")
      line="${line#*\"${BASH_REMATCH[1]}\"}"
    done
    # 检查是否到了数组结束
    if [[ "${line}" =~ \] ]]; then
      in_members=false
    fi
  fi
done < "${CARGO_TOML}"

# 展开 glob 模式（如 "crates/*" → crates/foo, crates/bar）
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

# --- 检查 1: 环境变量使用 ---
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

# --- 检查 2: 硬编码文件路径 ---
echo "--- Hardcoded File Paths ---"
echo

for member in "${MEMBERS[@]}"; do
  member_dir="${TARGET_DIR}/${member}"
  [[ -d "${member_dir}/src" ]] || continue

  member_name=$(basename "${member}")
  paths=$(grep -rnoE '"[^"]*\.(db|sqlite|json|toml|yaml|yml|log)"' "${member_dir}/src/" 2>/dev/null \
    | { grep -vE '(/tests/|/test_|_test\.rs:)' || true; }) || true

  if [[ -n "${paths}" ]]; then
    echo "  [${member_name}]"
    while IFS= read -r p; do
      echo "    ${p}"
    done <<< "${paths}"
    echo
  fi
done

# --- 检查 3: 数据目录构建方式 ---
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

# --- 检查 4: 跨入口一致性分析 ---
echo "--- Consistency Analysis ---"
echo

# 收集所有入口的 env var
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

# 找出语义相似但名称不同的 env var（如 *_DB_PATH, *_DATABASE_URL）
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
  echo "  修复：统一到单个 env var（如 APP_DB_PATH），在 core 层提供 resolve_db_path() 公共函数，所有入口调用该函数。"
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

# 检查硬编码的数据库文件名是否一致
declare -A DB_FILE_MEMBERS
for member in "${MEMBERS[@]}"; do
  member_dir="${TARGET_DIR}/${member}"
  [[ -d "${member_dir}/src" ]] || continue

  member_name=$(basename "${member}")
  db_files=$(grep -rhoE '"[^"]*\.(db|sqlite)"' "${member_dir}/src/" 2>/dev/null \
    | { grep -v '/tests/' || true; } \
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
  echo "  风险：不同 binary 创建各自的数据库文件，导致数据分裂。"
  echo "  修复：在 core 层定义 default_db_path() 返回唯一路径，所有入口统一调用。参考 vibeguard/workflows/auto-optimize/rules/universal.md U-11。"
  echo
  FOUND=$((FOUND + 1))
fi

# --- 总结 ---
echo "======================================"
if [[ ${FOUND} -eq 0 ]]; then
  echo "No cross-entry consistency issues detected."
else
  echo "Found ${FOUND} potential consistency issue(s)."
  echo ""
  echo "总体修复策略：在 core/共享库 中创建统一的配置/路径解析函数，所有入口调用同一函数。"
  echo "环境变量用统一前缀（如 APP_），数据路径用 dirs::data_local_dir() 统一基目录。"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
