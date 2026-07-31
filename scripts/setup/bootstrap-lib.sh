#!/usr/bin/env bash
# Shared fail-closed helpers for the pinned VibeGuard payload bootstrap.

bootstrap_error() {
  printf 'ERROR: %s\n' "$1" >&2
}

bootstrap_sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    return 1
  fi
}

bootstrap_validate_version() {
  local version="$1"
  local core_and_prerelease="${version}"
  local core prerelease="" build="" identifier
  local -a prerelease_identifiers=()

  if [[ "${core_and_prerelease}" == *+* ]]; then
    build="${core_and_prerelease#*+}"
    core_and_prerelease="${core_and_prerelease%%+*}"
    [[ "${build}" != *+* ]] || return 1
    [[ "${build}" =~ ^[0-9A-Za-z-]+([.][0-9A-Za-z-]+)*$ ]] || return 1
  fi

  if [[ "${core_and_prerelease}" == *-* ]]; then
    core="${core_and_prerelease%%-*}"
    prerelease="${core_and_prerelease#*-}"
    [[ "${prerelease}" =~ ^[0-9A-Za-z-]+([.][0-9A-Za-z-]+)*$ ]] || return 1
    IFS='.' read -r -a prerelease_identifiers <<< "${prerelease}"
    for identifier in "${prerelease_identifiers[@]}"; do
      if [[ "${identifier}" =~ ^[0-9]+$ \
        && "${identifier}" == 0* && "${identifier}" != "0" ]]; then
        return 1
      fi
    done
  else
    core="${core_and_prerelease}"
  fi

  [[ "${core}" =~ ^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$ ]]
}

bootstrap_download_release_assets() {
  local release_repo="$1" tag="$2" asset="$3" destination="$4"
  local gh_dir="${destination}/gh"
  local curl_dir="${destination}/curl"
  local base_url

  mkdir -p "${gh_dir}" "${curl_dir}"
  if command -v gh >/dev/null 2>&1 \
    && gh release download "${tag}" \
      --repo "${release_repo}" \
      --pattern "${asset}" \
      --pattern "SHA256SUMS" \
      --dir "${gh_dir}" >/dev/null 2>&1 \
    && [[ -f "${gh_dir}/${asset}" && ! -L "${gh_dir}/${asset}" ]] \
    && [[ -f "${gh_dir}/SHA256SUMS" && ! -L "${gh_dir}/SHA256SUMS" ]]; then
    printf '%s\n' "${gh_dir}"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    bootstrap_error "release download failed with gh and curl is unavailable."
    return 1
  fi
  base_url="https://github.com/${release_repo}/releases/download/${tag}"
  if ! curl -fsSL -o "${curl_dir}/${asset}" "${base_url}/${asset}" >/dev/null 2>&1 \
    || ! curl -fsSL -o "${curl_dir}/SHA256SUMS" \
      "${base_url}/SHA256SUMS" >/dev/null 2>&1; then
    bootstrap_error "release download failed for ${release_repo}@${tag}."
    return 1
  fi
  if [[ ! -f "${curl_dir}/${asset}" || -L "${curl_dir}/${asset}" \
    || ! -f "${curl_dir}/SHA256SUMS" || -L "${curl_dir}/SHA256SUMS" ]]; then
    bootstrap_error "release download did not produce regular ${asset} and SHA256SUMS files."
    return 1
  fi
  printf '%s\n' "${curl_dir}"
}

