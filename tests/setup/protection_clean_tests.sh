header "setup protects user customizations"
python3 - <<'PY' "${HOME}/.claude/settings.json" "${HOME}"
import json
import sys
from pathlib import Path

settings = Path(sys.argv[1])
home = sys.argv[2]
data = json.loads(settings.read_text(encoding="utf-8"))
for entry in data["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        entry["hooks"][0]["command"] = f"flock /tmp/vibeguard.lock bash {home}/.vibeguard/run-hook.sh pre-bash-guard.sh"
settings.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
custom_settings_out="$(bash "${REPO_DIR}/setup.sh" --yes 2>&1)"
assert_contains "${custom_settings_out}" "preserving customized VibeGuard hook command for pre-bash-guard.sh" "setup warns when preserving customized hook command"
assert_contains "${custom_settings_out}" "~/.vibeguard/config.json present (preserved)" "setup preserves existing runtime config file"
assert_cmd "customized hook command is preserved by default" grep -q "flock /tmp/vibeguard.lock" "${HOME}/.claude/settings.json"
force_settings_out="$(bash "${REPO_DIR}/setup.sh" --yes --force-overwrite 2>&1)"
assert_contains "${force_settings_out}" "Mode: force-overwrite" "--force-overwrite mode is visible"
assert_cmd "--force-overwrite restores canonical hook command" bash -c "! grep -q 'flock /tmp/vibeguard.lock' '${HOME}/.claude/settings.json'"

_CUSTOM_RULE="${HOME}/.claude/rules/vibeguard/common/security.md"
rm -f "${_CUSTOM_RULE}"
printf 'local custom security rule\n' > "${_CUSTOM_RULE}"
rule_protect_out="$(bash "${REPO_DIR}/setup.sh" --yes 2>&1 || true)"
assert_contains "${rule_protect_out}" "refusing to overwrite modified local rule file" "setup refuses to overwrite modified local rule copies"
assert_cmd "modified local rule copy remains a regular file" bash -c "[ -f '${_CUSTOM_RULE}' ] && [ ! -L '${_CUSTOM_RULE}' ]"
rule_force_out="$(bash "${REPO_DIR}/setup.sh" --yes --force-overwrite 2>&1)"
assert_contains "${rule_force_out}" "FORCE: replacing local rule copy" "--force-overwrite reports local rule replacement"
assert_cmd "--force-overwrite restores rule symlink" test -L "${_CUSTOM_RULE}"

header "codex config helper failure propagates"
_ORIG_CODEX_CONFIG_HELPER="${REPO_DIR}/scripts/lib/codex_config_toml.py"
_BACKUP_CODEX_CONFIG_HELPER="${TMP_HOME}/codex_config_toml.py.backup"
cp "${_ORIG_CODEX_CONFIG_HELPER}" "${_BACKUP_CODEX_CONFIG_HELPER}"
cat > "${_ORIG_CODEX_CONFIG_HELPER}" <<'PY'
#!/usr/bin/env python3
raise SystemExit(42)
PY
fail_install_out="$(bash "${REPO_DIR}/setup.sh" --yes 2>&1 || true)"
cp "${_BACKUP_CODEX_CONFIG_HELPER}" "${_ORIG_CODEX_CONFIG_HELPER}"
assert_contains "${fail_install_out}" "Failed to enable hooks feature in config.toml" "setup reports hooks helper failure"
assert_cmd "setup exits before reporting success when hooks helper fails" bash -c "! grep -q 'Setup complete! All components installed.' <<< '${fail_install_out}'"

header "setup --check rejects invalid codex config"
_VALID_CODEX_CONFIG="${TMP_HOME}/config.toml.valid.backup"
cp "${HOME}/.codex/config.toml" "${_VALID_CODEX_CONFIG}"
cat > "${HOME}/.codex/config.toml" <<'TOML'
not valid toml =
[features]
hooks = true
TOML
invalid_codex_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_CONFIG}" "${HOME}/.codex/config.toml"
assert_contains "${invalid_codex_check_out}" "[BROKEN] ~/.codex/config.toml is malformed TOML" "--check reports invalid ~/.codex/config.toml"
assert_cmd "invalid config does not report hooks enabled" bash -c "! grep -qF '[OK] hooks feature enabled in config.toml' <<< '${invalid_codex_check_out}'"

header "setup --check rejects invalid UTF-8 codex config"
python3 - <<'PY' "${HOME}/.codex/config.toml"
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'[features]\nhooks = true\n\xff')
PY
invalid_utf8_codex_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_CONFIG}" "${HOME}/.codex/config.toml"
assert_contains "${invalid_utf8_codex_check_out}" "[BROKEN] ~/.codex/config.toml is malformed TOML" "--check reports invalid UTF-8 ~/.codex/config.toml"
assert_cmd "invalid UTF-8 config does not report hooks enabled" bash -c "! grep -qF '[OK] hooks feature enabled in config.toml' <<< '${invalid_utf8_codex_check_out}'"

