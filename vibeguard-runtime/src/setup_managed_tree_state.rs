use crate::setup_install_state::{expand_home, read_state, setup_absolute_path};
use crate::setup_support::SetupResult;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

pub(super) fn carry_tracked_files(
    target: &mut Value,
    source_states: &[&Path; 2],
    tracked_dest: &Path,
) -> SetupResult<()> {
    let mut carried = BTreeMap::new();
    for source_path in source_states {
        if !source_path.exists() {
            continue;
        }
        let source = read_state(source_path)?;
        let files = source["files"]
            .as_object()
            .ok_or("install-state files must be an object")?;
        for (path, entry) in files {
            let expanded = setup_absolute_path(&expand_home(path));
            if expanded != tracked_dest && !expanded.starts_with(tracked_dest) {
                continue;
            }
            if carried
                .insert(path.clone(), entry.clone())
                .is_some_and(|previous| previous != *entry)
            {
                return Err(
                    "install-state generations disagree on tracked quarantine files".into(),
                );
            }
        }
    }
    if carried.is_empty() {
        return Err("quarantine publication has no exact tracked file inventory".into());
    }
    let target_files = target["files"]
        .as_object_mut()
        .ok_or("install-state files must be an object")?;
    for (path, entry) in carried {
        if target_files
            .insert(path, entry.clone())
            .is_some_and(|previous| previous != entry)
        {
            return Err("current install state conflicts with quarantine inventory".into());
        }
    }
    Ok(())
}
