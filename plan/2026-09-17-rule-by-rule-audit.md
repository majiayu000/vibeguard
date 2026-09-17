# VibeGuard 125 条规则逐项对照

日期：2026-09-17。分析基线：origin/main，49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a。状态：用户已授权破坏性重构；本表处置已落实为 75 个 canonical 主题与 Rust v2 实现，交付状态见配套重构方案。

通过仓库自身的 parse_rules 解析得到 125 个唯一 ID，六个规则线程逐条检查，第七个线程检查 Rust 职责；主线程核对覆盖、关键源码和反例。每个 ID 链接固定到分析基线原文。这里覆盖全部 canonical 规则，不把生成文档当另一套规则，也不把当前安装提示里的“127”当主干事实。

保留＝核心内容仍适用，可吸收重复项或微调适用范围；改写＝风险仍真实，但触发、结论或修法过宽；合并＝撤销独立条目，内容并入指定主题；交工具＝采用专业工具的明确检查，保留必要解释；删除＝撤销独立通用政策，不禁止项目在具体任务中采用该技术。以下均是设计判断，不是实模收益统计。

| 分组 | 保留 | 改写 | 合并 | 交工具 | 删除 | 合计 |
|---|---:|---:|---:|---:|---:|---:|
| 通用规则 | 7 | 9 | 12 | 0 | 1 | 29 |
| 工作流程 | 1 | 10 | 9 | 1 | 1 | 22 |
| 安全规则 | 6 | 7 | 3 | 1 | 0 | 17 |
| Rust 规则（含 TASTE） | 0 | 6 | 8 | 2 | 2 | 18 |
| Python / Go 与数据边界 | 5 | 6 | 4 | 5 | 5 | 25 |
| TypeScript / React | 2 | 5 | 3 | 2 | 2 | 14 |
| 合计 | 21 | 43 | 39 | 11 | 11 | 125 |

统计按旧条目的主要动作归类，不等于新版需要加载 75 条强制指令；合并后的内容仍要去重，常驻上下文只放极少数通用原则。相关的执行器、生成文档、示例、测试和评测必须同批改变。完整产品方案见 [Rust 核心重构方案](2026-09-17-frontier-model-reconstruction.md)。

**通用规则**

