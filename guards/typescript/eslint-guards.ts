/**
 * VibeGuard TypeScript ESLint Guard Rules Template
 *
 * Add the rules in this file to your project's ESLint configuration.
 * These rules correspond to the TypeScript version of the VibeGuard schema guard.
 *
 * How to use:
 * 1. Merge the following rules into the project's eslint.config.ts or .eslintrc.js
 * 2. Adjust severity (warn/error) according to project requirements
 */

// eslint.config.ts sample configuration
export const vibeguardRules = {
  rules: {
    // === Rule 1: Disallow empty catch blocks (corresponds to Python guard #1) ===
    // All catch blocks must have logging or re-throw
    "no-empty": ["error", { allowEmptyCatch: false }],

    // === Rule 2: disallow any type (corresponds to Python guard #2) ===
    // Public interface prohibits the use of any
    "@typescript-eslint/no-explicit-any": "error",

    // === Rule 3: Disable unused exports (corresponds to Python guard #3) ===
    // Prevent re-export shim
    "@typescript-eslint/no-unused-vars": [
      "error",
      { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
    ],

    // === Rule 4: Naming convention (corresponding to Python guard Layer 2) ===
    "@typescript-eslint/naming-convention": [
      "error",
      //Interface name uses PascalCase
      {
        selector: "interface",
        format: ["PascalCase"],
      },
      //The class name uses PascalCase
      {
        selector: "class",
        format: ["PascalCase"],
      },
      //Variables/functions use camelCase
      {
        selector: "variableLike",
        format: ["camelCase", "PascalCase", "UPPER_CASE"],
      },
    ],

    // === Rule 5: Disable console.log (production environment) ===
    "no-console": ["warn", { allow: ["warn", "error"] }],

    // === Other recommended rules ===

    //Require switch to have default
    "default-case": "error",

    // disable eval
    "no-eval": "error",

    // Force strict equality
    eqeqeq: ["error", "always"],

    // disable var
    "no-var": "error",

    // Priority const
    "prefer-const": "error",
  },
};

/**
 * Used in eslint.config.ts:
 *
 * ```ts
 * import { vibeguardRules } from './eslint-guards';
 *
 * export default [
 * // ...other configuration
 *   vibeguardRules,
 * ];
 * ```
 */
