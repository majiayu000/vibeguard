#!/usr/bin/env bash
# VibeGuard Rust Guard: Detect inconsistencies between action semantics and side effects (RS-13)
#
# Target question:
# - The function/tool name contains action semantics such as done/update/delete/remove/add/create/set etc.
# - But there is no visible state writing or event emission in the function body, which may be "semantic promise not fulfilled"
#
# Usage:
#   bash check_semantic_effect.sh [target_dir]
#   bash check_semantic_effect.sh --strict [target_dir]
#
# Allow list:
# Create .vibeguard-semantic-effect-allowlist in the root directory of the target warehouse
# One function name per line (such as mark_done)

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

ALLOWLIST_FILE="${TARGET_DIR}/.vibeguard-semantic-effect-allowlist"
ALLOWLIST_AWK=""
if [[ -f "${ALLOWLIST_FILE}" ]]; then
  while IFS= read -r name; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    ALLOWLIST_AWK="${ALLOWLIST_AWK}${name}\n"
  done < "${ALLOWLIST_FILE}"
fi

TMP_RS=$(create_tmpfile)
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_|_test\.rs$)' || true; } \
  > "${TMP_RS}"

if [[ ! -s "${TMP_RS}" ]]; then
  echo "No Rust source files found."
  exit 0
fi

REPORT=$(while IFS= read -r f; do
  [[ -f "${f}" ]] || continue
  lower_path="$(printf '%s' "${f}" | tr '[:upper:]' '[:lower:]')"
  # Focus on behavioral command-related modules to reduce false positives for pure functions
  if [[ "${lower_path}" != *task* && "${lower_path}" != *todo* && "${lower_path}" != *tool* && "${lower_path}" != *command* ]]; then
    continue
  fi

  awk -v file="${f}" -v allowlist="${ALLOWLIST_AWK}" '
    BEGIN {
      IGNORECASE = 1
      n = split(allowlist, arr, "\n")
      for (i = 1; i <= n; i++) {
        if (arr[i] != "") skip[arr[i]] = 1
      }
      in_fn = 0
      brace_depth = 0
    }

    function is_action_name(name) {
      lname = tolower(name)
      if (lname ~ /(^|_)(mark_)?done$/) return 1
      if (lname ~ /^(update|delete|remove|add|create|set)_[a-z0-9_]+$/) return 1
      if (lname ~ /^(task|todo).*(done|update|delete|remove|add|create)$/) return 1
      return 0
    }

    {
      line = $0

      if (!in_fn) {
        if (line ~ /fn[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
          fn_name = line
          sub(/^.*fn[[:space:]]+/, "", fn_name)
          sub(/[^A-Za-z0-9_].*$/, "", fn_name)
          if (is_action_name(fn_name) && !(fn_name in skip)) {
            in_fn = 1
            start_line = NR
            has_effect = 0
            has_result = 0
            brace_depth = 0
          }
        }
      }

      if (in_fn) {
        lower = tolower(line)
        # Visible status writing/event emission signal
        if (lower ~ /\.(insert|push|remove|retain|update|replace|set)[[:space:]]*\(/ ||
            lower ~ /::(insert|push|remove|update|set|replace|write)[[:space:]]*\(/ ||
            lower ~ /(^|[^[:alnum:]_])(write|save|commit|emit|publish|dispatch|send|persist)([^[:alnum:]_]|$)/) {
          has_effect = 1
        }
        # Result construction signal: usually tool output text/Result
        if (lower ~ /(ok\(|err\(|format!\(|json!\(|to_string\()/) {
          has_result = 1
        }

        tmp = line
        open_count = gsub(/\{/, "{", tmp)
        tmp = line
        close_count = gsub(/\}/, "}", tmp)
        brace_depth += open_count - close_count

        if (brace_depth <= 0 && line ~ /\}/) {
          if (!has_effect && has_result) {
            printf "%s:%d:%s\n", file, start_line, fn_name
          }
          in_fn = 0
        }
      }
    }
  ' "${f}" 2>/dev/null || true
done < "${TMP_RS}")

if [[ -z "${REPORT}" ]]; then
  echo "No semantic-effect mismatches detected."
  exit 0
fi

COUNT=$(echo "${REPORT}" | sed '/^$/d' | wc -l | tr -d ' ')
echo "[RS-13] Found ${COUNT} action-like function(s) without visible side-effects:"
while IFS= read -r line; do
  [[ -n "${line}" ]] && echo "  - ${line}"
done <<< "${REPORT}"
echo "Repair:"
echo " 1. Action functions should explicitly write status or send events (insert/update/remove/emit, etc.)"
echo " 2. If the original intention of the function is only query/format, rename it to query/format/describe semantics"
echo " 3. Pure functions can be added to .vibeguard-semantic-effect-allowlist"

if [[ "${STRICT}" == true ]]; then
  exit 1
fi
