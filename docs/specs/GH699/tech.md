# Tech Spec — 免 clone 安装:payload 产物 + 包管理器入口

## Linked Issue

GH-699

## 现状(本会话核实)

- `.github/workflows/release.yml` 在 tag push 时构建 4 个平台的
  `vibeguard-runtime` 二进制,连同 `SHA256SUMS` 与 attestation 上传 release。
- `scripts/setup/install.sh` 从 release 下载二进制并做 SHA-256 /
  attestation 校验,失败时回退 cargo 源码构建;但 rules/hooks/guards/skills/
  templates 全部以 `$REPO_ROOT`(即 git checkout)为源拷贝到
  `~/.vibeguard/installed/`。
- `vibeguard-runtime/VERSION` 是 release 版本的单一事实源(当前 `1.1.12`),CI
  断言其与 tag 一致。
- `setup.sh` 是安装/校验/清理的唯一入口,内部委托 `scripts/setup/` 下的模块。

## 方案

### 1. payload 产物(release 侧)

`.github/workflows/release.yml` 新增一个 job step:把安装所需内容打成

```
vibeguard-payload-<version>.tar.gz
```

内容为 git archive 的一个白名单子集(单一来源清单文件,新增
`scripts/release/payload-manifest.txt`):

- `rules/` `hooks/` `guards/` `skills/` `templates/` `schemas/` `agents/`
  `workflows/` `claude-md/` `context-profiles/` `packs/`
- `setup.sh` + `scripts/setup/` + `scripts/doctors/` + `scripts/hook-health.sh`
  + `scripts/project-init.sh` + 其余 setup 运行期依赖的脚本(以 manifest 为准,
  CI 校验 manifest 中路径全部存在)
- `vibeguard-runtime/VERSION`(payload 与二进制版本自洽的依据)
- `LICENSE` `CHANGELOG.md`

产物条目追加进现有 `SHA256SUMS`,并纳入现有 attestation 覆盖范围。排除测试、
eval、docs、site、plan 等开发面——payload 是安装介质,不是仓库镜像。

### 2. `setup.sh` payload 模式(安装侧)

- `setup.sh` 启动时探测运行根:存在 `.git` → checkout 模式(现状不变);存在
  payload 标记文件(打包时写入 `PAYLOAD_MANIFEST_SHA`)→ payload 模式。
- payload 模式差异仅两点:
  1. 跳过"未发布 main 回退 cargo 构建"分支——payload 永远对应一个已发布 tag,
     二进制资产必然存在;下载失败即失败,不做源码回退。
  2. `verify-dev-repo` 等仅对 checkout 有意义的子命令显式报
     `not applicable in payload mode` 并退出非零,而不是误报 BROKEN。
- 其余逻辑(profiles、languages、hook 部署、`verify-install`、doctor、clean)
  不分叉,同一套代码跑两种根。**禁止**为 payload 模式复制一份并行安装逻辑。

### 3. 免 clone 入口

**bootstrap 子命令(共享内核)**

在 `scripts/setup/` 下新增 bootstrap 脚本 `bootstrap.sh`(brew/npm 共用,不接受管道输入):

1. 读取入口自带的 pinned version(brew formula / npm 包版本即 payload 版本);
2. 下载 `vibeguard-payload-<version>.tar.gz` + `SHA256SUMS`(`gh` 优先,回退
   `curl -fsSL`,与 `scripts/setup/install.sh` 现有下载器同源复用);
3. SHA-256 校验失败即终止;可用时执行 attestation 校验,语义与现状一致
   (`verified-provenance` / `checksum-only`);
4. 解包到 `~/.vibeguard/dist/<version>/`,原子切换 `~/.vibeguard/dist/current`
   符号链接;
5. exec `~/.vibeguard/dist/current/setup.sh "$@"`(payload 模式)。

**brew tap**

- 新仓库 `majiayu000/homebrew-vibeguard`,formula 直接以 payload tarball 为
  source(`url` + `sha256` 内置于 formula,brew 自身完成校验),安装出一个
  `vibeguard` 命令 = bootstrap 的薄封装(此时步骤 2–3 已由 brew 完成,直接
  4–5)。
- formula 由 release workflow 在发 tag 时自动 bump(PR 到 tap 仓库)。

**npm 包**

- 包名 `vibeguard`,无 postinstall 副作用;`bunx vibeguard init` 显式触发
  bootstrap 全流程。包内只有启动器脚本与 pinned version,不内嵌 payload。

### 4. CI / 契约

- release workflow 新增断言:payload 内 `vibeguard-runtime/VERSION` == tag;
  manifest 中路径全部存在;payload 解包后 `bash setup.sh verify-install` 的
  smoke 在 macOS + Ubuntu runner 上通过(不 clone,只用 release 产物)。
- `scripts/local-contract-check.sh` 增加 payload manifest 存在性 + 标记文件
  生成的确定性测试。
- 行为评测门继续跑在 checkout 上(payload 是其子集,hook 内容 byte-identical,
  由 manifest + SHA 断言保证,无需重复跑一遍)。

## 安全

- 沿用 `docs/specs/install-friction-reduction.md` §4:不管道执行远端内容;
  payload 校验失败即终止,无未校验回退;attestation 语义(
  `verified-provenance` / `checksum-only` / `--require-provenance` fail-closed)
  原样适用于 payload 产物。
- brew/npm 入口各自叠加其生态的完整性模型(formula sha256、npm tarball 摘要),
  与 release 侧校验形成双层。
- SEC-13:bootstrap 与 payload 模式不得静默改写 `~/.claude/settings.json` /
  `AGENTS.md` 之外新增任何高上下文面;写入面与现有 `setup.sh` 完全一致。

## 风险

- payload 白名单漏文件 → 安装物残缺。缓解:manifest 单一事实源 + release
  smoke(AC 里必须真装真验)。
- brew tap 自动 bump 依赖跨仓库 token。缓解:tap PR 用 fine-grained token,
  失败只影响 brew 渠道,不阻塞 release 本体。
- 双模式漂移(checkout 与 payload 行为分叉)。缓解:同一 `setup.sh` 代码路径 +
  差异点白名单化(仅上述两处),新增差异需改本 spec。
