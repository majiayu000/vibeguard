#!/usr/bin/env bash
# VibeGuard Rust Guard: Detect duplicate type definitions across files (RS-05)
#
# Scan the names of pub struct/enum and report when types with the same name appear in multiple files.
# Usage:
#   bash check_duplicate_types.sh [target_dir]
# bash check_duplicate_types.sh --strict [target_dir] # If there are duplicates, exit code 1
#
#Exclude: tests/ directory

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

# Allow list
ALLOWLIST_FILE="${TARGET_DIR}/.vibeguard-duplicate-types-allowlist"

declare -A ALLOWLIST
if [[ -f "${ALLOWLIST_FILE}" ]]; then
  while IFS= read -r name; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    ALLOWLIST["${name}"]=1
  done < "${ALLOWLIST_FILE}"
fi

TMPFILE=$(create_tmpfile)

# Extraction: type name file path: line number (processed file by file, compatible with space paths and empty input)
# Use list_rs_prod_files to exclude test files and worktree copies.
list_rs_prod_files "${TARGET_DIR}" \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        # Exclude struct/enum within string literals (r#"..."# or "...")
        grep -nE '^[[:space:]]*pub[[:space:]]+(struct|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "${f}" 2>/dev/null \
          | grep -v 'r#"' \
          | awk -v file="${f}" '{
              split($0, ln, ":")
              s = $0
              sub(/^[0-9]+:.*pub[[:space:]]+(struct|enum)[[:space:]]+/, "", s)
              sub(/[^A-Za-z0-9_].*/, "", s)
              if (s != "") print s " " file ":" ln[1]
            }' || true
      fi
    done \
  | sort \
  > "${TMPFILE}"

# Construct allowed list parameters to awk
ALLOWLIST_AWK=""
for name in "${!ALLOWLIST[@]}"; do
  ALLOWLIST_AWK="${ALLOWLIST_AWK}${name}\n"
done

#Use awk single process to complete grouping, deduplication and reporting
RESULT=$(awk -v allowlist="${ALLOWLIST_AWK}" '
BEGIN {
  n = split(allowlist, arr, "\n")
  for (i = 1; i <= n; i++) if (arr[i] != "") skip[arr[i]] = 1
}
{
  name = $1; loc = $2
  split(loc, parts, ":")
  file = parts[1]
  if (!(name in first_file)) {
    first_file[name] = file
    seen[name, file] = 1
    locs[name] = loc
    file_count[name] = 1
  } else if (!((name, file) in seen)) {
    seen[name, file] = 1
    locs[name] = locs[name] ", " loc
    file_count[name]++
  }
}
END {
  found = 0
  for (name in file_count) {
    if (file_count[name] > 1 && !(name in skip)) {
      printf "[RS-05] Duplicate type: %s\n  Locations: %s\n\n", name, locs[name]
      found++
    }
  }
  if (found == 0)
    print "No duplicate types found."
  else
    printf "Found %d duplicate type(s).\n", found
  if (found > 0) {
    print ""
    print "Repair method:"
    print "1. Extract to the shared module: move the type definition to core/ or shared/, and introduce pub use at each entrance"
    print "2. If they have the same name but different synonyms: rename to distinguish semantics (such as ServerConfig vs DesktopConfig)"
    print "3. If it is a false positive caused by re-export: add to .vibeguard-duplicate-types-allowlist"
  }
  print "EXIT_CODE=" (found > 0 ? "1" : "0")
}
' "${TMPFILE}")

# Output the results (remove the last EXIT_CODE line)
echo "${RESULT}" | grep -v '^EXIT_CODE='

# Extract exit code
SHOULD_FAIL=$(echo "${RESULT}" | grep '^EXIT_CODE=' | cut -d= -f2)
if [[ "${STRICT}" == true && "${SHOULD_FAIL}" == "1" ]]; then
  exit 1
fi
