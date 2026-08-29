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
  status_cmd="bash ${repo_dir}/setup.sh --codex-status"
  stats_cmd="$({ printf 'bash %q' "${repo_dir}/scripts/stats.sh"; printf ' %q' "${stats_args[@]}"; printf '\n'; } )"
  health_cmd="$({ printf 'bash %q' "${repo_dir}/scripts/hook-health.sh"; printf ' %q' "${health_args[@]}"; printf '\n'; } )"
  if [[ -n "${value_runtime}" ]]; then
    value_cmd="$({ printf '%q' "${value_runtime}"; printf ' %q' "${value_args[@]}"; printf '\n'; } )"
  else
    value_cmd="vibeguard-runtime observe value --json --limit all --days ${days}"
  fi

  if \
    DASHBOARD_TEMPLATE_PATH="${PLUGIN_DIR}/assets/dashboard-template.html" \
    DASHBOARD_OUTPUT_PATH="${output_path}" \
    DASHBOARD_REPO_DIR="${repo_dir}" \
    DASHBOARD_GENERATED_AT="${generated_at}" \
    DASHBOARD_SCOPE="${scope:-project}" \
    DASHBOARD_PERIOD="${period_label}" \
    DASHBOARD_STATUS_OUT="${status_clean}" \
    DASHBOARD_STATS_OUT="${stats_clean}" \
    DASHBOARD_HEALTH_OUT="${health_clean}" \
    DASHBOARD_VALUE_OUT="${value_clean}" \
    DASHBOARD_VALUE_STATUS="${value_status}" \
    DASHBOARD_VALUE_RESOLUTION_STATUS="${value_resolution_status}" \
    DASHBOARD_STATUS_COMMAND="${status_cmd}" \
    DASHBOARD_STATS_COMMAND="${stats_cmd}" \
    DASHBOARD_HEALTH_COMMAND="${health_cmd}" \
    DASHBOARD_VALUE_COMMAND="${value_cmd}" \
    python3 - <<'PY'
import html
import json
import os
import sys
from pathlib import Path


def escape(value):
    return html.escape(str(value), quote=True)


def count_value(section, key):
    if not isinstance(section, dict):
        return None
    value = section.get(key)
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    return None


def count_text(value, state):
    if state in {"missing", "empty"}:
        return "No data"
    if value is None:
        return "Unavailable"
    return str(value)


def plural_count(value, noun):
    return f"{value} {noun}" if value == 1 else f"{value} {noun}s"


def diagnostic_list(items):
    if not isinstance(items, list):
        return '<p class="muted">No additional limitations were provided.</p>'
    values = [escape(item) for item in items if isinstance(item, str) and item]
    if not values:
        return '<p class="muted">No additional limitations were provided.</p>'
    return '<ul class="limit-list">' + ''.join(f"<li>{item}</li>" for item in values) + '</ul>'


def metric_note(value, state, missing_text, zero_text, observed_text):
    if state in {"missing", "empty"}:
        return missing_text
    if value is None:
        return "This value was not available in the observe-value JSON."
    if value == 0:
        return zero_text
    return observed_text


