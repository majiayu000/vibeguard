use serde_json::Value;
use std::collections::BTreeMap;

use crate::event_schema::field;

use super::Result;
use super::aggregate::{observe_extract_rule_ids, observe_string_field};

const CATALOG_JSON: &str = include_str!("../../../rules/rule-descriptions.json");
const CATALOG_SCHEMA_VERSION: u64 = 1;

pub(super) struct RuleDescriptions {
    descriptions: BTreeMap<String, String>,
}

impl RuleDescriptions {
    pub(super) fn load() -> Result<Self> {
        let catalog: Value = serde_json::from_str(CATALOG_JSON)?;
        if catalog.get("schema_version").and_then(Value::as_u64) != Some(CATALOG_SCHEMA_VERSION) {
            return Err("rule description catalog has an unsupported schema_version".into());
        }
        let rules = catalog
            .get("rules")
            .and_then(Value::as_object)
            .ok_or("rule description catalog is missing the rules object")?;
        if rules.is_empty() {
            return Err("rule description catalog must contain at least one rule".into());
        }

        let mut descriptions = BTreeMap::new();
        for (rule_id, entry) in rules {
            for field_name in ["name", "severity", "description"] {
                let value = entry
                    .get(field_name)
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty());
                if value.is_none() {
                    return Err(format!(
                        "rule description catalog entry {rule_id} has no {field_name}"
                    )
                    .into());
                }
            }
            let description = entry["description"]
                .as_str()
                .ok_or_else(|| format!("rule description catalog entry {rule_id} is invalid"))?;
            descriptions.insert(rule_id.clone(), description.to_string());
        }
        Ok(Self { descriptions })
    }

    pub(super) fn human_reason(&self, event: &Value) -> String {
        let raw_reason = observe_string_field(event, field::REASON);
        let Some(rule_id) = rule_id_for_event(event, &raw_reason) else {
            return raw_reason;
        };
        let Some(description) = self.descriptions.get(&rule_id) else {
            return raw_reason;
        };
        let detail = raw_reason
            .strip_prefix(&rule_id)
            .unwrap_or(&raw_reason)
            .trim_start_matches(|ch: char| {
                ch.is_ascii_whitespace() || matches!(ch, ':' | '-' | '|')
            });
        if detail.is_empty() {
            format!("{rule_id}: {description}")
        } else {
            format!("{rule_id}: {description} ({detail})")
        }
    }
}

fn rule_id_for_event(event: &Value, reason: &str) -> Option<String> {
    let structured = observe_string_field(event, field::RULE_ID).to_ascii_uppercase();
    if !structured.is_empty() {
        return Some(structured);
    }
    if let Some(rule_id) = observe_extract_rule_ids(reason).into_iter().next() {
        return Some(rule_id);
    }
    let hook = observe_string_field(event, field::HOOK);
    if hook == "post-edit-guard"
        && let Some(rule_id) = legacy_post_edit_rule_id(reason)
    {
        return Some(rule_id.to_string());
    }
    (hook == "count-active-constraints" && reason.starts_with("constraints="))
        .then(|| "U-32".to_string())
}

fn legacy_post_edit_rule_id(reason: &str) -> Option<&'static str> {
    let token = reason.split_ascii_whitespace().next()?;
    if token.eq_ignore_ascii_case("w14") {
        Some("W-14")
    } else if token.eq_ignore_ascii_case("w15") {
        Some("W-15")
    } else {
        None
    }
}
