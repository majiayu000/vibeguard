#!/usr/bin/env bash
# Crash-recoverable, cooperative retirement of inactive setup leases.

bootstrap_file_inode() {
  local path="$1" output inode
  output="$(LC_ALL=C ls -di -- "${path}" 2>/dev/null)" || return 1
  inode="${output%%[[:space:]]*}"
  [[ "${inode}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${inode}"
}

bootstrap_setup_retirement_read() {
  local claim_file="$1" parsed
  [[ ! -L "${claim_file}" && -f "${claim_file}" ]] || return 1
  parsed="$(awk -F= '
    NR == 1 && $1 == "schema" && $2 == "1" { schema = $2; next }
    NR == 2 && $1 == "lease_owner_pid" && $2 ~ /^[1-9][0-9]*$/ { owner = $2; next }
    NR == 3 && $1 == "lease_nonce" && $2 ~ /^[A-Za-z0-9._-]+$/ { lease_nonce = $2; next }
    NR == 4 && $1 == "lease_inode" && $2 ~ /^[0-9]+$/ { inode = $2; next }
    NR == 5 && $1 == "claimant_pid" && $2 ~ /^[1-9][0-9]*$/ { claimant = $2; next }
    NR == 6 && $1 == "claimant_identity" && $2 ~ /^[A-Za-z0-9_:.-]+$/ { identity = $2; next }
    NR == 7 && $1 == "claim_nonce" && $2 ~ /^[A-Za-z0-9]+$/ { claim_nonce = $2; next }
    NR == 8 && $1 == "evidence_name" && $2 ~ /^[A-Za-z0-9._-]+$/ { evidence = $2; next }
    NR == 9 && $1 == "reap_name" && $2 ~ /^[A-Za-z0-9._-]+$/ { reap = $2; next }
    { bad = 1 }
    END {
      if (!bad && NR == 9 && schema == 1 && owner != "" && lease_nonce != "" &&
          inode != "" && claimant != "" && identity != "" && claim_nonce != "" &&
          evidence != "" && reap != "") {
        print owner "|" lease_nonce "|" inode "|" claimant "|" identity "|" \
          claim_nonce "|" evidence "|" reap
      } else exit 1
    }
  ' "${claim_file}")" || return 1
  IFS='|' read -r BOOTSTRAP_RETIRE_OWNER_PID BOOTSTRAP_RETIRE_LEASE_NONCE \
    BOOTSTRAP_RETIRE_INODE BOOTSTRAP_RETIRE_CLAIMANT_PID \
    BOOTSTRAP_RETIRE_CLAIMANT_IDENTITY BOOTSTRAP_RETIRE_CLAIM_NONCE \
    BOOTSTRAP_RETIRE_EVIDENCE_NAME BOOTSTRAP_RETIRE_REAP_NAME <<< "${parsed}"
}

bootstrap_setup_retirement_phase_path() {
  printf '%s.%s.%s\n' "$1" "$2" "$3"
}

bootstrap_setup_retirement_phase_publish() {
  local claim_file="$1" claim_nonce="$2" phase="$3" phase_file
  phase_file="$(bootstrap_setup_retirement_phase_path \
    "${claim_file}" "${claim_nonce}" "${phase}")"
  if [[ -e "${phase_file}" || -L "${phase_file}" ]]; then
    [[ ! -L "${phase_file}" && -f "${phase_file}" \
      && "${phase_file}" -ef "${claim_file}" ]]
    return
  fi
  bootstrap_hard_link_no_follow "${claim_file}" "${phase_file}" || {
    [[ ! -L "${phase_file}" && -f "${phase_file}" \
      && "${phase_file}" -ef "${claim_file}" ]]
  }
}

bootstrap_setup_retirement_phase_read() {
  local claim_file="$1" claim_nonce="$2" phase phase_file seen_gap=0
  BOOTSTRAP_RETIRE_PHASE="claimed"
  for phase in evidenced retire_intent retired delete_intent; do
    phase_file="$(bootstrap_setup_retirement_phase_path \
      "${claim_file}" "${claim_nonce}" "${phase}")"
    if [[ -e "${phase_file}" || -L "${phase_file}" ]]; then
      [[ "${seen_gap}" == "0" && ! -L "${phase_file}" \
        && -f "${phase_file}" && "${phase_file}" -ef "${claim_file}" ]] \
        || return 1
      BOOTSTRAP_RETIRE_PHASE="${phase}"
    else
      seen_gap=1
    fi
  done
}

bootstrap_setup_retirement_claim_create() {
  local lease_file="$1" owner_pid="$2" lease_nonce="$3"
  local evidence_path="${4:-}" reap_path="${5:-}" initial_phase="${6:-claimed}"
  local claim_file="${lease_file}.claim" candidate claim_nonce inode claimant_identity
  local evidence_name reap_name
  bootstrap_setup_retirement_dead_candidates_clear "${claim_file}" || return 1
  if [[ -e "${claim_file}" || -L "${claim_file}" ]]; then return 0; fi
  if [[ -e "${lease_file}" && ! -L "${lease_file}" ]]; then
    inode="$(bootstrap_file_inode "${lease_file}")" || return 1
  elif [[ -n "${evidence_path}" && -e "${evidence_path}" && ! -L "${evidence_path}" ]]; then
    inode="$(bootstrap_file_inode "${evidence_path}")" || return 1
  else
    return 1
  fi
  bootstrap_process_snapshot $$ || return 1
  [[ "${BOOTSTRAP_PROCESS_IDENTITY_STRENGTH}" == "strong" \
    && "${BOOTSTRAP_PROCESS_STATE}" != Z* ]] || return 1
  claimant_identity="${BOOTSTRAP_PROCESS_IDENTITY}"
  candidate="$(mktemp "${claim_file}.candidate.$$.${claimant_identity}.XXXXXXXXXXXX")" \
    || return 1
  claim_nonce="${candidate##*.}"
  [[ "${claim_nonce}" =~ ^[A-Za-z0-9]+$ ]] || { rm -f -- "${candidate}"; return 1; }
  [[ -n "${evidence_path}" ]] \
    && evidence_name="${evidence_path##*/}" \
    || evidence_name="${lease_file##*/}.evidence.${claim_nonce}"
  [[ -n "${reap_path}" ]] \
    && reap_name="${reap_path##*/}" \
    || reap_name="${lease_file##*/}.reap.${claim_nonce}"
  printf 'schema=1\nlease_owner_pid=%s\nlease_nonce=%s\nlease_inode=%s\nclaimant_pid=%s\nclaimant_identity=%s\nclaim_nonce=%s\nevidence_name=%s\nreap_name=%s\n' \
    "${owner_pid}" "${lease_nonce}" "${inode}" "$$" "${claimant_identity}" \
    "${claim_nonce}" "${evidence_name}" "${reap_name}" > "${candidate}" || {
      rm -f -- "${candidate}"; return 1; }
  if ! bootstrap_hard_link_no_follow "${candidate}" "${claim_file}"; then
    rm -f -- "${candidate}"
    [[ ! -L "${claim_file}" && -f "${claim_file}" ]] || return 1
    return 0
  fi
  [[ ! -L "${claim_file}" && -f "${claim_file}" \
    && "${claim_file}" -ef "${candidate}" ]] || return 1
  rm -f -- "${candidate}" || return 1
  BOOTSTRAP_RETIRE_LOCAL_CLAIM_NONCE="${claim_nonce}"
  BOOTSTRAP_RETIRE_LOCAL_CLAIMANT_PID="$$"
  BOOTSTRAP_RETIRE_LOCAL_CLAIMANT_IDENTITY="${claimant_identity}"
  case "${initial_phase}" in
    claimed) ;;
    evidenced)
      bootstrap_setup_retirement_phase_publish \
        "${claim_file}" "${claim_nonce}" evidenced || return 1 ;;
    retired)
      for _retire_phase in evidenced retire_intent retired; do
        bootstrap_setup_retirement_phase_publish \
          "${claim_file}" "${claim_nonce}" "${_retire_phase}" || return 1
      done ;;
    retire_intent)
      for _retire_phase in evidenced retire_intent; do
        bootstrap_setup_retirement_phase_publish \
          "${claim_file}" "${claim_nonce}" "${_retire_phase}" || return 1
      done ;;
    *) return 1 ;;
  esac
}

