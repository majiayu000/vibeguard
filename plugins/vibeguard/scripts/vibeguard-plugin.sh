#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

print_usage() {
  cat <<'USAGE'
Usage: bash scripts/vibeguard-plugin.sh <command> [setup-options]

Commands:
  repo-dir         Print the resolved VibeGuard checkout path
  install          Run setup.sh with the provided install options
  check            Run setup.sh --check with the provided check options
  clean            Run setup.sh --clean with the provided clean options
  codex-status     Run setup.sh --codex-status with the provided status options
  help             Show this help

Set VIBEGUARD_REPO_DIR=/path/to/vibeguard when the plugin is installed from a
cache that is not nested under a VibeGuard repository checkout.
USAGE
}

canonical_dir() {
  local candidate="$1"
  if [[ -d "${candidate}" ]]; then
    (cd "${candidate}" && pwd)
  else
    return 1
  fi
}

is_vibeguard_repo() {
  local candidate="$1"
  [[ -f "${candidate}/setup.sh" ]] \
    && [[ -d "${candidate}/hooks" ]] \
    && [[ -d "${candidate}/skills" ]] \
    && [[ -f "${candidate}/vibeguard-runtime/Cargo.toml" ]]
}

resolve_repo_dir() {
  local candidate resolved git_root
  local -a candidates=()

  if [[ -n "${VIBEGUARD_REPO_DIR:-}" ]]; then
    candidates+=("${VIBEGUARD_REPO_DIR}")
  fi

  candidates+=("${PLUGIN_DIR}/../..")

  if git_root="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null)"; then
    candidates+=("${git_root}")
  fi

  candidates+=("${HOME}/vibeguard")

  for candidate in "${candidates[@]}"; do
    if resolved="$(canonical_dir "${candidate}")" && is_vibeguard_repo "${resolved}"; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  done

  printf 'ERROR: could not locate a VibeGuard repository checkout.\n' >&2
  printf 'Set VIBEGUARD_REPO_DIR=/path/to/vibeguard and retry.\n' >&2
  return 1
}

run_setup() {
  local mode="$1"
  shift || true

  local repo_dir
  repo_dir="$(resolve_repo_dir)"

  case "${mode}" in
    install)
      exec bash "${repo_dir}/setup.sh" "$@"
      ;;
    check)
      exec bash "${repo_dir}/setup.sh" --check "$@"
      ;;
    clean)
      exec bash "${repo_dir}/setup.sh" --clean "$@"
      ;;
    codex-status)
      exec bash "${repo_dir}/setup.sh" --codex-status "$@"
      ;;
    *)
      printf 'ERROR: unsupported setup mode: %s\n' "${mode}" >&2
      return 2
      ;;
  esac
}

case "${1:-help}" in
  help|--help|-h)
    print_usage
    ;;
  repo-dir)
    resolve_repo_dir
    ;;
  install|check|clean|codex-status)
    command="$1"
    shift || true
    run_setup "${command}" "$@"
    ;;
  *)
    printf 'ERROR: unknown command: %s\n' "$1" >&2
    print_usage >&2
    exit 2
    ;;
esac
