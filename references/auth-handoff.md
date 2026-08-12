# 产品授权交接参考

本文件说明如何把某个 EXE 的授权观察结果交给独立的统一授权系统。它不假定所有 EXE 的授权页面、卡密格式、设备绑定或离线策略相同，也不把某个产品的字段写进通用后台。

## 两个系统的分工

```text
产品生命周期 Skill
  识别程序入口、原有授权表面、启动条件、失败行为和版本影响
  维护 product-state/auth/ 与产品专属 Adapter
  构建、启动、更新和验证客户端

统一授权系统
  用户、角色、产品、授权、卡密、设备、到期、撤销、审计和 Release 访问权限
  返回版本化授权合同和服务端规则
```

Launcher 可以负责用户输入、调用授权合同和启动核心程序；核心程序是否还保留自己的授权检查，必须记录为产品事实并单独处理。不能因为有 Launcher 就假定核心程序的原授权路径已经消失。

把启动细节单独写入产品的 `auth/LAUNCH-CONTRACT.yaml`。至少记录 Launcher 和核心程序的实际路径、参数、工作目录、环境变量、子进程、Session/授权结果交接、成功/失败信号、退出码、断网行为，以及原授权界面是保留、替换、移到 Launcher 后面、通过产品适配处理，还是仍未确认。用户期望的“打开 Launcher、输入卡密、成功后进入程序”是目标流程，不是对核心内部状态的证明。

## 授权发现清单

把每一项写成“事实、证据、未知”三者之一：

| 区域 | 需要观察的内容 |
|---|---|
| 用户入口 | 登录窗口、卡密输入、账号注册、激活按钮、错误提示、退出条件 |
| 本地状态 | 配置文件、许可证文件、注册表、缓存、设备标识、时间戳、加密存储 |
| 网络交互 | 域名、协议、请求方法、字段名称、响应状态、重试、超时、代理和 TLS 行为 |
| 身份 | 产品编号、客户端编号、安装编号、设备指纹、用户、代理或角色信息 |
| 授权内容 | 功能、版本、频道、到期时间、并发数、设备数、试用、撤销和冻结 |
| 启动条件 | 授权成功后启动哪个文件、参数、工作目录、环境变量、子进程和返回码 |
| 失败路径 | 断网、过期、设备变化、重复激活、服务异常、时间错误和升级失败 |
| 更新关系 | 谁能看到新版本、谁能下载包、最低客户端版本、强制升级和回滚 |

“搜索到 URL/字符串”只是静态迹象。只有受控请求、日志、程序状态或可复现的失败/成功行为才能把网络或授权语义写成已确认事实。

## `AUTH-PROFILE.yaml` 填写规则

产品档案至少要有以下字段；暂时不知道的值写 `UNVERIFIED`，不要填猜测：

```yaml
schema_version: 1
product_id: "SAMPLE-PRODUCT"
integration_status: "DISCOVERY_PENDING"
client_entrypoint: "UNVERIFIED"
core_entrypoint: "UNVERIFIED"
original_auth_surface: "UNVERIFIED"
desired_user_flow: "launcher -> authorization contract -> core"
launch_contract: "product-state/auth/LAUNCH-CONTRACT.yaml"
user_visible_original_auth: "UNVERIFIED"
core_gate_after_launcher: "UNVERIFIED"
identity:
  app_id: "UNVERIFIED"
  installation_id: "UNVERIFIED"
  device_data: "UNVERIFIED"
entitlement:
  license_key: "UNVERIFIED"
  product_mapping: "UNVERIFIED"
  expiry: "UNVERIFIED"
  feature_claims: "UNVERIFIED"
server_contract:
  base_url: "UNVERIFIED"
  verify_operation: "UNVERIFIED"
  request_fields: []
  response_fields: []
  error_codes: []
session:
  token_kind: "UNVERIFIED"
  cache: "UNVERIFIED"
offline:
  allowed: "UNVERIFIED"
  maximum_age: "UNVERIFIED"
release_access:
  version_query: "UNVERIFIED"
  package_download: "UNVERIFIED"
evidence_refs: []
open_questions: []
```

`product_id` 是业务隔离键；`app_id`、`installation_id` 和 `device_data` 不要混为一个字段。普通客户端提交的产品编号不能单独成为服务端信任根，服务端应根据受信合同和注册关系解析产品。

## 交给授权系统 Agent 的文件

产品分析完成后，把以下文件交给另一个对话：

```text
product-state/auth/
├── AUTH-DISCOVERY.md
├── AUTH-PROFILE.yaml
├── AUTH-EVIDENCE-INDEX.yaml
├── AUTH-OPEN-QUESTIONS.md
├── AUTH-ADAPTER-REQUEST.md
└── LAUNCH-CONTRACT.yaml
```

建议提示语：

```text
请读取这个产品目录的 product-state/auth/，为 product_id 对应的 EXE 生成统一授权系统合同和产品专属适配说明。只使用文件中有证据的事实；未知项保留为 UNVERIFIED；不要把本产品字段写成所有产品的默认字段；返回 AUTH-CONTRACT-RESULT.yaml、AUTH-ADAPTER-SPEC.md 和联调测试清单。
```

授权系统 Agent 返回：

```text
product-state/auth/AUTH-CONTRACT-RESULT.yaml
product-state/auth/AUTH-ADAPTER-SPEC.md
product-state/auth/AUTH-INTEGRATION-TESTS.md
```

生命周期 Skill 读取返回文件后，才决定 Launcher、核心程序和 Adapter 的具体接线。合同未定、错误码未知、成功后启动条件不明或离线行为没有验收标准时，状态保持 `AUTH_HANDOFF_READY` 或 `MIGRATION_REQUIRED`，不要伪装成已接入。

授权平台如果负责推送新包，平台联调还要读取产品的 `release/RELEASE-PUBLISH-REQUEST.md`。生命周期 Skill 只负责本地构建物、组件 Hash/签名、测试和回滚；平台返回产品/Profile/Release/Artifact/Channel 的登记结果后，才更新本地发布状态。

## 原授权界面的记录方式

产品档案可以记录以下事实：

```text
original_auth_surface: observed / not_observed / unverified
user_visible_disposition: retain / replace / move_behind_launcher / unverified
core_gate_after_launcher: present / absent / unverified
verification: exact test command or controlled manual evidence
```

如果核心程序仍然强制检查原授权，先记录并验证其启动边界，再选择自有源码改造、产品专属适配或重新设计启动流程。不能仅凭隐藏一个窗口就宣称原授权已经被替换，也不能删除失败证据。

## 交接验收

授权合同和 Adapter 至少要能验证：

1. 正常激活后只进入对应产品和对应版本；
2. 错误卡密、过期、撤销、设备变化和重复激活有明确结果；
3. 断网行为符合产品档案，不使用未记录的永久本地放行；
4. 产品 A 的授权、公告、版本和设备记录不会串到产品 B；
5. Launcher、核心程序、更新器和后台使用同一个版本化 `product_id/profile_id/channel` 关系；
6. 日志不记录完整卡密、管理员凭据、私钥或不必要的设备材料；
7. 授权失败时可以回到上一条可用发布版本。
