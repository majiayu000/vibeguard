#[derive(Debug, Clone, Copy)]
pub(crate) enum FieldKind {
    Integer { minimum: u64, maximum: u64 },
    StringEnum { allowed: &'static [&'static str] },
    StringArray { maximum_items: usize },
    Version,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct RuntimeConfigField {
    pub path: &'static str,
    pub env: Option<&'static str>,
    pub default: &'static str,
    pub kind: FieldKind,
    pub category: &'static str,
    pub description: &'static str,
}

pub(crate) const RUNTIME_CONFIG_FIELDS: &[RuntimeConfigField] = &[
    RuntimeConfigField {
        path: "version",
        env: None,
        default: "1",
        kind: FieldKind::Version,
        category: "schema",
        description: "Runtime configuration schema version.",
    },
    RuntimeConfigField {
        path: "u16.warn_limit",
        env: Some("VG_U16_WARN_LIMIT"),
        default: "400",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
        category: "u16",
        description: "Source-file line count that produces a U-16 advisory.",
    },
    RuntimeConfigField {
        path: "u16.limit",
        env: Some("VG_U16_LIMIT"),
        default: "800",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
        category: "u16",
        description: "Source-file line count that reaches the U-16 hard limit.",
    },
    RuntimeConfigField {
        path: "circuit_breaker.threshold",
        env: Some("VG_CB_THRESHOLD"),
        default: "3",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
        category: "circuit_breaker",
        description: "Consecutive blocks before the hook circuit opens.",
    },
    RuntimeConfigField {
        path: "circuit_breaker.cooldown_seconds",
        env: Some("VG_CB_COOLDOWN"),
        default: "300",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 31_536_000,
        },
        category: "circuit_breaker",
        description: "Seconds an open circuit waits before a half-open probe.",
    },
    RuntimeConfigField {
        path: "circuit_breaker.lock_timeout_seconds",
        env: Some("VG_CB_LOCK_TIMEOUT_SECONDS"),
        default: "5",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 300,
        },
        category: "circuit_breaker",
        description: "Seconds to wait for the circuit-breaker state lock.",
    },
    RuntimeConfigField {
        path: "w14.cooldown_seconds",
        env: Some("VIBEGUARD_W14_COOLDOWN_SECONDS"),
        default: "3600",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 31_536_000,
        },
        category: "history",
        description: "Seconds before the same W-14 overlap may be reported again.",
    },
    RuntimeConfigField {
        path: "churn.informational_edit_count",
        env: Some("VIBEGUARD_CHURN_INFORMATIONAL_EDIT_COUNT"),
        default: "5",
        kind: FieldKind::Integer {
            minimum: 1,
            maximum: 1_000_000,
        },
        category: "churn",
        description: "Same-file edit count that starts informational churn guidance.",
    },
    RuntimeConfigField {
        path: "churn.warning_edit_count",
        env: Some("VIBEGUARD_CHURN_WARNING_EDIT_COUNT"),
        default: "10",
        kind: FieldKind::Integer {
            minimum: 1,
            maximum: 1_000_000,
        },
        category: "churn",
        description: "Same-file edit count that raises churn guidance to warning level.",
    },
    RuntimeConfigField {
        path: "churn.critical_edit_count",
        env: Some("VIBEGUARD_CHURN_CRITICAL_EDIT_COUNT"),
        default: "20",
        kind: FieldKind::Integer {
            minimum: 1,
            maximum: 1_000_000,
        },
        category: "churn",
        description: "Same-file edit count that enables critical churn classification.",
    },
    RuntimeConfigField {
        path: "churn.critical_build_failure_count",
        env: Some("VIBEGUARD_CHURN_CRITICAL_BUILD_FAILURE_COUNT"),
        default: "5",
        kind: FieldKind::Integer {
            minimum: 1,
            maximum: 1_000_000,
        },
        category: "churn",
        description: "Consecutive build failures needed with critical churn for escalation.",
    },
    RuntimeConfigField {
        path: "w15.minimum_consecutive_edits",
        env: Some("VIBEGUARD_W15_MINIMUM_CONSECUTIVE_EDITS"),
        default: "3",
        kind: FieldKind::Integer {
            minimum: 3,
            maximum: 1_000_000,
        },
        category: "w15",
        description: "Minimum same-file edit trail, including the current edit, before W-15 evaluates only the latest three deltas.",
    },
    RuntimeConfigField {
        path: "w15.latest_delta_character_ceiling",
        env: Some("VIBEGUARD_W15_LATEST_DELTA_CHARACTER_CEILING"),
        default: "300",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
        category: "w15",
        description: "Largest latest change radius eligible for W-15 micro-tuning detection.",
    },
    RuntimeConfigField {
        path: "paralysis.threshold",
        env: Some("VG_PARALYSIS_THRESHOLD"),
        default: "7",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
        category: "paralysis",
        description: "Read-only action streak that starts W-13 paralysis guidance.",
    },
    RuntimeConfigField {
        path: "write_mode",
        env: Some("VIBEGUARD_WRITE_MODE"),
        default: "warn",
        kind: FieldKind::StringEnum {
            allowed: &["warn", "block"],
        },
        category: "write_policy",
        description: "Whether new-source write guidance warns or blocks.",
    },
    RuntimeConfigField {
        path: "write_escalate_threshold",
        env: Some("VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD"),
        default: "5",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
        category: "write_policy",
        description: "Search-first reminders in one session before write guidance escalates.",
    },
    RuntimeConfigField {
        path: "learn.metrics_tail_bytes",
        env: Some("VIBEGUARD_LEARN_METRICS_TAIL_BYTES"),
        default: "5242880",
        kind: FieldKind::Integer {
            minimum: 1,
            maximum: 268_435_456,
        },
        category: "learning",
        description: "Maximum recent metrics bytes read by the learn evaluator.",
    },
    RuntimeConfigField {
        path: "disabled_skills",
        env: Some("VIBEGUARD_DISABLED_SKILLS"),
        default: "[]",
        kind: FieldKind::StringArray { maximum_items: 256 },
        category: "workflow",
        description: "Managed Codex workflow skill directory names to skip.",
    },
];

pub(crate) fn field_for_key(key: &str) -> Option<&'static RuntimeConfigField> {
    RUNTIME_CONFIG_FIELDS
        .iter()
        .find(|field| field.path == key || field.env == Some(key))
}

pub(crate) fn is_runtime_config_root_key(key: &str) -> bool {
    RUNTIME_CONFIG_FIELDS.iter().any(|field| {
        field
            .path
            .split_once('.')
            .map_or(field.path, |(root, _)| root)
            == key
    })
}
