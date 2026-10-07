/** Invoke the trusted runtime; proposed commands only travel on stdin. */
import type { Context } from '@deepseek-ai/cordis';
export interface RuntimeOptions {
    runtimePath: string;
    stateDir: string;
    timeoutMs: number;
}
export type RuntimeDecision = {
    kind: 'allow';
    reason?: string;
} | {
    kind: 'policy' | 'error';
    reason: string;
};
export declare function runHook(ctx: Context, options: RuntimeOptions, payload: Record<string, unknown>, signal: AbortSignal): Promise<RuntimeDecision>;
//# sourceMappingURL=runtime.d.ts.map