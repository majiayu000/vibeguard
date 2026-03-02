use crate::plan::{ExecPlan, Milestone, MilestoneStatus};
use chrono::Utc;

/// Convert an execution plan to markdown.
pub fn to_markdown(plan: &ExecPlan) -> String {
    let mut md = format!("# {}\n\n", plan.purpose);
    for m in &plan.milestones {
        let icon = match m.status {
            MilestoneStatus::Pending => "[ ]",
            MilestoneStatus::InProgress => "[~]",
            MilestoneStatus::Done => "[x]",
            MilestoneStatus::Blocked => "[!]",
        };
        md.push_str(&format!("- {} {} ({})\n", icon, m.title, m.id));
    }
    md
}

/// Parse markdown back into an execution plan.
pub fn from_markdown(md: &str) -> ExecPlan {
    let mut lines = md.lines();
    let purpose = lines
        .next()
        .unwrap_or("")
        .trim()
        .trim_start_matches('#')
        .trim()
        .to_string();

    let mut milestones = Vec::new();
    for line in lines {
        let trimmed = line.trim();
        if !trimmed.starts_with("- [") {
            continue;
        }
        let status = if trimmed.starts_with("- [x]") {
            MilestoneStatus::Done
        } else if trimmed.starts_with("- [~]") {
            MilestoneStatus::InProgress
        } else if trimmed.starts_with("- [!]") {
            MilestoneStatus::Blocked
        } else {
            MilestoneStatus::Pending
        };

        // Parse "title (id)" from after the checkbox
        let after_check = &trimmed[5..].trim();
        if let Some(paren_start) = after_check.rfind('(') {
            let title = after_check[..paren_start].trim().to_string();
            let id = after_check[paren_start + 1..]
                .trim_end_matches(')')
                .trim()
                .to_string();
            milestones.push(Milestone {
                id,
                title,
                status,
                updated_at: Utc::now(),
            });
        }
    }

    ExecPlan {
        purpose,
        milestones,
        created_at: Utc::now(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plan::MilestoneStatus;

    #[test]
    fn to_markdown_from_markdown_round_trip() {
        let mut plan = ExecPlan::from_spec("# Deploy pipeline");
        plan.add_milestone("p1", "build image");
        plan.add_milestone("p2", "run tests");
        plan.update_milestone("p1", MilestoneStatus::Done);

        let md = to_markdown(&plan);
        assert!(md.contains("# Deploy pipeline"));
        assert!(md.contains("[x] build image (p1)"));
        assert!(md.contains("[ ] run tests (p2)"));

        let restored = from_markdown(&md);
        assert_eq!(restored.purpose, "Deploy pipeline");
        assert_eq!(restored.milestones.len(), 2);
        assert_eq!(restored.milestones[0].id, "p1");
        assert_eq!(restored.milestones[0].status, MilestoneStatus::Done);
        assert_eq!(restored.milestones[1].id, "p2");
        assert_eq!(restored.milestones[1].status, MilestoneStatus::Pending);
    }
}
