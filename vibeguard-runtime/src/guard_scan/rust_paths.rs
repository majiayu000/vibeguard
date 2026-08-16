use std::path::Path;

use super::shared::{resolve_rust_type_path, rust_file_module};

pub(super) fn resolve_workspace_type_path(value: &str, path: &Path, target: &Path) -> String {
    let resolved = resolve_rust_type_path(value, path, target);
    if value
        .split("::")
        .next()
        .is_none_or(|segment| segment.trim() != "crate")
    {
        return resolved;
    }
    let Some(module) = rust_file_module(path, target) else {
        return resolved;
    };
    let prefix = module.split("::").next().unwrap_or("");
    if prefix.is_empty() || resolved.starts_with(&format!("{prefix}::")) {
        resolved
    } else {
        format!("{prefix}::{resolved}")
    }
}
