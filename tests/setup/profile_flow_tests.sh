remove_claude_hook_for_test() {
  python3 - "${HOME}/.claude/settings.json" "$1" <<'PY'
import json
import shlex
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
script = sys.argv[2]
data = json.loads(settings_path.read_text(encoding="utf-8"))
hooks = data.get("hooks", {})
changed = False
for event, entries in list(hooks.items()):
    if not isinstance(entries, list):
        continue
    next_entries = []
    for entry in entries:
        if not isinstance(entry, dict):
            next_entries.append(entry)
            continue
        hook_entries = entry.get("hooks")
        if not isinstance(hook_entries, list):
            next_entries.append(entry)
            continue
        kept = []
        for hook in hook_entries:
            command = hook.get("command") if isinstance(hook, dict) else ""
            parts = shlex.split(command) if isinstance(command, str) else []
            if any(Path(part).name == script for part in parts):
                changed = True
                continue
            kept.append(hook)
        if kept:
            entry["hooks"] = kept
            next_entries.append(entry)
    if next_entries:
        hooks[event] = next_entries
    else:
        hooks.pop(event, None)
settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
raise SystemExit(0 if changed else 1)
PY
}

assert_profile_hook_missing_after_remove() {
  local script="$1" target="$2"
  remove_claude_hook_for_test "${script}" &&
    ! python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target "${target}"
}

assert_profile_hook_restored_after_repair() {
  local profile="$1" target="$2"
  bash "${REPO_DIR}/setup.sh" --yes --profile "${profile}" >/dev/null &&
    python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target "${target}"
}

header "setup --clean"
printf 'user codex note\n' >> "${HOME}/.codex/AGENTS.md"
clean_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_out}" "VibeGuard cleaned." "--clean route to cleanup process"
assert_cmd "--clean removes scheduled GC entry" assert_scheduled_gc_absent
assert_cmd "~/.claude/skills/vibeguard has been removed after cleaning" test ! -e "${HOME}/.claude/skills/vibeguard"
assert_cmd "~/.claude/commands/vibeguard has been removed after cleaning" test ! -e "${HOME}/.claude/commands/vibeguard"
assert_cmd "~/.claude/commands/vg has been removed after cleaning" test ! -e "${HOME}/.claude/commands/vg"
assert_cmd "~/.claude/skills/agentsmd-audit has been removed after cleaning" test ! -e "${HOME}/.claude/skills/agentsmd-audit"
assert_cmd "~/.claude/skills/trajectory-review has been removed after cleaning" test ! -e "${HOME}/.claude/skills/trajectory-review"
assert_cmd "~/.codex/skills/agentsmd-audit has been removed after cleaning" test ! -e "${HOME}/.codex/skills/agentsmd-audit"
assert_cmd "~/.codex/skills/trajectory-review has been removed after cleaning" test ! -e "${HOME}/.codex/skills/trajectory-review"
assert_cmd "~/.codex/hooks.json is preserved after cleaning (for non-VibeGuard hooks)" test -f "${HOME}/.codex/hooks.json"
assert_cmd "VibeGuard managed Codex AGENTS block removed after cleaning" bash -c "! grep -q 'vibeguard-start' '${HOME}/.codex/AGENTS.md'"
assert_cmd "Unmanaged Codex AGENTS content remains after cleaning" grep -q 'user codex note' "${HOME}/.codex/AGENTS.md"
assert_cmd "VibeGuard managed Codex hooks removed after cleaning" bash -c "! grep -qE 'vibeguard-(pre-bash-guard|pre-edit-guard|pre-write-guard|post-edit-guard|post-write-guard|post-build-check|stop-guard|learn-evaluator)\\.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Pre-existing non-VibeGuard hook remains after cleaning" grep -q 'node /existing/non-vibeguard.js' "${HOME}/.codex/hooks.json"
assert_cmd "legacy Codex MCP block has been removed after cleaning" bash -c "[ ! -f '${HOME}/.codex/config.toml' ] || ! grep -q '^\[mcp_servers\.vibeguard\]' '${HOME}/.codex/config.toml'"

