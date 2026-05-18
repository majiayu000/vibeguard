#!/usr/bin/env bash
# Session id and CLI inference for hooks/log.sh.

# Session ID: events within the same CLI session share the same session_id.
# Strategy: ancestor process PID + 30-minute inactivity window + process startup time anchor.
# Also infer the caller CLI so events can distinguish Claude Code vs Codex.
if [[ -z "${VIBEGUARD_CLI:-}" && -n "${VIBEGUARD_SESSION_ID:-}" ]]; then
  VIBEGUARD_CLI="unknown"
fi

if [[ -z "${VIBEGUARD_CLI:-}" || -z "${VIBEGUARD_SESSION_ID:-}" ]]; then
  _vg_parent_pid=""
  _vg_parent_cli=""
  _vg_walk_pid="$$"
  _vg_depth=0
  while [[ $_vg_depth -lt 8 ]]; do
    _vg_ppid=$(ps -o ppid= -p "$_vg_walk_pid" 2>/dev/null | tr -d ' ') || break
    [[ -z "$_vg_ppid" || "$_vg_ppid" == "0" || "$_vg_ppid" == "1" ]] && break
    _vg_comm=$(ps -o comm= -p "$_vg_ppid" 2>/dev/null | tr -d ' ') || break
    # Fast path on comm alone — avoids a second ps(1) fork for ancestor
    # levels that are neither node nor a known CLI (login shell, launchd,
    # init, etc.). ps -o args= only runs when comm == node, where
    # claude-code / codex-cli / electron all share the same binary name.
    _vg_need_args=""
    case "$_vg_comm" in
      *codex*)
        _vg_parent_pid="$_vg_ppid"; _vg_parent_cli="codex"; break ;;
      *claude*|*Claude*|*electron*|*Electron*)
        _vg_parent_pid="$_vg_ppid"; _vg_parent_cli="claude"; break ;;
      node)
        _vg_need_args="1" ;;
    esac
    if [[ -n "$_vg_need_args" ]]; then
      _vg_args=$(ps -o args= -p "$_vg_ppid" 2>/dev/null || echo "")
      case "$_vg_args" in
        *@openai/codex*|*codex*)
          _vg_parent_pid="$_vg_ppid"; _vg_parent_cli="codex"; break ;;
        *@anthropic-ai/claude*|*claude*|*Claude*)
          _vg_parent_pid="$_vg_ppid"; _vg_parent_cli="claude"; break ;;
      esac
    fi
    _vg_walk_pid="$_vg_ppid"
    _vg_depth=$((_vg_depth + 1))
  done

  if [[ -z "${VIBEGUARD_CLI:-}" ]]; then
    if [[ -n "$_vg_parent_cli" ]]; then
      VIBEGUARD_CLI="$_vg_parent_cli"
    else
      VIBEGUARD_CLI="unknown"
    fi
  fi

  if [[ -z "${VIBEGUARD_SESSION_ID:-}" ]]; then
    if [[ -n "$_vg_parent_pid" ]]; then
      _vg_proc_start=$(TZ=UTC ps -o lstart= -p "$_vg_parent_pid" 2>/dev/null | xargs || echo "unknown")
      _vg_sf="${VIBEGUARD_PROJECT_LOG_DIR}/.session_${VIBEGUARD_CLI}_${_vg_parent_pid}"
      _vg_reuse=false
      # PERF-OK: find is scoped to one session file, not a directory traversal.
      if [[ -f "$_vg_sf" ]] && [[ -n "$(find "$_vg_sf" -mmin -30 2>/dev/null)" ]]; then
        _vg_stored_start=$(head -1 "$_vg_sf" 2>/dev/null)
        if [[ "$_vg_stored_start" == "$_vg_proc_start" ]]; then
          _vg_reuse=true
        fi
      fi

      if [[ "$_vg_reuse" == "true" ]]; then
        VIBEGUARD_SESSION_ID=$(tail -1 "$_vg_sf" 2>/dev/null)
        touch "$_vg_sf" 2>/dev/null || true
      else
        VIBEGUARD_SESSION_ID=$(printf '%04x%04x' $RANDOM $RANDOM)
        mkdir -p "$VIBEGUARD_PROJECT_LOG_DIR" 2>/dev/null
        _vg_tmp=$(mktemp "${VIBEGUARD_PROJECT_LOG_DIR}/.session_tmp_XXXXXX" 2>/dev/null) \
          || _vg_tmp="${_vg_sf}.tmp.$$"
        printf '%s\n%s\n' "$_vg_proc_start" "$VIBEGUARD_SESSION_ID" > "$_vg_tmp" \
          && mv "$_vg_tmp" "$_vg_sf" 2>/dev/null \
          || { rm -f "$_vg_tmp" 2>/dev/null; printf '%s\n%s\n' "$_vg_proc_start" "$VIBEGUARD_SESSION_ID" > "$_vg_sf"; }
      fi

      find "${VIBEGUARD_PROJECT_LOG_DIR}" -maxdepth 1 -name ".session_*" -mmin +120 -delete 2>/dev/null || true
    else
      _vg_sf="${VIBEGUARD_PROJECT_LOG_DIR}/.session_id_${VIBEGUARD_CLI}"
      # PERF-OK: find is scoped to one session file, not a directory traversal.
      if [[ -f "$_vg_sf" ]] && [[ -n "$(find "$_vg_sf" -mmin -30 2>/dev/null)" ]]; then
        VIBEGUARD_SESSION_ID=$(<"$_vg_sf")
        touch "$_vg_sf" 2>/dev/null || true
      else
        VIBEGUARD_SESSION_ID=$(printf '%04x%04x' $RANDOM $RANDOM)
        mkdir -p "$VIBEGUARD_PROJECT_LOG_DIR" 2>/dev/null
        printf '%s' "$VIBEGUARD_SESSION_ID" > "$_vg_sf"
      fi
    fi
  fi
