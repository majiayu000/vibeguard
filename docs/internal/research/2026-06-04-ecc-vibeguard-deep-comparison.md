# ECC vs VibeGuard 深度对比

Date: 2026-06-04 18:29 +0800  
Scope: `affaan-m/ECC` current public surface vs local/remote VibeGuard current surface.  
Readiness: analysis only; no install, no hook mutation, no config mutation.

## Executive Summary

ECC 有用，但不是 VibeGuard 的替代品。它是一个横跨 Claude Code、Codex、Cursor、OpenCode、Gemini、Zed 等 harness 的大号 workflow/operator 素材库；VibeGuard 是一个更窄、更硬的防守系统，核心价值在规则、hook、static guard、安装审计、验证和回放。

最准确的采用策略是：**把 ECC 当成参考库和竞争样本，不把它当成可直接叠加到本机的运行时。**

优先级建议：

1. **直接可用但只读运行**: `ecc-agentshield scan`，用于外部视角扫描 Claude/Codex 配置、hooks、MCP、agents、skills。
2. **高价值吸收**: GateGuard fact-forcing、agent harness output contract、selective install/profile 表达、catalog/count validation。
3. **低价值或重复**: 通用 coding/security checklist、常规 TDD/checklist skills，VibeGuard 已有更具体的 guard/validation 路径。
4. **不建议接入**: ECC full/plugin install、raw ECC hooks JSON、continuous-learning/session-memory hooks、Hermes/ECC2 operator control plane。

## Evidence Snapshot

### ECC Snapshot

Commands used:

```bash
gh repo view affaan-m/ECC --json ...
gh api repos/affaan-m/ECC/commits/main
gh api repos/affaan-m/ECC/contents/<dir> --jq length
gh api repos/affaan-m/ECC/actions/runs
gh issue list --repo affaan-m/ECC
gh pr list --repo affaan-m/ECC
npm view ecc-universal --json
npm view ecc-agentshield --json
npm view ecc --json
npm view ecc-install --json
```

Observed facts:

| Item | Value |
| --- | --- |
| Repo | `affaan-m/ECC` |
| Description | agent harness performance optimization system |
| Created | 2026-01-18 |
| Default branch | `main` |
| Current `main` HEAD | `0f84c0e2796703fbda87d577b2636351418c7442` |
| HEAD commit date | 2026-06-03T13:54:30Z |
| License | MIT |
| Primary language | JavaScript |
| Latest stable release via GitHub API | `v1.10.0`, 2026-04-05 |
| Latest prerelease observed | `v2.0.0-rc.1`, 2026-05-25 |
| npm `ecc-universal` | `latest=1.10.0`, `next=2.0.0-rc.1` |
| npm `ecc-agentshield` | `1.4.0` |
| Repo counts via GitHub contents API | `skills=249`, `agents=63`, `commands=79`, `rules=21`, `scripts=43`, `schemas=10`, `manifests=3`, `mcp-configs=1`, `ecc2=4` |
| Latest main CI observed | success on `main` push, 2026-06-03T13:54:35Z |
| Recent risk signals | several PR runs show `action_required`; open issues include Codex plugin path unreliability, context monitor repeated warnings, hook dry-run request, hook JSON validation error |

Important package entrypoint inconsistency:

- npm package is `ecc-universal`, with bins `ecc` and `ecc-install`.
- `npm view ecc` resolves to an unrelated elliptic curve cryptography package.
- `npm view ecc-install` returns 404.
- Therefore docs or postinstall guidance that suggests `npx ecc` or `npx ecc-install` is risky unless the package is explicitly invoked as `ecc-universal` or installed first.

### VibeGuard Snapshot

Commands used:

```bash
git status --short --branch
git rev-parse HEAD
gh repo view majiayu000/vibeguard --json ...
gh api repos/majiayu000/vibeguard/actions/runs
gh release list --repo majiayu000/vibeguard
find/rg over local repo
bash setup.sh packs explain safe-bash
bash setup.sh packs receipt safe-bash --target codex
```

Observed facts:

| Item | Value |
| --- | --- |
| Local branch | `codex/complete-changelog` |
| Local HEAD | `0f99bab55314f03c4b9f07d8b542b056a1ff26a0` |
| Local HEAD subject | `docs: complete changelog entries` |
| Remote repo | `majiayu000/vibeguard` |
| Remote latest release | `v1.1.2`, 2026-06-02 |
| Remote latest main CI observed | success on 2026-06-04T04:34:00Z push |
| Local counts | `skills=7`, `agents=14`, `commands=12`, `rules/claude-rules/*.md=18`, `hooks/*.sh|json=25`, `guards files=37`, `schemas=18`, `tests files=162`, `packs=1` |
| Runtime | `vibeguard-runtime` Rust crate version `1.1.2` |
| Guard Pack boundary | adoption-layer only; dry-run receipt/audit; real Core behavior remains source-of-truth in hooks/rules/manifests |

