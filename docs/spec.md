# VibeGuard Specification — AI-assisted development of an anti-hallucination framework

> Status: historical design snapshot.
> Some implementation details in this document no longer match the current repository layout.
> Current canonical sources:
> - `README.md` — product entry and Core vs Workflow boundary
> - `docs/rule-reference.md` — current public rule/guard summary
> - `schemas/install-modules.json` — install/runtime contract
> - `rules/claude-rules/`, `hooks/`, `guards/`, `scripts/` — implementation source


> Version: 1.0 | Update date: 2026-02-12

## 1. Design philosophy

### 1.1 Core Insight: Reversing the Traditional Line of Defense

Traditional code quality focuses on "developers do not make mistakes"; VibeGuard focuses on "AI-assisted development does not produce hallucinations".

The main failure mode of LLM is not syntax errors (which the IDE can catch), but:
- **Fabricated**: Invent non-existent APIs, file paths, data fields
- **Reinventing the wheel**: Create a new one without searching, resulting in multiple implementations of the same function
- **Naming confusion**: Mix camelCase/snake_case to create aliases
- **Empty Shell Delivery**: Generates a page that looks correct but has empty/hardcoded data
- **Over-engineering**: Adding unnecessary abstractions, compatibility layers, deprecated tags

### 1.2 Core Principles

```
Anti-hallucination = constraint input + verification output + automatic interception
```

| Principle | Meaning |
|------|------|
| Data-driven | Display blank if there is no data, never use fake data |
| Search first, then write | Before creating anything new, you must search for existing implementations |
| Single naming | One name for one concept, no aliases |
| Minimal changes | Just do what is asked, no additional "improvements" |
| Automatic blocking | CI guard automatically blocks known failure modes |

---

## 2. Seven-layer defense architecture

```
┌─────────────────────────────────────────────────────────┐
│ Layer 7: Weekly review (manual) │
│ — Review regression events, update rules, and adjust indicator targets │
├─────────────────────────────────────────────────────────┤
│ Layer 6: Prompt embedded rules (LLM behavior constraints) │
│ — Enforcement rules in CLAUDE.md / Codex instructions │
├─────────────────────────────────────────────────────────┤
│ Layer 5: Skill / Workflow (execution process constraints) │
│   — plan-flow / fixflow / optflow / vibeguard skill      │
├─────────────────────────────────────────────────────────┤
│ Layer 4: Architecture guard testing (AST level automatic detection) │
│ — test_code_quality_guards.py Five Core Rules │
├─────────────────────────────────────────────────────────┤
│ Layer 3: Pre-commit Hooks (interception before submission) │
│ — Name checking, duplicate checking, secret scanning, linting │
├─────────────────────────────────────────────────────────┤
│ Layer 2: Named constraint system (snake_case mandatory) │
│ — check_naming_convention.py + boundary conversion specification │
├─────────────────────────────────────────────────────────┤
│ Layer 1: Anti-duplication system (search first and write later) │
│ — check_duplicates.py + SEARCH BEFORE CREATE rule │
└─────────────────────────────────────────────────────────┘
```

### Layer 1: Anti-duplication system

**Intent**: To prevent the most common failure mode of LLM - creating new without searching.

**rule**:
1. Before creating a new file/class/Protocol/function, you must first search whether there is a similar function in the project
2. Expand if it already exists, don’t create a new one
3. Interfaces shared across modules are placed in `core/interfaces/`
4. Tool functions shared across modules are placed in `core/`
5. The third repetition must be abstract

**Detection Tool**: `check_duplicates.py`
- Scan for duplicate Protocol definitions
- Scan across files of the same class
- Scan module-level functions with the same name
- Support `--strict` mode (CI blocking)

**gap**:
- Only detects name duplication, not semantic duplication (two functions with similar functionality but different names)
- Upgrade path: Integrate LLM semantic similarity analysis

### Layer 2: Named constraint system

**Intent**: Eliminate the problem of mixing camelCase internally in Python.

**rule**:
- Python internally always uses snake_case
- API boundaries (request/response/snapshot) use camelCase
- Use `snakeize_obj()` to convert the entry, and use `camelize_obj()` to convert the exit
- Ban function/class names

**Detection Tool**: `check_naming_convention.py`
- Detect direct use of known camelCase key names in Python code
- Support path exemptions (API output, test files, front-end data construction, etc.)
- Support context exemptions (Pydantic alias, camelize_obj calls, etc.)

**gap**:
- Only checks the list of known key names and cannot capture new camelCase keys
- Upgrade path: changed to AST level detection, matching `dict.get("camelCase")` common pattern

### Layer 3: Pre-commit Hooks

