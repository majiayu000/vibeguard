#!/usr/bin/env bash
# UTF-8 truncation and sensitive-value redaction for hooks/log.sh.

vg_truncate_utf8() {
  local text="$1"
  local limit="${2:-200}"

  if [[ "${#text}" -le "$limit" ]]; then
    printf '%s' "$text"
    return 0
  fi

  if command -v perl &>/dev/null; then
    printf '%s' "$text" | perl -CS -e '
use strict;
use warnings;
my $limit = shift @ARGV;
local $/;
my $s = <STDIN> // q{};
print substr($s, 0, $limit);
' "$limit"
    return 0
  fi

  if command -v python3 &>/dev/null; then
    printf '%s' "$text" | python3 -c '
import sys
limit = int(sys.argv[1])
data = sys.stdin.buffer.read().decode("utf-8", errors="replace")
sys.stdout.write(data[:limit])
' "$limit"
    return 0
  fi

  printf '%s' "$text" | head -c "$limit"
}

vg_redact_sensitive() {
  local text="$1"

  case "$text" in
    *[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]*) ;;
    *[Bb][Ee][Aa][Rr][Ee][Rr]*) ;;
    *[Tt][Oo][Kk][Ee][Nn]*) ;;
    *[Ss][Ee][Cc][Rr][Ee][Tt]*) ;;
    *[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]*) ;;
    *[Pp][Aa][Ss][Ss][Ww][Dd]*) ;;
    *[Aa][Pp][Ii][_-][Kk][Ee][Yy]*) ;;
    *[Aa][Pp][Ii][Kk][Ee][Yy]*) ;;
    *)
      printf '%s' "$text"
      return 0
      ;;
  esac

  if command -v perl &>/dev/null; then
    printf '%s' "$text" | perl -CS -0777 -pe '
s/(\bAuthorization\s*:\s*Bearer\s+)[^\s"'\''`&;]+/${1}***REDACTED***/ig;
s/(\bBearer\s+)[^\s"'\''`&;]+/${1}***REDACTED***/ig;
s/(\s--?(?:api[_-]?key|password|passwd|secret|token)\s+)[^\s"'\''`&;]+/${1}***REDACTED***/ig;
s/\b([A-Za-z0-9_:-]*(?:api[_-]?key|password|passwd|secret|token)[A-Za-z0-9_:-]*\s*[:=]\s*)("[^"]*"|'\''[^'\'']*'\''|[^\s"'\''`&;]+)/${1}***REDACTED***/ig;
'
    return 0
  fi

  if command -v python3 &>/dev/null; then
    printf '%s' "$text" | python3 -c '
import re
import sys

data = sys.stdin.read()
patterns = [
    (r"(\bAuthorization\s*:\s*Bearer\s+)[^\s\"'"'"'`&;]+", r"\1***REDACTED***"),
    (r"(\bBearer\s+)[^\s\"'"'"'`&;]+", r"\1***REDACTED***"),
    (r"(\s--?(?:api[_-]?key|password|passwd|secret|token)\s+)[^\s\"'"'"'`&;]+", r"\1***REDACTED***"),
    (r"\b([A-Za-z0-9_:-]*(?:api[_-]?key|password|passwd|secret|token)[A-Za-z0-9_:-]*\s*[:=]\s*)(\"[^\"]*\"|'"'"'[^'"'"']*'"'"'|[^\s\"'"'"'`&;]+)", r"\1***REDACTED***"),
]
for pattern, repl in patterns:
    data = re.sub(pattern, repl, data, flags=re.IGNORECASE)
sys.stdout.write(data)
'
    return 0
  fi

  printf '%s' "$text" \
    | sed -E 's/([Aa]uthorization[[:space:]]*:[[:space:]]*[Bb]earer[[:space:]]+)[^[:space:]"'\''`&;]+/\1***REDACTED***/g' \
    | sed -E 's/([Bb]earer[[:space:]]+)[^[:space:]"'\''`&;]+/\1***REDACTED***/g' \
    | sed -E 's/([[:space:]]--?(api[_-]?key|password|passwd|secret|token)[[:space:]]+)[^[:space:]"'\''`&;]+/\1***REDACTED***/Ig' \
    | sed -E 's/([A-Za-z0-9_:-]*(api[_-]?key|password|passwd|secret|token)[A-Za-z0-9_:-]*[[:space:]]*[:=][[:space:]]*)[^[:space:]"'\''`&;]+/\1***REDACTED***/Ig'
}
