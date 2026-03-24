"""
VibeGuard LLM-as-Judge 测试样本

每个样本包含:
- rule: 规则 ID
- severity: 严重程度
- lang: 语言
- code: 违规代码
- description: 预期检出的问题描述
"""

SAMPLES = [
    # === Security Rules ===
    {
        "rule": "SEC-01",
        "severity": "critical",
        "lang": "python",
        "code": '''
def get_user(user_id):
    query = f"SELECT * FROM users WHERE id = '{user_id}'"
    cursor.execute(query)
    return cursor.fetchone()
''',
        "description": "SQL injection via string formatting",
    },
    {
        "rule": "SEC-02",
        "severity": "critical",
        "lang": "python",
        "code": '''
import jwt

SECRET_KEY = "my-super-secret-key-12345"
API_KEY = "sk-ant-api03-xxxxxxxxxxxxx"

def create_token(user_id):
    return jwt.encode({"user_id": user_id}, SECRET_KEY)
''',
        "description": "Hardcoded secrets and API keys",
    },
    {
        "rule": "SEC-03",
        "severity": "high",
        "lang": "typescript",
        "code": '''
function renderComment(comment: string) {
    const container = document.getElementById("comments");
    container.innerHTML = `<div class="comment">${comment}</div>`;
}
''',
        "description": "XSS via innerHTML with unsanitized input",
    },
    {
        "rule": "SEC-04",
        "severity": "high",
        "lang": "python",
        "code": '''
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route("/api/admin/users", methods=["DELETE"])
def delete_all_users():
    db.execute("DELETE FROM users")
    return jsonify({"status": "ok"})
''',
        "description": "Admin endpoint without auth/authorization",
    },
    {
        "rule": "SEC-07",
        "severity": "medium",
        "lang": "python",
        "code": '''
from flask import request, send_file

@app.route("/download")
def download():
    filename = request.args.get("file")
    return send_file(f"/data/uploads/{filename}")
''',
        "description": "Path traversal via unvalidated user input in file path",
    },
    {
        "rule": "SEC-09",
        "severity": "medium",
        "lang": "python",
        "code": '''
import pickle

def load_user_data(data_bytes):
    return pickle.loads(data_bytes)
''',
        "description": "Unsafe deserialization with pickle",
    },
    {
        "rule": "SEC-10",
        "severity": "medium",
        "lang": "python",
        "code": '''
import logging

def authenticate(username, password):
    logging.info(f"Login attempt: user={username}, password={password}")
    user = db.find_user(username)
    if user and user.check_password(password):
        token = generate_token(user)
        logging.info(f"Token issued: {token}")
        return token
    return None
''',
        "description": "Logging sensitive data (password and token)",
    },

    # === Python Rules ===
    {
        "rule": "PY-01",
        "severity": "high",
        "lang": "python",
        "code": '''
def add_item(name, items=[]):
    items.append(name)
    return items
''',
        "description": "Mutable default argument",
    },
    {
        "rule": "PY-02",
        "severity": "medium",
        "lang": "python",
        "code": '''
def process_data(data):
    try:
        result = transform(data)
        save(result)
    except:
        pass
''',
        "description": "Bare except with silent pass",
    },
    {
        "rule": "PY-03",
        "severity": "medium",
        "lang": "python",
        "code": '''
async def fetch_all_users(user_ids):
    results = []
    for uid in user_ids:
        user = await fetch_user(uid)
        results.append(user)
    return results
''',
        "description": "Sequential await in loop instead of gather",
    },
    {
        "rule": "PY-08",
        "severity": "high",
        "lang": "python",
        "code": '''
def run_user_formula(formula_str, context):
    return eval(formula_str, {"__builtins__": {}}, context)
''',
        "description": "Using eval() with user input",
    },
    {
        "rule": "PY-11",
        "severity": "medium",
        "lang": "python",
        "code": '''
def read_config(path):
    f = open(path, "r")
    data = f.read()
    f.close()
    return json.loads(data)
''',
        "description": "File operation without context manager",
    },

    # === TypeScript Rules ===
    {
        "rule": "TS-01",
        "severity": "medium",
        "lang": "typescript",
        "code": '''
function processData(input: any): any {
    const result = input.map((item: any) => ({
        name: item.name,
        value: item.value * 2,
    }));
    return result;
}
''',
        "description": "any type escape in function signature",
    },
    {
        "rule": "TS-02",
        "severity": "high",
        "lang": "typescript",
        "code": '''
async function saveUser(user: User) {
    const response = fetch("/api/users", {
        method: "POST",
        body: JSON.stringify(user),
    });
    return response;
}
''',
        "description": "Missing await on async call (unhandled Promise)",
    },
    {
        "rule": "TS-06",
        "severity": "medium",
        "lang": "typescript",
        "code": '''
function UserProfile({ userId }: { userId: string }) {
    const [user, setUser] = useState<User | null>(null);
    const fetchUser = async () => {
        const res = await fetch(`/api/users/${userId}`);
        setUser(await res.json());
    };
    useEffect(() => {
        fetchUser();
    }, []);
    return <div>{user?.name}</div>;
}
''',
        "description": "useEffect missing dependency (userId)",
    },
    {
        "rule": "TS-08",
        "severity": "high",
        "lang": "typescript",
        "code": '''
interface ApiResponse {
    data: unknown;
    status: number;
}

function getUsers(response: ApiResponse): User[] {
    return response.data as any as User[];
}
''',
        "description": "Using 'as any' to bypass type checking",
    },
    {
        "rule": "TS-11",
        "severity": "medium",
        "lang": "typescript",
        "code": '''
function getUserEmail(users: User[], id: string): string {
    const user = users.find(u => u.id === id);
    return user.email.toLowerCase();
}
''',
        "description": "Unhandled null/undefined (find may return undefined)",
    },

    # === Go Rules ===
    {
        "rule": "GO-01",
        "severity": "high",
        "lang": "go",
        "code": '''
func saveConfig(path string, data []byte) {
    f, _ := os.Create(path)
    f.Write(data)
    f.Close()
}
''',
        "description": "Unchecked error return value (assigned to _)",
    },
    {
        "rule": "GO-02",
        "severity": "high",
        "lang": "go",
        "code": '''
func startWorkers(tasks <-chan Task) {
    for i := 0; i < 10; i++ {
        go func() {
            for task := range tasks {
                process(task)
            }
        }()
    }
}
''',
        "description": "Goroutine without exit mechanism (no context)",
    },
    {
        "rule": "GO-03",
        "severity": "high",
        "lang": "go",
        "code": '''
var counter int

func increment() {
    counter++
}

func getCount() int {
    return counter
}
''',
        "description": "Data race on shared variable without mutex",
    },
    {
        "rule": "GO-08",
        "severity": "high",
        "lang": "go",
        "code": '''
func processFiles(paths []string) error {
    for _, path := range paths {
        f, err := os.Open(path)
        if err != nil {
            return err
        }
        defer f.Close()
        processFile(f)
    }
    return nil
}
''',
        "description": "defer inside loop (resource leak)",
    },
    {
        "rule": "GO-11",
        "severity": "medium",
        "lang": "go",
        "code": '''
func fetchData(url string) ([]byte, error) {
    ctx := context.Background()
    req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
    if err != nil {
        return nil, err
    }
    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    return io.ReadAll(resp.Body)
}
''',
        "description": "context.Background() in non-entry function",
    },

    # === Rust Rules ===
    {
        "rule": "RS-03",
        "severity": "medium",
        "lang": "rust",
        "code": '''
fn load_config(path: &str) -> Config {
    let content = std::fs::read_to_string(path).unwrap();
    let config: Config = serde_json::from_str(&content).unwrap();
    config
}
''',
        "description": "unwrap() in non-test code",
    },
    {
        "rule": "RS-10",
        "severity": "high",
        "lang": "rust",
        "code": '''
fn cleanup_old_records(conn: &Connection) {
    let _ = conn.execute("DELETE FROM logs WHERE created_at < date('now', '-30 days')", []);
    let _ = conn.execute("VACUUM", []);
}
''',
        "description": "Silent discard of meaningful Result with let _",
    },
    {
        "rule": "RS-14",
        "severity": "high",
        "lang": "rust",
        "code": '''
struct AppConfig {
    db_path: String,
    log_level: String,
    max_connections: u32,
}

impl AppConfig {
    fn load(path: &str) -> Result<Self, Error> {
        let content = std::fs::read_to_string(path)?;
        toml::from_str(&content).map_err(|e| Error::Config(e))
    }
}

fn main() {
    let config = AppConfig::default();
    let app = App::new(config);
    app.run();
}
''',
        "description": "Declaration-execution gap: Config::load exists but main uses default()",
    },

    # === Common/Behavioral Rules (testable with code) ===
    {
        "rule": "U-16",
        "severity": "medium",
        "lang": "python",
        "code": "# Imagine a 900-line Python file with mixed responsibilities\n"
        + "\n".join(
            [f"def function_{i}():\n    pass\n" for i in range(300)]
        ),
        "description": "File exceeds 800 line limit",
    },
    {
        "rule": "U-25",
        "severity": "high",
        "lang": "rust",
        "code": '''
// cargo check shows 3 errors but developer continues adding new features
fn new_feature() -> Result<(), Error> {
    let config = load_config()?;  // type mismatch error from previous edit
    let db = connect_db(&config)?;  // unresolved import
    process_data(&db)
}

// Instead of fixing the build errors above, adding yet another function:
fn another_new_feature() {
    println!("adding more code while build is broken");
}
''',
        "description": "Adding new code while build errors exist (U-25: fix build first)",
    },
    {
        "rule": "U-26",
        "severity": "high",
        "lang": "python",
        "code": '''
class CacheConfig(BaseModel):
    ttl: int = 3600
    max_size: int = 1000
    backend: str = "redis"

    @classmethod
    def from_file(cls, path: str) -> "CacheConfig":
        with open(path) as f:
            return cls(**json.load(f))

def create_app():
    # Bug: CacheConfig.from_file() exists but never called
    cache = CacheConfig()  # always uses defaults, config file ignored
    app = App(cache=cache)
    return app
''',
        "description": "Declaration-execution gap: from_file() exists but create_app uses defaults",
    },
    {
        "rule": "U-29",
        "severity": "high",
        "lang": "python",
        "code": '''
def generate_report(user_id: int) -> Report:
    try:
        data = fetch_user_data(user_id)
        sections = build_sections(data)
        return Report(sections=sections)
    except Exception as e:
        logger.warning("Report generation failed for user %s: %s", user_id, e)
        return Report(sections=[])  # returns empty report as if successful
''',
        "description": "Silent degradation: error returns empty report instead of raising (U-29)",
    },
    {
        "rule": "W-01",
        "severity": "high",
        "lang": "python",
        "code": '''
# Bug report: "login fails intermittently"
# Developer's fix attempt without investigating root cause:
def login(username, password):
    try:
        user = db.get_user(username)
        if user.check_password(password):
            return create_session(user)
    except Exception:
        pass
    # "Fix": just retry if it fails
    time.sleep(1)
    return login(username, password)  # recursive retry without understanding why
''',
        "description": "Fix without root cause analysis — blind retry instead of debugging (W-01)",
    },
    {
        "rule": "W-03",
        "severity": "high",
        "lang": "python",
        "code": '''
def migrate_database():
    """Run database migration."""
    # Changed the migration SQL
    run_sql("ALTER TABLE users ADD COLUMN role VARCHAR(50)")
    # Developer claims: "Migration is done, tested locally"
    # But never actually ran `python manage.py migrate` or checked the output
''',
        "description": "Claiming completion without verification evidence (W-03)",
    },
    {
        "rule": "W-12",
        "severity": "high",
        "lang": "python",
        "code": '''
# Test was failing, so developer "fixed" it by weakening the assertion
def test_calculate_total():
    result = calculate_total([10, 20, 30])
    # Was: assert result == 60
    # "Fixed" to:
    assert result > 0  # weakened assertion to make test pass
    assert isinstance(result, (int, float))  # type check instead of value check
''',
        "description": "Weakening test assertions to make failing test pass (W-12)",
    },

    # === Additional Python Rules ===
    {
        "rule": "PY-04",
        "severity": "medium",
        "lang": "python",
        "code": '''
class DataProcessor:
    def fetch_data(self): pass
    def validate_data(self): pass
    def transform_data(self): pass
    def filter_data(self): pass
    def aggregate_data(self): pass
    def format_output(self): pass
    def send_notification(self): pass
    def log_results(self): pass
    def cleanup(self): pass
    def retry_failed(self): pass
    def generate_report(self): pass
    def export_csv(self): pass
    def export_json(self): pass
    def backup_data(self): pass
''',
        "description": "God class with 14 public methods (PY-04: >10 methods)",
    },
    {
        "rule": "PY-09",
        "severity": "medium",
        "lang": "python",
        "code": "def process_order(order):\n"
        + "\n".join([f"    step_{i} = do_step_{i}(order)" for i in range(60)]),
        "description": "Function exceeds 50 lines (PY-09)",
    },
    {
        "rule": "PY-10",
        "severity": "medium",
        "lang": "python",
        "code": '''
def process(data):
    for item in data:
        if item.is_valid():
            for sub in item.children:
                if sub.needs_processing():
                    for field in sub.fields:
                        if field.value is not None:
                            for rule in field.rules:
                                if rule.applies(field):
                                    result = rule.execute(field)
''',
        "description": "Nesting exceeds 4 levels (PY-10)",
    },

    # === Additional Rust Rules ===
    {
        "rule": "RS-06",
        "severity": "medium",
        "lang": "rust",
        "code": '''
fn process_items(items: &[Item]) -> Vec<String> {
    let mut result = String::new();
    for item in items {
        result = result + &item.name + ", ";
    }
    vec![result]
}
''',
        "description": "String concatenation in loop instead of push_str or collect (RS-06)",
    },

    # === False Positives (should NOT trigger) ===
    {
        "rule": "NONE",
        "severity": "none",
        "lang": "python",
        "code": '''
def add_item(name, items=None):
    if items is None:
        items = []
    items.append(name)
    return items
''',
        "description": "CLEAN: Correct mutable default pattern",
    },
    {
        "rule": "NONE",
        "severity": "none",
        "lang": "go",
        "code": '''
func saveConfig(path string, data []byte) error {
    f, err := os.Create(path)
    if err != nil {
        return fmt.Errorf("create config: %w", err)
    }
    defer f.Close()
    if _, err := f.Write(data); err != nil {
        return fmt.Errorf("write config: %w", err)
    }
    return nil
}
''',
        "description": "CLEAN: Proper error handling in Go",
    },
    {
        "rule": "NONE",
        "severity": "none",
        "lang": "rust",
        "code": '''
fn load_config(path: &str) -> Result<Config, Box<dyn Error>> {
    let content = std::fs::read_to_string(path)?;
    let config: Config = serde_json::from_str(&content)?;
    Ok(config)
}
''',
        "description": "CLEAN: Proper error propagation with ?",
    },
    {
        "rule": "NONE",
        "severity": "none",
        "lang": "python",
        "code": '''
from flask import Flask, request, jsonify
from functools import wraps

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        token = request.headers.get("Authorization")
        if not token or not verify_token(token):
            return jsonify({"error": "unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated

@app.route("/api/admin/users", methods=["DELETE"])
@require_auth
def delete_all_users():
    db.execute("DELETE FROM users")
    return jsonify({"status": "ok"})
''',
        "description": "CLEAN: Admin endpoint with auth decorator",
    },
]