**Intent**: Intercept basic issues before the code reaches the warehouse.

**Detection items**:
| Hook | Function |
|------|------|
| trailing-whitespace | Remove trailing spaces |
| end-of-file-fixer | Make sure the file ends with a newline |
| check-yaml/json/toml | Verify configuration file format |
| check-added-large-files | Prevent large files (>1MB) from being submitted |
| detect-private-key | Detect private key leakage |
| ruff | Python linting + formatting |
| check-naming-convention | snake_case mandatory |
| shellcheck | Shell script quality |
| gitleaks | Secret scan |
| commit message validation | Submission information specifications |

**gap**:
- TypeScript guards depend on the front-end build environment
- Upgrade path: independent TS guard script, does not depend on `bun run lint`

### Layer 4: Architecture guard testing

**Intent**: AST-level automatic detection of five AI vibe-coding regression patterns.

**Five Core Rules**:

| # | Rules | Detection methods |
|---|------|----------|
| 1 | Disable silent swallowing of exceptions | AST checks whether the except block has logging/re-raise |
| 2 | Facade prohibits Any type | AST checks public method parameters and return values |
| 3 | Disable Re-export Shim | AST check if the file has only import + `__all__` |
| 4 | Disallow cross-module private attribute access | Regular check `xxx._private` mode |
| 5 | Duplication of Protocol definitions is prohibited | Regular scanning of Protocols with the same name across files |

**Configuration method**:
- `APP_ROOT`: project root directory
- `APPLICATION_DIRS` / `WORKFLOW_DIRS`: list of scanned directories
- `_PRIVATE_ACCESS_ALLOWLIST`: List of known technical debt exemptions
- `_DUPLICATE_PROTOCOL_ALLOWLIST`: allows duplicate Protocol list

**gap**:
- Rule 5 only detects Protocol and does not detect duplication of common interfaces
- Upgrade path: extended to interface types such as ABC and TypedDict

### Layer 5: Skill / Workflow

**Intent**: Use structured processes to constrain the execution path of AI.

| Skill | Function |
|-------|------|
| `vibeguard` | View the complete anti-hallucination specifications |
| `auto-optimize` | Autonomous optimization process (guard scanning + LLM in-depth analysis + automatic execution) |
| `plan-flow` | Redundancy analysis → Plan construction → Step execution |
| `fixflow` | Engineering delivery flow (Plan → Execute → Test → Submit) |
| `optflow` | Optimization discovery and execution |
| `plan-mode` | Structured plan generation and document implementation |

**Key Constraints**:
- Every workflow requires "analyze/plan first, then execute"
- Each step must have test evidence
- The state machine is strict: `pending → in_progress → completed`
- There can only be one `in_progress` step at a time

**gap**:
- BDD duplicate content between workflows
- Upgrade path: Extract shared BDD modules

### Layer 6: Prompt embedded rules

**Intent**: Implant mandatory rules in the system prompt of LLM.

**Rule source**: `~/.claude/CLAUDE.md` (global) and project `CLAUDE.md`

**Key Rules**:
- No backward compatibility
- No hardcoding
- No aliases are created
- Search first then write
- The third repetition must be abstract
- spec-driven workflow (write spec first for 3+ file changes)

**gap**:
- Rules are scattered in both global and project places, making it difficult to synchronize
- Upgrade path: VibeGuard unified management, setup.sh deployment

### Layer 7: Weekly review

**Intent**: Artificial closed loop, extracting new rules from regression events.

**Review content**:
1. Return events this week (invalid defense line, root cause, new rules)
2. Guard interception statistics (number of interceptions, typical cases)
3. Indicator trends
4. Highlights for next week

**gap**:
- Currently purely manual, no automated indicator collection
- Upgrade path: `metrics_collector.sh` automatically collects basic indicators

---

## 3. Quantitative indicator system

### 3.1 Core indicators

| # | Indicator | Definition | Target | Collection Method |
|---|------|------|------|----------|
| M1 | Regression density | Number of AI hallucination regressions per 100 commits | < 2 | `git log` + manual tagging |
| M2 | Guard interception rate | pre-commit + test number of violations blocked / total number of violations | > 80% | pre-commit log + CI report |
| M3 | Duplicate code rate | Number of duplicate groups reported by `check_duplicates.py` | < 5 groups | `check_duplicates.py` output |
| M4 | Naming Violation Rate | Number of issues reported by `check_naming_convention.py` | 0 | `check_naming_convention.py` Output |
| M5 | Architecture guard pass rate | `test_code_quality_guards.py` Number of passed rules / Total number of rules | 100% | pytest output |

### 3.2 Collection frequency

