header "package correction argv sentinel"
good_pkg_correction="${TMP_DIR}/good-pkg-correction"
mkdir -p "${good_pkg_correction}/hooks"
cat > "${good_pkg_correction}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
EOF
assert_cmd "argv-only package correction passes" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${good_pkg_correction}"

good_runtime_pkg_correction="${TMP_DIR}/good-runtime-pkg-correction"
mkdir -p "${good_runtime_pkg_correction}/hooks"
cat > "${good_runtime_pkg_correction}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
PRE_BASH_RESULT=$("$_VIBEGUARD_RUNTIME" pre-bash-check "$VIBEGUARD_ROOT")
CORRECTED=$(pre_bash_required_field corrected)
printf '%s\n' "$CORRECTED"
EOF
assert_cmd "runtime-owned package correction passes taint check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${good_runtime_pkg_correction}"

good_hook_runtime_pkg_correction="${TMP_DIR}/good-hook-runtime-pkg-correction"
mkdir -p "${good_hook_runtime_pkg_correction}/hooks" "${good_hook_runtime_pkg_correction}/vibeguard-runtime/src"
cat > "${good_hook_runtime_pkg_correction}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
exec "$_VIBEGUARD_RUNTIME" hook pre-bash
EOF
cat > "${good_hook_runtime_pkg_correction}/vibeguard-runtime/src/hook_checks_bash.rs" <<'EOF'
json!({
  "updatedInput": {
    "command": corrected,
  }
})
EOF
cat > "${good_hook_runtime_pkg_correction}/vibeguard-runtime/src/hook_orchestrator_pre_bash.rs" <<'EOF'
fn run() {
    println!("{}", corrected);
}
EOF
assert_cmd "runtime hook package correction passes taint check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${good_hook_runtime_pkg_correction}"

bad_runtime_pkg_eval="${TMP_DIR}/bad-runtime-pkg-eval"
mkdir -p "${bad_runtime_pkg_eval}/hooks"
cat > "${bad_runtime_pkg_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
PRE_BASH_RESULT=$("$_VIBEGUARD_RUNTIME" pre-bash-check "$VIBEGUARD_ROOT")
CORRECTED=$(pre_bash_required_field corrected)
eval "$CORRECTED"
EOF
assert_fails "runtime-owned package correction eval fails taint check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_runtime_pkg_eval}"

bad_pkg_correction="${TMP_DIR}/bad-pkg-correction"
mkdir -p "${bad_pkg_correction}/hooks"
cat > "${bad_pkg_correction}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': '$_PKG_CORRECTION'}}))
"
EOF
assert_fails "inline package correction interpolation fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_correction}"

bad_pkg_braced="${TMP_DIR}/bad-pkg-braced"
mkdir -p "${bad_pkg_braced}/hooks"
cat > "${bad_pkg_braced}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': '${_PKG_CORRECTION}'}}))
" "$_PKG_CORRECTION"
EOF
assert_fails "braced package correction interpolation fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_braced}"

bad_pkg_param_expansion="${TMP_DIR}/bad-pkg-param-expansion"
mkdir -p "${bad_pkg_param_expansion}/hooks"
cat > "${bad_pkg_param_expansion}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': '${_PKG_CORRECTION:-fallback}'}}))
" "$_PKG_CORRECTION"
EOF
assert_fails "parameter-expanded package correction interpolation fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_param_expansion}"

bad_pkg_escaped_quote="${TMP_DIR}/bad-pkg-escaped-quote"
mkdir -p "${bad_pkg_escaped_quote}/hooks"
cat > "${bad_pkg_escaped_quote}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(\"$_PKG_CORRECTION\")
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
EOF
assert_fails "escaped-quote package correction interpolation fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_escaped_quote}"

bad_pkg_single_quote_python="${TMP_DIR}/bad-pkg-single-quote-python"
mkdir -p "${bad_pkg_single_quote_python}/hooks"
cat > "${bad_pkg_single_quote_python}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c 'import json, sys
corrected = sys.argv[1]
print("'"$_PKG_CORRECTION"'")
print(json.dumps({"decision": "allow", "updatedInput": {"command": corrected}}))
' "$_PKG_CORRECTION"
EOF
assert_fails "single-quoted package correction interpolation fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_single_quote_python}"

