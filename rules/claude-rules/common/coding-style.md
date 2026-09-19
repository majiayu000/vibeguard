# General coding rules

These rules apply within the user's requested scope. They guide review; they are not universal runtime gates.

## U-01: Respect the requested contract (strict)
Preserve the API, response shape and externally observable behavior that the task requires. When the user authorizes a breaking change, update the affected consumers directly; do not add compatibility layers unless requested.

## U-02: Extract abstractions for a concrete shared responsibility (guideline)
Choose an abstraction when it makes the current behavior easier to understand, change or verify. Similar syntax and repetition counts do not prove shared semantics. Readable duplication, macros and direct field copying can all be appropriate.

## U-04: Keep changes within the authorized task (strict)
Complete the requested work without adding unrelated features, renames, formatting or architectural cleanup. Broad refactoring is appropriate when explicitly requested. Do not turn incidental observations into additional work.

## U-05: Establish ownership and consumers before deleting code (guideline)
Check references, exports, public entrypoints and the task's intended outcome before calling code unused. Delete it when the evidence and existing authorization support deletion; ask only when an unresolved contract would change that decision.

## U-06: Choose dependencies by the actual requirement (guideline)
Prefer suitable existing code and standard-library facilities. Consider correctness, security, maintenance and deployment costs before adding a dependency. Avoid reimplementing cryptography or complex parsers merely to avoid a dependency.

## U-10: Clarify material uncertainty and exercise routine judgment (strict)
Ask when missing facts materially change scope, authorization or correctness. Reuse answers and authorization already provided. Resolve routine implementation choices from the repository and task instead of repeatedly requesting permission.

## U-16: Review responsibility rather than file length (guideline)
Split a file when its responsibilities hinder the requested change or verification. Line counts alone do not establish a defect or authorize a refactor. A project may use its own explicit lint limits; VibeGuard has no global size threshold.

## U-18: Validate data at its trust boundary (strict)
Validate untrusted input against the actual contract before relying on it. Make missing or malformed required data visible. Avoid repeating the same validation through internal layers that already share a trusted representation.

## U-19: Follow existing data-access boundaries (guideline)
Use the project's established ownership and access patterns. Do not introduce a Repository layer, service or cache abstraction unless the current requirement needs it.

## U-21: Follow the project's commit convention (guideline)
When asked to commit, group coherent changes and follow the repository's convention. Keep unrelated work out of the commit. This rule does not itself request a commit or require separate commits for every mechanical change.

## U-22: Select checks for the changed behavior (strict)
Use the project's commands and the change's risk to select meaningful verification. Cover changed contracts and likely regressions. Do not manufacture tests for low-impact edits, repeat passing checks without new evidence, or impose universal coverage percentages.

## U-26: Connect promised behavior to real consumers (strict)
When changing configuration, persistence or an interface, check the actual lifecycle and consumers needed for the promised behavior. Valid defaults, lazy initialization, delegated effects and shutdown-time persistence are legitimate. Names or startup text alone cannot prove integration.

## U-32: Review conflicting or irrelevant instructions (guideline)
When instruction problems affect a task, identify conflicting requirements, duplication, broad triggers and outdated facts. A file inventory is not proof of what the model loaded. Do not judge quality by rule counts or create another policy engine.

## U-33: Choose navigation for the current search (guideline)
Use text search, symbol navigation or an index according to the question and repository. Start with available tools and inspect the relevant evidence. Repository size or search count does not mandate a vector database, structural index or new service.
