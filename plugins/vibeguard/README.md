# VibeGuard Codex plugin

One explicit help skill handles VibeGuard installation, diagnostics, and rule lookup. It does not inject all rules or add hooks independently.

Install the Rust CLI using [the repository instructions](../../README.md). Its native installer owns hooks. This directory can be distributed through Codex's plugin system; it has no MCP server, connector, personal marketplace mutation, or telemetry.

See [plugin.json](.codex-plugin/plugin.json) and [the skill](skills/vibeguard/SKILL.md).
