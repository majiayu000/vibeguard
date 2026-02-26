import path from "node:path";
import fs from "node:fs";
import { exec_script, get_guards_dir, get_scripts_dir, get_vibeguard_root } from "./executor.js";
import { detect_languages } from "./detector.js";

const FORBIDDEN_PREFIXES = ["/etc", "/usr", "/bin", "/sbin", "/var", "/System", "/Library", "/proc", "/sys"];

function validate_target_dir(target_dir: string): string {
  const resolved = path.resolve(target_dir);
  if (!path.isAbsolute(resolved)) {
    throw new Error(`路径必须是绝对路径: ${target_dir}`);
  }
  for (const prefix of FORBIDDEN_PREFIXES) {
    if (resolved === prefix || resolved.startsWith(prefix + "/")) {
      throw new Error(`禁止访问系统目录: ${resolved}`);
    }
  }
  if (!fs.existsSync(resolved)) {
    throw new Error(`目录不存在: ${resolved}`);
  }
  return resolved;
}

interface GuardEntry {
  command: string;
  build_args: (target_dir: string, strict: boolean) => string[];
}

type GuardRegistry = Record<string, Record<string, GuardEntry>>;

const TS_JS_GUARDS: Record<string, GuardEntry> = {
  eslint_guards: {
    command: "__special_eslint__",
    build_args: () => [],
  },
  any_abuse: {
    command: "bash",
    build_args: (target_dir, strict) => {
      const script = path.join(get_guards_dir(), "typescript", "check_any_abuse.sh");
      return strict ? [script, "--strict", target_dir] : [script, target_dir];
    },
  },
  console_residual: {
    command: "bash",
    build_args: (target_dir, strict) => {
      const script = path.join(get_guards_dir(), "typescript", "check_console_residual.sh");
      return strict ? [script, "--strict", target_dir] : [script, target_dir];
    },
  },
};

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
    single_source_of_truth: {
      command: "bash",
      build_args: (target_dir, strict) => {
        const script = path.join(get_guards_dir(), "rust", "check_single_source_of_truth.sh");
        return strict ? [script, "--strict", target_dir] : [script, target_dir];
      },
    },
    semantic_effect: {
      command: "bash",
      build_args: (target_dir, strict) => {
        const script = path.join(get_guards_dir(), "rust", "check_semantic_effect.sh");
        return strict ? [script, "--strict", target_dir] : [script, target_dir];
      },
    },
  },
  typescript: TS_JS_GUARDS,
  javascript: TS_JS_GUARDS,
  go: {
    vet: {
      command: "go",
      build_args: (target_dir, _strict) => {
        return ["vet", "./..."];
      },
    },
  },
};

async function run_eslint_guard(target_dir: string): Promise<string> {
  // 检查项目中是否有 eslint 配置
  const check = await exec_script("find", [
    target_dir, "-maxdepth", "2",
    "-name", "eslint.config.*", "-o", "-name", ".eslintrc*",
  ]);
  const configs = check.stdout.trim().split("\n").filter(Boolean);

  const rules_path = path.join(
    get_vibeguard_root(), "rules", "typescript.md"
  );
  const template_path = path.join(get_guards_dir(), "typescript", "eslint-guards.ts");

  if (configs.length === 0) {
    return (
      `[eslint_guards] INFO\n\n` +
      `目标项目无 ESLint 配置。TypeScript 守卫以规则文件形式提供：\n` +
      `  - 规则参考: ${rules_path}\n` +
      `  - ESLint 插件模板: ${template_path}\n` +
      `请将模板集成到项目 ESLint 配置中以启用自动检测。`
    );
  }

  // 如果项目有 eslint，尝试运行
  const result = await exec_script("npx", ["eslint", "--max-warnings=0", "."], target_dir, 120_000);
  return format_output("eslint_guards", result.stdout, result.stderr, result.exit_code);
}

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

function resolve_guard_concurrency(): number {
  const raw = Number(process.env.VIBEGUARD_GUARD_CONCURRENCY ?? "2");
  if (!Number.isFinite(raw)) return 2;
  return Math.max(1, Math.floor(raw));
}

