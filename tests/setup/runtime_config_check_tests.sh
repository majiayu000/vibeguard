#!/usr/bin/env bash
# Focused setup mode matrix for an invalid user runtime configuration.

header "runtime config setup mode matrix"

RUNTIME_CONFIG_TEST_FILE="${BROKEN_HOME}/runtime-config.json"
RUNTIME_CONFIG_TEST_RUNTIME="${VIBEGUARD_SETUP_RUNTIME}"
printf '%s\n' '{"write_mode":"sensitive-setup-value"}' > "${RUNTIME_CONFIG_TEST_FILE}"

run_invalid_runtime_case() {
  local label="$1" expected_rc="$2"
  shift 2
  local output rc
  output="$(
    HOME="${BROKEN_HOME}" \
      VIBEGUARD_SETUP_RUNTIME="${RUNTIME_CONFIG_TEST_RUNTIME}" \
      VIBEGUARD_CONFIG_FILE="${RUNTIME_CONFIG_TEST_FILE}" \
      bash "${SETUP_SCRIPT}" "$@" 2>&1
  )"
  rc=$?
  assert_eq "${rc}" "${expected_rc}" "${label}: exit ${expected_rc}"
  assert_contains "${output}" "category=config_enum_error" "${label}: preserves INVALID decision"
  assert_not_contains "${output}" "sensitive-setup-value" "${label}: redacts config value"
}

while IFS='|' read -r label expected args; do
  [[ -n "${label}" ]] || continue
  read -r -a argv <<< "${args}"
  run_invalid_runtime_case "${label}" "${expected}" "${argv[@]}"
done <<'CASES'
doctor|0|doctor
check|0|--check
doctor quiet|0|doctor --quiet
check quiet|0|--check --quiet
doctor project|0|doctor --project
check project|0|--check --project
doctor no-summary|0|doctor --no-summary
check no-summary|0|--check --no-summary
doctor strict|2|doctor --strict
doctor quiet strict|2|doctor --quiet --strict
doctor json|2|doctor --json
doctor install|2|doctor --install
doctor strict no-summary|0|doctor --strict --no-summary
doctor install no-summary|0|doctor --install --no-summary
check strict|2|--check --strict
check quiet strict|2|--check --quiet --strict
check json|2|--check --json
check install|2|--check --install
verify-project|2|verify-project
verify-project json|2|verify-project --json
verify-dev-repo|2|verify-dev-repo
verify-dev-repo json|2|verify-dev-repo --json
verify-install|2|verify-install
CASES

run_runtime_config_conflict() {
  local label="$1"
  shift
  local output rc
  output="$(HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" "$@" 2>&1)"
  rc=$?
  assert_eq "${rc}" "64" "${label}: usage exit 64"
  assert_contains "${output}" "ERROR:" "${label}: explains conflict"
}

run_runtime_config_conflict "doctor json quiet" doctor --json --quiet
run_runtime_config_conflict "doctor json install" doctor --json --install
run_runtime_config_conflict "doctor json no-summary" doctor --json --no-summary
run_runtime_config_conflict "check strict no-summary" --check --strict --no-summary
run_runtime_config_conflict "check json no-summary" --check --json --no-summary
run_runtime_config_conflict "check install no-summary" --check --install --no-summary
