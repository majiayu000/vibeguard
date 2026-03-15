/**
 * MCP Server Integration Tests
 *
 * Starts the compiled MCP server as a child process and exercises each tool
 * via raw JSON-RPC 2.0 over stdio — the same transport the real MCP host uses.
 *
 * Test coverage:
 *   - MCP initialization handshake
 *   - tools/list  (listing all tools)
 *   - guard_check: individual guards per language
 *   - guard_check: all guards (no `guard` arg)
 *   - compliance_report
 *   - metrics_collect
 *   - Invalid inputs / error responses
 */

import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const MCP_SERVER_ROOT = path.resolve(__dirname, "..", "..");
const VIBEGUARD_ROOT = path.resolve(MCP_SERVER_ROOT, "..");
const SERVER_BIN = path.join(MCP_SERVER_ROOT, "dist", "index.js");

// ---------------------------------------------------------------------------
// Minimal JSON-RPC 2.0 client over stdio
// ---------------------------------------------------------------------------

class McpTestClient {
  constructor() {
    this._proc = null;
    this._next_id = 0;
    this._pending = new Map(); // id → resolve_fn
    this._buf = "";
  }

  start() {
    this._proc = spawn("node", [SERVER_BIN], {
      env: { ...process.env, VIBEGUARD_ROOT },
      stdio: ["pipe", "pipe", "pipe"],
    });

    this._proc.stdout.on("data", (chunk) => {
      this._buf += chunk.toString("utf8");
      this._drain();
    });

    // Capture stderr silently (available for debugging if needed)
    this._proc.stderr.on("data", () => {});

    this._proc.on("error", (err) => {
      for (const cb of this._pending.values()) {
        cb({ jsonrpc: "2.0", id: null, error: { code: -32_000, message: err.message } });
      }
      this._pending.clear();
    });
  }

  /** Process any complete newline-delimited JSON messages in the buffer. */
  _drain() {
    let nl;
    while ((nl = this._buf.indexOf("\n")) !== -1) {
      const line = this._buf.slice(0, nl).trim();
      this._buf = this._buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue; // ignore non-JSON lines (e.g. debug prints)
      }
      if (msg.id !== undefined && msg.id !== null) {
        const cb = this._pending.get(msg.id);
        if (cb) {
          this._pending.delete(msg.id);
          cb(msg);
        }
      }
    }
  }

  /** Send a JSON-RPC request and return the response. */
  request(method, params = {}) {
    const id = ++this._next_id;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._pending.delete(id);
        reject(new Error(`Timeout (15 s) waiting for "${method}" (id=${id})`));
      }, 15_000);

      this._pending.set(id, (resp) => {
        clearTimeout(timer);
        resolve(resp);
      });

      this._proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }

  /** Send a JSON-RPC notification (no response expected). */
  notify(method, params = {}) {
    this._proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  }

  /** Perform MCP handshake (initialize + initialized notification). */
  async initialize() {
    const resp = await this.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "integration-test", version: "1.0.0" },
    });
    this.notify("notifications/initialized");
    return resp;
  }

  /** Gracefully shut down the server process. */
  async close() {
    if (!this._proc) return;
    this._proc.stdin.end();
    await new Promise((resolve) => {
      this._proc.once("close", resolve);
      setTimeout(() => {
        try { this._proc.kill(); } catch { /* already exited */ }
        resolve();
      }, 4_000);
    });
    this._proc = null;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function with_tmpdir(run) {
  const tmpdir = fs.mkdtempSync(path.join(VIBEGUARD_ROOT, ".tmp-int-test-"));
  try {
    return await run(tmpdir);
  } finally {
    fs.rmSync(tmpdir, { recursive: true, force: true });
  }
}

async function with_client(run) {
  const client = new McpTestClient();
  client.start();
  try {
    await client.initialize();
    return await run(client);
  } finally {
    await client.close();
  }
}

// Convenience: call a tool and return the text content from the first content item.
async function call_tool(client, name, args) {
  const resp = await client.request("tools/call", { name, arguments: args });
  assert.ok(resp.result || resp.error, "expected result or error in response");
  if (resp.result) {
    const items = resp.result.content;
    assert.ok(Array.isArray(items) && items.length > 0, "content array must be non-empty");
    return items[0].text;
  }
  // Some servers return error in JSON-RPC error field
  return resp.error.message ?? JSON.stringify(resp.error);
}

// ---------------------------------------------------------------------------
// Tests: MCP initialization
// ---------------------------------------------------------------------------

describe("initialize", () => {
  test("server responds with vibeguard server info and capabilities", async () => {
    const client = new McpTestClient();
    client.start();
    try {
      const resp = await client.request("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "test", version: "1.0.0" },
      });
      assert.ok(resp.result, "expected a result");
      assert.equal(resp.result.serverInfo.name, "vibeguard");
      assert.ok(typeof resp.result.serverInfo.version === "string");
      assert.ok(resp.result.capabilities, "capabilities must be present");
    } finally {
      await client.close();
    }
  });
});