## Positioning

### ECC

ECC positions itself as a cross-harness operator/workflow system:

- Large catalog of skills, agents, commands, rules, hooks, MCP configs.
- Broad targets: Claude Code, Codex, Cursor, OpenCode, Gemini, Zed, GitHub Copilot-adjacent surfaces.
- Operator direction: Hermes, ECC2 Rust control plane, multi-session dashboard, workflow orchestration, worktree state, MCP layer.
- Strong content/productivity surface: writing, media, social, investor, research, enterprise ops, prediction-market workflows.

ECC's strength is breadth and reusable workflow packaging. Its weakness is that the surface is very broad, install paths are complex, and some public docs/package entrypoints are not crisp enough for safe blind adoption.

### VibeGuard

VibeGuard positions itself as an anti-hallucination enforcement layer:

- Native rules and negative constraints.
- Real-time hooks for dangerous commands, file creation/editing, duplicate files, verification claims, analysis loops.
- Static guards for Rust, TypeScript, Python, Go, and universal codebase issues.
- Install-state, hook manifest, schemas, health checks, release/test gates.
- Explicit product split: Core vs Workflows.

VibeGuard's strength is narrowness plus mechanical enforcement. Its weakness is smaller workflow coverage and less broad operator orchestration.

## Surface-by-Surface Comparison

### 1. Rules

| Dimension | ECC | VibeGuard | Judgment |
| --- | --- | --- | --- |
| Scope | Common + many language/framework rule packs | 7-layer constraint index + numbered U/W/SEC rules + language-specific rules | ECC has broader coverage; VibeGuard has clearer enforcement priority |
| Style | Mostly positive guidance/checklists | Negative constraints and "does not exist" framing | VibeGuard better for anti-hallucination behavior shaping |
| Install | Plugin does not distribute rules automatically; manual copy required in README | `setup.sh` installs native rules and injects L1-L7 summary | VibeGuard has more coherent rule delivery |
| Verifiability | Some CI validators and catalog checks | Static guards, tests, schema contracts, setup health | VibeGuard stronger on rule-to-guard linkage |

What to borrow from ECC:

- Broader language/framework topic coverage as candidate input for future VibeGuard rules.
- Rule packaging/count validation ideas.

What not to borrow:

- Full broad checklist style. VibeGuard should keep high-signal, guardable rules rather than expand into a generic best-practices encyclopedia.

### 2. Hooks

| Dimension | ECC | VibeGuard | Judgment |
| --- | --- | --- | --- |
| Runtime | Mostly Node scripts through Claude plugin/root resolution | Shell hooks + Python helpers + Rust runtime for fast JSON/JSONL and Codex adaptation |
| Events | PreToolUse, PostToolUse, PostToolUseFailure, Stop, SessionStart, SessionEnd, PreCompact | Claude hooks plus Codex native Bash/apply_patch/PermissionRequest/PostToolUse/Stop where supported |
| Main hook ideas | Bash dispatcher, config protection, MCP health, GateGuard fact-force, quality gate, session/activity/cost tracking | pre-bash, pre-edit, pre-write, post-edit, post-write, analysis-paralysis, post-build, stop guard, learn evaluator |
| Blocking philosophy | Mixed: warnings, context monitor, quality gate, fact-force | Explicit pass/warn/block/escalate/correction contracts |
| Codex reality | ECC `.codex/AGENTS.md` still says Codex lacks hooks in one section, while repo has newer Codex configs elsewhere; open issue says Codex plugin path is unreliable | README states exact Codex native surfaces and unsupported Read/Glob/Grep boundary | VibeGuard has clearer Codex boundary |

High-value ECC hook ideas:

- `pre:edit-write:gateguard-fact-force`: first edit/write per file must gather importers, affected public API, schema/date formats, and quote user instruction.
- `pre:config-protection`: block edits to linter/formatter config when the right fix is production code.
- `pre/post:mcp-health-check`: useful conceptually, but VibeGuard should implement as doctor/check, not as invasive runtime hook unless a target exposes reliable MCP failure events.
- `stop:format-typecheck`: batching checks at Stop can reduce edit-time overhead, but VibeGuard already treats Stop carefully to avoid feedback loops.

Adoption decision:

