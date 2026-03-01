import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { detect_languages } from "../dist/detector.js";
import { set_vibeguard_root } from "../dist/executor.js";
import { handle_guard_check } from "../dist/tools.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const vibeguard_root = path.resolve(__dirname, "..", "..");
set_vibeguard_root(vibeguard_root);

function with_tmpdir(run) {
  const tmpdir = fs.mkdtempSync(path.join(vibeguard_root, ".tmp-mcp-test-"));
  try {
    return run(tmpdir);
  } finally {
    fs.rmSync(tmpdir, { recursive: true, force: true });
  }
}

async function with_tmpdir_async(run) {
  const tmpdir = fs.mkdtempSync(path.join(vibeguard_root, ".tmp-mcp-test-"));
  try {
    return await run(tmpdir);
  } finally {
    fs.rmSync(tmpdir, { recursive: true, force: true });
  }
}

test("detect_languages: package.json without tsconfig is treated as javascript", () => {
  with_tmpdir((tmpdir) => {
    fs.writeFileSync(path.join(tmpdir, "package.json"), '{"name":"demo"}\n', "utf8");
    const langs = detect_languages(tmpdir);
    assert.deepEqual(langs, ["javascript"]);
  });
});

test("detect_languages: tsconfig takes precedence over javascript fallback", () => {
  with_tmpdir((tmpdir) => {
    fs.writeFileSync(path.join(tmpdir, "package.json"), '{"name":"demo"}\n', "utf8");
    fs.writeFileSync(path.join(tmpdir, "tsconfig.json"), "{}\n", "utf8");
    const langs = detect_languages(tmpdir);
    assert.ok(langs.includes("typescript"));
    assert.ok(!langs.includes("javascript"));
  });
});

test("guard_check: javascript is a supported language", async () => {
  await with_tmpdir_async(async (tmpdir) => {
    fs.writeFileSync(path.join(tmpdir, "package.json"), '{"name":"demo"}\n', "utf8");
    const text = await handle_guard_check({
      target_dir: tmpdir,
      language: "javascript",
      guard: "not_exists",
      strict: false,
    });
    assert.match(text, /javascript 可用守卫/);
    assert.doesNotMatch(text, /不支持的语言/);
  });
});

test("guard_check: unsupported language fails fast instead of fallback", async () => {
  await with_tmpdir_async(async (tmpdir) => {
    const text = await handle_guard_check({
      target_dir: tmpdir,
      language: "ruby",
      strict: false,
    });
    assert.match(text, /不支持的语言/);
    assert.doesNotMatch(text, /PASS/);
  });
});

test("guard_check: unsupported guard fails fast instead of fallback", async () => {
  await with_tmpdir_async(async (tmpdir) => {
    fs.writeFileSync(path.join(tmpdir, "package.json"), '{"name":"demo"}\n', "utf8");
    const text = await handle_guard_check({
      target_dir: tmpdir,
      language: "javascript",
      guard: "vet",
      strict: false,
    });
    assert.match(text, /不支持的守卫/);
    assert.doesNotMatch(text, /PASS/);
  });
});

test("guard_check: rust available guards include p1 semantic guards", async () => {
  await with_tmpdir_async(async (tmpdir) => {
    const text = await handle_guard_check({
      target_dir: tmpdir,
      language: "rust",
      guard: "not_exists",
      strict: false,
    });
    assert.match(text, /single_source_of_truth/);
    assert.match(text, /semantic_effect/);
  });
});

test("guard_check: rust semantic_effect guard is wired", async () => {
  await with_tmpdir_async(async (tmpdir) => {
    const text = await handle_guard_check({
      target_dir: tmpdir,
      language: "rust",
      guard: "semantic_effect",
      strict: false,
    });
    assert.doesNotMatch(text, /不支持的守卫/);
  });
});

test("guard_check: typescript guard list includes anti-fallback and anti-direct-ai guards", async () => {
  await with_tmpdir_async(async (tmpdir) => {
    fs.writeFileSync(path.join(tmpdir, "package.json"), '{"name":"demo"}\n', "utf8");
    const text = await handle_guard_check({
      target_dir: tmpdir,
      language: "typescript",
      guard: "not_exists",
      strict: false,
    });
    assert.match(text, /no_api_direct_ai_call/);
    assert.match(text, /no_dual_track_fallback/);
    assert.match(text, /duplicate_constants/);
  });
});
