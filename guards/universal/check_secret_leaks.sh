#!/usr/bin/env bash
# VibeGuard Guard — Secret leak detection (SEC-12)
#
# Full credential scanning with:
# - Configurable pattern dictionary
# - Report generation (markdown)
# - Bypass support
# - Staged file scanning (pre-commit) or full project scan
# - External scanning (scan other projects without leaving residues)
#
# Usage:
# bash check_secret_leaks.sh [target_dir]                    # Scan staged files
# bash check_secret_leaks.sh --strict [target_dir]           # exit 1 on violations
# bash check_secret_leaks.sh --full [target_dir]             # Scan all tracked files
# bash check_secret_leaks.sh --score [target_dir]            # Security score
# bash check_secret_leaks.sh --include-env [target_dir]      # Include .env files
# bash check_secret_leaks.sh --external /path/to/project     # Scan externally

set -euo pipefail

# --- Configuration ---
CREDENTIALS_DIR="${VIBEGUARD_CREDENTIALS_DIR:-data}"
REPORTS_DIR="${CREDENTIALS_DIR}/reports"
PATTERNS_FILE="${VIBEGUARD_PATTERNS_FILE:-data/credential-patterns.txt}"
BYPASS_FILE="${CREDENTIALS_DIR}/bypass-scan"
EXTERNAL_MODE=false
OUTPUT_DIR=""

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Defaults ---
TARGET_DIR="."
MODE="staged"  # staged, full, score
STRICT=false
INCLUDE_ENV=false
REPORT_FILE=""

# --- Functions ---
log_info() { printf "${CYAN}[INFO]${NC} %s\n" "$1"; }
log_ok() { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

usage() {
  cat <<'EOF'
Usage: check_secret_leaks.sh [OPTIONS] [target_dir]

Modes:
  (default)         Scan staged files (pre-commit mode)
  --full            Scan all tracked files
  --score           Run security quality check
  --external        External scan (no residues left in target)

Options:
  --strict          Exit with code 1 if violations found
  --include-env     Include .env files in scanning
  --output-dir DIR  Where to save reports (default: data/reports)
  --patterns FILE   Pattern dictionary to use
  -h, --help        Show this help

Examples:
  bash check_secret_leaks.sh                     # Pre-commit scan
  bash check_secret_leaks.sh --strict            # Block on violations
  bash check_secret_leaks.sh --full              # Full project audit
  bash check_secret_leaks.sh --score             # Security grading
  bash check_secret_leaks.sh --external /path    # Scan another project
  bash check_secret_leaks.sh --external --output-dir /tmp/reports /path
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=true
      shift
      ;;
    --full)
      MODE="full"
      shift
      ;;
    --score)
      MODE="score"
      shift
      ;;
    --external)
      EXTERNAL_MODE=true
      MODE="full"
      shift
      ;;
    --include-env)
      INCLUDE_ENV=true
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --patterns)
      PATTERNS_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      log_error "Unknown option: $1"
      usage
      exit 2
      ;;
    *)
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

# --- External mode setup ---
if [[ "$EXTERNAL_MODE" == "true" ]]; then
  # Use output dir or create temp dir
  if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR=$(mktemp -d)
    log_info "External mode: reports will be in $OUTPUT_DIR"
  fi
  REPORTS_DIR="$OUTPUT_DIR"
  # Don't use bypass in external mode
  BYPASS_FILE="/dev/null"
fi

