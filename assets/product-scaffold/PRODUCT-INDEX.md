# 产品索引

- `product_id`: `__PRODUCT_ID__`
- 产品名称: `__PRODUCT_NAME__`
- 当前状态: `INIT`
- 当前模式: `bootstrap`
- 首次输入核心文件: `__CORE_FILE__`
- 保存的基线: `__BASELINE_ARTIFACT__`
- 基线 SHA-256: `__BASELINE_SHA256__`
- 首次说明文件: `__START_DOCUMENT__`
- 记录日期: `__DATE__`

## 读取顺序

1. 先读本文件，确认产品编号和当前状态；
2. 再读 `STATE.yaml`，选择第一个未完成阶段；
3. 再读 `PRODUCT-DOSSIER.md`、`CUSTOMIZATION-MANIFEST.yaml`、`auth/`、`release/` 和 `tooling/`；
4. 再读 `MAINTENANCE-MODE.yaml`、`OPERATION-MANIFEST.yaml`、`EVIDENCE-LEDGER.yaml`、`NETWORK-DATA-POLICY.yaml`、`HOST-INTEGRATION-MANIFEST.yaml` 和 `INPUT-SAFETY-POLICY.yaml`；
5. 最后按需读取 `analysis/`、`migrations/`、`reports/`、`rollback/`、`artifacts/INPUT-MANIFEST.yaml` 和测试证据。
6. `learning/` 只保存本产品到共享候选的私有追溯；共享模式由 Skill 的 `knowledge/verified/` 提供，命中后仍要在本产品复验。

## 当前结论

- 已确认事实: `UNVERIFIED`
- 未确认事项: `UNVERIFIED`
- 最新报告: `UNVERIFIED`
- 唯一下一步: 建立基线并分析输入文件

## 维护与交接索引

- 维护模式: `MAINTENANCE-MODE.yaml`
- 任意输入文件登记: `artifacts/INPUT-MANIFEST.yaml`
- 授权交接: `auth/`
- Launcher 启动合同: `auth/LAUNCH-CONTRACT.yaml`
- 平台发布请求: `release/RELEASE-PUBLISH-REQUEST.md`
- 四类交付物: `reports/CHANGES-AND-DIFF.md`、`reports/VERIFICATION-RECORD.md`、`rollback/ROLLBACK-RUNBOOK.md` 和实际构建物/差分路径
- 可复用经验草稿和导出回执: `learning/`

本文件只服务于 `__PRODUCT_ID__`。不要把其他产品的事实复制到这里。
