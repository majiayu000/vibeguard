import { spawn } from "node:child_process";
import path from "node:path";

let vibeguard_root = "";

export function set_vibeguard_root(root: string): void {
  vibeguard_root = root;
}

export function get_vibeguard_root(): string {
  return vibeguard_root;
}

export function get_guards_dir(): string {
  return path.join(vibeguard_root, "guards");
}

export function get_scripts_dir(): string {
  return path.join(vibeguard_root, "scripts");
}

export interface ExecResult {
  stdout: string;
  stderr: string;
  exit_code: number;
}

export function exec_script(
  command: string,
  args: string[],
  cwd?: string,
  timeout_ms: number = 60_000
): Promise<ExecResult> {
  return new Promise((resolve) => {
    let resolved = false;
    const proc = spawn(command, args, {
      cwd: cwd ?? vibeguard_root,
      stdio: ["ignore", "pipe", "pipe"],
    });

    const stdout_chunks: Buffer[] = [];
    const stderr_chunks: Buffer[] = [];

    proc.stdout.on("data", (chunk: Buffer) => stdout_chunks.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => stderr_chunks.push(chunk));

    // 手动超时：SIGTERM → 2s 后 SIGKILL
    const timer = setTimeout(() => {
      proc.kill("SIGTERM");
      setTimeout(() => {
        if (!resolved) proc.kill("SIGKILL");
      }, 2_000);
    }, timeout_ms);

    const finish = (code: number, extra_stderr?: string) => {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      resolve({
        stdout: Buffer.concat(stdout_chunks).toString("utf-8"),
        stderr:
          Buffer.concat(stderr_chunks).toString("utf-8") +
          (extra_stderr ?? ""),
        exit_code: code,
      });
    };

    proc.on("close", (code) => finish(code ?? 1));
    proc.on("error", (err) => finish(1, err.message));
  });
}
