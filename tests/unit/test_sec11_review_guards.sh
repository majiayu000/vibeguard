#!/usr/bin/env bash
# Unit tests for SEC-11 dependency/test-evolution review guards.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DEP_GUARD="${REPO_DIR}/guards/universal/check_dependency_changes.sh"
TEST_GUARD="${REPO_DIR}/guards/universal/check_test_weakening.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

run_expect() {
  local desc="$1"
  local expected="$2"
  local pattern="$3"
  shift 3

  TOTAL=$((TOTAL + 1))
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e

  if [[ "${rc}" -ne "${expected}" ]]; then
    red "${desc} (expected exit ${expected}, got ${rc})"
    printf '%s\n' "${out}" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ -n "${pattern}" ]] && ! grep -qF "${pattern}" <<< "${out}"; then
    red "${desc} (missing: ${pattern})"
    printf '%s\n' "${out}" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  green "${desc}"
  PASS=$((PASS + 1))
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

printf '\n=== SEC-11 dependency review guard ===\n'

req_diff="${TMP_DIR}/requirements.diff"
cat > "${req_diff}" <<'EOF'
diff --git a/requirements.txt b/requirements.txt
index 1111111..2222222 100644
--- a/requirements.txt
+++ b/requirements.txt
@@ -1 +1 @@
-requests==2.30.0
+requests==2.31.0
EOF
run_expect "requirements.txt version change fails" 1 "requests 2.30.0 -> 2.31.0" bash "${DEP_GUARD}" --diff "${req_diff}"

pkg_diff="${TMP_DIR}/package.diff"
cat > "${pkg_diff}" <<'EOF'
diff --git a/package.json b/package.json
index 1111111..2222222 100644
--- a/package.json
+++ b/package.json
@@ -3,7 +3,7 @@
   "version": "1.2.3",
   "dependencies": {
-    "lodash": "^4.17.20"
+    "lodash": "^4.17.21"
   }
 }
EOF
run_expect "package.json dependency version change fails" 1 "lodash ^4.17.20 -> ^4.17.21" bash "${DEP_GUARD}" --diff "${pkg_diff}"

package_version_only="${TMP_DIR}/package-version-only.diff"
cat > "${package_version_only}" <<'EOF'
diff --git a/package.json b/package.json
index 1111111..2222222 100644
--- a/package.json
+++ b/package.json
@@ -1,5 +1,5 @@
 {
   "name": "demo",
-  "version": "1.2.3",
+  "version": "1.2.4",
   "dependencies": {}
 }
EOF
run_expect "package metadata version alone passes" 0 "OK" bash "${DEP_GUARD}" --diff "${package_version_only}"

cargo_go_diff="${TMP_DIR}/cargo-go.diff"
cat > "${cargo_go_diff}" <<'EOF'
diff --git a/Cargo.toml b/Cargo.toml
index 1111111..2222222 100644
--- a/Cargo.toml
+++ b/Cargo.toml
@@ -5 +5 @@
-serde = { version = "1.0.190", features = ["derive"] }
+serde = { version = "1.0.200", features = ["derive"] }
diff --git a/go.mod b/go.mod
index 1111111..2222222 100644
--- a/go.mod
+++ b/go.mod
@@ -3 +3 @@ require (
-	golang.org/x/crypto v0.17.0
+	golang.org/x/crypto v0.18.0
 )
EOF
run_expect "Cargo.toml and go.mod dependency changes fail" 1 "golang.org/x/crypto v0.17.0 -> v0.18.0" bash "${DEP_GUARD}" --diff "${cargo_go_diff}"

printf '\n=== SEC-11 test evolution guard ===\n'

weaken_diff="${TMP_DIR}/assert-weaken.diff"
cat > "${weaken_diff}" <<'EOF'
diff --git a/src/calc.py b/src/calc.py
index 1111111..2222222 100644
--- a/src/calc.py
+++ b/src/calc.py
@@ -1,2 +1,2 @@
 def add(a, b):
-    return a + b
+    return int(a) + int(b)
diff --git a/tests/test_calc.py b/tests/test_calc.py
index 1111111..2222222 100644
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -1,4 +1,4 @@
 def test_add():
-    assertEqual(add(1, 2), 3)
+    assertTrue(add(1, 2))
EOF
run_expect "assertEqual to assertTrue fails with source+test diff" 1 "assertion weakened" bash "${TEST_GUARD}" --diff "${weaken_diff}"

removed_assertion_diff="${TMP_DIR}/removed-assertion.diff"
cat > "${removed_assertion_diff}" <<'EOF'
diff --git a/src/service.ts b/src/service.ts
index 1111111..2222222 100644
--- a/src/service.ts
+++ b/src/service.ts
@@ -1 +1 @@
-export const ok = false;
+export const ok = true;
diff --git a/src/service.test.ts b/src/service.test.ts
index 1111111..2222222 100644
--- a/src/service.test.ts
+++ b/src/service.test.ts
@@ -1,4 +1,3 @@
 test("works", () => {
-  expect(run()).toEqual("done");
   run();
 });
EOF
run_expect "removed assertion fails with source+test diff" 1 "assertion removed" bash "${TEST_GUARD}" --diff "${removed_assertion_diff}"

skip_diff="${TMP_DIR}/skip.diff"
cat > "${skip_diff}" <<'EOF'
diff --git a/lib/user.js b/lib/user.js
index 1111111..2222222 100644
--- a/lib/user.js
+++ b/lib/user.js
@@ -1 +1 @@
-export const active = false;
+export const active = true;
diff --git a/lib/user.test.js b/lib/user.test.js
index 1111111..2222222 100644
--- a/lib/user.test.js
+++ b/lib/user.test.js
@@ -1,4 +1,4 @@
-test("active user", () => {
+test.skip("active user", () => {
   expect(active).toBe(true);
 });
EOF
run_expect "added skip marker fails with source+test diff" 1 "skip marker added" bash "${TEST_GUARD}" --diff "${skip_diff}"

test_only_diff="${TMP_DIR}/test-only.diff"
cat > "${test_only_diff}" <<'EOF'
diff --git a/tests/test_calc.py b/tests/test_calc.py
index 1111111..2222222 100644
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -1,4 +1,4 @@
 def test_add():
-    assertEqual(add(1, 2), 3)
+    assertEqual(add(1, 2), 3)
EOF
run_expect "test-only non-weakening diff passes" 0 "OK" bash "${TEST_GUARD}" --diff "${test_only_diff}"

new_ai_test_diff="${TMP_DIR}/new-ai-test.diff"
cat > "${new_ai_test_diff}" <<'EOF'
diff --git a/tests/test_new_flow.py b/tests/test_new_flow.py
new file mode 100644
index 0000000..2222222
--- /dev/null
+++ b/tests/test_new_flow.py
@@ -0,0 +1,3 @@
+def test_flow():
+    assert run_flow()
EOF
run_expect "AI co-authored new test requires human intent restatement" 1 "human must restate the test intent" \
  bash "${TEST_GUARD}" --diff "${new_ai_test_diff}" --commit-message "Co-authored-by: Claude <noreply@anthropic.com>"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "${TOTAL}" "${PASS}" "${FAIL}"
[[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0
