/** Native DeepSeek Harness adapter for the installed VibeGuard runtime. */
import type { Context } from '@deepseek-ai/cordis';
import { HOOK_IDS, type PluginConfig } from './types.js';
export declare const name = "vibeguard-dsh";
export declare const inject: string[];
export declare const Config: import("@deepseek-ai/schemastery").default<PluginConfig>;
/** Public plugin configuration accepted by the DSH Cordis row. */
export interface Config extends PluginConfig {
}
export { HOOK_IDS };
export * from './decision.js';
export * from './lifecycle.js';
export * from './payloads.js';
export * from './types.js';
/** Install all configured VibeGuard lifecycle adapters into DSH. */
export declare function apply(ctx: Context, config: Config): void;
//# sourceMappingURL=index.d.ts.map