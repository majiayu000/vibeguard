/** DSH tool/session values translated to canonical VibeGuard hook payloads. */
import type { Agent, SessionStartSource } from '@deepseek-ai/dsh-agent';
import type { ToolExecution, ToolExecutionResult } from '@deepseek-ai/dsh-tools';
import type { HookId } from './types.js';
/** Hook routing and normalized input for one DSH tool call. */
export interface ToolHookPlan {
    canonicalName: 'Bash' | 'Edit' | 'Glob' | 'Grep' | 'Read' | 'Write' | 'Other';
    input: Record<string, unknown>;
    preHooks: HookId[];
    postHooks: HookId[];
    mutation: boolean;
}
/** Map one DSH tool call to the canonical VibeGuard matcher and hook set. */
export declare function toolHookPlan(exec: Pick<ToolExecution, 'name' | 'arguments'>): ToolHookPlan;
/** Build the SessionStart payload consumed by count-active-constraints. */
export declare function sessionPayload(agent: Agent, source: SessionStartSource): Record<string, unknown>;
/** Build a complete PreToolUse/PostToolUse payload from one DSH tool call. */
export declare function toolPayload(exec: Readonly<ToolExecution>, plan: ToolHookPlan, event: 'PreToolUse' | 'PostToolUse', result?: Readonly<ToolExecutionResult>): Record<string, unknown>;
/** Build a Stop payload and expose whether this turn already reached a stop boundary. */
export declare function stopPayload(agent: Agent, turn: number, active: boolean): Record<string, unknown>;
/** Locate the open DSH turn for tool-result correlation. */
export declare function currentTurn(agent: Agent): number;
//# sourceMappingURL=payloads.d.ts.map