---
paths: **/*.rs,**/Cargo.toml,**/Cargo.lock
---

# Rust review and tooling

## RS-01: Review lock ordering and lifetime (high)
Check actual acquisition order, reentrancy and guards held across await. Nested locks are not automatically a deadlock. Use applicable Clippy checks such as await_holding_lock as partial evidence. Do not mandate a framework-specific Signal or merge unrelated state into one lock.

## RS-02: Keep read-modify-write operations consistent (high)
Determine whether concurrent mutation can occur between the read and write. A get followed by insert under one guard or in single-threaded code is not inherently a race. Use Entry when it expresses the operation correctly; Clippy map_entry is not a concurrency proof.

## RS-03: Make panic and error propagation intentional (guideline)
Use the project's Clippy unwrap_used/expect_used policy where desired. Propagate recoverable failures and provide useful context for intentional unrecoverable failures. This applies in async code too. Do not replace errors with default values merely to remove unwrap.

## RS-05: Keep type identity consistent with domain meaning (guideline)
Check whether types actually describe the same contract before sharing or renaming them. Identical names in different modules can be legitimate; distinct meanings do not require merging into one type. Do not use a name-match gate.

## RS-08: Use ownership and Clippy to assess unnecessary clones (guideline)
Use clone_on_copy for the concrete Copy case. For other values, consider ownership, lifetime, readability and measured cost before changing a clone to a borrow. Do not assume every clone is wasteful.

## RS-09: Optimize formatting only on a demonstrated hot path (guideline)
Use a measurement or concrete workload to justify reducing allocations. Select a suitable buffer or formatting method for that case. Ordinary format! calls are valid; do not guess capacities or impose a global ban.

## RS-12: Keep ownership of shared mutable facts clear (high)
When two implementations appear to overlap, inspect their consumers, contracts and actual state ownership. Multiple Arc handles may share one allocation; different infrastructure can serve distinct responsibilities. Do not infer duplicate systems from names or automatically delete either implementation.

## RS-20: Check affected boundaries after type changes (strict)
After a struct or enum change, inspect actual serialization, storage, interface and test consumers affected by the change. Let the compiler check the constructors it covers. Do not require nonexistent layers, fixed search rounds, compatibility fields or old-data backfills unless the task asks for them.
