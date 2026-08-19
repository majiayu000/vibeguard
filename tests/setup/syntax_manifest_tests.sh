header "setup scripts syntax"
assert_cmd "executable payload templates declare deterministic LF checkout" bash -c '
  set -euo pipefail
  repo_dir="$1"
  shift
  for relative_path in "$@"; do
    test "$(git -C "${repo_dir}" check-attr eol -- "${relative_path}")" \
      = "${relative_path}: eol: lf"
    ! LC_ALL=C grep -q $'\''\r'\'' "${repo_dir}/${relative_path}"
  done
' _ "${REPO_DIR}" \
  scripts/setup/bootstrap_birth_token.jxa \
  scripts/systemd/vibeguard-gc.service \
  scripts/systemd/vibeguard-gc.timer \
  scripts/release/payload-manifest.txt \
  claude-md/CLAUDE.md \
  templates/AGENTS.md
assert_cmd "setup.sh syntax is correct" bash -n "${REPO_DIR}/setup.sh"
assert_cmd "scripts/setup/install.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/install.sh"
assert_cmd "source runtime build does not call cargo metadata" assert_prepare_runtime_from_source_no_cargo_metadata
assert_cmd "scripts/setup/check.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/check.sh"
assert_not_contains "$(cat "${REPO_DIR}/scripts/setup/check.sh")" \
  "TS/Rust AST guards will SKIP" \
  "setup health check has no obsolete ast-grep requirement"
assert_cmd "scripts/setup/clean.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/clean.sh"
assert_cmd "scripts/setup/markdown-compat.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/markdown-compat.sh"
assert_cmd "scripts/setup/runtime-clean-pin.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/runtime-clean-pin.sh"
assert_cmd "scripts/setup/codex-status.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/codex-status.sh"
assert_cmd "scripts/codex-contract-check.sh syntax is correct" bash -n "${REPO_DIR}/scripts/codex-contract-check.sh"
assert_cmd "scripts/project-init.sh syntax is correct" bash -n "${REPO_DIR}/scripts/project-init.sh"
assert_cmd "scripts/health-report-scheduled.sh syntax is correct" bash -n "${REPO_DIR}/scripts/health-report-scheduled.sh"
assert_cmd "scripts/install-health-report-scheduler.sh syntax is correct" bash -n "${REPO_DIR}/scripts/install-health-report-scheduler.sh"
assert_cmd "scripts/install-systemd.sh syntax is correct" bash -n "${REPO_DIR}/scripts/install-systemd.sh"
assert_cmd "scripts/lib/install-state.sh syntax is correct" bash -n "${REPO_DIR}/scripts/lib/install-state.sh"
assert_cmd "scripts/lib/settings_json.py syntax is correct" python3 -m py_compile "${SETTINGS_HELPER}"
assert_cmd "scripts/lib/hooks_manifest.py syntax is correct" python3 -m py_compile "${HOOKS_MANIFEST_HELPER}"
assert_cmd "scripts/lib/project_config_validate.py syntax is correct" python3 -m py_compile "${PROJECT_CONFIG_HELPER}"
assert_cmd "scripts/lib/claude_md.py syntax is correct" python3 -m py_compile "${REPO_DIR}/scripts/lib/claude_md.py"
assert_cmd "CLAUDE.md helper counts canonical non-numeric rule ids" python3 - "${REPO_DIR}" <<'PY'
import subprocess
import sys
from pathlib import Path

repo_dir = Path(sys.argv[1])
sys.path.insert(0, str(repo_dir / "scripts/lib"))
import claude_md

canonical = subprocess.check_output(
    [
        sys.executable,
        str(repo_dir / "scripts/lib/vibeguard_manifest.py"),
        "rule-ids",
        "--source",
        "canonical",
    ],
    text=True,
).splitlines()
assert "TASTE-ANSI" in canonical
assert claude_md.count_rule_headings(repo_dir / "rules/claude-rules") == len(canonical)
_, _, injected = claude_md.render_injected(
    "/tmp/vibeguard-missing-target.md",
    str(repo_dir / "claude-md/vibeguard-rules.md"),
    str(repo_dir),
    127,
)
assert f"`{repo_dir}/workflows/references/routing-contract.md`" in injected
assert "`workflows/references/routing-contract.md`" not in injected.split("<!-- vibeguard-start -->", 1)[-1]

