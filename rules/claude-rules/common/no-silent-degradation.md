# No Silent Degradation Rules

## U-29: Error-driven downgrade paths must be observable at error level (strict)

If an error causes user-visible missing data or incorrect output, you must log it at `error` level or raise it. Do not use `warning` plus fallback to silently emit a wrong result.

**Decision rule**: after the downgrade, what does the user see?
- Blank or missing content -> **error**
- Placeholder text or fake data -> **error**
- Corrupted formatting -> **error**
- Optional feature unavailable while the primary flow still works -> warning (for example, cache write failure)

**Trigger scenarios**:

### Generation pipeline downgrade
```python
# BAD — fake fallback output makes the caller believe generation succeeded
except Exception as e:
    logger.warning("Card generation failed: %s", e)
    return _build_fallback_card(section_type, context)

# GOOD — surface the failure
except Exception as e:
    logger.error("[GENERATION FAILED] %s: %s", section_type, e)
    raise

# GOOD — if fallback is unavoidable, mark it explicitly as degraded output
card = _build_fallback_card(section_type, context)
card.is_fallback = True
logger.error("[FALLBACK] %s: placeholder card due to: %s", section_type, e)
return card
```

### Persistence failure
```python
# BAD — data loss is only logged as a warning
except Exception as exc:
    logger.warning("Failed to sync document: %s", exc)

# GOOD — persistence failures must be error-level
except Exception as exc:
    logger.error("Failed to sync document %s: %s", document_id, exc)
    raise
```

### State-machine violation
```python
# BAD — illegal transition logs a warning but still executes
if not self._status.can_transition_to(new_status):
    logger.warning("Invalid transition: %s -> %s", ...)
self._status = new_status  # still executes!

# GOOD — illegal transitions must be rejected
if not self._status.can_transition_to(new_status):
    logger.error("Invalid transition: %s -> %s for %s", self._status, new_status, self.id)
    raise ValueError(f"Cannot transition from {self._status} to {new_status}")
self._status = new_status
```

### Missing route / builder
```python
# BAD — missing builder warns, then silently falls back
if builder is None:
    logger.warning("Builder %s missing for %s", builder_attr, section_type)
return self._build_fallback_card(...)

# GOOD — registered-but-missing builders are code errors
if builder is None:
    raise RuntimeError(f"Builder {builder_attr} registered but not found — code error")
```

**Anti-patterns**:
- `except Exception: pass` — the worst silent swallow
- `except Exception: continue` — silently skips failed items inside a loop
- `logger.warning(...); return None` — callers forget to check and crash later
- `logger.warning(...); return default_value` — default output gets treated as valid data
- Logging errors at `debug` level — debug is often disabled in production, which is equivalent to no logging

**Mechanical checks (agent execution rules)**:
- When writing an `except` block, check whether the return value from the exception branch will be treated as a normal result by upstream code.
- When writing `logger.warning`, inspect the same line or the next line for `return` or `continue`; if present, reconsider whether it should be upgraded to `error`.
- In fallback paths, ensure the returned object is explicitly marked as degraded output.
