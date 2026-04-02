---
description: "Test file writing specifications"
globs: ["**/*test*", "**/*spec*", "**/tests/**", "**/__tests__/**"]
---

# Test Patterns

- Test function naming: `test_<behavior under test>_<condition>_<expected result>`
- Use AAA mode: Arrange (preparation) → Act (execution) → Assert (assertion)
- Only verify one behavior per test, do not assert multiple unrelated things in one test
- Prioritize the use of real dependencies and only mock when necessary (external API, database, file system)
- Edge cases must be covered: empty input, oversized input, concurrency, wrong paths
- Allow unwrap/expect (Rust) and console.log (debugging) in tests without triggering VibeGuard warnings