- **Adapt GateGuard, do not copy ECC hooks.json.**
- VibeGuard should implement any fact-forcing gate through existing hook manifest and tests, with per-profile opt-in, latency budget, and false-positive tracking.

### 3. Static Guards and Verification

| Dimension | ECC | VibeGuard | Judgment |
| --- | --- | --- | --- |
| Static guards for arbitrary repos | Mostly skills/checklists plus AgentShield for AI config security | First-class `guards/` tree: universal, Rust, TS, Python, Go, ast-grep | VibeGuard stronger |
| Internal validation | `node tests/run-all.js`, catalog checks, manifest validation, package surface checks | shell/Python/Rust tests, manifest contracts, setup checks, doc path checks, hook perf contracts, release workflow tests | Both serious; VibeGuard more enforcement-specific |
| Coverage claims | Release says thousands of tests; broad package validators | Specific guard tests and CI gating | Both need fresh command evidence before claims |

What to borrow:

- ECC's catalog/count validation discipline for skills/agents/commands can help prevent docs/catalog drift.
- ECC's release gate idea can be compared with VibeGuard `tests/test_release_workflow.sh`.

What VibeGuard already does better:

- Static guard inventory is directly runnable against target projects.
- Guard Pack `receipt/audit/demo` has explicit dry-run and rollback semantics.

### 4. Install and Package Model

| Dimension | ECC | VibeGuard | Judgment |
| --- | --- | --- | --- |
| Installer | `install.sh`, `install.ps1`, npm package, plugin marketplace, selective install manifests | `setup.sh`, prebuilt runtime download, install-state, profiles, health gate | ECC broader; VibeGuard safer |
| Profiles | `minimal`, `core`, `developer`, `security`, `research`, `full` | `minimal`, `core`, `full`, `strict` | ECC has useful segmentation; VibeGuard has stricter operational meaning |
| Dry-run | ECC supports dry-run in installer; open issue asks dry-run for hook/agent execution | Guard Pack receipt/audit is dry-run by design; setup has dry-run paths | VibeGuard should keep pushing this direction |
| Risk | ECC full/plugin install may write broad Claude/OpenCode/Codex surfaces | VibeGuard also mutates user config but has install-state and health checks | Both risky if blindly run; VibeGuard better local audit story |

Important recommendation:

- Do not install ECC into this machine as a global plugin while VibeGuard hooks are active.
- If ECC is evaluated, use a temporary HOME or isolated container/worktree and inspect the dry-run plan.

### 5. Skills and Workflow Surface

| Dimension | ECC | VibeGuard | Judgment |
| --- | --- | --- | --- |
| Breadth | Very broad, 249 skills | Focused, 7 skills + workflows | ECC wins breadth |
| Relevance to VibeGuard | `search-first`, `gateguard`, `agent-harness-construction`, `verification-loop`, `security-review`, `eval-harness`, `ai-regression-testing`, `strategic-compact` | Native `/vibeguard:*`, plan/fix/optflow, iterative retrieval, eval, trajectory review | VibeGuard wins product coherence |
| Risk | Some skills are generic, marketing/content/operator-specific, and not guard-focused | Smaller but easier to verify | VibeGuard should not chase ECC breadth |

Use from ECC:

- `search-first`: already mirrors VibeGuard L1. Use as external confirmation and wording source, not as a new dependency.
- `gateguard`: candidate feature spec for pre-action fact forcing.
- `agent-harness-construction`: useful for schema-first tool output, deterministic observations, and recovery contracts.
- `verification-loop`: useful as a user-facing checklist, but VibeGuard's actual verification should stay command/test backed.

Do not use:

- Business/content/media/operator skills as part of VibeGuard core.
- Skills requiring external APIs unless explicitly scoped and credential-isolated.

### 6. Memory, Learning, and Privacy

| Dimension | ECC | VibeGuard | Judgment |
| --- | --- | --- | --- |
| Learning | Continuous-learning v2, instincts, Stop hooks, session activity | `/vibeguard:learn`, Stop evaluator, scheduled digest in prior design, correction signals | Both have useful ideas, both privacy-sensitive |
| Risk | Broad observation/session/cost tracking hooks can capture sensitive workflows | VibeGuard learning must remain explicit and bounded | Avoid automatic cross-tool telemetry unless user opts in |
| Best boundary | Keep learning local, auditable, exportable, disable-able | Same | Convergent |

Adoption decision:

- Do not import ECC continuous-learning hooks.
- Compare ECC continuous-learning docs only for UX ideas: confidence, import/export, skill evolution, pattern extraction.

### 7. AgentShield

`ecc-agentshield` is separate enough to evaluate as a tool, not as ECC runtime.

