#!/usr/bin/env bash
# RS-14: Statement-Perform Gap Detection (ast-grep version)
#
# Detect the case where the Config type is initialized through Default::default() instead of the load() method.
# Use ast-grep AST level scanning to eliminate the full false positive problem of previous grep versions.
#
# Usage:
#   bash check_declaration_execution_gap.sh [--strict] [target_dir]

set -euo pipefail

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

if ! command -v ast-grep >/dev/null 2>&1; then
  echo "[RS-14] SKIP: ast-grep is not installed (installation method: brew install ast-grep)"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[RS-14] SKIP: python3 is not available"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"
TMPFILE=$(create_tmpfile)

TEST_PATH_PATTERN='((^|/)tests[/._]|/test_|_test\.rs$|tests\.rs$|test_helpers\.rs$|(^|/)examples/|(^|/)benches/)'

# Detect *Config::default() usage (exclude test paths)
# Only reported when the corresponding Config type has a load() method to avoid false positives of legal default-only Config
export VG_TARGET_DIR="${TARGET_DIR}"

_ASG_TMPOUT=$(create_tmpfile)
if ! ast-grep scan \
    --rule "${RULES_DIR}/rs-14-config-default.yml" \
    --json \
    "${TARGET_DIR}" > "${_ASG_TMPOUT}"; then
  echo "[RS-14] WARN: ast-grep scan failed (the rule file may be missing), skipping detection" >&2
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
  exit 0
fi

python3 -c '
import json, sys, re, subprocess, os

TEST_PATH = re.compile(r"((^|/)tests[/._]|/test_|_test\.rs$|tests\.rs$|test_helpers\.rs$|(^|/)examples/|(^|/)benches/)")
target_dir = os.environ.get("VG_TARGET_DIR", ".")

data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
try:
    matches = json.loads(data)
except Exception as e:
    print("[RS-14] WARN: ast-grep JSON parsing failed: " + str(e), file=sys.stderr)
    sys.exit(1)

load_cache = {}

def has_load_method(full_type_path, search_dir):
    """Check if the Config type has a load() method.

    full_type_path preserves module namespace (e.g. "config::AppConfig") so that
    same-named Config types in different modules do not pollute each other cache
    entries or impl-file search results.
    """
    if full_type_path in load_cache:
        return load_cache[full_type_path]

    bare_type = full_type_path.split("::")[-1]
    module_parts = full_type_path.split("::")[:-1]

    try:
        all_impl_files = subprocess.run(
            ["grep", "-rEl", r"impl.*\b" + re.escape(bare_type) + r"\b", "--include=*.rs", search_dir],
            capture_output=True, text=True
        ).stdout.strip().splitlines()

        # Narrow to files whose path is consistent with the module namespace to
        # avoid cross-module pollution when multiple modules define same-named
        # Config types.  Fall back to the full list only when filtering yields
        # nothing (e.g. re-exported types with path aliases).
        if module_parts:
            module_suffix = os.path.join(*module_parts)
            narrowed = [f for f in all_impl_files if module_suffix in f]
            impl_files = narrowed if narrowed else all_impl_files
        else:
            impl_files = all_impl_files

        # Match impl blocks specifically for this Config type (inherent or trait impls).
        # Brace-count to stay within the block, preventing false positives from
        # other types defined in the same file.
        # Match impl header line: allow { on same line, or where clause, or bare line-break.
        # [^<>]*(?:<[^<>]*>[^<>]*)* handles one level of nested generics in the type params.
        _nested_generic = r"[^<>]*(?:<[^<>]*>[^<>]*)*"
        impl_pat = re.compile(
            r"^\s*impl(?:<" + _nested_generic + r">)?\s+(?:[\w:]+(?:<" + _nested_generic + r">)?\s+for\s+)?(?:\w+::)*"
            + re.escape(bare_type) + r"(?:<" + _nested_generic + r">)?\s*(?:\{|where\b|$)"
        )
        load_pat = re.compile(r"\bfn\s+load\s*\(")
        for impl_file in impl_files:
            try:
                with open(impl_file, "r", errors="ignore") as fh:
                    lines = fh.readlines()
                i = 0
                while i < len(lines):
                    if impl_pat.search(lines[i]):
                        depth = lines[i].count("{") - lines[i].count("}")
                        j = i + 1
                        # Handle where clause / line-broken brace: scan until we enter the block.
                        while j < len(lines) and depth <= 0:
                            depth += lines[j].count("{") - lines[j].count("}")
                            j += 1
                        # Scan inside the impl block for fn load.
                        while j < len(lines) and depth > 0:
                            depth += lines[j].count("{") - lines[j].count("}")
                            if load_pat.search(lines[j]):
                                load_cache[full_type_path] = True
                                return True
                            j += 1
                    i += 1
            except Exception:
                pass
    except Exception:
        pass
    load_cache[full_type_path] = False
    return False

