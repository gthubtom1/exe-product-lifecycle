# 发布平台登记/推送请求

## 请求状态

- `status`: `NOT_REQUESTED`
- `product_id`: `__PRODUCT_ID__`
- `profile_id`: `UNVERIFIED`
- `release_id`: `UNVERIFIED`
- `channel`: `UNVERIFIED`

## 产品工作流已经完成的内容

- 构建物路径和 SHA-256: `UNVERIFIED`
- 组件清单: `release/COMPONENT-RELEASE-MANIFEST.yaml`
- Release manifest: `release/RELEASE-MANIFEST.yaml`
- 验证记录: `reports/VERIFICATION-RECORD.md`
- 回滚记录: `rollback/ROLLBACK-RUNBOOK.md`

## 需要统一授权/发布平台执行的动作

| 动作 | 结果 | 平台记录 |
|---|---|---|
| 登记产品/Profile/Release | `PENDING` | `UNVERIFIED` |
| 绑定完整包和组件 Hash | `PENDING` | `UNVERIFIED` |
| 设置用户/代理/角色可见范围 | `PENDING` | `UNVERIFIED` |
| 设置 stable/beta 等频道 | `PENDING` | `UNVERIFIED` |
| 配置推送、强制更新或撤回 | `PENDING` | `UNVERIFIED` |
| 记录启用和回滚关系 | `PENDING` | `UNVERIFIED` |

## 边界

本 Skill 负责构建、Hash、组件签名检查、Release manifest、测试和回滚资料；统一平台负责产品登记、授权可见性、用户/代理下载权限、频道推送、撤回和发布审计。未获得平台返回记录前，本请求保持 `NOT_REQUESTED` 或 `PENDING`，不把本地候选包写成已推送版本。

## 平台返回

- `platform_release_id`: `UNVERIFIED`
- `platform_artifact_id`: `UNVERIFIED`
- `visibility_result`: `UNVERIFIED`
- `channel_result`: `UNVERIFIED`
- `rollback_result`: `UNVERIFIED`
- `returned_contract`: `UNVERIFIED`