bootstrap_setup_retirement_object_validate() {
  local path="$1" owner_pid="$2" lease_nonce="$3" inode
  [[ ! -L "${path}" && -f "${path}" ]] || return 1
  inode="$(bootstrap_file_inode "${path}")" || return 1
  [[ "${inode}" == "${BOOTSTRAP_RETIRE_INODE}" ]] || return 1
  bootstrap_setup_lease_read "${path}" || return 1
  [[ "${BOOTSTRAP_LEASE_OWNER_PID}" == "${owner_pid}" \
    && "${BOOTSTRAP_LEASE_NONCE}" == "${lease_nonce}" ]]
}

bootstrap_setup_retirement_inventory() {
  local lease_file="$1" owner_pid="$2" lease_nonce="$3"
  local directory="${lease_file%/*}" marker evidence_path reap_path
  evidence_path="${directory}/${BOOTSTRAP_RETIRE_EVIDENCE_NAME}"
  reap_path="${directory}/${BOOTSTRAP_RETIRE_REAP_NAME}"
  BOOTSTRAP_RETIRE_LEASE_PRESENT=0 BOOTSTRAP_RETIRE_EVIDENCE_PRESENT=0
  BOOTSTRAP_RETIRE_REAP_PRESENT=0
  for marker in "${lease_file}.evidence."* "${lease_file}.reap."*; do
    if [[ -e "${marker}" || -L "${marker}" ]]; then
      [[ "${marker}" == "${evidence_path}" || "${marker}" == "${reap_path}" ]] || return 1
    fi
  done
  if [[ -e "${lease_file}" || -L "${lease_file}" ]]; then
    bootstrap_setup_retirement_object_validate \
      "${lease_file}" "${owner_pid}" "${lease_nonce}" || return 1
    BOOTSTRAP_RETIRE_LEASE_PRESENT=1
  fi
  if [[ -e "${evidence_path}" || -L "${evidence_path}" ]]; then
    bootstrap_setup_retirement_object_validate \
      "${evidence_path}" "${owner_pid}" "${lease_nonce}" || return 1
    BOOTSTRAP_RETIRE_EVIDENCE_PRESENT=1
  fi
  if [[ -e "${reap_path}" || -L "${reap_path}" ]]; then
    bootstrap_setup_retirement_object_validate \
      "${reap_path}" "${owner_pid}" "${lease_nonce}" || return 1
    BOOTSTRAP_RETIRE_REAP_PRESENT=1
  fi
}

