#!/usr/bin/env bash
# Bootstrap payload integrity comparison and transaction-owned cleanup helpers.

bootstrap_write_payload_entry_modes() {
  local root="$1" output="$2"
  if ! : > "${output}"; then
    bootstrap_error "could not initialize payload entry mode map: ${output}"
    return 1
  fi
  if ! find "${root}" -mindepth 1 -print | LC_ALL=C sort | while IFS= read -r path; do
    local kind mode relative
    relative="${path#${root}/}"
    if [[ -d "${path}" ]]; then
      kind="directory"
    elif [[ -f "${path}" ]]; then
      kind="file"
    else
      bootstrap_error "payload mode map encountered a link or special entry: ${relative}"
      exit 1
    fi
    if mode="$(stat -c '%a' -- "${path}" 2>/dev/null)"; then
      :
    elif mode="$(stat -f '%Lp' "${path}" 2>/dev/null)"; then
      :
    else
      bootstrap_error "could not read payload permissions: ${relative}"
      exit 1
    fi
    printf '%s\t%s\t%s\n' "${relative}" "${kind}" "${mode}"
  done >> "${output}"; then
    bootstrap_error "could not build payload entry mode map: ${root}"
    return 1
  fi
}

bootstrap_payload_entry_modes_match() {
  local staged_root="$1" retained_root="$2" work_root="$3"
  local staged_map="${work_root}/staged-entry-modes"
  local retained_map="${work_root}/retained-entry-modes"
  bootstrap_write_payload_entry_modes "${staged_root}" "${staged_map}" || return 1
  bootstrap_write_payload_entry_modes "${retained_root}" "${retained_map}" || return 1
  if ! diff -q "${staged_map}" "${retained_map}" >/dev/null 2>&1; then
    bootstrap_error \
      "existing distribution permissions or entry types differ from the verified payload: ${retained_root}"
    return 1
  fi
}

bootstrap_reap_transaction_write_temporaries() {
  local dist_root="$1" entries entry
  if ! entries="$(
    find "${dist_root}" -mindepth 1 -maxdepth 1 \
      -name '.bootstrap-transaction-write.*' -print | LC_ALL=C sort
  )"; then
    bootstrap_error "could not enumerate bootstrap transaction write temporaries."
    return 1
  fi
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    if [[ -L "${entry}" || ! -f "${entry}" ]]; then
      bootstrap_error "bootstrap transaction write temporary is not a regular file: ${entry}"
      return 1
    fi
    if ! rm -f -- "${entry}" \
      || [[ -e "${entry}" || -L "${entry}" ]]; then
      bootstrap_error "could not remove bootstrap transaction write temporary: ${entry}"
      return 1
    fi
  done <<< "${entries}"
}

bootstrap_reap_orphaned_work_directories() {
  local dist_root="$1" protected_work_dir="${2:-}"
  local entries entry name candidate version nonce
  if ! entries="$(
    find "${dist_root}" -mindepth 1 -maxdepth 1 \
      -name '.bootstrap-*.*' -print | LC_ALL=C sort
  )"; then
    bootstrap_error "could not enumerate bootstrap work directories."
    return 1
  fi
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    name="${entry##*/}"
    case "${name}" in
      .bootstrap-transaction-*|.bootstrap.lock.owner.*)
        continue
        ;;
    esac
    candidate="${name#.bootstrap-}"
    version="${candidate%.*}"
    nonce="${candidate##*.}"
    if [[ "${version}" == "${candidate}" \
      || ! "${nonce}" =~ ^[[:alnum:]]{6}$ ]] \
      || ! bootstrap_validate_version "${version}"; then
      bootstrap_error "bootstrap work path has ambiguous ownership metadata: ${entry}"
      return 1
    fi
    if [[ -L "${entry}" || ! -d "${entry}" ]]; then
      bootstrap_error "bootstrap work path is not a real directory: ${entry}"
      return 1
    fi
    if [[ -n "${protected_work_dir}" && "${entry}" == "${protected_work_dir}" ]]; then
      continue
    fi
    if ! rm -rf -- "${entry}" \
      || [[ -e "${entry}" || -L "${entry}" ]]; then
      bootstrap_error "could not remove orphaned bootstrap work directory: ${entry}"
      return 1
    fi
  done <<< "${entries}"
}

