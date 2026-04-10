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
# Collects startup files into an array with while-read to avoid word-splitting on paths
# containing spaces (replaces the old buggy `for file in $startup_files` pattern).
# Excludes build artifacts (target/) and non-production dirs to avoid false results from
# workspace members or generated code masking a missing call in the real entrypoint.
_pm_startup_files=()
while IFS= read -r _f; do
  [[ -f "${_f}" ]] && _pm_startup_files+=("${_f}")
done < <(find "${TARGET_DIR}" \
    \( -name 'main.rs' -o -name 'lib.rs' \) \
    -not -path '*/target/*' \
    -not -path '*/examples/*' \
    -not -path '*/benches/*' \
    -not -path '*/tests/*' \
    2>/dev/null | head -5)

if [[ ${#_pm_startup_files[@]} -gt 0 ]]; then
  for _method in save load persist restore; do
    # Only flag methods declared in production code; exclude build artifacts and test dirs
    # so that a method declared only in tests/examples never triggers startup enforcement.
    if grep -rqE "fn[[:space:]]+${_method}[[:space:]]*\(" \
        --include='*.rs' \
        --exclude-dir=target \
        --exclude-dir=examples \
        --exclude-dir=benches \
        --exclude-dir=tests \
        "${TARGET_DIR}" 2>/dev/null; then
      _called=false
      for _file in "${_pm_startup_files[@]}"; do
        # Match actual call sites only: strip fn-declaration lines and comment lines first
        # so that `fn load(`, `// load(`, and `/* load(` do not count as a startup call
        # (false negative guard — prevents CI passing when method is never invoked at runtime).
        if grep -E "\b${_method}[[:space:]]*\(" "${_file}" 2>/dev/null \
            | grep -vE "^\s*(//|/\*|\*)" \
            | grep -vE "\bfn[[:space:]]+${_method}[[:space:]]*\(" \
            | grep -q .; then
          _called=true
          break
        fi
      done
      if [[ "${_called}" == "false" ]]; then
        echo "[RS-14] Persistence method '${_method}()' is declared but not called at startup (main.rs / lib.rs). Fix: invoke ${_method}() in the startup path, or add // vibeguard-disable-next-line RS-14 if intentional." >> "$TMPFILE"
      fi
    fi
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