prose = (
    "Codex-only Computer Use notes.\n"
    "Do not paste raw <!-- vibeguard-start --> or <!-- vibeguard-end --> here.\n"
)
prose_target = Path("/tmp/vibeguard-prose-markers.md")
prose_target.write_text(prose)
action, original, appended = claude_md.render_injected(
    str(prose_target),
    str(repo_dir / "claude-md/vibeguard-rules.md"),
    str(repo_dir),
    127,
)
assert action == "APPENDED"
assert original == prose
assert appended.startswith(prose)
assert appended.count("<!-- vibeguard-start -->") == 2
assert "# VibeGuard shared core" in appended
assert claude_md.count_managed_blocks(prose) == 0
assert claude_md.count_managed_blocks(appended) == 1
inline_heading_prose = (
    "Prose <!-- vibeguard-start -->\n"
    "# VibeGuard shared core\n"
    "more prose <!-- vibeguard-end -->\n"
)
assert claude_md.count_managed_blocks(inline_heading_prose) == 0
fenced_example = (
    "```markdown\n"
    "<!-- vibeguard-start -->\n"
    "# VibeGuard shared core\n"
    "example\n"
    "<!-- vibeguard-end -->\n"
    "```\n"
)
assert claude_md.count_managed_blocks(fenced_example) == 0
crlf = (
    "Before\r\n\r\n"
    "<!-- vibeguard-start -->\r\n"
    "# VibeGuard shared core\r\n"
    "old\r\n"
    "<!-- vibeguard-end -->\r\n\r\n"
    "After\r\n"
)
crlf_target = Path("/tmp/vibeguard-crlf-markers.md")
crlf_target.write_bytes(crlf.encode())
action, _, crlf_updated = claude_md.render_injected(
    str(crlf_target),
    str(repo_dir / "claude-md/vibeguard-rules.md"),
    str(repo_dir),
    127,
)
assert action == "UPDATED"
assert crlf_updated.startswith("Before\n\n<!-- vibeguard-start -->\n")
assert crlf_updated.endswith("<!-- vibeguard-end -->\n\nAfter\r\n")
PY
mode_preview_home="${TMP_HOME}/mode-preview-home"
mkdir -p "${mode_preview_home}/.vibeguard"
printf '%s\n' dev-linked-repo > "${mode_preview_home}/.vibeguard/execution-mode"
assert_cmd "requested default mode overrides persisted dev-linked mode for host rule previews" env \
  HOME="${mode_preview_home}" VIBEGUARD_SETUP_DEV_LINKED=0 bash -c '
    source "$1/scripts/setup/lib.sh"
    source "$1/scripts/setup/targets/claude-home.sh"
    source "$1/scripts/setup/targets/codex-home.sh"
    test "$(_claude_execution_root)" = "$HOME/.vibeguard/installed"
    test "$(_codex_execution_root)" = "$HOME/.vibeguard/installed"
  ' _ "${REPO_DIR}"
assert_cmd "legacy managed-span ignores fenced marker examples" bash -c '
  source "$1/scripts/setup/lib.sh"
  fenced="$2"
  printf "%s\n" "\`\`\`markdown" "<!-- vibeguard-start -->" "# VibeGuard shared core" "example" "<!-- vibeguard-end -->" "\`\`\`" > "$fenced"
  test "$(setup_md_legacy_managed_span "$fenced")" = "0 0 0"
' _ "${REPO_DIR}" "${TMP_HOME}/legacy-fenced-example.md"
assert_cmd "legacy compatibility prepares unmanaged fenced examples without sed address zero" bash -c '
  source "$1/scripts/setup/lib.sh"
  setup_md_legacy_prepare_target "$2" "$3" TEST_START TEST_END
  grep -qF TEST_START "$3"
  grep -qF TEST_END "$3"