| 原 ID / 源文 | 原要求或问题摘要 | 建议 | 调整后的边界与执行方式 |
|---|---|---|---|
| [U-01](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L3) | 尊重 API 契约 | 保留 | 按本次授权维护契约；明确允许破坏性重构时直接改，不自动补兼容层。归属：短指令、接口测试。 |
| [U-02](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L6) | 单次代码不能抽象 | 改写 | 按当前职责与可读性决定抽象；删“第三次才抽取”等计数口诀。归属：审查。 |
| [U-03](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L9) | 重复代码与宏 | 合并 | 并入 U-02；宏可表达合理领域语义，删固定重复次数和统一替代法。归属：审查。 |
| [U-04](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L12) | 不添加未请求功能 | 保留 | 保留任务范围边界；明确授权的大重构可在范围内充分实施。归属：短指令、任务验收。 |
| [U-05](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L15) | 删除疑似死代码前确认 | 改写 | 先查调用者、导出与用户意图；证据充分且已授权就删除，不每次问人。归属：审查。 |
| [U-06](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L18) | 标准库优先、少依赖 | 改写 | 优先已有能力，结合正确性、安全与维护成本选依赖；不能因此手写密码学或复杂解析器。归属：审查。 |
| [U-07](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L21) | 修行为不改风格 | 合并 | 并入 U-04；避免无关格式差异，不强制每次顺带格式调整都单独提交。归属：范围审查。 |
| [U-08](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L24) | 不跳过验证 | 合并 | 并入 W-03，删除重复验证口令。归属：实际工具结果。 |
| [U-09](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L27) | 提交不混入无关修复 | 合并 | 并入 U-21；提交按连贯变更组织，只有提交任务才触发。归属：提交审查。 |
| [U-10](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L30) | 不要猜用户意图 | 改写 | 仅对会改变范围、授权或正确性的缺失事实澄清；常规实现选择自行判断。归属：短指令。 |
| [U-11](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/data-consistency.md#L13) | 多入口数据路径一致 | 改写 | 只在应共享同一数据集时统一解析；不指定 APP_DB_PATH、helper 名称或 core 层。归属：集成测试、审查。 |
| [U-12](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/data-consistency.md#L28) | 首次启动错误创建共享数据文件 | 合并 | 并入 U-11；覆盖首次启动解析结果，不能用 cwd 回退掩盖共享路径错误。归属：边界测试。 |
| [U-13](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/data-consistency.md#L31) | 入口环境变量名不一致 | 合并 | 并入 U-11；变量名不同本身不构成数据分裂，检查最终数据源。归属：边界测试。 |
| [U-14](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/data-consistency.md#L34) | CLI 与 GUI 默认目录不一致 | 合并 | 并入 U-11；按是否应共享数据判断，不统一所有独立数据目录。归属：边界测试。 |
| [U-15](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L33) | 通用不可变优先 | 删除 | 删除跨语言默认复制与不可变训诫；Rust 的受控可变借用正常，所有权由语言与实际需求决定。 |
| [U-16](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L36) | 文件大小控制 | 改写 | 删除全局 400/800 行硬阈值、历史基线与自动拆分；按职责审查，项目明确的体量政策交已有 lint。 |
| [U-17](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L55) | 完整处理错误 | 合并 | 并入 U-29，统一错误语义，避免重复捕获与重复日志。 |
| [U-18](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L59) | 校验输入 | 保留 | 在可信边界按契约校验一次，不每层重验。归属：项目边界实现与测试。 |
| [U-19](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L62) | 遵守数据访问边界 | 保留 | 遵循项目已存在的分层；不要求每个项目新建 Repository 抽象。归属：按需审查。 |
| [U-20](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L65) | 响应形状一致 | 合并 | 并入 U-01；保持具体 API 契约，不发明统一 envelope 或错误码平台。归属：接口测试。 |
| [U-21](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L68) | 项目提交约定 | 保留 | 只在提交时遵循现有约定，吸收 U-09。归属：提交工具与审查。 |
| [U-22](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L71) | 验证改变的行为 | 保留 | 当前按风险、行为与项目命令选测试的方向合理；不设全局覆盖率或测试数量。归属：项目检查。 |
| [U-23](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L81) | 不静默降级 | 合并 | 并入 U-29，删除重复正文和不同严重度表达。 |
| [U-24](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L84) | 命名修改不越界 | 合并 | 并入 U-04；保留范围约束，不生成独立命名门禁。 |
| [U-25](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L87) | 连贯变更后处理构建错误 | 合并 | 并入 W-03；避免逐编辑构建，提交前完成适用验证。 |
| [U-26](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L93) | 声明与执行接通 | 保留 | 核对承诺行为、真实生命周期与消费者；默认值、惰性加载、退出时保存可以合理。归属：集成测试、审查。 |
| [U-29](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/no-silent-degradation.md#L3) | 错误驱动降级必须 error 级日志 | 改写 | 改为失败不得伪装成功；允许正确传播 Result 和已授权 best-effort，日志级别不能代替语义，不强制 is_fallback 字段。 |
| [U-32](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L99) | 检查指令过载 | 改写 | 审查冲突、重复和过宽触发；清点存在文件不等于模型已加载，不以数量判质量。归属：按需指令审查。 |
| [U-33](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/coding-style.md#L112) | 大仓库强制结构导航 | 改写 | 按任务选 rg、LSP 或索引；删 400k LOC/50 次搜索阈值，纠正 claude-context 不用向量的错误描述。 |

**工作流程**

| 原 ID / 源文 | 原要求或问题摘要 | 建议 | 调整后的边界与执行方式 |
|---|---|---|---|
| [W-01](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L5) | 没有根因不修复 | 改写 | 围绕证据、可检验假设和原始症状推进；不要求所有问题先永久复现测试或逐行阅读。 |
| [W-02](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L22) | 三次失败必须后退 | 合并 | 并入 W-01；反复失败应挑战假设，但次数不自动判停滞或强制暂停。 |
| [W-03](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L37) | 验证后才声称完成 | 改写 | 结论对应真实终态结果及实际覆盖对象；当前 head 的可靠 CI 也可用。Rust 提供事实，不颁发“任务全部完成”证明。 |
| [W-04](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L73) | 测试先行 | 改写 | 按项目约定与变更风险选择 TDD；不把所有功能、文档或机械修改变成先写测试流程。 |
| [W-05](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L230) | 子代理上下文隔离 | 改写 | 有独立任务才分工，传递足够相关上下文；删永不传历史、评审仅看 diff/spec 的绝对限制。 |
| [W-10](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/publish-action-confirmation.md#L3) | 具体行动确认并复用授权 | 保留 | 当前边界合理；按用户已给授权执行，确实超范围才询问，不加新审批协议。 |
| [W-11](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/fact-inference-separation.md#L3) | 区分事实推断建议 | 改写 | 重要结论说明证据和不确定性；不逐句贴标签，不要求每个事实都列替代解释。 |
| [W-12](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L90) | 保护测试完整性 | 改写 | 保留不得造假或削弱验收；允许合理修改测试与配置，删除文件名硬禁和“删除断言即作弊”的判断。 |
| [W-13](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L66) | 检查无效探索 | 合并 | 并入 W-01；当前正文允许有价值阅读，删除其他执行路径中的计数催促编辑。 |
| [W-14](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L117) | 单写者仓库所有权 | 改写 | 限制同一可变工作区的冲突写入；隔离 worktree 可独立工作，共享外部状态另明确归属。 |
| [W-15](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L148) | 低信息循环检测 | 合并 | 并入 W-01；删除 3 轮、50%、300 字等自动中断代理指标。 |
| [W-16](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L194) | 验证必须来自本会话 | 合并 | 并入 W-03；证据是否对应当前交付物比会话来源重要，旧代码结果不能冒充新结果。 |
| [W-17](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L202) | 少而精的门禁 | 合并 | 并入 W-19；删除规则数量阈值与自动化天然更优的推断。 |
| [W-18](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/eval-validation.md#L11) | 评测要检查路径 | 改写 | 以任务结果及必要权限、只读等不变量评分；不要求唯一轨迹，ECE 仅在有有效置信度数据时使用。 |
| [W-19](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L242) | 指令文件体量与正反例配对 | 改写 | 保留相关性、冲突与负担审查；删除字数硬失败、每条禁令必配示例等形式要求。 |
| [W-20](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/execution-pinning.md#L3) | 显式可复现实验固定环境 | 交工具 | 仅对明确复现实验记录所需版本与 lockfile；Rust 可收集事实，删除一般工作中的环境漂移阻断。 |
| [W-21](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/evidence-provenance.md#L3) | 证据确实执行过 | 合并 | 并入 W-03；保留原始记录与可核查结果，不再重复跑一轮只为证明记录存在。 |
| [W-30](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/agent-harness-audit.md#L3) | Harness 边界保真稳定性 | 合并 | 并入 W-18；保留评测维度，删每步计划 ID、每五轮报告、所有助手只读等强制轨迹。 |
| [W-37](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L278) | 从成功与失败学习 | 改写 | 有记忆需求时沉淀确有用的经验；不强制每次失败生成规则、状态 schema 或每次检索配齐两类样例。 |
| [W-38](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/workflow.md#L308) | 区分工具需要识别与调用 | 合并 | 并入 W-18，作为有需要的诊断指标；删统一 20% 阈值和对隐藏推理的要求。 |
| [W-41](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/vibe-coding-production.md#L3) | 生产系统五项不变量 | 删除 | 移出通用执行规则；与授权、验证、运维实践重复，不能给每个仓库追加日志部署平台。 |
| [W-42](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/long-horizon-reliability.md#L3) | 交付物传递不变量 | 合并 | 并入 W-03；保留重要约束跨交接验证，不给普通任务追加轮次与保真率流程。 |

**安全规则**

| 原 ID / 源文 | 原要求或问题摘要 | 建议 | 调整后的边界与执行方式 |
|---|---|---|---|
| [SEC-01](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L3) | 防 SQL/NoSQL/命令注入 | 改写 | 不可信值不能改变操作结构；参数化、标识符与目标程序分别处理，argv 也非完整安全证明。归属：边界实现、审查。 |
| [SEC-02](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L11) | 不硬编码凭证 | 保留 | 吸收 SEC-10，敏感数据不得进入非授权代码、提交或输出；用现有 secret scanner，Rust 减少并脱敏自身日志。 |
| [SEC-03](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L15) | HTML 输入转义 | 保留 | 按 HTML/JS/URL 实际上下文处理；需要富文本才选择 sanitizer，不能看到 innerHTML 就一律暂停。 |
| [SEC-04](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L18) | API 认证授权 | 改写 | 保护需要保护的操作并检查资源级授权；公开 endpoint 正常，存在 middleware 不代表授权正确。 |
| [SEC-05](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L21) | 已知依赖漏洞 | 交工具 | 用 lockfile、当前漏洞库与项目工具判版本风险；可利用性另审。Rust 归集真实结果，不复制漏洞数据库。 |
| [SEC-06](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L24) | 弱密码算法 | 改写 | 限定密码存储和安全用途，采用适当成熟算法；非安全 MD5 使用不自动构成密码漏洞。 |
| [SEC-07](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L27) | 文件路径校验 | 改写 | 检查非可信路径实际访问是否越过授权边界，考虑平台、符号链接与归档；normalize 不等于安全。 |
| [SEC-08](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L30) | 防 SSRF | 保留 | 按真实服务端请求边界限制非可信目标，结合网络隔离；字符串 URL 检查非完整保证。 |
| [SEC-09](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L33) | 安全反序列化 | 保留 | 判断来源及对象构造能力，使用安全 API；仅凭 yaml.load 名称不能判漏洞。 |
| [SEC-10](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L36) | 日志不泄露敏感信息 | 合并 | 并入 SEC-02；保留 Rust 自身脱敏，不宣称正则能发现所有秘密。 |
| [SEC-11](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L39) | AI 代码安全基线与强制人审 | 改写 | 按认证、支付、敏感数据、执行边界的实际风险安排独立审查；删研究倍数泛化、AI 作者标签和每条新测试复述要求。 |
| [SEC-12](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L82) | MCP 描述漂移 | 改写 | 审查来源、实际权限与敏感更新；删每次描述 hash 变化强制审批。alwaysLoad 是预加载，不是永久全信任。 |
| [SEC-13](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L123) | 高上下文文件完整性 | 改写 | 保护免受未经授权的依赖/生成器修改；授权内不重复询问，异常先归因并展示 diff，不能默认删用户文件。 |
| [SEC-14](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L180) | MCP 描述拒绝权威及覆盖词 | 合并 | 并入 SEC-18；删除关键词硬拒绝引擎，攻击示例和防御文档不因引用词语成为攻击。 |
| [SEC-16](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L213) | 按 CWE 禁止 AI 安全修复 | 合并 | 并入 SEC-11；按实际数据流、攻击回归与影响审查，删除作者身份和类别硬表裁决。 |
| [SEC-17](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L248) | 第三方 skill 与真实权限 | 保留 | 现有来源、权限审查及复用信任的边界合理；保留宿主隔离，不新建证书平台。 |
| [SEC-18](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/common/security.md#L256) | 外部内容限于授权任务 | 保留 | 外部内容作为数据，拒绝越权和敏感数据改道；普通任务内阅读不加审批，吸收 SEC-14。 |

**Rust 规则（含 TASTE）**

| 原 ID / 源文 | 原要求或问题摘要 | 建议 | 调整后的边界与执行方式 |
|---|---|---|---|
| [RS-01](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L7) | 嵌套锁获取 | 改写 | 检查锁顺序、生命周期与跨 await 持锁；不强制 Signal<State>，Clippy 只覆盖部分模式。 |
| [RS-02](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L10) | get 后 insert 即 TOCTOU | 改写 | 同一锁内或单线程不自动有竞争；Entry 按具体场景使用，map_entry 不证明并发安全。 |
| [RS-03](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L13) | 非测试 unwrap | 交工具 | 采用项目选择的 Clippy unwrap/expect 策略，保留有意 panic 的判断；不能为消警把错误改成默认值。 |
| [RS-04](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L16) | 多 Signal/Arc 管同一状态 | 合并 | 并入 RS-12；多个 Arc 可指向同一份状态，不能据此要求 Signal 或合并结构。 |
| [RS-05](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L19) | 同名异义类型 | 改写 | 按领域含义和 API 边界判断；模块内同名合法，不按名称匹配强制合并所有类型。 |
| [RS-06](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L22) | 重复 match 分支 | 合并 | 并入 U-02；先统一正文、Rust 扫描与 eval 的三种含义，按实际共享职责判断重复。 |
| [RS-07](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L25) | 手工逐字段复制 | 删除 | 普通字段复制可读且类型安全；不为此默认新增 apply 方法、Update trait 或抽象层。 |
| [RS-08](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L28) | 多余 clone | 交工具 | Copy 克隆交 Clippy clone_on_copy；其余按所有权与测量判断，借用不总比克隆适合。 |
| [RS-09](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L31) | 热点 format 分配 | 改写 | 先证实热点与规模再优化，不能全局禁止 format! 或猜容量。 |
| [RS-10](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L34) | 丢弃有意义 Result | 合并 | 并入 U-29；检查实际错误语义，let _ 不一定接收 Result，正确传播无须逐层日志。 |
| [RS-11](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L44) | 同系统不同基础设施 | 合并 | 并入 RS-12；同一事实出现独立可变副本才重点审查，不同职责可以选不同设施。 |
| [RS-12](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L47) | 两个系统同一职责 | 改写 | 检查真实状态所有权与行为重叠；删 Todo/TaskManagement 名称判断和自动删除建议。 |
| [RS-13](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L50) | 动作命名函数无副作用 | 合并 | 并入 U-26；委托执行、纯函数返回新状态均可正确，删除按 insert/push 等字符串推断生效。 |
| [RS-14](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L53) | 声明未接入启动 | 合并 | 并入 U-26；按实际生命周期查消费者，保存可在退出时、加载可惰性；删 startup 文本匹配硬门禁。 |
| [RS-20](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/struct-field-change-checklist.md#L7) | 结构字段变更查全链 | 改写 | 只检查真实存在且受影响的序列化、存储和调用者；编译器已覆盖的构造缺项不另造四轮搜索与兼容回填。 |
| [TASTE-ANSI](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L82) | 硬编码 ANSI | 删除 | 这是项目风格选择，不是全局缺陷；无需为少量转义强制加依赖。 |
| [TASTE-ASYNC-UNWRAP](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L85) | async 内 unwrap | 合并 | 并入 RS-03；异步场景风险由任务边界决定，不维护重复规则。 |
| [TASTE-PANIC-MSG](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/rust/quality.md#L88) | panic 缺说明 | 合并 | 并入 RS-03，保留有意 panic 及上下文说明的审查，不用非空字符串证明合理。 |

**Python / Go 与数据边界**

| 原 ID / 源文 | 原要求或问题摘要 | 建议 | 调整后的边界与执行方式 |
|---|---|---|---|
| [PY-01](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L7) | 可变默认参数 | 交工具 | 用 Ruff B006；保留有意共享状态的明确例外，自动修复不视为总安全。 |
| [PY-02](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L10) | 裸 except 与宽泛捕获 | 合并 | 并入 U-29；有日志不等于正确恢复，允许边界捕获与正确传播；Ruff E722 只补语法检查。 |
| [PY-03](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L13) | 独立异步任务并发 | 保留 | 现有顺序、限流、独立性和资源边界合理；同步修正 eval 中顺序 await 一律有错的标签。 |
| [PY-04](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L17) | 500 行类/10 个方法 | 合并 | 并入 PY-09；两种计数均不能证明职责混乱，删除自动抽 mixin/service。 |
| [PY-05](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L20) | 重复 try/except | 删除 | 相似语法可能有不同错误、重试与取消语义；不默认抽统一装饰器。 |
| [PY-06](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L23) | 循环重复正则编译 | 删除 | Python 会缓存近期模式；是否预编译按测量和 pattern 生命周期决定，不作默认缺陷。 |
| [PY-07](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L26) | 循环字符串拼接 | 删除 | 按输入规模、热点和流式需求选 join 等写法；不凭循环出现就强制性能改写。 |
| [PY-08](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L29) | eval/exec/__import__ | 改写 | 检查非可信输入是否进入执行边界；动态执行存在不等于越权，Ruff 可列候选但不证明可利用性。 |
| [PY-09](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L32) | 函数职责混杂 | 保留 | 现有不为行数拆函数的方向合理；吸收类与嵌套结构审查，局限当前变更。 |
| [PY-10](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L35) | 嵌套超过四层 | 合并 | 并入 PY-09；清楚的数据遍历可保留，只改实际妨碍理解与验证的结构。 |
| [PY-11](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L38) | open 未使用 with | 交工具 | 用 Ruff SIM115，结合句柄所有权转移、返回资源及 ExitStack；不强制所有 open 就地关闭。 |
| [PY-13](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/quality.md#L43) | 死兼容转发模块 | 改写 | 确认调用者、迁移状态及公共入口契约后删除；纯 re-export 只能是线索，不能证明 dead。 |
| [U-30](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/pydantic-boundary.md#L7) | 边界未知字段处理 | 保留 | 按实际数据契约选择 forbid/allow/ignore；不要求每个 Pydantic 模型机械声明。 |
| [U-31](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/python/pydantic-boundary.md#L13) | 语义变化使缓存失效 | 改写 | 保留语义失效原则，移到通用数据一致性范围；不为每个 key 强制版本号或新缓存协议。 |
| [GO-01](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L7) | 忽略 error 返回 | 交工具 | 用 errcheck -blank 检查真正 error；停止把所有 _ = fn() 判错，错误后续语义仍须审查。 |
| [GO-02](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L10) | goroutine 泄漏 | 改写 | 检查有限工作、阻塞点和退出归属；不要求每个 goroutine 有 Context/select，删除当前关键词严格检查。 |
| [GO-03](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L13) | 数据竞争 | 交工具 | 运行项目适用的 go test -race，仅覆盖实际执行路径；允许 atomic、不可变共享及正确所有权转移。 |
| [GO-04](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L16) | 接口应在消费端 | 改写 | 作为新增抽象的一般建议；不自动搬迁已有公共接口，也不为 mock 预造接口。 |
| [GO-05](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L19) | 重复错误包装 | 合并 | 并入 GO-01；需要有用上下文才 wrap，直接 return err 正常，不逐层重复包装。 |
| [GO-06](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L22) | append 未预分配 | 删除 | 已知规模和测得热点才预分配；不猜 expectedLen，不把普通 append 当缺陷。 |
| [GO-07](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L25) | 加号字符串拼接 | 删除 | 短字符串相加正常；大量累积有测量收益才考虑 Builder/Join。 |
| [GO-08](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L28) | 循环 defer | 交工具 | 用 Staticcheck SA5003/SA9001 检查其明确覆盖的模式；按实际释放时点判断，不强制抽 helper。 |
| [GO-09](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L31) | 函数职责混杂 | 保留 | 现有不为 80 行阈值拆分的方向合理；在相关变更中审查。 |
| [GO-10](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L34) | init 外部副作用 | 保留 | 保留启动网络/文件 I/O 的失败、超时、测试隔离审查；不禁止普通注册和纯初始化。 |
| [GO-11](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/golang/quality.md#L37) | 非入口使用 Background | 改写 | 判断是否丢失调用方取消与截止时间；独立生命周期可有根 context，不机械重写无关签名。 |

**TypeScript / React**

| 原 ID / 源文 | 原要求或问题摘要 | 建议 | 调整后的边界与执行方式 |
|---|---|---|---|
| [TS-01](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L7) | any 类型逃逸 | 交工具 | 用 typescript-eslint no-explicit-any 与项目选用的类型检查；吸收 TS-08，语法命中不等于运行时缺陷。 |
| [TS-02](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L10) | 未处理 Promise 拒绝 | 改写 | 明确等待、返回或终止边界处理的责任；return Promise 可正确传播，no-floating-promises 等仅覆盖部分模式。 |
| [TS-03](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L13) | 宽松相等 | 交工具 | 用 ESLint eqeqeq；当前规则允许 == null，配置须一致；先修 runtime 把 console 标为 TS-03 的漂移。 |
| [TS-04](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L16) | 组件职责混杂 | 保留 | 现有按维护与测试困难决定拆分的边界合理；取消别处 300 行即失败的冲突执行。 |
| [TS-05](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L19) | 重复 fetch/API 调用 | 合并 | 并入 TS-13；仅实际共享鉴权、错误、缓存或取消职责时抽取，不凭调用外形建 client。 |
| [TS-06](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L22) | Effect 依赖缺失或过宽 | 改写 | 先确认是否需要 Effect，再处理同步逻辑和依赖；用 exhaustive-deps，不把 memo 作为统一修复。 |
| [TS-07](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L25) | 渲染性能优化 | 保留 | 保留测量或明确成本及 Compiler 条件；吸收 TS-12 的按需 props 优化。 |
| [TS-08](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L29) | as any 与 ts-ignore | 合并 | 并入 TS-01；删推荐 as unknown as T 的修复，双重断言不增加运行时验证。 |
| [TS-09](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L32) | 超过四个参数 | 删除 | 参数数量不能决定接口质量；不强制 options object，遵循真实 API 与调用可读性。 |
| [TS-10](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L35) | 回调超过三层 | 删除 | 回调可能是同步遍历或事件逻辑；不机械改 async/await，真实异步责任归 TS-02。 |
| [TS-11](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L38) | null/undefined 处理 | 改写 | 按契约区分允许缺失与错误缺失；?.、??、提前 return 不应掩盖错误，类型检查不能替代外部边界验证。 |
| [TS-12](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L41) | props 不传完整对象 | 合并 | 并入 TS-07；根据稳定引用、memo/Compiler 和职责判断收益，不无条件拆 props API。 |
| [TS-13](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L44) | 同义组件/hook 重复 | 改写 | 先查相关实现再判断共享行为；删固定目录、组件数和 class 字符串阈值，不从外形认定重复职责。 |
| [TS-14](https://github.com/majiayu000/vibeguard/blob/49fac538bfc0cc7a4e857ca9e2ce87836a93ac8a/rules/claude-rules/typescript/quality.md#L57) | mock 与模块漂移 | 改写 | 采用有类型 mock 与覆盖测试文件的类型检查，再验行为；Partial 不能证明完整返回契约，限本次实际受影响调用者。 |

**专业工具的能力依据与限制**

这些是采用/适配决定，沿用项目已经选择的工具和版本；不会全局安装或强制开启整套 lint。运行工具可由宿主完成，必要时由现有 Rust CLI 薄调用，不另建通用执行平台。

| 范围 | 官方依据与具体边界 |
|---|---|
| Rust | [Clippy clone_on_copy](https://rust-lang.github.io/rust-clippy/master/index.html#clone_on_copy)、[map_entry](https://rust-lang.github.io/rust-clippy/master/index.html#map_entry)、[await_holding_lock](https://rust-lang.github.io/rust-clippy/master/index.html#await_holding_lock)、[unwrap_used](https://rust-lang.github.io/rust-clippy/master/index.html#unwrap_used) 各管明确模式，不能证明全局锁安全、所有权设计或所有 panic 合理。 |
| Python | [Ruff B006](https://docs.astral.sh/ruff/rules/mutable-argument-default/)、[E722](https://docs.astral.sh/ruff/rules/bare-except/)、[SIM115](https://docs.astral.sh/ruff/rules/open-file-with-context-handler/) 对应具体语法检查，不保证错误语义或资源所有权正确；[Python re](https://docs.python.org/3/library/re.html#re.compile) 说明近期正则存在缓存。 |
| Go | [errcheck](https://github.com/kisielk/errcheck) 可查丢弃 error；[race detector](https://go.dev/doc/articles/race_detector) 仅覆盖实际执行路径；[Staticcheck](https://staticcheck.dev/docs/checks/) 的 SA5003/SA9001 有具体适用范围；[context](https://pkg.go.dev/context) 的取消传递不能简化为入口名称判断。 |
| TypeScript | [no-explicit-any](https://typescript-eslint.io/rules/no-explicit-any/)、[ban-ts-comment](https://typescript-eslint.io/rules/ban-ts-comment/)、[no-floating-promises](https://typescript-eslint.io/rules/no-floating-promises/)、[eqeqeq](https://eslint.org/docs/latest/rules/eqeqeq)、[strictNullChecks](https://www.typescriptlang.org/tsconfig/strictNullChecks.html) 各有明确边界。return Promise 是有效传播，void Promise 则不自动处理 rejection。 |
| React / mock | [exhaustive-deps](https://react.dev/reference/eslint-plugin-react-hooks/lints/exhaustive-deps) 要求先考虑 Effect 必要性；[memo](https://react.dev/reference/react/memo) 是条件化优化；[Partial](https://www.typescriptlang.org/docs/handbook/utility-types.html#partialtype) 使字段可选；[Vitest mock](https://vitest.dev/api/vi.html#vi-mock) 与[类型检查](https://vitest.dev/guide/testing-types.html) 不能单独证明完整行为契约。 |
| 安全 | [RustSec](https://rustsec.org/) 与 [Go 漏洞工具](https://go.dev/doc/security/vuln/) 使用专业漏洞数据；[Claude MCP](https://code.claude.com/docs/en/mcp) 将 alwaysLoad 定义为预加载。依赖研究的指定 Python 任务与旧模型样本不能泛化为 Astra/Fable 固定缺陷率，见[原研究](https://arxiv.org/html/2605.06279v1)。 |

尚未测得：Astra/Fable 在真实任务中逐条规则的净收益、工具在目标用户项目中的精度及延迟。部分旧研究数字尚未独立复核，建议从执行政策撤下，不能视为现代模型事实。确定的源码/反例证据及后续对照设计列在配套方案中。