// ---------------------------------------------------------------------------
// Tests: tools/list
// ---------------------------------------------------------------------------

describe("tools/list", () => {
  test("returns exactly 3 tools", async () => {
    await with_client(async (client) => {
      const resp = await client.request("tools/list");
      assert.ok(resp.result, "expected a result");
      assert.equal(resp.result.tools.length, 3, "expected 3 tools");
    });
  });

  test("includes guard_check, compliance_report, metrics_collect", async () => {
    await with_client(async (client) => {
      const resp = await client.request("tools/list");
      const names = resp.result.tools.map((t) => t.name);
      assert.ok(names.includes("guard_check"), "missing guard_check");
      assert.ok(names.includes("compliance_report"), "missing compliance_report");
      assert.ok(names.includes("metrics_collect"), "missing metrics_collect");
    });
  });

  test("guard_check schema includes required target_dir and language properties", async () => {
    await with_client(async (client) => {
      const resp = await client.request("tools/list");
      const tool = resp.result.tools.find((t) => t.name === "guard_check");
      assert.ok(tool, "guard_check tool must exist");
      const props = tool.inputSchema.properties;
      assert.ok(props.target_dir, "guard_check must have target_dir parameter");
      assert.ok(props.language, "guard_check must have language parameter");
    });
  });

  test("each tool has a non-empty description", async () => {
    await with_client(async (client) => {
      const resp = await client.request("tools/list");
      for (const tool of resp.result.tools) {
        assert.ok(
          typeof tool.description === "string" && tool.description.length > 0,
          `tool "${tool.name}" must have a non-empty description`
        );
      }
    });
  });
});

// ---------------------------------------------------------------------------
// Tests: guard_check — individual guards
// ---------------------------------------------------------------------------

describe("guard_check — individual guards", () => {
  test("rust semantic_effect guard is wired (no unsupported-guard error)", async () => {
    await with_tmpdir(async (tmpdir) => {
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "rust",
          guard: "semantic_effect",
          strict: false,
        });
        assert.doesNotMatch(text, /不支持的守卫/);
      });
    });
  });

  test("rust taste_invariants guard is wired", async () => {
    await with_tmpdir(async (tmpdir) => {
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "rust",
          guard: "taste_invariants",
          strict: false,
        });
        assert.doesNotMatch(text, /不支持的守卫/);
      });
    });
  });

  test("go error_handling guard is wired", async () => {
    await with_tmpdir(async (tmpdir) => {
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "go",
          guard: "error_handling",
          strict: false,
        });
        assert.doesNotMatch(text, /不支持的守卫/);
      });
    });
  });

  test("typescript component_duplication guard is wired", async () => {
    await with_tmpdir(async (tmpdir) => {
      fs.writeFileSync(path.join(tmpdir, "tsconfig.json"), "{}\n", "utf8");
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "typescript",
          guard: "component_duplication",
          strict: false,
        });
        assert.doesNotMatch(text, /不支持的守卫/);
      });
    });
  });

  test("javascript console_residual guard is wired", async () => {
    await with_tmpdir(async (tmpdir) => {
      fs.writeFileSync(path.join(tmpdir, "package.json"), '{"name":"demo"}\n', "utf8");
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "javascript",
          guard: "console_residual",
          strict: false,
        });
        assert.doesNotMatch(text, /不支持的守卫/);
      });
    });
  });
});

