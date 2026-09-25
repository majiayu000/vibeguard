# Security policy

Report vulnerabilities privately to **1835304752@qq.com**, with subject `[VibeGuard Security] <brief description>`. Include version/commit, platform and host, reproduction, impact, and proposed mitigation. Do not include real credentials or publish private exploit details in an issue.

Acknowledgment target: 48 hours; initial assessment: 7 days; high/critical remediation: 30 days; medium/low: 90 days. Coordinate disclosure when a fix is available or after the 90-day window. Follow up at the same address if acknowledgment is missing. Credit is optional; there is no monetary bounty.

The maintained source is main. Use fixed source or release and explicitly reinstall the affected integration to update its copied binary.

Relevant reports include installer path injection, unintended changes to user-managed files, credential exposure, malformed protocol handling, and incorrect behavior within documented check coverage.

VibeGuard is not a security boundary. The Bash recognizer does not parse all shell syntax, follow scripts/substitutions, or intercept every tool. Local Git hooks are bypassable. Host permissions/sandboxing and remote protection remain necessary. See [the contract](docs/runtime-contract.md).

V2 has no network client or telemetry upload. It retains one latest observation per host without raw commands or output. Paths and tool-use IDs may still be sensitive. Review source and host hook trust before enabling integration.