' _ "${REPO_DIR}" "${TMP_HOME}/legacy-fenced-example.md" "${TMP_HOME}/legacy-fenced-compat.md"
assert_cmd "legacy compatibility preserves CRLF outside managed markers" bash -c '
  source "$1/scripts/setup/lib.sh"
  printf "Before\r\n<!-- vibeguard-start -->\r\n# VibeGuard shared core\r\nold\r\n<!-- vibeguard-end -->\r\nAfter\r\n" > "$2"
  setup_md_legacy_prepare_target "$2" "$3" TEST_START TEST_END
  printf "Before\r\n<!-- vibeguard-start -->\r\n# VibeGuard shared core\r\nold\r\n<!-- vibeguard-end -->\r\nAfter\r\n" > "$4"
  cmp "$3" "$4"
' _ "${REPO_DIR}" "${TMP_HOME}/legacy-crlf.md" "${TMP_HOME}/legacy-crlf-compat.md" "${TMP_HOME}/legacy-crlf-expected.md"
assert_cmd "managed rule banner ignores fenced examples before the detected block" bash -c '
  source "$1/scripts/setup/lib.sh"
  printf "%s\n" "\`\`\`markdown" "<!-- vibeguard-start -->" "# VibeGuard shared core" "999 rules total" "<!-- vibeguard-end -->" "\`\`\`" "<!-- vibeguard-start -->" "# VibeGuard shared core" "127 rules total" "<!-- vibeguard-end -->" > "$2"
  test "$(vibeguard_managed_rule_banner_count "$2")" = 127
' _ "${REPO_DIR}" "${TMP_HOME}/managed-banner-fenced.md"
assert_cmd "legacy read-only diff stages outside an unwritable target directory" bash -c '
  source "$1/scripts/setup/lib.sh"
  mkdir -p "$2"
  printf "%s\n" "user content" > "$2/AGENTS.md"
  chmod 555 "$2"
  trap '\''chmod 755 "$2"'\'' EXIT
  setup_runtime() { printf "SKIP\n"; }
  TMPDIR="$3" setup_md_legacy_call setup-md-diff-inject "$2/AGENTS.md" "$1/claude-md/vibeguard-codex-rules.md" unused-root 127 >/dev/null
' _ "${REPO_DIR}" "${TMP_HOME}/legacy-read-only" "${TMP_HOME}"
assert_cmd "legacy rendering prequotes production routing paths with spaces" bash -c '
  source "$1/scripts/setup/lib.sh"
  printf "%s\n" "user content" > "$2"
  setup_runtime() {
    grep -qF "\`/tmp/Vibe Guard snapshot/workflows/references/routing-contract.md\`" "$3" || return 1
    printf "SKIP\n"
  }
  TMPDIR="$3" setup_md_legacy_call setup-md-diff-inject "$2" "$1/claude-md/vibeguard-codex-rules.md" "/tmp/Vibe Guard snapshot" 127 >/dev/null
' _ "${REPO_DIR}" "${TMP_HOME}/legacy-routing.md" "${TMP_HOME}"
assert_cmd "legacy restoration failure is fail-visible and preserves the target" bash -c '
  source "$1/scripts/setup/lib.sh"
  printf "%s\n" "user content" > "$2"
  cp "$2" "$3"
  sed_calls=0
  sed() {
    sed_calls=$((sed_calls + 1))
    if [[ "${sed_calls}" -eq 3 ]]; then
      return 1
    fi
    command sed "$@"
  }
  setup_runtime() {
    printf "%s\n" "<!-- vibeguard-start -->" "# VibeGuard shared core" "127 rules total" "<!-- vibeguard-end -->" >> "$2"
    printf "UPDATED\n"
  }
  ! setup_md_legacy_call setup-md-inject "$2" "$1/claude-md/vibeguard-codex-rules.md" unused-root 127 >/dev/null 2>&1
  cmp "$2" "$3"
