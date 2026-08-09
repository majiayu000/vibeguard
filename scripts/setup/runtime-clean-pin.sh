#!/usr/bin/env bash
# Keep a physical runtime copy alive while clean removes the installed snapshot.
# shellcheck shell=bash

setup_runtime_bootstrap_cleanup() {
  if [[ -n "${VIBEGUARD_SETUP_RUNTIME_BOOTSTRAP_TMP:-}" ]]; then
    rm -rf "${VIBEGUARD_SETUP_RUNTIME_BOOTSTRAP_TMP}" 2>/dev/null || true
  fi
}

setup_runtime_physical_path() {
  local path="$1" target directory hops=0
  case "${path}" in
    /*) ;;
    *) path="${PWD}/${path}" ;;
  esac
  while [[ -L "${path}" ]]; do
    hops=$((hops + 1))
    [[ "${hops}" -le 40 ]] || return 1
    target="$(readlink "${path}")" || return 1
    case "${target}" in
      /*) path="${target}" ;;
      *) path="$(dirname "${path}")/${target}" ;;
    esac
  done
  directory="$(cd -P "$(dirname "${path}")" && pwd)" || return 1
  printf '%s/%s\n' "${directory}" "$(basename "${path}")"
}

pin_setup_runtime_for_clean() {
  local runtime managed_root physical_runtime tmp dest
  runtime="$(setup_runtime_path)" || return 1
  managed_root="${HOME}/.vibeguard/installed"
  [[ -d "${managed_root}" ]] || return 0
  managed_root="$(cd -P "${managed_root}" && pwd)" || return 1
  physical_runtime="$(setup_runtime_physical_path "${runtime}")" || return 1
  case "${physical_runtime}" in
    "${managed_root}/"*) ;;
    *) return 0 ;;
  esac

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-runtime-clean_XXXXXX")"
  dest="${tmp}/vibeguard-runtime"
  if ! cp "${runtime}" "${dest}" || ! chmod +x "${dest}"; then
    rm -rf "${tmp}"
    return 1
  fi
  export VIBEGUARD_SETUP_RUNTIME="${dest}"
  export VIBEGUARD_SETUP_RUNTIME_BOOTSTRAP_TMP="${tmp}"
  trap setup_runtime_bootstrap_cleanup EXIT
  setup_runtime_path >/dev/null 2>&1
}