header "setup --check validates codex AGENTS"
_VALID_CODEX_AGENTS="${TMP_HOME}/AGENTS.md.valid.backup"
cp "${HOME}/.codex/AGENTS.md" "${_VALID_CODEX_AGENTS}"
: > "${HOME}/.codex/AGENTS.md"
zero_byte_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${zero_byte_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md is 0 bytes" "--check reports 0-byte ~/.codex/AGENTS.md"
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("<!-- vibeguard-end -->", "", 1), encoding="utf-8")
PY
missing_end_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${missing_end_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md marker mismatch" "--check reports missing Codex AGENTS end marker"
printf '<!-- vibeguard-start -->\n' >> "${HOME}/.codex/AGENTS.md"
duplicate_start_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${duplicate_start_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md marker mismatch" "--check reports duplicate Codex AGENTS start marker"
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("| SEC-13 |", "| SEC-X |", 1), encoding="utf-8")
PY
missing_anchor_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${missing_anchor_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md missing required anchors" "--check reports missing Codex AGENTS required anchors"
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated, count = re.subn(r"\b[0-9]+ rules total\b", "999 rules total", text, count=1)
if count != 1:
    raise SystemExit(1)
path.write_text(updated, encoding="utf-8")
PY
stale_banner_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${stale_banner_agents_check_out}" "~/.codex/AGENTS.md declares 999 rules" "--check reports stale Codex AGENTS rule banner"
printf '# malicious injection appended by something\n' >> "${HOME}/.codex/AGENTS.md"
external_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${external_agents_check_out}" "[WARN] ~/.codex/AGENTS.md has 1 non-empty unmanaged line(s) outside VibeGuard block" "--check warns on unmanaged Codex AGENTS content"
assert_contains "${external_agents_check_out}" "Codex native hooks: PreToolUse(Bash/Edit/Write via apply_patch), PermissionRequest(Bash/Edit/Write via apply_patch), PostToolUse(Bash/Edit/Write via apply_patch), Stop(stop-guard/learn-evaluator)" "--check reports exact Codex native hook scope"

header "setup --check uses managed rule count banners"
_VALID_CLAUDE_MD="${TMP_HOME}/CLAUDE.md.valid.backup"
cp "${HOME}/.claude/CLAUDE.md" "${_VALID_CLAUDE_MD}"
python3 - <<'PY' "${HOME}/.claude/CLAUDE.md"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text("Personal note: 5 rules I keep locally.\n" + text, encoding="utf-8")
PY
external_rule_count_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CLAUDE_MD}" "${HOME}/.claude/CLAUDE.md"
assert_contains "${external_rule_count_check_out}" "[OK] Rule count in sync:" "--check ignores unmanaged Claude rule count text"
assert_not_contains "${external_rule_count_check_out}" "CLAUDE.md declares 5 rules" "--check does not read rule count outside the VibeGuard Claude block"

header "setup --check stays read-only"
python3 - <<'PY' "${HOME}/.claude/CLAUDE.md"
from pathlib import Path
import re
path = Path(__import__('sys').argv[1])
text = path.read_text(encoding='utf-8')
updated = re.sub(r'\b\d+ rules\b', '999 rules', text, count=1)
path.write_text(updated, encoding='utf-8')
PY
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated, count = re.subn(r"\b[0-9]+ rules total\b", "999 rules total", text, count=1)
if count != 1:
    raise SystemExit(1)
path.write_text(updated, encoding="utf-8")
PY
before_sha="$(shasum -a 256 "${HOME}/.claude/CLAUDE.md" | cut -d' ' -f1)"
agents_before_sha="$(shasum -a 256 "${HOME}/.codex/AGENTS.md" | cut -d' ' -f1)"
check_again_out="$(bash "${REPO_DIR}/setup.sh" --check)"
after_sha="$(shasum -a 256 "${HOME}/.claude/CLAUDE.md" | cut -d' ' -f1)"
agents_after_sha="$(shasum -a 256 "${HOME}/.codex/AGENTS.md" | cut -d' ' -f1)"
assert_contains "${check_again_out}" "CLAUDE.md declares 999 rules" "--check reports CLAUDE.md drift"
assert_contains "${check_again_out}" "~/.codex/AGENTS.md declares 999 rules" "--check reports Codex AGENTS.md drift"
assert_contains "${check_again_out}" "[OK] vibeguard-runtime runtime binary installed" "--check reports vibeguard-runtime installed"
assert_cmd "--check does not rewrite ~/.claude/CLAUDE.md" test "${before_sha}" = "${after_sha}"
assert_cmd "--check does not rewrite ~/.codex/AGENTS.md" test "${agents_before_sha}" = "${agents_after_sha}"
assert_cmd "--check does not drop or duplicate the chat contract block" python3 -c "from pathlib import Path; text = Path('${HOME}/.claude/CLAUDE.md').read_text(encoding='utf-8'); raise SystemExit(0 if text.count('${CHAT_CONTRACT_ANCHOR}') == 1 else 1)"
repair_out="$(bash "${REPO_DIR}/setup.sh" --yes)"
assert_contains "${repair_out}" "Setup complete! All components installed." "re-running setup after drift still succeeds"
assert_cmd "repair restores CLAUDE.md rule banner count" assert_claude_rule_banner_matches_installed_rules
assert_cmd "repair restores Codex AGENTS.md rule banner count" assert_codex_rule_banner_matches_installed_rules
assert_cmd "repeat setup keeps exactly one chat contract block" python3 -c "from pathlib import Path; text = Path('${HOME}/.claude/CLAUDE.md').read_text(encoding='utf-8'); raise SystemExit(0 if text.count('${CHAT_CONTRACT_ANCHOR}') == 1 else 1)"

header "upsert idempotency with non-standard wrapper path"
# Run upsert twice with a wrapper path that does not contain 'run-hook-codex.sh'.
# Without the _has_entry dedup fix, the second upsert would append duplicates.
_IDEMPOTENT_HOOKS="${TMP_HOME}/.codex/hooks-idempotent.json"
_IDEMPOTENT_WRAPPER="${TMP_HOME}/test/wrapper.sh"
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}" >/dev/null
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}" >/dev/null
assert_cmd "double-upsert with non-standard wrapper produces exactly 4 Stop entries (not 8)" python3 -c "
import json
data = json.load(open('${_IDEMPOTENT_HOOKS}'))
stop_entries = data.get('hooks', {}).get('Stop', [])
raise SystemExit(0 if len(stop_entries) == 2 else 1)
"
assert_cmd "double-upsert with non-standard wrapper: check-vibeguard passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}"