| Indicator | Frequency | Trigger method |
|------|------|----------|
| M1 | Weekly | Manual review statistics |
| M2 | Each submission | pre-commit hook automatic recording |
| M3 | Each run | `check_duplicates.py` |
| M4 | per commit | pre-commit hook |
| M5 | CI every time | pytest automatically runs |

### 3.3 Alarm threshold

| Indicators | Yellow Alert | Red Alert |
|------|----------|----------|
| M1 | > 2 times/week | > 5 times/week |
| M2 | < 80% | < 60% |
| M3 | > 5 groups | > 10 groups |
| M4 | > 0 | > 5 |
| M5 | < 100% | < 80% |

---

## 4. Execute template

### 4.1 Task startup Checklist

Before starting each development task, you must confirm:

```yaml
task_contract:
  required:
    - objective: "clear and verifiable goal"
    - data_source: "Data source (file/API/database)"
    - acceptance: "Acceptance criteria (at least 1 testable)"
  forbidden:
    - "Write first and then talk"
    - "Probably/might/should work"
    - "Direct copy"
  warnings:
    - no_search_before_create: "Existing implementations are not searched before creating new files/classes/functions"
    - no_test_evidence: "Step completed but no test evidence"
    - large_diff: "More than 300 lines of net changes in a single step"
```

### 4.2 Plan document template

See `workflows/plan-flow/references/plan-template.md`

### 4.3 Review report template

See `skills/vibeguard/references/review-template.md`

### 4.4 CI configuration recommendations

```yaml
# GitHub Actions example (the path is adjusted according to the actual structure of the project)
- name: Run architecture guards
  run: pytest tests/architecture/test_code_quality_guards.py -v

- name: Check duplicates
  run: python ${VIBEGUARD_DIR}/guards/python/check_duplicates.py --strict

- name: Check naming convention
  run: python ${VIBEGUARD_DIR}/guards/python/check_naming_convention.py <APP_ROOT>/
```

---

## 5. Asset topology map

```
vibeguard/
├── docs/spec.md # This file (~500 lines) - complete specification
├── README.md # Quick start (~50 lines)
├── setup.sh # One-click deployment (~30 lines)
│
├── claude-md/
│ └── vibeguard-rules.md # CLAUDE.md Add paragraph (~150 lines)
│
├── skills/vibeguard/
│ ├── SKILL.md # Complete specification Skill (~100 lines)
│   └── references/
│ ├── task-contract.yaml # Task startup Checklist
│ ├── review-template.md # Weekly review template
│ └── scoring-matrix.md # risk-impact scoring matrix
│
├── workflows/
│ ├── auto-optimize/ # Autonomous optimization (shield + spear)
│ │ ├── SKILL.md # Integrate the optimization process of VibeGuard
│ │ └── rules/ # LLM scanning reference rules
│   │       ├── universal.md
│ │ ├── python.md # Contains guard cross-references
│   │       ├── rust.md
│   │       ├── typescript.md
│   │       └── go.md
│ ├── plan-flow/ # Redundancy analysis + plan construction
│   │   ├── SKILL.md
│   │   ├── references/
│   │   │   ├── analysis-playbook.md
│   │   │   ├── risk-impact-scoring.md
│   │   │   ├── plan-template.md
│   │   │   └── plan-accomplishments.md
│   │   └── scripts/
│   │       ├── redundancy_scan.sh
│   │       ├── findings_to_plan.py
│   │       └── plan_lint.py
│ ├── fixflow/SKILL.md # Project delivery flow
│ ├── optflow/SKILL.md # Optimization discovery and execution
│ └── plan-mode/SKILL.md # Plan implementation
│
├── guards/
│   ├── python/
│ │ ├── test_code_quality_guards.py # General version of architecture guards
│ │ ├── check_naming_convention.py # General version naming check
│ │ ├── check_duplicates.py # General version duplication check
│ │ └── pre-commit-config.yaml # pre-commit template
│   ├── rust/
│ │ ├── check_nested_locks.sh # RS-01: Nested lock detection
│ │ ├── check_unwrap_in_prod.sh # RS-03: unwrap/expect detection
│ │ └── check_duplicate_types.sh # RS-05: Cross-file duplicate type detection
│   └── typescript/
│ └── eslint-guards.ts # TS guard template
│
├── templates/language/
│ ├── python-CLAUDE.md # Python project CLAUDE.md template
│ ├── typescript-CLAUDE.md # TS project CLAUDE.md template
│ └── rust-CLAUDE.md # Rust project CLAUDE.md template
│
└── scripts/
    ├── compliance_check.sh # Compliance check
    └── metrics_collector.sh # Metric collection
```

---

## 6. Practical cases

