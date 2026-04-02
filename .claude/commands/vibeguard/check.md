---
name: "VibeGuard: Check"
description: "Run all guard scripts with one click and output project health report"
category: VibeGuard
tags: [vibeguard, check, guard, quality]
argument-hint: "[project_dir]"
---

<!-- VIBEGUARD:CHECK:START -->
**Core Concept**
- Quickly and non-invasively check the code health of your current project
- Automatically detect the project language and run the corresponding guard script
- Output structured reports, sorted by severity
- Can be run at any time during the coding process to verify that modifications do not introduce new problems

**Guardrails**
- Read-only operation, no modification of any files
- No automatic fixes — just report the problem and fix it at the user's discretion
- If the user provides a preflight constraint set baseline, report changes compared to the baseline

**Steps**

1. **Determine project path and language**
   - Project path: User parameters > Current working directory
   - Language detection:
     - `Cargo.toml` → Rust
     - `package.json` → TypeScript/JavaScript
     - `pyproject.toml` / `setup.py` / `requirements.txt` → Python
     - `go.mod` → Go
   - Locate the vibeguard installation path (`~/Desktop/code/AI/tools/vibeguard/` or via the `VIBEGUARD_DIR` environment variable)

2. **Run the guard script corresponding to the language**

   **Rust Project**:
   ```bash
   bash ${VIBEGUARD_DIR}/guards/rust/check_unwrap_in_prod.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/rust/check_duplicate_types.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/rust/check_nested_locks.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/rust/check_workspace_consistency.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/rust/check_single_source_of_truth.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/rust/check_semantic_effect.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/rust/check_taste_invariants.sh <project_dir>
   ```

   **TypeScript/JavaScript Project**:
   ```bash
   # eslint_guards: Automatically run npx eslint --max-warnings=0 when the project has eslint configuration.
   bash ${VIBEGUARD_DIR}/guards/typescript/check_any_abuse.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/typescript/check_console_residual.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/typescript/check_component_duplication.sh <project_dir>
   ```

   **Python Project**:
   ```bash
   python3 ${VIBEGUARD_DIR}/guards/python/check_duplicates.py <project_dir>
   python3 ${VIBEGUARD_DIR}/guards/python/check_naming_convention.py <project_dir>
   python3 ${VIBEGUARD_DIR}/guards/python/test_code_quality_guards.py
   ```

   **Go Project**:
   ```bash
   go vet ./...                                 # vet（MCP go.vet）
   bash ${VIBEGUARD_DIR}/guards/go/check_error_handling.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/go/check_goroutine_leak.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/go/check_defer_in_loop.sh <project_dir>
   ```

   Each guard operates independently, and the failure of one does not affect other guards.

3. **Run Compliance Check**
   ```bash
   bash ${VIBEGUARD_DIR}/scripts/verify/compliance_check.sh <project_dir>
   ```

4. **Summary Report**

   Output format:
   ```
   ══════════════════════════════════
   VibeGuard Health Report
   Project: <project_name>
   Date: <date>
   ══════════════════════════════════

   ┌─ RS-03 unwrap/expect ─────────┐
   │ Found: 50 │
   │ Severity: Moderate │
   └────────────────────────────────┘

   ┌─ RS-05 Repeat Type ──────────────┐
   │ Found: 2 places │
   │ Severity: Moderate │
   │ - SearchQuery (server, core)  │
   │ - AppState (desktop, server)  │
   └────────────────────────────────┘

   ┌─ RS-01 Nested Lock ─────────────────┐
   │ Found: 0 places │
   │ Severity: ✓ Pass │
   └────────────────────────────────┘

   ┌─ RS-06 cross-entry consistency ──────────┐
   │ Found: 2 places │
   │ Severity: Moderate │
   └────────────────────────────────┘

   ┌─ Compliance Inspection ─────────────────────┐
   │ PASS: 3  WARN: 3  FAIL: 2    │
   └────────────────────────────────┘

   Overall rating: 6.5/10
   ```

5. **Comparison with preflight baseline (optional)**
   - If `/vibeguard:preflight` was previously run and a baseline was recorded
   - Compare current data to baseline and mark deteriorating items:
     ```
     ┌─ Baseline comparison ──────────────────┐
     │ unwrap:  50 → 48  ✓ (-2)   │
     │ Repeat type: 2 → 2 = (unchanged) │
     │ Nested lock: 0 → 0 ✓ (unchanged) │
     │ Consistency: 2 → 0 ✓ (-2) │
     └────────────────────────────┘
     ```
   - If there is any deterioration, give a clear warning

**Reference**
- VibeGuard guard script: `vibeguard/guards/`
- VibeGuard compliance check: `scripts/verify/compliance_check.sh`
- Best used with `/vibeguard:preflight`
<!-- VIBEGUARD:CHECK:END -->