async function run_with_concurrency<T>(
  tasks: Array<() => Promise<T>>,
  concurrency: number,
): Promise<T[]> {
  const results: T[] = new Array(tasks.length);
  let cursor = 0;

  async function worker(): Promise<void> {
    while (true) {
      const index = cursor++;
      if (index >= tasks.length) {
        return;
      }
      results[index] = await tasks[index]();
    }
  }

  const worker_count = Math.min(concurrency, tasks.length);
  await Promise.all(Array.from({ length: worker_count }, () => worker()));
  return results;
}

function format_guard_runtime_error(guard_name: string, error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return `[${guard_name}] ISSUES FOUND (exit code: 1)\n\nruntime error:\n${message}\n`;
}

export async function handle_guard_check(params: GuardCheckParams): Promise<string> {
  let target_dir: string;
  try {
    target_dir = validate_target_dir(params.target_dir);
  } catch (e) {
    return (e as Error).message;
  }
  const { language, guard, strict = false } = params;

  // auto 模式：检测项目语言，跑所有相关守卫
  if (language === "auto") {
    const detected = detect_languages(target_dir);
    if (detected.length === 0) {
      return `未检测到支持的语言。支持的语言: ${Object.keys(GUARD_REGISTRY).join(", ")}\n检测方式: Cargo.toml(rust), tsconfig.json(typescript), pyproject.toml/setup.py(python), go.mod(go)`;
    }

    const results: string[] = [];
    results.push(`[auto] 检测到语言: ${detected.join(", ")}\n`);
    for (const lang of detected) {
      results.push(`== ${lang} ==`);
      const sub_result = await run_guards_for_language(target_dir, lang, guard, strict);
      results.push(sub_result);
    }
    return results.join("\n");
  }

  const lang_guards = GUARD_REGISTRY[language];
  if (!lang_guards) {
    const detected = detect_languages(target_dir);
    const hint = detected.length > 0 ? `\n提示: 检测到项目语言为 ${detected.join(", ")}，可使用 language: "auto" 自动选择` : "";
    return `不支持的语言: ${language}。支持的语言: ${Object.keys(GUARD_REGISTRY).join(", ")}${hint}`;
  }

  return run_guards_for_language(target_dir, language, guard, strict);
}

async function run_guards_for_language(
  target_dir: string,
  language: string,
  guard: string | undefined,
  strict: boolean,
): Promise<string> {
  const lang_guards = GUARD_REGISTRY[language];
  if (!lang_guards) {
    return `不支持的语言: ${language}`;
  }

  const guards_to_run = guard
    ? { [guard]: lang_guards[guard] }
    : lang_guards;

  if (guard && !lang_guards[guard]) {
    const available = Object.keys(lang_guards).join(", ");
    return `不支持的守卫: ${guard}。${language} 可用守卫: ${available}`;
  }

  const tasks = Object.entries(guards_to_run).map(([name, entry]) => async () => {
    try {
      if (entry.command === "__special_quality__") {
        return await run_quality_guard(target_dir);
      }
      if (entry.command === "__special_eslint__") {
        return await run_eslint_guard(target_dir);
      }
      const args = entry.build_args(target_dir, strict);
      const cwd = language === "go" ? target_dir : undefined;
      const result = await exec_script(entry.command, args, cwd);
      return format_output(name, result.stdout, result.stderr, result.exit_code);
    } catch (error) {
      return format_guard_runtime_error(name, error);
    }
  });

  const results = await run_with_concurrency(tasks, resolve_guard_concurrency());
  return results.join("\n---\n\n");
}

export interface ProjectParams {
  project_dir: string;
}

export async function handle_compliance_report(params: ProjectParams): Promise<string> {
  let project_dir: string;
  try {
    project_dir = validate_target_dir(params.project_dir);
  } catch (e) {
    return (e as Error).message;
  }
  const script = path.join(get_scripts_dir(), "compliance_check.sh");
  const result = await exec_script("bash", [script, project_dir]);
  return format_output("compliance_report", result.stdout, result.stderr, result.exit_code);
}

export async function handle_metrics_collect(params: ProjectParams): Promise<string> {
  let project_dir: string;
  try {
    project_dir = validate_target_dir(params.project_dir);
  } catch (e) {
    return (e as Error).message;
  }
  const script = path.join(get_scripts_dir(), "metrics_collector.sh");
  const result = await exec_script("bash", [script, project_dir]);
  return format_output("metrics_collect", result.stdout, result.stderr, result.exit_code);
}
