#!/usr/bin/env bash
# VibeGuard Guard - W-20 runtime/tool/rule pinning drift check.

set -euo pipefail

MODE=""
SNAPSHOT=""
TOOL_INVENTORY=""
RUNTIME_INVENTORY=""
RULES_DIR=""
DECISION_LOG=""
REASON=""
HEAD="HEAD"

usage() {
  cat <<'EOF'
Usage:
  bash check_runtime_drift.sh snapshot --snapshot FILE --tool-inventory FILE [--runtime-inventory FILE] [--rules-dir DIR]
  bash check_runtime_drift.sh check    --snapshot FILE --tool-inventory FILE [--runtime-inventory FILE] [--rules-dir DIR]
  bash check_runtime_drift.sh accept   --snapshot FILE --tool-inventory FILE --decision-log FILE --reason TEXT [--runtime-inventory FILE] [--rules-dir DIR]

Tool inventory format:
  Each non-comment line must contain: <kind> <name> <description_sha256>
  Example: mcp github.get_pull_request 2b7e151628aed2a6abf7158809cf4f3c...

Exit codes:
  0  Snapshot written, no drift, or acceptance logged
  1  Runtime, tool, or rule drift detected
  2  Usage or input error
EOF
}

die_usage() {
  echo "[W-20] $1" >&2
  usage >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    snapshot|check|accept)
      [[ -z "${MODE}" ]] || die_usage "mode specified more than once"
      MODE="$1"
      shift
      ;;
    --snapshot)
      SNAPSHOT="${2:-}"
      shift 2
      ;;
    --tool-inventory)
      TOOL_INVENTORY="${2:-}"
      shift 2
      ;;
    --runtime-inventory)
      RUNTIME_INVENTORY="${2:-}"
      shift 2
      ;;
    --rules-dir)
      RULES_DIR="${2:-}"
      shift 2
      ;;
    --decision-log)
      DECISION_LOG="${2:-}"
      shift 2
      ;;
    --reason)
      REASON="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

[[ -n "${MODE}" ]] || die_usage "missing mode"
[[ -n "${SNAPSHOT}" ]] || die_usage "missing --snapshot"
[[ -n "${TOOL_INVENTORY}" ]] || die_usage "missing --tool-inventory"

if [[ "${MODE}" == "accept" ]]; then
  [[ -n "${DECISION_LOG}" ]] || die_usage "accept requires --decision-log"
  [[ -n "${REASON}" ]] || die_usage "accept requires --reason"
fi

if [[ -z "${RULES_DIR}" ]]; then
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    RULES_DIR="$(git rev-parse --show-toplevel)/rules/claude-rules"
  else
    RULES_DIR="rules/claude-rules"
  fi
fi

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  else
    shasum -a 256 "${file}" | awk '{print $1}'
  fi
}

validate_rules_dir() {
  [[ -d "${RULES_DIR}" ]] || die_usage "rules directory not found: ${RULES_DIR}"
  find "${RULES_DIR}" -type f -name '*.md' | grep -q . || die_usage "rules directory has no markdown rules: ${RULES_DIR}"
}

validate_runtime_inventory() {
  [[ -z "${RUNTIME_INVENTORY}" || -f "${RUNTIME_INVENTORY}" ]] || die_usage "runtime inventory not found: ${RUNTIME_INVENTORY}"
}

capture_runtime() {
  local tmp="$1"
  : > "${tmp}"

  if [[ -n "${RUNTIME_INVENTORY}" ]]; then
    sed 's/[[:space:]]\+$//' "${RUNTIME_INVENTORY}" >> "${tmp}"
    return
  fi

  printf 'model_id=%s\n' "${VIBEGUARD_MODEL_ID:-<unset>}" >> "${tmp}"
  local cmd
  for cmd in codex claude node python3 cargo go; do
    if command -v "${cmd}" >/dev/null 2>&1; then
      case "${cmd}" in
        go) printf '%s=%s\n' "${cmd}" "$("${cmd}" version 2>&1 | head -n 1)" >> "${tmp}" ;;
        *) printf '%s=%s\n' "${cmd}" "$("${cmd}" --version 2>&1 | head -n 1)" >> "${tmp}" ;;
      esac
    else
      printf '%s=<missing>\n' "${cmd}" >> "${tmp}"
    fi
  done
}

validate_tool_inventory() {
  [[ -f "${TOOL_INVENTORY}" ]] || die_usage "tool inventory not found: ${TOOL_INVENTORY}"
  [[ -s "${TOOL_INVENTORY}" ]] || die_usage "tool inventory is empty: ${TOOL_INVENTORY}"

  local line_no=0
  local data_lines=0
  local line kind name hash extra
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_no=$((line_no + 1))
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    data_lines=$((data_lines + 1))
    read -r kind name hash extra <<< "${line}"
    if [[ -z "${kind:-}" || -z "${name:-}" || -z "${hash:-}" || -n "${extra:-}" ]]; then
      die_usage "tool inventory line ${line_no} must be: <kind> <name> <description_sha256>"
    fi
    if [[ ! "${hash}" =~ ^[0-9a-fA-F]{64}$ ]]; then
      die_usage "tool inventory line ${line_no} has invalid description hash"
    fi
  done < "${TOOL_INVENTORY}"

  [[ "${data_lines}" -gt 0 ]] || die_usage "tool inventory has no entries: ${TOOL_INVENTORY}"
}