bootstrap_prepare_clean_plan() {
  local dist_root="$1" current_link="$2"
  local entries entry name version final_dir all_entries found index
  BOOTSTRAP_CLEAN_OWNED_VERSIONS=()
  BOOTSTRAP_CLEAN_OWNED_VERSION_COUNT=0
  bootstrap_prepare_clean_selection "${dist_root}" "${current_link}" || return 1
  bootstrap_reap_transaction_write_temporaries "${dist_root}" || return 1
  bootstrap_reap_orphaned_work_directories \
    "${dist_root}" "${BOOTSTRAP_TMP:-}" || return 1

  if ! entries="$(
    find "${dist_root}" -mindepth 1 -maxdepth 1 \
      -name '.bootstrap-transaction-*' -print | LC_ALL=C sort
  )"; then
    bootstrap_error "could not enumerate bootstrap transaction evidence."
    return 1
  fi
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    name="${entry##*/}"
    version="${name#.bootstrap-transaction-}"
    final_dir="${dist_root}/${version}"
    bootstrap_validate_version "${version}" || continue
    if [[ -L "${entry}" || ! -f "${entry}" ]] \
      || ! bootstrap_transaction_read "${entry}" \
      || [[ "${BOOTSTRAP_TRANSACTION_VERSION}" != "${version}" ]]; then
      bootstrap_error "bootstrap cleanup ownership evidence is invalid: ${entry}"
      return 1
    fi
    if [[ -e "${final_dir}" || -L "${final_dir}" ]]; then
      if [[ -L "${final_dir}" || ! -d "${final_dir}" ]] \
        || ! bootstrap_validate_extracted_payload "${final_dir}" "${version}"; then
        bootstrap_error "bootstrap cleanup payload evidence is invalid: ${final_dir}"
        return 1
      fi
    elif [[ "${BOOTSTRAP_TRANSACTION_PHASE}" != "cleaning" ]]; then
      bootstrap_error "bootstrap cleanup transaction has no owned payload: ${entry}"
      return 1
    fi
    BOOTSTRAP_CLEAN_OWNED_VERSIONS[${BOOTSTRAP_CLEAN_OWNED_VERSION_COUNT}]="${version}"
    BOOTSTRAP_CLEAN_OWNED_VERSION_COUNT=$((BOOTSTRAP_CLEAN_OWNED_VERSION_COUNT + 1))
  done <<< "${entries}"

  if [[ -n "${BOOTSTRAP_CLEAN_SELECTED_VERSION}" ]]; then
    found=0
    index=0
    while [[ "${index}" -lt "${BOOTSTRAP_CLEAN_OWNED_VERSION_COUNT}" ]]; do
      if [[ "${BOOTSTRAP_CLEAN_OWNED_VERSIONS[${index}]}" \
        == "${BOOTSTRAP_CLEAN_SELECTED_VERSION}" ]]; then
        found=1
        break
      fi
      index=$((index + 1))
    done
    if [[ "${found}" != "1" ]]; then
      bootstrap_error \
        "active bootstrap payload has no transaction ownership evidence: ${BOOTSTRAP_CLEAN_SELECTED_VERSION}"
      return 1
    fi
  fi

  if ! all_entries="$(
    find "${dist_root}" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort
  )"; then
    bootstrap_error "could not enumerate distribution entries for cleanup."
    return 1
  fi
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    version="${entry##*/}"
    bootstrap_validate_version "${version}" || continue
    found=0
    index=0
    while [[ "${index}" -lt "${BOOTSTRAP_CLEAN_OWNED_VERSION_COUNT}" ]]; do
      if [[ "${BOOTSTRAP_CLEAN_OWNED_VERSIONS[${index}]}" == "${version}" ]]; then
        found=1
        break
      fi
      index=$((index + 1))
    done
    if [[ "${found}" != "1" ]]; then
      printf 'Preserving unowned distribution directory: %s\n' "${version}"
    fi
  done <<< "${all_entries}"
}

bootstrap_apply_clean_plan() {
  local dist_root="$1" current_link="$2"
  local index=0 version final_dir transaction_file payload_sha256
  if [[ -n "${BOOTSTRAP_CLEAN_SELECTED_VERSION}" ]]; then
    if [[ ! -L "${current_link}" \
      || "$(readlink "${current_link}")" != "${BOOTSTRAP_CLEAN_SELECTED_VERSION}" ]]; then
      bootstrap_error "active payload selection changed during clean; preserving distribution evidence."
      return 1
    fi
    if ! rm -f -- "${current_link}"; then
      bootstrap_error "failed to remove active bootstrap payload selection: ${current_link}"
      return 1
    fi
  fi

  while [[ "${index}" -lt "${BOOTSTRAP_CLEAN_OWNED_VERSION_COUNT}" ]]; do
    version="${BOOTSTRAP_CLEAN_OWNED_VERSIONS[${index}]}"
    final_dir="${dist_root}/${version}"
    transaction_file="${dist_root}/.bootstrap-transaction-${version}"
    if [[ -L "${transaction_file}" || ! -f "${transaction_file}" ]] \
      || ! bootstrap_transaction_read "${transaction_file}" \
      || [[ "${BOOTSTRAP_TRANSACTION_VERSION}" != "${version}" ]]; then
      bootstrap_error "bootstrap cleanup ownership changed before removal: ${transaction_file}"
      return 1
    fi
    if [[ -e "${final_dir}" || -L "${final_dir}" ]]; then
      if [[ -L "${final_dir}" || ! -d "${final_dir}" ]] \
        || ! bootstrap_validate_extracted_payload "${final_dir}" "${version}"; then
        bootstrap_error "bootstrap cleanup payload changed before removal: ${final_dir}"
        return 1
      fi
    elif [[ "${BOOTSTRAP_TRANSACTION_PHASE}" != "cleaning" ]]; then
      bootstrap_error "bootstrap cleanup payload disappeared before removal: ${final_dir}"
      return 1
    fi
    payload_sha256="${BOOTSTRAP_TRANSACTION_SHA256}"
    bootstrap_transaction_write "${transaction_file}" "${dist_root}" \
      "${version}" "${payload_sha256}" "cleaning" || return 1
    if [[ -e "${final_dir}" || -L "${final_dir}" ]] \
      && ! rm -rf -- "${final_dir}"; then
      bootstrap_error "failed to remove transaction-owned payload: ${final_dir}"
      return 1
    fi
    if ! rm -f -- "${transaction_file}"; then
      bootstrap_error "failed to remove bootstrap cleanup transaction: ${transaction_file}"
      return 1
    fi
    index=$((index + 1))
  done
}
