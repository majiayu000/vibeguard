
# 禁止静默降级规则

## U-29: 错误降级必须 error 级别可观测（严格）

错误导致用户可见的数据缺失或输出错误时，必须 `logger.error` 或 `raise`，禁止 `logger.warning` + fallback 静默产出错误结果。

**判断标准**：降级后用户看到的是什么？
- 空白/缺失内容 → **error**
- 占位文本/假数据 → **error**
- 格式错乱 → **error**
- 可选功能缺失但主流程正常 → warning（如缓存写入失败）

**触发场景**：

### 生成管线降级
```python
# ❌ BAD — 生成失败造假卡片，上层以为成功
except Exception as e:
    logger.warning("Card generation failed: %s", e)
    return _build_fallback_card(section_type, context)

# ✅ GOOD — 失败就向上传播
except Exception as e:
    logger.error("[GENERATION FAILED] %s: %s", section_type, e)
    raise

# ✅ GOOD — 如果必须 fallback，标记降级状态
card = _build_fallback_card(section_type, context)
card.is_fallback = True
logger.error("[FALLBACK] %s: placeholder card due to: %s", section_type, e)
return card
```

### 持久化失败
```python
# ❌ BAD — 数据丢失只 warn
except Exception as exc:
    logger.warning("Failed to sync document: %s", exc)

# ✅ GOOD — 持久化失败必须 error
except Exception as exc:
    logger.error("Failed to sync document %s: %s", document_id, exc)
    raise
```

### 状态机违规
```python
# ❌ BAD — 非法转换 warn 后仍执行
if not self._status.can_transition_to(new_status):
    logger.warning("Invalid transition: %s -> %s", ...)
self._status = new_status  # 仍然执行了！

# ✅ GOOD — 非法转换拒绝执行
if not self._status.can_transition_to(new_status):
    logger.error("Invalid transition: %s -> %s for %s", self._status, new_status, self.id)
    raise ValueError(f"Cannot transition from {self._status} to {new_status}")
self._status = new_status
```

### 路由/Builder 缺失
```python
# ❌ BAD — builder 找不到只 warn 走 fallback
if builder is None:
    logger.warning("Builder %s missing for %s", builder_attr, section_type)
return self._build_fallback_card(...)

# ✅ GOOD — 注册了但找不到是代码错误
if builder is None:
    raise RuntimeError(f"Builder {builder_attr} registered but not found — code error")
```

**反模式**：
- `except Exception: pass` — 最严重的静默吞异常
- `except Exception: continue` — 循环内静默跳过失败项
- `logger.warning(...); return None` — 调用方不检查 None 就崩
- `logger.warning(...); return default_value` — 默认值被当正常数据使用
- `logger.debug(...)` 记录错误 — debug 级别在生产环境默认不输出，等于没记

**机械化检查（Agent 执行规则）**：
- 写 `except` 块时，检查 except 分支的返回值是否会被上层当成正常结果
- 写 `logger.warning` 时，检查同行或下一行是否有 `return`/`continue`，如有则审视是否应升级为 error
- 在 fallback 路径中，检查返回的对象是否有标记表明它是降级产物
