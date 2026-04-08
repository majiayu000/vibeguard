---
paths: **/*.py,**/pyproject.toml
---

# Pydantic 跨层模型边界规则

## U-30: 跨层 Pydantic model 必须 extra="allow"（严格）

接收外部/跨层数据的 Pydantic model 必须设置 `extra="allow"`，防止 `model_validate()` 静默丢弃未声明字段。

**"外部/跨层"定义**：
- 从 JSON/缓存反序列化（`model_validate(json_dict)`）
- 从 LLM 输出解析
- 跨 bounded context 传递
- 从前端/API 接收的复杂嵌套结构

**不需要 extra="allow" 的场景**：
- 纯内部使用的 DTO（同一模块内创建和消费）
- API request model（`extra="forbid"` 更安全）
- 配置模型（字段固定，不应有额外字段）

```python
# ❌ BAD — 默认 extra="ignore"，未声明字段被静默丢弃
class BlockProps(BaseModel):
    model_config = ConfigDict(populate_by_name=True)
    # 新增 block 类型的 props 不在这里声明 → model_validate 丢弃 → 前端渲染空白

# ✅ GOOD — extra="allow" 保留未声明字段作为安全网
class BlockProps(BaseModel):
    """extra='allow' 防止 model_validate 静默丢弃。"""
    model_config = ConfigDict(populate_by_name=True, extra="allow")
```

**新增字段的全链路追踪清单**：

```
1. 创建层：builder/factory 写入字段值                    ✅ 写入
2. 模型层：Pydantic model 声明字段 + alias               ✅ 声明
3. 序列化层：model_dump(exclude_none=True) 不会丢弃      ✅ 输出
4. 缓存层：缓存 key 包含版本号（字段变更需递增）           ✅ 失效
5. 消费层：前端 TypeScript interface 声明字段              ✅ 渲染
```

**断裂最常发生的 3 个点**：

| 断裂点 | 机制 | 症状 |
|--------|------|------|
| `model_validate` | 未声明字段被 `extra="ignore"` 丢弃 | 前端收到空 props |
| `FieldResolver` | 未在 `fieldConfig` 中声明的字段不被提取 | builder 拿到空 context |
| `model_dump(exclude_none=True)` | `None` 值字段不进入 JSON | 缓存/前端缺字段 |

**机械化检查（Agent 执行规则）**：
- 新建 Pydantic model 时，检查是否有 `model_validate()` 调用传入外部数据，如有 → 设置 `extra="allow"`
- 修改 model 字段后，搜索所有 `model_validate` 和 `model_dump` 调用点，验证数据流完整
- 给 block 新增 props 时，同步检查 `BlockProps` 是否声明了对应字段（即使有 `extra="allow"` 也应显式声明以获得类型检查）
- 给 section 新增数据字段时，检查 `fieldConfig` (asset-noir.json) 是否声明了该字段

## U-31: 缓存 key 必须包含代码版本（严格）

修改 builder/生成逻辑后，旧缓存必须自动失效。缓存 key 需包含代码版本维度。

```python
# ❌ BAD — 缓存 key 只基于输入数据
key = hash(section_type + data_hash + prompt_hash)
# 修改 builder 逻辑 → key 不变 → 返回旧格式卡片

# ✅ GOOD — 包含代码版本
BUILDER_VERSION = "v3"  # 每次修改 builder 逻辑时递增
key = hash(section_type + data_hash + prompt_hash + BUILDER_VERSION)
```

**触发版本递增的修改**：
- `card_builders/*.py` 中的 `build()` 逻辑
- `block_builders.py` 中的 block 创建逻辑
- `docmodel.py` 中的模型字段变更
- 模板 JSON 中的 `sectionDefaults` 变更
