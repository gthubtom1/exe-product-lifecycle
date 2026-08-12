# Windows EXE 工具链与自动发现

这份参考资料定义“做什么时找什么工具”，不把任何一台机器的绝对路径写死。每个产品接入时运行 `scripts/discover-tools.ps1`，把当前机器真实可用的路径保存到产品自己的 `product-state/tooling/`。

## 选择顺序

1. 先运行 `discover-tools.ps1 -ReuseInventory`，再看它生成的 `product-state/tooling/TOOL-INVENTORY.md` 和 `TOOL-PLAN.yaml`。不要因为清单文件已经存在就直接采信：那份快照没有做过存在性校验，工具卸载或换位置后它仍然显示可用；
2. 若本机存在 `skills/tool-index.json`，把它当作额外的路径证据；
3. 复用命中时脚本会秒回并复核每条记录的路径；快照过期、工具消失或搜索范围变化时自动全量重新发现。需要时增加 `-AdditionalSearchRoot <工具目录>`（这会自动触发重新发现），不要要求用户重复报工具名；
4. 只有在工具已经被发现并记录真实路径后才调用它；
5. 工具不存在时换同一角色的已发现工具，不要重新让用户描述工具名，也不要猜安装路径；
6. 需要下载或安装时，先把工具名、来源、版本、许可证和退出方案写进报告，并按宿主 Agent 的安装规则处理。

## 搜索范围

发现脚本不写死任何盘符。它会自动覆盖：

- 环境变量给出的 `Program Files` / `Program Files (x86)`（不假定在 C 盘）；
- **每一个本地固定磁盘**上按常见目录名探测，如 `Program`、`Tools`、`bin`、`opt`、`开发`、`软件`、`工具`——所以工具装在 D 盘或 E 盘同样能找到；
- 用户目录下的 `Tools`、`bin`、`scoop\shims`、`.cargo\bin`、`.local\bin`、`go\bin`、`.dotnet\tools`；
- `AppData\Local\Programs` 和 WinGet 的 `Links` / `Packages`；
- 当前 `PATH` 里的每个目录；
- 注册表里已安装程序的安装目录和 App Paths（跟着用户实际安装位置走，重装换盘也有效）；
- 用户自己登记的额外目录（见下）。

## 找不到某个角色时的固定处理顺序

不要在第一次 `not-found` 就告诉用户「没有这个工具」。按顺序走完：

1. 加 `-DeepScan` 重跑一次：整盘遍历，比常规发现慢几分钟，但能找到装在非常规位置的工具；
2. 仍然找不到，再换同一角色的备用工具（见上表的「备用角色」列）；
3. 备用也没有，才用中文告诉用户缺什么、这会影响哪一步分析，并问工具是不是装在别处；
4. 用户给出位置后，**同时做两件事**：本次用 `-AdditionalSearchRoot <目录>` 立即生效，并把该目录写进下面的长期清单，避免下次再问一遍。

## 让新装的工具下次就能被发现

工具清单是快照，不是永久事实。三重保障：

- 快照超过 `-MaxInventoryAgeHours`（默认 24 小时）自动失效重扫，所以今天装的工具明天一定会被看见；
- 搜索范围、深度、工具目录清单或工具名录任一变化，旧快照立即失效；
- 想立刻生效就不带 `-ReuseInventory` 跑一次，或直接 `-DeepScan`。

长期额外目录写在这两个文件里，一行一个目录，`#` 开头是注释：

```text
%CODEX_HOME%\exe-lifecycle-tool-roots.txt        # 本机所有产品共用；默认 %USERPROFILE%\.codex\
<产品目录>\product-state\tooling\EXTRA-TOOL-ROOTS.txt   # 只对这个产品生效
```

它们**故意放在 Skill 目录之外**：同步或重装 Skill 会删掉安装目录里不属于源码的文件，写在 Skill 里的清单会被抹掉。这两个文件的内容变化也会让旧快照失效，所以加完目录下一次发现就会带上它。

## 按任务选择工具