for m in matches:
    f = m.get("file", "")
    if TEST_PATH.search(f):
        continue
    text = m.get("text", "").strip()
    # Extract full qualified path before ::default(), preserving module namespace.
    # Handles plain, path-qualified, and turbofish forms:
    #   AppConfig::default()
    #   config::AppConfig::default()
    #   AppConfig::<Prod>::default()          (turbofish pattern in yml)
    #   config::AppConfig::<Prod>::default()
    config_match = re.search(r"((?:\w+::)*\w+)::(?:<[^<>]*(?:<[^<>]*>[^<>]*)*>::)?default\(\)\s*$", text)
    if not config_match:
        continue
    full_type_path = config_match.group(1)  # e.g. "config::AppConfig" or "AppConfig"
    bare_type = full_type_path.split("::")[-1]
    if not bare_type.endswith("Config"):
        continue
    if not has_load_method(full_type_path, target_dir):
        continue
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    msg = m.get("message", "")
    print("[RS-14] " + f + ":" + str(line) + " " + msg + " (" + text + ")")
' < "${_ASG_TMPOUT}" > "$TMPFILE" || {
  echo "[RS-14] WARN: python3 processing failed, skipping detection" >&2
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
  exit 0
}

# RS-14 persistence-method check: verify save/load/persist/restore are called at startup.
# Fix (Issue 3): scan src/bin/*.rs alongside main.rs/lib.rs; remove head -5 truncation
#   so workspace members with >5 startup files or bin/ entrypoints are fully covered.
# Fix (Issue 1): per-(type,method) tracking — python3 extracts the impl-type name for
#   each declaration so that an unrelated load( call on a different type cannot satisfy
#   the check (false-negative where "anything named load" collapses to one _called flag).
# Fix (Issue 2): inline // comment stripping + string-literal exclusion in call-site
#   grep so that `foo(); // load(` and `"load("` do not count as startup invocations.
_pm_startup_files=()
while IFS= read -r _f; do
  [[ -f "${_f}" ]] && _pm_startup_files+=("${_f}")
done < <(find "${TARGET_DIR}" \
    \( -name 'main.rs' -o -name 'lib.rs' -o -path '*/bin/*.rs' \) \
    -not -path '*/target/*' \
    -not -path '*/examples/*' \
    -not -path '*/benches/*' \
    -not -path '*/tests/*' \
    2>/dev/null)

