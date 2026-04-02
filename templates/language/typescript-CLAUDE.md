# [Project Name] — Claude Code Guidelines

## Project Overview

[Project Brief]

| Component | Location | Tech Stack |
|-----------|----------|------------|
| Frontend | `src/` | React + TypeScript + Tailwind |

---

## Critical Rules

### 1. NO BACKWARD COMPATIBILITY

Simply delete old code and components.

```typescript
// ❌ BAD
/** @deprecated Use NewComponent instead */
export const OldComponent = NewComponent;

// ✅ GOOD - delete directly, update all callers
```

### 2. NO HARDCODING

Content must come from props, context or API.

```typescript
// ❌ BAD
const title = "Welcome";

// ✅ GOOD
const title = data.title;
```

### 3. NAMING CONVENTION

- Component: PascalCase(`UserProfile.tsx`)
- Function/Variable: camelCase(`getUserProfile`)
- Type/Interface: PascalCase(`UserProfile`)
- Constant: UPPER_SNAKE_CASE(`MAX_RETRIES`)
- Filename: matches the export name

### 4. SEARCH BEFORE CREATE

You must search before creating a new component /hook/utility.

```bash
grep -rn "export.*function.*<name>" src/ --include="*.ts" --include="*.tsx"
grep -rn "export.*const.*<name>" src/ --include="*.ts" --include="*.tsx"
```

### 5. NO ANY TYPE

The use of `any` is prohibited for public interfaces.

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
├── components/ # UI components
│ ├── common/ # Shared components
│ └── features/ # Functional components
├── hooks/               # Custom hooks
├── services/ # API call
├── stores/ # Status management
├── types/ # TypeScript types
├── utils/ # Utility function
└── pages/ # Page component
```

---

## Code Quality

### ESLint rules

- `no-explicit-any`: error
- `no-empty`: error (empty catch is prohibited)
- `eqeqeq`: error (strictly equal)
- `no-console`: warn (production environment)

Run the check:
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

1. Type safety: prohibit any, use strict types
2. Componentization: small and independent components
3. Search first and then write: you must search before creating a new one.
4. Minimal changes: only do what is asked
5. Test each repair tape
