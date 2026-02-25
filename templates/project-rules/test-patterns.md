---
description: "测试文件的编写规范"
globs: ["**/*test*", "**/*spec*", "**/tests/**", "**/__tests__/**"]
---

# Test Patterns

- 测试函数命名：`test_<被测行为>_<条件>_<预期结果>`
- 使用 AAA 模式：Arrange（准备）→ Act（执行）→ Assert（断言）
- 每个测试只验证一个行为，不要在一个测试中断言多个不相关的事
- 优先使用真实依赖，只在必要时 mock（外部 API、数据库、文件系统）
- 边界情况必须覆盖：空输入、超大输入、并发、错误路径
- 测试中允许 unwrap/expect（Rust）和 console.log（调试），不触发 VibeGuard 警告
