# VibeGuard 分步修复手册

## 目标

按 `P0 -> P1 -> P2` 顺序收敛风险，确保每一步都可验证、可回滚。

## 执行进度（2026-02-26）

- `DONE` Step 0: 基线回归（`tests/test_hooks.sh`）
- `DONE` Phase 1 / Step 1.1: `setup.sh` 薄入口路由 + `scripts/setup/{install,check,clean}.sh`
- `DONE` Phase 1 / Step 1.2: 提取 `scripts/lib/settings_json.py`，集中管理 settings 的 check/upsert/remove
- `DONE` Phase 1 / Step 1.3: 新增 `tests/test_setup.sh`，覆盖 `check/install/clean` 最小回归
- `DONE` Phase 2 / Step 2.1-2.2: `post-write-guard` 改为 `rg` 快路径并加入扫描预算降级
- `DONE` Phase 2 / Step 2.3: 新增 `post-write` 关键测试用例（同名、重复定义、降级）
- `DONE` Phase 3 / Step 3.1: MCP 守卫执行增加并发上限（`VIBEGUARD_GUARD_CONCURRENCY`）+ 单守卫异常隔离
- `DONE` Phase 3 / Step 3.2（部分）: MCP 增加 `javascript` 语言支持并与 TS 守卫对齐
- `DONE` Phase 3 / Step 3.3（基础）: 新增 `mcp-server` 测试（语言检测与 javascript 支持）
- `DONE` Phase 4 / Step 4.1: 接入 `.github/workflows/ci.yml`（validate + hooks/setup 测试 + MCP build/test）
- `DONE` P0 Contract: 新增 `scripts/ci/validate-config-contract.sh`，校验 `index.ts schema` / `tools.ts runtime` / `README` 三方一致
- `DONE` P0 Rule: `rules/universal.md` 新增 `U-23`（禁止静默降级）
- `DONE` P1 Guard: Rust 新增 `single_source_of_truth` / `semantic_effect` 守卫并接入 MCP
- `DONE` P1 Test: 新增 `tests/test_rust_guards.sh` 并接入 CI
- `DONE` P1 Wiring: 新增 `scripts/ci/validate-wiring-contract.sh`（Rust guard 实现/接线/文档一致性）
- `TODO` Phase 4 / Step 4.2: 仓库设置中启用“PR 必须通过 CI 才可合并”
- `DONE` Phase 5 / Step 5.2（部分）: setup 增加 `plan-flow` 兼容别名，保留 `plan-folw` 向后兼容
- `TODO` Phase 5: 公共库进一步收敛（hooks/scripts 共享库）与命名迁移文档

## Step 0: 固化基线（必须先做）

### 改动

- 不改业务逻辑，只记录基线状态与耗时。

### 命令

```bash
cd /Users/apple/Desktop/code/AI/tool/vibeguard
bash tests/test_hooks.sh
git status --short
```

### 通过标准

- hooks 用例全通过。
- 工作区状态可解释（无未知脏改动）。

---

## Phase 1（P0）: 拆分 setup 与公共能力提取

### Step 1.1 拆分入口

### 改动

- 保留 `setup.sh` 作为薄入口，仅负责参数路由：
  - `--check` -> `scripts/setup/check.sh`
  - `--clean` -> `scripts/setup/clean.sh`
  - 默认 -> `scripts/setup/install.sh`

### Step 1.2 提取 JSON/配置助手

### 改动

- 新增 `scripts/lib/settings_json.py`（读写 `~/.claude/settings.json` 的统一助手）。
- setup/hook 中重复的 `python3 -c` JSON 逻辑迁移到公共函数。

### Step 1.3 增加 setup 回归测试

### 改动

- 新增 `tests/test_setup.sh`（覆盖 check/clean/install 的最小回归路径）。

### 验收命令

```bash
bash tests/test_hooks.sh
bash tests/test_setup.sh
bash setup.sh --check
```

### 通过标准

