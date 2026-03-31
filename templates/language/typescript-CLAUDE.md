# [项目名] — Claude Code Guidelines

## Project Overview

[项目简述]

| Component | Location | Tech Stack |
|-----------|----------|------------|
| Frontend | `src/` | React + TypeScript + Tailwind |

---

## Critical Rules

### 1. NO BACKWARD COMPATIBILITY

直接删除旧代码和旧组件。

```typescript
// ❌ BAD
/** @deprecated Use NewComponent instead */
export const OldComponent = NewComponent;

// ✅ GOOD - 直接删除，更新所有调用方
```

### 2. NO HARDCODING

内容必须来自 props、context 或 API。

```typescript
// ❌ BAD
const title = "Welcome";

// ✅ GOOD
const title = data.title;
```

### 3. NAMING CONVENTION

- 组件：PascalCase（`UserProfile.tsx`）
- 函数/变量：camelCase（`getUserProfile`）
- 类型/接口：PascalCase（`UserProfile`）
- 常量：UPPER_SNAKE_CASE（`MAX_RETRIES`）
- 文件名：与导出名匹配

### 4. SEARCH BEFORE CREATE

新建组件/hook/utility 前必须先搜索。

```bash
grep -rn "export.*function.*<name>" src/ --include="*.ts" --include="*.tsx"
grep -rn "export.*const.*<name>" src/ --include="*.ts" --include="*.tsx"
```

### 5. NO ANY TYPE

公开接口禁止使用 `any`。

```typescript
// ❌ BAD
function processData(data: any): any { ... }

// ✅ GOOD
function processData(data: UserData): ProcessedResult { ... }
```

---

## Architecture

```
src/
├── components/          # UI 组件
│   ├── common/          # 共享组件
│   └── features/        # 功能组件
├── hooks/               # Custom hooks
├── services/            # API 调用
├── stores/              # 状态管理
├── types/               # TypeScript 类型
├── utils/               # 工具函数
└── pages/               # 页面组件
```

---

## Code Quality

### ESLint 规则

- `no-explicit-any`: error
- `no-empty`: error（禁止空 catch）
- `eqeqeq`: error（严格等于）
- `no-console`: warn（生产环境）

运行检查：
```bash
npm run lint
npm run typecheck
```

---

## Development

| Service | Port | Command |
|---------|------|---------|
| Frontend | 7788 | `npm run dev -- --port 7788` |

---

## Key Principles

1. 类型安全：禁止 any，使用严格类型
2. 组件化：小而独立的组件
3. 先搜后写：新建前必须搜索
4. 最小改动：只做被要求的事
5. 每个修复带测试