' _ "${REPO_DIR}" "${TMP_HOME}/legacy-restore-failure.md" "${TMP_HOME}/legacy-restore-original.md"
assert_cmd "setup shell rule counter counts canonical non-numeric rule ids" bash -c "
  set -euo pipefail
  source '${REPO_DIR}/scripts/setup/lib.sh'
  source '${REPO_DIR}/scripts/setup/targets/claude-home.sh'
  actual=\"\$(claude_rule_id_count '${REPO_DIR}/rules/claude-rules')\"
  expected=\"\$(python3 '${REPO_DIR}/scripts/lib/vibeguard_manifest.py' rule-ids --source canonical | wc -l | tr -d ' ')\"
  test \"\${actual}\" = \"\${expected}\"
"
assert_cmd "scripts/lib/codex_hooks_json.py syntax is correct" python3 -m py_compile "${CODEX_HOOKS_HELPER}"
assert_cmd "scripts/lib/codex_config_toml.py syntax is correct" python3 -m py_compile "${CODEX_CONFIG_HELPER}"
assert_cmd "Codex wrapper syntax is correct" bash -n "${REPO_DIR}/hooks/run-hook-codex.sh"
assert_cmd "Codex physical alias shells are absent" bash -c "! compgen -G '${REPO_DIR}/hooks/vibeguard-*.sh' >/dev/null"
assert_cmd "scripts/setup/regenerate-hooks-from-manifest.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/regenerate-hooks-from-manifest.sh"
assert_cmd "scripts/ci/validate-hooks-manifest.sh syntax is correct" bash -n "${REPO_DIR}/scripts/ci/validate-hooks-manifest.sh"
assert_cmd "CLAUDE.md template uses generated rule count placeholder" grep -q "__VIBEGUARD_RULE_COUNT__" "${REPO_DIR}/claude-md/vibeguard-rules.md"

header "setup help"
setup_help_rc=0
setup_help_out="$(bash "${REPO_DIR}/setup.sh" --help 2>&1)" || setup_help_rc=$?
TOTAL=$((TOTAL + 1))
if [[ "${setup_help_rc}" == "0" ]]; then
  green "setup.sh --help exits 0"
  PASS=$((PASS + 1))
else
  red "setup.sh --help exits 0 (exit code: ${setup_help_rc})"
  FAIL=$((FAIL + 1))
fi
assert_contains "${setup_help_out}" "Usage: bash setup.sh" "setup.sh --help prints usage"
assert_contains "${setup_help_out}" "--profile minimal|core|full|strict" "setup.sh --help documents profiles"
assert_contains "${setup_help_out}" "--purge-data" "setup.sh --help documents clean purge option"
assert_not_contains "${setup_help_out}" "unknown argument" "setup.sh --help does not report unknown argument"

header "install-state argv safety"
install_state_home="${TMP_HOME}/install-state quote ' home"
install_state_repo="${TMP_HOME}/repo quote ' newline"$'\n'"dir"
install_state_dest="${install_state_home}/tracked quote ' newline"$'\n'"file.txt"
install_state_source="generated/source quote ' newline"$'\n'"file.txt"
install_state_hook="${install_state_home}/project/.git/hooks/pre-commit"
install_state_profile="core quote ' profile"
install_state_languages="rust,py'thon"$'\n'"go"
mkdir -p "${install_state_home}/.vibeguard" "$(dirname "${install_state_dest}")" "$(dirname "${install_state_hook}")" "${install_state_repo}"
printf '%s' "${install_state_repo}" > "${install_state_home}/.vibeguard/repo-path"
printf 'tracked\n' > "${install_state_dest}"
ln -s "${install_state_home}/.vibeguard/pre-commit" "${install_state_hook}"
assert_cmd "install-state accepts quoted/newline values via argv" env \
  HOME="${install_state_home}" \
  SPECIAL_PROFILE="${install_state_profile}" \
  SPECIAL_LANGUAGES="${install_state_languages}" \
  SPECIAL_DEST="${install_state_dest}" \
  SPECIAL_SOURCE="${install_state_source}" \
  SPECIAL_HOOK="${install_state_hook}" \
  bash -c '
    set -euo pipefail
    source "$1"
    state_init "$SPECIAL_PROFILE" "$SPECIAL_LANGUAGES"
    state_record_file "$SPECIAL_DEST" "$SPECIAL_SOURCE" "copy"
    state_record_project_hook "$PWD" "$SPECIAL_HOOK" "pre-commit"
    state_check_drift >/dev/null
    state_list >/dev/null
    state_list_project_hooks | grep -q "$SPECIAL_HOOK"
  ' bash "${REPO_DIR}/scripts/lib/install-state.sh"
