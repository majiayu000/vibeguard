# Publish / Destructive-Action Confirmation Rules

## W-10: Require four confirmations before publish, deletion, or remote deploy (strict)

Before any irreversible or high-risk action, confirm four items with the user and wait for explicit approval.

**Trigger actions**:
- `cargo publish`, `npm publish`, or `pypi upload`
- `gh release create` or Git tag creation
- `ssh` remote commands that are not read-only
- `docker push` or production deployment
- `rm -rf` or bulk file deletion
- Database `DROP`, `TRUNCATE`, or bulk `DELETE`
- DNS, CDN, or domain-configuration changes

**Four-point checklist**:

### 1. Target artifact
Clearly state what will be published, deleted, or deployed.
```
Publish target: my-crate v0.3.1 -> crates.io
```

### 2. Change scope
Summarize the changes included in this operation.
```
Scope:
- Adds the insights command
- Fixes session-ingestion retry logic
- 3 files changed, 0 breaking changes
```

### 3. Untouched items
State what this operation must not affect so the user can verify the boundary.
```
Untouched:
- Existing CLI command interfaces remain unchanged
- Database schema remains unchanged
- Environment variables remain unchanged
```

### 4. Execution approval
Ask directly and wait for an explicit affirmative response.
```
If the summary above is correct, I will run `cargo publish`. Continue?
```

**Template**:
```
--- Publish Confirmation ---
Target: [artifact and target environment]
Scope: [summary of change set]
Untouched: [what must remain unaffected]
Command: [command that will be executed]
---
Do you approve execution?
```

**Anti-patterns**:
- The user says "ship it" and you immediately run `cargo publish` without the checklist.
- You SSH into a server and edit config files without confirming target and scope.
- You bulk-delete files without listing what will be removed.

**Exceptions**:
- Local or development-only targets (`localhost`, `dev`) can skip the checklist.
- `--dry-run` commands can run directly because they do not create side effects.
- Repeated operations already explicitly approved in the same conversation (for example, "future patch versions can be released directly").

**Mechanical checks (agent execution rules)**:
- If a command matches one of the trigger actions, interrupt execution.
- Fill out the four-point confirmation template and show it to the user.
- Only continue after the user gives an explicit yes.
- Report the result afterward, including success/failure and artifact links when relevant.