def render_evidence():
    raw = os.environ.get("DASHBOARD_VALUE_OUT", "")
    try:
        command_status = int(os.environ.get("DASHBOARD_VALUE_STATUS", "2"))
    except ValueError:
        command_status = 2
    try:
        resolution_status = int(os.environ.get("DASHBOARD_VALUE_RESOLUTION_STATUS", command_status))
    except ValueError:
        resolution_status = command_status

    if command_status != 0:
        return {
            "state": "unavailable",
            "state_label": "Evidence unavailable",
            "headline": "Evidence command failed; no headline evidence was rendered." if resolution_status == 0 else "First-win evidence is unavailable.",
            "body": "The selected runtime was available, but observe value --json did not complete successfully." if resolution_status == 0 else "The selected runtime could not provide observe value --json, so no headline evidence is shown.",
            "next_action": "Check the escaped command output below, then update or build the VibeGuard runtime if needed." if resolution_status == 0 else "Update or build the VibeGuard runtime, then regenerate this dashboard.",
            "verified_build": "Unavailable",
            "verified_note": "No JSON evidence was available.",
            "follow_up": "Unavailable",
            "follow_note": "No JSON evidence was available.",
            "unresolved": "Unavailable",
            "unresolved_note": "No JSON evidence was available.",
            "overhead": "Unavailable",
            "overhead_note": "No JSON evidence was available.",
            "repeated": "Unavailable",
            "suppressions": "Unavailable",
            "uncorrelatable": "Unavailable",
            "friction_note": "Friction cannot be assessed until the JSON evidence command succeeds.",
            "estimated_reason": "The evidence command did not produce usable output." if resolution_status == 0 else "The selected runtime does not support observe-value evidence.",
            "limitations": diagnostic_list([]),
            "raw": raw,
        }

    try:
        payload = json.loads(raw)
        value = payload["value"]
        if not isinstance(payload, dict) or not isinstance(value, dict):
            raise ValueError("observe value JSON does not contain an object value")
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        return {
            "state": "unavailable",
            "state_label": "Evidence unavailable",
            "headline": "Evidence output could not be parsed; no headline evidence was rendered.",
            "body": "The runtime returned output, but it was not the expected observe-value JSON envelope.",
            "next_action": "Update or build the VibeGuard runtime, then regenerate this dashboard.",
            "verified_build": "Unavailable",
            "verified_note": "The JSON output could not be parsed.",
            "follow_up": "Unavailable",
            "follow_note": "The JSON output could not be parsed.",
            "unresolved": "Unavailable",
            "unresolved_note": "The JSON output could not be parsed.",
            "overhead": "Unavailable",
            "overhead_note": "The JSON output could not be parsed.",
            "repeated": "Unavailable",
            "suppressions": "Unavailable",
            "uncorrelatable": "Unavailable",
            "friction_note": "Friction cannot be assessed until the JSON evidence output is valid.",
            "estimated_reason": f"The observe-value JSON could not be parsed ({error}).",
            "limitations": diagnostic_list([]),
            "raw": raw,
        }

    data_state = value.get("data_state")
    state = data_state if isinstance(data_state, str) and data_state in {"missing", "empty", "observed"} else "partial"
    verified = value.get("verified", {})
    observed = value.get("observed", {})
    verified_build = count_value(verified, "sessions_with_later_build_pass")
    follow_up = count_value(observed, "sessions_with_later_follow_up_pass")
    unresolved = count_value(observed, "sessions_without_later_follow_up_pass")
    repeated = count_value(observed, "sessions_with_repeated_attention")
    suppressions = count_value(observed, "suppression_events")
    uncorrelatable = count_value(observed, "uncorrelatable_attention_events")
    attention_events = count_value(observed, "attention_events")
    attention_sessions = count_value(observed, "sessions_with_attention")
    duration = observed.get("hook_duration_ms") if isinstance(observed, dict) else None
    duration_count = count_value(duration, "count")
    duration_avg = count_value(duration, "avg_ms")
    duration_p95 = count_value(duration, "p95_ms")
    partial = state == "partial" or any(
        item is None for item in (verified_build, follow_up, unresolved, repeated, suppressions, uncorrelatable)
    )
    if uncorrelatable is not None and uncorrelatable > 0:
        partial = True

    if state in {"missing", "empty"}:
        headline = "No local event data in the selected window."
        body = "The dashboard keeps this state explicit; it does not turn an absent or empty source into zero evidence."
        next_action = "Trigger one protected action in the project, then regenerate the dashboard."
    elif verified_build is not None and verified_build > 0:
        headline = "A later build pass is recorded after VibeGuard stepped in."
        body = f"{plural_count(verified_build, 'session')} contains a strictly later post-build-check pass after a guardrail signal. This is a time-ordered association, not proof VibeGuard caused the result."
        next_action = "Keep observing the next intervention-to-pass sequence in this project."
    elif follow_up is not None and follow_up > 0:
        headline = "A follow-up pass is visible after VibeGuard stepped in."
        body = f"The event stream shows a later ordinary pass in {plural_count(follow_up, 'session')}, but no later build-pass association is recorded here."
        next_action = "Run or observe a post-build check after the next follow-up."
    elif unresolved is not None and unresolved > 0:
        headline = f"A guardrail signal still needs follow-up in {plural_count(unresolved, 'session')}."
        body = "These sessions have no later ordinary pass recorded in the selected event window."
        next_action = "Inspect the unresolved sessions before drawing a conclusion."
    elif partial:
        headline = "Partial / unresolved local evidence."
        body = "Some guardrail signals or fields cannot support a complete sequence in this window."
        next_action = "Inspect the local event stream and observe the next intervention-to-pass sequence."
    else:
        headline = "No supported intervention-to-follow-up sequence is recorded yet."
        body = "The selected event stream is present, but it does not contain a supported first-win story in this window."
        next_action = "Use VibeGuard in the project and observe the next protected action."

    if state not in {"missing", "empty"} and partial:
        body += " Evidence is partial:"
        if uncorrelatable is not None and uncorrelatable > 0:
            body += f" {plural_count(uncorrelatable, 'guardrail signal')} could not be correlated by session and timestamp."
        else:
            body += " one or more required fields were unavailable."

    if duration_count is not None and duration_count > 0 and duration_avg is not None:
        overhead = f"{duration_avg} ms"
        overhead_note = f"Average observed hook duration across {plural_count(duration_count, 'event')}"
        if duration_p95 is not None:
            overhead_note += f"; p95 {duration_p95} ms."
        else:
            overhead_note += "."
    elif state in {"missing", "empty"}:
        overhead = "No data"
        overhead_note = "No timing data in the selected source."
    elif duration_count == 0:
        overhead = "No timing data"
        overhead_note = "The selected events did not include usable durations."
    else:
        overhead = "Unavailable"
        overhead_note = "Hook duration was not available in the observe-value JSON."

    estimated = value.get("estimated", {})
    estimated_reason = estimated.get("reason") if isinstance(estimated, dict) else None
    if not isinstance(estimated_reason, str) or not estimated_reason:
        estimated_reason = "The local event stream does not provide causal, incident, savings, or compliance evidence."
    friction_note = "These are observed friction signals, not outcome claims."
    if attention_events is not None and attention_sessions is not None:
        friction_note = f"Observed {plural_count(attention_events, 'attention event')} across {plural_count(attention_sessions, 'session')}; these signals do not establish impact."

    return {
        "state": state,
        "state_label": "Partial / unresolved local evidence" if partial else ("Observed local evidence" if state == "observed" else "No local event data"),
        "headline": headline,
        "body": body,
        "next_action": next_action,
        "verified_build": count_text(verified_build, state),
        "verified_note": metric_note(verified_build, state, "The selected source has no usable events.", "No later build-pass association is recorded in this window.", "Strictly later post-build-check pass association(s) after a guardrail signal."),
        "follow_up": count_text(follow_up, state),
        "follow_note": metric_note(follow_up, state, "The selected source has no usable events.", "No later ordinary pass is recorded in this window.", "Later ordinary pass(es) observed after a guardrail signal."),
        "unresolved": count_text(unresolved, state),
        "unresolved_note": metric_note(unresolved, state, "The selected source has no usable events.", "No unresolved guardrail-signal session is recorded in this window.", "Guardrail-signal session(s) without a later ordinary pass."),
        "overhead": overhead,
        "overhead_note": overhead_note,
        "repeated": count_text(repeated, state),
        "suppressions": count_text(suppressions, state),
        "uncorrelatable": count_text(uncorrelatable, state),
        "friction_note": friction_note,
        "estimated_reason": estimated_reason,
        "limitations": diagnostic_list(value.get("limitations")),
        "raw": raw,
    }


