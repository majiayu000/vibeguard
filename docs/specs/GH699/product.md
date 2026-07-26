# Product Spec — 免 clone 安装:发布产物成为唯一分发单元

## Linked Issue

GH-699

complexity: large

## 用户问题

VibeGuard 当前唯一受支持的安装路径是 `git clone` 整个仓库 + `bash setup.sh`。
运行时二进制已经从 release 下载并做 SHA-256 / attestation 校验,但 rules、
hooks、guards、skills、templates 仍然从 git checkout 读取——**仓库本身就是安装
介质**。对目标用户(Claude Code / Codex 用户,多数没有 Rust 工具链、也不想维护
一份第三方 checkout)来说,这是最大的采纳门槛,也是增长 roadmap
(`plan/2026-07-26-growth-and-architecture-roadmap.md`,WS1)判定的第一优先级。

`docs/specs/install-friction-reduction.md`(2026-06-02)已经落地了它的 §3.1–§3.4
(预编译二进制、校验、VERSION 锁定、调度器 opt-in);本 spec 承接它的 §3.5 遗留
方向,但不做单二进制合并,而是把"安装所需的全部内容"打成一个带校验的发布产物。

## 设计决策(需维护者确认)

安全约束:`docs/specs/install-friction-reduction.md` §4 明确"下载路径不得把远端
内容通过管道送进 shell"。因此 **curl | bash 一键脚本不在方案内**。选定路线是
GH-699 评论中的方案 (a):

- **包管理器作为免 clone 入口**:brew tap(macOS/Linux)与 npm 包(`bunx vibeguard`),
  两者自带完整性模型(formula 内置 sha256 / npm 锁定 tarball 摘要)。
- 包管理器安装的是一个薄启动器;真正的规则/hook 内容来自带 SHA-256 与
  attestation 的 release payload 产物,复用现有校验语义。

## 目标

- G1:发布流水线额外产出一个 **payload 产物**(rules/hooks/guards/skills/
  templates/schemas + 安装入口),进 `SHA256SUMS` 与 attestation,与运行时二进制
  同 tag、同校验强度。
- G2:`setup.sh` 支持 **payload 模式**:从解包后的 payload 目录运行时,行为与
  git checkout 运行完全一致(profiles、languages、verify-install、doctor、clean)。
- G3:brew formula 与 npm 包作为免 clone 入口,安装后一条命令完成部署并通过
  `verify-install`。
- G4:git checkout 路径保持完全兼容,降级为"开发/贡献者路径";文档相应改写。

## 非目标

- 不做 curl | bash 引导脚本(违反上游 spec §4 的供应链立场)。
- 不做 Windows 原生包(hooks 依赖 bash;沿用现状 smoke-contract 级别支持)。
- 不把 Python 可选组件(evals、docs 生成、语言 guard packs)打进 payload;它们
  保持 checkout-only。
- 不在本 spec 内做 Claude Code plugin marketplace 上架(依赖 payload 存在,单独
  开 issue)。

## Done-when

- 一台全新 macOS/Linux 机器,不装 Rust、不 clone 仓库,通过 brew 或 bunx 一条
  命令(加一次确认)完成安装,`verify-install` 退出码 0,新开 Claude Code /
  Codex 会话后 hook 拦截真实生效。
- 篡改 payload 或校验和使安装以校验错误终止,绝不静默降级。
- 现有 clone + `setup.sh` 路径的全部 CI 门(行为评测、contract check、
  self-application)在 payload 模式下有等价覆盖或被显式豁免并说明原因。
