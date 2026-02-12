/**
 * VibeGuard TypeScript ESLint Guard Rules Template
 *
 * 将此文件中的规则添加到项目的 ESLint 配置中。
 * 这些规则对应 VibeGuard 架构守卫的 TypeScript 版本。
 *
 * 使用方法：
 *   1. 将下方规则合并到项目的 eslint.config.ts 或 .eslintrc.js
 *   2. 根据项目需求调整 severity（warn / error）
 */

// eslint.config.ts 示例配置
export const vibeguardRules = {
  rules: {
    // === Rule 1: 禁止空 catch 块（对应 Python 守卫 #1） ===
    // 所有 catch 块必须有 logging 或 re-throw
    "no-empty": ["error", { allowEmptyCatch: false }],

    // === Rule 2: 禁止 any 类型（对应 Python 守卫 #2） ===
    // 公开接口禁止使用 any
    "@typescript-eslint/no-explicit-any": "error",

    // === Rule 3: 禁止未使用的 export（对应 Python 守卫 #3） ===
    // 防止 re-export shim
    "@typescript-eslint/no-unused-vars": [
      "error",
      { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
    ],

    // === Rule 4: 命名规范（对应 Python 守卫 Layer 2） ===
    "@typescript-eslint/naming-convention": [
      "error",
      // 接口名使用 PascalCase
      {
        selector: "interface",
        format: ["PascalCase"],
      },
      // 类名使用 PascalCase
      {
        selector: "class",
        format: ["PascalCase"],
      },
      // 变量/函数使用 camelCase
      {
        selector: "variableLike",
        format: ["camelCase", "PascalCase", "UPPER_CASE"],
      },
    ],

    // === Rule 5: 禁止 console.log（生产环境） ===
    "no-console": ["warn", { allow: ["warn", "error"] }],

    // === 其他推荐规则 ===

    // 要求 switch 有 default
    "default-case": "error",

    // 禁止 eval
    "no-eval": "error",

    // 强制严格等于
    eqeqeq: ["error", "always"],

    // 禁止 var
    "no-var": "error",

    // 优先 const
    "prefer-const": "error",
  },
};

/**
 * 在 eslint.config.ts 中使用：
 *
 * ```ts
 * import { vibeguardRules } from './eslint-guards';
 *
 * export default [
 *   // ...其他配置
 *   vibeguardRules,
 * ];
 * ```
 */
