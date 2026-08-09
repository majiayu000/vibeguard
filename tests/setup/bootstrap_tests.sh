# Bootstrap regression suite split by concern; sourced by tests/test_setup.sh.
# shellcheck source=setup/bootstrap_payload_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_payload_tests.sh"
# shellcheck source=setup/bootstrap_identity_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_identity_tests.sh"
# shellcheck source=setup/bootstrap_lease_schema_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_lease_schema_tests.sh"
# shellcheck source=setup/bootstrap_lease_retirement_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_lease_retirement_tests.sh"
# shellcheck source=setup/bootstrap_transaction_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_transaction_tests.sh"
# shellcheck source=setup/bootstrap_termination_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_termination_tests.sh"
# shellcheck source=setup/bootstrap_stopped_recovery_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_stopped_recovery_tests.sh"
# shellcheck source=setup/bootstrap_recovery_scheduler_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_recovery_scheduler_tests.sh"
