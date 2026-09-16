#!/usr/bin/env bash
# Structured setup health-report suite split by concern.
python3 "$(cd "$(dirname "$0")/.." && pwd)/tests/test_cron_health.py" || exit 1
# shellcheck source=setup/check_status_tests.sh
source "$(cd "$(dirname "$0")/.." && pwd)/tests/setup/check_status_tests.sh"
# shellcheck source=setup/check_hook_tests.sh
source "${REPO_DIR}/tests/setup/check_hook_tests.sh"
# shellcheck source=setup/check_scheduler_contract_tests.sh
source "${REPO_DIR}/tests/setup/check_scheduler_contract_tests.sh"
