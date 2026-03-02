use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Skill priority for deduplication.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkillLocation {
    System = 0,
    Admin = 1,
    User = 2,
    Repo = 3,
}

/// A registered skill definition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Skill {
    pub name: String,
    pub description: String,
    pub location: SkillLocation,
}

/// In-memory skill registry.
pub struct SkillStore {
    skills: Vec<Skill>,
}

impl SkillStore {
    pub fn new() -> Self {
        Self { skills: Vec::new() }
    }

    pub fn add(&mut self, skill: Skill) {
        self.skills.push(skill);
    }

    pub fn list(&self) -> &[Skill] {
        &self.skills
    }

    pub fn delete(&mut self, name: &str) -> bool {
        let before = self.skills.len();
        self.skills.retain(|s| s.name != name);
        self.skills.len() < before
    }

    /// Deduplicate skills by name, keeping the highest-priority location
    /// (repo > user > admin > system).
    pub fn deduplicate(&mut self) {
        let mut best: HashMap<String, Skill> = HashMap::new();
        for skill in self.skills.drain(..) {
            let entry = best.entry(skill.name.clone()).or_insert_with(|| skill.clone());
            if skill.location > entry.location {
                *entry = skill;
            }
        }
        self.skills = best.into_values().collect();
        self.skills.sort_by(|a, b| a.name.cmp(&b.name));
    }
}

impl Default for SkillStore {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skill_store_create_and_list() {
        let mut store = SkillStore::new();
        assert!(store.list().is_empty());

        store.add(Skill {
            name: "tdd-guide".to_string(),
            description: "Test-driven development".to_string(),
            location: SkillLocation::Repo,
        });
        store.add(Skill {
            name: "eval-harness".to_string(),
            description: "Evaluation harness".to_string(),
            location: SkillLocation::User,
        });

        assert_eq!(store.list().len(), 2);
        assert_eq!(store.list()[0].name, "tdd-guide");
    }

    #[test]
    fn skill_store_delete() {
        let mut store = SkillStore::new();
        store.add(Skill {
            name: "to-remove".to_string(),
            description: "temporary".to_string(),
            location: SkillLocation::System,
        });
        assert_eq!(store.list().len(), 1);

        assert!(store.delete("to-remove"));
        assert!(store.list().is_empty());

        // deleting non-existent returns false
        assert!(!store.delete("nonexistent"));
    }

    #[test]
    fn deduplicate_by_location_priority() {
        let mut store = SkillStore::new();
        store.add(Skill {
            name: "lint".to_string(),
            description: "system lint".to_string(),
            location: SkillLocation::System,
        });
        store.add(Skill {
            name: "lint".to_string(),
            description: "repo lint".to_string(),
            location: SkillLocation::Repo,
        });
        store.add(Skill {
            name: "lint".to_string(),
            description: "user lint".to_string(),
            location: SkillLocation::User,
        });

        store.deduplicate();
        assert_eq!(store.list().len(), 1);
        // Repo has highest priority, should win
        assert_eq!(store.list()[0].description, "repo lint");
        assert_eq!(store.list()[0].location, SkillLocation::Repo);
    }
}
