# exe-product-lifecycle

一个面向 AI 智能体的 **Agent Skill**：维护并演进「Windows EXE 二次发行」产品的完整工作流——接入任意 EXE、记录并复用品牌/界面/联系方式/功能定制、用启动器（Launcher）控制入口、把授权需求交接给独立的授权平台、在上游更新时保住定制，并把脱敏后的多产品经验沉淀成可复用规则。

> 这是一个「技能（skill）」，不是可独立运行的程序。把它交给支持 Agent Skills 的 AI（Codex / Claude Code / Cursor 等），AI 读取根目录的 `SKILL.md` 后即按其中的流程工作。

## 运行前提

- **Windows** + **Windows PowerShell 5.1 或更高**。脚本使用注册表、`System32`、`.exe` 工具发现等 Windows 专属能力。
- 这是由 skill 的领域决定的：它处理的对象就是 Windows EXE。Linux / macOS 上的 AI 能读懂 `SKILL.md` 的流程，但**无法执行**其中的 `.ps1` 脚本。
- 无需额外安装依赖。分析类工具（反编译器等）由 `scripts/discover-tools.ps1` 在本机自动发现；缺失时会提示，绝不静默安装。

## 安装：把整个目录放进你所用 AI 的 skills 目录

本仓库的**根目录本身就是一个 skill**（根目录有 `SKILL.md`）。安装 = 把整个目录放到对应工具的 skills 目录下，目录名保持 `exe-product-lifecycle`。

**Codex**

```bash
git clone https://github.com/gthubtom1/exe-product-lifecycle "$HOME/.codex/skills/exe-product-lifecycle"
```

Windows 上即 `%USERPROFILE%\.codex\skills\exe-product-lifecycle`。仓库自带 `scripts/sync-local-skill.ps1`，可从任意本地副本同步到该位置并逐文件校验哈希。

**Claude Code**

```bash
git clone https://github.com/gthubtom1/exe-product-lifecycle "$HOME/.claude/skills/exe-product-lifecycle"
```

项目级可改放到 `<你的项目>/.claude/skills/exe-product-lifecycle`。

**Cursor**

放到 Cursor 的用户 skills 目录（通常是 `~/.cursor/skills/exe-product-lifecycle`），或按 Cursor 官方 Agent Skills 文档指定的位置。

> 各工具的 skills 目录约定可能调整，以其官方文档为准。唯一判定标准是：该目录下的 `exe-product-lifecycle/SKILL.md` 能被你的 AI 加载到。

## 给 AI 的入口

- **`SKILL.md`** 是唯一入口和路由说明，AI 从这里开始。
- 每次工作的第一步固定是运行 `scripts/start-here.ps1 -ProductRoot <产品文件夹> -UserRequest "<用户原话>"`：它只读，会逐条打印接下来该执行的命令，不要凭正文推断顺序。
- 完整目录树、脚本参数与分模式流程见 `WORKFLOW.md`。

## 装好后自检（可选）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-skill-layout.ps1
```

输出 `RESULT: passed` 表示目录结构、PowerShell 语法、JSON 语法和公开知识边界都正常。想跑更全的回归，见 `scripts/` 下的 `test-*.ps1`。

## 顶层结构

| 路径 | 作用 |
| --- | --- |
| `SKILL.md` | skill 入口与路由边界 |
| `WORKFLOW.md` | 完整目录树、脚本参数、分模式流程 |
| `scripts/` | PowerShell 脚本：产品状态机、输入登记、保护探测、工具发现、知识生命周期、自检测试 |
| `assets/` | 状态定义 `lifecycle-states.json` 与产品脚手架 `product-scaffold/` |
| `references/` | 按需加载的工具链、授权交接、知识生命周期说明 |
| `knowledge/` | 公开、脱敏的可复用经验库（仅 JSON，带公开边界门禁） |
| `agents/openai.yaml` | Codex 触发配置 |

## 许可

MIT，见 [`LICENSE`](LICENSE)。本 skill 衍生自 reverse-skill 工具集。