bootstrap_setup_retirement_claim_liveness() {
  BOOTSTRAP_RETIRE_CLAIMANT_LIVENESS="ambiguous"
  if [[ "${BOOTSTRAP_RETIRE_LOCAL_CLAIM_NONCE:-}" == "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" \
    && "${BOOTSTRAP_RETIRE_LOCAL_CLAIMANT_PID:-}" == "${BOOTSTRAP_RETIRE_CLAIMANT_PID}" \
    && "${BOOTSTRAP_RETIRE_LOCAL_CLAIMANT_IDENTITY:-}" == "${BOOTSTRAP_RETIRE_CLAIMANT_IDENTITY}" ]]; then
    BOOTSTRAP_RETIRE_CLAIMANT_LIVENESS="self"
    return 0
  fi
  bootstrap_process_identity_liveness \
    "${BOOTSTRAP_RETIRE_CLAIMANT_PID}" "${BOOTSTRAP_RETIRE_CLAIMANT_IDENTITY}"
  if [[ "${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}" == "active" ]]; then
    [[ "${BOOTSTRAP_RETIRE_CLAIMANT_PID}" == "$$" ]] \
      && BOOTSTRAP_RETIRE_CLAIMANT_LIVENESS="self" \
      || BOOTSTRAP_RETIRE_CLAIMANT_LIVENESS="active"
  else
    BOOTSTRAP_RETIRE_CLAIMANT_LIVENESS="${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}"
  fi
}

