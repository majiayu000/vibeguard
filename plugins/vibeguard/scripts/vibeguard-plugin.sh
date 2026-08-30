#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

print_usage() {
  cat <<'USAGE'
Usage: bash scripts/vibeguard-plugin.sh <command> [setup-options]

Commands:
  repo-dir         Print the resolved VibeGuard checkout path
  dashboard        Generate a local HTML observability dashboard
  health           Run the hook health snapshot
  stats            Run hook trigger statistics
  doctor           Run the Codex install + hook capability doctor
  metrics-export   Export Prometheus-format local metrics
  open-site        Open or print the VibeGuard product site path
  install          Run setup.sh with the provided install options
  check            Run setup.sh --check with the provided check options
  clean            Run setup.sh --clean with the provided clean options
  codex-status     Run setup.sh --codex-status with the provided status options
  help             Show this help

Set VIBEGUARD_REPO_DIR=/path/to/vibeguard when the plugin is installed from a
cache that is not nested under a VibeGuard repository checkout.
USAGE
}

html_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&#39;/g"
}

strip_ansi() {
  perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g'
}

render_dashboard_template() {
  local template_path="$1"
  local output_path="$2"
  shift 2

  if [[ ! -r "${template_path}" ]]; then
    printf 'ERROR: dashboard template is not readable: %s\n' "${template_path}" >&2
    return 1
  fi
  if (( $# % 2 != 0 )); then
    printf 'ERROR: dashboard template replacements must be key/value pairs\n' >&2
    return 1
  fi

  local key value key_list=""
  local -a replacement_env=()
  while [[ $# -gt 0 ]]; do
    key="$1"
    value="$2"
    shift 2
    key_list="${key_list}${key_list:+ }${key}"
    replacement_env+=("DASHBOARD_REPLACE_${key}=${value}")
  done

  local temp_output
  if ! temp_output="$(mktemp "${output_path}.tmp.XXXXXX")"; then
    printf 'ERROR: could not create temporary dashboard beside: %s\n' "${output_path}" >&2
    return 1
  fi
  if ! env "${replacement_env[@]}" awk -v key_list="${key_list}" '
    BEGIN {
      key_count = split(key_list, keys, " ")
      failed = 0
    }
    {
      source = $0
      rendered = ""
      while (length(source) > 0) {
        unknown_at = index(source, "{{")
        best_at = 0
        best_key = ""
        best_token = ""
        for (index_key = 1; index_key <= key_count; index_key++) {
          token = "{{" keys[index_key] "}}"
          token_at = index(source, token)
          if (token_at > 0 && (best_at == 0 || token_at < best_at)) {
            best_at = token_at
            best_key = keys[index_key]
            best_token = token
          }
        }
        if (unknown_at > 0 && (best_at == 0 || unknown_at < best_at)) {
          failed = 1
          next
        }
        if (best_at == 0) {
          rendered = rendered source
          source = ""
        } else {
          rendered = rendered substr(source, 1, best_at - 1) ENVIRON["DASHBOARD_REPLACE_" best_key]
          source = substr(source, best_at + length(best_token))
        }
      }
      if (!failed) {
        print rendered
      }
    }
    END {
      if (failed) {
        print "ERROR: dashboard template contains an unknown placeholder" > "/dev/stderr"
        exit 1
      }
    }
  ' "${template_path}" > "${temp_output}"; then
    rm -f "${temp_output}"
    printf 'ERROR: could not write dashboard: %s\n' "${output_path}" >&2
    return 1
  fi
  if ! mv -f "${temp_output}" "${output_path}"; then
    rm -f "${temp_output}"
    printf 'ERROR: could not install generated dashboard: %s\n' "${output_path}" >&2
    return 1
  fi
}

dashboard_json_field() {
  local runtime="$1"
  local payload="$2"
  local field="$3"
  printf '%s\n' "${payload}" | "${runtime}" json-field --strict "${field}" 2>/dev/null
}

dashboard_count_value() {
  local value
  value="$(dashboard_json_field "$1" "$2" "$3")" || return 1
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${value}"
}

dashboard_count_text() {
  local value="$1"
  local state="$2"
  if [[ "${state}" == "missing" || "${state}" == "empty" ]]; then
    printf 'No data\n'
  elif [[ -z "${value}" ]]; then
    printf 'Unavailable\n'
  else
    printf '%s\n' "${value}"
  fi
}

dashboard_plural_count() {
  local value="$1"
  local noun="$2"
  if [[ "${value}" == "1" ]]; then
    printf '1 %s\n' "${noun}"
  else
    printf '%s %ss\n' "${value}" "${noun}"
  fi
}

dashboard_metric_note() {
  local value="$1"
  local state="$2"
  local missing_text="$3"
  local zero_text="$4"
  local observed_text="$5"
  if [[ "${state}" == "missing" || "${state}" == "empty" ]]; then
    printf '%s\n' "${missing_text}"
  elif [[ -z "${value}" ]]; then
    printf 'This value was not available in the observe-value JSON.\n'
  elif [[ "${value}" == "0" ]]; then
    printf '%s\n' "${zero_text}"
  else
    printf '%s\n' "${observed_text}"
  fi
}

capture_command() {
  local output status
  status=0
  output="$("$@" 2>&1)" || status=$?
  if [[ "${status}" -ne 0 ]]; then
    printf 'ERROR: command failed (%s):' "${status}" >&2
    printf ' %q' "$@" >&2
    printf '\n%s\n' "${output}" >&2
    return "${status}"
  fi
  printf '%s\n' "${output}"
}

capture_dashboard_command() {
  local output status
  status=0
  output="$("$@" 2>&1)" || status=$?
  if [[ "${status}" -ne 0 ]]; then
    printf 'COMMAND FAILED (%s):' "${status}"
    printf ' %q' "$@"
    printf '\n%s\n' "${output}"
    return 0
  fi
  printf '%s\n' "${output}"
}

capture_dashboard_value_command() {
  local output status
  status=0
  output="$("$@" 2>&1)" || status=$?
  if [[ "${status}" -ne 0 ]]; then
    printf 'COMMAND FAILED (%s):' "${status}"
    printf ' %q' "$@"
    printf '\n%s\n' "${output}"
    return "${status}"
  fi
  printf '%s\n' "${output}"
}

canonical_dir() {
  local candidate="$1"
  if [[ -d "${candidate}" ]]; then
    (cd "${candidate}" && pwd)
  else
    return 1
  fi
}

is_vibeguard_repo() {
  local candidate="$1"
  [[ -f "${candidate}/setup.sh" ]] \
    && [[ -d "${candidate}/hooks" ]] \
    && [[ -d "${candidate}/skills" ]] \
    && [[ -f "${candidate}/vibeguard-runtime/Cargo.toml" ]]
}

resolve_repo_dir() {
  local candidate resolved git_root
  local -a candidates=()

  if [[ -n "${VIBEGUARD_REPO_DIR:-}" ]]; then
    if resolved="$(canonical_dir "${VIBEGUARD_REPO_DIR}")" && is_vibeguard_repo "${resolved}"; then
      printf '%s\n' "${resolved}"
      return 0
    fi
    printf 'ERROR: VIBEGUARD_REPO_DIR is not a VibeGuard repository checkout: %s\n' "${VIBEGUARD_REPO_DIR}" >&2
    return 1
  fi

  candidates+=("${PLUGIN_DIR}/../..")

  if git_root="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null)"; then
    candidates+=("${git_root}")
  fi

  candidates+=("${HOME}/vibeguard")

  for candidate in "${candidates[@]}"; do
    if resolved="$(canonical_dir "${candidate}")" && is_vibeguard_repo "${resolved}"; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  done

  printf 'ERROR: could not locate a VibeGuard repository checkout.\n' >&2
  printf 'Set VIBEGUARD_REPO_DIR=/path/to/vibeguard and retry.\n' >&2
  return 1
}

run_setup() {
  local mode="$1"
  shift || true

  local repo_dir
  repo_dir="$(resolve_repo_dir)"

  case "${mode}" in
    install)
      exec bash "${repo_dir}/setup.sh" "$@"
      ;;
    check)
      exec bash "${repo_dir}/setup.sh" --check "$@"
      ;;
    clean)
      exec bash "${repo_dir}/setup.sh" --clean "$@"
      ;;
    codex-status)
      exec bash "${repo_dir}/setup.sh" --codex-status "$@"
      ;;
    *)
      printf 'ERROR: unsupported setup mode: %s\n' "${mode}" >&2
      return 2
      ;;
  esac
}

