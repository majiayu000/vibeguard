# Tasks — GH-699 免 clone 安装

## Implementation Tasks

- [x] `SP699-T1` Owner: unassigned — payload manifest 与打包脚本:新增 `scripts/release/payload-manifest.txt` 与打包 step,产出 `vibeguard-payload-<version>.tar.gz` 并进 `SHA256SUMS` / attestation。 Done when: 本地以任意 tag 版本可复现打包,manifest 路径全部存在断言通过。 Verify: `bash scripts/local-contract-check.sh --quick`
- [x] `SP699-T2` Owner: unassigned — `setup.sh` payload 模式:运行根探测 + 两处白名单差异(无源码回退;checkout-only 子命令显式 not-applicable)。 Done when: 解包 payload 后 `bash setup.sh --yes` 与 `bash setup.sh verify-install` 行为与 checkout 一致。 Verify: `bash setup.sh verify-install`
- [ ] `SP699-T3` Owner: unassigned — bootstrap 共享内核:在 `scripts/setup/` 下新增 `bootstrap.sh`(下载 payload、校验、原子切换 dist/current、exec setup)。 Done when: 篡改 payload 或校验和时以校验错误终止且不落盘安装。 Verify: `bash tests/test_setup.sh`
- [ ] `SP699-T4` Owner: unassigned — release workflow 集成:payload 构建、VERSION==tag 断言、macOS+Ubuntu 免 clone smoke(下载产物→安装→verify-install)。 Done when: tag 演练 run 全绿且 release 页出现 payload 资产。 Verify: `gh run view <release-run>`
- [ ] `SP699-T5` Owner: unassigned — brew tap:`majiayu000/homebrew-vibeguard` formula + release 自动 bump。 Done when: `brew install majiayu000/vibeguard/vibeguard && vibeguard --yes` 后 `verify-install` 退出码 0。 Verify: `bash setup.sh verify-install`
- [ ] `SP699-T6` Owner: unassigned — npm 启动器:`vibeguard` 包,无 postinstall 副作用,`bunx vibeguard init` 走 bootstrap。 Done when: 干净机器 `bunx vibeguard init` 完成安装并通过 verify-install。 Verify: `bash setup.sh verify-install`
- [ ] `SP699-T7` Owner: unassigned — 文档:README 安装节、`docs/how/quickstart.md`、`docs/how/team-rollout.md` 改写为免 clone 默认 + checkout 开发者路径。 Done when: 文档路径校验通过且首屏安装命令为包管理器入口。 Verify: `bash scripts/ci/validate-doc-paths.sh`

## Verification

- 免 clone AC:全新环境,brew 或 bunx 单命令安装,`verify-install` 退出 0,新会话 hook 拦截生效。
- 供应链 AC:payload/校验和被篡改 → 安装终止;`--require-provenance` 在 attestation 不可用时 fail-closed。
- 兼容 AC:checkout 路径全部现有 CI 门保持绿;payload 与 checkout 的 hook 内容 byte-identical(manifest+SHA 断言)。

## Parallelization

- SP699-T1 / SP699-T2 可并行(打包侧与安装侧接口是 manifest + 标记文件)。
- SP699-T3 依赖 T1、T2;T4 依赖 T1–T3;T5 / T6 依赖 T4 后可并行;T7 最后。
