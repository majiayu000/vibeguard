#!/usr/bin/env bash
active_state="${HOME}/.systemctl-vibeguard-gc-active"
service_active_state="${HOME}/.systemctl-vibeguard-gc-service-active"
enabled_state="${HOME}/.systemctl-vibeguard-gc-enabled"
[[ "${1:-}" == "--user" ]] && shift
case "${1:-}" in
  daemon-reload) exit 0 ;;
  enable)
    [[ "${2:-}" == "--now" && "${3:-}" == "vibeguard-gc.timer" ]] || exit 0
    [[ "${VIBEGUARD_TEST_SYSTEMD_ENABLE_FAIL:-0}" == "1" ]] && exit 1
    touch "$active_state" "$enabled_state"
    ;;
  start)
    [[ "${2:-}" == "vibeguard-gc.timer" ]] && touch "$active_state"
    ;;
  stop)
    case "${2:-}" in
      vibeguard-gc.timer)
        [[ "${VIBEGUARD_TEST_SYSTEMD_STOP_FAIL:-0}" == "1" ]] && exit 1
        [[ "${VIBEGUARD_TEST_SYSTEMD_STILL_ACTIVE:-0}" == "1" ]] || rm -f "$active_state"
        ;;
      vibeguard-gc.service)
        [[ "${VIBEGUARD_TEST_SYSTEMD_SERVICE_STOP_FAIL:-0}" == "1" ]] && exit 1
        [[ "${VIBEGUARD_TEST_SYSTEMD_SERVICE_STILL_ACTIVE:-0}" == "1" ]] \
          || rm -f "$service_active_state"
        ;;
    esac
    ;;
  disable)
    [[ "${VIBEGUARD_TEST_SYSTEMD_DISABLE_FAIL:-0}" == "1" ]] && exit 1
    [[ "${VIBEGUARD_TEST_SYSTEMD_STILL_ENABLED:-0}" == "1" ]] || rm -f "$enabled_state"
    ;;
  is-active)
    if [[ "${2:-}" == "vibeguard-gc.timer" && -f "$active_state" ]]; then
      printf 'active\n'; exit 0
    fi
    if [[ "${2:-}" == "vibeguard-gc.service" && -f "$service_active_state" ]]; then
      printf 'active\n'; exit 0
    fi
    printf 'inactive\n'; exit 3
    ;;
  is-enabled)
    if [[ "${2:-}" == "vibeguard-gc.timer" && -f "$enabled_state" ]]; then
      printf 'enabled\n'; exit 0
    fi
    printf 'disabled\n'; exit 1
    ;;
  status)
    [[ "${2:-}" == "vibeguard-gc.timer" && -f "$active_state" ]] && exit 0
    exit 3
    ;;
  list-timers)
    if [[ -f "$active_state" ]]; then
      printf 'NEXT LEFT LAST PASSED UNIT ACTIVATES\n'
      printf 'Sun 03:00 - - - vibeguard-gc.timer vibeguard-gc.service\n'
    fi
    ;;
  *) exit 0 ;;
esac
