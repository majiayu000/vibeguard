/** Execute canonical VibeGuard scripts through DSH's managed shell service. */
import type { Context } from '@deepseek-ai/cordis';
import { type GuardDecision, type HookId, type PluginConfig } from './types.js';
/** Validated, lifecycle-safe executor for the selected canonical hook scripts. */
export declare class HookRunner {
    private readonly ctx;
    private readonly hooksDir;
    private readonly buildTimeoutMs;
    private readonly enabled;
    private readonly failureMode;
    private readonly stdoutMaxBytes;
    private readonly timeoutMs;
    constructor(ctx: Context, hooksDir: string, config: PluginConfig);
    /** Whether one canonical hook is enabled in this deployment. */
    has(hook: HookId): boolean;
    private path;
    /** Run one hook and record its stable structured decision. */
    run(hook: HookId, payload: Record<string, unknown>, workdir: string, signal: AbortSignal): Promise<GuardDecision>;
    /** Run a hook sequence in manifest order and combine its signals. */
    runMany(hooks: readonly HookId[], payload: Record<string, unknown>, workdir: string, signal: AbortSignal): Promise<GuardDecision>;
}
//# sourceMappingURL=hook-runner.d.ts.map