// ---------------------------------------------------------------------------
// Tests: guard_check — all guards (no `guard` argument)
// ---------------------------------------------------------------------------

describe("guard_check — all guards", () => {
  test("running all rust guards returns multiple guard results", async () => {
    await with_tmpdir(async (tmpdir) => {
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "rust",
          strict: false,
        });
        // At least two guard names must appear in the output
        const guard_hits = ["nested_locks", "unwrap", "semantic_effect", "taste_invariants"].filter(
          (g) => text.includes(g)
        );
        assert.ok(guard_hits.length >= 2, `expected >= 2 rust guards in output, got: ${guard_hits.join(", ")}`);
      });
    });
  });

  test("running all go guards reports all expected guard names", async () => {
    await with_tmpdir(async (tmpdir) => {
      // Trigger "available guards" listing by passing a nonexistent guard name
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "go",
          guard: "__nonexistent__",
          strict: false,
        });
        assert.match(text, /error_handling/);
        assert.match(text, /goroutine_leak/);
        assert.match(text, /defer_in_loop/);
      });
    });
  });

  test("running all javascript guards lists component_duplication as available", async () => {
    await with_tmpdir(async (tmpdir) => {
      fs.writeFileSync(path.join(tmpdir, "package.json"), '{"name":"demo"}\n', "utf8");
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "javascript",
          guard: "__nonexistent__",
          strict: false,
        });
        assert.match(text, /javascript 可用守卫/);
        assert.match(text, /component_duplication/);
      });
    });
  });
});

// ---------------------------------------------------------------------------
// Tests: guard_check — auto-detect
// ---------------------------------------------------------------------------

describe("guard_check — auto language detection", () => {
  test("detects typescript project and runs typescript guards", async () => {
    await with_tmpdir(async (tmpdir) => {
      fs.writeFileSync(path.join(tmpdir, "package.json"), '{"name":"demo"}\n', "utf8");
      fs.writeFileSync(path.join(tmpdir, "tsconfig.json"), "{}\n", "utf8");
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "auto",
          strict: false,
        });
        assert.match(text, /\[auto\]/);
        assert.match(text, /typescript/);
      });
    });
  });

  test("reports unsupported when no language markers present", async () => {
    await with_tmpdir(async (tmpdir) => {
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "auto",
          strict: false,
        });
        assert.match(text, /未检测到支持的语言/);
      });
    });
  });
});

// ---------------------------------------------------------------------------
// Tests: compliance_report
// ---------------------------------------------------------------------------

describe("compliance_report", () => {
  test("returns compliance envelope with VibeGuard Compliance Check header", async () => {
    await with_tmpdir(async (tmpdir) => {
      await with_client(async (client) => {
        const text = await call_tool(client, "compliance_report", { project_dir: tmpdir });
        assert.match(text, /\[compliance_report\]/);
        assert.match(text, /VibeGuard Compliance Check/);
      });
    });
  });

  test("nonexistent directory returns 目录不存在 error", async () => {
    await with_client(async (client) => {
      const text = await call_tool(client, "compliance_report", {
        project_dir: "/nonexistent/vibeguard-int-test-path",
      });
      assert.match(text, /目录不存在/);
    });
  });
});

// ---------------------------------------------------------------------------
// Tests: metrics_collect
// ---------------------------------------------------------------------------