bad_pkg_stdin_python="${TMP_DIR}/bad-pkg-stdin-python"
mkdir -p "${bad_pkg_stdin_python}/hooks"
cat > "${bad_pkg_stdin_python}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
python3 - <<PY
print("$_PKG_CORRECTION")
PY
EOF
assert_fails "stdin-fed package correction interpolation fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_stdin_python}"

bad_pkg_eval="${TMP_DIR}/bad-pkg-eval"
mkdir -p "${bad_pkg_eval}/hooks"
cat > "${bad_pkg_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
if [[ -n "$_PKG_CORRECTION" ]]; then
  eval "$_PKG_CORRECTION"
fi
EOF
assert_fails "indented shell eval of package correction fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_eval}"

bad_pkg_same_line_eval="${TMP_DIR}/bad-pkg-same-line-eval"
mkdir -p "${bad_pkg_same_line_eval}/hooks"
cat > "${bad_pkg_same_line_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
if [[ -n "$_PKG_CORRECTION" ]]; then eval "$_PKG_CORRECTION"; fi
EOF
assert_fails "same-line shell eval of package correction fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_same_line_eval}"

bad_pkg_braced_eval="${TMP_DIR}/bad-pkg-braced-eval"
mkdir -p "${bad_pkg_braced_eval}/hooks"
cat > "${bad_pkg_braced_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
if [[ -n "${_PKG_CORRECTION}" ]]; then
  bash -c "${_PKG_CORRECTION}"
fi
EOF
assert_fails "braced shell eval of package correction fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_braced_eval}"

bad_pkg_multiline_eval="${TMP_DIR}/bad-pkg-multiline-eval"
mkdir -p "${bad_pkg_multiline_eval}/hooks"
cat > "${bad_pkg_multiline_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
eval \
  "$_PKG_CORRECTION"
EOF
assert_fails "multiline shell eval of package correction fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_multiline_eval}"

bad_pkg_indirect_eval="${TMP_DIR}/bad-pkg-indirect-eval"
mkdir -p "${bad_pkg_indirect_eval}/hooks"
cat > "${bad_pkg_indirect_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
cmd="$_PKG_CORRECTION"
eval "$cmd"
EOF
assert_fails "indirect shell eval of package correction fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_indirect_eval}"

bad_pkg_indented_indirect_eval="${TMP_DIR}/bad-pkg-indented-indirect-eval"
mkdir -p "${bad_pkg_indented_indirect_eval}/hooks"
cat > "${bad_pkg_indented_indirect_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
if [[ -n "$_PKG_CORRECTION" ]]; then
  cmd="$_PKG_CORRECTION"
  eval "$cmd"
fi
EOF
assert_fails "indented indirect shell eval of package correction fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_indented_indirect_eval}"

bad_pkg_then_assignment_eval="${TMP_DIR}/bad-pkg-then-assignment-eval"
mkdir -p "${bad_pkg_then_assignment_eval}/hooks"
cat > "${bad_pkg_then_assignment_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
if true; then cmd="$_PKG_CORRECTION"; fi
eval "$cmd"
EOF
assert_fails "same-line control assignment shell eval of package correction fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_then_assignment_eval}"

bad_pkg_export_eval="${TMP_DIR}/bad-pkg-export-eval"
mkdir -p "${bad_pkg_export_eval}/hooks"
cat > "${bad_pkg_export_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
export cmd="$_PKG_CORRECTION"
eval "$cmd"
EOF
assert_fails "exported indirect shell eval of package correction fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_export_eval}"

bad_pkg_positional_eval="${TMP_DIR}/bad-pkg-positional-eval"
mkdir -p "${bad_pkg_positional_eval}/hooks"
cat > "${bad_pkg_positional_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
set -- "$_PKG_CORRECTION"
eval "$1"
EOF
assert_fails "positional shell eval of package correction fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_positional_eval}"

bad_pkg_positional_all_eval="${TMP_DIR}/bad-pkg-positional-all-eval"
mkdir -p "${bad_pkg_positional_all_eval}/hooks"
cat > "${bad_pkg_positional_all_eval}/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
_PKG_CORRECTION="pnpm install"
# PKG-CORRECTION-ARGV-CONTRACT: pass the generated command as sys.argv[1].
python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
set -- "$_PKG_CORRECTION"
eval "$@"
EOF
assert_fails "positional all shell eval of package correction fails argv check" bash "${SELF_DIR}/check-pkg-correction-argv-only.sh" "${bad_pkg_positional_all_eval}"