bootstrap_setup_retirement_legacy_adopt() {
  local lease_file="$1" owner_pid="$2" lease_nonce="$3"
  local marker evidence_path="" reap_path="" evidence_count=0 reap_count=0
  for marker in "${lease_file}.evidence."*; do
    if [[ -e "${marker}" || -L "${marker}" ]]; then
      evidence_count=$((evidence_count + 1)) evidence_path="${marker}"
    fi
  done
  for marker in "${lease_file}.reap."*; do
    if [[ -e "${marker}" || -L "${marker}" ]]; then
      reap_count=$((reap_count + 1)) reap_path="${marker}"
    fi
  done
  [[ "${evidence_count}" -eq 1 && ! -L "${evidence_path}" ]] || return 1
  if [[ -f "${lease_file}" && ! -L "${lease_file}" \
    && "${reap_count}" -eq 0 && "${lease_file}" -ef "${evidence_path}" ]]; then
    bootstrap_setup_retirement_claim_create \
      "${lease_file}" "${owner_pid}" "${lease_nonce}" \
      "${evidence_path}" "" evidenced
  elif [[ ! -e "${lease_file}" && ! -L "${lease_file}" \
    && "${reap_count}" -eq 1 && ! -L "${reap_path}" \
    && "${evidence_path}" -ef "${reap_path}" ]]; then
    bootstrap_setup_retirement_claim_create \
      "${lease_file}" "${owner_pid}" "${lease_nonce}" \
      "${evidence_path}" "${reap_path}" retired
  elif [[ ! -e "${lease_file}" && ! -L "${lease_file}" \
    && "${reap_count}" -eq 0 ]]; then
    bootstrap_setup_lease_liveness "${evidence_path}" "${owner_pid}" "${lease_nonce}"
    [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" == "dead" ]] || return 1
    bootstrap_setup_retirement_claim_create \
      "${lease_file}" "${owner_pid}" "${lease_nonce}" \
      "${evidence_path}" "" retire_intent
  else
    return 1
  fi
}

bootstrap_setup_retirement_help() {
  local lease_file="$1" owner_pid="$2" lease_nonce="$3"
  local claim_file="${lease_file}.claim" directory="${lease_file%/*}"
  local evidence_path reap_path terminal_file
  bootstrap_setup_retirement_read "${claim_file}" || return 1
  [[ "${BOOTSTRAP_RETIRE_OWNER_PID}" == "${owner_pid}" \
    && "${BOOTSTRAP_RETIRE_LEASE_NONCE}" == "${lease_nonce}" \
    && "${BOOTSTRAP_RETIRE_EVIDENCE_NAME}" == "${lease_file##*/}.evidence."* \
    && "${BOOTSTRAP_RETIRE_REAP_NAME}" == "${lease_file##*/}.reap."* ]] || return 1
  bootstrap_process_identity_is_strong "${BOOTSTRAP_RETIRE_CLAIMANT_IDENTITY}" || return 1
  bootstrap_setup_retirement_claim_liveness
  [[ "${BOOTSTRAP_RETIRE_CLAIMANT_LIVENESS}" == "self" \
    || "${BOOTSTRAP_RETIRE_CLAIMANT_LIVENESS}" == "dead" ]] || return 1
  evidence_path="${directory}/${BOOTSTRAP_RETIRE_EVIDENCE_NAME}"
  reap_path="${directory}/${BOOTSTRAP_RETIRE_REAP_NAME}"
  bootstrap_setup_retirement_phase_read \
    "${claim_file}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" || return 1
  bootstrap_setup_retirement_inventory \
    "${lease_file}" "${owner_pid}" "${lease_nonce}" || return 1

  terminal_file="$(bootstrap_setup_retirement_terminal_path \
    "${claim_file}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}")"
  if [[ -e "${terminal_file}" || -L "${terminal_file}" ]] \
    || [[ "${BOOTSTRAP_RETIRE_LEASE_PRESENT}" == "0" \
      && "${BOOTSTRAP_RETIRE_EVIDENCE_PRESENT}" == "0" \
      && "${BOOTSTRAP_RETIRE_REAP_PRESENT}" == "0" ]]; then
    if [[ ! -e "${terminal_file}" && ! -L "${terminal_file}" ]]; then
      bootstrap_hard_link_no_follow "${claim_file}" "${terminal_file}" || return 1
    fi
    bootstrap_setup_retirement_terminal_cleanup \
      "${lease_file}" "${owner_pid}" "${lease_nonce}" "${terminal_file}"
    return
  fi

  if [[ "${BOOTSTRAP_RETIRE_PHASE}" == "claimed" ]]; then
    [[ "${BOOTSTRAP_RETIRE_LEASE_PRESENT}" == "1" \
      && "${BOOTSTRAP_RETIRE_REAP_PRESENT}" == "0" ]] || return 1
    if [[ "${BOOTSTRAP_RETIRE_EVIDENCE_PRESENT}" == "0" ]]; then
      bootstrap_hard_link_no_follow "${lease_file}" "${evidence_path}" || true
      bootstrap_setup_retirement_inventory \
        "${lease_file}" "${owner_pid}" "${lease_nonce}" || return 1
    fi
    [[ "${BOOTSTRAP_RETIRE_EVIDENCE_PRESENT}" == "1" \
      && "${lease_file}" -ef "${evidence_path}" ]] || return 1
    bootstrap_setup_retirement_phase_publish \
      "${claim_file}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" evidenced || return 1
    BOOTSTRAP_RETIRE_PHASE="evidenced"
  fi

  if [[ "${BOOTSTRAP_RETIRE_PHASE}" == "evidenced" ]]; then
    [[ "${BOOTSTRAP_RETIRE_LEASE_PRESENT}" == "1" \
      && "${BOOTSTRAP_RETIRE_EVIDENCE_PRESENT}" == "1" \
      && "${BOOTSTRAP_RETIRE_REAP_PRESENT}" == "0" ]] || return 1
    bootstrap_setup_lease_liveness "${evidence_path}" "${owner_pid}" "${lease_nonce}"
    [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" == "dead" ]] || return 1
    bootstrap_setup_retirement_phase_publish \
      "${claim_file}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" retire_intent || return 1
    BOOTSTRAP_RETIRE_PHASE="retire_intent"
  fi

  if [[ "${BOOTSTRAP_RETIRE_PHASE}" == "retire_intent" ]]; then
    [[ "${BOOTSTRAP_RETIRE_EVIDENCE_PRESENT}" == "1" ]] || return 1
    bootstrap_setup_lease_liveness "${evidence_path}" "${owner_pid}" "${lease_nonce}"
    [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" == "dead" ]] || return 1
    if [[ "${BOOTSTRAP_RETIRE_REAP_PRESENT}" == "0" ]]; then
      if [[ "${BOOTSTRAP_RETIRE_LEASE_PRESENT}" == "1" ]]; then
        bootstrap_hard_link_no_follow "${lease_file}" "${reap_path}" || true
      else
        bootstrap_hard_link_no_follow "${evidence_path}" "${reap_path}" || true
      fi
      bootstrap_setup_retirement_inventory \
        "${lease_file}" "${owner_pid}" "${lease_nonce}" || return 1
    fi
    [[ "${BOOTSTRAP_RETIRE_EVIDENCE_PRESENT}" == "1" \
      && "${BOOTSTRAP_RETIRE_REAP_PRESENT}" == "1" \
      && "${evidence_path}" -ef "${reap_path}" ]] || return 1
    if [[ "${BOOTSTRAP_RETIRE_LEASE_PRESENT}" == "1" ]]; then
      [[ "${lease_file}" -ef "${evidence_path}" ]] || return 1
      bootstrap_setup_lease_liveness "${evidence_path}" "${owner_pid}" "${lease_nonce}"
      [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" == "dead" ]] || return 1
      rm -- "${lease_file}" || return 1
      bootstrap_setup_retirement_inventory \
        "${lease_file}" "${owner_pid}" "${lease_nonce}" || return 1
    fi
    [[ "${BOOTSTRAP_RETIRE_LEASE_PRESENT}" == "0" \
      && "${BOOTSTRAP_RETIRE_EVIDENCE_PRESENT}" == "1" \
      && "${BOOTSTRAP_RETIRE_REAP_PRESENT}" == "1" \
      && "${evidence_path}" -ef "${reap_path}" ]] || return 1
    bootstrap_setup_retirement_phase_publish \
      "${claim_file}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" retired || return 1
    BOOTSTRAP_RETIRE_PHASE="retired"
  fi

  if [[ "${BOOTSTRAP_RETIRE_PHASE}" == "retired" ]]; then
    [[ "${BOOTSTRAP_RETIRE_LEASE_PRESENT}" == "0" \
      && "${BOOTSTRAP_RETIRE_EVIDENCE_PRESENT}" == "1" \
      && "${BOOTSTRAP_RETIRE_REAP_PRESENT}" == "1" ]] || return 1
    bootstrap_setup_retirement_phase_publish \
      "${claim_file}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" delete_intent || return 1
    BOOTSTRAP_RETIRE_PHASE="delete_intent"
  fi

  if [[ "${BOOTSTRAP_RETIRE_PHASE}" == "delete_intent" ]]; then
    rm -f -- "${reap_path}" || return 1
    rm -f -- "${evidence_path}" || return 1
    bootstrap_setup_retirement_inventory \
      "${lease_file}" "${owner_pid}" "${lease_nonce}" || return 1
    [[ "${BOOTSTRAP_RETIRE_LEASE_PRESENT}" == "0" \
      && "${BOOTSTRAP_RETIRE_EVIDENCE_PRESENT}" == "0" \
      && "${BOOTSTRAP_RETIRE_REAP_PRESENT}" == "0" ]] || return 1
    bootstrap_hard_link_no_follow "${claim_file}" "${terminal_file}" || return 1
    bootstrap_setup_retirement_terminal_cleanup \
      "${lease_file}" "${owner_pid}" "${lease_nonce}" "${terminal_file}"
  fi
}

bootstrap_setup_lease_retire_inactive() {
  local lease_file="$1" owner_pid="$2" lease_nonce="$3" claim_file="${1}.claim"
  local marker_present=0 marker
  if [[ ! -e "${claim_file}" && ! -L "${claim_file}" ]]; then
    for marker in "${claim_file}."*.terminal; do
      if [[ -e "${marker}" || -L "${marker}" ]]; then
        bootstrap_setup_retirement_terminal_adopt \
          "${lease_file}" "${owner_pid}" "${lease_nonce}"
        return
      fi
    done
    for marker in "${lease_file}.evidence."* "${lease_file}.reap."*; do
      [[ -e "${marker}" || -L "${marker}" ]] && marker_present=1
    done
    if [[ "${marker_present}" == "1" ]]; then
      bootstrap_setup_retirement_legacy_adopt \
        "${lease_file}" "${owner_pid}" "${lease_nonce}" || {
          bootstrap_error "legacy setup lease retirement evidence is incomplete; manual recovery is required."
          return 1
        }
    elif [[ ! -e "${lease_file}" && ! -L "${lease_file}" ]]; then
      return 0
    else
      bootstrap_setup_lease_liveness "${lease_file}" "${owner_pid}" "${lease_nonce}"
      if [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" != "dead" ]]; then
        if [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" != "active" ]] \
          || ! bootstrap_setup_stopped_group_recover \
            "${lease_file}" "${owner_pid}" "${lease_nonce}"; then
          bootstrap_error "setup process group is ${BOOTSTRAP_SETUP_LEASE_LIVENESS}; preserving its lock and worktree."
          return 1
        fi
        bootstrap_setup_lease_liveness "${lease_file}" "${owner_pid}" "${lease_nonce}"
      fi
      [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" == "dead" ]] || return 1
      bootstrap_setup_retirement_claim_create \
        "${lease_file}" "${owner_pid}" "${lease_nonce}" || return 1
    fi
  fi
  bootstrap_setup_retirement_help "${lease_file}" "${owner_pid}" "${lease_nonce}"
}
