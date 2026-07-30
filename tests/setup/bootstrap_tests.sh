# Bootstrap regression suite split by concern; sourced by tests/test_setup.sh.
# shellcheck source=setup/bootstrap_payload_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_payload_tests.sh"
# shellcheck source=setup/bootstrap_transaction_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_transaction_tests.sh"
# shellcheck source=setup/bootstrap_recovery_scheduler_tests.sh
source "${REPO_DIR}/tests/setup/bootstrap_recovery_scheduler_tests.sh"
