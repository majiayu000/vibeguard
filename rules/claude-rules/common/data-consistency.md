---
paths: **/*.rs,**/*.go,**/*.py,**/*.ts,**/*.tsx,**/*.js,**/*.jsx,**/Cargo.toml,**/Cargo.lock,**/go.mod,**/go.sum,**/pyproject.toml,**/setup.py,**/package.json,**/package-lock.json,**/pnpm-lock.yaml,**/yarn.lock
---

# Cross-Entry Data Consistency Rules

When multiple binaries in a monorepo or workspace share one data source, configuration must converge.

## Applicability

U-11 through U-14 apply when a project has multiple entry points, binaries, services, CLIs, workers, or UI/server surfaces that share persisted database or cache state. For a single-entry-point project, or a project with no persisted shared state, treat these rules as not applicable and do not create work solely to satisfy them.

## U-11: Inconsistent default DB/cache paths across binaries (high)
Different entry points hardcode different data paths, which splits user data. Fix: make every entry point call the same shared `default_db_path()` helper in the core layer, and standardize environment-variable names.

```
// Before: each entry point hardcodes its own path
fn get_db_path() -> PathBuf { base.join("server.db") }  // server
fn get_db_path() -> PathBuf { base.join("data.db") }    // desktop

// After: converge on one shared core helper
pub fn default_db_path() -> PathBuf {
    dirs::data_local_dir().unwrap_or_else(|| PathBuf::from("."))
        .join("app").join("app.db")
}
```

## U-12: Shared-data fallback creates the wrong file on first boot (high)
Fallback logic can create a split file during first startup. Fix: ensure every startup path converges on the same physical location.

## U-13: Environment variable names diverge across entry points (medium)
For example, `SERVER_DB_PATH` and `DESKTOP_DB_PATH` point at different defaults. Fix: unify them under one name such as `APP_DB_PATH`.

## U-14: CLI default path uses a different base directory than GUI/server (medium)
Different entry points use different base directories. Fix: make every entry point call the same shared path constructor.
