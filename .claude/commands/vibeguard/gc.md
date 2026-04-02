---
name: "VibeGuard: GC"
description: "Garbage collection - log archiving, Worktree cleaning, code garbage scanning"
category: VibeGuard
tags: [vibeguard, gc, cleanup, maintenance]
---

<!-- VIBEGUARD:GC:START -->
**Core Concept** (from OpenAI Harness Engineering)
- AI-generated code produces "slop": empty catch blocks, legacy debugging code, expired TODOs, dead code
- Manual cleaning consumes a lot of man-hours (the Harness team once spent 20% of their time cleaning every Friday)
- Automated GC allows cleaning throughput to scale proportionally with code generation throughput

**Trigger condition**
- Regular maintenance (once a week is recommended)
- When the log file is too large
- After the project code volume increases

**Guardrails**
- Worktrees with unmerged changes will only be warned but not deleted
- Verify JSON format before log archiving, and retain damaged lines in the main file
- Code junk scan only reports and does not automatically repair (repair requires user confirmation)

**Steps**

1. **Log Archive**
   - Run `bash ${VIBEGUARD_DIR}/scripts/gc/gc-logs.sh`
   - events.jsonl archived monthly (gzip) when larger than 10MB
   - Keep the last 3 months, older ones will be automatically deleted
   - Output archive statistics

2. **Worktree Cleanup**
   - Run `bash ${VIBEGUARD_DIR}/scripts/gc/gc-worktrees.sh`
   - Delete worktrees that have been inactive for more than 7 days and have no unmerged changes
   - Only warnings about unmerged changes, listing those that need to be handled manually

3. **Code Junk Scanning**
   - Run `bash ${VIBEGUARD_DIR}/guards/universal/check_code_slop.sh <project directory>`
   - Detect 5 types of AI garbage patterns: null exception handling, legacy debugging code, expired TODO, dead code marking, overlong files
   - Output structured reports

4. **Summary Report**
   ```
   VibeGuard GC Report
   ==================
   Log: Archive XX items, current XX items
   Worktree: Clean X, warn X
   Code garbage: X problems
     - Null exception handling: X
     - Legacy debug code: X
     - Expired TODO: X
     - Dead code mark: X
     - Extra long files: X
   ```

5. **Recommended fix**
   - Provide repair suggestions for each type of garbage problem
   - Can be repaired item by item after user confirmation
   - Run `/vibeguard:check` to verify after fixing

**Reference**
- Log archive: `scripts/gc/gc-logs.sh`
- Worktree cleanup: `scripts/gc/gc-worktrees.sh`
- Code garbage detection: `guards/universal/check_code_slop.sh`
<!-- VIBEGUARD:GC:END -->
