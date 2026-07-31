#!/usr/bin/env bash
# Bootstrap payload integrity comparison and transaction-owned cleanup helpers.
bootstrap_process_snapshot() {
  local expected_pid="$1" snapshot parsed
  BOOTSTRAP_PROCESS_PGID="" BOOTSTRAP_PROCESS_IDENTITY=""
  snapshot="$(LC_ALL=C ps -p "${expected_pid}" -o pid= -o pgid= -o lstart= 2>/dev/null)" || return 1
  parsed="$(awk -v expected="${expected_pid}" '
    NF == 7 && $1 == expected && $1 ~ /^[1-9][0-9]*$/ && $2 ~ /^[1-9][0-9]*$/ {
      if ($3 !~ /^[A-Z][a-z][a-z]$/ || $4 !~ /^[A-Z][a-z][a-z]$/ ||
          $5 !~ /^[0-9][0-9]?$/ || $6 !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ ||
          $7 !~ /^[0-9][0-9][0-9][0-9]$/) bad = 1
      count += 1
      pgid = $2
      identity = $3 "_" $4 "_" $5 "_" $6 "_" $7
      next
    }
    NF { bad = 1 }
    END {
      if (!bad && count == 1) print pgid "\t" identity
      else exit 1
    }
  ' <<< "${snapshot}")" || return 1
  IFS=$'\t' read -r BOOTSTRAP_PROCESS_PGID BOOTSTRAP_PROCESS_IDENTITY <<< "${parsed}"
}
bootstrap_process_group_liveness() {
  local expected_pgid="$1" table state
  BOOTSTRAP_PROCESS_GROUP_LIVENESS="ambiguous"
  table="$(LC_ALL=C ps -A -o pid= -o pgid= 2>/dev/null)" || return 0
  if state="$(awk -v expected="${expected_pgid}" '
    NF != 2 || $1 !~ /^[1-9][0-9]*$/ || $2 !~ /^[1-9][0-9]*$/ { bad = 1; next }
    seen[$1]++ { bad = 1 }
    $2 == expected { found = 1 }
    { count += 1 }
    END {
      if (bad || count == 0) exit 1
      print found ? "active" : "dead"
    }
  ' <<< "${table}")"; then
    BOOTSTRAP_PROCESS_GROUP_LIVENESS="${state}"
  fi
}
bootstrap_setup_lease_read() {
  local lease_file="$1" parsed
  [[ ! -L "${lease_file}" && -f "${lease_file}" ]] || {
    bootstrap_error "setup lease must be a regular file: ${lease_file}"; return 1; }
  parsed="$(awk -F= '
    NR == 1 && $1 == "schema" && $2 == "1" { schema = $2; next }
    NR == 2 && $1 == "owner_pid" && $2 ~ /^[1-9][0-9]*$/ { owner = $2; next }
    NR == 3 && $1 == "nonce" && $2 ~ /^[A-Za-z0-9._-]+$/ { nonce = $2; next }
    NR == 4 && $1 == "state" && ($2 == "pending" || $2 == "active") { state = $2; next }
    NR == 5 && state == "active" && $1 == "leader_pid" && $2 ~ /^[1-9][0-9]*$/ { leader = $2; next }
    NR == 6 && state == "active" && $1 == "process_group" && $2 ~ /^[1-9][0-9]*$/ { pgid = $2; next }
    NR == 7 && state == "active" && $1 == "leader_identity" && $2 ~ /^[A-Za-z0-9_:.-]+$/ { identity = $2; next }
    { bad = 1 }
    END {
      if (!bad && schema == 1 && owner != "" && nonce != "" &&
          ((state == "pending" && NR == 4) ||
           (state == "active" && NR == 7 && leader != "" && pgid != "" && identity != ""))) {
        print owner "\t" nonce "\t" state "\t" leader "\t" pgid "\t" identity
      } else exit 1
    }
  ' "${lease_file}")" || {
    bootstrap_error "setup lease metadata is malformed: ${lease_file}"; return 1; }
  IFS=$'\t' read -r BOOTSTRAP_LEASE_OWNER_PID BOOTSTRAP_LEASE_NONCE \
    BOOTSTRAP_LEASE_STATE BOOTSTRAP_LEASE_LEADER_PID BOOTSTRAP_LEASE_PGID \
    BOOTSTRAP_LEASE_LEADER_IDENTITY <<< "${parsed}"
}
bootstrap_setup_lease_write() {
  local lease_file="$1" owner_pid="$2" nonce="$3" state="$4"
  local leader_pid="${5:-}" pgid="${6:-}" identity="${7:-}" temporary="${lease_file}.write.$$.$RANDOM"
  [[ ! -e "${temporary}" && ! -L "${temporary}" ]] || return 1
  if [[ "${state}" == "pending" ]]; then
    [[ ! -e "${lease_file}" && ! -L "${lease_file}" ]] || return 1
    printf 'schema=1\nowner_pid=%s\nnonce=%s\nstate=pending\n' \
      "${owner_pid}" "${nonce}" > "${temporary}" || return 1
  elif [[ "${state}" == "active" ]]; then
    printf 'schema=1\nowner_pid=%s\nnonce=%s\nstate=active\nleader_pid=%s\nprocess_group=%s\nleader_identity=%s\n' \
      "${owner_pid}" "${nonce}" "${leader_pid}" "${pgid}" "${identity}" \
      > "${temporary}" || return 1
  else return 1
  fi
  if ! mv -f -- "${temporary}" "${lease_file}"; then
    rm -f -- "${temporary}"; return 1
  fi
}
bootstrap_setup_lease_liveness() {
  local lease_file="$1" owner_pid="$2" nonce="$3"; BOOTSTRAP_SETUP_LEASE_LIVENESS="ambiguous"
  bootstrap_setup_lease_read "${lease_file}" || return 0
  [[ "${BOOTSTRAP_LEASE_OWNER_PID}" == "${owner_pid}" && "${BOOTSTRAP_LEASE_NONCE}" == "${nonce}" ]] || return 0
  [[ "${BOOTSTRAP_LEASE_STATE}" == "active" ]] || { BOOTSTRAP_SETUP_LEASE_LIVENESS="dead"; return 0; }
  bootstrap_process_group_liveness "${BOOTSTRAP_LEASE_PGID}"
  [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" == "dead" ]] && { BOOTSTRAP_SETUP_LEASE_LIVENESS="dead"; return 0; }
  [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" == "active" ]] \
    && bootstrap_process_snapshot "${BOOTSTRAP_LEASE_LEADER_PID}" \
    && [[ "${BOOTSTRAP_PROCESS_PGID}" == "${BOOTSTRAP_LEASE_PGID}" ]] \
    && [[ "${BOOTSTRAP_PROCESS_IDENTITY}" == "${BOOTSTRAP_LEASE_LEADER_IDENTITY}" ]] \
    && BOOTSTRAP_SETUP_LEASE_LIVENESS="active"; return 0
}
bootstrap_setup_lease_clear_inactive() {
  local lease_file="$1" owner_pid="$2" nonce="$3" claimed="${1}.reap.$$.$RANDOM"
  [[ ! -e "${lease_file}" && ! -L "${lease_file}" ]] && return 0; bootstrap_setup_lease_liveness "${lease_file}" "${owner_pid}" "${nonce}"
  if [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" != "dead" ]]; then
    bootstrap_error "setup process group is ${BOOTSTRAP_SETUP_LEASE_LIVENESS}; preserving its lock and worktree."
    return 1
  fi
  if [[ -e "${claimed}" || -L "${claimed}" ]] || ! mv -- "${lease_file}" "${claimed}"; then
    bootstrap_error "could not claim inactive setup lease: ${lease_file}"
    return 1
  fi
  bootstrap_setup_lease_liveness "${claimed}" "${owner_pid}" "${nonce}"
  if [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" != "dead" ]]; then
    bootstrap_error "setup process group changed during lease claim; preserving its lock and worktree."
    if [[ ! -e "${lease_file}" && ! -L "${lease_file}" ]]; then
      mv -- "${claimed}" "${lease_file}" || \
        bootstrap_error "could not restore setup lease after liveness verification: ${claimed}"
    fi
    return 1
  fi
  rm -f -- "${claimed}" || return 1
}
bootstrap_run_setup_with_lease() {
  local setup_path="$1" dist_root="$2" owner_pid="$3" nonce="$4"; shift 4
  local lease_file="${dist_root}/.bootstrap.lock.lease.${nonce}"
  local gate_file="${BOOTSTRAP_TMP}/setup-lease-start" leader_pid setup_rc=0 monitor_enabled=0
  bootstrap_setup_lease_write "${lease_file}" "${owner_pid}" "${nonce}" pending || return 1
  BOOTSTRAP_SETUP_LEASE_FILE="${lease_file}" BOOTSTRAP_SETUP_LEASE_HELD=1
  [[ $- == *m* ]] && monitor_enabled=1; set -m
  (
    while [[ ! -f "${gate_file}" ]]; do
      kill -0 "${owner_pid}" 2>/dev/null || exit 125
      sleep 0.02
    done
    PYTHONDONTWRITEBYTECODE=1 bash "${setup_path}" "$@"
  ) &
  leader_pid=$!; [[ "${monitor_enabled}" == "1" ]] || set +m
  if ! bootstrap_process_snapshot "${leader_pid}" \
    || [[ "${BOOTSTRAP_PROCESS_PGID}" != "${leader_pid}" ]]; then
    kill "${leader_pid}" 2>/dev/null || true
    wait "${leader_pid}" 2>/dev/null || true
    bootstrap_error "could not establish an isolated setup process group."; return 1
  fi
  if ! bootstrap_setup_lease_write "${lease_file}" "${owner_pid}" "${nonce}" active \
      "${leader_pid}" "${BOOTSTRAP_PROCESS_PGID}" "${BOOTSTRAP_PROCESS_IDENTITY}" \
    || ! : > "${gate_file}"; then
    bootstrap_error "could not publish the setup process-group gate."; \
      kill -TERM -- "-${leader_pid}" 2>/dev/null || kill "${leader_pid}" 2>/dev/null || true
    wait "${leader_pid}" 2>/dev/null || true
    if bootstrap_setup_lease_clear_inactive "${lease_file}" "${owner_pid}" "${nonce}"; then
      BOOTSTRAP_SETUP_LEASE_HELD=0 BOOTSTRAP_SETUP_LEASE_FILE=""
    fi
    return 1
  fi
  wait "${leader_pid}" || setup_rc=$?
  bootstrap_setup_lease_clear_inactive "${lease_file}" "${owner_pid}" "${nonce}" || return 73
  BOOTSTRAP_SETUP_LEASE_HELD=0 BOOTSTRAP_SETUP_LEASE_FILE=""
  return "${setup_rc}"
}
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