assert_cmd "install-state preserves quoted/newline JSON values" python3 - \
  "${install_state_home}/.vibeguard/install-state.json" \
  "${install_state_profile}" \
  "${install_state_languages}" \
  "${install_state_repo}" \
  "${install_state_dest}" \
  "${install_state_source}" \
  "${install_state_hook}" <<'PY'
import json
import sys

state_file, profile, languages, repo_dir, dest, source, hook = sys.argv[1:8]
with open(state_file, encoding="utf-8") as f:
    state = json.load(f)

entry = state["files"][dest]
hook_entry = state["project_hooks"][hook]
assert state["profile"] == profile
assert state["languages"] == languages.split(",")
assert state["repo_dir"] == repo_dir
assert entry["source"] == source
assert entry["type"] == "copy"
assert entry["checksum"].startswith("sha256:")
assert hook_entry["hook_name"] == "pre-commit"
PY

header "manifest skill enumeration failure"
manifest_failure_stdout="${TMP_HOME}/manifest-failure.stdout"
manifest_failure_stderr="${TMP_HOME}/manifest-failure.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER=/bin/false; manifest_skill_links_checked '~/.claude/skills/'" >"${manifest_failure_stdout}" 2>"${manifest_failure_stderr}"; then
  red "manifest skill enumeration fails on helper error (expected failure)"
  FAIL=$((FAIL + 1))
else
  green "manifest skill enumeration fails on helper error"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
manifest_failure_err="$(cat "${manifest_failure_stderr}")"
assert_contains "${manifest_failure_err}" "failed to enumerate manifest skills" "manifest skill enumeration failure is visible on stderr"
assert_cmd "manifest skill enumeration failure leaves stdout empty" test ! -s "${manifest_failure_stdout}"

manifest_empty_helper="${TMP_HOME}/empty-manifest-helper.py"
cat > "${manifest_empty_helper}" <<'PY'
#!/usr/bin/env python3
raise SystemExit(0)
PY
manifest_empty_stdout="${TMP_HOME}/manifest-empty.stdout"
manifest_empty_stderr="${TMP_HOME}/manifest-empty.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER='${manifest_empty_helper}'; manifest_skill_links_checked '~/.claude/skills/'" >"${manifest_empty_stdout}" 2>"${manifest_empty_stderr}"; then
  red "manifest skill enumeration fails on empty target output (expected failure)"
  FAIL=$((FAIL + 1))
else
  green "manifest skill enumeration fails on empty target output"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
manifest_empty_err="$(cat "${manifest_empty_stderr}")"
assert_contains "${manifest_empty_err}" "no manifest skills declared for ~/.claude/skills/" "manifest skill empty target failure is visible on stderr"
assert_cmd "manifest skill empty target leaves stdout empty" test ! -s "${manifest_empty_stdout}"

manifest_whitespace_helper="${TMP_HOME}/whitespace-manifest-helper.py"
cat > "${manifest_whitespace_helper}" <<'PY'
#!/usr/bin/env python3
print("   ")
raise SystemExit(0)
PY
manifest_whitespace_stdout="${TMP_HOME}/manifest-whitespace.stdout"
manifest_whitespace_stderr="${TMP_HOME}/manifest-whitespace.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER='${manifest_whitespace_helper}'; manifest_skill_links_checked '~/.claude/skills/'" >"${manifest_whitespace_stdout}" 2>"${manifest_whitespace_stderr}"; then
  red "manifest skill enumeration fails on whitespace-only target output (expected failure)"
  FAIL=$((FAIL + 1))
else
  green "manifest skill enumeration fails on whitespace-only target output"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
manifest_whitespace_err="$(cat "${manifest_whitespace_stderr}")"
assert_contains "${manifest_whitespace_err}" "no manifest skills declared for ~/.claude/skills/" "manifest skill whitespace-only target failure is visible on stderr"

