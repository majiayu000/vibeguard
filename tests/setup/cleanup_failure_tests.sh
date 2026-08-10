cleanup_real_runtime="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
cleanup_fixture_version="$(tr -d '[:space:]' < "${REPO_DIR}/vibeguard-runtime/VERSION")"
assert_cmd "cleanup failure fixtures have a real runtime delegate" \
  test -x "${cleanup_real_runtime}"

md_cleanup_failure_home="${TMP_HOME}/md-cleanup-failure-home"
md_cleanup_failure_runtime="${TMP_HOME}/md-cleanup-failure-runtime"
mkdir -p "${md_cleanup_failure_home}/.claude" \
  "${md_cleanup_failure_home}/.codex" \
  "${md_cleanup_failure_home}/.vibeguard/dist/${cleanup_fixture_version}"
printf '<!-- vibeguard-start -->\nmanaged\n<!-- vibeguard-end -->\n' \
  > "${md_cleanup_failure_home}/.claude/CLAUDE.md"
printf '<!-- vibeguard-start -->\nmanaged\n<!-- vibeguard-end -->\n' \
  > "${md_cleanup_failure_home}/.codex/AGENTS.md"
printf '#!/usr/bin/env bash\n' \
  > "${md_cleanup_failure_home}/.vibeguard/run-hook-codex.sh"
printf 'verified payload\n' \
  > "${md_cleanup_failure_home}/.vibeguard/dist/${cleanup_fixture_version}/payload"
cat > "${md_cleanup_failure_runtime}" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "setup-md-remove" \
  && "\${2:-}" == "${md_cleanup_failure_home}/.claude/CLAUDE.md" ]]; then
  exit 42
fi
exec "${cleanup_real_runtime}" "\$@"
SH
chmod +x "${md_cleanup_failure_runtime}"
md_cleanup_failure_rc=0
HOME="${md_cleanup_failure_home}" \
  VIBEGUARD_SETUP_RUNTIME="${md_cleanup_failure_runtime}" \
  bash "${REPO_DIR}/setup.sh" --clean >/dev/null 2>&1 \
  || md_cleanup_failure_rc=$?
assert_cmd "CLAUDE.md helper failure aborts clean" \
  test "${md_cleanup_failure_rc}" -ne 0
assert_cmd "CLAUDE.md helper failure preserves high-context files and recovery payload" bash -c \
  'test -f "$1" && test -f "$2" && test -f "$3" && test -f "$4"' _ \
  "${md_cleanup_failure_home}/.claude/CLAUDE.md" \
  "${md_cleanup_failure_home}/.codex/AGENTS.md" \
  "${md_cleanup_failure_home}/.vibeguard/run-hook-codex.sh" \
  "${md_cleanup_failure_home}/.vibeguard/dist/${cleanup_fixture_version}/payload"

hooks_cleanup_failure_home="${TMP_HOME}/hooks-cleanup-failure-home"
hooks_cleanup_failure_runtime="${TMP_HOME}/hooks-cleanup-failure-runtime"
mkdir -p "${hooks_cleanup_failure_home}/.codex" \
  "${hooks_cleanup_failure_home}/.vibeguard/dist/${cleanup_fixture_version}"
printf '<!-- vibeguard-start -->\nmanaged\n<!-- vibeguard-end -->\n' \
  > "${hooks_cleanup_failure_home}/.codex/AGENTS.md"
printf '{"hooks":{"PreToolUse":[]}}\n' \
  > "${hooks_cleanup_failure_home}/.codex/hooks.json"
printf '#!/usr/bin/env bash\n' \
  > "${hooks_cleanup_failure_home}/.vibeguard/run-hook-codex.sh"
printf 'verified payload\n' \
  > "${hooks_cleanup_failure_home}/.vibeguard/dist/${cleanup_fixture_version}/payload"
cat > "${hooks_cleanup_failure_runtime}" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "setup-codex-hooks-remove" \
  && "\${2:-}" == "${REPO_DIR}" ]]; then
  exit 43
