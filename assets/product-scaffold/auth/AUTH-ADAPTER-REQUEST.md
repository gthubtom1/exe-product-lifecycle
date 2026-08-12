# 授权系统适配请求

## 产品

- `product_id`: `__PRODUCT_ID__`
- 核心文件: `__CORE_FILE__`
- 基线 SHA-256: `__BASELINE_SHA256__`
- 当前状态: `DISCOVERY_PENDING`
- Launcher 合同: `auth/LAUNCH-CONTRACT.yaml`

## 已发现事实

| 项目 | 事实 | 证据 | 置信度 |
|---|---|---|---|
| 授权入口 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 原授权界面 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 产品编号来源 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 设备信息 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 成功后启动条件 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 失败和离线行为 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 版本/更新访问 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 原授权界面处理 | `UNVERIFIED` | `auth/LAUNCH-CONTRACT.yaml` | `UNVERIFIED` |

详细事实放在同目录的 `AUTH-DISCOVERY.md`、`AUTH-EVIDENCE-INDEX.yaml` 和 `AUTH-OPEN-QUESTIONS.md`。本文件是交接入口，不复制完整日志。

## 请统一授权系统返回

请为本产品生成：

```text
AUTH-CONTRACT-RESULT.yaml
AUTH-ADAPTER-SPEC.md
AUTH-INTEGRATION-TESTS.md
```

合同至少要说明：

1. 请求身份和服务端如何确定 `product_id/profile_id`；
2. 卡密/账号、设备、到期、功能和版本授权字段；
3. 成功响应、错误码、撤销、过期、重复激活和设备变更；
4. Session、缓存、断网和最大离线时间；
5. Release 查询、包下载、频道和最低版本；
6. Launcher 与核心程序的启动协议、参数、工作目录和返回码；
7. 日志、审计、速率限制和数据留存；
8. 客户端不保存的管理员凭据、私钥和服务端管理能力。

请同时回填 `auth/LAUNCH-CONTRACT.yaml` 中的成功/失败信号、Session 交接、核心路径、原授权门状态和断网行为。目标用户流程可以是“打开 Launcher、输入卡密、授权成功后进入核心程序”，但必须用实际启动证据确认核心是否仍会显示原授权界面或执行原授权门。

## 限制

- 不把本产品的字段写成所有产品的通用字段；
- 不根据 `UNVERIFIED` 内容猜测合同；
- 不把真实凭据、私钥或完整客户卡密写入返回文件；
- 合同未通过联调测试前，状态保持 `AUTH_HANDOFF_READY`。
