# Long-Horizon Reliability Rules

## W-42: Verify important invariants across artifact handoffs (guideline)
For repeated edits or handoffs, verify the facts, behavior, formulas, and other properties the user expects to preserve. Choose checks at meaningful milestones and before delivery.

Use the artifact's existing tests or review method. Documents may need fact comparison; spreadsheets may need formula and value checks; code needs focused behavior checks. Deliberately changed semantics should be compared against the requested result.

**FIX / SKIP**: Fix lost requirements or broken invariants. Skip arbitrary iteration counters, universal fidelity percentages, and new comparator infrastructure when existing checks suffice. If an important property cannot be verified, state that limitation rather than inventing a fidelity score.
