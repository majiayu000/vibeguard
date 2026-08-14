/** Shared public contracts for the native DSH adapter. */
export declare const HOOK_IDS: readonly ["count-active-constraints", "pre-bash-guard", "pre-edit-guard", "pre-write-guard", "post-edit-guard", "post-write-guard", "post-build-check", "analysis-paralysis-guard", "stop-guard", "learn-evaluator"];
/** Canonical VibeGuard hooks supported by the DSH bundle. */
export type HookId = typeof HOOK_IDS[number];
/** Machine-readable category of one VibeGuard observation. */
export type SignalType = 'analysis' | 'build' | 'command_policy' | 'completion' | 'constraints' | 'file_policy' | 'guard_error' | 'learning' | 'quality';
/** One machine-readable fact emitted by the adapter. */
export interface GuardSignal {
    signal_type: SignalType;
    signal: string;
    reason: string;
}
/** Stable JSON envelope used in logs and model-visible guard decisions. */
export interface GuardDecision {
    version: 'vibeguard.dsh/v1';
    decision: 'allow' | 'warn' | 'deny' | 'continue';
    signals: GuardSignal[];
}
/** Minimal shell result shape consumed by the hook interpreter. */
export interface HookRunResult {
    exitCode: number | null;
    signal: NodeJS.Signals | null;
    timedOut: boolean;
    aborted: boolean;
    stdout: string;
    stderr: string;
    stdoutTruncated?: boolean;
}
/** Deployment settings for the VibeGuard DSH adapter. */
export interface PluginConfig {
    /** Installed VibeGuard hooks directory. Empty selects the standard snapshot. */
    hooksDir?: string;
    /** Maximum runtime for ordinary hooks. */
    timeoutMs?: number;
    /** Maximum runtime for the build-check hook. */
    buildTimeoutMs?: number;
    /** Maximum stdout bytes collected from one hook. */
    stdoutMaxBytes?: number;
    /** Whether guard infrastructure failures deny/block or only warn. */
    failureMode?: 'closed' | 'open';
    /** Canonical hooks to activate. */
    enabledHooks?: HookId[];
    /** Successful tool names that make the current turn require verification. */
    mutatingTools?: string[];
    /** Regular expressions recognizing Bash verification commands. */
    verificationCommandPatterns?: string[];
    /** Enable the one-shot unverified-completion continuation guard. */
    guardUnverifiedCompletion?: boolean;
}
//# sourceMappingURL=types.d.ts.map