fi
exec "${cleanup_real_runtime}" "\$@"
SH
chmod +x "${hooks_cleanup_failure_runtime}"
hooks_cleanup_failure_rc=0
HOME="${hooks_cleanup_failure_home}" \
  VIBEGUARD_SETUP_RUNTIME="${hooks_cleanup_failure_runtime}" \
  bash "${REPO_DIR}/setup.sh" --clean >/dev/null 2>&1 \
  || hooks_cleanup_failure_rc=$?
assert_cmd "Codex hooks helper failure aborts clean" \
  test "${hooks_cleanup_failure_rc}" -ne 0
assert_cmd "Codex hooks helper failure preserves hooks, wrapper, and recovery payload" bash -c \
  'test -f "$1" && test -f "$2" && test -f "$3"' _ \
  "${hooks_cleanup_failure_home}/.codex/hooks.json" \
  "${hooks_cleanup_failure_home}/.vibeguard/run-hook-codex.sh" \
  "${hooks_cleanup_failure_home}/.vibeguard/dist/${cleanup_fixture_version}/payload"

rm_cleanup_failure_home="${TMP_HOME}/rm-cleanup-failure-home"
rm_cleanup_failure_bin="${TMP_HOME}/rm-cleanup-failure-bin"
rm_cleanup_failure_runtime="${TMP_HOME}/rm-cleanup-failure-runtime"
rm_cleanup_failure_skill="${rm_cleanup_failure_home}/.codex/skills/vibeguard"
rm_cleanup_real="$(command -v rm)"
mkdir -p "${rm_cleanup_failure_home}/.vibeguard/_lib" \
  "${rm_cleanup_failure_home}/.vibeguard/dist/${cleanup_fixture_version}" \
  "${rm_cleanup_failure_skill}" "${rm_cleanup_failure_bin}"
printf 'managed skill\n' > "${rm_cleanup_failure_skill}/SKILL.md"
python3 - "${rm_cleanup_failure_skill}" \
  "${rm_cleanup_failure_home}/.vibeguard/install-state.json" <<'PY'
import hashlib, json, sys
skill_dir, state_path = sys.argv[1:]
content = open(f"{skill_dir}/SKILL.md", "rb").read()
state = {
    "version": 1,
    "generation": 1,
    "complete": True,
    "files": {
        f"{skill_dir}/SKILL.md": {
            "source": "skills/vibeguard/SKILL.md",
            "type": "copy",
            "checksum": f"sha256:{hashlib.sha256(content).hexdigest()}",
        }
    },
}
with open(state_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
PY
printf '#!/usr/bin/env bash\n' \
  > "${rm_cleanup_failure_home}/.vibeguard/run-hook-codex.sh"
printf '#!/usr/bin/env bash\n' \
  > "${rm_cleanup_failure_home}/.vibeguard/_lib/codex_diag.sh"
printf 'verified payload\n' \
  > "${rm_cleanup_failure_home}/.vibeguard/dist/${cleanup_fixture_version}/payload"
cat > "${rm_cleanup_failure_runtime}" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "setup-codex-hooks-remove" ]]; then
  printf 'SKIP\n'
  exit 0
fi
exec "${cleanup_real_runtime}" "\$@"
SH
cat > "${rm_cleanup_failure_bin}/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\${arg}" == "${rm_cleanup_failure_skill}" ]]; then
    exit 44
  fi
done
exec "${rm_cleanup_real}" "\$@"
SH
chmod +x "${rm_cleanup_failure_runtime}" "${rm_cleanup_failure_bin}/rm"
rm_cleanup_failure_rc=0
HOME="${rm_cleanup_failure_home}" \
  PATH="${rm_cleanup_failure_bin}:${PATH}" \
  VIBEGUARD_SETUP_RUNTIME="${rm_cleanup_failure_runtime}" \
  bash "${REPO_DIR}/setup.sh" --clean >/dev/null 2>&1 \
  || rm_cleanup_failure_rc=$?
assert_cmd "managed skill removal failure aborts clean" \
  test "${rm_cleanup_failure_rc}" -ne 0
assert_cmd "managed skill removal failure preserves skill and recovery payload" bash -c \
  'test -f "$1" && test -f "$2"' _ \
  "${rm_cleanup_failure_skill}/SKILL.md" \
  "${rm_cleanup_failure_home}/.vibeguard/dist/${cleanup_fixture_version}/payload"
