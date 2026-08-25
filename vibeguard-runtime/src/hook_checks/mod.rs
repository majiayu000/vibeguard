//! Hook check implementations grouped by concern; `checks` holds the
//! pre-write/pre-edit evaluation core re-exported at the group root.

pub mod bash;
pub mod common;
pub mod history;
pub mod js;
pub mod jsonl;
pub mod scan;
pub mod write;
pub mod write_scan;

mod checks;
pub use checks::*;
