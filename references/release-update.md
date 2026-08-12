# 发布、更新与回滚参考

本文件用于多个不同 EXE 的长期维护。它把“谁可以使用”“谁可以下载哪个版本”“如何安装和回滚”分开处理。具体安装器、数据目录、启动参数和更新端点必须写在每个产品的 `product-state/release/UPDATE-PROFILE.yaml`，不能依赖公共模板猜测。

## 发布对象

```text
Product
  稳定的 product_id 和产品隔离边界
Profile
  启动方式、平台、架构、数据目录和兼容范围
Release
  不可变的版本记录和发布状态
Package
  一个完整安装包、便携包或增量包
Artifact
  包内组件、Hash、签名和依赖
Channel
  stable、beta、canary 等接收范围
Entitlement
  某个用户/设备/角色可使用或下载什么
```

组件级完整性记录在 `release/COMPONENT-RELEASE-MANIFEST.yaml`：至少覆盖
Launcher、核心程序、DLL、sidecar、资源、安装器和实际运行时依赖，并分别
记录上游签名、维护版签名、证书链、公钥指纹、组件 Hash、依赖、权限和回滚
路径。`RELEASE-MANIFEST.yaml` 不能用一个包 Hash 代替组件关系。

授权系统可以返回“该用户能看哪个 Release”，但客户端仍要验证包的签名、Hash、产品/Profile、版本关系和安装条件。客户端不保存后台管理密钥。

## 默认采用完整包

先发布完整包，再考虑增量更新。增量包只有在以下条件都具备时才启用：

- 起始版本、目标版本、架构和文件清单明确；
- 差分应用过程可重复、幂等且不会路径穿越或覆盖未知文件；
- 应用前后都验证组件 Hash 和签名；
- 失败时能保留并启动上一条可用版本；
- 已经有同版本、跨版本、断电、磁盘不足和中途失败测试。

## 更新流程

```text
查询已授权的 Release 元数据
    ↓
验证 HTTPS/证书或公钥约束、签名、产品/Profile、版本和撤回状态
    ↓
下载到临时目录，不覆盖当前运行版本
    ↓
再次验证包 Hash、组件清单、签名、架构和依赖
    ↓
停止或切换 Launcher/核心程序，执行数据迁移（如有）
    ↓
安装新版本并启动健康检查
    ↓
成功：记录 active；失败：恢复上一条 active 并保留证据
```

更新元数据至少应包含：`product_id`、`profile_id`、`target`、`arch`、`channel`、`version`、`minimum_supported_version`、`release_id`、包 URL、大小、Hash、签名、公钥指纹、创建/过期时间、撤回状态和回滚关系。

## 防止误更新

必须拒绝：

- 产品或 Profile 不匹配；
- 架构不匹配；
- 低于当前版本的未授权降级；
- 元数据签名、包 Hash 或组件 Hash 不一致；
- 证书/公钥约束不满足；
- Release 已撤回、过期或不在授权范围；
- 包内路径逃逸、重复覆盖、大小超过限制或依赖不满足；
- 安装器需要未记录的管理员权限或外部宿主修改。

更新失败时状态应能回到：

```text
active(old) -> update_failed(new) -> active(old)
```

失败包、日志、验证命令和原因保留在产品的 `releases/` 或 `rollback/`，不要删除以制造成功记录。

## 版本迁移的三方比较

收到同一产品的新参考版本时，必须分别记录：

```text
A_old -> A_new: 原参考产品发生了什么变化
B_old -> B_new: 维护版需要怎样跟进
授权/发布合同: 服务端字段、版本访问或更新规则是否变化
```

已有的 Logo、品牌、联系方式、UI、功能开关、Launcher、Adapter 和测试规则来自 `CUSTOMIZATION-MANIFEST.yaml`，不是来自旧 EXE 的“记忆”。每一条规则都要重新定位并验证。找不到锚点时写入迁移报告并停在 `MIGRATION_REQUIRED`。

## 发布状态

推荐状态：

```text
DRAFT -> VERIFIED -> INACTIVE -> CANARY -> ACTIVE
ACTIVE -> SUPERSEDED
ACTIVE -> ROLLED_BACK
```

没有灰度能力时，至少保留 `INACTIVE` 验证记录，再由用户明确要求启用。测试版和正式版使用不同 Channel；不要用把 beta 包改名的方式伪装正式发布。

## 参考实现方向

以下项目用于理解行业常见模型，不是本 Skill 的强制依赖：

- [The Update Framework overview](https://theupdateframework.io/docs/overview/): 签名元数据、Hash、版本、过期时间和防回滚思路；
- [Velopack](https://github.com/velopack/velopack): Windows 完整包、增量包、便携包和回滚方向；
- [Squirrel.Windows](https://github.com/Squirrel/Squirrel.Windows): Windows 安装、更新频道和客户端更新 API；
- [NetSparkle](https://github.com/NetSparkleUpdater/NetSparkle): Appcast、签名和可定制更新界面；
- [Keygen Releases API](https://keygen.sh/docs/api/releases/): Release、Package、Artifact、Channel、Entitlement 和发布状态模型。

实际选择依赖前先检查许可证、维护状态、平台兼容性、签名方案、迁移能力和退出方案；不要把外部项目整包复制进每个产品。

## 发布验收

发布前至少执行并记录：

1. 包、组件和签名验证命令，以及字面输出和退出状态；
2. 安装、首次启动、重复启动、重启和卸载/回滚；
3. 正常授权、过期、撤销、断网、设备变化和版本不匹配；
4. 自定义 Logo、品牌、联系方式、UI 和功能仍存在；
5. 旧用户数据不会被错误删除或串到其他产品；
6. 更新中断、磁盘不足、包损坏和启动失败可恢复；
7. `RELEASE-MANIFEST.yaml`、测试证据和 rollback 记录互相引用且 Hash 一致。

## 平台推包边界

本地产品工作流输出 `release/RELEASE-PUBLISH-REQUEST.md`，把已验证的
Product/Profile/Release/Artifact/Channel、包路径、组件清单、授权可见范围和
回滚关系交给统一授权/发布平台。平台负责登记、用户/代理可见性、频道推送、
强制更新、撤回和审计；本地 workflow 不把“生成了包”写成“已经推送”。平台
返回记录后再回填本产品的 Release 状态。

每次修改或发布还必须有四类相互引用的资料：

1. 修改后构建物或修改文件；
2. Patch/Diff 或可重复的资源覆盖/二进制补丁记录；
3. 含基线与修改后命令、输入、字面输出和退出状态的验证记录；
4. 指向已验证旧版本并可执行的回滚手册。
