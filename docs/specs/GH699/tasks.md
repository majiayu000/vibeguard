# Tasks — GH-699 免 clone 安装

## Implementation Tasks

- [x] `SP699-T1` Owner: unassigned — payload manifest 与本地可复现打包合同:新增精确 install-only `scripts/release/payload-manifest.txt`,以同一 git ref 的 manifest blob 和内容产出 byte-identical `vibeguard-payload-<version>.tar.gz`;release workflow 将 payload 与 runtime 一同纳入排序后的 `SHA256SUMS` 和 attestation。Done when:同 ref 重复打包 SHA-256 一致,dirty working tree 不改变 `--ref HEAD` 输出,manifest 路径存在且 release 静态合同通过。Verify: `bash tests/test_payload.sh && bash tests/test_release_workflow.sh`
- [x] `SP699-T2` Owner: unassigned — `setup.sh` payload 模式:运行根探测,禁止源码回退、跨版本 runtime override 和 dev-linked,checkout-only 子命令显式 not-applicable。Done when:在 temp HOME 中解包 payload 后 `bash setup.sh --yes` 与 `bash setup.sh verify-install` 使用本地 release fixture 成功,且 payload-only 逃生口均 fail-closed。Verify: `bash tests/test_payload.sh`
- [ ] `SP699-T3` Owner: unassigned — bootstrap 共享内核:在 `scripts/setup/` 下新增 `bootstrap.sh`(下载 payload、校验、原子切换 dist/current、exec setup)。 Done when: 篡改 payload 或校验和时以校验错误终止且不落盘安装。 Verify: `bash tests/test_setup.sh`
- [ ] `SP699-T4` Owner: unassigned — no-clone runner 与真实发布证据:在 macOS+Ubuntu runner 仅从构建产物执行下载→安装→`verify-install` smoke,并保留 tag 演练 run/release 页资产证据。T1 只负责本地打包与 release 静态合同,不以此替代 T4 的 runner/release-run 验证。Done when: tag 演练 run 全绿且 release 页出现 payload 资产。Verify: `gh run view <release-run>`
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
