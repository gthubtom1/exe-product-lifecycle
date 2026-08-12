# 版本迁移手册

## 目标

把同一产品的新上游版本迁移成 `__PRODUCT_ID__` 的维护版，同时保留已记录的品牌、联系方式、UI、功能、启动流程、授权适配、更新策略和测试。

## 输入

- 旧上游版本: `UPSTREAM-VERSIONS.yaml`
- 当前维护版本: `UNVERIFIED`
- 新上游文件: `incoming/`
- 当前定制规则: `CUSTOMIZATION-MANIFEST.yaml`
- 维护方式: `MAINTENANCE-MODE.yaml`
- 授权合同/适配: `auth/`
- Launcher 启动合同: `auth/LAUNCH-CONTRACT.yaml`
- 更新配置: `release/UPDATE-PROFILE.yaml`
- 运营模块: `OPERATION-MANIFEST.yaml`
- 网络/数据和宿主边界: `NETWORK-DATA-POLICY.yaml`、`HOST-INTEGRATION-MANIFEST.yaml`
- 工具快照: `tooling/TOOL-INVENTORY.md`

## 三方比较

```text
A_old -> A_new: 参考产品变化
B_old -> B_new: 维护版需要变化
平台合同: 授权、Release、更新和数据隔离是否变化
```

## 每次迁移步骤

1. 保存新输入文件并计算 SHA-256；
2. 确认它属于同一 `product_id/profile_id/target/arch`；
3. 比较旧上游、新上游和当前维护版；
4. 先读取 `MAINTENANCE-MODE.yaml`，按组件判断是源码重建、资源覆盖、二进制差分、Launcher 包装还是需要重新建立构建链；
5. 逐条读取 `CUSTOMIZATION-MANIFEST.yaml`，重新定位品牌、UI、联系方式、功能和运行时规则；
6. 更新产品专属 Adapter、授权合同引用和更新配置；
7. 对找不到稳定锚点的规则写迁移冲突，不自动恢复上游内容；
8. 构建候选版本并运行 `TEST-MATRIX.md`；
9. 生成修改后构建物、Patch/Diff、验证记录和可运行回滚记录；
10. 生成迁移报告、Release manifest、组件发布清单和平台发布请求；
11. 通过验证后才把状态推进到 `VERIFIED` 或 `RELEASED`。

## 只有 EXE 的迁移规则

只有 EXE 时，默认只能把它当作只读上游基线。可以复用的部分必须有产品证据：

| 路径 | 可以承担的内容 | 更新时要求 |
|---|---|---|
| `SOURCE_AVAILABLE` | 自有源码、资源、构建脚本和 Adapter | 重建 B 并回归测试 |
| `RESOURCE_OVERLAY` | 图标、版本资源、可替换文件和配置 | 重新应用覆盖并验证 |
| `BINARY_PATCH_RECORD` | 有版本边界、输入 Hash、偏移/锚点和逆向验证的差分 | 只对匹配基线应用，否则进入冲突 |
| `WRAPPER_LAUNCHER` | Launcher、授权、更新、配置和入口控制 | 验证核心路径、参数、工作目录和原授权门 |
| `REBUILD_REQUIRED` | 内部 UI/功能改动但没有可复现构建路径 | 停在 `MIGRATION_REQUIRED`，先补构建依据 |
| `UNKNOWN` | 证据不足 | 不猜测、不覆盖、不宣称已同步 |

## 停止条件

- 新文件身份或版本关系不清；
- 定制规则无法定位；
- 原授权/新授权的成功和失败含义不清；
- 安装器、数据迁移、更新签名或回滚行为不清；
- 关键功能没有可执行测试；
- 只能靠猜测修改或覆盖当前维护版。

每次操作的四类交付物必须互相引用：

1. 修改后构建物或修改文件；
2. Patch/Diff 或可重复的覆盖/补丁记录；
3. 含基线命令、修改后命令、输入、字面输出和退出状态的验证记录；
4. 指向已验证旧版本并可执行的回滚手册。

## 本产品的迁移记录

| 迁移 ID | A_old | A_new | B_old | B_new | 结果 | 报告 |
|---|---|---|---|---|---|---|
| MIG-000 | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` | `UNVERIFIED` | `PENDING` | `UNVERIFIED` |
