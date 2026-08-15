#!/usr/bin/env bash
# Managed Markdown compatibility for runtimes released before setup-md-managed-span.

setup_md_runtime_has_safe_blocks() {
  setup_runtime setup-md-managed-span /dev/null >/dev/null 2>&1
}

setup_md_legacy_prepare_target() {
  local target_file="$1" compat_file="$2" start_token="$3" end_token="$4"
  local managed_span start_line end_line carriage_return=$'\r'
  if [[ ! -f "${target_file}" ]]; then
    touch "${compat_file}"
    return 0
  fi

  managed_span=$(awk '
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line == "<!-- vibeguard-start -->" {
      in_block = 1
      candidate_start = NR
      has_heading = 0
      next
    }
    line == "<!-- vibeguard-end -->" {
      if (in_block && has_heading) {
        print candidate_start, NR
        exit
      }
      in_block = 0
      has_heading = 0
      next
    }
    in_block && line == "# VibeGuard shared core" { has_heading = 1 }
  ' "${target_file}") || return 1
  read -r start_line end_line <<< "${managed_span}"

  local -a transforms=(
    -e "s/${carriage_return}$//"
    -e "s|<!-- vibeguard-start -->|${start_token}|g"
    -e "s|<!-- vibeguard-end -->|${end_token}|g"
  )
  if [[ -n "${start_line:-}" && -n "${end_line:-}" ]]; then
    transforms+=(
      -e "${start_line}s|^${start_token}$|<!-- vibeguard-start -->|"
      -e "${end_line}s|^${end_token}$|<!-- vibeguard-end -->|"
    )
  fi
  sed "${transforms[@]}" "${target_file}" > "${compat_file}"
}

setup_md_legacy_call() {
  local command="$1" target_file="$2"
  shift 2
  local target_parent compat_dir compat_file restored_file start_token end_token output rc=0
  target_parent="$(dirname "${target_file}")"
  compat_dir=$(mktemp -d "${target_parent}/.vibeguard-md-compat.XXXXXX") || return 1
  compat_file="${compat_dir}/target.md"
  restored_file="${compat_dir}/restored.md"
  start_token="VIBEGUARD_PROSE_START_$$_${RANDOM}"
  end_token="VIBEGUARD_PROSE_END_$$_${RANDOM}"
  while [[ -f "${target_file}" ]] \
    && { grep -qF "${start_token}" "${target_file}" || grep -qF "${end_token}" "${target_file}"; }; do
    start_token="${start_token}_x"
    end_token="${end_token}_x"
  done

  if ! setup_md_legacy_prepare_target \
    "${target_file}" "${compat_file}" "${start_token}" "${end_token}"; then
    rm -rf "${compat_dir}"
    return 1
  fi
  output=$(setup_runtime "${command}" "${compat_file}" "$@" 2>&1) || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    rm -rf "${compat_dir}"
    printf '%s\n' "${output}" >&2
    return "${rc}"
  fi

  output="${output//${compat_file}/${target_file}}"
  output="${output//${start_token}/<!-- vibeguard-start -->}"
  output="${output//${end_token}/<!-- vibeguard-end -->}"
  case "${command}:${output##*$'\n'}" in
    setup-md-inject:APPENDED|setup-md-inject:UPDATED|setup-md-remove:REMOVED)
      sed \
        -e "s|${start_token}|<!-- vibeguard-start -->|g" \
        -e "s|${end_token}|<!-- vibeguard-end -->|g" \
        "${compat_file}" > "${restored_file}"
      mv "${restored_file}" "${target_file}"
      ;;
  esac
  rm -rf "${compat_dir}"
  printf '%s\n' "${output}"
}

setup_md_diff_inject() {
  if setup_md_runtime_has_safe_blocks; then
    setup_runtime setup-md-diff-inject "$@"
  else
    setup_md_legacy_call setup-md-diff-inject "$@"
  fi
}

setup_md_inject() {
  if setup_md_runtime_has_safe_blocks; then
    setup_runtime setup-md-inject "$@"
  else
    setup_md_legacy_call setup-md-inject "$@"
  fi
}

setup_md_remove() {
  if setup_md_runtime_has_safe_blocks; then
    setup_runtime setup-md-remove "$@"
  else
    setup_md_legacy_call setup-md-remove "$@"
  fi
}
