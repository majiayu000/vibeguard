---
paths: **/*.ts,**/*.tsx,**/*.js,**/*.jsx
---

# TypeScript 质量规则

## TS-01: any 类型逃逸（中）
函数参数或返回值为 any。修复：替换为具体类型或 `unknown`，对 unknown 做类型收窄后使用。

## TS-02: 未处理的 Promise rejection（高）
async 函数调用缺少错误处理。修复：所有 async 调用加 `await` + try/catch，或 `.catch()` 处理。

## TS-03: == 而非 ===（中）
非 null check 场景使用宽松相等。修复：改为 `===`。null check 场景可用 `== null`。

## TS-04: 超大组件 > 300 行（中）
React 组件过大。修复：拆分为子组件和自定义 hooks，单组件不超过 300 行。

## TS-05: 多处相同的 fetch/API 调用模式（中）
修复：提取公共 API 客户端函数或 hook。

## TS-06: useEffect 缺少依赖或依赖过宽（中）
修复：精确声明依赖数组。过宽依赖改用 useCallback/useMemo 稳定引用。

## TS-07: 大数组在 render 中 map 无 memo（低）
修复：用 `useMemo` 缓存 map 结果，或将数组处理移到 render 外部。

## TS-08: 使用 `as any` 或 `@ts-ignore` 绕过类型检查（高）
修复：替换为正确类型定义或类型守卫。必要时用 `as unknown as T` 并注释原因。

## TS-09: 函数参数超过 4 个（中）
修复：合并为单个 options 对象参数。

## TS-10: 嵌套回调超过 3 层（中）
修复：改用 async/await 展平异步链。

## TS-11: 未处理的 null/undefined（中）
缺少可选链或空值检查。修复：用 `?.`、`??` 或提前 guard return。

## TS-12: 组件 props 传递整个对象而非必要字段（低）
修复：只传递组件实际需要的字段，避免不必要的重渲染。