run_repo_script() {
  local script_path="$1"
  shift || true

  local repo_dir
  repo_dir="$(resolve_repo_dir)"
  exec bash "${repo_dir}/${script_path}" "$@"
}

open_path() {
  local path="$1"
  if command -v open >/dev/null 2>&1; then
    open "${path}"
    return
  fi
  printf '%s\n' "${path}"
}

open_site() {
  local repo_dir site_path
  repo_dir="$(resolve_repo_dir)"
  site_path="${repo_dir}/site/index.html"
  if [[ ! -f "${site_path}" ]]; then
    printf 'ERROR: VibeGuard site is missing: %s\n' "${site_path}" >&2
    return 1
  fi
  open_path "${site_path}"
}

generate_dashboard() {
  local output_path=""
  local open_after=1
  local days="7"
  local hours="24"
  local scope=""
  local project=""
  local log_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)
        [[ $# -ge 2 ]] || { printf 'ERROR: --output requires a path\n' >&2; return 2; }
        output_path="$2"
        shift 2
        ;;
      --no-open)
        open_after=0
        shift
        ;;
      --days)
        [[ $# -ge 2 ]] || { printf 'ERROR: --days requires a value\n' >&2; return 2; }
        days="$2"
        shift 2
        ;;
      --hours)
        [[ $# -ge 2 ]] || { printf 'ERROR: --hours requires a value\n' >&2; return 2; }
        hours="$2"
        shift 2
        ;;
      --scope)
        [[ $# -ge 2 ]] || { printf 'ERROR: --scope requires project or global\n' >&2; return 2; }
        scope="$2"
        shift 2
        ;;
      --project)
        [[ $# -ge 2 ]] || { printf 'ERROR: --project requires a path or hash\n' >&2; return 2; }
        project="$2"
        shift 2
        ;;
      --log-file)
        [[ $# -ge 2 ]] || { printf 'ERROR: --log-file requires a path\n' >&2; return 2; }
        log_file="$2"
        shift 2
        ;;
      --help|-h)
        cat <<'USAGE'
Usage: bash scripts/vibeguard-plugin.sh dashboard [options]

Options:
  --output PATH          Write dashboard HTML to PATH
  --no-open              Do not open the generated dashboard
  --days N|all           Stats window, default 7
  --hours N              Health window, default 24
  --scope project|global Select value evidence, stats, and health scope
  --project PATH_OR_HASH Select project for value evidence, stats, and health
  --log-file PATH        Read value evidence, stats, and health from PATH
USAGE
        return 0
        ;;
      *)
        printf 'ERROR: unknown dashboard option: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  if [[ "${days}" != "all" ]] && { ! [[ "${days}" =~ ^[0-9]+$ ]] || [[ "${days}" -le 0 ]]; }; then
    printf 'ERROR: --days must be a positive integer or all\n' >&2
    return 2
  fi
  if ! [[ "${hours}" =~ ^[0-9]+$ ]] || [[ "${hours}" -le 0 ]]; then
    printf 'ERROR: --hours must be a positive integer\n' >&2
    return 2
  fi
  if [[ -n "${scope}" && "${scope}" != "project" && "${scope}" != "global" ]]; then
    printf 'ERROR: --scope must be project or global\n' >&2
    return 2
  fi
  if [[ -n "${project}" && "${scope}" == "global" ]]; then
    printf 'ERROR: --project cannot be used with --scope global\n' >&2
    return 2
  fi

  local explicit_log_missing=0
  if [[ -n "${log_file}" && ! -e "${log_file}" ]]; then
    explicit_log_missing=1
  fi

  local repo_dir dashboard_dir generated_at period_label
  repo_dir="$(resolve_repo_dir)"
  dashboard_dir="${PLUGIN_DATA:-${VIBEGUARD_PLUGIN_DATA:-${HOME}/.vibeguard/plugin}}"
  if [[ -z "${output_path}" ]]; then
    output_path="${dashboard_dir}/vibeguard-dashboard.html"
  fi
  mkdir -p "$(dirname "${output_path}")"

  local -a stats_args=("${days}")
  local -a health_args=("${hours}")
  if [[ -n "${scope}" ]]; then
    stats_args=(--scope "${scope}" "${stats_args[@]}")
    health_args=(--scope "${scope}" "${health_args[@]}")
  fi
  if [[ -n "${project}" ]]; then
    stats_args=(--project "${project}" "${stats_args[@]}")
    health_args=(--project "${project}" "${health_args[@]}")
  fi
  if [[ -n "${log_file}" ]]; then
    stats_args=(--log-file "${log_file}" "${stats_args[@]}")
    health_args=(--log-file "${log_file}" "${health_args[@]}")
  fi

  local -a value_args=(observe value --json --limit all --days "${days}")
  if [[ -n "${scope}" ]]; then
    value_args+=(--scope "${scope}")
  fi
  if [[ -n "${project}" ]]; then
    value_args+=(--project "${project}")
  fi
  if [[ -n "${log_file}" ]]; then
    value_args+=(--log-file "${log_file}")
  fi

  local status_out stats_out health_out value_out value_runtime=""
  local value_resolution_status value_status
  value_resolution_status=0
  value_status=0
  status_out="$(capture_dashboard_command bash "${repo_dir}/setup.sh" --codex-status)"
  stats_out="$(capture_dashboard_command bash "${repo_dir}/scripts/stats.sh" "${stats_args[@]}")"
  health_out="$(capture_dashboard_command bash "${repo_dir}/scripts/hook-health.sh" "${health_args[@]}")"

  if [[ ! -f "${repo_dir}/scripts/lib/runtime.sh" ]]; then
    value_resolution_status=2
    value_status=2
    value_out="RUNTIME CAPABILITY UNAVAILABLE: shared runtime resolver is missing from ${repo_dir}/scripts/lib/runtime.sh"
  elif ! source "${repo_dir}/scripts/lib/runtime.sh"; then
    value_resolution_status=2
    value_status=2
    value_out="RUNTIME RESOLVER FAILED: could not load ${repo_dir}/scripts/lib/runtime.sh"
  elif value_runtime="$(vg_resolve_runtime "${repo_dir}" observe_value 2>&1)"; then
    value_out="$(capture_dashboard_value_command "${value_runtime}" "${value_args[@]}")" || value_status=$?
  else
    value_resolution_status=$?
    value_status="${value_resolution_status}"
    value_out="RUNTIME CAPABILITY UNAVAILABLE (${value_resolution_status}): ${value_runtime}"
  fi

  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if [[ "${days}" == "all" ]]; then
    period_label="all available history"
  else
    period_label="last ${days} days"
  fi

  local status_clean stats_clean health_clean value_clean
  local stats_cmd health_cmd status_cmd value_cmd
  status_clean="$(printf '%s\n' "${status_out}" | strip_ansi)"
  stats_clean="$(printf '%s\n' "${stats_out}" | strip_ansi)"
  health_clean="$(printf '%s\n' "${health_out}" | strip_ansi)"
  value_clean="$(printf '%s\n' "${value_out}" | strip_ansi)"
  status_cmd="$(printf 'bash %q --codex-status' "${repo_dir}/setup.sh")"
  stats_cmd="$({ printf 'bash %q' "${repo_dir}/scripts/stats.sh"; printf ' %q' "${stats_args[@]}"; printf '\n'; } )"
  health_cmd="$({ printf 'bash %q' "${repo_dir}/scripts/hook-health.sh"; printf ' %q' "${health_args[@]}"; printf '\n'; } )"
  value_cmd="$({ printf '%q' "${value_runtime:-vibeguard-runtime}"; printf ' %q' "${value_args[@]}"; printf '\n'; } )"

  local state="unavailable"
  local state_label="Evidence unavailable"
  local headline body next_action
  local verified_build="" follow_up="" unresolved="" repeated="" suppressions="" uncorrelatable=""
  local attention_events="" attention_sessions="" duration_count="" duration_avg="" duration_p95=""
  local overhead="Unavailable" overhead_note="No JSON evidence was available."
  local friction_note="Friction cannot be assessed until the JSON evidence command succeeds."
  local estimated_reason limitations_html
  local partial=0 parse_status=0

  limitations_html='<p class="muted">No additional limitations were provided.</p>'
  if [[ "${explicit_log_missing}" -eq 1 ]]; then
    state="missing"
    state_label="Event source missing"
    headline="The selected local event source is missing."
    body="The selected log path does not exist, so this dashboard cannot treat the window as empty or report zero evidence."
    next_action="Check the selected log path and VibeGuard setup, then regenerate the dashboard."
    overhead="No data"
    overhead_note="No timing data in the selected source."
    friction_note="Friction cannot be assessed until the selected event source exists."
    estimated_reason="The selected event source is missing, so outcome evidence is unavailable."
  elif [[ "${value_status}" -ne 0 ]]; then
    if [[ "${value_resolution_status}" -eq 0 ]]; then
      headline="Evidence command failed; no headline evidence was rendered."
      body="The selected runtime was available, but observe value --json did not complete successfully."
      next_action="Check the escaped command output below, then update or build the VibeGuard runtime if needed."
      estimated_reason="The evidence command did not produce usable output."
    else
      headline="First-win evidence is unavailable."
      body="The selected runtime could not provide observe value --json, so no headline evidence is shown."
      next_action="Update or build the VibeGuard runtime, then regenerate this dashboard."
      estimated_reason="The selected runtime does not support observe-value evidence."
    fi
  else
    state="$(dashboard_json_field "${value_runtime}" "${value_clean}" value.data_state)" || parse_status=$?
    if [[ "${parse_status}" -ne 0 ]]; then
      state="unavailable"
      headline="Evidence output could not be parsed; no headline evidence was rendered."
      body="The runtime returned output, but it was not the expected observe-value JSON envelope."
      next_action="Update or build the VibeGuard runtime, then regenerate this dashboard."
      overhead_note="The JSON output could not be parsed."
      friction_note="Friction cannot be assessed until the JSON evidence output is valid."
      estimated_reason="The observe-value JSON could not be parsed."
    else
      case "${state}" in
        missing|empty|observed) ;;
        *) state="partial" ;;
      esac

      verified_build="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.verified.sessions_with_later_build_pass)" || verified_build=""
      follow_up="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.observed.sessions_with_later_follow_up_pass)" || follow_up=""
      unresolved="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.observed.sessions_without_later_follow_up_pass)" || unresolved=""
      repeated="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.observed.sessions_with_repeated_attention)" || repeated=""
      suppressions="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.observed.suppression_events)" || suppressions=""
      uncorrelatable="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.observed.uncorrelatable_attention_events)" || uncorrelatable=""
      attention_events="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.observed.attention_events)" || attention_events=""
      attention_sessions="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.observed.sessions_with_attention)" || attention_sessions=""
      duration_count="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.observed.hook_duration_ms.count)" || duration_count=""
      duration_avg="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.observed.hook_duration_ms.avg_ms)" || duration_avg=""
      duration_p95="$(dashboard_count_value "${value_runtime}" "${value_clean}" value.observed.hook_duration_ms.p95_ms)" || duration_p95=""

      if [[ "${state}" == "partial" || -z "${verified_build}" || -z "${follow_up}" || -z "${unresolved}" || -z "${repeated}" || -z "${suppressions}" || -z "${uncorrelatable}" ]]; then
        partial=1
      fi
      if [[ -n "${uncorrelatable}" && "${uncorrelatable}" -gt 0 ]]; then
        partial=1
      fi

      if [[ "${state}" == "missing" ]]; then
        headline="The selected local event source is missing."
        body="The configured source could not be found, so this dashboard cannot treat the window as empty or report zero evidence."
        next_action="Check the selected log path and VibeGuard setup, then regenerate the dashboard."
      elif [[ "${state}" == "empty" ]]; then
        headline="No local event data in the selected window."
        body="The selected source exists but has no usable events in this window; the dashboard does not turn that absence into zero evidence."
        next_action="Trigger one protected action in the project, then regenerate the dashboard."
      elif [[ -n "${verified_build}" && "${verified_build}" -gt 0 ]]; then
        headline="A later build pass is recorded after VibeGuard stepped in."
        body="$(dashboard_plural_count "${verified_build}" session) contains a strictly later post-build-check pass after a guardrail signal. This is a time-ordered association, not proof VibeGuard caused the result."
        next_action="Keep observing the next intervention-to-pass sequence in this project."
      elif [[ -n "${follow_up}" && "${follow_up}" -gt 0 ]]; then
        headline="A follow-up pass is visible after VibeGuard stepped in."
        body="The event stream shows a later ordinary pass in $(dashboard_plural_count "${follow_up}" session), but no later build-pass association is recorded here."
        next_action="Run or observe a post-build check after the next follow-up."
      elif [[ -n "${unresolved}" && "${unresolved}" -gt 0 ]]; then
        headline="A guardrail signal still needs follow-up in $(dashboard_plural_count "${unresolved}" session)."
        body="These sessions have no later ordinary pass recorded in the selected event window."
        next_action="Inspect the unresolved sessions before drawing a conclusion."
      elif [[ "${partial}" -eq 1 ]]; then
        headline="Partial / unresolved local evidence."
        body="Some guardrail signals or fields cannot support a complete sequence in this window."
        next_action="Inspect the local event stream and observe the next intervention-to-pass sequence."
      else
        headline="No supported intervention-to-follow-up sequence is recorded yet."
        body="The selected event stream is present, but it does not contain a supported first-win story in this window."
        next_action="Use VibeGuard in the project and observe the next protected action."
      fi

      if [[ "${state}" != "missing" && "${state}" != "empty" && "${partial}" -eq 1 ]]; then
        if [[ -n "${uncorrelatable}" && "${uncorrelatable}" -gt 0 ]]; then
          body="${body} Evidence is partial: $(dashboard_plural_count "${uncorrelatable}" "guardrail signal") could not be correlated by session and timestamp."
        else
          body="${body} Evidence is partial: one or more required fields were unavailable."
        fi
      fi

      if [[ -n "${duration_count}" && "${duration_count}" -gt 0 && -n "${duration_avg}" ]]; then
        overhead="${duration_avg} ms"
        overhead_note="Average observed hook duration across $(dashboard_plural_count "${duration_count}" event)"
        if [[ -n "${duration_p95}" ]]; then
          overhead_note="${overhead_note}; p95 ${duration_p95} ms."
        else
          overhead_note="${overhead_note}."
        fi
      elif [[ "${state}" == "missing" || "${state}" == "empty" ]]; then
        overhead="No data"
        overhead_note="No timing data in the selected source."
      elif [[ "${duration_count}" == "0" ]]; then
        overhead="No timing data"
        overhead_note="The selected events did not include usable durations."
      else
        overhead="Unavailable"
        overhead_note="Hook duration was not available in the observe-value JSON."
      fi

      estimated_reason="$(dashboard_json_field "${value_runtime}" "${value_clean}" value.estimated.reason)" || estimated_reason=""
      if [[ -z "${estimated_reason}" ]]; then
        estimated_reason="The local event stream does not provide causal, incident, savings, or compliance evidence."
      fi
      if [[ -n "${attention_events}" && -n "${attention_sessions}" ]]; then
        friction_note="Observed $(dashboard_plural_count "${attention_events}" "attention event") across $(dashboard_plural_count "${attention_sessions}" session); these signals do not establish impact."
      else
        friction_note="These are observed friction signals, not outcome claims."
      fi

      local limitation limitations_raw index=0 limitation_items=""
      limitations_raw="$(dashboard_json_field "${value_runtime}" "${value_clean}" value.limitations)" || limitations_raw=""
      while limitation="$(dashboard_json_field "${value_runtime}" "${value_clean}" "value.limitations.${index}")"; do
        if [[ -n "${limitation}" ]]; then
          limitation_items="${limitation_items}<li>$(printf '%s' "${limitation}" | html_escape)</li>"
        fi
        index=$((index + 1))
      done
      if [[ -n "${limitation_items}" ]]; then
        limitations_html="<ul class=\"limit-list\">${limitation_items}</ul>"
      elif [[ -n "${limitations_raw}" && "${limitations_raw}" != "[]" ]]; then
        limitations_html='<p class="muted">Limitations were reported but could not be rendered; inspect the raw observe-value output below.</p>'
      fi

      if [[ "${partial}" -eq 1 ]]; then
        state_label="Partial / unresolved local evidence"
      elif [[ "${state}" == "observed" ]]; then
        state_label="Observed local evidence"
      elif [[ "${state}" == "missing" ]]; then
        state_label="Event source missing"
      else
        state_label="No local event data"
      fi
    fi
  fi

  local unavailable_note="No JSON evidence was available."
  if [[ "${parse_status}" -ne 0 ]]; then
    unavailable_note="The JSON output could not be parsed."
  fi
  local verified_text follow_up_text unresolved_text repeated_text suppressions_text uncorrelatable_text
  local verified_note follow_up_note unresolved_note
  if [[ "${state}" == "unavailable" ]]; then
    verified_text="Unavailable"
    follow_up_text="Unavailable"
    unresolved_text="Unavailable"
    repeated_text="Unavailable"
    suppressions_text="Unavailable"
    uncorrelatable_text="Unavailable"
    verified_note="${unavailable_note}"
    follow_up_note="${unavailable_note}"
    unresolved_note="${unavailable_note}"
  else
    verified_text="$(dashboard_count_text "${verified_build}" "${state}")"
    follow_up_text="$(dashboard_count_text "${follow_up}" "${state}")"
    unresolved_text="$(dashboard_count_text "${unresolved}" "${state}")"
    repeated_text="$(dashboard_count_text "${repeated}" "${state}")"
    suppressions_text="$(dashboard_count_text "${suppressions}" "${state}")"
    uncorrelatable_text="$(dashboard_count_text "${uncorrelatable}" "${state}")"
    verified_note="$(dashboard_metric_note "${verified_build}" "${state}" "The selected source has no usable events." "No later build-pass association is recorded in this window." "Strictly later post-build-check pass association(s) after a guardrail signal.")"
    follow_up_note="$(dashboard_metric_note "${follow_up}" "${state}" "The selected source has no usable events." "No later ordinary pass is recorded in this window." "Later ordinary pass(es) observed after a guardrail signal.")"
    unresolved_note="$(dashboard_metric_note "${unresolved}" "${state}" "The selected source has no usable events." "No unresolved guardrail-signal session is recorded in this window." "Guardrail-signal session(s) without a later ordinary pass.")"
  fi

  if ! render_dashboard_template "${PLUGIN_DIR}/assets/dashboard-template.html" "${output_path}" \
    REPO_DIR "$(printf '%s' "${repo_dir}" | html_escape)" \
    GENERATED_AT "$(printf '%s' "${generated_at}" | html_escape)" \
    SCOPE "$(printf '%s' "${scope:-project}" | html_escape)" \
    PERIOD "$(printf '%s' "${period_label}" | html_escape)" \
    DATA_STATE "$(printf '%s' "${state}" | html_escape)" \
    STATE_LABEL "$(printf '%s' "${state_label}" | html_escape)" \
    STORY_HEADLINE "$(printf '%s' "${headline}" | html_escape)" \
    STORY_BODY "$(printf '%s' "${body}" | html_escape)" \
    NEXT_ACTION "$(printf '%s' "${next_action}" | html_escape)" \
    VERIFIED_BUILD "$(printf '%s' "${verified_text}" | html_escape)" \
    VERIFIED_NOTE "$(printf '%s' "${verified_note}" | html_escape)" \
    FOLLOW_UP "$(printf '%s' "${follow_up_text}" | html_escape)" \
    FOLLOW_NOTE "$(printf '%s' "${follow_up_note}" | html_escape)" \
    UNRESOLVED "$(printf '%s' "${unresolved_text}" | html_escape)" \
    UNRESOLVED_NOTE "$(printf '%s' "${unresolved_note}" | html_escape)" \
    OVERHEAD "$(printf '%s' "${overhead}" | html_escape)" \
    OVERHEAD_NOTE "$(printf '%s' "${overhead_note}" | html_escape)" \
    REPEATED "$(printf '%s' "${repeated_text}" | html_escape)" \
    SUPPRESSIONS "$(printf '%s' "${suppressions_text}" | html_escape)" \
    UNCORRELATABLE "$(printf '%s' "${uncorrelatable_text}" | html_escape)" \
    FRICTION_NOTE "$(printf '%s' "${friction_note}" | html_escape)" \
    ESTIMATED_REASON "$(printf '%s' "${estimated_reason}" | html_escape)" \
    LIMITATIONS "${limitations_html}" \
    STATUS_OUT "$(printf '%s' "${status_clean}" | html_escape)" \
    STATS_OUT "$(printf '%s' "${stats_clean}" | html_escape)" \
    HEALTH_OUT "$(printf '%s' "${health_clean}" | html_escape)" \
    VALUE_OUT "$(printf '%s' "${value_clean}" | html_escape)" \
    STATUS_COMMAND "$(printf '%s' "${status_cmd}" | html_escape)" \
    STATS_COMMAND "$(printf '%s' "${stats_cmd}" | html_escape)" \
    HEALTH_COMMAND "$(printf '%s' "${health_cmd}" | html_escape)" \
    VALUE_COMMAND "$(printf '%s' "${value_cmd}" | html_escape)"; then
    printf 'ERROR: dashboard template generation failed\n' >&2
    return 1
  fi
  if ! chmod 600 "${output_path}"; then
    printf 'ERROR: could not set private permissions on dashboard: %s\n' "${output_path}" >&2
    return 1
  fi
  printf '%s\n' "${output_path}"

  if [[ "${open_after}" -eq 1 ]]; then
    open_path "${output_path}"
  fi
}

case "${1:-help}" in
  help|--help|-h)
    print_usage
    ;;
  repo-dir)
    resolve_repo_dir
    ;;
  dashboard)
    shift || true
    generate_dashboard "$@"
    ;;
  stats)
    shift || true
    run_repo_script "scripts/stats.sh" "$@"
    ;;
  health)
    shift || true
    run_repo_script "scripts/hook-health.sh" "$@"
    ;;
  doctor)
    shift || true
    run_repo_script "scripts/doctors/codex-doctor.sh" "$@"
    ;;
  metrics-export)
    shift || true
    run_repo_script "scripts/metrics/metrics-exporter.sh" "$@"
    ;;
  open-site)
    shift || true
    if [[ $# -ne 0 ]]; then
      printf 'ERROR: open-site does not accept arguments\n' >&2
      exit 2
    fi
    open_site
    ;;
  install|check|clean|codex-status)
    command="$1"
    shift || true
    run_setup "${command}" "$@"
    ;;
  *)
    printf 'ERROR: unknown command: %s\n' "$1" >&2
    print_usage >&2
    exit 2
    ;;
esac
