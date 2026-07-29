# Install-flow regression suite split by concern; sourced by tests/test_setup.sh.
# shellcheck source=setup/install_core_flow_tests.sh
source "${REPO_DIR}/tests/setup/install_core_flow_tests.sh"
# shellcheck source=setup/install_scheduler_health_tests.sh
source "${REPO_DIR}/tests/setup/install_scheduler_health_tests.sh"