# --- Pattern Loading ---
load_patterns() {
  if [[ ! -f "$PATTERNS_FILE" ]]; then
    log_warn "Dictionary not found at $PATTERNS_FILE"
    log_info "Using built-in patterns"
    PATTERNS=(
      # API Keys
      "sk-[a-zA-Z0-9]{20,}"
      "sk-proj-[a-zA-Z0-9]{20,}"
      "sk-ant-[a-zA-Z0-9]{20,}"
      "AIza[a-zA-Z0-9_-]{35}"
      "AKIA[a-zA-Z0-9]{16}"
      "ghp_[a-zA-Z0-9]{36}"
      "gho_[a-zA-Z0-9]{36}"
      "ghs_[a-zA-Z0-9]{36}"
      "glpat-[a-zA-Z0-9_-]{20,}"
      # Connection strings
      "postgresql://[^:]+:[^@]+@"
      "mysql://[^:]+:[^@]+@"
      "mongodb(\+srv)?://[^:]+:[^@]+@"
      "redis://[^:]+:[^@]+@"
      # Auth
      "Bearer [a-zA-Z0-9._~+/=-]{20,}"
      "eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}"
      # Private keys
      "BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY"
    )
    PATTERN_COUNT=${#PATTERNS[@]}
    return
  fi

  # Load from dictionary file (strip comments and blank lines)
  TMP_PATTERNS=$(mktemp)
  awk '/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next} {sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print}' "$PATTERNS_FILE" > "$TMP_PATTERNS"
  PATTERN_COUNT=$(wc -l < "$TMP_PATTERNS" | xargs)

  if [[ "$PATTERN_COUNT" -eq 0 ]]; then
    log_warn "Dictionary empty, using built-in patterns"
    rm "$TMP_PATTERNS"
    load_patterns
    return
  fi

  log_info "Loaded $PATTERN_COUNT patterns from dictionary"
}

# --- Report Generation ---
generate_report() {
  local status="$1"
  local leak_files="$2"
  local leak_details="$3"
  local scanned_files="$4"
  local file_count="$5"

  mkdir -p "$REPORTS_DIR"
  REPORT_FILE="$REPORTS_DIR/pre-commit-$(date -u +%Y%m%d-%H%M%S).md"

  {
    echo "# Pre-commit Credential Scan"
    echo ""
    echo "- **Date**: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- **Project**: $(basename "$(git rev-parse --show-toplevel)")"
    echo "- **Branch**: $(git branch --show-current)"
    echo "- **Scope**: Staged files only"
    echo "- **Patterns**: $PATTERN_COUNT"
    echo "- **Files scanned**: $file_count"
    echo ""
    echo "## Status: $status"
    echo ""

    if [[ -n "$scanned_files" ]]; then
      echo "### Scanned files"
      echo ""
      echo "$scanned_files"
      echo ""
    fi

    if [[ -n "$leak_files" ]]; then
      echo "### Files with leaks"
      echo ""
      echo "$leak_files"
      echo ""
    fi

    if [[ -n "$leak_details" ]]; then
      echo "### Details"
      echo ""
      echo "$leak_details"
      echo ""
    fi

    if [[ "$status" == BLOCKED* ]]; then
      echo "### Bypass options"
      echo ""
      echo '```'
      echo "touch $BYPASS_FILE"
      echo "git commit"
      echo '```'
    fi
  } > "$REPORT_FILE"
}

# --- Sensitive File Detection ---
check_sensitive_files() {
  local files="$1"

  for f in $files; do
    case "$f" in
      .env|.env.*|.mcp.json|*credentials*|*secrets*|*.pem|*.key|*.p12|*.pfx)
        log_error "SENSITIVE FILE DETECTED: $f"

        mkdir -p "$REPORTS_DIR"
        REPORT_FILE="$REPORTS_DIR/pre-commit-$(date -u +%Y%m%d-%H%M%S).md"

        {
          echo "# Pre-commit Credential Scan"
          echo ""
          echo "- **Date**: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
          echo "- **Project**: $(basename "$(git rev-parse --show-toplevel)")"
          echo "- **Branch**: $(git branch --show-current)"
          echo ""
          echo "## Status: BLOCKED — SENSITIVE FILE"
          echo ""
          echo "### Blocked file"
          echo ""
          echo "- \`$f\`"
          echo ""
          echo "### Fix"
          echo ""
          echo '```'
          echo "git reset HEAD $f"
          echo "echo '$f' >> .gitignore"
          echo '```'
        } > "$REPORT_FILE"

        echo ""
        echo "=========================================="
        echo "  SENSITIVE FILE DETECTED — COMMIT BLOCKED"
        echo "=========================================="
        echo ""
        echo "File: $f"
        echo "Report: $REPORT_FILE"
        echo ""
        return 1
        ;;
    esac
  done
  return 0
}