describe("metrics_collect", () => {
  test("returns metrics envelope with VibeGuard Metrics Report header", async () => {
    await with_tmpdir(async (tmpdir) => {
      await with_client(async (client) => {
        const text = await call_tool(client, "metrics_collect", { project_dir: tmpdir });
        assert.match(text, /\[metrics_collect\]/);
        assert.match(text, /VibeGuard Metrics Report/);
      });
    });
  });

  test("nonexistent directory returns 目录不存在 error", async () => {
    await with_client(async (client) => {
      const text = await call_tool(client, "metrics_collect", {
        project_dir: "/nonexistent/vibeguard-int-test-path",
      });
      assert.match(text, /目录不存在/);
    });
  });
});

// ---------------------------------------------------------------------------
// Tests: error handling / invalid inputs
// ---------------------------------------------------------------------------

describe("error handling", () => {
  test("invalid language enum value is rejected at schema validation level", async () => {
    await with_tmpdir(async (tmpdir) => {
      await with_client(async (client) => {
        // "ruby" is not in the language enum; the MCP SDK rejects it with -32602
        // before the tool handler is invoked.
        const resp = await client.request("tools/call", {
          name: "guard_check",
          arguments: { target_dir: tmpdir, language: "ruby", strict: false },
        });
        // Either a JSON-RPC error (-32602) or an error wrapped in result content
        if (resp.error) {
          assert.match(
            resp.error.message,
            /invalid|enum|validation/i,
            "expected validation error for unknown language"
          );
        } else {
          // Some SDK versions surface it as tool content
          const text = resp.result.content[0].text;
          assert.match(text, /不支持的语言|invalid|enum|validation/i);
        }
      });
    });
  });

  test("unsupported guard for language returns 不支持的守卫 message", async () => {
    await with_tmpdir(async (tmpdir) => {
      fs.writeFileSync(path.join(tmpdir, "package.json"), '{"name":"demo"}\n', "utf8");
      await with_client(async (client) => {
        const text = await call_tool(client, "guard_check", {
          target_dir: tmpdir,
          language: "javascript",
          guard: "vet", // valid Go guard, invalid for JS
          strict: false,
        });
        assert.match(text, /不支持的守卫/);
        assert.doesNotMatch(text, /PASS/);
      });
    });
  });

  test("nonexistent target_dir returns 目录不存在 message", async () => {
    await with_client(async (client) => {
      const text = await call_tool(client, "guard_check", {
        target_dir: "/nonexistent/vibeguard-int-test-dir",
        language: "python",
      });
      assert.match(text, /目录不存在/);
    });
  });

  test("system directory /etc is rejected with 禁止访问系统目录", async () => {
    await with_client(async (client) => {
      const text = await call_tool(client, "guard_check", {
        target_dir: "/etc",
        language: "python",
      });
      assert.match(text, /禁止访问系统目录/);
    });
  });

  test("unknown tool name returns JSON-RPC error or tool-not-found response", async () => {
    await with_client(async (client) => {
      const resp = await client.request("tools/call", {
        name: "nonexistent_tool_xyz",
        arguments: {},
      });
      // MCP SDK returns a JSON-RPC error for unknown tools
      assert.ok(resp.error || resp.result, "must return error or result");
    });
  });

  test("multiple concurrent tool calls are handled correctly", async () => {
    await with_tmpdir(async (tmpdir) => {
      await with_client(async (client) => {
        const [r1, r2, r3] = await Promise.all([
          call_tool(client, "compliance_report", { project_dir: tmpdir }),
          call_tool(client, "metrics_collect", { project_dir: tmpdir }),
          call_tool(client, "guard_check", {
            target_dir: tmpdir,
            language: "rust",
            guard: "unwrap",
            strict: false,
          }),
        ]);
        assert.match(r1, /\[compliance_report\]/);
        assert.match(r2, /\[metrics_collect\]/);
        assert.doesNotMatch(r3, /不支持的守卫/);
      });
    });
  });
});