cleanup_whitespace_stdout="${TMP_HOME}/cleanup-whitespace.stdout"
cleanup_whitespace_stderr="${TMP_HOME}/cleanup-whitespace.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER='${manifest_whitespace_helper}'; manifest_skill_links_for_cleanup '~/.claude/skills/'" >"${cleanup_whitespace_stdout}" 2>"${cleanup_whitespace_stderr}"; then
  red "cleanup skill enumeration unexpectedly accepts whitespace-only target output"
  FAIL=$((FAIL + 1))
else
  green "cleanup skill enumeration rejects whitespace-only target output"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
cleanup_whitespace_err="$(cat "${cleanup_whitespace_stderr}")"
assert_contains "${cleanup_whitespace_err}" "no manifest skills declared for ~/.claude/skills/" "cleanup whitespace-only target warning is visible on stderr"
assert_cmd "cleanup whitespace-only target leaves stdout empty" test ! -s "${cleanup_whitespace_stdout}"

header "clean continues when manifest skill enumeration fails"
broken_clean_home="${TMP_HOME}/broken-clean-home"
mkdir -p \
  "${broken_clean_home}/.claude/commands" \
  "${broken_clean_home}/.claude/agents" \
  "${broken_clean_home}/.claude/context-profiles" \
  "${broken_clean_home}/.claude/rules/vibeguard/common" \
  "${broken_clean_home}/.codex" \
  "${broken_clean_home}/.vibeguard"
ln -s "${REPO_DIR}/.claude/commands/vibeguard" "${broken_clean_home}/.claude/commands/vibeguard"
ln -s "${REPO_DIR}/.claude/commands/vg" "${broken_clean_home}/.claude/commands/vg"
touch "${broken_clean_home}/.claude/agents/dispatcher.md"
touch "${broken_clean_home}/.claude/context-profiles/dev.md"
touch "${broken_clean_home}/.claude/rules/vibeguard/common/security.md"
touch "${broken_clean_home}/.vibeguard/run-hook-codex.sh"
python3 "${SETTINGS_HELPER}" upsert-vibeguard --settings-file "${broken_clean_home}/.claude/settings.json" --repo-dir "${REPO_DIR}" --profile full >/dev/null
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${broken_clean_home}/.codex/hooks.json" --wrapper "${broken_clean_home}/.vibeguard/run-hook-codex.sh" >/dev/null
broken_clean_out="$(
  HOME="${broken_clean_home}" bash -c "
    set -euo pipefail
    source '${REPO_DIR}/scripts/setup/lib.sh'
    source '${REPO_DIR}/scripts/lib/install-state.sh'
    source '${REPO_DIR}/scripts/setup/targets/claude-home.sh'
    source '${REPO_DIR}/scripts/setup/targets/codex-home.sh'
    MANIFEST_HELPER=/bin/false
    clean_claude_home_installation
    clean_codex_home_installation
  " 2>&1
)"
assert_contains "${broken_clean_out}" "skipping skill link cleanup" "clean warns when manifest skill enumeration fails"
assert_cmd "clean continues after Claude manifest failure" test ! -e "${broken_clean_home}/.claude/commands/vibeguard"
assert_cmd "clean removes Claude vg shortcut commands after manifest failure" test ! -e "${broken_clean_home}/.claude/commands/vg"
assert_cmd "clean removes Claude agents after manifest failure" test ! -e "${broken_clean_home}/.claude/agents/dispatcher.md"
assert_cmd "clean removes Claude rules after manifest failure" test ! -e "${broken_clean_home}/.claude/rules/vibeguard"
assert_cmd "clean removes Claude hooks after manifest failure" bash -c "! grep -q 'pre-bash-guard.sh' '${broken_clean_home}/.claude/settings.json'"
assert_cmd "clean continues after Codex manifest failure" bash -c "! grep -q 'vibeguard-pre-bash-guard.sh' '${broken_clean_home}/.codex/hooks.json'"
assert_cmd "clean removes Codex wrapper after manifest failure" test ! -e "${broken_clean_home}/.vibeguard/run-hook-codex.sh"