bootstrap_verify_checksum() {
  local asset_path="$1" sums_path="$2" asset_name="$3"
  local expected actual

  expected="$(
    awk -v file="${asset_name}" '
      ($2 == file || $2 == "*" file) {
        count += 1
        digest = $1
      }
      END {
        if (count == 1) {
          print digest
          exit 0
        }
        exit 1
      }
    ' "${sums_path}"
  )" || {
    bootstrap_error "SHA256SUMS must contain exactly one entry for ${asset_name}."
    return 1
  }
  if [[ ${#expected} -ne 64 || "${expected}" == *[!0-9a-f]* ]]; then
    bootstrap_error "SHA256SUMS contains an invalid digest for ${asset_name}."
    return 1
  fi
  if ! actual="$(bootstrap_sha256_file "${asset_path}")"; then
    bootstrap_error "sha256sum or shasum is required to verify ${asset_name}."
    return 1
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    bootstrap_error "payload checksum verification failed for ${asset_name}."
    bootstrap_error "expected ${expected}, got ${actual}."
    return 1
  fi
  # shellcheck disable=SC2034 # Consumed by the sourcing bootstrap entrypoint.
  BOOTSTRAP_PAYLOAD_SHA256="${actual}"
}

bootstrap_verify_release_provenance() {
  local asset_path="$1" release_repo="$2" tag="$3"
  BOOTSTRAP_PROVENANCE_STATUS="checksum-only"
  BOOTSTRAP_PROVENANCE_REASON=""

  if ! command -v gh >/dev/null 2>&1; then
    BOOTSTRAP_PROVENANCE_REASON="gh not found"
    return 2
  fi
  if ! gh attestation verify --help >/dev/null 2>&1; then
    BOOTSTRAP_PROVENANCE_REASON="gh attestation verify unavailable"
    return 2
  fi
  if ! gh auth status >/dev/null 2>&1; then
    BOOTSTRAP_PROVENANCE_REASON="gh auth unavailable"
    return 2
  fi
  if gh attestation verify "${asset_path}" \
    --repo "${release_repo}" \
    --signer-workflow "github.com/${release_repo}/.github/workflows/release.yml" \
    --source-ref "refs/tags/${tag}" \
    --deny-self-hosted-runners >/dev/null 2>&1; then
    # shellcheck disable=SC2034 # Consumed by the sourcing bootstrap entrypoint.
    BOOTSTRAP_PROVENANCE_STATUS="verified-provenance"
    return 0
  fi

  # shellcheck disable=SC2034 # Consumed by the sourcing bootstrap entrypoint.
  BOOTSTRAP_PROVENANCE_REASON="gh attestation verify failed"
  return 1
}

bootstrap_validate_archive_listing() {
  local archive="$1" names_file="$2" types_file="$3"

  if ! LC_ALL=C tar -tzf "${archive}" > "${names_file}" \
    || ! LC_ALL=C tar -tvzf "${archive}" > "${types_file}"; then
    bootstrap_error "payload archive cannot be read as gzip-compressed tar."
    return 1
  fi
  if ! awk '
    function reject(message) {
      print "ERROR: unsafe payload archive path: " message > "/dev/stderr"
      bad = 1
    }
    {
      name = $0
      normalized = name
      sub(/\/$/, "", normalized)
      if (name == "" || normalized == "") reject("empty path")
      if (name !~ /^[A-Za-z0-9._+@=\/-]+$/) reject(name)
      if (name ~ /^\//) reject(name)
      if (name ~ /(^|\/)\.\.?($|\/)/) reject(name)
      if (name ~ /\/\//) reject(name)
      if (seen[normalized]++) reject("duplicate " normalized)
      if (normalized == ".vibeguard-payload") marker = 1
      if (normalized == "setup.sh") setup = 1
      if (normalized == "scripts/release/payload-manifest.txt") manifest = 1
      if (normalized == "vibeguard-runtime/VERSION") version = 1
    }
    END {
      if (!marker || !setup || !manifest || !version) {
        print "ERROR: payload archive is missing a required install file." > "/dev/stderr"
        bad = 1
      }
      exit bad
    }
  ' "${names_file}"; then
    return 1
  fi
  if ! awk '
    {
      type = substr($1, 1, 1)
      if (type != "-" && type != "d") {
        print "ERROR: payload archive contains a link or special entry." > "/dev/stderr"
        bad = 1
      }
    }
    END { exit bad }
  ' "${types_file}"; then
    return 1
  fi
}

bootstrap_validate_extracted_payload() {
  local root="$1" expected_version="$2"
  local marker="${root}/.vibeguard-payload"
  local manifest="${root}/scripts/release/payload-manifest.txt"
  local runtime_version_file="${root}/vibeguard-runtime/VERSION"
  local marker_version marker_manifest_sha marker_commit actual_manifest_sha runtime_version

  if find "${root}" -type l -print | grep -q . \
    || find "${root}" ! -type d ! -type f -print | grep -q .; then
    bootstrap_error "extracted payload contains a link or special entry."
    return 1
  fi
  if [[ ! -f "${marker}" || -L "${marker}" \
    || ! -f "${manifest}" || -L "${manifest}" \
    || ! -f "${runtime_version_file}" || -L "${runtime_version_file}" \
    || ! -f "${root}/setup.sh" || -L "${root}/setup.sh" \
    || ! -x "${root}/setup.sh" ]]; then
    bootstrap_error "extracted payload is missing a required regular executable or metadata file."
    return 1
  fi

  if ! awk -F= '
    $1 == "version" { versions += 1 }
    $1 == "manifest_sha256" { manifests += 1 }
    $1 == "git_commit" { commits += 1 }
    $1 != "version" && $1 != "manifest_sha256" && $1 != "git_commit" { unknown += 1 }
    END { exit !(versions == 1 && manifests == 1 && commits == 1 && unknown == 0) }
  ' "${marker}"; then
    bootstrap_error "payload marker must contain exactly version, manifest_sha256, and git_commit."
    return 1
  fi
  marker_version="$(awk -F= '$1 == "version" { print $2; exit }' "${marker}")"
  marker_manifest_sha="$(awk -F= '$1 == "manifest_sha256" { print $2; exit }' "${marker}")"
  marker_commit="$(awk -F= '$1 == "git_commit" { print $2; exit }' "${marker}")"
  runtime_version="$(tr -d '[:space:]' < "${runtime_version_file}")"
  if [[ "${marker_version}" != "${expected_version}" \
    || "${runtime_version}" != "${expected_version}" ]]; then
    bootstrap_error "payload version metadata does not match required version ${expected_version}."
    return 1
  fi
  if [[ ${#marker_manifest_sha} -ne 64 || "${marker_manifest_sha}" == *[!0-9a-f]* \
    || ${#marker_commit} -ne 40 || "${marker_commit}" == *[!0-9a-f]* ]]; then
    bootstrap_error "payload marker contains invalid digest or commit metadata."
    return 1
  fi
  if ! actual_manifest_sha="$(bootstrap_sha256_file "${manifest}")" \
    || [[ "${actual_manifest_sha}" != "${marker_manifest_sha}" ]]; then
    bootstrap_error "payload marker manifest checksum verification failed."
    return 1
  fi
}

bootstrap_atomic_replace_symlink() {
  local source_link="$1" target_link="$2"

  # GNU and BusyBox mv support -T. Probe the operation itself so Linux
  # implementations are not inferred from a GNU-only version banner.
  if mv -fT -- "${source_link}" "${target_link}" 2>/dev/null; then
    return 0
  fi

  # BSD mv (including macOS) uses -h to replace a destination symlink instead
  # of following it when that symlink targets a directory.
  if mv -hf "${source_link}" "${target_link}" 2>/dev/null; then
    return 0
  fi
  bootstrap_error "mv lacks a verified atomic no-dereference rename mode (-T or -h)."
  return 1
}

bootstrap_prepare_clean_selection() {
  local dist_root="$1" current_link="$2" selected
  # shellcheck disable=SC2034 # Consumed by the sourcing bootstrap entrypoint.
  BOOTSTRAP_CLEAN_SELECTED_VERSION=""
  if [[ ! -L "${current_link}" ]]; then
    return 0
  fi
  selected="$(readlink "${current_link}")" || return 1
  if ! bootstrap_validate_version "${selected}" \
    || [[ ! -d "${dist_root}/${selected}" || -L "${dist_root}/${selected}" ]] \
    || ! bootstrap_validate_extracted_payload "${dist_root}/${selected}" "${selected}"; then
    bootstrap_error "active bootstrap payload selection is not safely removable: ${selected}"
    return 1
  fi
  BOOTSTRAP_CLEAN_SELECTED_VERSION="${selected}"
}

bootstrap_pid_liveness() {
  local pid="$1" ps_output="" pid_state
  BOOTSTRAP_PID_LIVENESS="ambiguous"
  if kill -0 "${pid}" 2>/dev/null; then
    BOOTSTRAP_PID_LIVENESS="active"
    return 0
  fi
  if ! ps_output="$(LC_ALL=C ps -A -o pid= 2>/dev/null)"; then
    return 0
  fi
  if pid_state="$(awk -v expected="${pid}" '
    NF != 1 || $1 !~ /^[1-9][0-9]*$/ { bad = 1; next }
    seen[$1]++ { bad = 1 }
    $1 == expected { found = 1 }
    { count += 1 }
    END {
      if (bad || count == 0) exit 1
      print found ? "active" : "dead"
    }
  ' <<< "${ps_output}")"; then
    BOOTSTRAP_PID_LIVENESS="${pid_state}"
  fi
}

bootstrap_lock_parse_owner_file() {
  local owner_file="$1" parsed

  if [[ -L "${owner_file}" || ! -f "${owner_file}" ]]; then
    bootstrap_error "lock owner metadata must be a regular file: ${owner_file}"
    return 1
  fi
  if ! parsed="$(awk -F= '
    NR == 1 && NF == 2 && $1 == "pid" && $2 ~ /^[1-9][0-9]*$/ {
      pid = $2
      next
    }
    NR == 2 && NF == 2 && $1 == "nonce" && $2 ~ /^[A-Za-z0-9._-]+$/ {
      nonce = $2
      next
    }
    { bad = 1 }
    END {
      if (!bad && NR == 2 && pid != "" && nonce != "") {
        print pid "\t" nonce
        exit 0
      }
      exit 1
    }
  ' "${owner_file}")"; then
    bootstrap_error "lock owner metadata is malformed: ${owner_file}"
    return 1
  fi
  IFS=$'\t' read -r BOOTSTRAP_LOCK_READ_PID BOOTSTRAP_LOCK_READ_NONCE <<< "${parsed}"
}

bootstrap_lock_reap_exact_owner() {
  local lock_file="$1" dist_root="$2" expected_pid="$3" expected_nonce="$4" action="$5"
  local claimed="${dist_root}/.bootstrap.lock.reap.$$.$RANDOM.${expected_nonce}"
  local require_dead="${6:-0}" owner_matches=1

  if [[ -e "${claimed}" || -L "${claimed}" ]]; then
    bootstrap_error "lock reap path already exists: ${claimed}"
    return 1
  fi
  if ! mv -- "${lock_file}" "${claimed}"; then
    bootstrap_error "could not claim bootstrap lock for ${action}: ${lock_file}"
    return 1
  fi
  if ! bootstrap_lock_parse_owner_file "${claimed}" \
    || [[ "${BOOTSTRAP_LOCK_READ_PID}" != "${expected_pid}" ]] \
    || [[ "${BOOTSTRAP_LOCK_READ_NONCE}" != "${expected_nonce}" ]]; then
    owner_matches=0
  fi
  if [[ "${owner_matches}" == "1" && "${require_dead}" == "1" ]]; then
    bootstrap_pid_liveness "${expected_pid}"
    if [[ "${BOOTSTRAP_PID_LIVENESS}" != "dead" ]]; then
      bootstrap_error "lock owner pid=${expected_pid} is no longer proven dead during ${action}."
      owner_matches=0
    fi
  fi
  if [[ "${owner_matches}" == "0" ]]; then
    bootstrap_error "lock ownership changed during ${action}; preserving foreign lock."
    if [[ ! -e "${lock_file}" && ! -L "${lock_file}" ]]; then
      if ! mv -- "${claimed}" "${lock_file}"; then
        bootstrap_error "could not restore foreign lock after ${action}: ${claimed}"
      fi
    else
      bootstrap_error "foreign lock retained at reap path after ${action}: ${claimed}"
    fi
    return 1
  fi
  if ! rm -f -- "${claimed}"; then
    bootstrap_error "failed to remove exact bootstrap lock owner during ${action}: ${claimed}"
    return 1
  fi
}

bootstrap_lock_reap_legacy_directory() {
  local lock_dir="$1" dist_root="$2" expected_pid="$3" expected_nonce="$4" action="$5"
  local claimed="${dist_root}/.bootstrap.lock.reap.$$.$RANDOM.legacy"
  local owner_matches=1

  if [[ -L "${lock_dir}" || ! -d "${lock_dir}" ]]; then
    bootstrap_error "legacy bootstrap lock must be a real directory: ${lock_dir}"
    return 1
  fi
  if find "${lock_dir}" -mindepth 1 -maxdepth 1 ! -name owner -print | grep -q .; then
    bootstrap_error "legacy bootstrap lock contains unexpected entries; preserving ${lock_dir}."
    return 1
  fi
  if [[ -e "${claimed}" || -L "${claimed}" ]] || ! mv -- "${lock_dir}" "${claimed}"; then
    bootstrap_error "could not claim legacy bootstrap lock for ${action}: ${lock_dir}"
    return 1
  fi
  if ! bootstrap_lock_parse_owner_file "${claimed}/owner" \
    || [[ "${BOOTSTRAP_LOCK_READ_PID}" != "${expected_pid}" ]] \
    || [[ "${BOOTSTRAP_LOCK_READ_NONCE}" != "${expected_nonce}" ]]; then
    owner_matches=0
  else
    bootstrap_pid_liveness "${expected_pid}"
    [[ "${BOOTSTRAP_PID_LIVENESS}" == "dead" ]] || owner_matches=0
  fi
  if [[ "${owner_matches}" == "0" || -e "${lock_dir}" || -L "${lock_dir}" ]]; then
    bootstrap_error "legacy lock ownership changed or is no longer proven dead during ${action}."
    if [[ ! -e "${lock_dir}" && ! -L "${lock_dir}" ]]; then
      mv -- "${claimed}" "${lock_dir}" || \
        bootstrap_error "could not restore legacy lock after ${action}: ${claimed}"
    else
      bootstrap_error "legacy lock retained at reap path after ${action}: ${claimed}"
    fi
    return 1
  fi
  if ! rm -f -- "${claimed}/owner" || ! rmdir "${claimed}"; then
    bootstrap_error "failed to remove legacy bootstrap lock during ${action}: ${claimed}"
    return 1
  fi
}

bootstrap_setup_args_include_help() {
  local index=1
  while [[ "${index}" -lt "${SETUP_ARG_COUNT}" ]]; do
    case "${SETUP_ARGS[${index}]}" in
      --help|-h) return 0 ;;
    esac
    index=$((index + 1))
  done
  return 1
}

bootstrap_prepend_setup_arg() {
  local value="$1" index=0
  local -a updated=("${value}")
  while [[ "${index}" -lt "${SETUP_ARG_COUNT}" ]]; do
    updated[${#updated[@]}]="${SETUP_ARGS[${index}]}"
    index=$((index + 1))
  done
  SETUP_ARGS=("${updated[@]}")
  SETUP_ARG_COUNT=$((SETUP_ARG_COUNT + 1))
}

bootstrap_transaction_write() {
  local transaction_file="$1" dist_root="$2" version="$3" payload_sha256="$4" phase="$5"
  local temporary="${dist_root}/.bootstrap-transaction-write.$$.$RANDOM"

  case "${phase}" in
    prepared|setup|committed|cleaning) ;;
    *) bootstrap_error "invalid bootstrap transaction phase: ${phase}"; return 1 ;;
  esac
  if [[ ${#payload_sha256} -ne 64 || "${payload_sha256}" == *[!0-9a-f]* ]]; then
    bootstrap_error "invalid bootstrap transaction payload checksum."
    return 1
  fi
  if [[ -e "${temporary}" || -L "${temporary}" ]]; then
    bootstrap_error "bootstrap transaction temporary path exists: ${temporary}"
    return 1
  fi
  if ! printf 'version=%s\npayload_sha256=%s\nphase=%s\n' \
    "${version}" "${payload_sha256}" "${phase}" > "${temporary}" \
    || ! mv -f -- "${temporary}" "${transaction_file}"; then
    rm -f -- "${temporary}" 2>/dev/null || true
    bootstrap_error "failed to persist bootstrap transaction: ${transaction_file}"
    return 1
  fi
}

bootstrap_transaction_read() {
  local transaction_file="$1" parsed

  if [[ -L "${transaction_file}" || ! -f "${transaction_file}" ]]; then
    bootstrap_error "bootstrap transaction must be a regular file: ${transaction_file}"
    return 1
  fi
  if ! parsed="$(awk -F= '
    NR == 1 && NF == 2 && $1 == "version" && $2 != "" { version = $2; next }
    NR == 2 && NF == 2 && $1 == "payload_sha256" && $2 ~ /^[0-9a-f]{64}$/ { sha = $2; next }
    NR == 3 && NF == 2 && $1 == "phase" && $2 ~ /^(prepared|setup|committed|cleaning)$/ { phase = $2; next }
    { bad = 1 }
    END {
      if (!bad && NR == 3 && version != "" && sha != "" && phase != "") {
        print version "\t" sha "\t" phase
        exit 0
      }
      exit 1
    }
  ' "${transaction_file}")"; then
    bootstrap_error "bootstrap transaction metadata is malformed: ${transaction_file}"
    return 1
  fi
  # shellcheck disable=SC2034 # Consumed by the sourcing bootstrap entrypoint.
  IFS=$'\t' read -r BOOTSTRAP_TRANSACTION_VERSION \
    BOOTSTRAP_TRANSACTION_SHA256 BOOTSTRAP_TRANSACTION_PHASE <<< "${parsed}"
}

BOOTSTRAP_PROCESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bootstrap_process.sh"
if [[ ! -f "${BOOTSTRAP_PROCESS_LIB}" ]]; then
  bootstrap_error "missing bootstrap process helper: ${BOOTSTRAP_PROCESS_LIB}"
  return 1
fi
# shellcheck source=scripts/setup/bootstrap_process.sh
source "${BOOTSTRAP_PROCESS_LIB}"

BOOTSTRAP_STATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bootstrap_state.sh"
if [[ ! -f "${BOOTSTRAP_STATE_LIB}" ]]; then
  bootstrap_error "missing bootstrap state helper: ${BOOTSTRAP_STATE_LIB}"
  return 1
fi
# shellcheck source=scripts/setup/bootstrap_state.sh
source "${BOOTSTRAP_STATE_LIB}"