header "setup install default languages before rust filter"
install_default_lang_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile core)"
assert_contains "${install_default_lang_out}" "manifest rules -> ~/.claude/rules/vibeguard/" "default install writes manifest native rules"
assert_cmd "default install includes Python native rules" test -L "${HOME}/.claude/rules/vibeguard/python/quality.md"
assert_cmd "default install includes Go native rules" test -L "${HOME}/.claude/rules/vibeguard/golang/quality.md"
assert_cmd "core profile hooks match manifest" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target profile-hooks:core
assert_cmd "core profile check catches missing analysis-paralysis hook" assert_profile_hook_missing_after_remove analysis-paralysis-guard.sh profile-hooks:core
core_missing_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_contains "${core_missing_out}" "[MISSING] Claude hooks missing for core profile" "setup --check reports missing core profile hook"
assert_cmd "core profile repair restores analysis-paralysis hook" assert_profile_hook_restored_after_repair core profile-hooks:core
old_profile_runtime="${TMP_HOME}/old-profile-runtime"
cat > "${old_profile_runtime}" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  setup-settings-check-supports-profile-hooks)
    printf '%s\n' 'Unknown command: setup-settings-check-supports-profile-hooks' >&2
    exit 2
    ;;
  setup-state-list-symlinks-under|setup-manifest-skill-links|setup-md-remove|setup-settings-check-stale|setup-codex-config-check-hooks|setup-codex-hooks-check-stale)
    exit 0
    ;;
  setup-settings-check)
    case "${4:-}" in
      profile-hooks:*) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "${old_profile_runtime}"
old_runtime_check_out="$(VIBEGUARD_SETUP_RUNTIME="${old_profile_runtime}" bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_not_contains "${old_runtime_check_out}" "[MISSING] Claude hooks missing for core profile" "setup --check skips stale runtime profile-hook false missing"

header "setup install --languages rust"
install_lang_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile core --languages rust)"
assert_contains "${install_lang_out}" "Languages: rust" "--languages parameter takes effect"
assert_cmd "--languages keeps common native rules" test -L "${HOME}/.claude/rules/vibeguard/common/security.md"
assert_cmd "--languages installs selected Rust native rules" test -L "${HOME}/.claude/rules/vibeguard/rust/quality.md"
assert_cmd "--languages removes unselected Python native rules" test ! -e "${HOME}/.claude/rules/vibeguard/python/quality.md"
assert_cmd "--languages removes unselected Go native rules" test ! -e "${HOME}/.claude/rules/vibeguard/golang/quality.md"
assert_cmd "--languages after installation --check executable" bash -c "bash '${REPO_DIR}/setup.sh' --check >/dev/null 2>&1"

header "setup --clean (after --languages)"
clean_lang_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_lang_out}" "VibeGuard cleaned." "languages profile cleaned successfully"

header "setup install --profile full"
install_full_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile full)"
assert_contains "${install_full_out}" "Profile: full" "full profile parameter takes effect"
assert_cmd "full profile configuration full hooks" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target full-hooks
assert_cmd "full profile hooks match manifest" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target profile-hooks:full
assert_cmd "full profile enable stop-guard" grep -q "stop-guard.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile enable learn-evaluator" grep -q "learn-evaluator.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile enable post-build-check" grep -q "post-build-check.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile check catches missing analysis-paralysis hook" assert_profile_hook_missing_after_remove analysis-paralysis-guard.sh profile-hooks:full
full_missing_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_contains "${full_missing_out}" "[MISSING] Claude hooks missing for full profile" "setup --check reports missing full profile hook"
assert_cmd "full profile repair restores manifest hooks" assert_profile_hook_restored_after_repair full profile-hooks:full

header "setup --clean (after full)"
clean_full_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_full_out}" "VibeGuard cleaned." "full profile cleaned successfully"
assert_cmd "full hooks have been removed after cleaning" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target full-hooks >/dev/null 2>&1; test \$? -ne 0"

header "setup install --profile strict"
install_strict_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile strict)"
assert_contains "${install_strict_out}" "Profile: strict" "strict profile parameter takes effect"
assert_cmd "strict profile still configures full hooks" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target full-hooks
assert_cmd "strict profile hooks match manifest" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target profile-hooks:strict
assert_cmd "strict profile enables U-32 constraint budget hook" grep -q "count_active_constraints.sh" "${HOME}/.claude/settings.json"
assert_cmd "strict profile does not enable session-tagger" bash -c "! grep -q 'session-tagger.sh' '${HOME}/.claude/settings.json' && ! grep -q 'session-tagger.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "strict profile does not enable cognitive-reminder" bash -c "! grep -q 'cognitive-reminder.sh' '${HOME}/.claude/settings.json' && ! grep -q 'cognitive-reminder.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "strict profile check catches missing U-32 constraint hook" assert_profile_hook_missing_after_remove count_active_constraints.sh profile-hooks:strict
strict_missing_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_contains "${strict_missing_out}" "[MISSING] Claude hooks missing for strict profile" "setup --check reports missing strict profile hook"
assert_cmd "strict profile repair restores U-32 hook" assert_profile_hook_restored_after_repair strict profile-hooks:strict

header "setup --clean (after strict)"
clean_strict_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_strict_out}" "VibeGuard cleaned." "strict profile cleaned successfully"
assert_cmd "strict profile clean removes U-32 constraint budget hook" bash -c "! grep -q 'count_active_constraints.sh' '${HOME}/.claude/settings.json'"