header "remove-vibeguard cleans custom-wrapper-path hooks"
# Issue fix: _is_vibeguard_command must recognise vibeguard-* scripts even when
# the wrapper path does not contain 'run-hook-codex.sh'.
python3 "${CODEX_HOOKS_HELPER}" remove-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}"
assert_cmd "remove-vibeguard removes custom-wrapper vibeguard hooks" bash -c "! grep -q 'vibeguard-pre-bash-guard.sh' '${_IDEMPOTENT_HOOKS}'"
assert_cmd "remove-vibeguard removes all managed hook scripts" bash -c "! grep -qE 'vibeguard-(pre-bash-guard|pre-edit-guard|pre-write-guard|post-edit-guard|post-write-guard|post-build-check|stop-guard|learn-evaluator)\\.sh' '${_IDEMPOTENT_HOOKS}'"

header "_has_entry validates type and timeout (Issue 2 guard)"
# A stale entry that has the correct command but is missing 'type: command' or
# has a spurious timeout must NOT satisfy check-vibeguard (silent false positive).
_STALE_HOOKS="${TMP_HOME}/.codex/hooks-stale.json"
_STALE_WRAPPER="${TMP_HOME}/test/stale-wrapper.sh"
# Write an entry with correct command but no 'type' field and no 'timeout'.
python3 -c "
import json, sys
data = {
  'hooks': {
    'PreToolUse': [{
      'matcher': 'Bash',
      'hooks': [{'command': 'bash ${_STALE_WRAPPER} vibeguard-pre-bash-guard.sh'}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects stale entry missing type field" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# After upsert the entry must be repaired and check must pass.
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}" >/dev/null
assert_cmd "upsert repairs stale entry; check-vibeguard then passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}"
# Write a Stop entry with correct command but a spurious timeout (Stop spec has none).
python3 -c "
import json
data = {
  'hooks': {
    'Stop': [{
      'hooks': [{'type': 'command', 'command': 'bash ${_STALE_WRAPPER} vibeguard-stop-guard.sh', 'timeout': 99}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects Stop entry with spurious timeout" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# Write a Stop entry with correct command+type but a spurious matcher (Stop spec has none).
python3 -c "
import json
data = {
  'hooks': {
    'Stop': [{
      'matcher': 'Bash',
      'hooks': [{'type': 'command', 'command': 'bash ${_STALE_WRAPPER} vibeguard-stop-guard.sh'}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects Stop entry with spurious matcher" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# After upsert the entry must be repaired and check must pass.
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}" >/dev/null
assert_cmd "upsert repairs Stop entry with spurious matcher; check-vibeguard then passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}"