fi

if [[ -z "${VIBEGUARD_CLIENT:-}" ]]; then
  case "${VIBEGUARD_CLI:-unknown}" in
    claude)
      VIBEGUARD_CLIENT="claude"
      VIBEGUARD_CLIENT_VARIANT="${VIBEGUARD_CLIENT_VARIANT:-claude-code-hooks}"
      VIBEGUARD_CALLER_EVIDENCE="${VIBEGUARD_CALLER_EVIDENCE:-parent-process}"
      ;;
    codex)
      VIBEGUARD_CLIENT="codex"
      VIBEGUARD_CLIENT_VARIANT="${VIBEGUARD_CLIENT_VARIANT:-codex-cli-hooks}"
      VIBEGUARD_CALLER_EVIDENCE="${VIBEGUARD_CALLER_EVIDENCE:-parent-process}"
      ;;
    *)
      VIBEGUARD_CLIENT="unknown"
      VIBEGUARD_CLIENT_VARIANT="${VIBEGUARD_CLIENT_VARIANT:-unknown}"
      VIBEGUARD_CALLER_EVIDENCE="${VIBEGUARD_CALLER_EVIDENCE:-no-client-evidence}"
      ;;
  esac
elif [[ -z "${VIBEGUARD_CLIENT_VARIANT:-}" ]]; then
  case "${VIBEGUARD_CLIENT}" in
    claude) VIBEGUARD_CLIENT_VARIANT="claude-code-hooks" ;;
    codex) VIBEGUARD_CLIENT_VARIANT="codex-cli-hooks" ;;
    *) VIBEGUARD_CLIENT_VARIANT="unknown" ;;
  esac
fi

if [[ -z "${VIBEGUARD_CALLER_EVIDENCE:-}" ]]; then
  VIBEGUARD_CALLER_EVIDENCE="explicit-client"
fi

export VIBEGUARD_CLI VIBEGUARD_SESSION_ID
export VIBEGUARD_CLIENT VIBEGUARD_CLIENT_VARIANT VIBEGUARD_CALLER_EVIDENCE
export VIBEGUARD_WRAPPER VIBEGUARD_SOURCE_CONFIG VIBEGUARD_HOOK_PROTOCOL_VERSION
