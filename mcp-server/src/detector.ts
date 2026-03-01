import fs from "node:fs";
import path from "node:path";

const LANGUAGE_MARKERS: Record<string, string[]> = {
  rust: ["Cargo.toml"],
  python: ["pyproject.toml", "setup.py", "requirements.txt", "Pipfile"],
  typescript: ["tsconfig.json"],
  go: ["go.mod"],
};

function has_language_marker(target_dir: string, markers: string[]): boolean {
  return markers.some((marker) => fs.existsSync(path.join(target_dir, marker)));
}

// 检测顺序：先检查 TS。若存在 package.json 且无 tsconfig.json，则视为 JavaScript 项目。
export function detect_languages(target_dir: string): string[] {
  const languages: string[] = [];

  for (const [lang, markers] of Object.entries(LANGUAGE_MARKERS)) {
    if (has_language_marker(target_dir, markers)) {
      languages.push(lang);
    }
  }

  const has_typescript = languages.includes("typescript");
  const has_package_json = fs.existsSync(path.join(target_dir, "package.json"));
  const has_js_config = fs.existsSync(path.join(target_dir, "jsconfig.json"));
  if (!has_typescript && (has_package_json || has_js_config)) {
    languages.push("javascript");
  }

  return languages;
}

// --- Task-to-Agent 自动调度 ---

export interface TaskClassification {
  agent: string;
  confidence: "high" | "medium" | "low";
  reason: string;
}

const FILE_PATTERN_AGENTS: [RegExp, string, string][] = [
  [/\.(test|spec)\.(ts|js|tsx|jsx|py|rs|go)$/, "tdd-guide", "测试文件变更"],
  [/migration|migrate|schema\.sql/i, "database-reviewer", "数据库迁移"],
  [/(README|CHANGELOG|docs\/)/i, "doc-updater", "文档变更"],
  [/(security|auth|crypt|token|jwt|oauth)/i, "security-reviewer", "安全相关"],
  [/\.(env|secret|credential)/i, "security-reviewer", "凭证文件"],
];

const ERROR_PATTERN_AGENTS: [RegExp, string, string][] = [
  [/error\[E\d+\]|cannot find|unresolved/i, "build-error-resolver", "编译错误"],
  [/FAIL|AssertionError|panic/i, "tdd-guide", "测试失败"],
  [/go build|go vet/i, "go-build-resolver", "Go 构建错误"],
];

/**
 * 根据变更文件列表推断最合适的 agent。
 * 返回 null 表示无法自动判断，需要手动指定。
 */
export function classify_task(
  changed_files: string[],
  error_output?: string,
): TaskClassification | null {
  // 优先匹配错误输出
  if (error_output) {
    for (const [pattern, agent, reason] of ERROR_PATTERN_AGENTS) {
      if (pattern.test(error_output)) {
        return { agent, confidence: "high", reason };
      }
    }
  }

  // 按文件模式匹配
  const agent_votes: Record<string, { count: number; reason: string }> = {};
  for (const file of changed_files) {
    for (const [pattern, agent, reason] of FILE_PATTERN_AGENTS) {
      if (pattern.test(file)) {
        if (!agent_votes[agent]) {
          agent_votes[agent] = { count: 0, reason };
        }
        agent_votes[agent].count++;
      }
    }
  }

  // 多文件重构检测
  if (changed_files.length >= 5 && Object.keys(agent_votes).length === 0) {
    return {
      agent: "refactor-cleaner",
      confidence: "medium",
      reason: `${changed_files.length} 文件变更，疑似重构`,
    };
  }

  // 取投票最高的 agent
  const sorted = Object.entries(agent_votes).sort(
    (a, b) => b[1].count - a[1].count,
  );
  if (sorted.length > 0) {
    const [agent, { count, reason }] = sorted[0];
    const confidence = count >= 3 ? "high" : count >= 2 ? "medium" : "low";
    return { agent, confidence, reason };
  }

  return null;
}
