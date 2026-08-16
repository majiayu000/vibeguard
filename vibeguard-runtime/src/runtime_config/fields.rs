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
}

pub(crate) const RUNTIME_CONFIG_FIELDS: &[RuntimeConfigField] = &[
    RuntimeConfigField {
        path: "version",
        env: None,
        default: "1",
        kind: FieldKind::Version,
    },
    RuntimeConfigField {
        path: "u16.warn_limit",
        env: Some("VG_U16_WARN_LIMIT"),
        default: "400",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
    },
    RuntimeConfigField {
        path: "u16.limit",
        env: Some("VG_U16_LIMIT"),
        default: "800",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
    },
    RuntimeConfigField {
        path: "circuit_breaker.threshold",
        env: Some("VG_CB_THRESHOLD"),
        default: "3",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
    },
    RuntimeConfigField {
        path: "circuit_breaker.cooldown_seconds",
        env: Some("VG_CB_COOLDOWN"),
        default: "300",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 31_536_000,
        },
    },
    RuntimeConfigField {
        path: "circuit_breaker.lock_timeout_seconds",
        env: Some("VG_CB_LOCK_TIMEOUT_SECONDS"),
        default: "5",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 300,
        },
    },
    RuntimeConfigField {
        path: "w14.cooldown_seconds",
        env: Some("VIBEGUARD_W14_COOLDOWN_SECONDS"),
        default: "3600",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 31_536_000,
        },
    },
    RuntimeConfigField {
        path: "paralysis.threshold",
        env: Some("VG_PARALYSIS_THRESHOLD"),
        default: "7",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
    },
    RuntimeConfigField {
        path: "write_mode",
        env: Some("VIBEGUARD_WRITE_MODE"),
        default: "warn",
        kind: FieldKind::StringEnum {
            allowed: &["warn", "block"],
        },
    },
    RuntimeConfigField {
        path: "write_escalate_threshold",
        env: Some("VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD"),
        default: "5",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
    },
    RuntimeConfigField {
        path: "learn.metrics_tail_bytes",
        env: Some("VIBEGUARD_LEARN_METRICS_TAIL_BYTES"),
        default: "5242880",
        kind: FieldKind::Integer {
            minimum: 1,
            maximum: 268_435_456,
        },
    },
    RuntimeConfigField {
        path: "disabled_skills",
        env: Some("VIBEGUARD_DISABLED_SKILLS"),
        default: "[]",
        kind: FieldKind::StringArray { maximum_items: 256 },
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
