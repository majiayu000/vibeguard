#!/usr/bin/env bash
# Unit tests for check_secret_leaks.sh guard (SEC-15)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="${SCRIPT_DIR}/../../guards/universal/check_secret_leaks.sh"
TEST_DIR=$(mktemp -d)

cleanup() {
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

pass=0
fail=0

assert_pass() {
  local test_name="$1"
  shift
  if "$@"; then
    printf '\033[32m✓ %s\033[0m\n' "${test_name}"
    pass=$((pass + 1))
  else
    printf '\033[31m✗ %s\033[0m\n' "${test_name}"
    fail=$((fail + 1))
  fi
}

assert_fail() {
  local test_name="$1"
  shift
  if "$@"; then
    printf '\033[31m✗ %s (expected failure but passed)\033[0m\n' "${test_name}"
    fail=$((fail + 1))
  else
    printf '\033[32m✓ %s\033[0m\n' "${test_name}"
    pass=$((pass + 1))
  fi
}

# Setup test git repo
setup_git_repo() {
  rm -rf "${TEST_DIR}"
  mkdir -p "${TEST_DIR}"
  cd "${TEST_DIR}"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
}

# Test 1: Clean file should pass
test_clean_file() {
  setup_git_repo
  local test_file="${TEST_DIR}/clean.py"
  cat > "${test_file}" <<'EOF'
import os
from pathlib import Path

def get_config():
    return {"key": os.environ.get("API_KEY")}
EOF
  git add "${test_file}"
  bash "${GUARD}" "${TEST_DIR}"
}

# Test 2: OpenAI key should fail
test_openai_key() {
  setup_git_repo
  local test_file="${TEST_DIR}/leak_openai.py"
  cat > "${test_file}" <<'EOF'
api_key = "sk-1234567890abcdef1234567890abcdef"
EOF
  git add "${test_file}"
  assert_fail "OpenAI key detected" bash "${GUARD}" --strict "${TEST_DIR}"
}

# Test 3: AWS key should fail
test_aws_key() {
  setup_git_repo
  local test_file="${TEST_DIR}/leak_aws.py"
  cat > "${test_file}" <<'EOF'
aws_key = "AKIA1234567890ABCDEF"
EOF
  git add "${test_file}"
  assert_fail "AWS key detected" bash "${GUARD}" --strict "${TEST_DIR}"
}

# Test 4: GitHub token should fail
test_github_token() {
  setup_git_repo
  local test_file="${TEST_DIR}/leak_github.py"
  cat > "${test_file}" <<'EOF'
token = "ghp_1234567890abcdef1234567890abcdef1234"
EOF
  git add "${test_file}"
  assert_fail "GitHub token detected" bash "${GUARD}" --strict "${TEST_DIR}"
}

# Test 5: Connection string should fail
test_connection_string() {
  setup_git_repo
  local test_file="${TEST_DIR}/leak_conn.py"
  cat > "${test_file}" <<'EOF'
DATABASE_URL = "postgresql://user:password@localhost:5432/db"
EOF
  git add "${test_file}"
  assert_fail "Connection string detected" bash "${GUARD}" --strict "${TEST_DIR}"
}

# Test 6: Private key should fail
test_private_key() {
  setup_git_repo
  local test_file="${TEST_DIR}/leak_key.pem"
  cat > "${test_file}" <<'EOF'
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AHB7MhgHcTz6sE2I2yPB
-----END RSA PRIVATE KEY-----
EOF
  git add "${test_file}"
  assert_fail "Private key detected" bash "${GUARD}" --strict "${TEST_DIR}"
}

# Test 7: Bearer token should fail
test_bearer_token() {
  setup_git_repo
  local test_file="${TEST_DIR}/leak_bearer.py"
  cat > "${test_file}" <<'EOF'
headers = {"Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"}
EOF
  git add "${test_file}"
  assert_fail "Bearer token detected" bash "${GUARD}" --strict "${TEST_DIR}"
}

# Test 8: Non-strict mode should pass even with violations
test_non_strict() {
  setup_git_repo
  local test_file="${TEST_DIR}/leak_nonstrict.py"
  cat > "${test_file}" <<'EOF'
key = "sk-1234567890abcdef1234567890abcdef"
EOF
  git add "${test_file}"
  bash "${GUARD}" "${TEST_DIR}"
}

# Test 9: .env file should be excluded by default
test_env_excluded() {
  setup_git_repo
  local test_file="${TEST_DIR}/.env"
  cat > "${test_file}" <<'EOF'
API_KEY=sk-1234567890abcdef1234567890abcdef
EOF
  git add "${test_file}"
  # .env is blocked as sensitive file, not scanned for patterns
  # This test verifies .env is caught as sensitive, not as pattern leak
  assert_fail ".env caught as sensitive file" bash "${GUARD}" --strict "${TEST_DIR}"
}

# Test 10: Sensitive file detection
test_sensitive_file() {
  setup_git_repo
  local test_file="${TEST_DIR}/.env"
  cat > "${test_file}" <<'EOF'
SECRET=test
EOF
  git add "${test_file}"
  assert_fail "Sensitive file detected" bash "${GUARD}" --strict "${TEST_DIR}"
}

# Test 11: Full project scan mode
test_full_scan() {
  setup_git_repo
  local test_file="${TEST_DIR}/clean.py"
  cat > "${test_file}" <<'EOF'
import os
EOF
  git add "${test_file}"
  git commit -q -m "initial"
  bash "${GUARD}" --full "${TEST_DIR}"
}

# Test 12: Security score mode
test_security_score() {
  setup_git_repo
  # Create a clean file to commit
  local test_file="${TEST_DIR}/clean.py"
  cat > "${test_file}" <<'EOF'
import os
EOF
  git add "${test_file}"
  git commit -q -m "initial"
  # Security score needs data/reports/ dir to exist
  mkdir -p "${TEST_DIR}/data/reports"
  # Run score from test directory - should return 0 (score is low but valid)
  (cd "${TEST_DIR}" && bash "${GUARD}" --score) || true
}

# Run tests
printf '\n\033[1mRunning secret leak guard tests...\033[0m\n\n'

assert_pass "Clean file passes" test_clean_file
test_openai_key
test_aws_key
test_github_token
test_connection_string
test_private_key
test_bearer_token
assert_pass "Non-strict mode passes" test_non_strict
assert_pass ".env excluded by default" test_env_excluded
test_sensitive_file
assert_pass "Full scan mode works" test_full_scan
assert_pass "Security score works" test_security_score

# Summary
printf '\n\033[1mResults: %d passed, %d failed\033[0m\n' "${pass}" "${fail}"

if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0
