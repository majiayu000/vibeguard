use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

struct TestProject {
    root: PathBuf,
}

impl TestProject {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should follow the Unix epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "vibeguard-guard-scan-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&root).expect("guard scan fixture should be created");
        Self { root }
    }

    fn write(&self, relative: &str, content: &str) {
        let path = self.root.join(relative);
        fs::create_dir_all(path.parent().expect("fixture file should have a parent"))
            .expect("fixture parent should be created");
        fs::write(path, content).expect("fixture file should be written");
    }
}

impl Drop for TestProject {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn populated_project() -> TestProject {
    let project = TestProject::new();
    project.write(
        "Cargo.toml",
        r#"[workspace]
members = ["crates/api", "crates/cli"]
resolver = "2"
"#,
    );
    project.write(
        "src/main.rs",
        r#"use std::sync::Mutex;

pub struct AppConfig;
impl AppConfig {
    pub fn load() -> Self { Self }
    pub fn save(&self) {}
}
impl Default for AppConfig { fn default() -> Self { Self } }

struct State { a: Mutex<i32>, b: Mutex<i32> }
impl State {
    fn update(&self) {
        let _a = self.a.lock();
        let _b = self.b.lock();
    }
}

static TODO_TASKS: Mutex<Vec<String>> = Mutex::new(Vec::new());
static TASK_STORE: Mutex<Vec<String>> = Mutex::new(Vec::new());
fn tools() { let _ = (TodoWrite, TaskManagement); }
async fn async_read(value: Option<i32>) -> i32 { value.unwrap() }
fn main() {
    let _config = AppConfig::default();
    let value = Some(1).expect("fixture");
    let _ansi = "\x1b[31m";
    if value == 0 { panic!() }
}
"#,
    );
    project.write("src/a.rs", "pub struct DuplicateType;\n");
    project.write("src/b.rs", "pub struct DuplicateType;\n");
    project.write(
        "src/task_commands.rs",
        r#"fn update_task() -> Result<(), String> { Ok(()) }
fn delete_todo() -> String { format!("done") }
"#,
    );
    project.write(
        "crates/api/Cargo.toml",
        "[package]\nname = \"api\"\nversion = \"0.1.0\"\n",
    );
    project.write(
        "crates/api/src/main.rs",
        r#"fn main() {
    let _ = std::env::var("API_DB_PATH");
    let _ = "api.db";
}
"#,
    );
    project.write(
        "crates/cli/Cargo.toml",
        "[package]\nname = \"cli\"\nversion = \"0.1.0\"\n",
    );
    project.write(
        "crates/cli/src/main.rs",
        r#"fn main() {
    let _ = std::env::var("CLI_DATABASE_PATH");
    let _ = "cli.sqlite";
}
"#,
    );
    project.write(
        "worker.go",
        r#"package worker

func risky() error { return nil }
func work() {}
func run() {
    _ = risky()
    go work()
    for {
        defer risky()
    }
}
"#,
    );
    let style = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-long-style";
    for index in 0..4 {
        project.write(
            &format!("src/hooks/use_query_{index}.tsx"),
            &format!(
                r#"// @ts-ignore
export const SHARED_VALUE = {index};
export interface SharedType {{ value: any }}
export function sharedHelper() {{ console.log("fixture"); }}
export function Field() {{ return <label className="{style}">{{children}}{{required}}</label>; }}
export function Table() {{ const [sort, setSortKey] = useState("id"); return <table><thead><th>{{sort}}</th></thead></table>; }}
export function useData() {{ const result = useQuery("key"); return {{ result, isLoading, error, refetch }}; }}
"#
            ),
        );
    }
    project
}

fn scan(project: &Path, language: &str, rule: &str) {
    let args = vec![
        language.to_string(),
        rule.to_string(),
        project.display().to_string(),
    ];
    super::run(&args).unwrap_or_else(|error| panic!("{language}/{rule} failed: {error}"));
}

#[test]
fn every_language_guard_executes_in_the_runtime() {
    let project = populated_project();
    for (language, rule) in [
        ("rust", "unwrap"),
        ("rust", "nested-locks"),
        ("rust", "duplicate-types"),
        ("rust", "workspace-consistency"),
        ("rust", "single-source-of-truth"),
        ("rust", "semantic-effect"),
        ("rust", "taste-invariants"),
        ("rust", "declaration-execution-gap"),
        ("go", "error-handling"),
        ("go", "goroutine-leak"),
        ("go", "defer-in-loop"),
        ("typescript", "any-abuse"),
        ("typescript", "console-residual"),
        ("typescript", "component-duplication"),
        ("typescript", "duplicate-constants"),
    ] {
        scan(&project.root, language, rule);
    }
}

#[test]
fn scan_arguments_and_unknown_rules_fail_visibly() {
    assert!(super::run(&[]).is_err());
    assert!(super::run(&["rust".to_string(), "unknown".to_string()]).is_err());
}
