//! Hook orchestration grouped by lifecycle stage; `dispatch` holds the
//! shared runtime dispatch core re-exported at the group root.

pub mod context;
pub mod learn;
pub mod post_edit;
pub mod post_edit_history;
pub mod post_write;
pub mod pre_bash;
pub mod pre_edit;
pub mod stop;

mod dispatch;
pub(crate) use dispatch::*;
