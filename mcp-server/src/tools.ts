import path from "node:path";
import { exec_script, get_guards_dir, get_scripts_dir } from "./executor.js";

interface GuardEntry {
  command: string;
  build_args: (target_dir: string, strict: boolean) => string[];
}

type GuardRegistry = Record<string, Record<string, GuardEntry>>;

const GUARD_REGISTRY: GuardRegistry = {
  python: {
    duplicates: {
      command: "python3",
      build_args: (target_dir, strict) => {
        const script = path.join(get_guards_dir(), "python", "check_duplicates.py");
        const args = [script, target_dir];
        if (strict) args.push("--strict");
        return args;
      },
    },
    naming: {
      command: "python3",
      build_args: (target_dir, _strict) => {
        const script = path.join(get_guards_dir(), "python", "check_naming_convention.py");
        return [script, target_dir];
      },
    },
    quality: {
      command: "__special_quality__",
      build_args: () => [],
    },
  },
  rust: {
    nested_locks: {
      command: "bash",
      build_args: (target_dir, strict) => {
        const script = path.join(get_guards_dir(), "rust", "check_nested_locks.sh");
        return strict ? [script, "--strict", target_dir] : [script, target_dir];
      },
    },
    unwrap: {
      command: "bash",
      build_args: (target_dir, strict) => {
        const script = path.join(get_guards_dir(), "rust", "check_unwrap_in_prod.sh");
        return strict ? [script, "--strict", target_dir] : [script, target_dir];
      },
    },
    duplicate_types: {
      command: "bash",
      build_args: (target_dir, strict) => {
        const script = path.join(get_guards_dir(), "rust", "check_duplicate_types.sh");
        return strict ? [script, "--strict", target_dir] : [script, target_dir];
      },
    },
    workspace_consistency: {
      command: "bash",
      build_args: (target_dir, strict) => {
        const script = path.join(get_guards_dir(), "rust", "check_workspace_consistency.sh");
        return strict ? [script, "--strict", target_dir] : [script, target_dir];
      },
    },
  },
};

async function run_quality_guard(target_dir: string): Promise<string> {
  // quality guard 需要在目标项目中查找 test_code_quality_guards.py
  const find_result = await exec_script("find", [
    target_dir,
    "-name",
    "test_code_quality_guards.py",
    "-not",
    "-path",
    "*/node_modules/*",
    "-not",
    "-path",
    "*/.git/*",
  ]);

  const files = find_result.stdout.trim().split("\n").filter(Boolean);
  if (files.length === 0) {
    return (
      "quality guard: 目标项目中未找到 test_code_quality_guards.py。\n" +
      "该守卫是项目级模板，需要先部署到目标项目中才能运行。\n" +
      "参考 vibeguard/guards/python/test_code_quality_guards.py 模板。"
    );
  }

  const result = await exec_script("python3", ["-m", "pytest", files[0], "-v"], target_dir);
  return format_output("quality", result.stdout, result.stderr, result.exit_code);
}

function format_output(
  guard_name: string,
  stdout: string,
  stderr: string,
  exit_code: number
): string {
  const status = exit_code === 0 ? "PASS" : "ISSUES FOUND";
  let output = `[${guard_name}] ${status} (exit code: ${exit_code})\n`;
  if (stdout.trim()) output += `\n${stdout.trim()}\n`;
  if (stderr.trim()) output += `\nstderr:\n${stderr.trim()}\n`;
  return output;
}

export interface GuardCheckParams {
  target_dir: string;
  language: string;
  guard?: string;
  strict?: boolean;
}

export async function handle_guard_check(params: GuardCheckParams): Promise<string> {
  const { target_dir, language, guard, strict = false } = params;

  const lang_guards = GUARD_REGISTRY[language];
  if (!lang_guards) {
    return `不支持的语言: ${language}。支持的语言: ${Object.keys(GUARD_REGISTRY).join(", ")}`;
  }

  const guards_to_run = guard
    ? { [guard]: lang_guards[guard] }
    : lang_guards;

  if (guard && !lang_guards[guard]) {
    const available = Object.keys(lang_guards).join(", ");
    return `不支持的守卫: ${guard}。${language} 可用守卫: ${available}`;
  }

  const tasks = Object.entries(guards_to_run).map(async ([name, entry]) => {
    if (entry.command === "__special_quality__") {
      return run_quality_guard(target_dir);
    }
    const args = entry.build_args(target_dir, strict);
    const result = await exec_script(entry.command, args);
    return format_output(name, result.stdout, result.stderr, result.exit_code);
  });

  const results = await Promise.all(tasks);
  return results.join("\n---\n\n");
}

export interface ProjectParams {
  project_dir: string;
}

export async function handle_compliance_report(params: ProjectParams): Promise<string> {
  const script = path.join(get_scripts_dir(), "compliance_check.sh");
  const result = await exec_script("bash", [script, params.project_dir]);
  return format_output("compliance_report", result.stdout, result.stderr, result.exit_code);
}

export async function handle_metrics_collect(params: ProjectParams): Promise<string> {
  const script = path.join(get_scripts_dir(), "metrics_collector.sh");
  const result = await exec_script("bash", [script, params.project_dir]);
  return format_output("metrics_collect", result.stdout, result.stderr, result.exit_code);
}
