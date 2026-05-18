---
name: "VibeGuard: Live Truth"
description: "Verify live claims with fresh facts, inferences, and unresolved gaps"
category: VibeGuard
tags: [vibeguard, verification, live-truth, claims]
argument-hint: "[checklist|latest|pr-ready|merged|running|deployed|published] ..."
---

**Core Concept**
- Turn stateful claims like "latest", "ready to merge", "merged", "running", "deployed", or "published" into fresh evidence.
- Separate observed facts from inferences and unresolved gaps.
- Produce a compact artifact that can be pasted into a final answer or PR comment.

**Steps**

1. Pick the claim type from the user request:
   - `latest`: current git branch freshness against a fetched remote ref
   - `pr-ready`: PR state, draft state, mergeability, CI checks, and review evidence
   - `merged`: remote PR state plus optional local target branch containment
   - `running`: OS process identity plus optional health endpoint
   - `deployed`: live URL/health endpoint plus optional version/ref text
   - `published`: registry/package metadata plus tag, commit, or artifact checksum parity

2. Run the reusable verifier:
   ```bash
   python3 ~/vibeguard/scripts/live_truth.py checklist
   python3 ~/vibeguard/scripts/live_truth.py latest --repo <repo_dir> --remote origin --branch main
   python3 ~/vibeguard/scripts/live_truth.py pr-ready --repo <owner/name> --pr <number>
   python3 ~/vibeguard/scripts/live_truth.py merged --repo <owner/name> --pr <number> --repo-path <repo_dir> --remote origin --branch main
   python3 ~/vibeguard/scripts/live_truth.py running --pid <pid> --health-url <url>
   python3 ~/vibeguard/scripts/live_truth.py deployed --url <url> --expect-text <version-or-ref>
   python3 ~/vibeguard/scripts/live_truth.py published --fixture <metadata.json>
   ```

3. Report the verifier output without upgrading gaps into facts:
   ```text
   LIVE-TRUTH <claim>
   verdict: pass | fail | gap
   facts:
   - ...
   inferences:
   - ...
   unresolved_gaps:
   - ...
   ```

**Rules**
- Fresh evidence is required for mutable claims; memory alone is not proof.
- A `gap` verdict must be stated as unresolved, not treated as success.
- A `fail` verdict blocks claims that the state is ready, merged, live, current, or published.