header "clean preserves unmanaged Claude command paths"
unmanaged_commands_home="${TMP_HOME}/unmanaged-commands-home"
mkdir -p \
  "${unmanaged_commands_home}/.claude/commands/vg" \
  "${unmanaged_commands_home}/.vibeguard"
printf 'custom shortcut\n' > "${unmanaged_commands_home}/.claude/commands/vg/custom.md"
unmanaged_commands_clean_out="$(
  HOME="${unmanaged_commands_home}" bash -c "
    set -euo pipefail
    source '${REPO_DIR}/scripts/setup/lib.sh'
    source '${REPO_DIR}/scripts/lib/install-state.sh'
    source '${REPO_DIR}/scripts/setup/targets/claude-home.sh'
    clean_claude_home_installation
  " 2>&1
)"
assert_contains "${unmanaged_commands_clean_out}" "Preserved unmanaged vg shortcut commands path" "clean warns before preserving unmanaged vg commands directory"
assert_cmd "clean preserves unmanaged vg commands directory" test -f "${unmanaged_commands_home}/.claude/commands/vg/custom.md"

header "retired manifest skill cleanup"
retired_home="${TMP_HOME}/retired-skill-home"
mkdir -p \
  "${retired_home}/.claude/skills" \
  "${retired_home}/.codex/skills" \
  "${retired_home}/.vibeguard"
ln -s "${REPO_DIR}/skills/vibeguard" "${retired_home}/.claude/skills/vibeguard"
ln -s "${REPO_DIR}/skills/eval-harness" "${retired_home}/.claude/skills/eval-harness"
ln -s "${REPO_DIR}/skills/old-retired" "${retired_home}/.claude/skills/old-retired"
ln -s "${REPO_DIR}/skills/user-skill" "${retired_home}/.claude/skills/user-skill"
mkdir -p "${retired_home}/.claude/skills/old-dir"
ln -s "${REPO_DIR}/workflows/old-flow" "${retired_home}/.codex/skills/old-flow"
python3 - <<'PY' "${retired_home}"
import json
import sys
from pathlib import Path

home = Path(sys.argv[1])
state = {
    "version": 1,
    "files": {
        str(home / ".claude/skills/vibeguard"): {"source": "skills/vibeguard", "type": "symlink"},
        str(home / ".claude/skills/eval-harness"): {"source": "skills/eval-harness", "type": "symlink"},
        str(home / ".claude/skills/old-retired"): {"source": "skills/old-retired", "type": "symlink"},
        str(home / ".claude/skills/old-dir"): {"source": "skills/old-dir", "type": "symlink"},
        str(home / ".codex/skills/old-flow"): {"source": "workflows/old-flow", "type": "symlink"},
    },
}
(home / ".vibeguard/install-state.json").write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
PY
retired_cleanup_out="$(
  HOME="${retired_home}" bash -c "
    set -euo pipefail
    source '${REPO_DIR}/scripts/setup/lib.sh'
    source '${REPO_DIR}/scripts/lib/install-state.sh'
    cleanup_retired_manifest_skill_links '~/.claude/skills/' '${retired_home}/.claude/skills'
    cleanup_retired_manifest_skill_links '~/.codex/skills/' '${retired_home}/.codex/skills'
  " 2>&1
)"
assert_contains "${retired_cleanup_out}" "Removed retired VibeGuard skill link" "retired skill cleanup reports removed managed links"
assert_cmd "retired cleanup removes retired Claude vibeguard skill" test ! -L "${retired_home}/.claude/skills/vibeguard"
assert_cmd "retired cleanup keeps active manifest Claude skill" test -L "${retired_home}/.claude/skills/eval-harness"
assert_cmd "retired cleanup removes tracked retired Claude skill" test ! -L "${retired_home}/.claude/skills/old-retired"
assert_cmd "retired cleanup removes tracked retired Codex skill" test ! -L "${retired_home}/.codex/skills/old-flow"
assert_cmd "retired cleanup preserves untracked user skill" test -L "${retired_home}/.claude/skills/user-skill"
assert_cmd "retired cleanup preserves retired regular directories" test -d "${retired_home}/.claude/skills/old-dir"