# --- Scan Logic ---
scan_staged_files() {
  # Change to target directory
  cd "$TARGET_DIR" 2>/dev/null || {
    log_error "Target directory not found: $TARGET_DIR"
    return 1
  }

  # Check for bypass
  if [[ -f "$BYPASS_FILE" ]]; then
    log_warn "BYPASS: Scan skipped (bypass file exists)"
    rm "$BYPASS_FILE"

    mkdir -p "$REPORTS_DIR"
    REPORT_FILE="$REPORTS_DIR/pre-commit-$(date -u +%Y%m%d-%H%M%S).md"

    {
      echo "# Pre-commit Credential Scan"
      echo ""
      echo "- **Date**: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "- **Project**: $(basename "$(git rev-parse --show-toplevel)")"
      echo "- **Branch**: $(git branch --show-current)"
      echo ""
      echo "## Status: BYPASS"
      echo ""
      echo "Scan was bypassed by user."
    } > "$REPORT_FILE"

    echo "Report: $REPORT_FILE"
    return 0
  fi

  # Get staged files
  STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

  if [[ -z "$STAGED_FILES" ]]; then
    log_info "No staged files. Skipping scan."
    return 0
  fi

  # Check for sensitive files first
  check_sensitive_files "$STAGED_FILES" || return 1

  # Load patterns
  load_patterns

  # Scan files
  HAS_LEAK=0
  LEAK_FILES=""
  LEAK_DETAILS=""
  SCANNED_FILES=""
  FILE_COUNT=0

  for f in $STAGED_FILES; do
    # Skip example files
    case "$f" in
      *.example.*|credential-patterns.example.*) continue ;;
    esac

    SCANNED_FILES="$SCANNED_FILES- \`$f\`\n"
    FILE_COUNT=$((FILE_COUNT + 1))

    # Get file content from git
    CONTENT=$(git show :"$f" 2>/dev/null || true)
    if [[ -z "$CONTENT" ]]; then
      continue
    fi

    # Search for patterns
    if [[ -f "${TMP_PATTERNS:-}" ]]; then
      MATCHES=$(echo "$CONTENT" | grep -nEf "$TMP_PATTERNS" 2>/dev/null || true)
    elif [[ -f "$PATTERNS_FILE" ]]; then
      # Load patterns first
      load_patterns
      MATCHES=$(echo "$CONTENT" | grep -nEf "$TMP_PATTERNS" 2>/dev/null || true)
    else
      # Use built-in patterns
      MATCHES=""
      for pattern in "${PATTERNS[@]}"; do
        PATTERN_MATCHES=$(echo "$CONTENT" | grep -nE "$pattern" 2>/dev/null || true)
        if [[ -n "$PATTERN_MATCHES" ]]; then
          MATCHES="${MATCHES}${PATTERN_MATCHES}\n"
        fi
      done
      MATCHES=$(echo -e "$MATCHES" | sed '/^$/d')
    fi

    if [[ -n "$MATCHES" ]]; then
      HAS_LEAK=1
      LEAK_FILES="$LEAK_FILES- \`$f\`\n"
      LEAK_DETAILS="$LEAK_DETAILS\n### \`$f\`\n\`\`\`\n$MATCHES\n\`\`\`\n"
      log_error "LEAK: $f"
    fi
  done

  # Clean up temp patterns file
  [[ -f "${TMP_PATTERNS:-}" ]] && rm "$TMP_PATTERNS"

  # Generate report
  if [[ "$HAS_LEAK" -eq 1 ]]; then
    generate_report "BLOCKED" "$LEAK_FILES" "$LEAK_DETAILS" "$SCANNED_FILES" "$FILE_COUNT"

    echo ""
    echo "=========================================="
    echo "  CREDENTIAL LEAK DETECTED — COMMIT BLOCKED"
    echo "=========================================="
    echo ""
    echo "Report: $REPORT_FILE"
    echo "Bypass: touch $BYPASS_FILE && git commit"
    echo ""

    # Only return 1 in strict mode
    if [[ "$STRICT" == "true" ]]; then
      return 1
    else
      return 0
    fi
  else
    generate_report "PASS" "" "" "$SCANNED_FILES" "$FILE_COUNT"

    log_ok "Credential scan: PASS"
    return 0
  fi
}

