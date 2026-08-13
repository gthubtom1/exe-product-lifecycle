# EXE Product Lifecycle

给 AI 智能体使用的 **Windows 软件二次开发**工作流 Skill：既支持 EXE 黑盒二次发行，也支持"学开源思路、自己写"的源码复用二开（见下方"两条入口"）。

你交给它一个 EXE，它负责：建立这个产品的独立档案，记录品牌 / Logo / 界面 / 联系方式 / 功能定制，把入口收到 Launcher 下，把授权需求整理成交接资料给独立的授权平台，在上游发布新版时把你的定制原样迁移过去，并留下测试记录、发布包和可运行的回滚路径。

所有产品事实都写在磁盘上的 `product-state/` 里，**不依赖聊天历史**——换一台电脑、换一个智能体、隔三个月再回来，读档案就能接着干。

## 两条入口

同一套状态机与质量门（反捏造、真跑成品、授权绑定强度、真回滚），前半段分两条并行入口：

- **① EXE 二次发行（黑盒逆向）**：你手上有别家的 EXE，要在保留/定制它的基础上二次发行。逆向分析 → 定制 → 绑定授权 → 发布。**本文其余部分默认讲的就是这条。**
- **② 源码复用·二开（不整包复制、学思路自己写）**：你只有"一句需求"、没有也不会有 EXE，想参考同类开源项目的写法自己实现。用 `scripts/init-source-product.ps1` 建源码产品档案（无需 EXE），走 `需求录入 → 找参考 → 拆能力标注 → 自实现`，之后汇入与 EXE 二开**共享的下游**（定制/授权/构建/验证/发布/回滚）。

**不确定走哪条、或手上没有 EXE，先运行 `scripts/start-here.ps1`**：它是只读的，会按当前产品档案判断该走哪条入口并逐条打印下一步命令。两条入口的完整说明见 `SKILL.md` / `WORKFLOW.md` 的"两条入口"。

## 它解决什么问题

- **上游一发新版，定制就白做。** 定制被记录成带锚点的规则，而不是只存在于某个改好的 EXE 里；迁移时逐条重放，锚点找不到就报冲突，而不是悄悄退回原版外观。
- **"假装接好了授权"。** 启动器与主程序的绑定强度必须在 `auth/LAUNCH-CONTRACT.yaml` 里明确定级（A 强绑定 / B 中等 / C 仅外壳），并给出实测级别与绕过风险；只有外壳的产品无法被记成强绑定。
- **状态可以凭空声称。** 产品状态只能通过 `scripts/update-product-state.ps1` 改，它按 `assets/lifecycle-states.json` 校验证据、拒绝跳级，并把两份状态文件当一个事务写。
- **改之前不知道能不能改。** `scripts/detect-protections.ps1` 先静态判定加壳、熵值、反调试、自校验和签名，由判定结果决定维护策略——它从不运行目标程序。
- **经验只留在某个人的对话里。** 跨产品经验要经过脱敏、第二个真实产品复验、正负 Fixture 和绑定正文 Hash 的审核，才能进入共享知识库；自动检索只允许已审核的那一层。

## 安装

仓库地址：

```text
https://github.com/gthubtom1/exe-product-lifecycle
```

### 给智能体的一句话

把下面这段连同上面的地址一起发给任何支持 Skill 的智能体，它照做即可：

```text
把 https://github.com/gthubtom1/exe-product-lifecycle 安装成我这台机器的全局 Skill：
克隆到 <宿主的全局 skills 目录>/exe-product-lifecycle/，
确保 SKILL.md 直接位于该目录下、文件夹名就叫 exe-product-lifecycle，装完告诉我怎么开始用。
```

### 各宿主的安装位置

文件夹名必须**正好是** `exe-product-lifecycle`（与 `SKILL.md` 里的 `name` 一致），且 `SKILL.md` 必须**直接**躺在这个文件夹下，不能再套一层。

| 宿主 | 全局（所有项目可用） | 项目内 |
| --- | --- | --- |
| 厂商中立（推荐，任意 agent 通用） | `~/.agents/skills/exe-product-lifecycle/` | `.agents/skills/exe-product-lifecycle/` |
| Cursor | `~/.cursor/skills/exe-product-lifecycle/` | `.cursor/skills/exe-product-lifecycle/` |
| Claude Code / Claude Desktop | `~/.claude/skills/exe-product-lifecycle/` | `.claude/skills/exe-product-lifecycle/` |
| Codex | `~/.codex/skills/exe-product-lifecycle/` | `.codex/skills/exe-product-lifecycle/` |

