# 可进化经验库

本 Skill 的“进化”是证据驱动的知识迭代，不是让 Agent 任意改写 `SKILL.md`。每个新 EXE 先产生自己的产品证据；只有跨产品可复用的分析、识别、迁移、验证和回滚方法，才进入共享经验审核。

## 数据边界

```text
产品目录（私有事实）                         Skill 仓库（可共享知识）
product-state/EVIDENCE-LEDGER.yaml          knowledge/candidates/
product-state/analysis/                     knowledge/verified/
product-state/learning/CANDIDATE-DRAFT.json knowledge/deprecated/
product-state/learning/*.private.json       knowledge/INDEX.json
                |                                   ^
                +---- 脱敏、补证据、审核、晋升 ------+
```

产品目录保留原始 EXE、文件名、产品名、Hash、路径、字符串、偏移、网址、授权字段、截图、日志、客户数据和完整追溯关系。共享仓库只保存泛化后的适用条件、识别信号、反向信号、操作步骤、验证、停止条件、局限和回滚方法。

公开 `source_evidence[].evidence_proof_id` 只是随机、不可反查的证明编号，不是原始 EXE 或报告 Hash，也不是公开可验证的密码学证明。原始 Hash 和本地路径只保存在产品自己的 `learning/EXPERIENCE-EXPORTS.json` 与 `*.private.json` 中，由审核者在产品环境内复核。

## 生命周期

1. **产品证据**：先把观察写进 `EVIDENCE-LEDGER.yaml`、`analysis/` 和验证报告。静态字符串不等于运行行为。
2. **本地草稿**：把可复用方法写入 `learning/CANDIDATE-DRAFT.json`。草稿必须删除产品名、路径、网址、账号、授权值、精确偏移和客户数据。
3. **候选导出**：运行 `capture-experience.ps1`。脚本生成产品本地追溯回执和共享 `candidate`，自动扫描失败时不导出。
4. **独立补证据**：在另一个真实产品或独立 Fixture 上复验，用 `add-experience-evidence.ps1` 补充证据。同一产品重复执行沿用同一个随机来源编号，不能冒充独立来源。
5. **审核**：用 `review-experience.ps1` 记录批准或拒绝。审核要确认适用范围、反向信号、停止条件、验证和回滚均可执行。
6. **晋升**：用 `promote-pattern.ps1`。必须满足“两种不同真实产品 + 正向 Fixture + 负面 Fixture”，并且审核记录绑定当前候选正文 Hash。候选内容或证据变化后，旧审核自动失效。
   涉及 UI、授权、更新、迁移或发布行为的模式，还必须至少有一条真实产品的实际执行或动态结果，只有静态字符串不能晋升。
7. **使用**：新任务只能通过 `find-verified-patterns.ps1` 检索 `verified`。不带 `-Tag` 时返回全部 `verified`，给了 `-Tag` 才按标签取交集过滤。命中后仍要在当前产品重新验证，不能把旧结论直接写成当前事实。
8. **废弃**：发现误判、上游框架变化或更好模式时运行 `deprecate-pattern.ps1`。`deprecated` 只保留审计，不再参与自动匹配。

## 命令流程

```powershell
# 1. 从当前产品证据建立候选
powershell -File scripts/capture-experience.ps1 `
  -ProductRoot <PRODUCT_ROOT> `
  -EvidencePath <PRODUCT_EVIDENCE_FILE>

# 2. 从另一个产品或 Fixture 补充独立证据
powershell -File scripts/add-experience-evidence.ps1 `
  -ProductRoot <ANOTHER_PRODUCT_OR_FIXTURE_ROOT> `
  -ExperienceId <EXP_ID> `
  -EvidencePath <EVIDENCE_FILE> `
  -SourceKind fixture `
  -EvidenceRole positive_fixture

# 3. 审核、晋升、全库校验
powershell -File scripts/review-experience.ps1 -ExperienceId <EXP_ID> -Decision approve -Reviewer <ROLE> -Notes <REVIEW_RESULT>
powershell -File scripts/promote-pattern.ps1 -ExperienceId <EXP_ID> -PromotedBy <ROLE>
powershell -File scripts/validate-knowledge.ps1
```

## 硬门禁

- `candidate` 和 `deprecated` 不参与自动匹配；
- 检索失败即关闭：索引中的 `verified` 条目缺字段、路径不是 `knowledge/verified/<experience_id>.json`、记录文件缺失、记录 Hash 与索引不符或记录本身不是 `verified` 时，`find-verified-patterns.ps1` 整次检索报错退出且不输出任何 `MATCH`，必须先用 `validate-knowledge.ps1` 修复索引；
- 共享知识禁止绝对路径、URL、邮箱、私网 IP、凭据、私钥、产品名和脚手架占位符；
- 二进制、安装包、截图、Dump、PCAP、反编译数据库和原始日志不进入 `knowledge/`；
- 同一产品的多个版本默认只算一个独立来源；Fixture 不能冒充第二个真实产品；
- 每条模式必须包含反向信号和停止条件，证据不足时回到普通分析；
- 模式命中不代表当前产品已验证；当前产品仍需写自己的证据和测试；
- 修改 Pattern、脚本、Schema、路由或 Skill 正文必须跑完整回归并审核；只有脱敏候选记录可以走较轻的知识审查流程；
- GitHub 只同步 Skill、Schema、Fixture 和脱敏经验。真实产品的 `product-state/` 留在本地或私有仓库。

## GitHub 与多电脑

独立仓库是共享 Skill 的真相源。换电脑时从仓库根目录安装；本机开发完成后用 `sync-local-skill.ps1` 同步到 Codex 安装目录。脚本只同步并校验文件，不自动提交、推送或覆盖其他仓库；Git 提交和 GitHub 推送由 Agent 在完整测试通过后执行并留下可回退 Commit。