hash_tool_inventory() {
  validate_tool_inventory
  local tmp
  tmp="$(mktemp)"
  grep -vE '^[[:space:]]*(#|$)' "${TOOL_INVENTORY}" | sed 's/[[:space:]]\+/ /g; s/[[:space:]]$//' | LC_ALL=C sort > "${tmp}"
  sha256_file "${tmp}"
  rm -f "${tmp}"
}

hash_rules() {
  local tmp
  tmp="$(mktemp)"
  while IFS= read -r file; do
    printf '%s  %s\n' "$(sha256_file "${file}")" "${file}" >> "${tmp}"
  done < <(find "${RULES_DIR}" -type f -name '*.md' | LC_ALL=C sort)
  local digest
  digest="$(sha256_file "${tmp}")"
  rm -f "${tmp}"
  printf '%s\n' "${digest}"
}

validate_inputs_for_current_hashes() {
  validate_runtime_inventory
  validate_tool_inventory
  validate_rules_dir
}

current_hashes() {
  validate_inputs_for_current_hashes
  local runtime_tmp
  runtime_tmp="$(mktemp)"
  capture_runtime "${runtime_tmp}"
  local runtime_hash tool_hash rules_hash
  runtime_hash="$(sha256_file "${runtime_tmp}")"
  rm -f "${runtime_tmp}"
  tool_hash="$(hash_tool_inventory)"
  rules_hash="$(hash_rules)"
  printf 'runtime_hash=%s\n' "${runtime_hash}"
  printf 'tool_hash=%s\n' "${tool_hash}"
  printf 'rules_hash=%s\n' "${rules_hash}"
}

write_snapshot() {
  local hashes
  hashes="$(current_hashes)"
  mkdir -p "$(dirname "${SNAPSHOT}")"
  {
    printf '# VibeGuard W-20 runtime pinning snapshot\n'
    printf 'version=1\n'
    printf 'created_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'head=%s\n' "$(git rev-parse --verify "${HEAD}" 2>/dev/null || printf '<no-git>')"
    printf 'rules_dir=%s\n' "${RULES_DIR}"
    printf 'tool_inventory=%s\n' "${TOOL_INVENTORY}"
    [[ -n "${RUNTIME_INVENTORY}" ]] && printf 'runtime_inventory=%s\n' "${RUNTIME_INVENTORY}"
    printf '%s\n' "${hashes}"
  } > "${SNAPSHOT}"
  echo "[W-20] snapshot written: ${SNAPSHOT}"
}

read_snapshot_hashes() {
  [[ -f "${SNAPSHOT}" ]] || die_usage "snapshot not found: ${SNAPSHOT}"
  SNAP_RUNTIME=""
  SNAP_TOOL=""
  SNAP_RULES=""
  local key value
  while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    case "${key}" in
      runtime_hash) SNAP_RUNTIME="${value}" ;;
      tool_hash) SNAP_TOOL="${value}" ;;
      rules_hash) SNAP_RULES="${value}" ;;
    esac
  done < "${SNAPSHOT}"
  [[ -n "${SNAP_RUNTIME}" && -n "${SNAP_TOOL}" && -n "${SNAP_RULES}" ]] || die_usage "snapshot is missing required hashes"
}

check_drift() {
  read_snapshot_hashes
  validate_inputs_for_current_hashes
  local hashes current_runtime current_tool current_rules
  hashes="$(current_hashes)"
  current_runtime="$(awk -F= '$1=="runtime_hash"{print $2}' <<< "${hashes}")"
  current_tool="$(awk -F= '$1=="tool_hash"{print $2}' <<< "${hashes}")"
  current_rules="$(awk -F= '$1=="rules_hash"{print $2}' <<< "${hashes}")"

  local drift=0
  if [[ "${SNAP_RUNTIME}" != "${current_runtime}" ]]; then
    echo "[W-20] runtime drift: ${SNAP_RUNTIME} -> ${current_runtime}"
    drift=1
  fi
  if [[ "${SNAP_TOOL}" != "${current_tool}" ]]; then
    echo "[W-20] tools drift: ${SNAP_TOOL} -> ${current_tool}"
    drift=1
  fi
  if [[ "${SNAP_RULES}" != "${current_rules}" ]]; then
    echo "[W-20] rules drift: ${SNAP_RULES} -> ${current_rules}"
    drift=1
  fi

  if [[ "${drift}" -eq 0 ]]; then
    echo "[W-20] OK: runtime, tools, and rules match snapshot"
    return 0
  fi

  echo "[W-20] drift detected; stop or record explicit user acceptance before continuing"
  return 1
}

accept_drift() {
  local output rc
  set +e
  output="$(check_drift 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -eq 2 ]]; then
    printf '%s\n' "${output}" >&2
    return 2
  fi
  if [[ "${rc}" -eq 0 ]]; then
    echo "[W-20] no drift to accept"
    return 0
  fi

  mkdir -p "$(dirname "${DECISION_LOG}")"
  {
    printf '\n## Runtime Drift Acceptance - %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "- Snapshot: \`${SNAPSHOT}\`"
    printf '%s\n' "- Tool inventory: \`${TOOL_INVENTORY}\`"
    printf '%s\n' "- Rules directory: \`${RULES_DIR}\`"
    printf '%s\n\n' "- Reason: ${REASON}"
    printf 'Check output:\n\n'
    printf '```text\n%s\n```\n' "${output}"
  } >> "${DECISION_LOG}"
  echo "[W-20] drift acceptance recorded: ${DECISION_LOG}"
}

case "${MODE}" in
  snapshot) write_snapshot ;;
  check) check_drift ;;
  accept) accept_drift ;;
  *) die_usage "unknown mode: ${MODE}" ;;
esac
