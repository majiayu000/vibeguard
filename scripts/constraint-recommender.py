#!/usr/bin/env python3
"""VibeGuard Preflight 约束自动推荐器

基于项目探索结果（语言、框架、文件模式）自动生成约束初稿。
信心度分级：high（自动接受）/ medium（提示确认）/ low（需讨论）。

用法：
  python3 constraint-recommender.py <project_dir>
  python3 constraint-recommender.py <project_dir> --json
"""

import json
import os
import re
import sys
from pathlib import Path


def detect_languages(project_dir: str) -> list[dict]:
    """检测项目使用的语言和框架"""
    results = []
    p = Path(project_dir)

    # Rust
    if (p / "Cargo.toml").exists():
        workspace = False
        try:
            content = (p / "Cargo.toml").read_text()
            workspace = "[workspace]" in content
        except Exception:
            pass
        results.append({
            "language": "rust",
            "framework": "workspace" if workspace else "crate",
            "config": "Cargo.toml",
        })

    # TypeScript / JavaScript
    if (p / "package.json").exists():
        framework = "node"
        try:
            pkg = json.loads((p / "package.json").read_text())
            deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
            if "next" in deps:
                framework = "next"
            elif "react" in deps:
                framework = "react"
            elif "vue" in deps:
                framework = "vue"
            elif "express" in deps:
                framework = "express"
        except Exception:
            pass
        results.append({
            "language": "typescript" if (p / "tsconfig.json").exists() else "javascript",
            "framework": framework,
            "config": "package.json",
        })

    # Python
    for cfg in ["pyproject.toml", "setup.py", "requirements.txt"]:
        if (p / cfg).exists():
            framework = "python"
            try:
                if cfg == "pyproject.toml":
                    content = (p / cfg).read_text()
                    if "django" in content.lower():
                        framework = "django"
                    elif "fastapi" in content.lower():
                        framework = "fastapi"
                    elif "flask" in content.lower():
                        framework = "flask"
            except Exception:
                pass
            results.append({
                "language": "python",
                "framework": framework,
                "config": cfg,
            })
            break

    # Go
    if (p / "go.mod").exists():
        results.append({
            "language": "go",
            "framework": "go",
            "config": "go.mod",
        })

    return results


def scan_patterns(project_dir: str, languages: list[dict]) -> dict:
    """扫描项目中的常见模式"""
    p = Path(project_dir)
    patterns = {
        "has_tests": False,
        "has_ci": False,
        "has_docker": False,
        "has_env_file": False,
        "entry_points": [],
        "db_paths": [],
        "env_vars": [],
    }

    # 检测常见目录/文件
    patterns["has_tests"] = any(
        (p / d).exists() for d in ["tests", "test", "__tests__", "spec"]
    )
    patterns["has_ci"] = (p / ".github").exists() or (p / ".gitlab-ci.yml").exists()
    patterns["has_docker"] = (p / "Dockerfile").exists() or (p / "docker-compose.yml").exists()
    patterns["has_env_file"] = (p / ".env").exists() or (p / ".env.example").exists()

    # 扫描入口点
    lang_set = {l["language"] for l in languages}
    if "rust" in lang_set:
        for main in p.rglob("main.rs"):
            if "target" not in str(main):
                patterns["entry_points"].append(str(main.relative_to(p)))
    if "go" in lang_set:
        for main in p.rglob("main.go"):
            if "vendor" not in str(main):
                patterns["entry_points"].append(str(main.relative_to(p)))
    if "python" in lang_set:
        for candidate in ["app.py", "main.py", "manage.py", "wsgi.py"]:
            if (p / candidate).exists():
                patterns["entry_points"].append(candidate)

    return patterns


