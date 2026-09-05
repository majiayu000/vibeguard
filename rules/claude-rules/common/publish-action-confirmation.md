# Publish / Destructive-Action Authorization Rules

## W-10: Confirm the concrete action and reuse existing authorization (strict)

Before publishing, deploying, deleting data, or changing an external system, establish the exact target, intended change, and authorization from the user's request and the current conversation. Prepare a concrete, reviewable result before requesting a missing approval.

**Actions requiring this check:**
- Package publication, releases, tags, image pushes, and production deployment.
- Remote commands that modify a system, bulk deletion, and destructive database operations.
- DNS, CDN, domain, and other externally visible configuration changes.

**Execution guidance:**
1. Use an existing explicit approval when it covers the same target, scope, and action. Do not ask again or require a fixed confirmation template.
2. Interpret short approvals such as “ship it” using the concrete result already discussed. If the target or operation is still ambiguous, ask one focused question.
3. Prepare artifacts, inspect differences, and complete independent authorized checks before asking for a missing final approval.
4. Ask again only for a material change in target, scope, risk, or an approval explicitly reserved for a later step. Permission to edit does not imply permission to deploy; permission to create a PR does not imply permission to merge it.
5. Preserve mandatory organizational approvals and runtime safety controls. Conversational authorization does not bypass a configured guard or host permission boundary.
6. Report the actual result with the relevant artifact or deployment evidence.

**Examples:**
- The user approves publishing the already-reviewed package version to the named registry: execute the authorized release without another ritual.
- The user approves a staging change, then the target changes to production: obtain the missing production approval.
- The user requests remote diagnosis only: remain read-only.
- Dry runs and independent read-only preparation can proceed within the requested scope.
