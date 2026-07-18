---
name: specrail-write-product-spec
description: Use when writing or updating a SpecRail product spec for a linked issue. Produces the numbered `product.md` spec from the locale-appropriate template, focusing on user-facing behavior, goals, non-goals, and acceptance criteria without implementation detail.
---

# SpecRail Write Product Spec

Use this skill for the product half of the `write_spec` route.

## Steps

1. Confirm the linked issue number. Search first if no issue is provided.
2. Read `workflow.yaml`, `states.yaml`, `labels.yaml`, and the relevant product
   spec template from `templates/<locale>/product_spec.md` or
   `templates/product_spec.md`.
3. Run the local gate when available:

```sh
python3 checks/route_gate.py --repo . --route write_spec --issue <issue-number> --state ready_to_spec --json
```

4. Pick the depth tier from the length heuristic below, then write
   `docs/specs/GH<issue-number>/product.md`.
5. Keep product content about observable behavior: goals, non-goals, behavior
   invariants, acceptance criteria, edge cases, and open questions.
6. Write behavior as numbered, testable invariants without implementation
   detail, following the density rule and the worked example below.
7. Fill the boundary checklist: every category is either covered by a named
   invariant or explicitly marked N/A with a reason.
8. Keep implementation approach, file ownership, test commands, and rollout
   mechanics for the tech spec or task plan.

## Length heuristic

Length follows complexity, never the template. Do not pad a simple change and
do not compress a gate-contract change.

| Tier | Typical change | Spec size |
| --- | --- | --- |
| trivial | single-file fix, no new behavior contract | minimal spec; declare `complexity: trivial` under the Linked Issue heading and keep only the invariants that actually exist |
| small | one behavior, few states | ~30-60 lines |
| medium | new contract, several failure/authorization states | ~80-150 lines |
| large | multi-component contract, state machine, migration | longer as needed |

If a tier feels ambiguous, pick the higher tier: err toward one more edge
case, not one less.

## Stable invariant IDs

- Number invariants `B-001`, `B-002`, ... consecutively.
- Revisions append new IDs; never renumber, and never reuse a published
  `B-xxx` for a different behavior.
- Downstream artifacts reference these IDs: the tech spec maps every `B-xxx`
  to a verification, and task-plan items carry `Covers: B-xxx`.

## Boundary checklist

Enumerate boundaries before writing invariants, then record the verdict per
category in the spec (a table works well). Every category gets either
`covered: B-xxx` or `N/A + reason`. Silent omission is the failure mode this
checklist exists to kill.

1. Empty / missing input (absent fields, empty lists vs missing keys)
2. Error and failure paths (each failure mode, not "errors are handled")
3. Authorization / permission (and every combination with failure states)
4. Concurrency / race / ordering
5. Retry / repetition / idempotency
6. Illegal state transitions
7. Compatibility / migration (old data, old clients, old specs)
8. Degradation / fallback (is the degraded path allowed to look like success?)
9. Evidence and audit integrity (can a claim pass without its prerequisite
   recorded?)
10. Cancellation / interruption / partial completion

Pay special attention to combinations: the historically expensive misses are
rarely single categories — they are cross products like "authorized + no
prerequisite evidence recorded" or "failed + retried + evidence reused".

## Worked example

The invariants below are the density target. They describe a merge-review
gate: independent review is required before merge; if the reviewer lane fails,
the item degrades instead of silently substituting self-review.

> 1. B-001 每个 merge 候选项必须记录 review 来源，取值为闭集
>    {independent_lane, self_review}；缺失、为空或越界取值时该项判为
>    blocked。
> 2. B-002 reviewer lane 失败（usage limit、崩溃、零输出）时，对应项必须
>    降级为 blocked 或 needs_human，并在 checkpoint 中记录失败事件
>    （lane id、失败类别、证据）。
> 3. B-003 失败事件记录是追加式的：后续成功不得删除或改写已记录的失败。
> 4. B-004 `lane_failures` 为空列表与字段缺失等价，均视为"无失败记录"。
> 5. B-005 基于 self_review 的 merge 必须持有专用授权记录，且授权与队列
>    drain 授权分离；复用队列授权视同无授权。
> 6. B-006 即使授权有效，`review_source: self_review` 且无已记录的 lane
>    失败时仍必须阻断——self-review 只能是失败恢复路径，不能成为跳过
>    独立审查的捷径。
> 7. B-007 失败的 lane 不得在同一项上署名"审查通过"；重试必须使用新的
>    lane id。
> 8. B-008 gate 对已发生的 merge（`merged`）与待 merge（`merge_ready`）
>    施加同一规则；"先斩后奏"的历史记录同样被判为违规。
> 9. B-009 负例 fixture 必须 schema 合法但被 gate 拒绝；schema 非法的
>    负例测不到 gate 逻辑，不算覆盖。
> 10. B-010 兼容：存量 checkpoint 缺少新字段时按保守值处理（等价于
>     "无独立审查"），不得默认放行。
>
> Boundary checklist verdict — Cancellation / interruption: N/A. The gate is
> an offline check with no long-running session state; rerunning it is
> idempotent after interruption. This verdict has no `B-xxx` ID because it is
> not a behavior invariant.

Note how B-006 exists only because B-001 (source recorded) and B-005
(authorization recorded) were combined with "prerequisite evidence absent".
That combination was a real post-merge defect in this repo's history; specs
that stop at B-001/B-005 let it through.

## Density rule

Match the density of the worked example, not the emptiness of the template.
The template supplies structure; this skill supplies depth. Filling one or two
bullets under each heading is slot completion, not a spec. A useful self-check
before finishing: for the boundary checklist's combination categories, either
point at the invariant that pins each cross product down, or write the N/A
reason you would defend in review.

## Boundaries

- Do not write a numbered spec without a linked issue unless a human explicitly
  chooses a non-GitHub workflow.
- Do not translate stable IDs, paths, commands, JSON keys, states, or route
  names.
- Keep human-facing product text in the selected locale; invariant phrasing
  may use natural "当/若…系统应…" or "When/If … the system shall …" style in
  either locale.
- Do not invent invariants to satisfy a length target; the heuristic bounds
  effort, it is not a quota.

## When to Activate

- Activate this route only when the request matches the skill description and the SpecRail router selected it.
- Use it after loading repository instructions, workflow policy, and the current user-authorized scope.

## Red Flags

- Required issue, spec, PR, runtime, or review evidence is missing or stale.
- A proposed action would bypass an offline gate, CI, review, or human authorization.
- The route would ignore configured paths, duplicate an artifact, or cross the requested scope.

## Checklist

- [ ] Confirm the route, configured paths, locale, and authorization mode before writes.
- [ ] Search first and record missing evidence or human gates without inventing state.
- [ ] Run the focused validator and report its exact decision or blocker.
