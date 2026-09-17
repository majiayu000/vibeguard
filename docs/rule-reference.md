# Rule reference

Generated from the canonical Markdown. These are review topics, not claims of automatic enforcement.
The library contains 75 topics; read only those relevant to the task.

| ID | Topic | Scope |
|---|---|---|
| [U-01](../rules/claude-rules/common/coding-style.md) | Respect the requested contract | strict |
| [U-02](../rules/claude-rules/common/coding-style.md) | Extract abstractions for a concrete shared responsibility | guideline |
| [U-04](../rules/claude-rules/common/coding-style.md) | Keep changes within the authorized task | strict |
| [U-05](../rules/claude-rules/common/coding-style.md) | Establish ownership and consumers before deleting code | guideline |
| [U-06](../rules/claude-rules/common/coding-style.md) | Choose dependencies by the actual requirement | guideline |
| [U-10](../rules/claude-rules/common/coding-style.md) | Clarify material uncertainty and exercise routine judgment | strict |
| [U-16](../rules/claude-rules/common/coding-style.md) | Review responsibility rather than file length | guideline |
| [U-18](../rules/claude-rules/common/coding-style.md) | Validate data at its trust boundary | strict |
| [U-19](../rules/claude-rules/common/coding-style.md) | Follow existing data-access boundaries | guideline |
| [U-21](../rules/claude-rules/common/coding-style.md) | Follow the project's commit convention | guideline |
| [U-22](../rules/claude-rules/common/coding-style.md) | Select checks for the changed behavior | strict |
| [U-26](../rules/claude-rules/common/coding-style.md) | Connect promised behavior to real consumers | strict |
| [U-32](../rules/claude-rules/common/coding-style.md) | Review conflicting or irrelevant instructions | guideline |
| [U-33](../rules/claude-rules/common/coding-style.md) | Choose navigation for the current search | guideline |
| [U-11](../rules/claude-rules/common/data-consistency.md) | Resolve shared data consistently across entrypoints | strict |
| [U-31](../rules/claude-rules/common/data-consistency.md) | Invalidate caches when result semantics change | strict |
| [U-29](../rules/claude-rules/common/no-silent-degradation.md) | Do not present failed work as successful | strict |
| [SEC-01](../rules/claude-rules/common/security.md) | Keep untrusted values from changing operation structure | critical |
| [SEC-02](../rules/claude-rules/common/security.md) | Keep secrets out of unauthorized storage and output | critical |
| [SEC-03](../rules/claude-rules/common/security.md) | Render untrusted content safely | high |
| [SEC-04](../rules/claude-rules/common/security.md) | Authorize protected operations and resources | high |
| [SEC-05](../rules/claude-rules/common/security.md) | Check dependencies with current vulnerability data | high |
| [SEC-06](../rules/claude-rules/common/security.md) | Use appropriate cryptography for security purposes | high |
| [SEC-07](../rules/claude-rules/common/security.md) | Keep untrusted paths within the authorized boundary | high |
| [SEC-08](../rules/claude-rules/common/security.md) | Restrict untrusted server-side request targets | high |
| [SEC-09](../rules/claude-rules/common/security.md) | Deserialize untrusted data without unintended execution | high |
| [SEC-11](../rules/claude-rules/common/security.md) | Review security-sensitive changes according to risk | strict |
| [SEC-12](../rules/claude-rules/common/security.md) | Review actual MCP permissions and sensitive changes | strict |
| [SEC-13](../rules/claude-rules/common/security.md) | Preserve high-context files outside authorized changes | strict |
| [SEC-17](../rules/claude-rules/common/security.md) | Review third-party skills and enforce real permissions | strict |
| [SEC-18](../rules/claude-rules/common/security.md) | Keep external content within the authorized task | strict |
| [W-01](../rules/claude-rules/common/workflow.md) | Investigate with evidence and check the original symptom | strict |
| [W-03](../rules/claude-rules/common/workflow.md) | Match completion claims to actual evidence | strict |
| [W-04](../rules/claude-rules/common/workflow.md) | Use test-first development where it helps | guideline |
| [W-05](../rules/claude-rules/common/workflow.md) | Give delegated tasks sufficient relevant context | guideline |
| [W-10](../rules/claude-rules/common/workflow.md) | Reuse authorization and make approval concrete | strict |
| [W-11](../rules/claude-rules/common/workflow.md) | Make important uncertainty clear | guideline |
| [W-12](../rules/claude-rules/common/workflow.md) | Preserve the meaning of verification | strict |
| [W-14](../rules/claude-rules/common/workflow.md) | Avoid conflicting writes to shared state | strict |
| [W-18](../rules/claude-rules/common/workflow.md) | Evaluate outcomes and necessary process boundaries | guideline |
| [W-19](../rules/claude-rules/common/workflow.md) | Keep instructions relevant and maintainable | guideline |
| [W-20](../rules/claude-rules/common/workflow.md) | Record the environment required by a reproducible experiment | guideline |
| [W-37](../rules/claude-rules/common/workflow.md) | Retain useful lessons when memory is part of the task | guideline |
| [GO-01](../rules/claude-rules/golang/quality.md) | Handle meaningful error returns | high |
| [GO-02](../rules/claude-rules/golang/quality.md) | Give goroutines an appropriate lifetime | high |
| [GO-03](../rules/claude-rules/golang/quality.md) | Check actual concurrent access | high |
| [GO-04](../rules/claude-rules/golang/quality.md) | Define interfaces at a useful consumer boundary | guideline |
| [GO-08](../rules/claude-rules/golang/quality.md) | Check when deferred resources are released | high |
| [GO-09](../rules/claude-rules/golang/quality.md) | Review functions with mixed responsibilities | guideline |
| [GO-10](../rules/claude-rules/golang/quality.md) | Review external work during initialization | guideline |
| [GO-11](../rules/claude-rules/golang/quality.md) | Preserve caller cancellation where it applies | high |
| [U-30](../rules/claude-rules/python/pydantic-boundary.md) | Choose unknown-field handling from the data contract | strict |
| [PY-01](../rules/claude-rules/python/quality.md) | Check unintended mutable defaults | high |
| [PY-03](../rules/claude-rules/python/quality.md) | Consider concurrency for independent async work | guideline |
| [PY-08](../rules/claude-rules/python/quality.md) | Review dynamic execution at the trust boundary | high |
| [PY-09](../rules/claude-rules/python/quality.md) | Review mixed responsibilities and difficult control flow | guideline |
| [PY-11](../rules/claude-rules/python/quality.md) | Make file ownership and cleanup explicit | guideline |
| [PY-13](../rules/claude-rules/python/quality.md) | Remove shims only after checking their contract | guideline |
| [RS-01](../rules/claude-rules/rust/quality.md) | Review lock ordering and lifetime | high |
| [RS-02](../rules/claude-rules/rust/quality.md) | Keep read-modify-write operations consistent | high |
| [RS-03](../rules/claude-rules/rust/quality.md) | Make panic and error propagation intentional | guideline |
| [RS-05](../rules/claude-rules/rust/quality.md) | Keep type identity consistent with domain meaning | guideline |
| [RS-08](../rules/claude-rules/rust/quality.md) | Use ownership and Clippy to assess unnecessary clones | guideline |
| [RS-09](../rules/claude-rules/rust/quality.md) | Optimize formatting only on a demonstrated hot path | guideline |
| [RS-12](../rules/claude-rules/rust/quality.md) | Keep ownership of shared mutable facts clear | high |
| [RS-20](../rules/claude-rules/rust/quality.md) | Check affected boundaries after type changes | strict |
| [TS-01](../rules/claude-rules/typescript/quality.md) | Use type tooling for unsafe escapes | guideline |
| [TS-02](../rules/claude-rules/typescript/quality.md) | Assign responsibility for Promise completion and failure | high |
| [TS-03](../rules/claude-rules/typescript/quality.md) | Use deliberate equality semantics | guideline |
| [TS-04](../rules/claude-rules/typescript/quality.md) | Review components with mixed responsibilities | guideline |
| [TS-06](../rules/claude-rules/typescript/quality.md) | Keep Effects and their dependencies accurate | high |
| [TS-07](../rules/claude-rules/typescript/quality.md) | Optimize rendering when there is demonstrated cost | guideline |
| [TS-11](../rules/claude-rules/typescript/quality.md) | Handle missing values according to the contract | high |
| [TS-13](../rules/claude-rules/typescript/quality.md) | Reuse genuinely shared behavior | guideline |
| [TS-14](../rules/claude-rules/typescript/quality.md) | Keep mocks aligned with affected contracts | high |