def generate_constraints(
    languages: list[dict], patterns: dict
) -> list[dict]:
    """生成约束推荐"""
    constraints = []
    c_id = 1

    lang_set = {l["language"] for l in languages}

    # --- 高信心度约束（自动接受） ---

    # 错误处理约束
    if "rust" in lang_set:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "错误处理",
            "description": "非测试代码禁止 unwrap()，使用 ? 或 map_err",
            "confidence": "high",
            "source": "Rust 项目检测",
            "verify": "guards/rust/check_unwrap_in_prod.sh",
        })
        c_id += 1

    if "go" in lang_set:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "错误处理",
            "description": "error 返回值必须检查，禁止赋值给 _",
            "confidence": "high",
            "source": "Go 项目检测",
            "verify": "guards/go/check_error_handling.sh",
        })
        c_id += 1

    if "typescript" in lang_set or "javascript" in lang_set:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "类型安全",
            "description": "禁止使用 as any 和 @ts-ignore 绕过类型检查",
            "confidence": "high",
            "source": "TypeScript 项目检测",
            "verify": "guards/typescript/check_any_abuse.sh",
        })
        c_id += 1

    # 命名约束
    constraints.append({
        "id": f"C-{c_id:02d}",
        "category": "命名一致",
        "description": "snake_case 命名（API 边界 camelCase）",
        "confidence": "high",
        "source": "VibeGuard 通用规范",
        "verify": "guards/python/check_naming_convention.py",
    })
    c_id += 1

    # 类型唯一
    if "rust" in lang_set:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "类型唯一",
            "description": "不新增与现有类型重名的 pub struct/enum 定义",
            "confidence": "high",
            "source": "Rust workspace 检测",
            "verify": "guards/rust/check_duplicate_types.sh",
        })
        c_id += 1

    if "python" in lang_set:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "类型唯一",
            "description": "不新增重复的 Protocol/class 定义",
            "confidence": "high",
            "source": "Python 项目检测",
            "verify": "guards/python/check_duplicates.py",
        })
        c_id += 1

    # --- 中等信心度约束（提示确认） ---

    # 数据收敛
    if len(patterns["entry_points"]) > 1:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "数据收敛",
            "description": "所有入口的数据路径必须通过公共函数获取",
            "confidence": "medium",
            "source": f"检测到 {len(patterns['entry_points'])} 个入口点",
            "verify": "人工检查数据路径一致性",
        })
        c_id += 1

    # 测试约束
    if patterns["has_tests"]:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "测试覆盖",
            "description": "新增功能必须附带对应测试",
            "confidence": "medium",
            "source": "检测到 tests/ 目录",
            "verify": "运行项目测试套件",
        })
        c_id += 1

    # 环境变量
    if patterns["has_env_file"]:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "配置安全",
            "description": "禁止修改 .env 文件，新增环境变量需更新 .env.example",
            "confidence": "medium",
            "source": "检测到 .env 文件",
            "verify": "git diff --name-only 检查",
        })
        c_id += 1

    # Docker
    if patterns["has_docker"]:
        constraints.append({
            "id": f"C-{c_id:02d}",
            "category": "部署一致",
            "description": "修改依赖时同步更新 Dockerfile",
            "confidence": "medium",
            "source": "检测到 Dockerfile",
            "verify": "docker build 验证",
        })
        c_id += 1

    # --- 低信心度约束（需讨论） ---

    # 安全约束
    constraints.append({
        "id": f"C-{c_id:02d}",
        "category": "安全",
        "description": "新增 API 端点必须有认证/授权检查",
        "confidence": "low",
        "source": "VibeGuard 安全规范 (SEC-04)",
        "verify": "代码审查",
    })
    c_id += 1

    return constraints


def main():
    if len(sys.argv) < 2:
        print("用法: python3 constraint-recommender.py <project_dir> [--json]")
        sys.exit(1)

    project_dir = sys.argv[1]
    json_output = "--json" in sys.argv

    if not os.path.isdir(project_dir):
        print(f"目录不存在: {project_dir}")
        sys.exit(1)

    languages = detect_languages(project_dir)
    patterns = scan_patterns(project_dir, languages)
    constraints = generate_constraints(languages, patterns)

    if json_output:
        result = {
            "languages": languages,
            "patterns": {
                k: v for k, v in patterns.items()
                if not isinstance(v, list) or v
            },
            "constraints": constraints,
        }
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    # 格式化输出
    print(f"\nVibeGuard 约束推荐")
    print("=" * 40)

    print(f"\n检测到的语言/框架:")
    for lang in languages:
        print(f"  {lang['language']} ({lang['framework']}) — {lang['config']}")

    if patterns["entry_points"]:
        print(f"\n入口点:")
        for ep in patterns["entry_points"]:
            print(f"  {ep}")

    # 按信心度分组输出
    for level, label in [("high", "自动接受"), ("medium", "建议确认"), ("low", "需讨论")]:
        group = [c for c in constraints if c["confidence"] == level]
        if not group:
            continue
        print(f"\n{label} ({level}):")
        for c in group:
            print(f"  [{c['id']}] {c['category']}: {c['description']}")
            print(f"        来源: {c['source']}")
            print(f"        验证: {c['verify']}")

    print(f"\n共 {len(constraints)} 条约束推荐")
    high = sum(1 for c in constraints if c["confidence"] == "high")
    medium = sum(1 for c in constraints if c["confidence"] == "medium")
    low = sum(1 for c in constraints if c["confidence"] == "low")
    print(f"  high: {high}, medium: {medium}, low: {low}")
    print()


if __name__ == "__main__":
    main()
