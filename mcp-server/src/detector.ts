import fs from "node:fs";
import path from "node:path";

const LANGUAGE_MARKERS: Record<string, string[]> = {
  rust: ["Cargo.toml"],
  python: ["pyproject.toml", "setup.py", "requirements.txt", "Pipfile"],
  typescript: ["tsconfig.json"],
  go: ["go.mod"],
};

// 检测顺序：先检查 TS（有 tsconfig.json 才算 TS，否则可能是纯 JS）
// package.json 不单独作为 TS 标志，避免误判
export function detect_languages(target_dir: string): string[] {
  const languages: string[] = [];

  for (const [lang, markers] of Object.entries(LANGUAGE_MARKERS)) {
    for (const marker of markers) {
      if (fs.existsSync(path.join(target_dir, marker))) {
        languages.push(lang);
        break;
      }
    }
  }

  return languages;
}