Windows 上 `~` 就是 `%USERPROFILE%`，例如 `C:\Users\你的用户名\.cursor\skills\exe-product-lifecycle\`。

Cursor 出于兼容也会加载 `~/.claude/skills/` 和 `~/.codex/skills/`，所以三个宿主都在用的话，装一份到 `~/.codex/skills/` 通常就够了。

`.agents/skills/` 是厂商中立的官方约定位置，越来越多宿主（含 Cursor）原生识别；想让"把这个 URL 甩给任意 agent 就能自装"最稳妥，优先装到这里。

### 安装命令（PowerShell）

```powershell
# 换成你要装的宿主目录：.cursor / .claude / .codex
$dest = "$env:USERPROFILE\.codex\skills\exe-product-lifecycle"
git clone --depth 1 https://github.com/gthubtom1/exe-product-lifecycle.git $dest
```

以后更新：

```powershell
git -C "$env:USERPROFILE\.codex\skills\exe-product-lifecycle" pull
```

装完让智能体确认一下装对没有：`SKILL.md`、`WORKFLOW.md`、`scripts/start-here.ps1` 三个都能在那个目录里直接找到就对了。

## Windows 前提

- **只能在 Windows 上真正运行。** 二十多个脚本都是 PowerShell，用到注册表、`System32` 和 Windows 专用分析工具。在 macOS / Linux 上智能体能读懂流程，但脚本会失败。
- **Windows PowerShell 5.1（系统自带）或 PowerShell 7 都可以**，两条通道都在 CI 上跑。
- **Python 3 只有维护者需要**：仅 `scripts/validate-schema-links.py` 这一个校验脚本用到，日常使用这个 Skill 不需要 Python。
- **不需要管理员权限**，除非要启动本地临时授权 mock 服务器（`scripts/mock-authorization-server.ps1`）——Windows 的 http.sys 注册本地 URL 通常要管理员或 `netsh` 预留；被拒时脚本会明确区分"权限不足"和"端口被占用"，不会让你白换端口。
- **不联网装任何东西。** 分析工具由 `scripts/discover-tools.ps1` 在本机所有磁盘上发现；找不到会问你要位置，绝不静默安装。

## 零基础用户怎么用

你不需要懂 Git、PowerShell、产品编号、YAML 或测试命令。最少只要一个 EXE；安装包、DLL、截图和说明文件有就一起给，没有也能先开始。

1. 把 EXE 放进一个产品文件夹，其他材料有就一起放；
2. 用普通话告诉智能体你想保留、修改、更新还是发布什么；
3. 只在它问到会改变结果的问题时回答。

直接说这句就能开始：

```text
接入这个 EXE，保留现有 UI、品牌、联系方式和功能；以后收到新版时继续维护，并给我测试和回滚结果。
```

如果发现智能体没按流程走（比如没建档就开始分析、把"继续维护"当成只汇报进度），对它说：

```text
先运行 scripts/start-here.ps1，按它打印的顺序做。
```

那个脚本是只读的，会把"现在该执行哪条命令"逐条打印出来。

## 可进化经验

```text
新 EXE 产品证据
  -> 产品本地 learning/ 草稿和私有追溯
  -> 脱敏 candidate
  -> 第二个真实产品复验
  -> 正向 Fixture + 负向 Fixture
  -> 绑定当前正文 Hash 的审核
  -> verified 共享模式
  -> deprecated 废弃审计
```

后续智能体只能自动检索 `verified`。产品名、原始 EXE Hash、路径、地址、授权字段和客户数据不进入共享知识库。完整规则见 `references/knowledge-lifecycle.md`。

### 让经验不随这台机器一起消失

经验写在**正在运行的那一份**技能副本旁边，而智能体运行的是安装副本。所以安装方式决定了经验会不会丢：

- **用 `git clone` 安装并保留 `.git`**（上面的安装命令就是这么写的）。这样安装副本本身就是仓库，学到的东西一开始就在版本控制里。
- **更新代码用 `git pull`**，顺带把别人发布的经验一起取回来。
- **发布这台机器学到的经验**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/publish-knowledge.ps1
```

它会重建索引、跑公开内容门禁（带产品身份、哈希、地址或占位符的记录一律拒绝），然后**只提交 `knowledge/`** 并推送。加 `-DryRun` 可以先看它打算发什么。

如果安装副本是复制进去的、不是 clone，`publish-knowledge.ps1` 会直接告诉你没有地方可发，并给出改用 clone 的命令——因为那种副本一旦丢失，学到的东西哪里都没有备份。

## 顶层结构

| 路径 | 作用 |
| --- | --- |
| `SKILL.md` | Skill 入口与路由边界，智能体从这里开始 |
| `WORKFLOW.md` | 完整目录树、脚本参数、分模式流程 |
| `scripts/` | PowerShell 脚本：产品状态机、输入登记、保护探测、工具发现、知识生命周期、自检测试 |
| `assets/` | 状态定义 `lifecycle-states.json` 与产品脚手架 `product-scaffold/` |
| `references/` | 按需加载的工具链、授权交接、知识生命周期说明 |
| `knowledge/` | 公开、脱敏的可复用经验库（仅 JSON，带公开边界门禁） |
| `agents/openai.yaml` | Codex 触发配置 |

## 维护者验证

以下命令是维护这个 Skill 的人用的，不是普通用户的使用步骤：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-skill-layout.ps1
python scripts/validate-schema-links.py
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-evolution.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-product-scaffold.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-product-state-gates.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-detect-protections.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-mock-authorization.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-mock-authorization-http.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-tool-inventory-reuse.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-install-parity.ps1
```

`test-install-parity.ps1` 的最后一段会比对**这台机器上智能体实际加载的那份副本**。它报 `DRIFT:` 就说明源目录已经改好但装的还是旧版。

装的那份是 clone 就用 `git pull` 更新；是从别处复制过去的才用同步脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync-local-skill.ps1
```

同步脚本对着 clone 会直接拒绝（复制会把 clone 变成一直有改动的状态），并且**不会**删掉安装副本里独有的 `knowledge/` 记录——那些是这台机器学到、还没发布的东西，别处没有备份。

## 许可

MIT，见 [`LICENSE`](LICENSE)。本 Skill 衍生自作者自用的逆向工具集。
