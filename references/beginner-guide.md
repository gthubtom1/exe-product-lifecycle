# 零基础使用说明

## 最短用法

你不需要懂技术，也不需要自己执行命令。最少把一个 EXE 放进产品文件夹；安装包、DLL、截图和说明文件有就一起放进去，没有也先开始。然后直接告诉 Agent 目标：

```text
接入这个 EXE，保留现有界面、品牌、联系方式和功能；以后有新版时继续维护。
```

| 你提供 | Agent 负责 |
|---|---|
| 一个 EXE；安装包、DLL、截图和说明文件有就一起提供 | 找到主程序和输入资料，建立产品档案 |
| “保留 UI/联系方式/功能/启动器”等要求 | 记录成可重复迁移的定制规则 |
| 新版文件和“继续更新” | 比较新旧版本、迁移定制、测试和保留回滚 |
| “准备测试版” | 生成候选包和验证报告，不擅自发布 |

不要自己填写产品 ID、选择工具、编辑 YAML、创建 `product-state/` 或运行 PowerShell。Agent 会自动完成这些工作；如果确实需要你的业务决定，只用中文问一个最小问题。

## 你第一次要做什么

把一个 EXE 放进产品文件夹即可，文件名不固定；说明文件有就一起放进去，例如：

```text
产品A/
└── TARGET.exe
# 可选：我的需求说明.md、安装包、DLL、截图
```

然后对 Agent 说：

```text
接入这个 EXE，按当前技能建立产品档案。先分析，再记录我需要保留的品牌、联系方式、UI、功能和授权接入点。
```

Agent 应该自动完成：保存原始文件指纹、建立产品档案、分析可见界面和启动流程、建立定制清单、准备授权系统交接资料，并把不确定的地方标成 `UNVERIFIED`。

首次分析结束时，Agent 会用一句人话给出三种结论之一：

- `可自动迁移`：已有内容有稳定的保留办法；
- `部分内容需要确认`：大部分能继续做，但有少数关键资料需要你确认；
- `需要重新实现`：当前 EXE 没有足够稳定的保留入口，相关内容要重新做。

## 第一次完成后文件夹会变成什么

```text
产品A/
├── 我的需求说明.md
├── TARGET.exe
├── incoming/                  # 后续收到的新参考版本放这里
└── product-state/            # 最重要：这个产品的长期记忆
    ├── PRODUCT-INDEX.md
    ├── STATE.yaml
    ├── PRODUCT-DOSSIER.md
    ├── CUSTOMIZATION-MANIFEST.yaml
    ├── MAINTENANCE-MODE.yaml
    ├── OPERATION-MANIFEST.yaml
    ├── EVIDENCE-LEDGER.yaml
    ├── NETWORK-DATA-POLICY.yaml
    ├── HOST-INTEGRATION-MANIFEST.yaml
    ├── INPUT-SAFETY-POLICY.yaml
    ├── UPSTREAM-VERSIONS.yaml
    ├── MIGRATION-RUNBOOK.md
    ├── TEST-MATRIX.md
    ├── artifacts/INPUT-MANIFEST.yaml
    ├── reports/VERIFICATION-RECORD.md
    ├── rollback/ROLLBACK-RUNBOOK.md
    ├── auth/
    │   └── LAUNCH-CONTRACT.yaml
    ├── tooling/              # 本机已发现工具和本产品工具选择
    ├── learning/             # 本产品证据提炼出的私有候选草稿和共享导出回执
    └── release/
        ├── COMPONENT-RELEASE-MANIFEST.yaml
        └── RELEASE-PUBLISH-REQUEST.md
```

不要把多个产品的 `product-state/` 合并。公共授权后台可以共享，但每个 EXE 的输入清单、Logo、联系方式、UI、功能、Launcher、授权适配、更新和回滚必须留在自己的产品目录。产品根目录里的 `docs/`、`AGENTS.md`、`RULES.md` 等宿主文件不会自动成为产品资料。