if [[ ${#_pm_startup_files[@]} -gt 0 ]]; then
  for _method in save load persist restore; do
    # Extract all impl-type names that declare fn <_method>( in production code.
    # python3 tracks brace-depth to stay inside each impl block, preventing
    # cross-type pollution when multiple types in the same file define the same
    # method name.  Only production (non-test, non-example) files are scanned.
    _decl_types=$(python3 - "${_method}" "${TARGET_DIR}" <<'PYEOF'
import sys, re, subprocess

method  = sys.argv[1]
tgt_dir = sys.argv[2]

TEST_PATH = re.compile(r'((^|/)tests[/._]|/test_|_test\.rs$|tests\.rs$|(^|/)examples/|(^|/)benches/)')

try:
    res = subprocess.run(
        ["grep", "-rlE", r"fn\s+" + re.escape(method) + r"\s*\(",
         "--include=*.rs",
         "--exclude-dir=target", "--exclude-dir=examples",
         "--exclude-dir=benches", "--exclude-dir=tests",
         tgt_dir],
        capture_output=True, text=True
    )
    decl_files = [f for f in res.stdout.strip().splitlines() if not TEST_PATH.search(f)]
except Exception:
    sys.exit(0)

_ng = r"[^<>]*(?:<[^<>]*>[^<>]*)*"
impl_pat = re.compile(
    r'^\s*impl(?:<' + _ng + r'>)?\s+'
    r'(?:[\w:]+(?:<' + _ng + r'>)?\s+for\s+)?'
    r'(\w+)(?:<' + _ng + r'>)?\s*(?:\{|where\b|$)'
)
method_pat  = re.compile(r'\bfn\s+' + re.escape(method) + r'\s*\(')
comment_pat = re.compile(r'^\s*(//|/\*|\*)')

types_found = set()
for filepath in decl_files:
    try:
        with open(filepath, 'r', errors='ignore') as fh:
            lines = fh.readlines()
    except Exception:
        continue
    i = 0
    while i < len(lines):
        m = impl_pat.search(lines[i])
        if m:
            type_name = m.group(1)
            depth = lines[i].count('{') - lines[i].count('}')
            j = i + 1
            while j < len(lines) and depth <= 0:
                depth += lines[j].count('{') - lines[j].count('}')
                j += 1
            while j < len(lines) and depth > 0:
                depth += lines[j].count('{') - lines[j].count('}')
                if method_pat.search(lines[j]) and not comment_pat.search(lines[j]):
                    types_found.add(type_name)
                    break
                j += 1
            i = j
        else:
            i += 1

for t in sorted(types_found):
    print(t)
PYEOF
    )
    [[ -z "${_decl_types}" ]] && continue

    # For each declaring type, verify a call anchored to that specific type exists
    # in at least one startup file.  Five-stage filter pipeline per startup file:
    #  1. initial grep: require Type:: or . prefix so the match is anchored to this type
    #  2. drop full-line comment/doc lines (// /* *)
    #  3. drop fn-declaration lines (false call — it's a definition, not invocation)
    #  4. drop lines where the match falls inside an inline // comment
    #  5. drop lines where the match is inside a double-quoted string literal
    while IFS= read -r _type; do
      [[ -z "${_type}" ]] && continue
      _type_called=false
      for _startup in "${_pm_startup_files[@]}"; do
        if grep -E "(${_type}[[:space:]]*::|\.)[[:space:]]*${_method}[[:space:]]*\(" "${_startup}" 2>/dev/null \
            | grep -vE '^\s*(//|/\*|\*)' \
            | grep -vE '\bfn[[:space:]]+'"${_method}"'[[:space:]]*\(' \
            | grep -vE '//.*\b'"${_method}"'[[:space:]]*\(' \
            | grep -vE '"[^"]*\b'"${_method}"'[[:space:]]*\([^"]*"' \
            | grep -q .; then
          _type_called=true
          break
        fi
      done
      if [[ "${_type_called}" == "false" ]]; then
        echo "[RS-14] Persistence method '${_type}::${_method}()' is declared but not called at startup (main.rs / lib.rs / src/bin/*.rs). Fix: invoke ${_type}::${_method}() in the startup path, or add // vibeguard-disable-next-line RS-14 if intentional." >> "$TMPFILE"
      fi
    done <<< "${_decl_types}"
  done
fi

apply_suppression_filter "$TMPFILE"
FOUND=$(wc -l < "$TMPFILE" | tr -d ' ')

if [[ $FOUND -eq 0 ]]; then
  echo "[RS-14] PASS: Config statement-execution gap not detected"
  exit 0
fi

cat "$TMPFILE"
echo ""
echo "Found ${FOUND} potential Config declaration-execution gap(s)."
echo ""
echo "Repair method:"
echo " 1. If Config has a load() method, Config::load() should be called during startup instead of Config::default()"
echo " 2. If Default::default() is indeed the expected behavior (such as testing or default configuration), add a comment"

if [[ "${STRICT}" == true ]]; then
  exit 1
fi
