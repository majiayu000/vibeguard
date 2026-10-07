import type { Context } from '@deepseek-ai/cordis';
import type { ToolExecution, ToolExecutionResult } from '@deepseek-ai/dsh-tools';
import z from '@deepseek-ai/schemastery';
declare module '@deepseek-ai/dsh-llm' {
    interface MessageSourceMap {
        vibeguard: {
            kind: 'vibeguard';
            form: 'notice';
            summary: string;
        };
    }
}
export declare const name = "vibeguard-dsh";
export declare const inject: string[];
export interface Config {
    runtimePath?: string;
    stateDir?: string;
    timeoutMs?: number;
}
export declare const Config: z<Config>;
/** Translate structured DSH facts; display text is never an exit status. */
export declare function toolPayload(exec: ToolExecution, result?: ToolExecutionResult): Record<string, unknown>;
/** Mount native pre/post events without implementing policy in TypeScript. */
export declare function apply(ctx: Context, config: Config): void;
//# sourceMappingURL=index.d.ts.map