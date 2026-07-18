#!/usr/bin/env bash
# Runtime binary acquisition and provenance helpers for setup/install.sh.

runtime_release_target() {
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

runtime_release_tag() {
  local version version_file
  if [[ "${RUNTIME_VERSION_OVERRIDE_SET}" == "1" ]]; then
    version="${RUNTIME_VERSION_OVERRIDE}"
  else
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

runtime_sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    return 1
  fi
}

download_prebuilt_runtime() {
  local target="$1" tag="$2" dest="$3"
  local asset="vibeguard-runtime-${target}"
  local release_repo="${VIBEGUARD_RUNTIME_RELEASE_REPO:-majiayu000/vibeguard}"
  local download_dir downloaded reason expected actual actual_size
  local manifest_metadata manifest_expected manifest_size
  local provenance_rc provenance_status provenance_note
  local -a errors=()

  download_dir="$(mktemp -d "$(dirname "${dest}")/runtime_download_XXXXXX")"
  downloaded=0
  echo "  Downloading ${asset} from ${release_repo}@${tag}..."

  if command -v gh >/dev/null 2>&1; then
    if gh release download "${tag}" \
      --repo "${release_repo}" \
      --pattern "${asset}" \
      --pattern "SHA256SUMS" \
      --dir "${download_dir}" >/dev/null 2>&1; then
      downloaded=1
      gh release download "${tag}" \
        --repo "${release_repo}" \
        --pattern "${SETUP_RUNTIME_RELEASE_MANIFEST}" \
        --dir "${download_dir}" >/dev/null 2>&1 || true
    else
      errors+=("gh release download failed")
    fi
  else
    errors+=("gh not found")
  fi

  if [[ "${downloaded}" != "1" ]]; then
    if command -v curl >/dev/null 2>&1; then
      local base_url="https://github.com/${release_repo}/releases/download/${tag}"
      if curl -fsSL -o "${download_dir}/${asset}" "${base_url}/${asset}" >/dev/null 2>&1 \
        && curl -fsSL -o "${download_dir}/SHA256SUMS" "${base_url}/SHA256SUMS" >/dev/null 2>&1; then
        downloaded=1
        curl -fsSL -o "${download_dir}/${SETUP_RUNTIME_RELEASE_MANIFEST}" \
          "${base_url}/${SETUP_RUNTIME_RELEASE_MANIFEST}" >/dev/null 2>&1 || true
      else
        errors+=("curl release download failed")
      fi
    else
      errors+=("curl not found")
    fi
  fi

  if [[ "${downloaded}" != "1" ]]; then
    reason="download failed"
    if [[ ${#errors[@]} -gt 0 ]]; then
      reason="${errors[*]}"
    fi
    RUNTIME_PREBUILT_REASON="${reason}"
    rm -rf "${download_dir}"
    return 1
  fi

  if [[ ! -f "${download_dir}/${asset}" || ! -f "${download_dir}/SHA256SUMS" ]]; then
    red "  ERROR: release download did not include ${asset} and SHA256SUMS."
    rm -rf "${download_dir}"
    return 10
  fi

  expected="$(awk -v file="${asset}" '($2 == file || $2 == "*" file) { print $1; exit }' "${download_dir}/SHA256SUMS")"
  if [[ -z "${expected}" ]]; then
    red "  ERROR: SHA256SUMS missing entry for ${asset}."
    rm -rf "${download_dir}"
    return 10
  fi
  if ! actual="$(runtime_sha256_file "${download_dir}/${asset}")"; then
    red "  ERROR: sha256sum or shasum not found; cannot verify vibeguard-runtime release binary."
    rm -rf "${download_dir}"
    return 10
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    red "  ERROR: vibeguard-runtime checksum verification failed for ${asset}."
    red "  Expected ${expected}, got ${actual}."
    rm -rf "${download_dir}"
    return 10
  fi
  if [[ -f "${download_dir}/${SETUP_RUNTIME_RELEASE_MANIFEST}" ]]; then
    if ! actual_size="$(setup_runtime_file_size "${download_dir}/${asset}")"; then
      red "  ERROR: could not determine downloaded size for ${asset}."
      rm -rf "${download_dir}"
      return 10
    fi
    if ! manifest_metadata="$(setup_runtime_release_manifest_sha256 \
      "${download_dir}/${SETUP_RUNTIME_RELEASE_MANIFEST}" \
      "${tag}" \
      "${release_repo}" \
      "${target}" \
      "${asset}")"; then
      red "  ERROR: runtime release manifest verification failed for ${asset}."
      red "  ${SETUP_RUNTIME_RELEASE_MANIFEST} must match repo, tag, version, target, filename, size, and SHA256 format."
      rm -rf "${download_dir}"
      return 10
    fi
    read -r manifest_expected manifest_size <<< "${manifest_metadata}"
    if [[ "${manifest_expected}" != "${expected}" ]]; then
      red "  ERROR: runtime release manifest checksum mismatch for ${asset}."
      red "  SHA256SUMS has ${expected}, ${SETUP_RUNTIME_RELEASE_MANIFEST} has ${manifest_expected}."
      rm -rf "${download_dir}"
      return 10
    fi
    if [[ "${manifest_size}" != "${actual_size}" ]]; then
      red "  ERROR: runtime release manifest size mismatch for ${asset}."
      red "  Downloaded ${actual_size} bytes, ${SETUP_RUNTIME_RELEASE_MANIFEST} has ${manifest_size}."
      rm -rf "${download_dir}"
      return 10
    fi
  fi
  provenance_rc=0
  setup_runtime_verify_release_provenance "${download_dir}/${asset}" "${release_repo}" "${tag}" || provenance_rc=$?
  case "${provenance_rc}" in
    0)
      provenance_status="verified-provenance"
      provenance_note="provenance=verified-provenance"
      ;;
    2)
      if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
        red "  ERROR: vibeguard-runtime provenance verification is required but unavailable for ${asset}."
        red "  ${SETUP_RUNTIME_PROVENANCE_REASON:-verifier unavailable}"
        rm -rf "${download_dir}"
        return 10
      fi
      provenance_status="checksum-only"
      provenance_note="provenance=checksum-only (${SETUP_RUNTIME_PROVENANCE_REASON:-verifier unavailable})"
      yellow "  Runtime provenance is checksum-only: ${SETUP_RUNTIME_PROVENANCE_REASON:-verifier unavailable}."
      ;;
    *)
      red "  ERROR: vibeguard-runtime provenance verification failed for ${asset}."
      red "  ${SETUP_RUNTIME_PROVENANCE_REASON:-unknown provenance verification failure}"
      rm -rf "${download_dir}"
      return 10
      ;;
  esac

  mkdir -p "$(dirname "${dest}")"
  cp "${download_dir}/${asset}" "${dest}"
  chmod +x "${dest}"
  RUNTIME_PROVENANCE_STATUS="${provenance_status}"
  RUNTIME_PROVENANCE_REASON="${SETUP_RUNTIME_PROVENANCE_REASON:-}"
  RUNTIME_PROVENANCE_RELEASE_REPO="${release_repo}"
  RUNTIME_PROVENANCE_TAG="${tag}"
  RUNTIME_PROVENANCE_TARGET="${target}"
  RUNTIME_PROVENANCE_SHA256="${actual}"
  rm -rf "${download_dir}"
  green "  vibeguard-runtime downloaded and verified (${tag}, ${target}; ${provenance_note})"
}

runtime_version_mismatch_reason() {
  local runtime_path="$1" expected actual
  expected="$(setup_runtime_expected_version 2>/dev/null)" || {
    printf 'runtime VERSION could not be resolved'
    return 1
  }
  actual="$("${runtime_path}" version 2>/dev/null)" || {
    printf 'runtime does not support the version command'
    return 1
  }
  actual="${actual%%$'\n'*}"
  actual="${actual//$'\r'/}"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'runtime self-reported version %s, expected %s' "${actual:-unknown}" "${expected}"
    return 1
  fi
  return 0
}

verify_prepared_runtime_version() {
  local runtime_path="$1" reason
  if reason="$(runtime_version_mismatch_reason "${runtime_path}")"; then
    return 0
  fi
  red "  ERROR: prepared vibeguard-runtime is incompatible: ${reason}"
  return 1
}

prepare_runtime_from_source() {
  local fallback_reason="${1:-}"
  if [[ -n "${fallback_reason}" ]]; then
    yellow "  Falling back to source build (${fallback_reason})."
  fi
  if [[ ! -f "${REPO_DIR}/vibeguard-runtime/Cargo.toml" ]]; then
    red "  ERROR: vibeguard-runtime/Cargo.toml not found; cannot install hooks without the Rust runtime."
    exit 2
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    if [[ -n "${fallback_reason}" ]]; then
      red "  ERROR: prebuilt vibeguard-runtime unavailable (${fallback_reason}) and cargo not found for source fallback."
      red "  Install Rust/Cargo or use a platform with a published release binary."
    else
      red "  ERROR: --build-from-source requested but cargo not found. Install Rust/Cargo before installing VibeGuard."
    fi
    exit 2
  fi
  echo "  Building vibeguard-runtime from source (Rust)..."
  local runtime_target_dir="${_INSTALL_TMP}/cargo-target"
  if cargo build --release --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --target-dir "${runtime_target_dir}" --quiet 2>/dev/null; then
    local runtime_binary
    runtime_binary="${runtime_target_dir}/release/vibeguard-runtime"
    if [[ ! -x "${runtime_binary}" ]]; then
      red "  ERROR: vibeguard-runtime build output not found at ${runtime_binary}"
      exit 2
    fi
    mkdir -p "${_INSTALL_TMP}/bin"
    cp "${runtime_binary}" "${_INSTALL_TMP}/bin/vibeguard-runtime"
    chmod +x "${_INSTALL_TMP}/bin/vibeguard-runtime"
    verify_prepared_runtime_version "${_INSTALL_TMP}/bin/vibeguard-runtime" || exit 2
    rm -rf "${runtime_target_dir}"
    RUNTIME_PROVENANCE_STATUS="source-build"
    RUNTIME_PROVENANCE_REASON="${fallback_reason:-build-from-source requested}"
    RUNTIME_PROVENANCE_RELEASE_REPO=""
    RUNTIME_PROVENANCE_TAG=""
    RUNTIME_PROVENANCE_TARGET=""
    RUNTIME_PROVENANCE_SHA256=""
    green "  vibeguard-runtime binary prepared from source"
  else
    red "  ERROR: vibeguard-runtime build failed. Fix the Rust build before installing VibeGuard."
    exit 2
  fi
}

write_runtime_provenance_state() {
  local dest="$1"
  mkdir -p "$(dirname "${dest}")"
  {
    printf 'status=%s\n' "${RUNTIME_PROVENANCE_STATUS:-unknown}"
    [[ -z "${RUNTIME_PROVENANCE_REASON}" ]] || printf 'reason=%s\n' "${RUNTIME_PROVENANCE_REASON}"
    [[ -z "${RUNTIME_PROVENANCE_RELEASE_REPO}" ]] || printf 'release_repo=%s\n' "${RUNTIME_PROVENANCE_RELEASE_REPO}"
    [[ -z "${RUNTIME_PROVENANCE_TAG}" ]] || printf 'tag=%s\n' "${RUNTIME_PROVENANCE_TAG}"
    [[ -z "${RUNTIME_PROVENANCE_TARGET}" ]] || printf 'target=%s\n' "${RUNTIME_PROVENANCE_TARGET}"
    [[ -z "${RUNTIME_PROVENANCE_SHA256}" ]] || printf 'sha256=%s\n' "${RUNTIME_PROVENANCE_SHA256}"
  } > "${dest}"
}

prepare_runtime_binary() {
  local target tag download_rc fallback_reason
  mkdir -p "${_INSTALL_TMP}/bin"

  if [[ "${BUILD_FROM_SOURCE}" == "1" ]]; then
    prepare_runtime_from_source ""
    return
  fi

  if ! target="$(runtime_release_target)"; then
    if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
      red "  ERROR: --require-provenance requires a supported release target; unsupported platform $(uname -s)/$(uname -m)."
      exit 2
    fi
    prepare_runtime_from_source "unsupported platform $(uname -s)/$(uname -m)"
    return
  fi
  if ! tag="$(runtime_release_tag)"; then
    if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
      red "  ERROR: --require-provenance requires a resolvable runtime release tag."
      exit 2
    fi
    prepare_runtime_from_source "runtime VERSION could not be resolved"
    return
  fi

  RUNTIME_PREBUILT_REASON=""
  download_rc=0
  download_prebuilt_runtime "${target}" "${tag}" "${_INSTALL_TMP}/bin/vibeguard-runtime" || download_rc=$?
  if [[ "${download_rc}" -eq 0 ]]; then
    if verify_prepared_runtime_version "${_INSTALL_TMP}/bin/vibeguard-runtime"; then
      return
    fi
    if [[ "${RUNTIME_VERSION_OVERRIDE_SET}" == "1" ]]; then
      exit 2
    fi
    if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
      red "  ERROR: --require-provenance requires a downloaded runtime that matches the repo runtime VERSION."
      exit 2
    fi
    rm -f "${_INSTALL_TMP}/bin/vibeguard-runtime"
    prepare_runtime_from_source "downloaded runtime does not match repo runtime VERSION"
    return
  fi
  if [[ "${download_rc}" -eq 10 ]]; then
    exit 2
  fi
  fallback_reason="${RUNTIME_PREBUILT_REASON:-download failed}"
  if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
    red "  ERROR: --require-provenance requires a downloaded runtime with verified provenance (${fallback_reason})."
    exit 2
  fi
  prepare_runtime_from_source "${fallback_reason}"
}
