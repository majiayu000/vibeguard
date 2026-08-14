/** Per-agent state for startup delivery, verification, and stop-loop control. */
import type { Agent } from '@deepseek-ai/dsh-agent';
import type { ToolExecution, ToolExecutionResult } from '@deepseek-ai/dsh-tools';
import type { GuardDecision, GuardSignal } from './types.js';
import type { ToolHookPlan } from './payloads.js';
/** Track mutations and successful verification commands per DSH turn. */
export declare class VerificationTracker {
    private readonly mutatingTools;
    private readonly verificationPatterns;
    private readonly states;
    constructor(mutatingTools: ReadonlySet<string>, verificationPatterns: readonly RegExp[]);
    /** Observe one settled call without treating editor view operations as mutations. */
    observe(exec: Readonly<ToolExecution>, plan: ToolHookPlan, turn: number, result: Readonly<ToolExecutionResult>): void;
    /** Return the continuation signal at most once for one dirty, unverified turn. */
    completionSignal(agent: object, turn: number): GuardSignal | undefined;
}
/** Gate first-step delivery on an asynchronously executed SessionStart hook. */
export declare class StartupGate {
    private readonly controller;
    private readonly pending;
    private readonly byAgent;
    /** Start one hook run at the emit-shaped session boundary. */
    start(agent: Agent, task: (signal: AbortSignal) => Promise<GuardDecision>): void;
    /** Await and consume the pending SessionStart decision for one agent. */
    take(agent: Agent): Promise<GuardDecision | undefined>;
    /** Abort detached work and wait until every spawned hook reaches quiescence. */
    dispose(): Promise<void>;
}
/** Ensure Stop and learning hooks execute once per DSH turn. */
export declare class StopTracker {
    private readonly turns;
    /** Return true on the first stop boundary observed for this agent/turn. */
    first(agent: Agent, turn: number): boolean;
}
//# sourceMappingURL=lifecycle.d.ts.map