# --- Full Project Scan ---
scan_full_project() {
  # Change to target directory
  cd "$TARGET_DIR" 2>/dev/null || {
    log_error "Target directory not found: $TARGET_DIR"
    return 1
  }

  load_patterns

  log_info "Scanning all tracked files..."

  FILES=$(git ls-files 2>/dev/null | grep -v -E '\.env$|\.env\.|\.mcp\.json|node_modules/|\.next/|\.vercel/|\.git/' | grep -v -E '\.pem$|\.key$|\.cert$|\.crt$|credentials|secrets' | grep -v -E '\.example\.')

  FILE_COUNT=$(echo "$FILES" | wc -w | xargs)
  log_info "Scanning $FILE_COUNT files..."

  HAS_LEAK=0
  LEAK_COUNT=0
  LEAK_FILES=""
  LEAK_DETAILS=""

  for f in $FILES; do
    if [[ ! -f "$f" ]]; then
      continue
    fi

    if [[ -f "${TMP_PATTERNS:-}" ]]; then
      MATCHES=$(grep -nEf "$TMP_PATTERNS" "$f" 2>/dev/null || true)
    else
      MATCHES=""
      for pattern in "${PATTERNS[@]}"; do
        PATTERN_MATCHES=$(grep -nE "$pattern" "$f" 2>/dev/null || true)
        if [[ -n "$PATTERN_MATCHES" ]]; then
          MATCHES="${MATCHES}${PATTERN_MATCHES}\n"
        fi
      done
      MATCHES=$(echo -e "$MATCHES" | sed '/^$/d')
    fi

    if [[ -n "$MATCHES" ]]; then
      HAS_LEAK=1
      LEAK_COUNT=$((LEAK_COUNT + 1))
      LEAK_FILES="$LEAK_FILES- \`$f\`\n"
      LEAK_DETAILS="$LEAK_DETAILS\n### \`$f\`\n\`\`\`\n$MATCHES\n\`\`\`\n"
      log_error "LEAK: $f"
    fi
  done

  # Generate report
  mkdir -p "$REPORTS_DIR"
  REPORT_FILE="$REPORTS_DIR/full-project-$(date -u +%Y%m%d-%H%M%S).md"

  {
    echo "# Full Project Scan"
    echo ""
    echo "- **Date**: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- **Scope**: ALL tracked files"
    echo "- **Files scanned**: $FILE_COUNT"
    echo "- **Patterns used**: $PATTERN_COUNT"
    echo ""

    if [[ "$HAS_LEAK" -eq 1 ]]; then
      echo "## Status: RISK FOR DATA LEAKS FOUND ($LEAK_COUNT files)"
      echo ""
      echo "### Files with leaks"
      echo ""
      echo -e "$LEAK_FILES"
      echo "### Details"
      echo ""
      echo -e "$LEAK_DETAILS"
    else
      echo "## Status: CLEAN"
      echo ""
      echo "No credential leaks detected."
    fi
  } > "$REPORT_FILE"

  if [[ "$HAS_LEAK" -eq 1 ]]; then
    echo ""
    echo "=========================================="
    echo "  SCAN COMPLETE: $LEAK_COUNT FILES WITH LEAKS"
    echo "=========================================="
    echo ""
    echo "Report: $REPORT_FILE"
    return 1
  else
    echo ""
    echo "=========================================="
    echo "  SCAN COMPLETE: ALL CLEAN"
    echo "=========================================="
    return 0
  fi
}

