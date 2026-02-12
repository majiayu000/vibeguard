# VibeGuard

AI 辅助开发防幻觉框架。通过七层防御架构系统性阻止 LLM 代码生成中的常见失效模式。

## 快速开始

```bash
# 1. Clone 仓库
git clone <repo-url> ~/Desktop/code/AI/tools/vibeguard

# 2. 一键部署到 ~/.claude/ 和 ~/.codex/
bash ~/Desktop/code/AI/tools/vibeguard/setup.sh

# 3. 验证安装
bash ~/Desktop/code/AI/tools/vibeguard/setup.sh --check
```

## 核心功能

| 功能 | 说明 |
|------|------|
| **CLAUDE.md 规则** | 自动追加防幻觉规则到全局 CLAUDE.md |
| **vibeguard Skill** | 调用 `/vibeguard` 查阅完整规范 |
| **auto-optimize** | 调用 `/auto-optimize` 自主扫描 + 修复项目问题（整合守卫体系） |
| **Workflow Skills** | plan-folw / fixflow / optflow / plan-mode |
| **Python Guards** | 架构守卫、命名检查、重复检测模板 |
| **项目模板** | Python / TypeScript / Rust CLAUDE.md 模板 |
| **合规检查** | 一键检查项目是否符合 VibeGuard 规范 |

## 仓库结构

```
vibeguard/
├── spec.md              # 完整规范文档（七层架构 + 量化指标 + 案例）
├── setup.sh             # 一键部署
├── claude-md/           # CLAUDE.md 追加规则
├── skills/vibeguard/    # 防幻觉规范 Skill
├── workflows/           # 执行流程 Skills
│   ├── plan-folw/       #   冗余分析 + 计划构建
│   ├── fixflow/         #   工程交付流
│   ├── optflow/         #   优化发现与执行
│   ├── plan-mode/       #   计划落地
│   └── auto-optimize/   #   自主优化（守卫扫描 + LLM 深度分析 + 自动执行）
├── guards/              # 通用守卫模板（Python / TypeScript）
├── project-templates/   # 新项目 CLAUDE.md 模板
└── scripts/             # 合规检查 + 指标采集
```

## 新项目接入

```bash
# 1. 复制守卫到项目
cp vibeguard/guards/python/test_code_quality_guards.py my-project/tests/architecture/
cp vibeguard/guards/python/check_duplicates.py my-project/scripts/
cp vibeguard/guards/python/check_naming_convention.py my-project/scripts/
cp vibeguard/guards/python/pre-commit-config.yaml my-project/.pre-commit-config.yaml

# 2. 复制 CLAUDE.md 模板
cp vibeguard/project-templates/python-CLAUDE.md my-project/CLAUDE.md

# 3. 修改配置（路径、豁免列表等）

# 4. 检查合规
bash vibeguard/scripts/compliance_check.sh my-project/
```

## 换电脑恢复

```bash
# Clone 仓库后运行 setup.sh 即可恢复所有配置
git clone <repo-url> ~/Desktop/code/AI/tools/vibeguard
bash ~/Desktop/code/AI/tools/vibeguard/setup.sh
```
