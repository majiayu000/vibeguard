#!/usr/bin/env bash
# #430 self-application: Rust hook/guard paths must use the runtime test classifier.
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

failures=0

if grep -Eq 'TEST_PATH_PATTERN=' "${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh"; then
  echo "FAIL: check_unwrap_in_prod.sh must not define its own test path pattern"
  failures=$((failures + 1))
fi

function_body() {
  local fn_name="$1" file="$2"
  awk -v fn="${fn_name}" '
    $0 ~ "^" fn "\\(\\) \\{" { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { exit }
  ' "${file}"
}

for fn in vg_post_edit_detect_rust vg_post_edit_detect_hardcoded_db_path vg_post_edit_detect_u16_size; do
  body="$(function_body "${fn}" "${REPO_DIR}/hooks/_lib/post_edit_quality.sh")"
  if ! grep -Fq 'vg_post_edit_is_test_path "$FILE_PATH"' <<< "${body}"; then
    echo "FAIL: ${fn} must use vg_post_edit_is_test_path"
    failures=$((failures + 1))
  fi
  if grep -Eq '\*/tests/\*|\*/examples/\*|\*/benches/\*|\*_test\.rs|\*/test_\*' <<< "${body}"; then
    echo "FAIL: ${fn} must not reintroduce inline Rust test-path globs"
    failures=$((failures + 1))
  fi
done

if ! grep -Fq 'test-path-filter' "${REPO_DIR}/guards/rust/common.sh"; then
  echo "FAIL: guards/rust/common.sh must consume vibeguard-runtime test-path-filter"
  failures=$((failures + 1))
fi

if ! grep -Fq 'test-path-filter' "${REPO_DIR}/hooks/_lib/post_edit_quality.sh"; then
  echo "FAIL: post_edit_quality.sh must consume vibeguard-runtime test-path-filter"
  failures=$((failures + 1))
fi

if [[ "${failures}" -gt 0 ]]; then
  exit 1
fi

echo "OK: Rust hook/guard test-path classification uses runtime classifier"
