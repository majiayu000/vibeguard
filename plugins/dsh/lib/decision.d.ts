/** Hook output parsing and stable decision composition. */
import type { GuardDecision, GuardSignal, HookId, HookRunResult } from './types.js';
/** Create a stable guard decision without undefined signal fields. */
export declare function guardDecision(decision: GuardDecision['decision'], signals?: GuardSignal[]): GuardDecision;
/** Serialize a decision for DSH logs and model-visible content. */
export declare function serializeDecision(decision: GuardDecision): string;
/** Merge hook decisions; deny wins, then continue, then warn. */
export declare function mergeDecisions(decisions: readonly GuardDecision[]): GuardDecision;
/** Convert one canonical VibeGuard hook outcome into the DSH decision contract. */
export declare function interpretHookResult(hook: HookId, result: HookRunResult, failureMode: 'closed' | 'open'): GuardDecision;
//# sourceMappingURL=decision.d.ts.map