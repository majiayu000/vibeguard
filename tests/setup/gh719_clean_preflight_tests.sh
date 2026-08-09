# GH719 clean preflight regressions kept focused outside the legacy lifecycle aggregate.
# shellcheck shell=bash

gh719_clean_preflight_runtime="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"

for gh719_legacy_state_name in \
  install-state.json.next.fixture install-state.previous.json.backup.fixture; do
  gh719_legacy_clean_home="${TMP_HOME}/gh719-legacy-clean-${gh719_legacy_state_name}"
  mkdir -p "${gh719_legacy_clean_home}/.vibeguard"
  printf '%s\n' '{"version":1,"generation":1,"complete":true,"files":{}}' \
    > "${gh719_legacy_clean_home}/.vibeguard/${gh719_legacy_state_name}"
  printf '%s\n' 'must-survive' > "${gh719_legacy_clean_home}/.vibeguard/run-hook.sh"
  gh719_legacy_clean_rc=0
  HOME="${gh719_legacy_clean_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_clean_preflight_runtime}" \
    bash "${REPO_DIR}/setup.sh" --clean >/dev/null 2>&1 || gh719_legacy_clean_rc=$?
  assert_cmd "clean rejects legacy ${gh719_legacy_state_name} before mutation" \
    test "${gh719_legacy_clean_rc}" -ne 0
  assert_cmd "failed clean preserves assets for legacy ${gh719_legacy_state_name}" \
    test -f "${gh719_legacy_clean_home}/.vibeguard/run-hook.sh"
done

for gh719_exact_case in extra source-mismatch; do
  gh719_exact_home="${TMP_HOME}/gh719-exact-preflight-${gh719_exact_case}"
  gh719_exact_dest="${gh719_exact_home}/.codex/skills/plan-flow"
  gh719_exact_quarantine="${gh719_exact_home}/.codex/skills/.plan-flow.vibeguard-quarantine.kept"
  gh719_exact_transaction="${gh719_exact_home}/.codex/skills/.plan-flow.vibeguard-transaction.kept.json"
  mkdir -p "${gh719_exact_home}/.vibeguard/installed" "${gh719_exact_quarantine}"
  printf '%s\n' 'snapshot-must-survive' > "${gh719_exact_home}/.vibeguard/installed/version"
  printf 'hello' > "${gh719_exact_quarantine}/SKILL.md"
  python3 - "${gh719_exact_home}/.vibeguard/install-state.json" \
    "${gh719_exact_dest}" "${gh719_exact_quarantine}" \
    "${gh719_exact_transaction}" "${gh719_exact_case}" <<'PY'
import hashlib, json, sys
state_path, dest, quarantine, transaction_path, case = sys.argv[1:]
tracked_source = "skills/other/SKILL.md" if case == "source-mismatch" else "skills/plan-flow/SKILL.md"
entry = {
    "source": tracked_source,
    "type": "copy",
    "checksum": "sha256:" + hashlib.sha256(b"hello").hexdigest(),
}
files = {dest + "/SKILL.md": entry}
canonical = json.dumps(files, sort_keys=True, separators=(",", ":"))
digest = "sha256:" + hashlib.sha256(canonical.encode()).hexdigest()
record = {
    "version": 1,
    "quarantine": quarantine,
    "transaction": transaction_path,
    "source_prefix": "skills/plan-flow",
    "tracked_digest": digest,
    "install_state_generation": 1,
    "nonce": "kept",
}
state = {
    "version": 1,
    "generation": 1,
    "complete": True,
    "files": files,
    "disabled_skill_quarantines": {dest: record},
}
transaction = dict(record, phase="committed", dest=dest)
json.dump(state, open(state_path, "w", encoding="utf-8"))
json.dump(transaction, open(transaction_path, "w", encoding="utf-8"))
PY
  if [[ "${gh719_exact_case}" == "extra" ]]; then
    printf '%s\n' 'untracked' > "${gh719_exact_quarantine}/EXTRA.md"
  fi
  gh719_exact_state_hash="$(shasum -a 256 \
    "${gh719_exact_home}/.vibeguard/install-state.json" | awk '{print $1}')"
  gh719_exact_install_rc=0
  HOME="${gh719_exact_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_clean_preflight_runtime}" \
    bash "${REPO_DIR}/setup.sh" --yes --profile core >/dev/null 2>&1 || gh719_exact_install_rc=$?
  assert_cmd "${gh719_exact_case} active quarantine fails install preflight" \
    test "${gh719_exact_install_rc}" -ne 0
  assert_cmd "${gh719_exact_case} preflight preserves installed snapshot" \
    grep -qx 'snapshot-must-survive' "${gh719_exact_home}/.vibeguard/installed/version"
  assert_cmd "${gh719_exact_case} preflight preserves install-state bytes" test \
    "$(shasum -a 256 "${gh719_exact_home}/.vibeguard/install-state.json" | awk '{print $1}')" = \
    "${gh719_exact_state_hash}"
done

gh719_alias_clean_home="${TMP_HOME}/gh719-alias-clean-home"
mkdir -p "${gh719_alias_clean_home}/.vibeguard/installed/bin" \
  "${gh719_alias_clean_home}/bin" "${gh719_alias_clean_home}/.config/systemd/user"
cp "${gh719_clean_preflight_runtime}" \
  "${gh719_alias_clean_home}/.vibeguard/installed/bin/vibeguard-runtime"
chmod +x "${gh719_alias_clean_home}/.vibeguard/installed/bin/vibeguard-runtime"
printf '%s\n' 'must-survive' > "${gh719_alias_clean_home}/.vibeguard/run-hook.sh"
ln -s ../.vibeguard/installed/bin/vibeguard-runtime \
  "${gh719_alias_clean_home}/bin/vibeguard-runtime"
printf '%s\n' 'not-vibeguard' \
  > "${gh719_alias_clean_home}/.config/systemd/user/vibeguard-gc.service"
gh719_alias_clean_rc=0
gh719_alias_clean_out="$(
  cd "${gh719_alias_clean_home}" && HOME="${gh719_alias_clean_home}" \
    VIBEGUARD_SETUP_RUNTIME=bin/vibeguard-runtime VIBEGUARD_SETUP_SKIP_REPO_RUNTIME=1 \
    bash "${REPO_DIR}/setup.sh" --clean 2>&1
)" || gh719_alias_clean_rc=$?
assert_cmd "relative runtime alias clean reaches the injected cleanup failure" \
  test "${gh719_alias_clean_rc}" -ne 0
assert_cmd "relative runtime alias clean releases the canonical setup lock" \
  test ! -e "${gh719_alias_clean_home}/.vibeguard/setup.lock"
assert_not_contains "${gh719_alias_clean_out}" "failed to release the VibeGuard setup lock" \
  "relative symlink runtime target stays pinned through lock release"