Potential value:

- Scans Claude Code configuration, settings, MCP configs, hooks, agent definitions, and skills.
- Could provide an external "security auditor" viewpoint for VibeGuard install surfaces.
- Useful in read-only CI or local audit mode if output is stable.

Risks:

- It depends on Anthropic SDK and other npm packages.
- `--fix` should not be used without a dedicated fixture/audit pass.
- It may not fully understand Codex-specific VibeGuard hook semantics.

Recommended trial:

```bash
npx ecc-agentshield scan --path ~/.claude --format json
npx ecc-agentshield scan --path ~/.codex --format json
```

Only run this in read-only mode first. If results are useful, wrap them in a VibeGuard `doctor`/`check` lane as optional external evidence, not as a blocking default gate.

### 8. ECC2 and Hermes

ECC2 and Hermes are important strategically but not immediately adoptable for VibeGuard:

- ECC2 README says alpha quality, not GA.
- It manages sessions, worktrees, status, daemon, dashboard, observability and risk scoring.
- Hermes setup frames ECC as a reusable substrate behind a broader operator shell for content, sales, finance, research and engineering.

VibeGuard boundary:

- Current VibeGuard sources favor native Claude/Codex hook surfaces and explicit unsupported-surface documentation over adding a new Codex server wrapper layer.
- Therefore ECC2/Hermes should be treated as market/architecture research, not implementation input for VibeGuard Core.

## Quality and Maturity Signals

### Positive ECC Signals

- Active repo with recent main push and successful main CI.
- MIT license.
- Large organized directories: skills, agents, commands, hooks, manifests, schemas, mcp configs.
- Release candidate has explicit boundary language: RC, not final GA.
- Some real engineering hygiene: install manifests, test runner, catalog checks, package allowlist, Windows/adapter issues being actively fixed.

### Negative ECC Signals

- Package/docs entrypoint confusion: `ecc-universal` is the real package, but `ecc` is an unrelated npm package and `ecc-install` is not a package.
- Some open issues are directly relevant to VibeGuard concerns: Codex plugin path unreliability, context monitor repeated false warnings, hook JSON validation failures, dry-run request.
- Very broad scope creates integration risk: content workflows, MCPs, operator shell, billing/pro surfaces, media, social, prediction-market skills.
- Hook graph is large and global; raw adoption would be noisy and hard to debug.
- Star/fork count is not sufficient evidence. Treat popularity as discovery signal only, not quality proof.

### Positive VibeGuard Signals

- Clear product boundary: Core vs Workflows.
- Concrete local install/health/release contract.
- Latest remote main CI observed passing.
- Guard Pack adoption layer is explicitly dry-run/audit/receipt-first.
- Codex hook support is described with known unsupported surfaces.
- Tests are focused on hooks, manifests, setup, guard packs, runtime, and doc contracts.

### VibeGuard Gaps vs ECC

- Smaller skill catalog and less broad onboarding/workflow variety.
- Less polished cross-harness packaging beyond Claude/Codex.
- Less operator-dashboard/session-control story.
- Some CLI UX roughness remains: `bash setup.sh --help` currently reports unknown argument while printing usage.
- Could benefit from catalog/count drift validation for skills/agents/commands similar to ECC.

## What VibeGuard Should Borrow

### P0: Borrow as Design Input Now

1. **GateGuard fact-forcing**
   - Add a VibeGuard spec for optional fact-forcing in `pre-edit-guard` / `pre-write-guard`.
   - Keep it profile-gated, likely `strict` first.
   - Require tests for:
     - first edit per file
     - first new file write
     - destructive bash
     - suppression / timeout / false-positive budget
   - Do not require it on every routine command.

2. **Agent harness output contract**
   - Map tool/check output to `status`, `summary`, `next_actions`, `artifacts`, `root_cause_hint`, `safe_retry`, `stop_condition`.
   - VibeGuard already has schema infrastructure; use that rather than adding a new abstraction.

3. **Selective install UX language**
   - Compare ECC's `minimal/core/developer/security/research/full` with VibeGuard's `minimal/core/full/strict`.
   - Consider whether VibeGuard needs a `security` profile or should keep `strict` as the security-heavy lane.
   - Improve `setup.sh --help` behavior.

4. **Catalog drift checks**
   - Add or extend a check that validates skill/agent/command counts and registry docs if VibeGuard expands workflow count.
   - Avoid hard-coded marketing counts unless CI enforces them.

### P1: Trial in Isolation

