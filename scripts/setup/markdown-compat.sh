#!/usr/bin/env bash
# Managed Markdown compatibility for runtimes released before setup-md-managed-span.

setup_md_runtime_has_safe_blocks() {
  setup_runtime setup-md-managed-span /dev/null >/dev/null 2>&1
}

setup_md_legacy_managed_span() {
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      probe = line
      indent = 0
      while (indent < 3 && substr(probe, 1, 1) == " ") {
        probe = substr(probe, 2)
        indent++
      }
      marker = substr(probe, 1, 1)
      run = 0
      if (marker == "`" || marker == "~") {
        while (substr(probe, run + 1, 1) == marker) run++
      }
      tail = substr(probe, run + 1)
      if (fence_marker != "") {
        if (marker == fence_marker && run >= fence_length && tail ~ /^[[:space:]]*$/) {
          fence_marker = ""
          fence_length = 0
        }
        next
      }
      if (indent <= 3 && run >= 3 && (marker != "`" || index(tail, "`") == 0)) {
        fence_marker = marker
        fence_length = run
        next
      }
      if (line == "<!-- vibeguard-start -->") {
        in_block = 1
        candidate_start = NR
        has_heading = 0
        next
      }
      if (line == "<!-- vibeguard-end -->") {
        if (in_block && has_heading) {
          count++
          if (count == 1) {
            first_start = candidate_start
            first_end = NR
          }
        }
        in_block = 0
        has_heading = 0
        next
      }
      if (in_block && (line == "# VibeGuard shared core" || line == "#VibeGuard — AI anti-hallucination rules")) {
        has_heading = 1
      }
    }
    END { print count + 0, first_start + 0, first_end + 0 }
  ' "$1"
}

setup_md_legacy_prepare_target() {
  local target_file="$1" compat_file="$2" start_token="$3" end_token="$4"
  local managed_span start_line end_line carriage_return=$'\r'
  if [[ ! -f "${target_file}" ]]; then
    touch "${compat_file}"
    return 0
  fi

  managed_span=$(setup_md_legacy_managed_span "${target_file}") || return 1
  managed_span="${managed_span#* }"
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
