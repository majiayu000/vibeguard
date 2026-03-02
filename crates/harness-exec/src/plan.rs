use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Status of a milestone within an execution plan.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MilestoneStatus {
    Pending,
    InProgress,
    Done,
    Blocked,
}

/// A milestone in an execution plan.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Milestone {
    pub id: String,
    pub title: String,
    pub status: MilestoneStatus,
    pub updated_at: DateTime<Utc>,
}

/// Long-running execution plan.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecPlan {
    pub purpose: String,
    pub milestones: Vec<Milestone>,
    pub created_at: DateTime<Utc>,
}

impl ExecPlan {
    /// Parse an execution plan from a spec string.
    /// Extracts the first line as purpose.
    pub fn from_spec(spec: &str) -> Self {
        let purpose = spec
            .lines()
            .next()
            .unwrap_or("unnamed plan")
            .trim()
            .trim_start_matches('#')
            .trim()
            .to_string();

        Self {
            purpose,
            milestones: Vec::new(),
            created_at: Utc::now(),
        }
    }

    /// Add a new milestone.
    pub fn add_milestone(&mut self, id: &str, title: &str) {
        self.milestones.push(Milestone {
            id: id.to_string(),
            title: title.to_string(),
            status: MilestoneStatus::Pending,
            updated_at: Utc::now(),
        });
    }

    /// Update milestone status by ID.
    pub fn update_milestone(&mut self, id: &str, status: MilestoneStatus) -> bool {
        for m in &mut self.milestones {
            if m.id == id {
                m.status = status;
                m.updated_at = Utc::now();
                return true;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_plan_from_spec_extracts_purpose() {
        let spec = "# Migrate database schema\n\n- Step 1\n- Step 2";
        let plan = ExecPlan::from_spec(spec);
        assert_eq!(plan.purpose, "Migrate database schema");
        assert!(plan.milestones.is_empty());
    }

    #[test]
    fn add_and_update_milestone() {
        let mut plan = ExecPlan::from_spec("test plan");
        plan.add_milestone("m1", "design");
        plan.add_milestone("m2", "implement");
        assert_eq!(plan.milestones.len(), 2);
        assert_eq!(plan.milestones[0].status, MilestoneStatus::Pending);

        let updated = plan.update_milestone("m1", MilestoneStatus::Done);
        assert!(updated);
        assert_eq!(plan.milestones[0].status, MilestoneStatus::Done);

        // Non-existent milestone
        assert!(!plan.update_milestone("m99", MilestoneStatus::Done));
    }
}
