import path from "node:path";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { set_vibeguard_root } from "./executor.js";
import {
  handle_guard_check,
  handle_compliance_report,
  handle_metrics_collect,
} from "./tools.js";

// vibeguard 根目录：优先使用 VIBEGUARD_ROOT 环境变量，兜底通过文件路径推导
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const vibeguard_root =
  process.env.VIBEGUARD_ROOT || path.resolve(__dirname, "..", "..");
set_vibeguard_root(vibeguard_root);

const server = new McpServer({
  name: "vibeguard",
  version: "1.0.0",
});

server.tool(
  "guard_check",
  "运行语言特定的守卫检查（重复检测、命名规范、代码质量、嵌套锁、unwrap 等）",
  {
    target_dir: z.string().describe("目标项目目录绝对路径"),
    language: z.enum(["python", "rust"]).describe("项目语言"),
    guard: z
      .string()
      .optional()
      .describe(
        "守卫名称。python: duplicates/naming/quality；rust: nested_locks/unwrap/duplicate_types。不指定则运行该语言全部守卫"
      ),
    strict: z
      .boolean()
      .optional()
      .default(false)
      .describe("严格模式，发现问题时返回非零退出码"),
  },
  async (params) => {
    const text = await handle_guard_check({
      target_dir: params.target_dir,
      language: params.language,
      guard: params.guard,
      strict: params.strict,
    });
    return { content: [{ type: "text", text }] };
  }
);

server.tool(
  "compliance_report",
  "运行合规检查，返回 PASS/WARN/FAIL 报告",
  {
    project_dir: z.string().describe("目标项目目录绝对路径"),
  },
  async (params) => {
    const text = await handle_compliance_report({
      project_dir: params.project_dir,
    });
    return { content: [{ type: "text", text }] };
  }
);

server.tool(
  "metrics_collect",
  "收集项目量化指标报告",
  {
    project_dir: z.string().describe("目标项目目录绝对路径"),
  },
  async (params) => {
    const text = await handle_metrics_collect({
      project_dir: params.project_dir,
    });
    return { content: [{ type: "text", text }] };
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("vibeguard mcp server failed:", err);
  process.exit(1);
});
