# TypeScript Rules（TypeScript 特定规则）

TypeScript 项目扫描和修复的特定规则。

## 扫描检查项

| ID | 类别 | 检查项 | 严重度 |
|----|------|--------|--------|
| TS-01 | Bug | any 类型逃逸（函数参数或返回值为 any） | 中 |
| TS-02 | Bug | 未处理的 Promise rejection | 高 |
| TS-03 | Bug | == 而非 ===（非 null check 场景） | 中 |
| TS-04 | Design | 超大组件（> 300 行 React 组件） | 中 |
| TS-05 | Dedup | 多处相同的 fetch/API 调用模式 | 中 |
| TS-06 | Perf | useEffect 缺少依赖或依赖过宽 | 中 |
| TS-07 | Perf | 大数组在 render 中 map 无 memo | 低 |

## SKIP 规则（TypeScript 特定）

| 条件 | 判定 | 理由 |
|------|------|------|
| 用 interface 而非 type（或反之） | SKIP | 风格偏好，不影响功能 |
| 缺少 JSDoc 但类型签名清晰 | SKIP | 类型即文档 |
| 用 enum 而非 union type | SKIP | 除非造成 bundle size 问题 |

## ECC 增强规则

| ID | 类别 | 检查项 | 严重度 |
|----|------|--------|--------|
| TS-08 | Safety | 使用 `as any` 或 `@ts-ignore` 绕过类型检查 | 高 |
| TS-09 | Design | 函数参数超过 4 个（应使用 options 对象） | 中 |
| TS-10 | Design | 嵌套回调超过 3 层（应使用 async/await） | 中 |
| TS-11 | Safety | 未处理的 null/undefined（缺少可选链或空值检查） | 中 |
| TS-12 | Perf | 组件 props 传递整个对象而非必要字段 | 低 |

## 验证命令
```bash
npx tsc --noEmit && npx eslint . && npm test
```