| 工具角色 | 优先检查的命令或文件名 | 用途 | 备用角色 |
|---|---|---|---|
| PE/EXE 初筛 | `die`, `diec`, `Detect-It-Easy`, `strings`, `7z`, `tar`, PowerShell `Get-FileHash` | 判断格式、架构、编译器、压缩/打包迹象、资源和指纹 | `dumpbin`, `llvm-readobj`, `objdump` |
| PE 结构和导入 | `dumpbin`, `llvm-readobj`, `objdump`, `rabin2` | 节、导入导出、CLR、依赖和版本信息 | `diec`、Ghidra/IDA 的导入视图 |
| 原生静态分析 | `ida`, `ida64`, `idat64`, `ghidraRun`, `analyzeHeadless`, `r2`, `rizin`, `Cutter` | 函数、字符串交叉引用、资源引用、调用关系和二进制差异 | Ghidra、radare2、Python 解析脚本 |
| .NET/托管分析 | `dnSpyEx`, `dnSpy`, `ILSpy`, `ilspycmd`, `ildasm`, `de4dot`, `dotnet` | 程序集、类型、资源、启动入口和托管配置 | `diec`、PE 初筛、源码/构建资料 |
| 资源和品牌 | `ResourceHacker`, `rcedit`, `7z`, `7zz` | 图标、版本资源、对话框、嵌入文件和安装包 | 对应框架的源码资源工具 |
| 动态调试 | `x64dbg`, `x32dbg`, `WinDbgX`, `cdb` | 启动、异常、加载顺序、关键调用和失败路径 | Procmon、应用自带日志 |
| 系统行为 | `Procmon`, `procexp`, API Monitor 类工具 | 文件、注册表、进程、DLL、权限和子进程行为 | PowerShell 事件/日志、Windows 事件查看器 |
| 运行时插桩 | `frida`, `frida-ps` | 受控运行时观察和参数确认 | 调试器、应用日志、网络抓包 |
| 网络观察 | `Wireshark`, `tshark`, `mitmproxy`, `Fiddler`, 代理工具 | 端点、协议、请求状态、更新和授权交互的证据 | 产品自有日志、受控代理 |
| 构建 | `MSBuild`, `dotnet`, `cargo`, `go`, `node`, `npm` | 编译 Launcher、Adapter、资源和测试工具 | 项目已有构建脚本 |
| 签名与发布 | `signtool`, `7z`, PowerShell 哈希 | 签名、校验、打包、组件清单和回滚包 | 平台已有发布工具 |
| 自动化 | `python`, `py`, `uv`, PowerShell, `git` | 解析、差分、报告、测试和可恢复变更 | Node.js 脚本 |

## EXE 类型分流

| 发现结果 | 默认分析链 |
|---|---|
| .NET CLR 头存在 | DIE/PE 初筛 → dnSpyEx/ILSpy → 资源和启动流程 → 需要时动态验证 |
| 原生 PE | DIE/PE 初筛 → IDA/Ghidra/radare2 → 资源、导入、启动流程 → x64dbg/WinDbg/Procmon |
| Electron/Node | 资源/包结构 → `asar` 或程序自带资源 → JavaScript 静态分析 → 启动和更新验证 |
| Qt/WinForms/WPF | 资源和程序集识别 → 对应静态工具 → UI 资源、配置和运行时行为 |
| 安装器或便携包 | 先保存原包 → 7-Zip/格式识别 → 安装路径、子进程、卸载和数据迁移测试 |
| 识别结果不明确 | 只做初筛和证据记录，状态保持 `UNVERIFIED`，不要据此选择深度工具 |

工具发现结果只说明“工具路径存在”，不说明某个工具适合修改当前产品。工具实际承担的角色、输入、输出和验证命令要写进本产品的 `TOOL-PLAN.yaml`；分析、资源替换、二进制差分、Launcher 构建和签名发布也要分别登记。

## 当前主机发现结果的保存方式

工具路径和版本属于主机事实，不应进入通用 Skill。运行发现脚本后，产品目录会有：

```text
product-state/tooling/
├── TOOL-INVENTORY.md       # 人能读懂的当前机器快照
├── TOOL-INVENTORY.json     # Agent 便于读取的结构化快照
└── TOOL-PLAN.yaml          # 本产品实际选用的工具角色和证据要求
```

`TOOL-PLAN.yaml` 必须记录实际调用的 `tool_id`、绝对路径、版本、用途、输入、输出和验证命令。若路径改变，重新生成快照并更新计划；不要把旧路径继续当成可用。

## 与现有 reverse-skill 工具索引的关系

当本技能位于现有 `reverse-skill/skills/` 下时，可以读取旁边的 `tool-index.json`，并把可用项作为路径证据。现有总路由、各逆向 Skill 和自举脚本仍由宿主项目管理；本技能只调用已发现的工具，不修改 `routing.json`、`MASTER-ROUTING.md` 或其他 Skill 的触发条件。

当本技能被复制到其他 Agent 时，没有旁边的索引也能独立工作：使用自带发现脚本和当前 Agent 能访问的工具。这样“工具角色”保持通用，“本机路径”保持产品/主机本地，互不污染。
