#!/usr/bin/env bash
# User runtime configuration health adapter for setup checks.

check_user_runtime_config() {
  local config_file runtime output decision
  config_file="${VIBEGUARD_CONFIG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/config.json}"

  echo
  echo "User Runtime Config"
  echo "------------------------------"

  if ! runtime="$(setup_runtime_path 2>/dev/null)"; then
    if [[ -e "${config_file}" || -L "${config_file}" ]]; then
      red "[FAIL] User runtime config cannot be validated (${config_file}; run: bash setup.sh --yes)"
    else
      yellow "[INFO] No user runtime config found; runtime defaults apply (${config_file})"
    fi
    return 0
  fi

  if output="$("${runtime}" runtime-config-validate "${config_file}" 2>&1)"; then
    decision="${output%%$'\n'*}"
    case "${decision}" in
      MISSING)
        yellow "[INFO] No user runtime config found; runtime defaults apply (${config_file})"
        ;;
      VALID)
        green "[OK] User runtime config valid (${config_file})"
        ;;
      *)
        red "[FAIL] User runtime config validator returned an invalid decision (${config_file})"
        ;;
    esac
  else
    red "[FAIL] User runtime config invalid (${config_file}): ${output%%$'\n'*}"
  fi
}
