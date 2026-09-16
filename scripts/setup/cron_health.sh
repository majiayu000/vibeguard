#!/usr/bin/env bash
# Read-only user-crontab diagnostics; setup must also work without Python.
set -euo pipefail
command -v crontab >/dev/null 2>&1 || exit 0

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
LC_ALL=C crontab -l > "${work}/out" 2> "${work}/err" &
reader=$!
(
  trap - EXIT
  timer=""
  trap '[[ -z "${timer}" ]] || kill "${timer}" 2>/dev/null || true; exit 0' TERM INT
  sleep 10 &
  timer=$!
  wait "${timer}"
  : > "${work}/timeout"
  kill "${reader}" 2>/dev/null || true
) >/dev/null 2>&1 &
watcher=$!
rc=0
wait "${reader}" || rc=$?
kill "${watcher}" 2>/dev/null || true
wait "${watcher}" 2>/dev/null || true
if [[ -f "${work}/timeout" ]]; then
  printf 'Cannot read user crontab: timed out after 10s\n' >&2
  exit 1
fi
if [[ "${rc}" -ne 0 ]]; then
  if [[ "${rc}" -eq 1 ]] && grep -q 'no crontab for ' "${work}/err"; then
    exit 0
  fi
  printf 'Cannot read user crontab (exit %s); run crontab -l to diagnose\n' "${rc}" >&2
  exit 1
fi

# Tokenize quotes and escapes without evaluating any part of the cron command.
awk '
  {
    command = $0
    sub(/^[[:space:]]+/, "", command)
    if (command == "" || command ~ /^#/ || command ~ /^[[:alnum:]_]+[[:space:]]*=/) next
    fields = command ~ /^@/ ? 1 : 5
    for (i = 0; i < fields; i++) {
      if (!sub(/^[^[:space:]]+[[:space:]]+/, "", command)) next
    }
    for (i in words) delete words[i]
    count = 0; word = ""; started = 0; quote = ""; escaped = 0
    single = sprintf("%c", 39)
    for (i = 1; i <= length(command); i++) {
      c = substr(command, i, 1)
      if (escaped) { word = word c; escaped = 0; continue }
      if (c == "\\" && quote != single) {
        next_c = substr(command, i + 1, 1)
        if (quote == "\"" && next_c !~ /[\\"$`]/) word = word c
        else escaped = 1
        started = 1; continue
      }
      if (quote != "") {
        if (c == quote) quote = ""
        else word = word c
        continue
      }
      if (c == single || c == "\"") { quote = c; started = 1; continue }
      if (c == "#" && !started) break
      if (c ~ /[[:space:];&|<>]/) {
        if (started) words[++count] = word
        word = ""; started = 0
        if (c !~ /[[:space:]]/) words[++count] = c
        continue
      }
      word = word c; started = 1
    }
    if (quote != "" || escaped) {
      if (index(command, "/scripts/gc/gc-scheduled.sh")) print NR "\tparse\t-"
      next
    }
    if (started) words[++count] = word
    interpreted = words[1] ~ /(^|\/)(bash|sh|zsh)$/
    target = interpreted ? words[2] : words[1]
    if (target ~ /\/scripts\/gc\/gc-scheduled\.sh$/)
      print NR "\t" (interpreted ? "shell" : "direct") "\t" target
  }
' "${work}/out" > "${work}/entries"

while IFS=$'\t' read -r number kind target; do
  prefix="Unmanaged GC cron line ${number}"
  if [[ "${kind}" == parse ]]; then
    printf '[WARN] %s: cannot parse script target; inspect with crontab -l\n' "${prefix}"
  elif [[ "${target}" != /* || "${target}" == *'$'* || "${target}" == *'`'* ]]; then
    printf '[WARN] %s: script target needs shell resolution; inspect with crontab -l\n' "${prefix}"
  elif [[ ! -f "${target}" || ! -r "${target}" ]]; then
    printf '[BROKEN] %s: script missing or unreadable: %s\n' "${prefix}" "${target}"
  elif [[ "${kind}" == direct && ! -x "${target}" ]]; then
    printf '[BROKEN] %s: script not executable: %s\n' "${prefix}" "${target}"
  else
    printf '[WARN] %s: script exists: %s; cron is user-managed (inspect with crontab -l)\n' "${prefix}" "${target}"
  fi
done < "${work}/entries"
