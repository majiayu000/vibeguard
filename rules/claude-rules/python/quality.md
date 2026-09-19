---
paths: **/*.py,**/pyproject.toml
---

# Python review and tooling

## PY-01: Check unintended mutable defaults (high)
Use Ruff B006 to find shared mutable parameter defaults. Confirm whether shared state was intentional before changing it. The automatic fix can change behavior; do not mechanically replace every default with None.

## PY-03: Consider concurrency for independent async work (guideline)
Parallelize only when operations are independent and ordering, rate limits, cancellation and resource ownership permit it. Sequential await can be correct. Trigger this review for relevant scheduling or performance work, not every async function.

## PY-08: Review dynamic execution at the trust boundary (high)
Check whether untrusted input can reach eval, exec or a dynamic import with unintended authority. The presence of __import__ alone does not establish a vulnerability. Ruff S307/S102 can identify candidates but do not prove exploitability or isolation.

## PY-09: Review mixed responsibilities and difficult control flow (guideline)
Refactor functions or classes when their responsibilities or control flow hinder the requested change and verification. Lines, public-method counts and nesting depth alone do not justify extracting services, mixins or helpers. Keep clear traversals intact.

## PY-11: Make file ownership and cleanup explicit (guideline)
Use a context manager where the current scope owns the file lifetime; Ruff SIM115 can identify candidates. Returning a handle, transferring ownership or using ExitStack can be legitimate. Do not close a resource before its owner is finished.

## PY-13: Remove shims only after checking their contract (guideline)
Before deleting a forwarding module, establish that the relevant migration and callers are updated and that it is not a public entrypoint. Pure re-export syntax is only a clue, not proof that the module is dead.
