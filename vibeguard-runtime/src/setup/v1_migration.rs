//! Explicit removal of recognized Claude v1 hook calls, with a private backup.
use super::legacy;
use super::support::write_atomic_if_unchanged;
use crate::Result;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

pub(super) struct V1Migration {
    pub(super) removed: usize,
    pub(super) backup: Option<PathBuf>,
}

/// Removes recognized v1 handlers from `config` when requested and names the
/// backup that must be written before the settings change.
pub(super) fn plan(config: &mut Value, host_dir: &Path, enabled: bool) -> Result<V1Migration> {
    let removed = if enabled {
        prune_v1_claude_hooks(config)
    } else {
        0
    };
    let backup = if removed > 0 {
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos();
        Some(host_dir.join(format!("settings.json.vibeguard-v1-{timestamp}.bak")))
    } else {
        None
    };
    Ok(V1Migration { removed, backup })
}

impl V1Migration {
    pub(super) fn preview(&self, config_path: &Path, changes: &mut Vec<Value>) {
        if let Some(backup) = &self.backup {
            changes.push(json!({"path":backup,"operation":"backup_original_settings"}));
            changes.push(json!({"path":config_path,"operation":"remove_v1_hooks","handler_count":self.removed}));
        }
    }

    pub(super) fn write_backup(&self, old_config: Option<&str>) -> Result<()> {
        let Some(backup) = &self.backup else {
            return Ok(());
        };
        let original = old_config.ok_or("migration requires existing settings")?;
        write_atomic_if_unchanged(backup, original.as_bytes(), 0o600, None)
    }
}

fn prune_v1_claude_hooks(config: &mut Value) -> usize {
    let Some(events) = config.get_mut("hooks").and_then(Value::as_object_mut) else {
        return 0;
    };
    let mut removed = 0;
    for groups in events.values_mut() {
        groups
            .as_array_mut()
            .expect("validated events")
            .retain_mut(|group| {
                let handlers = group["hooks"].as_array_mut().expect("validated handlers");
                let before = handlers.len();
                handlers.retain(|handler| {
                    let owned = handler["type"] == "command"
                        && handler.get("args").is_none()
                        && handler["command"]
                            .as_str()
                            .is_some_and(legacy::is_v1_claude_hook);
                    removed += usize::from(owned);
                    !owned
                });
                handlers.len() == before || !handlers.is_empty()
            });
    }
    removed
}
