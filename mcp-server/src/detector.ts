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
