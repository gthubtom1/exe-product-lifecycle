# 产品档案

## 身份

- `product_id`: `__PRODUCT_ID__`
- 产品名称: `__PRODUCT_NAME__`
- 首次说明文件: `__START_DOCUMENT__`
- 核心输入文件: `__CORE_FILE__`
- 保存位置: `__BASELINE_ARTIFACT__`
- SHA-256: `__BASELINE_SHA256__`
- 记录日期: `__DATE__`
- 任意输入登记: `artifacts/INPUT-MANIFEST.yaml`
- 维护模式: `MAINTENANCE-MODE.yaml`

## 运行环境

| 项目 | 结果 | 证据 |
|---|---|---|
| 文件格式 | `UNVERIFIED` | `UNVERIFIED` |
| 架构 | `UNVERIFIED` | `UNVERIFIED` |
| 运行时/框架 | `UNVERIFIED` | `UNVERIFIED` |
| 启动文件和参数 | `UNVERIFIED` | `UNVERIFIED` |
| 子进程/DLL/依赖 | `UNVERIFIED` | `UNVERIFIED` |
| 数据目录和配置 | `UNVERIFIED` | `UNVERIFIED` |
| 安装/便携方式 | `UNVERIFIED` | `UNVERIFIED` |
| 源码/构建是否可用 | `UNVERIFIED` | `MAINTENANCE-MODE.yaml` |
| 资源覆盖/二进制差分/Launcher 路径 | `UNVERIFIED` | `MAINTENANCE-MODE.yaml` |

## 用户可见界面

| 区域 | 观察结果 | 要保留或修改的内容 | 验证方式 |
|---|---|---|---|
| 启动界面 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 主窗口 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 登录/授权入口 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 功能页面 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 联系方式/公告 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |
| 错误和更新提示 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |

联系方式可能出现在主窗口、功能页、公告、错误提示、配置或远程资源中；不能只检查授权页。每个位置都要登记为定制规则并有验证证据。

## 能力清单

每项能力都要链接到分析证据、定制规则和测试。未知能力不得写成已存在。

| 能力 ID | 能力 | 状态 | 证据 | 定制规则 | 测试 |
|---|---|---|---|---|---|
| CAP-001 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` |

## 版本和迁移摘要

- 上游基线: `__BASELINE_SHA256__`
- 当前维护版: `UNVERIFIED`
- 最近一次迁移: `UNVERIFIED`
- 已知迁移冲突: `UNVERIFIED`
- 详细记录: `UPSTREAM-VERSIONS.yaml`、`MIGRATION-RUNBOOK.md`

## 授权、启动和平台接入

- 原授权表面: `auth/AUTH-DISCOVERY.md`、`auth/LAUNCH-CONTRACT.yaml`
- 统一授权合同: `auth/AUTH-CONTRACT-RESULT.yaml`（如已返回）
- 运营模块选择: `OPERATION-MANIFEST.yaml`
- 网络与数据边界: `NETWORK-DATA-POLICY.yaml`
- 宿主集成边界: `HOST-INTEGRATION-MANIFEST.yaml`
- 发布平台登记: `release/RELEASE-PUBLISH-REQUEST.md`

## 只有 EXE 时的事实边界

只有参考 EXE 不等于存在可复现的完整构建链。内部功能、界面或协议改动必须绑定到 `SOURCE_AVAILABLE`、`RESOURCE_OVERLAY`、`BINARY_PATCH_RECORD`、`WRAPPER_LAUNCHER` 或 `REBUILD_REQUIRED` 中的一种已验证路径；未知时保持 `UNKNOWN`，后续更新不能假定可以自动重建。

## 事实边界

本档案只记录 `__PRODUCT_ID__` 的事实。静态字符串、推测和运行时成功证据必须分开写；没有证据的字段保持 `UNVERIFIED`。
