use std::path::PathBuf;

mod go;
mod jsx;
mod rust;
mod rust_structural;
mod shared;
mod typescript;

#[cfg(test)]
mod tests;

use shared::{ScanArgs, ScanContext, ScanResult};

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

pub fn run(args: &[String]) -> Result {
    let parsed = ScanArgs::parse(args)?;
    let context = ScanContext::new(&parsed)?;
    let result = match (parsed.language.as_str(), parsed.rule.as_str()) {
        ("rust", "unwrap") | ("rust", "unwrap-in-prod") => rust::unwrap(&context)?,
        ("rust", "nested-locks") => rust::nested_locks(&context)?,
        ("rust", "taste-invariants") => rust::taste_invariants(&context)?,
        ("rust", "duplicate-types") => rust_structural::duplicate_types(&context)?,
        ("rust", "workspace-consistency") => rust_structural::workspace_consistency(&context)?,
        ("rust", "single-source-of-truth") => rust_structural::single_source_of_truth(&context)?,
        ("rust", "semantic-effect") => rust_structural::semantic_effect(&context)?,
        ("rust", "declaration-execution-gap") => {
            rust_structural::declaration_execution_gap(&context)?
        }
        ("go", "error-handling") => go::error_handling(&context)?,
        ("go", "goroutine-leak") => go::goroutine_leak(&context)?,
        ("go", "defer-in-loop") => go::defer_in_loop(&context)?,
        ("typescript", "any-abuse") => typescript::any_abuse(&context)?,
        ("typescript", "console-residual") => typescript::console_residual(&context)?,
        ("typescript", "component-duplication") => typescript::component_duplication(&context)?,
        ("typescript", "duplicate-constants") => typescript::duplicate_constants(&context)?,
        _ => {
            return Err(format!(
                "unsupported guard scan: {}/{}",
                parsed.language, parsed.rule
            )
            .into());
        }
    };
    result.print();
    if parsed.strict && result.has_findings() {
        std::process::exit(1);
    }
    Ok(())
}

#[allow(dead_code)]
fn _path_type_anchor(_: PathBuf, _: ScanResult) {}