def main():
    template_path = Path(os.environ["DASHBOARD_TEMPLATE_PATH"])
    output_path = Path(os.environ["DASHBOARD_OUTPUT_PATH"])
    template = template_path.read_text(encoding="utf-8")
    evidence = render_evidence()
    replacements = {
        "REPO_DIR": escape(os.environ.get("DASHBOARD_REPO_DIR", "")),
        "GENERATED_AT": escape(os.environ.get("DASHBOARD_GENERATED_AT", "")),
        "SCOPE": escape(os.environ.get("DASHBOARD_SCOPE", "project")),
        "PERIOD": escape(os.environ.get("DASHBOARD_PERIOD", "last 7 days")),
        "DATA_STATE": escape(evidence["state"]),
        "STATE_LABEL": escape(evidence["state_label"]),
        "STORY_HEADLINE": escape(evidence["headline"]),
        "STORY_BODY": escape(evidence["body"]),
        "NEXT_ACTION": escape(evidence["next_action"]),
        "VERIFIED_BUILD": escape(evidence["verified_build"]),
        "VERIFIED_NOTE": escape(evidence["verified_note"]),
        "FOLLOW_UP": escape(evidence["follow_up"]),
        "FOLLOW_NOTE": escape(evidence["follow_note"]),
        "UNRESOLVED": escape(evidence["unresolved"]),
        "UNRESOLVED_NOTE": escape(evidence["unresolved_note"]),
        "OVERHEAD": escape(evidence["overhead"]),
        "OVERHEAD_NOTE": escape(evidence["overhead_note"]),
        "REPEATED": escape(evidence["repeated"]),
        "SUPPRESSIONS": escape(evidence["suppressions"]),
        "UNCORRELATABLE": escape(evidence["uncorrelatable"]),
        "FRICTION_NOTE": escape(evidence["friction_note"]),
        "ESTIMATED_REASON": escape(evidence["estimated_reason"]),
        "LIMITATIONS": evidence["limitations"],
        "STATUS_OUT": escape(os.environ.get("DASHBOARD_STATUS_OUT", "")),
        "STATS_OUT": escape(os.environ.get("DASHBOARD_STATS_OUT", "")),
        "HEALTH_OUT": escape(os.environ.get("DASHBOARD_HEALTH_OUT", "")),
        "VALUE_OUT": escape(evidence["raw"]),
        "STATUS_COMMAND": escape(os.environ.get("DASHBOARD_STATUS_COMMAND", "")),
        "STATS_COMMAND": escape(os.environ.get("DASHBOARD_STATS_COMMAND", "")),
        "HEALTH_COMMAND": escape(os.environ.get("DASHBOARD_HEALTH_COMMAND", "")),
        "VALUE_COMMAND": escape(os.environ.get("DASHBOARD_VALUE_COMMAND", "")),
    }
    for key, value in replacements.items():
        template = template.replace("{{" + key + "}}", value)
    if "{{" in template:
        raise RuntimeError("dashboard template contains an unresolved placeholder")
    output_path.write_text(template, encoding="utf-8")


try:
    main()
except (OSError, RuntimeError, UnicodeError) as error:
    sys.stderr.write(f"ERROR: could not generate dashboard: {error}\n")
    raise SystemExit(1)
PY
  then
    if ! chmod 600 "${output_path}"; then
      printf 'ERROR: could not set private permissions on dashboard: %s\n' "${output_path}" >&2
      return 1
    fi
    printf '%s\n' "${output_path}"
  else
    printf 'ERROR: dashboard template generation failed\n' >&2
    return 1
  fi

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
