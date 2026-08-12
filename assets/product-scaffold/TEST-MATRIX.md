# 产品测试矩阵

测试必须针对本产品实际入口和功能填写。`UNVERIFIED` 不是通过。

| 测试 ID | 场景 | 预期 | 实际证据 | 状态 |
|---|---|---|---|---|
| T-001 | 启动 Launcher | 界面出现且没有崩溃 | `UNVERIFIED` | `PENDING` |
| T-002 | 输入有效授权 | 只进入对应产品和版本 | `UNVERIFIED` | `PENDING` |
| T-003 | 授权失败/过期/撤销 | 错误明确且不进入核心流程 | `UNVERIFIED` | `PENDING` |
| T-004 | 断网行为 | 符合产品授权档案 | `UNVERIFIED` | `PENDING` |
| T-005 | 核心功能 | 原有核心流程保持可用 | `UNVERIFIED` | `PENDING` |
| T-006 | 自定义品牌和 Logo | 用户定制内容可见 | `UNVERIFIED` | `PENDING` |
| T-007 | 自定义联系方式 | 程序各已记录位置显示维护方信息 | `UNVERIFIED` | `PENDING` |
| T-008 | 自定义 UI/功能 | 每条定制规则都有对应结果 | `UNVERIFIED` | `PENDING` |
| T-009 | 更新检查 | 只显示匹配产品和授权可见版本 | `UNVERIFIED` | `PENDING` |
| T-010 | 安装/重启/数据 | 用户数据不串、不丢 | `UNVERIFIED` | `PENDING` |
| T-011 | 包和签名 | Hash、签名、组件清单一致 | `UNVERIFIED` | `PENDING` |
| T-012 | 回滚 | 失败后可启动上一版本 | `UNVERIFIED` | `PENDING` |
| T-013 | 原授权界面处理 | Launcher 成功后用户看见的授权流程符合 `LAUNCH-CONTRACT.yaml` | `UNVERIFIED` | `PENDING` |
| T-014 | 三方版本迁移 | `A_old -> A_new`、`B_old -> B_new` 和平台合同变化分别有记录 | `UNVERIFIED` | `PENDING` |
| T-015 | 定制锚点迁移 | Logo、联系方式、UI 和功能规则逐条重新定位，没有静默还原 | `UNVERIFIED` | `PENDING` |
| T-016 | 四类交付物 | 修改物、Patch/Diff、验证记录和可运行回滚互相引用 | `UNVERIFIED` | `PENDING` |
| T-017 | 产品隔离 | 产品/Profile/频道/版本数据不串到其他产品 | `UNVERIFIED` | `PENDING` |

## 测试证据约定

每次执行记录：命令或操作、输入文件及 Hash、实际输出、退出状态、截图/日志路径和测试时间。人工点击也要写清步骤和结果。