Skill 会从每次分析中积累方法，但不是把你的 EXE、产品名或授权资料上传到公共仓库。它先在 `product-state/learning/` 留下私有草稿和追溯，再导出不含产品身份的候选。候选经过第二个真实产品、正向测试样例、反向测试样例和审核后，才成为以后可自动参考的共享模式；每个新 EXE 仍会重新验证，不会直接照搬旧产品结论。

## 以后如何更新

把同一个产品的新参考 EXE 和任意说明文件放进 `incoming/`，然后说：

```text
按照这个产品已有档案，把 incoming 里的新版本迁移成当前产品的新版本。保留已有 Logo、品牌、联系方式、UI、自定义功能、启动器和授权流程，并给出测试和回滚记录。
```

Agent 应先读取旧档案，再比较：

```text
旧参考版本 -> 新参考版本
旧维护版本 -> 新维护版本
统一授权/更新合同是否变化
```

它不能只把新的 EXE 覆盖旧文件，因为这样会丢失已经做好的定制。每个定制项都要重新定位、迁移、测试；找不到对应位置时应停下来报告冲突。

## 授权系统怎么衔接

本技能不把某一个 EXE 的授权字段硬编码到所有产品里。它会从当前程序中整理出产品专属资料，例如：

- 程序从哪里进入登录或授权；
- 需要产品编号、卡密、账号、设备信息还是到期时间；
- 成功后怎样进入核心程序；
- 失败、断网、过期、换设备时怎样表现；
- 程序是否还有自己的本地授权文件或启动检查；
- 更新包是否也需要按产品、版本或授权等级限制。

这些内容进入 `product-state/auth/`，再交给你的“万能授权系统”对话。授权系统对话返回产品专属合同和适配说明，之后本技能按说明接入、构建和验证。`auth/LAUNCH-CONTRACT.yaml` 还要记录 Launcher 启动核心程序的真实路径、参数、工作目录、Session 交接、失败行为，以及原授权界面是否仍会出现。后台密钥和私钥不放进这里。

## 只有 EXE 时要注意什么

只有 EXE 时，AI 可以先做基线、资源、入口、Launcher、授权交接、配置覆盖和证据整理；内部 UI/功能是否能在上游更新后自动重建，要看产品的 `MAINTENANCE-MODE.yaml`。如果没有源码、稳定资源入口或版本绑定的 Patch/Diff，AI 会把该项标成 `REBUILD_REQUIRED` 或 `UNKNOWN`，不会假装任何 EXE 都能完整自动迁移。

## 看不懂报告时只看这三项

1. `product-state/STATE.yaml` 的 `status`：当前做到哪一步；
2. `product-state/PRODUCT-INDEX.md` 的“下一步”：下一次直接做什么；
3. `product-state/reports/` 最新报告：这次确认了什么、还有什么问题。

常见状态含义：

| 状态 | 直白含义 |
|---|---|
| `INIT` | 文件已登记，还在开始分析 |
| `ANALYZED` | 已建立程序和运行信息记录 |
| `CUSTOMIZATION_RECORDED` | 已记录需要保留的改动 |
| `AUTH_HANDOFF_READY` | 已整理好给授权系统的资料 |
| `BUILD_READY` | 已具备构建候选版本的资料 |
| `VERIFIED` | 候选版本已经按测试矩阵验证 |
| `MIGRATION_REQUIRED` | 新版本有差异，需要先处理冲突 |
| `ROLLBACK_READY` | 已保存可恢复的旧版本 |

## 什么时候需要你补充资料

只有缺少会改变结果的资料时才需要你补充，例如：正式产品名称、Logo 文件、联系方式、授权服务器的接口合同、测试账号、可接受的离线行为或验收标准。Agent 应先完成能完成的静态分析和档案整理，不要因为一个未知项就丢掉全部进度。
