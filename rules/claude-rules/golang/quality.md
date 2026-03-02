---
paths: **/*.go,**/go.mod,**/go.sum
---

# Go 质量规则

## GO-01: 未检查 error 返回值（高）
赋值给 `_` 丢弃 error。修复：`if err != nil { return fmt.Errorf("context: %w", err) }`

## GO-02: goroutine 泄漏（高）
`go func()` 无退出机制。修复：传入 `context.Context`，用 `select { case <-ctx.Done(): return }`

## GO-03: data race（高）
共享变量无 mutex 或 channel 保护。修复：用 `sync.Mutex`/`sync.RWMutex` 保护，或改用 channel 通信。

## GO-04: 接口定义在实现侧而非消费侧（中）
修复：接口移到消费方包中定义，遵循"依赖接口不依赖实现"原则。

## GO-05: 多处相同的 error wrapping 模式（中）
修复：统一使用 `fmt.Errorf("...: %w", err)` 格式。

## GO-06: 循环内 append 未预分配 cap（低）
修复：`make([]T, 0, expectedLen)` 预分配切片容量。

## GO-07: 字符串拼接用 + 而非 strings.Builder（低）
修复：改用 `strings.Builder` 或 `strings.Join`。

## GO-08: defer 在循环内（高）
资源泄漏风险，defer 到函数结束才执行。修复：将循环体提取为独立函数，defer 在函数内部执行。

## GO-09: 函数超过 80 行（中）
修复：提取子函数，单函数不超过 80 行。

## GO-10: 包级别 init() 有副作用（中）
网络/文件 IO 在 init() 中执行。修复：移到显式初始化函数中，由调用方控制时机。

## GO-11: context.Background() 在非入口函数中使用（中）
修复：将 context 作为第一个参数从调用链顶部传入。非入口函数不创建根 context。

## GO-12: 结构体字段未按大小排序（低）
内存对齐浪费。修复：按字段大小降序排列（大字段在前），减少 padding。
