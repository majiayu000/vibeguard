
# 跨入口数据一致性规则

Monorepo / workspace 中多个 binary 共享数据源时，必须检查配置收敛性。

## U-11: 多 binary 默认 DB/缓存路径不一致（高）
各入口硬编码不同的数据路径导致数据分裂。修复：所有入口调用 core 的公共 `default_db_path()` 函数，环境变量统一命名。

```
// Before: 各入口各自硬编码
fn get_db_path() -> PathBuf { base.join("server.db") }  // server
fn get_db_path() -> PathBuf { base.join("data.db") }    // desktop

// After: 统一到 core 的公共函数
pub fn default_db_path() -> PathBuf {
    dirs::data_local_dir().unwrap_or_else(|| PathBuf::from("."))
        .join("app").join("app.db")
}
```

## U-12: 共享数据源 fallback 路径创建错误文件（高）
首次启动时 fallback 逻辑创建分裂文件。修复：确保所有启动顺序都收敛到同一物理路径。

## U-13: 多入口环境变量名不统一（中）
如 `SERVER_DB_PATH` vs `DESKTOP_DB_PATH` 指向不同默认值。修复：统一环境变量名，如全部使用 `APP_DB_PATH`。

## U-14: CLI 默认路径与 GUI/Server 基目录不同（中）
不同入口的基目录不一致。修复：统一基目录，所有入口调用同一个路径构造函数。
