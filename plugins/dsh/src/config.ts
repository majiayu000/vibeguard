/** Runtime-validated plugin configuration. */

import z from '@deepseek-ai/schemastery'
import { HOOK_IDS, type PluginConfig } from './types.js'

export const DEFAULT_VERIFICATION_PATTERNS = [
  String.raw`(^|[;&|]\s*)(npm|pnpm|yarn|bun)\s+(run\s+)?(test|lint|check|build|typecheck)(\s|$)`,
  String.raw`(^|[;&|]\s*)(cargo\s+(test|check|clippy|build)|go\s+test|pytest|ruff\s+check|mypy|tsc|vitest|jest)(\s|$)`,
]

/** Schemastery contract used by Cordis while loading the bundle. */
export const Config: z<PluginConfig> = z.object({
  hooksDir: z.string().default(''),
  timeoutMs: z.number().default(15_000),
  buildTimeoutMs: z.number().default(35_000),
  stdoutMaxBytes: z.number().default(65_536),
  failureMode: z.union(['closed', 'open']).default('closed'),
  enabledHooks: z.array(z.union([...HOOK_IDS])).default([...HOOK_IDS]),
  mutatingTools: z.array(z.string()).default(['write', 'edit', 'str_replace_editor']),
  verificationCommandPatterns: z.array(z.string()).default(DEFAULT_VERIFICATION_PATTERNS),
  guardUnverifiedCompletion: z.boolean().default(true),
})