1. **AgentShield read-only scan**
   - Run against synthetic fixtures and temporary HOME first.
   - Then run against real `~/.claude` / `~/.codex` only with no `--fix`.
   - Convert useful findings into VibeGuard-native checks.

2. **MCP health idea**
   - Implement as `setup.sh --check` / doctor diagnostics if needed.
   - Do not add as a blocking runtime hook until Codex/Claude event semantics are reliable.

3. **Stop-time batched verification**
   - Explore only if hook latency remains acceptable.
   - Stop hook must not create feedback loops or false "done" claims.

### P2: Track but Do Not Adopt

1. ECC2 control plane.
2. Hermes operator topology.
3. Broad social/media/business skills.
4. Prediction-market / external API workflow packs.
5. Full cross-harness plugin adapters.

## What VibeGuard Should Not Borrow

- Raw ECC hooks JSON.
- ECC plugin install as part of VibeGuard setup.
- Continuous-learning/session observation hooks by default.
- MCP defaults that require multiple networked tools.
- Global `notify`, multi-agent config, or project-local model recommendations.
- Any install command copied from README without verifying package ownership and package name.
- Any broad "AI OS" positioning. It dilutes VibeGuard's defensible wedge.

## Competitive Interpretation

ECC is strong as an ecosystem bundler. It is trying to own the whole agent workbench: prompt/rule packs, skills, hooks, MCPs, operator workflows, dashboard/control plane, and hosted/GitHub App surfaces.

VibeGuard is stronger as a defensive correctness layer. It should not compete by matching ECC's catalog size. It should compete by being:

- more deterministic,
- more audit-friendly,
- more Codex-native,
- more precise about hook/runtime boundaries,
- more conservative about global writes,
- better at turning repeated failures into tests/guards.

The practical relationship is complementary:

- ECC can inspire workflows and broad coverage ideas.
- VibeGuard should enforce the small subset that materially prevents AI coding failures.

## Recommended Execution Plan

### Phase 1: Evidence-Only Intake

- Create a small matrix of ECC candidate assets:
  - `skills/gateguard`
  - `skills/agent-harness-construction`
  - `skills/search-first`
  - `skills/verification-loop`
  - ECC hooks JSON IDs only
  - ECC install profiles manifest
  - `ecc-agentshield`
- Store only links and notes; do not vendor code.

### Phase 2: VibeGuard-Native Specs

Write specs, not code, for:

1. `strict` profile fact-forcing pre-action gate.
2. Optional external AgentShield read-only doctor.
3. Catalog/count drift validation.
4. Setup help/entrypoint polish.

### Phase 3: Implement One Slice at a Time

Recommended order:

1. Fix local UX roughness: `setup.sh --help`.
2. Add catalog/count drift validation if needed.
3. Add fact-forcing gate behind `strict`.
4. Run hook perf benchmark before enabling by default.
5. Trial AgentShield read-only scan against fixtures.

### Phase 4: Reject Scope Creep

Do not add:

- operator dashboard,
- broad MCP bundle,
- social/media/business skills,
- global plugin import,
- hidden telemetry or always-on learning.

## Bottom Line

ECC is worth studying and selectively mining. The best pieces for VibeGuard are not the big catalog or operator shell; they are the engineering patterns around fact-forcing, selective install, manifest validation, and external security scanning.

The default operational answer remains:

```text
Do not install ECC globally.
Do not stack ECC hooks on top of VibeGuard hooks.
Extract ideas, reimplement the few high-signal pieces inside VibeGuard's own hook/manifest/test system.
```

## Source Links

- ECC repo: https://github.com/affaan-m/ECC
- ECC v2.0.0-rc.1 release: https://github.com/affaan-m/ECC/releases/tag/v2.0.0-rc.1
- ECC hooks docs: https://github.com/affaan-m/ECC/blob/main/hooks/README.md
- ECC install profiles: https://github.com/affaan-m/ECC/blob/main/manifests/install-profiles.json
- ECC2 README: https://github.com/affaan-m/ECC/blob/main/ecc2/README.md
- ECC Hermes setup: https://github.com/affaan-m/ECC/blob/main/docs/HERMES-SETUP.md
- ECC AgentShield package: https://www.npmjs.com/package/ecc-agentshield
- VibeGuard repo: https://github.com/majiayu000/vibeguard
- VibeGuard README: `README.md`
- VibeGuard Chinese README: `docs/README_CN.md`
- VibeGuard hook manifest: `hooks/manifest.json`
- VibeGuard install modules: `schemas/install-modules.json`
- VibeGuard safe-bash pack: `packs/safe-bash/pack.yaml`
- VibeGuard routing contract: `workflows/references/routing-contract.md`
