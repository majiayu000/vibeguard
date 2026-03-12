#!/usr/bin/env bash
# RS-14: 声明-执行鸿沟检测
# 检测 Config/Trait/持久化层声明但启动时未集成的情况

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${1:-.}"
STRICT_MODE="${2:-false}"

cd "$PROJECT_ROOT"

VIOLATIONS=()

# 检测 1: Config 结构体存在但启动时用 Default::default()
check_config_default_usage() {
    local config_structs=$(rg -t rust 'struct\s+\w*Config\s*\{' --no-heading -o | sed 's/struct \(.*\)Config.*/\1Config/g' | sort -u)

    for config in $config_structs; do
        # 检查是否有 load/from_file 方法
        local has_load=$(rg -t rust "impl.*${config}" -A 20 | rg -q 'fn (load|from_file|read)' && echo "yes" || echo "no")

        if [[ "$has_load" == "yes" ]]; then
            # 检查启动代码是否调用 Default::default() 而非 load()
            local uses_default=$(rg -t rust "${config}::default\(\)" --no-heading | head -1)
            if [[ -n "$uses_default" ]]; then
                VIOLATIONS+=("[RS-14] Config 声明了 load() 但启动时用 Default::default(): ${config}")
            fi
        fi
    done
}

# 检测 2: Trait 声明但无 impl 或未注册
check_trait_implementation() {
    local traits=$(rg -t rust '^pub trait \w+' --no-heading -o | sed 's/pub trait //g' | sort -u)

    for trait in $traits; do
        local impl_count=$(rg -t rust "impl.*${trait}" --count-matches 2>/dev/null | awk '{s+=$1} END {print s+0}')

        if [[ "$impl_count" -eq 0 ]]; then
            VIOLATIONS+=("[RS-14] Trait 声明但无任何 impl: ${trait}")
        fi
    done
}

# 检测 3: 持久化方法存在但启动时从不调用
check_persistence_methods() {
    local persist_methods=$(rg -t rust 'fn (save|load|persist|restore)\(' --no-heading | grep -v 'test' | head -10)

    if [[ -n "$persist_methods" ]]; then
        # 检查 main.rs 或 lib.rs 是否调用这些方法
        local startup_files=$(find . -name 'main.rs' -o -name 'lib.rs' | head -5)

        for method in save load persist restore; do
            local has_method=$(echo "$persist_methods" | rg -q "fn ${method}\(" && echo "yes" || echo "no")
            if [[ "$has_method" == "yes" ]]; then
                local called_at_startup="no"
                for file in $startup_files; do
                    if rg -q "${method}\(" "$file" 2>/dev/null; then
                        called_at_startup="yes"
                        break
                    fi
                done

                if [[ "$called_at_startup" == "no" ]]; then
                    VIOLATIONS+=("[RS-14] 持久化方法 ${method}() 存在但启动时从不调用")
                fi
            fi
        done
    fi
}

# 检测 4: 新字段加入 struct 但构造函数未初始化
check_struct_field_initialization() {
    # 查找带有 new() 方法的 struct
    local structs_with_new=$(rg -t rust 'impl.*\{' -A 30 | rg -B 5 'fn new\(' | rg 'impl' | sed 's/impl \(.*\) {/\1/g' | sort -u)

    for struct_name in $structs_with_new; do
        # 获取 struct 定义的字段数
        local field_count=$(rg -t rust "struct ${struct_name}" -A 20 | rg '^\s+\w+:' | wc -l | tr -d ' ')

        # 获取 new() 方法中初始化的字段数
        local init_count=$(rg -t rust "impl.*${struct_name}" -A 50 | rg 'fn new\(' -A 30 | rg '^\s+\w+:' | wc -l | tr -d ' ')

        if [[ "$field_count" -gt 0 ]] && [[ "$init_count" -lt "$field_count" ]]; then
            VIOLATIONS+=("[RS-14] ${struct_name} 有 ${field_count} 个字段但 new() 只初始化 ${init_count} 个")
        fi
    done
}

# 执行检测
check_config_default_usage
check_trait_implementation
check_persistence_methods
check_struct_field_initialization

# 输出结果
if [[ ${#VIOLATIONS[@]} -gt 0 ]]; then
    echo "=== RS-14: 声明-执行鸿沟检测 ==="
    for violation in "${VIOLATIONS[@]}"; do
        echo "$violation"
    done
    echo ""
    echo "修复方法："
    echo "1. Config: 启动时显式调用 Config::load_from_file() 而非 Default::default()"
    echo "2. Trait: 添加至少一个 impl 或删除未使用的 trait"
    echo "3. 持久化: 在 main.rs 启动代码中调用 restore()/load()"
    echo "4. 字段初始化: 在所有构造函数中初始化新增字段"

    if [[ "$STRICT_MODE" == "true" ]]; then
        exit 1
    fi
else
    echo "[RS-14] ✓ 无声明-执行鸿沟"
fi
