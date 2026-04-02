# OpenAI Harness Engineering — Full Reference

> Source: [Harness Engineering (2026-02-11)](https://openai.com/index/harness-engineering/) | [Unlocking the Codex Harness (2026-02-04)](https://openai.com/index/unlocking-the-codex-harness/) | [Martin Fowler Analysis](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html) | [SmartScope Overview](https://smartscope.blog/en/blog/harness-engineering-overview/) | [InfoQ Report](https://www.infoq.com/news/2026/02/openai-harness-engineering-codex/) | [SuperGok App Server Analysis](https://supergok.com/codex-harness-architecture-app-server/)

---

## Core experiment

The OpenAI Harness team built a production-grade product in 5 months with **zero lines of handwritten code**. 3-7 engineers generate ~1 million lines of code, ~1500 PRs, 3.5 PR per person per day, and development time is about 1/10 of traditional methods.

The core principle: "No manually-written code" became a guiding principle, forcing the team to focus on empowering agents through infrastructure and abstractions rather than direct coding.

> "Humans steer. Agents execute."

The human role shifts from writing code to: designing the environment, specifying intent through prompts, building feedback loops, and diagnosing missing capabilities.

---

## Concept level

Three-level progressive relationship:

- **Prompt Engineering**: Optimize the command text for LLM
- **Context Engineering**: manages all tokens entered into LLM (tools, RAG, memory, schema)
- **Harness Engineering**: Design the entire operating system around the agent

Harness metaphor: prompt is like a verbal command, context is like a map for the horse, and harness is "reins, saddles, fences, and road maintenance"—the infrastructure that prevents unpredictable behavior of the agent.

---

## Three-layer core components

### 1. Context Engineering

Continuously enhanced warehouse knowledge base + dynamic contextual access:

**Chrome DevTools Protocol integration:**
- Agent captures DOM snapshots before and after UI changes
- Autonomous bug reproduction, verification and repair, reasoning about UI behavior
- Each git worktree can start a separate instance for isolated testing

**Observability Exposure:**
- Local temporary stack: Victoria Logs / Victoria Metrics / Victoria Traces
- Query API: LogQL (log), PromQL (metrics), TraceQL (tracing)
- Support prompts such as "Ensure service startup is completed within 800ms"

**The warehouse is a system of record:**
> "Push all relevant team knowledge into the repository as versioned, co-located artifacts. Slack discussions, Google Docs, and tacit human knowledge are invisible to agents."

Information not accessible to the Agent in the context = does not exist.

### 2. Architectural Constraints

**Dependency layer enforcement:**
Types → Config → Repo → Service → Runtime → UI (one-way dependency). Structural testing verifies compliance and prevents hierarchical violations.

**Mechanized invariant execution:**
- Custom linter, error message **directly contains remediation instructions** (remediation instructions)
- Not documented guardrails, but mechanical enforcement
- "Every violation becomes a learning opportunity for the agent"
- Once encoded into rules, they can be universally executed on all agents without repeated manual intervention.

**Taste Invariants code taste enforcement:**
- Structured log enforcement
- Naming convention
- File size limit
- Platform reliability constraints (e.g. Rust: fold if, inline format!, method references over closures, match exhaustive, avoid ANSI blue/yellow)

### 3. Garbage Collection

The team initially spent **20% of their time** manually cleaning up "AI slop" every Friday. Turn to automation after discovering that it cannot be scaled:

- Coding **Golden Principles** (mechanical, opinionated rules)
- Run the background Codex agent regularly:
  -Scan deviation
  - Update quality grades
  - Open targeted reconstruction PR every day
- Most refactoring PRs are automatically reviewed and merged within **1 minute**
- Cleaning throughput scales proportionally to code generation throughput**
- Includes: document inconsistency detection, architectural constraint violation detection, entropy reduction and decay prevention

---

## Four operational quadrants

1. **Architecture Constraints**: Mechanized execution through linter and dependency rules
2. **Feedback Loops**: Observability integration, CI/CD connections, measurable indicators
3. **Workflow Control**: task splitting, parallel execution, permission management
4. **Improvement Cycles**: entropy management, automatic cleaning, document freshness

---

## Golden Principles (High Level)

1. **Executable products first** — Documents must be machine executable (Markdown/JSON/Shell), discussion and design are not within the agent’s field of view = does not exist
2. **Diagnose lack of capabilities rather than reasons for failure** — When the agent is stuck, ask "what is missing" rather than "why it failed", and use boring techniques to let the agent fill it in by itself
3. **Mechanical execution is better than documentation** — linter error messages directly give repair instructions, and you learn from violations.
4. **Give the agent a pair of eyes** — The observability stack allows the agent to automatically reproduce bugs from data
5. **Give a map but not a manual** — Large and comprehensive instructions lead to pattern matching to the local part, and progressive disclosure can guide the overall situation.
6. **Humans steer, agents execute** — Humans set priorities and acceptance criteria, agents perform modifications, run checks, and iterate based on feedback
7. **Repository as system of record** — All knowledge is pushed into the repository as versioned artifacts; Slack discussions, Google Docs, and tacit knowledge are not visible to the agent = do not exist

---

## Golden Principles (specific mechanization rules)

> OpenAI does not disclose the complete list of rules. The following are known specific rules pieced together from the official blog, Martin Fowler analysis, InfoQ reports, and third-party agent-harness repositories.

### Taste Invariants (code taste enforcement)

| Rules | Description |
|------|------|
| Structured log mandatory | Bare print/console is prohibited, structured log must be used |
| Schema/type naming convention | The naming of schemas and types must follow unified conventions |
| File size limit | A single file does not exceed the specified number of lines |
| Rust platform-specific constraints | fold if, inline format!, method reference over closure, match exhaustive, avoid ANSI blue/yellow |
| Prioritize shared tool packages | Use shared utility packages instead of handwritten helpers to keep constants centralized |
| Disable YOLO data probing | Do not guess data shape, must verify at boundaries or rely on typed SDKs |

### Architecture Invariants (architecture constraint enforcement)

| Rules | Description |
|------|------|
| Six-layer one-way dependency | Types → Config → Repo → Service → Runtime → UI, custom linter + structural test enforcement, build failure if violation |
| Custom linter with repair instructions | Error messages are directly injected into the agent context |
| `src/lib/` prohibits UI import | Reusable core logic must not introduce UI components |
| `src/server/` thin boundary layer | The server only delegates, and the core logic is in `src/lib/` |
| Protocol logic is not included in UI components | Communication/protocol processing is separated from the view layer |
| Cross-aspect systems must be centralized | New cross-aspect systems must be explicitly centralized and not decentralized |
| Validation at data boundaries | tRPC procedures must define Zod input schemas |

### GC operation rules

| Rules | Description |
|------|------|
| Encoding golden principles into executable rules | Each principle corresponds to a detectable linter/test |
| The background Codex agent regularly scans for deviations | Scans the code base to compare rules and detect violations |
| Automatically open directional reconstruction PR for violations | Most PRs will be automatically reviewed and merged within 1 minute |
| Daily execution | Prevent bad patterns from accumulating, and scale cleaning throughput in proportion to generation throughput |
| Coverage | Document inconsistency detection, architectural constraint violation detection, entropy reduction and decay prevention |

### Workflow rules

| Rules | Description |
|------|------|
| AGENTS.md ~100 lines | Acts as a table of contents (map) rather than an encyclopedia, pointing to docs/ for deeper documentation |
| Progressive Disclosure | Global → Project level → Current directory, the last overwrites the previous |
| AGENTS.override.md | Allow temporary instructions to take priority, suitable for long-term experiments |
| Hardcoding of keys is prohibited | Use environment variables `${VAR_NAME}` or secure storage |
| Synchronous updates of documentation and configuration | Documented behavior must be consistent with the actual system configuration |
| compact PR + fast feedback | Not blocked for perfection, follow-up correction cost is low |
| Each agent requires an independent identity document | Non-templated identity, mission, and tool documents |

### Observability rules

| Rules | Description |
|------|------|
| Chrome DevTools Protocol integration | Agent captures DOM snapshots before and after UI changes to reproduce bugs autonomously |
| Independent observable stack per worktree | Victoria Logs/Metrics/Traces isolated by git branch |
| Queryable API | LogQL (log), PromQL (metric), TraceQL (tracing) |
| Performance constraints can be prompted | For example, "Ensure that service startup is completed within 800ms" becomes an executable command |

### Information source annotation

| Source | Credibility | Content |
|------|--------|------|
| [OpenAI official blog](https://openai.com/index/harness-engineering/) | Authoritative | High-level principles, GC concepts, taste invariants categories |
| [Martin Fowler Analysis](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html) | High | Architecture constraint details, dependency layer design |
| [engineering.fyi Mirror](https://www.engineering.fyi/article/harness-engineering-leveraging-codex-in-an-agent-first-world) | High | Rule execution methods, supplementary details |
| [Tony Lee Interpretation](https://tonylee.im/en/blog/openai-harness-engineering-five-principles-codex) | Medium | ExecPlan standard, structured execution |
| [MattMagg/agent-harness](https://github.com/MattMagg/agent-harness) | Medium (third party) | Specific invariants implementation (tRPC/Zod/ESLint) |
| [InfoQ report](https://www.infoq.com/news/2026/02/openai-harness-engineering-codex/) | Medium | Quantitative data, team size |

> **Note**: OpenAI does not publish the complete list of rules. The above are known rules pieced together from multiple sources, and the actual number of internal rules may be much greater than this.

---

## AGENTS.md Strategy

- **~100 lines**, serves as a **catalogue (map)** rather than an encyclopedia
- Points to deeper structured documentation in the `docs/` directory
- Prevent agent "pattern matching into local rather than intentional navigation"
- Discovery chain: global → project level → current directory (after overwriting before)
- Scope = the entire subtree of the directory where it is located
- AGENTS.override.md allows temporary instructions to take precedence, suitable for long-term experiments

Documentation shifts from "encyclopedia" mode to "catalogue" mode: design documents, architecture maps, quality levels, and execution plans become versioned products of first-class citizens, supporting progressive disclosure rather than overwhelming instructions.

---

## Skills System

Directory structure:
```
skill-name/
├── SKILL.md # Required: YAML frontmatter + Markdown command
├── agents/openai.yaml # Recommended: UI metadata
├── scripts/ # Optional: deterministic scripts
├── references/ # Optional: documents loaded on demand
└── assets/ # Optional: Output resources
```

Progressive Disclosure:
1. **Metadata** (name + description) – always in context (~100 words)
2. **SKILL.md text** — Load when Skill is triggered (< 5k words)
3. **Bundled Resources** — Load on demand (unlimited)

Four-layer discovery chain: repo → user → admin → system

---

## Feedback loop (core learning mechanism)

> "When the agent struggles, we treat it as a signal: identify what is missing — tools, guardrails, documentation — and feed it back into the repository."

**Cycle process:**
```
Agent execution failed/stuck
    ↓
Diagnose missing abilities (not "try harder")
    ↓
Let the Agent build the missing capabilities into the warehouse by itself
    ↓
New capabilities become the infrastructure for all future Agent missions
    ↓
compound growth effect
```

Key: The direction of repair is always to improve the environment (tools, guards, documentation, abstractions), not to improve the prompt. Knowledge must be pushed into the warehouse (a versioned, co-located artifact).

**Correction over Prevention**: Minimum blocking merge gates, short-lived PRs, prioritizing correction over blocking failures.

---

##Multi-Agent collaboration

- **Initializer Agent**: Create progress files (init.sh, claude-progress.txt, feature_list.json) for the first time
- **Coding Agent**: Read progress → Select features → Implement → Submit → Update
- feature_list.json Only Coding Agent can modify the passes field
- Use JSON instead of Markdown (models are less likely to inappropriately overwrite JSON)
- Agent-to-Agent review (on-premises and cloud)
- Test flake using follow-up run without blocking

**Complete autonomy**: Codex can be executed end-to-end: verify code base status → reproduce bug → record video → implement repair → verify through app interaction → open PR → process feedback → repair failure → merge. Only upgrade when human judgment is required.

---

## Editing format optimization

- hashline format vs apply_patch: success rate from **6.7% → 68.3%**
- Token consumption** reduced by 20%**
- Row-level hashes serve as edit anchors to reduce context matching failures
- Can.ac’s experiment proves: tool interface changes alone can bring 10x improvement

---

## App Server Architecture (Protocol Implementation Layer)

**Communication protocol:**
- Bidirectional JSON-RPC, JSONL over stdio
- Omit the standard JSON-RPC "2.0" version field and retain the method and params structures
- Backward compatibility: old clients can safely connect to new servers

**Message component:**
- Requests：method + params + id
- Responses：echo id + result/error
- Notifications: method + params (no id, used for event streaming)

**Structured primitives (three levels):**
1. **Items**: Single typed event (agent message, user input, tool execution)
2. **Turns**: agent work unit initiated by user operation, containing ordered items
3. **Threads**: persistent session container, supports reconnection and recovery

**Four components:**
- stdio reader
- Codex message processor
- thread manager
- core threads

**Integrated Mode:**
- Local IDE/Desktop: child process + permanent stdio channel
- Web: Backend worker proxy JSON-RPC
- CLI: Unify harness to ensure consistency

---

## Quantify impact

- Can.ac experiment: only tool interface changes, model performance from 6.7% → 68.3%
- LangChain: No model modification, only harness improvement to achieve 13 points improvement
- A single agent run can last 6+ hours (often executed while humans are sleeping)

---

## Unanswered questions

- How will the architectural consistency of a fully agent-generated system evolve over the years?
- How will increased model capabilities reshape the harness approach?
- Will harness replace traditional service templates?
- Do AI systems need more constraints rather than fewer?

---

> "Building software still demands discipline, but the discipline shows up more in the scaffolding rather than the code."