### Case 1: Pro Forma empty header

**Symptom**: Pro Forma page column headers display `1, 2, 3, 4, 5` instead of the actual year date.

**Root Cause**: The Excel parser used a generic number label and did not extract the actual date row as the column header.

**Failed Line of Defense**: Layer 4 (architecture guards do not cover data accuracy)

**Fix**: Modify the header extraction logic and use date rows instead of generic numeric labels.

**New rules**: None (data accuracy requires integration test coverage, not suitable for AST guards).

**Lessons**: AST guards cannot catch semantic errors and need to be coordinated with data validation testing.

### Case 2: Naming mismatch

**Symptoms**: Python internally uses `data.get("askingPrice")` instead of `data.get("asking_price")`,
Causes snakeize_obj to evaluate to None after conversion.

**Root cause**: LLM copied camelCase key names directly from the API documentation without conversion via snakeize_obj.

**Invalid Defense Line**: Layer 2 (check_naming_convention.py successfully intercepted)

**Fix**: Add `snakeize_obj()` call in data entry.

**New rule**: Add `askingPrice` to the `KNOWN_CAMEL_KEYS` dictionary.

**Lesson**: Guards must continually update the list of known keys.

### Case 3: Mixed aliases

**Symptoms**: Both `format_percent` and `format_percentage` exist in the code base,
Some callers using old names cause ImportError.

**Root Cause**: LLM created the function alias `format_percent = format_percentage` as "backward compatibility".

**Breaking Line of Defense**: Layer 6 (the "no aliases" rule in CLAUDE.md prevents this mode)

**Fix**: Select `format_percentage` as the canonical name, replace the caller globally, remove the alias.

**New rule**: Detect module level name assignments in `check_duplicates.py`.

**Lesson**: LLM tends to create compatibility layers rather than direct modifications.

### Case 4: Empty page delivery

**Symptom**: The Property Highlights page in the generated OM document is blank.

**Root cause**: card builder uses `hero_image_url` (building photo) instead of `amenities_map_url` (map),
Causes an empty page to be returned when no data is found.

**Invalid line of defense**: Layer 6 (CLAUDE.md clarifies the usage rules of `amenities_map_url`)

**FIX**: Fixed data source references in card builder.

**New Rule**: Add explicit Page Type → Data Source mapping in CLAUDE.md.

**Lesson**: LLM tends to use field names that "look reasonable" rather than consulting the documentation.

---

## 7. Gaps and Roadmaps

### 7.1 Current Gap

| # | Gap | Impact | Priority |
|---|------|------|--------|
| G1 | Semantic duplication detection (different names but similar functionality) | Unable to capture variant duplications | P1 |
| G2 | Automated indicator collection | Review relies on manual statistics | P1 |
| G3 | TypeScript Guards | TS code missing schema guards | P2 |
| G4 | Runtime data validation | Empty page problem requires integration testing | P2 |
| G5 | Workflow BDD module deduplication | BDD paragraph duplication in fixflow/optflow | P3 |

### 7.2 Roadmap

**Phase 1 (current)**:
- Establish a VibeGuard warehouse to centrally manage all anti-hallucination assets
- setup.sh deploys to ~/.claude/ and ~/.codex/ with one click
- Universal guard template to support quick access to new projects

**Phase 2 (next step)**:
- Automated metric collection (`metrics_collector.sh`)
- TypeScript schema guards (`eslint-guards.ts`)
- ~~Rust project templates and guards~~ ✅ Rust guards completed (RS-01/RS-03/RS-05)

**Phase 3 (Future)**:
- LLM-assisted semantic duplication detection
- Integrated test data validation framework
- Cross-project metrics dashboard

---

## Appendix A: Glossary

| Terminology | Meaning |
|------|------|
| Hallucination | LLM generates output that looks correct but is actually wrong |
| Vibe Coding | A development approach that relies on LLM to "feel" coding rather than verify |
| Guard | Automatically detect and block violating tests or scripts |
| Regression | Previously correct functionality is no longer valid due to new changes |
| AST | Abstract Syntax Tree, abstract syntax tree |
| Pre-commit Hook | Git check script that automatically runs before submission |
| DoR | Definition of Ready, ready definition |
| BDD | Behavior-Driven Development, behavior-driven development |

## Appendix B: References

- [Keep a Changelog](https://keepachangelog.com/)
- [Semantic Versioning](https://semver.org/)
- Lore commit protocol (see `CONTRIBUTING.md`)
- [Ruff](https://docs.astral.sh/ruff/) - Python linting
- [Gitleaks](https://gitleaks.io/) - Secret scanning
- [ShellCheck](https://www.shellcheck.net/) - Shell script analysis
