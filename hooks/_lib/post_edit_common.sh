#!/usr/bin/env bash
# Shared helpers for post-edit quality and history detectors.

vg_post_edit_append_warning() {
  local warning="$1"
  [[ -n "$warning" ]] || return 0
  WARNINGS="${WARNINGS:+${WARNINGS}
---
}${warning}"
}

# Reads NEW_STRING from stdin; outputs lines NOT suppressed by the rule.
# Suppression: a line is suppressed when the immediately preceding line
# contains "vibeguard-disable-next-line RULE_ID" (any comment prefix).
vg_filter_suppressed() {
  local rule="$1"
  # trisq passed via -v so that ''' never appears inside the single-quoted awk body.
  awk -v rule="$rule" -v trisq="'''" '
    BEGIN { suppress = 0; in_template = 0; in_triple_dq = 0; in_triple_sq = 0 }
    {
      # Record multiline-string state at the START of this line so a
      # disable comment that is itself inside a string is not honoured.
      start_in_ml = (in_template || in_triple_dq || in_triple_sq)

      # Track JS/TS template-literal depth via backtick parity.
      tmp = $0; n = gsub(/`/, "", tmp)
      if (n % 2 == 1) in_template = 1 - in_template

      # Track triple-double-quote multi-line strings (Python, Rust raw).
      tmp = $0; n = gsub(/"""/, "", tmp)
      if (n % 2 == 1) in_triple_dq = 1 - in_triple_dq

      # Track triple-single-quote multi-line strings (Python).
      tmp = $0; n = gsub(trisq, "", tmp)
      if (n % 2 == 1) in_triple_sq = 1 - in_triple_sq

      if (suppress) { suppress = 0; next }
      if (!start_in_ml &&
          $0 ~ "^[[:space:]]*(//|#)[[:space:]]*vibeguard-disable-next-line[[:space:]]+" rule "([[:space:]]|--|$)") {
        suppress = 1
      }
      print
    }
  '
}