- 与当前外部行为兼容（命令入口不变）。
- 重复内嵌 Python 明显减少。

---

## Phase 2（P0）: post-write 性能治理

### Step 2.1 替换高开销扫描

### 改动

- 将 `find + grep -rl` 主路径改为 `rg`。
- 增加默认排除目录白名单（`.git/node_modules/dist/build/target/vendor`）。

### Step 2.2 增加扫描预算与降级策略

### 改动

- 增加环境变量：
  - `VG_SCAN_MAX_FILES`（默认如 5000）
  - `VG_SCAN_MAX_DEFS`（默认如 20）
  - `VG_SCAN_TIMEOUT_MS`（默认如 1500）
- 超预算时降级为“轻量提示”，不做深度扫描。

### Step 2.3 增加性能回归测试

### 改动

- 新增 `tests/test_post_write_perf.sh`，构造中等规模目录验证不会超时。

### 验收命令

```bash
bash tests/test_hooks.sh
bash tests/test_post_write_perf.sh
```

### 通过标准

- 常见项目下写入后 hook 延迟可控（无明显卡顿）。
- 功能语义保持：仍能给出重复文件/定义提示。

---

## Phase 3（P1）: MCP 稳定性与语言模型一致性

### Step 3.1 并发治理

### 改动

- `mcp-server/src/tools.ts` 引入并发上限（如 2）。
- 为重守卫增加超时与失败隔离（单守卫失败不影响其余守卫结果输出）。

### Step 3.2 语言模型统一

### 改动

- `index.ts` 入参支持 `javascript`（或显式 `js` 别名）。
- `detector.ts` 增加 JS 判定策略（例如 `package.json + 无 tsconfig + js 文件存在`）。
- README 与规则文档同步。

### Step 3.3 MCP 测试补齐

### 改动

- 新增 `mcp-server` 的最小单元测试（语言检测、守卫调度、错误路径）。

### 验收命令

```bash
cd mcp-server
npm run build
# 如果新增 test script:
# npm test
```

### 通过标准

- 资源占用更平滑，输出可预期。
- JS/TS 相关行为在 hooks 与 MCP 层一致。

---

## Phase 4（P1）: CI 接入与门禁自动化

### Step 4.1 接入 workflow

### 改动

- 新增 `.github/workflows/ci.yml`：
  - Shell 语法/执行权限检查
  - 规则文件校验
  - hooks/setup 测试
  - MCP build

### Step 4.2 合并质量门禁

### 改动

- PR 必须通过 CI 才可合并（仓库设置层面）。

### 验收命令

```bash
bash scripts/ci/validate-guards.sh
bash scripts/ci/validate-hooks.sh
bash scripts/ci/validate-rules.sh
```

### 通过标准

- 本地与 CI 结果一致。
- 新增回归能在 PR 阶段被自动拦截。

---

## Phase 5（P2）: 公共库与命名债务收敛

### Step 5.1 公共脚本库

### 改动

- 建立 `scripts/lib/` 与 `hooks/lib/`，沉淀：
  - JSON 读写
  - 路径过滤
  - 日志/脱敏
  - 通用错误处理

### Step 5.2 `plan-folw` 兼容迁移

### 改动

- 新增标准命名 `plan-flow`，保留 `plan-folw` 软链接与兼容检查提示。
- 文档默认使用新名，旧名标注 deprecate 时间线。

### 通过标准

- 用户可无缝迁移。
- 代码与文档命名统一，不引入破坏性变更。

---

## 里程碑建议

- M1（1-2 天）：完成 Phase 1，先降低维护风险。
- M2（2-4 天）：完成 Phase 2 + 3，解决性能和稳定性主矛盾。
- M3（1-2 天）：完成 Phase 4 + 5，补齐工程化与长期可维护性。

## 每阶段统一退出条件

- 测试通过。
- 文档更新完成（README/变更说明）。
- `git diff` 可审阅（单阶段不做超大混合改动）。