# --- Security Score ---
run_security_score() {
  SCORE=0
  MAX_SCORE=100
  FINDINGS=""

  echo "=== Credential Guard Quality Grader ==="
  echo ""

  # 1. Pre-commit hook installed (20 points)
  if [[ -x ".git/hooks/pre-commit" ]]; then
    SCORE=$((SCORE+20))
    echo -e "  ${GREEN}+20${NC} Pre-commit hook installed"
  else
    echo -e "  ${RED}+0${NC}  Pre-commit hook missing"
  fi

  # 2. Credential patterns exist (20 points)
  if [[ -f "$PATTERNS_FILE" ]]; then
    PATTERN_COUNT=$(grep -cve '^\s*$\|^\s*#' "$PATTERNS_FILE" 2>/dev/null || echo 0)
    if [[ "$PATTERN_COUNT" -gt 50 ]]; then
      SCORE=$((SCORE+20))
      echo -e "  ${GREEN}+20${NC} Credential patterns comprehensive ($PATTERN_COUNT patterns)"
    elif [[ "$PATTERN_COUNT" -gt 10 ]]; then
      SCORE=$((SCORE+15))
      echo -e "  ${YELLOW}+15${NC} Credential patterns basic ($PATTERN_COUNT patterns)"
    elif [[ "$PATTERN_COUNT" -gt 0 ]]; then
      SCORE=$((SCORE+10))
      echo -e "  ${YELLOW}+10${NC} Credential patterns minimal ($PATTERN_COUNT patterns)"
    else
      echo -e "  ${RED}+0${NC}  Credential patterns file empty"
    fi
  else
    echo -e "  ${RED}+0${NC}  Credential patterns not found"
  fi

  # 3. .gitignore configured (15 points)
  if [[ -f ".gitignore" ]] && grep -q "data/reports/" .gitignore 2>/dev/null; then
    SCORE=$((SCORE+15))
    echo -e "  ${GREEN}+15${NC} data/reports/ in .gitignore"
  else
    echo -e "  ${RED}+0${NC}  data/reports/ not in .gitignore"
  fi

  # 4. No .env files tracked (15 points)
  ENV_FILES=$(git ls-files 2>/dev/null | grep -E '\.env$|\.env\.' | wc -w | xargs)
  if [[ "$ENV_FILES" -eq 0 ]]; then
    SCORE=$((SCORE+15))
    echo -e "  ${GREEN}+15${NC} No .env files tracked in git"
  else
    echo -e "  ${RED}+0${NC}  $ENV_FILES .env files tracked in git!"
    FINDINGS="$FINDINGS\n  - CRITICAL: $ENV_FILES .env files tracked in git"
  fi

  # 5. No private keys tracked (15 points)
  KEY_FILES=$(git ls-files 2>/dev/null | grep -E '\.pem$|\.key$|\.p12$|\.pfx$' | wc -w | xargs)
  if [[ "$KEY_FILES" -eq 0 ]]; then
    SCORE=$((SCORE+15))
    echo -e "  ${GREEN}+15${NC} No private key files tracked in git"
  else
    echo -e "  ${RED}+0${NC}  $KEY_FILES private key files tracked in git!"
    FINDINGS="$FINDINGS\n  - CRITICAL: $KEY_FILES private key files tracked"
  fi

  # 6. Scan results (15 points)
  if [[ -d "$REPORTS_DIR" ]]; then
    REPORT_COUNT=$(ls "$REPORTS_DIR"/*.md 2>/dev/null | wc -w | xargs)
    if [[ "$REPORT_COUNT" -gt 0 ]]; then
      LATEST=$(ls -t "$REPORTS_DIR"/*.md 2>/dev/null | head -1)
      if [[ -n "$LATEST" ]] && grep -q "CLEAN\|PASS" "$LATEST" 2>/dev/null; then
        SCORE=$((SCORE+15))
        echo -e "  ${GREEN}+15${NC} Latest scan: CLEAN"
      else
        LEAK_COUNT=$(grep -c "LEAK:" "$LATEST" 2>/dev/null || true)
        LEAK_COUNT=${LEAK_COUNT:-0}
        SCORE=$((SCORE+5))
        echo -e "  ${YELLOW}+5${NC}  Latest scan: $LEAK_COUNT leaks detected"
        FINDINGS="$FINDINGS\n  - $LEAK_COUNT credential leaks found in latest scan"
      fi
    else
      echo -e "  ${YELLOW}+0${NC}  No scan reports yet"
    fi
  else
    echo -e "  ${YELLOW}+0${NC}  No scan reports folder"
  fi

  # Grade
  echo ""
  echo "=== Score: $SCORE / $MAX_SCORE ==="
  echo ""

  if [[ "$SCORE" -ge 85 ]]; then
    GRADE="A"
    COLOR=$GREEN
  elif [[ "$SCORE" -ge 70 ]]; then
    GRADE="B"
    COLOR=$GREEN
  elif [[ "$SCORE" -ge 55 ]]; then
    GRADE="C"
    COLOR=$YELLOW
  elif [[ "$SCORE" -ge 40 ]]; then
    GRADE="D"
    COLOR=$YELLOW
  else
    GRADE="F"
    COLOR=$RED
  fi

  echo -e "  Grade: ${COLOR}$GRADE${NC}"

  if [[ -n "$FINDINGS" ]]; then
    echo ""
    echo -e "${CYAN}Findings:${NC}"
    echo -e "$FINDINGS"
  fi

  echo ""
  return 0
}

# --- Main ---
main() {
  case "$MODE" in
    staged)
      scan_staged_files
      ;;
    full)
      scan_full_project
      ;;
    score)
      run_security_score
      ;;
  esac
}

main
