
# Cross-entry data consistency rules

When multiple binaries share data sources in a Monorepo/workspace, configuration convergence must be checked.

## U-11: Multiple binary default DB/cache paths are inconsistent (high)
Hardcoding different data paths for each entry leads to data fragmentation. Fix: All entries call the core's public `default_db_path()` function, and the environment variables are named uniformly.

```
// Before: Each entry is hard-coded.
fn get_db_path() -> PathBuf { base.join("server.db") }  // server
fn get_db_path() -> PathBuf { base.join("data.db") }    // desktop

// After: unified to core public functions
pub fn default_db_path() -> PathBuf {
    dirs::data_local_dir().unwrap_or_else(|| PathBuf::from("."))
        .join("app").join("app.db")
}
```

## U-12: Shared data source fallback path creation error file (high)
Fallback logic creates split files on first startup. Fix: Ensure all boot sequences converge to the same physical path.

## U-13: Multiple entry environment variable names are not uniform (medium)
For example, `SERVER_DB_PATH` vs `DESKTOP_DB_PATH` points to different default values. Fix: Unify environment variable names, such as using `APP_DB_PATH` for all.

## U-14: CLI default path is different from GUI/Server base directory (medium)
The base directories of different entries are inconsistent. Fix: Unify the base directory and call the same path constructor for all entries.
