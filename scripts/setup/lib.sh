#!/usr/bin/env bash
# VibeGuard Setup — shared variables and functions
# Sourced by install.sh, check.sh, clean.sh

REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CLAUDE_DIR="${HOME}/.claude"
CODEX_DIR="${HOME}/.codex"
SETTINGS_HELPER="${REPO_DIR}/scripts/lib/settings_json.py"
CODEX_HOOKS_HELPER="${REPO_DIR}/scripts/lib/codex_hooks_json.py"
CODEX_CONFIG_HELPER="${REPO_DIR}/scripts/lib/codex_config_toml.py"
MANIFEST_HELPER="${REPO_DIR}/scripts/lib/vibeguard_manifest.py"
CLAUDE_MD_HELPER="${REPO_DIR}/scripts/lib/claude_md.py"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
VIBEGUARD_SETUP_DRY_RUN="${VIBEGUARD_SETUP_DRY_RUN:-0}"
VIBEGUARD_SETUP_AUTO="${VIBEGUARD_SETUP_AUTO:-0}"
VIBEGUARD_SETUP_FORCE_OVERWRITE="${VIBEGUARD_SETUP_FORCE_OVERWRITE:-0}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

setup_runtime_path() {
  local candidate
  for candidate in \
    "${VIBEGUARD_SETUP_RUNTIME:-}" \
    "${_INSTALL_TMP:-}/bin/vibeguard-runtime" \
    "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" \
    "${REPO_DIR}/vibeguard-runtime/target/release/vibeguard-runtime" \
    "${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime" \
    "vibeguard-runtime"; do
    [[ -n "${candidate}" ]] || continue
    if [[ "${VIBEGUARD_SETUP_SKIP_REPO_RUNTIME:-0}" == "1" && "${candidate}" == "${REPO_DIR}/vibeguard-runtime/target/"* ]]; then
      continue
    fi
    if [[ "${candidate}" == */* ]]; then
      if [[ -x "${candidate}" ]] && setup_runtime_supports "${candidate}"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    elif command -v "${candidate}" >/dev/null 2>&1; then
      candidate="$(command -v "${candidate}")"
      if setup_runtime_supports "${candidate}"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done
  return 1
}

setup_runtime_expected_version() {
  local version version_file
  version="${VIBEGUARD_SETUP_RUNTIME_VERSION:-}"
  if [[ -z "${version}" ]]; then
    version_file="${REPO_DIR}/vibeguard-runtime/VERSION"
    [[ -f "${version_file}" ]] || return 1
    version="$(tr -d '[:space:]' < "${version_file}")"
  fi
  [[ -n "${version}" ]] || return 1
  case "${version}" in
    v*) printf '%s\n' "${version#v}" ;;
    *) printf '%s\n' "${version}" ;;
  esac
}

setup_runtime_version_matches() {
  local runtime="$1" expected actual
  expected="$(setup_runtime_expected_version)" || return 1
  actual="$("${runtime}" version 2>/dev/null)" || return 1
  actual="${actual%%$'\n'*}"
  actual="${actual//$'\r'/}"
  [[ "${actual}" == "${expected}" ]]
}

setup_runtime_supports() {
  local runtime="$1" probe_state="${TMPDIR:-/tmp}/vibeguard-runtime-probe.$$.json"
  "${runtime}" setup-state-list-symlinks-under "${probe_state}" "${TMPDIR:-/tmp}" >/dev/null 2>&1 || return 1
  setup_runtime_version_matches "${runtime}" || return 1

  local command probe_out
  for command in \
    version \
    setup-manifest-skill-links \
    setup-md-remove \
    setup-settings-check \
    setup-settings-check-stale \
    setup-codex-config-check-hooks \
    setup-codex-hooks-upsert \
    setup-codex-hooks-check \
    setup-codex-hooks-check-stale \
    setup-codex-hooks-check-timeouts; do
    probe_out="$("${runtime}" "${command}" 2>&1 || true)"
    if printf '%s\n' "${probe_out}" | grep -q "Unknown command"; then
      return 1
    fi
  done
  return 0
}

setup_runtime() {
  local runtime
  runtime="$(setup_runtime_path)" || {
    red "  ERROR: vibeguard-runtime not found; run setup with --build-from-source or install a release binary." >&2
    return 127
  }
  "${runtime}" "$@"
}

setup_runtime_release_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}:${arch}" in
    Darwin:arm64|Darwin:aarch64)
      printf 'aarch64-apple-darwin' ;;
    Darwin:x86_64|Darwin:amd64)
      printf 'x86_64-apple-darwin' ;;
    Linux:x86_64|Linux:amd64)
      printf 'x86_64-unknown-linux-musl' ;;
    Linux:aarch64|Linux:arm64)
      printf 'aarch64-unknown-linux-musl' ;;
    *)
      return 1 ;;
  esac
}

setup_runtime_release_tag() {
  local version version_file
  version="${VIBEGUARD_SETUP_RUNTIME_VERSION:-}"
  if [[ -z "${version}" ]]; then
    version_file="${REPO_DIR}/vibeguard-runtime/VERSION"
    [[ -f "${version_file}" ]] || return 1
    version="$(tr -d '[:space:]' < "${version_file}")"
  fi
  [[ -n "${version}" ]] || return 1
  case "${version}" in
    v*) printf '%s' "${version}" ;;
    *) printf 'v%s' "${version}" ;;
  esac
}

setup_runtime_sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    return 1
  fi
}

setup_runtime_verify_release_provenance() {
  local asset_path="$1" release_repo="$2" tag="$3"
  SETUP_RUNTIME_PROVENANCE_STATUS="checksum-only"
  SETUP_RUNTIME_PROVENANCE_REASON=""

  if ! command -v gh >/dev/null 2>&1; then
    SETUP_RUNTIME_PROVENANCE_REASON="gh not found"
    return 2
  fi
  if ! gh auth status >/dev/null 2>&1; then
    SETUP_RUNTIME_PROVENANCE_REASON="gh auth unavailable"
    return 2
  fi

  if gh attestation verify "${asset_path}" \
    --repo "${release_repo}" \
    --signer-workflow "github.com/${release_repo}/.github/workflows/release.yml" \
    --source-ref "refs/tags/${tag}" \
    --deny-self-hosted-runners >/dev/null 2>&1; then
    SETUP_RUNTIME_PROVENANCE_STATUS="verified-provenance"
    return 0
  fi

  SETUP_RUNTIME_PROVENANCE_REASON="gh attestation verify failed"
  return 1
}

setup_download_prebuilt_runtime_quiet() {
  local target="$1" tag="$2" dest="$3"
  local asset="vibeguard-runtime-${target}"
  local release_repo="${VIBEGUARD_RUNTIME_RELEASE_REPO:-majiayu000/vibeguard}"
  local download_dir downloaded expected actual provenance_rc

  download_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-runtime-download_XXXXXX")"
  downloaded=0

  if command -v gh >/dev/null 2>&1; then
    if gh release download "${tag}" \
      --repo "${release_repo}" \
      --pattern "${asset}" \
      --pattern "SHA256SUMS" \
      --dir "${download_dir}" >/dev/null 2>&1; then
      downloaded=1
    fi
  fi

  if [[ "${downloaded}" != "1" ]] && command -v curl >/dev/null 2>&1; then
    local base_url="https://github.com/${release_repo}/releases/download/${tag}"
    if curl -fsSL -o "${download_dir}/${asset}" "${base_url}/${asset}" >/dev/null 2>&1 \
      && curl -fsSL -o "${download_dir}/SHA256SUMS" "${base_url}/SHA256SUMS" >/dev/null 2>&1; then
      downloaded=1
    fi
  fi

  if [[ "${downloaded}" != "1" || ! -f "${download_dir}/${asset}" || ! -f "${download_dir}/SHA256SUMS" ]]; then
    rm -rf "${download_dir}"
    return 1
  fi

  expected="$(awk -v file="${asset}" '($2 == file || $2 == "*" file) { print $1; exit }' "${download_dir}/SHA256SUMS")"
  if [[ -z "${expected}" ]]; then
    rm -rf "${download_dir}"
    return 1
  fi
  if ! actual="$(setup_runtime_sha256_file "${download_dir}/${asset}")" || [[ "${actual}" != "${expected}" ]]; then
    rm -rf "${download_dir}"
    return 1
  fi
  provenance_rc=0
  setup_runtime_verify_release_provenance "${download_dir}/${asset}" "${release_repo}" "${tag}" || provenance_rc=$?
  if [[ "${provenance_rc}" -eq 1 ]]; then
    rm -rf "${download_dir}"
    return 1
  fi

  mkdir -p "$(dirname "${dest}")"
  cp "${download_dir}/${asset}" "${dest}"
  chmod +x "${dest}"
  rm -rf "${download_dir}"
}

setup_runtime_bootstrap_cleanup() {
  if [[ -n "${VIBEGUARD_SETUP_RUNTIME_BOOTSTRAP_TMP:-}" ]]; then
    rm -rf "${VIBEGUARD_SETUP_RUNTIME_BOOTSTRAP_TMP}" 2>/dev/null || true
  fi
}

ensure_setup_runtime_available() {
  local target tag tmp dest
  if setup_runtime_path >/dev/null 2>&1; then
    return 0
  fi
  target="$(setup_runtime_release_target)" || return 1
  tag="$(setup_runtime_release_tag)" || return 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-runtime-bootstrap_XXXXXX")"
  dest="${tmp}/vibeguard-runtime"
  if ! setup_download_prebuilt_runtime_quiet "${target}" "${tag}" "${dest}"; then
    rm -rf "${tmp}"
    return 1
  fi
  export VIBEGUARD_SETUP_RUNTIME="${dest}"
  export VIBEGUARD_SETUP_RUNTIME_BOOTSTRAP_TMP="${tmp}"
  trap setup_runtime_bootstrap_cleanup EXIT
  setup_runtime_path >/dev/null 2>&1
}

settings_check() {
  local settings_file="$1" target="$2"
  [[ -f "${settings_file}" ]] || return 1
  if [[ "${target}" == profile-hooks:* ]] && command -v python3 >/dev/null 2>&1; then
    python3 "${SETTINGS_HELPER}" check --settings-file "${settings_file}" --target "${target}" >/dev/null 2>&1
    local python_status=$?
    case "${python_status}" in
      126|127) ;;
      *) return "${python_status}" ;;
    esac
  fi
  if [[ "${target}" == profile-hooks:* ]]; then
    local runtime probe_out
    runtime="$(setup_runtime_path)" || return 2
    probe_out="$("${runtime}" setup-settings-check-supports-profile-hooks 2>&1 || true)"
    if printf '%s\n' "${probe_out}" | grep -q "Unknown command"; then
      return 2
    fi
    "${runtime}" setup-settings-check "${REPO_DIR}" "${settings_file}" "${target}" >/dev/null 2>&1
    return $?
  fi
  setup_runtime setup-settings-check "${REPO_DIR}" "${settings_file}" "${target}" >/dev/null 2>&1
  local status=$?
  if [[ "${status}" -eq 127 ]]; then
    return 2
  fi
  return "${status}"
}

settings_stale_hooks_report() {
  local settings_file="$1"
  [[ -f "${settings_file}" ]] || return 0
  setup_runtime setup-settings-check-stale "${settings_file}"
}

settings_upsert() {
  local settings_file="$1" profile="$2"
  local args=(setup-settings-upsert "${REPO_DIR}" "${settings_file}" "${profile}")
  if [[ "${VIBEGUARD_SETUP_FORCE_OVERWRITE}" == "1" ]]; then
    args+=(--force-overwrite)
  fi
  setup_runtime "${args[@]}"
}

settings_upsert_diff() {
  local settings_file="$1" profile="$2"
  local args=(setup-settings-upsert "${REPO_DIR}" "${settings_file}" "${profile}" --dry-run)
  if [[ "${VIBEGUARD_SETUP_FORCE_OVERWRITE}" == "1" ]]; then
    args+=(--force-overwrite)
  fi
  setup_runtime "${args[@]}"
}

settings_remove() {
  local settings_file="$1"
  setup_runtime setup-settings-remove "${REPO_DIR}" "${settings_file}"
}

manifest_skill_links() {
  local target="$1"
  if [[ "${MANIFEST_HELPER}" != "${REPO_DIR}/scripts/lib/vibeguard_manifest.py" ]]; then
    python3 "${MANIFEST_HELPER}" skill-links --target "${target}"
    return
  fi
  setup_runtime setup-manifest-skill-links "${REPO_DIR}" "${target}"
}

manifest_rule_links() {
  local languages="${1:-}"
  if [[ "${MANIFEST_HELPER}" != "${REPO_DIR}/scripts/lib/vibeguard_manifest.py" ]]; then
    if [[ -n "${languages}" ]]; then
      python3 "${MANIFEST_HELPER}" rule-links --languages "${languages}"
    else
      python3 "${MANIFEST_HELPER}" rule-links
    fi
    return
  fi
  if [[ -n "${languages}" ]]; then
    setup_runtime setup-manifest-rule-links "${REPO_DIR}" "${languages}"
  else
    setup_runtime setup-manifest-rule-links "${REPO_DIR}"
  fi
}

manifest_rule_labels() {
  local languages="${1:-}"
  if [[ "${MANIFEST_HELPER}" != "${REPO_DIR}/scripts/lib/vibeguard_manifest.py" ]]; then
    if [[ -n "${languages}" ]]; then
      python3 "${MANIFEST_HELPER}" rule-labels --languages "${languages}"
    else
      python3 "${MANIFEST_HELPER}" rule-labels
    fi
    return
  fi
  if [[ -n "${languages}" ]]; then
    setup_runtime setup-manifest-rule-labels "${REPO_DIR}" "${languages}"
  else
    setup_runtime setup-manifest-rule-labels "${REPO_DIR}"
  fi
}

manifest_rule_links_checked() {
  local languages="${1:-}"
  local output
  if ! output="$(manifest_rule_links "${languages}" 2>&1)"; then
    red "  ERROR: failed to enumerate manifest rules" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && red "  ${line}" >&2
    done <<< "${output}"
    return 1
  fi
  if [[ -z "${output//[[:space:]]/}" ]]; then
    red "  ERROR: no manifest rules declared" >&2
    return 1
  fi
  printf '%s\n' "${output}"
}

manifest_rule_labels_checked() {
  local languages="${1:-}"
  local output
  if ! output="$(manifest_rule_labels "${languages}" 2>&1)"; then
    red "  ERROR: failed to enumerate manifest rule labels" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && red "  ${line}" >&2
    done <<< "${output}"
    return 1
  fi
  if [[ -z "${output//[[:space:]]/}" ]]; then
    red "  ERROR: no manifest rule labels declared" >&2
    return 1
  fi
  printf '%s\n' "${output}"
}

manifest_skill_links_checked() {
  local target="$1"
  local output
  if ! output="$(manifest_skill_links "${target}" 2>&1)"; then
    red "  ERROR: failed to enumerate manifest skills for ${target}" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && red "  ${line}" >&2
    done <<< "${output}"
    return 1
  fi
  if [[ -z "${output//[[:space:]]/}" ]]; then
    red "  ERROR: no manifest skills declared for ${target}" >&2
    return 1
  fi
  printf '%s\n' "${output}"
}

manifest_skill_links_for_cleanup() {
  local target="$1"
  local output
  if ! output="$(manifest_skill_links "${target}" 2>&1)"; then
    yellow "  WARN: failed to enumerate manifest skills for ${target}; skipping skill link cleanup" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && yellow "  ${line}" >&2
    done <<< "${output}"
    return 0
  fi
  if [[ -z "${output//[[:space:]]/}" ]]; then
    yellow "  WARN: no manifest skills declared for ${target}; skipping skill link cleanup" >&2
    return 0
  fi
  printf '%s\n' "${output}"
}

cleanup_retired_manifest_skill_links() {
  local target="$1"
  local dest_dir="$2"
  local active_links

  if ! declare -F state_list_tracked_symlinks_under >/dev/null; then
    return 0
  fi

  active_links="$(manifest_skill_links_for_cleanup "${target}")"
  [[ -n "${active_links//[[:space:]]/}" ]] || return 0

  local active_names=$'\n'
  local source_path skill
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    active_names+="${skill}"$'\n'
  done <<< "${active_links}"

  local tracked_path name display
  while IFS= read -r tracked_path; do
    [[ -n "${tracked_path}" ]] || continue
    name="$(basename "${tracked_path}")"
    [[ "${active_names}" == *$'\n'"${name}"$'\n'* ]] && continue
    display="${tracked_path/#${HOME}/~}"
    if [[ -L "${tracked_path}" ]]; then
      rm -f "${tracked_path}"
      yellow "  Removed retired VibeGuard skill link: ${display}"
    elif [[ -e "${tracked_path}" ]]; then
      yellow "  SKIP retired VibeGuard skill path is not a symlink: ${display}"
    fi
  done < <(state_list_tracked_symlinks_under "${dest_dir}")
}

install_manifest_skills() {
  local target_uri="$1" dest_dir="$2" install_fn="$3"
  local skill_links source_path skill

  mkdir -p "${dest_dir}"
  skill_links="$(manifest_skill_links_checked "${target_uri}")" || return 1
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    if [[ -d "${REPO_DIR}/${source_path}" ]]; then
      "${install_fn}" "${REPO_DIR}/${source_path}" "${dest_dir}/${skill}" "${source_path}" "${skill}" || return 1
    else
      yellow "  SKIP ${skill} (source not found: ${source_path})"
    fi
  done <<< "${skill_links}"
}

install_context_profiles() {
  local target_dir="$1" display_prefix="$2"
  mkdir -p "${target_dir}"
  local profile name
  for profile in "${REPO_DIR}"/context-profiles/*.md; do
    [[ -f "${profile}" ]] || continue
    name=$(basename "${profile}")
    cp "${profile}" "${target_dir}/${name}"
    state_record_file "${target_dir}/${name}" "context-profiles/${name}" "copy"
    green "  ${name} -> ${display_prefix}/${name}"
  done
}

vibeguard_rule_id_count() {
  local root="$1"
  local total=0 file_count rule_file
  if [[ -f "${root}" ]]; then
    grep -cE '^##[[:space:]]+(RS|GO|TS|PY|U|SEC|W|TASTE)-[A-Za-z0-9-]+([[:space:]:]|$)' "${root}" 2>/dev/null || true
    return 0
  fi
  if [[ ! -d "${root}" ]]; then
    printf '0\n'
    return 0
  fi
  while IFS= read -r rule_file; do
    file_count=$(grep -cE '^##[[:space:]]+(RS|GO|TS|PY|U|SEC|W|TASTE)-[A-Za-z0-9-]+([[:space:]:]|$)' "${rule_file}" 2>/dev/null || true)
    total=$((total + file_count))
  done < <(find "${root}" \( -type f -o -type l \) -name "*.md" 2>/dev/null)
  printf '%s\n' "${total}"
}

vibeguard_managed_rule_banner_count() {
  local file="$1"
  [[ -f "${file}" ]] || return 1
  awk '
    /<!-- vibeguard-start -->/ { in_block = 1; next }
    /<!-- vibeguard-end -->/ { in_block = 0 }
    in_block && match($0, /[0-9][0-9]* rules/) {
      text = substr($0, RSTART, RLENGTH)
      sub(/ rules$/, "", text)
      print text
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "${file}"
}

vibeguard_managed_rules_block_matches_source() {
  local target_file="$1" rule_count="$2"
  local rules_file="${REPO_DIR}/claude-md/vibeguard-rules.md"
  local diff_output
  [[ -f "${target_file}" ]] || return 2
  if ! diff_output=$(setup_runtime setup-md-diff-inject "${target_file}" "${rules_file}" "${REPO_DIR}" "${rule_count}" 2>/dev/null); then
    return 2
  fi
  [[ "${diff_output}" == "SKIP" ]]
}

inject_vibeguard_rules() {
  local target_file="$1" display_label="$2" state_source="$3"
  local rules_file="${REPO_DIR}/claude-md/vibeguard-rules.md"
  local rules_diff rule_count result

  rule_count=$(claude_rule_count_for_banner)
  mkdir -p "$(dirname "${target_file}")"
  if ! rules_diff=$(setup_runtime setup-md-diff-inject "${target_file}" "${rules_file}" "${REPO_DIR}" "${rule_count}" 2>&1); then
    red "  Failed to compute ${display_label} diff"
    return 1
  fi
  if ! confirm_high_context_write "${display_label}" "${rules_diff}"; then
    if [[ "${VIBEGUARD_SETUP_DRY_RUN}" == "1" ]]; then
      echo
      return 0
    fi
    return 1
  fi
  if [[ "${rules_diff}" == "SKIP" ]]; then
    if [[ -f "${target_file}" ]]; then
      state_record_file "${target_file}" "${state_source}" "copy"
    fi
    green "  ${display_label} already up to date"
    echo
    return 0
  fi
  if result=$(setup_runtime setup-md-inject "${target_file}" "${rules_file}" "${REPO_DIR}" "${rule_count}" 2>&1); then
    if [[ -f "${target_file}" ]]; then
      state_record_file "${target_file}" "${state_source}" "copy"
    fi
    green "  VibeGuard rules synced to ${display_label} (${result})"
  else
    red "  Failed to update ${display_label}"
    return 1
  fi
  echo
}

confirm_high_context_write() {
  local label="$1"
  local diff_output="$2"

  if [[ "${diff_output}" == "SKIP" ]]; then
    return 0
  fi

  printf '%s\n' "${diff_output}" >&2

  if [[ "${VIBEGUARD_SETUP_DRY_RUN}" == "1" ]]; then
    yellow "  DRY-RUN: ${label} not written"
    return 1
  fi

  if [[ "${VIBEGUARD_SETUP_AUTO}" == "1" ]]; then
    yellow "  AUTO: applying ${label} (VIBEGUARD_SETUP_AUTO=1 or --yes)"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    red "  ERROR: ${label} requires explicit confirmation. Re-run with --yes or VIBEGUARD_SETUP_AUTO=1."
    return 2
  fi

  local answer
  read -r -p "Apply ${label}? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) red "  Aborted ${label}"; return 2 ;;
  esac
}

safe_symlink() {
  local src="$1" dst="$2"
  if [[ -d "${dst}" && ! -L "${dst}" ]]; then
    if [[ -n "$(ls -A "${dst}" 2>/dev/null)" ]]; then
      red "  ERROR: ${dst} is a non-empty directory, refusing to overwrite."
      red "  Please remove or rename it manually, then re-run setup.sh."
      return 1
    fi
    rmdir "${dst}"
  fi
  ln -sfn "${src}" "${dst}"
}
