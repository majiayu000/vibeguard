#!/usr/bin/env bash
# Durable terminal cleanup for crash-recoverable setup-lease retirement.

bootstrap_setup_retirement_dead_candidates_clear() {
  local claim_file="$1" candidate suffix claimant_pid claimant_identity
  for candidate in "${claim_file}.candidate."*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    suffix="${candidate#"${claim_file}.candidate."}"
    claimant_pid="${suffix%%.*}"
    suffix="${suffix#*.}"
    claimant_identity="${suffix%.*}"
    [[ "${claimant_pid}" =~ ^[1-9][0-9]*$ ]] || continue
    bootstrap_process_identity_is_strong "${claimant_identity}" || continue
    bootstrap_process_identity_liveness "${claimant_pid}" "${claimant_identity}"
    if [[ "${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}" == "dead" ]]; then
      rm -f -- "${candidate}" || return 1
    fi
  done
}

bootstrap_setup_retirement_terminal_path() {
  printf '%s.%s.terminal\n' "$1" "$2"
}

bootstrap_setup_retirement_terminal_cleanup() {
  local lease_file="$1" owner_pid="$2" lease_nonce="$3" terminal_file="$4"
  local claim_file="${lease_file}.claim" expected_terminal marker phase phase_file
  [[ ! -L "${terminal_file}" && -f "${terminal_file}" ]] || return 1
  bootstrap_setup_retirement_read "${terminal_file}" || return 1
  expected_terminal="$(bootstrap_setup_retirement_terminal_path \
    "${claim_file}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}")"
  [[ "${terminal_file}" == "${expected_terminal}" \
    && "${BOOTSTRAP_RETIRE_OWNER_PID}" == "${owner_pid}" \
    && "${BOOTSTRAP_RETIRE_LEASE_NONCE}" == "${lease_nonce}" ]] || return 1
  bootstrap_setup_retirement_inventory \
    "${lease_file}" "${owner_pid}" "${lease_nonce}" || return 1
  [[ "${BOOTSTRAP_RETIRE_LEASE_PRESENT}" == "0" \
    && "${BOOTSTRAP_RETIRE_EVIDENCE_PRESENT}" == "0" \
    && "${BOOTSTRAP_RETIRE_REAP_PRESENT}" == "0" ]] || return 1
  for marker in "${claim_file}."*; do
    [[ -e "${marker}" || -L "${marker}" ]] || continue
    [[ "${marker}" == "${terminal_file}" \
      || "${marker}" == "${claim_file}.candidate."* \
      || "${marker}" == "${claim_file}.${BOOTSTRAP_RETIRE_CLAIM_NONCE}.evidenced" \
      || "${marker}" == "${claim_file}.${BOOTSTRAP_RETIRE_CLAIM_NONCE}.retire_intent" \
      || "${marker}" == "${claim_file}.${BOOTSTRAP_RETIRE_CLAIM_NONCE}.retired" \
      || "${marker}" == "${claim_file}.${BOOTSTRAP_RETIRE_CLAIM_NONCE}.delete_intent" ]] \
      || return 1
  done
  for phase in delete_intent retired retire_intent evidenced; do
    phase_file="$(bootstrap_setup_retirement_phase_path \
      "${claim_file}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" "${phase}")"
    if [[ -e "${phase_file}" || -L "${phase_file}" ]]; then
      [[ ! -L "${phase_file}" && -f "${phase_file}" \
        && "${phase_file}" -ef "${terminal_file}" ]] || return 1
      rm -f -- "${phase_file}" || return 1
    fi
  done
  if [[ -e "${claim_file}" || -L "${claim_file}" ]]; then
    [[ ! -L "${claim_file}" && -f "${claim_file}" \
      && "${claim_file}" -ef "${terminal_file}" ]] || return 1
    rm -f -- "${claim_file}" || return 1
  fi
  rm -f -- "${terminal_file}"
}

bootstrap_setup_retirement_terminal_adopt() {
  local lease_file="$1" owner_pid="$2" lease_nonce="$3"
  local claim_file="${lease_file}.claim" marker terminal_file="" terminal_count=0
  for marker in "${claim_file}."*.terminal; do
    if [[ -e "${marker}" || -L "${marker}" ]]; then
      terminal_count=$((terminal_count + 1)) terminal_file="${marker}"
    fi
  done
  [[ "${terminal_count}" -eq 1 ]] || return 1
  bootstrap_setup_retirement_terminal_cleanup \
    "${lease_file}" "${owner_pid}" "${lease_nonce}" "${terminal_file}"
}
