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
  --scope project|global Pass scope through to stats and health
  --project PATH_OR_HASH Pass project through to stats and health
  --log-file PATH        Read observe events from PATH
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

  local repo_dir dashboard_dir generated_at
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

  local status_out stats_out health_out
  status_out="$(capture_dashboard_command bash "${repo_dir}/setup.sh" --codex-status)"
  stats_out="$(capture_dashboard_command bash "${repo_dir}/scripts/stats.sh" "${stats_args[@]}")"
  health_out="$(capture_dashboard_command bash "${repo_dir}/scripts/hook-health.sh" "${health_args[@]}")"
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local status_html stats_html health_html repo_html generated_html
  local stats_cmd_html health_cmd_html status_cmd_html
  status_html="$(printf '%s\n' "${status_out}" | strip_ansi | html_escape)"
  stats_html="$(printf '%s\n' "${stats_out}" | strip_ansi | html_escape)"
  health_html="$(printf '%s\n' "${health_out}" | strip_ansi | html_escape)"
  repo_html="$(printf '%s\n' "${repo_dir}" | html_escape)"
  generated_html="$(printf '%s\n' "${generated_at}" | html_escape)"
  status_cmd_html="$(printf 'bash %q --codex-status' "${repo_dir}/setup.sh" | html_escape)"
  stats_cmd_html="$({ printf 'bash %q' "${repo_dir}/scripts/stats.sh"; printf ' %q' "${stats_args[@]}"; printf '\n'; } | html_escape)"
  health_cmd_html="$({ printf 'bash %q' "${repo_dir}/scripts/hook-health.sh"; printf ' %q' "${health_args[@]}"; printf '\n'; } | html_escape)"

  cat > "${output_path}" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VibeGuard Observability</title>
<style>
:root {
  color-scheme: light;
  --bg: #f7f8fb;
  --panel: #ffffff;
  --text: #18212f;
  --muted: #5c6676;
  --line: #d9dee8;
  --green: #178a4f;
  --amber: #b76b00;
  --red: #b42318;
  --blue: #2358c2;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
main {
  width: min(1180px, calc(100% - 32px));
  margin: 0 auto;
  padding: 32px 0 40px;
}
header {
  display: flex;
  justify-content: space-between;
  gap: 20px;
  align-items: flex-start;
  padding-bottom: 20px;
  border-bottom: 1px solid var(--line);
}
h1 {
  margin: 0 0 8px;
  font-size: 32px;
  line-height: 1.1;
  letter-spacing: 0;
}
.sub {
  margin: 0;
  color: var(--muted);
  font-size: 14px;
  line-height: 1.5;
}
.badge {
  border: 1px solid var(--line);
  background: var(--panel);
  border-radius: 8px;
  padding: 8px 10px;
  color: var(--muted);
  font-size: 12px;
  white-space: nowrap;
}
.grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 14px;
  margin: 20px 0;
}
.card {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 16px;
  min-height: 116px;
}
.card h2 {
  margin: 0 0 8px;
  font-size: 16px;
  letter-spacing: 0;
}
.card p {
  margin: 0;
  color: var(--muted);
  font-size: 13px;
  line-height: 1.45;
}
.ok { color: var(--green); }
.warn { color: var(--amber); }
.risk { color: var(--red); }
section {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  margin-top: 14px;
  overflow: hidden;
}
section h2 {
  margin: 0;
  padding: 14px 16px;
  font-size: 15px;
  border-bottom: 1px solid var(--line);
}
pre {
  margin: 0;
  padding: 16px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
  font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  color: #172033;
  background: #fbfcff;
}
.cmd {
  color: var(--blue);
  border-top: 1px solid var(--line);
  background: #f5f8ff;
}
@media (max-width: 860px) {
  header { display: block; }
  .badge { display: inline-block; margin-top: 12px; white-space: normal; }
  .grid { grid-template-columns: 1fr; }
  h1 { font-size: 26px; }
}
</style>
</head>
<body>
<main>
  <header>
    <div>
      <h1>VibeGuard Observability</h1>
      <p class="sub">Local hook health, trigger stats, and Codex setup state generated from VibeGuard diagnostics.</p>
      <p class="sub">Repo: ${repo_html}</p>
    </div>
    <div class="badge">Generated ${generated_html}</div>
  </header>

  <div class="grid">
    <div class="card">
      <h2 class="ok">Runtime Health</h2>
      <p>Shows installed hook state, warnings, repair hints, and recent Codex hook activity.</p>
    </div>
    <div class="card">
      <h2 class="warn">Hook Friction</h2>
      <p>Use health and stats together to separate noisy hooks from missing installation state.</p>
    </div>
    <div class="card">
      <h2 class="risk">Eval Boundary</h2>
      <p>This dashboard is runtime evidence. It does not replace behavior eval gates.</p>
    </div>
  </div>

  <section>
    <h2>Codex Status</h2>
    <pre>${status_html}</pre>
    <pre class="cmd">${status_cmd_html}</pre>
  </section>

  <section>
    <h2>Hook Health</h2>
    <pre>${health_html}</pre>
    <pre class="cmd">${health_cmd_html}</pre>
  </section>

  <section>
    <h2>Trigger Stats</h2>
    <pre>${stats_html}</pre>
    <pre class="cmd">${stats_cmd_html}</pre>
  </section>
</main>
</body>
</html>
HTML

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
