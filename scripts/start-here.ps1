#requires -Version 5

<#
The single entry point. Run this before doing anything else with a product folder.

    powershell -NoProfile -ExecutionPolicy Bypass -File start-here.ps1 -ProductRoot <product-root>

Why it exists: the ordering used to live only in SKILL.md prose, and prose gets skimmed,
reordered and half-applied. An agent would pick a mode before registering the input, treat
"继续维护" as a read-only status report, or edit STATE.yaml by hand. Prose cannot enforce an
order; a script that prints the next literal command can.

Read-only by design: it inspects, decides and prints. It never writes to the product, so it is
always safe to run again, including in the middle of someone else's work.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,

    # What the user actually said, in their own words. Used only to separate "report" from "act";
    # when omitted the mode is derived from the directory alone.
    [string]$UserRequest,

    # Route-Gate task marker (written by route.ps1). When present, the entry verifies it;
    # when absent, this script keeps its historical parameter-less behavior unchanged.
    [string]$TaskId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters.ContainsKey('TaskId')) {
    $gateDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".route-gate"
    if (Test-Path -LiteralPath (Join-Path $gateDir "DISABLED")) {
        Write-Output '逃生模式开着（门禁已关），这次放行。要恢复：删除 ~/.route-gate/DISABLED 或双击桌面恢复。'
    }
    else {
        $decisionPath = Join-Path $gateDir ($TaskId + '\decision.json')
        if (-not (Test-Path -LiteralPath $decisionPath -PathType Leaf)) {
            Write-Output '这个活还没走分派，我先不直接开工。先运行 route.ps1 领个号（约 1 秒），领完我马上接着干。'
            exit 1
        }
        try {
            $routeDecision = [System.IO.File]::ReadAllText($decisionPath) | ConvertFrom-Json
        }
        catch {
            Write-Output '分派标记读不出来，我先不直接开工。先运行 route.ps1 领个号（约 1 秒），领完我马上接着干。'
            exit 1
        }
        $rd = $routeDecision
        $hasAsk = $null -ne $rd.PSObject.Properties['ask']
        $hasDecision = $null -ne $rd.PSObject.Properties['decision']
        $hasTask = $null -ne $rd.PSObject.Properties['task_id']
        $hasVersion = $null -ne $rd.PSObject.Properties['route_version']
        $hasStamp = $null -ne $rd.PSObject.Properties['created_at']
        if ($hasDecision -and [string]$rd.decision -eq 'ask') {
            Write-Output '这个任务的方向还没选定，先把路由那句 1/2/3 回掉。'
            exit 1
        }
        if ((-not $hasTask) -or (-not $hasDecision) -or [string]$rd.task_id -ne $TaskId -or [string]$rd.decision -ne 'exe-product-lifecycle') {
            Write-Output '这个任务的分派结果不是走我这条流程。先运行 route.ps1 确认分派，它会告诉你走哪条流程。'
            exit 1
        }
        $routeVersion = if ($hasVersion) { [string]$rd.route_version } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($routeVersion) -and $routeVersion -ne '1.0') {
            Write-Output '分派标记的版本和当前路由版本对不上，我先停一下。重新运行 route.ps1（约 1 秒）更新标记，我马上接着干。'
            exit 1
        }
        $routeStamp = $null
        if ($hasStamp) {
            try { $routeStamp = [DateTime]$rd.created_at } catch { }
        }
        if ($null -ne $routeStamp) {
            $alreadyStarted = (Test-Path -LiteralPath (Join-Path $ProductRoot 'product-state\STATE.yaml') -PathType Leaf)
            if (-not $alreadyStarted -and (Get-Date).ToUniversalTime() - $routeStamp -gt [TimeSpan]::FromHours(12)) {
                Write-Output '分派标记已经过期了，我先停一下。重新运行 route.ps1（约 1 秒）更新标记，我马上接着干。'
                exit 1
            }
        }
    }
}

# Windows-only, said up front. On PowerShell 7 on macOS/Linux the very next line (dot-sourcing
# lib\product-state-common.ps1) fails with an opaque "cannot find path", because the PE analysis,
# registry lookups and System32 probes this skill relies on exist only on Windows. Fail fast with the
# message the README already promises, so an arbitrary agent that reads the URL and runs this on the
# wrong OS is told plainly instead of chasing a cryptic error. ($IsWindows exists only on PS6+; on 5.1
# the host is Windows by definition, and -and short-circuits so the variable is never referenced there.)
if (($PSVersionTable.PSVersion.Major -ge 6) -and -not $IsWindows) {
    Write-Output '当前平台缺少本脚本的运行依赖（注册表 / System32 / Windows 分析工具）。请在 Windows（PowerShell 5.1 或 7）环境继续本流程。'
    exit 1
}

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

trap {
    try {
        Write-UserFacingFailure -Message $_.Exception.Message -ScriptName 'start-here.ps1' -ErrorRecord $_
    }
    catch {
        Write-Output ('错误: ' + $_.Exception.Message)
    }
    exit 1
}

if (-not (Test-Path -LiteralPath $ProductRoot -PathType Container)) {
    throw (New-UserFacingError -Message "产品文件夹不存在: $ProductRoot" `
        -Hint '先确认这个路径，或者让用户把 EXE 放进一个文件夹再把文件夹路径告诉你。')
}
$root = Resolve-CanonicalPath -Path (Resolve-Path -LiteralPath $ProductRoot).Path
$stateRoot = Join-Path $root 'product-state'
$scriptDir = $PSScriptRoot
$hasState = Test-Path -LiteralPath (Join-Path $stateRoot 'STATE.yaml') -PathType Leaf

$hostInstructionNames = @('AGENTS.md', 'CLAUDE.md', 'GEMINI.md', 'RULES.md', 'RULES_zh.md')

function Get-RegisteredHashes {
    # Returned with the comma operator throughout: PowerShell unrolls an IEnumerable return value,
    # and an *empty* HashSet unrolls to nothing at all, so the caller silently receives $null --
    # which only happens on the brand-new-product path, the one path that must always work.
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not $hasState) { return , $set }
    $manifests = New-Object System.Collections.Generic.List[string]
    $rootManifest = Join-Path $stateRoot 'artifacts\INPUT-MANIFEST.yaml'
    if (Test-Path -LiteralPath $rootManifest -PathType Leaf) { [void]$manifests.Add($rootManifest) }
    $migrations = Join-Path $stateRoot 'migrations'
    if (Test-Path -LiteralPath $migrations -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $migrations -File -Filter '*-INPUT-MANIFEST.yaml' -Recurse)) {
            [void]$manifests.Add($file.FullName)
        }
    }
    foreach ($manifest in $manifests) {
        foreach ($match in [regex]::Matches((Read-TextFileSafe -Path $manifest), '(?i)sha256:\s*["'']?([0-9A-Fa-f]{64})')) {
            [void]$set.Add($match.Groups[1].Value.ToUpperInvariant())
        }
    }
    return , $set
}

$registered = Get-RegisteredHashes
$looseInputs = New-Object System.Collections.Generic.List[object]
foreach ($file in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)) {
    if ($hostInstructionNames -contains $file.Name) { continue }
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($registered.Contains($hash)) { continue }
    [void]$looseInputs.Add([pscustomobject]@{ Name = $file.Name; Full = $file.FullName; Extension = $file.Extension.ToLowerInvariant() })
}
$incomingRoot = Join-Path $root 'incoming'
$incomingFiles = @()
if (Test-Path -LiteralPath $incomingRoot -PathType Container) {
    $incomingFiles = @(Get-ChildItem -LiteralPath $incomingRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not $registered.Contains((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToUpperInvariant()) })
}

# --- mode ---------------------------------------------------------------------------------------
# Input normalization decides the mode, not the other way round: an unregistered artifact means
# there is real work to do regardless of how the user phrased the request.
$readOnlyRequest = $false
if (-not [string]::IsNullOrWhiteSpace($UserRequest)) {
    # A question about progress is answered, not acted on. The action words win when both appear,
    # because mistaking "继续维护" for a status report is the failure that wastes the user's turn.
    $readOnlyRequest = $UserRequest -match '(?i)(状态|进度|进展|做到哪|到哪一步|哪一步|怎么样了|完成了|做完了|还差|还缺|查看|看看|report|status|progress)' -and
        $UserRequest -notmatch '(?i)(继续|接着|往下|开始|更新|迁移|发布|打包|回滚|resume|continue|update|release|rollback)'
}

$mode = 'status'
if (-not $hasState) { $mode = 'bootstrap' }
elseif ($looseInputs.Count -gt 0 -or $incomingFiles.Count -gt 0) { $mode = 'update' }
elseif ($readOnlyRequest) { $mode = 'status' }
elseif (-not [string]::IsNullOrWhiteSpace($UserRequest) -and $UserRequest -match '(?i)(回滚|rollback|上一版|旧版本)') { $mode = 'rollback' }
elseif (-not [string]::IsNullOrWhiteSpace($UserRequest) -and $UserRequest -match '(?i)(发布|打包|测试版|release|package)') { $mode = 'release' }
else { $mode = 'resume' }

$steps = New-Object System.Collections.Generic.List[string]
$quotedRoot = '"' + $root + '"'

# The banner must match the product's track: printing an "EXE" title over a source-reuse product is
# the same track-mismatch the routing below already avoids -- only the title lagged. Read the track
# early (only when a product archive exists) so banner and routing agree; bootstrap (no archive yet)
# keeps the neutral EXE-first default.
$bannerTrack = ''
if ($hasState) { $bannerTrack = (Get-YamlScalar -Text (Read-TextFileSafe -Path (Join-Path $stateRoot 'STATE.yaml')) -Key 'track').Trim() }
if ($bannerTrack -eq 'source') { Write-Output '=== 源码复用二开 · 产品生命周期 · 现在该做什么 ===' }
else { Write-Output '=== EXE 产品生命周期 · 现在该做什么 ===' }
Write-Output ("产品目录: " + $root)
Write-Output ("模式: " + $mode)

if (-not $hasState) {
    Write-Output '当前状态: 还没有产品档案'
    $exeCandidates = @($looseInputs | Where-Object { $_.Extension -eq '.exe' })
    Write-Output ''
    Write-Output '必须按顺序执行:'
    if ($exeCandidates.Count -eq 0) {
        # Two entries share this skill (SKILL.md "两条入口"): black-box EXE maintenance and source-reuse
        # (Phase 2, no EXE ever). Only offering "upload the EXE" here sent every source-reuse user down
        # the wrong entry, so both doors are named and the agent routes by what the user actually wants.
        Write-Output '  1. 这个文件夹里没有 EXE。两条入口都还开着，先判断用户要走哪条，不要张口就要 EXE:'
        Write-Output '     - 黑盒 EXE 维护: 用中文问用户要主程序。只问这一句: 请直接上传 EXE，或告诉我它所在的产品文件夹；有说明文件就一起放进去。'
        Write-Output '     - 源码复用二开(用户只带一句需求、没有也不会有 EXE): 直接建源码产品档案，建好后重新运行本脚本:'
        Write-Output ('       powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'init-source-product.ps1') + '" -ProductRoot ' + $quotedRoot + ' -ProductId <你选的编号> -Goal "<用户的一句需求>"')
    }
    else {
        $core = $exeCandidates[0].Full
        if ($exeCandidates.Count -gt 1) {
            Write-Output ("  0. 这里有 " + $exeCandidates.Count + " 个 EXE，先判断哪个是主程序（看文件大小、版本资源和名称），不要让用户猜。")
            foreach ($candidate in $exeCandidates) { Write-Output ('     - ' + $candidate.Name) }
        }
        Write-Output '  1. 建立产品档案并保存基线（产品编号由你决定，不要问用户）:'
        Write-Output ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'init-product.ps1') + '" -ProductRoot ' + $quotedRoot + ' -ProductId <你选的编号> -CorePath "' + $core + '"')
        Write-Output '  2. 建档后立刻重新运行本脚本，它会给出下一步:'
        Write-Output ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'start-here.ps1') + '" -ProductRoot ' + $quotedRoot)
    }
    Write-Output ''
    Write-Output '不要做: 不要先分析、不要先发现工具、不要先问用户任何技术问题。先建档保存原件。'
    exit 0
}

$stateText = Read-TextFileSafe -Path (Join-Path $stateRoot 'STATE.yaml')
$status = Get-YamlScalar -Text $stateText -Key 'status'
# The same track->table selection the validator and the writer already use. Judged against the EXE
# table, every legitimate source status (track: source, Phase 2) read as unknown, so this entry point
# printed STATE_REPAIR_REQUIRED and told the agent to "repair" the status back to an EXE value --
# advice that corrupts a legal source product, at the one place an agent looks first.
$track = (Get-YamlScalar -Text $stateText -Key 'track').Trim()
$lifecycleFile = Get-LifecycleTableFileForTrack -Track $track
$readiness = Get-LifecycleReadiness -StateRoot $stateRoot -Status $status -TableFile $lifecycleFile
if (-not [string]::IsNullOrWhiteSpace($status) -and -not $readiness.Known) {
    # STATE.yaml carries a status the lifecycle table does not know -- hand-edited, or a skipped step
    # left it polluted. Every step below is derived from a status the table understands, so print the
    # one repair action machine-readably and stop, instead of empty "继续..." steps that send the
    # agent off to re-improvise the order (the ISSUE-096 relapse the validator now also guards).
    $legalStatuses = @((Get-LifecycleTable -TableFile $lifecycleFile).states | ForEach-Object { [string]$_.status })
    Write-Output ''
    Write-Output ("STATE_REPAIR_REQUIRED: STATE.yaml 的 status=" + $status + " 不在生命周期表里，先修状态再谈下一步")
    Write-Output "NEXT-STATUS: STATE_REPAIR"
    Write-Output "NEXT-ACTION: 用 update-product-state.ps1 把 status 改回下列合法值之一，再重新运行本脚本（不要手改 STATE.yaml）"
    Write-Output ("BLOCKING-FACTS: status=" + $status + "; 合法值=" + ($legalStatuses -join ', '))
    exit 0
}
Write-Output ("当前状态: " + $status + "（" + $readiness.Meaning + "）")
Write-Output ("CURRENT-USER-TESTABILITY: " + (Get-UserTestability -StateRoot $stateRoot -Status $status))

$stepNumber = 0
Write-Output ''
Write-Output '必须按顺序执行:'

if ($looseInputs.Count -gt 0 -or $incomingFiles.Count -gt 0) {
    $stepNumber++
    $names = @(@(@($looseInputs | ForEach-Object { $_.Name }) + @($incomingFiles | ForEach-Object { $_.Name })) | Select-Object -Unique)
    Write-Output ("  " + $stepNumber + ". [先做这个] 有 " + $names.Count + " 个文件还没有登记: " + ($names -join ', '))
    if ($looseInputs.Count -gt 0) {
        Write-Output '     先把产品根目录里的这些文件移进 incoming/（不要覆盖当前版本），再登记:'
    }
    Write-Output ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'register-input-bundle.ps1') + '" -ProductRoot ' + $quotedRoot + ' -InputRoot incoming')
    Write-Output '     登记之前不要分析、不要比较版本、不要改任何状态。'
}

if ($mode -eq 'status') {
    $stepNumber++
    Write-Output ("  " + $stepNumber + ". 用户只是想知道进度。读 PRODUCT-INDEX.md 和 STATE.yaml，用中文回答: 做完了什么 / 发现了什么 / 下一步是什么。")
    Write-Output '     不要修改任何文件。想推进工作时用户会再说一次。'
}
else {
    $stepNumber++
    Write-Output ("  " + $stepNumber + ". " + $readiness.NextAction)
    foreach ($item in $readiness.PendingForNext) {
        Write-Output ("     还缺: " + $item.Why)
    }
    if ($readiness.ReadyToAdvance) {
        Write-Output '     [可以收工] 本阶段该做的都齐了：下一步就是把它落地。先跑下面这条 update 命令建一个检查点，再继续；不要停在这一阶段反复加工。'
    }
    if (@($readiness.PendingForNext | Where-Object { $_.Detail -like '*TOOL-INVENTORY*' }).Count -gt 0) {
        Write-Output ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'discover-tools.ps1') + '" -ProductRoot ' + $quotedRoot + ' -ReuseInventory')
    }
    if (@($readiness.PendingForNext | Where-Object { $_.Detail -like '*PROTECTION-PROFILE*' }).Count -gt 0) {
        Write-Output '     先探测目标的保护机制（加壳/自校验/反调试/签名），它决定能不能改、能不能加固:'
        Write-Output ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'detect-protections.ps1') + '" -ProductRoot ' + $quotedRoot)
    }
    if (@($readiness.PendingForNext | Where-Object { $_.Detail -like '*ANALYSIS-FINDINGS*' }).Count -gt 0) {
        # Optional escape from analysis paralysis, printed beside the pressure point that causes it (the
        # six categories still undecided) rather than in prose, for the same reason this whole script
        # exists. It is off by default and NOT a required step -- only a way out when an agent is stuck on
        # how to even begin. The gate that makes it honest lives in validate-product-state.ps1: once you
        # mark BRAINSTORM-LOG resolved you must have landed a real ROUTE-DECISION, or it reds.
        Write-Output '     [可选] 不确定怎么切入（六类迟迟给不出决定 / 找不到授权面 / 不知道走哪条复刻路线）: 可以开一场有界头脑风暴——主对话当桥，派 2-4 个对立角色（静态结构派 / 动态调试派 / 已知工具复用派 / 怀疑者）各出一个切入方案并互相找漏洞，1-2 轮快速收敛。做法见 references/analysis-brainstorm.md。'
        Write-Output '     它默认关、也不是必经步骤；一旦你开了并把 analysis/BRAINSTORM-LOG.yaml 的 status 改成 resolved，就必须已经在 analysis/ROUTE-DECISION.yaml 里选定一条真实路线（否则校验会红——讨论结束不等于完成）。'
        # The six reverse-engineering categories each have to end in done/not_applicable/blocked before
        # ANALYZED can be written, and that gate pushes. When a category genuinely ran its tool and got
        # nothing back, the cheapest way out is not_applicable -- which is exactly the "quietly fill the
        # category -> drift into a shell -> claim done" failure gap-classify.ps1 was built to stop. The
        # classifier only helps if the agent meets it at that moment, so the escape hatch is printed
        # beside the requirement that creates the pressure. Stating it in prose instead is what made the
        # ordering rules move into this script in the first place.
        Write-Output '     六类里如果有哪一类你真的跑过工具却产不出证据: 不要填 not_applicable、也不要留空。用下面这条把它记成有证据绑定的 blocked，它会判定这是缺工具 / 输入问题 / 死路，并写进 STATE.yaml 的 blocking_items:'
        Write-Output ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'gap-classify.ps1') + '" -ProductRoot ' + $quotedRoot + ' -CapabilityId <能力id，例 unpack.pe.upx> -Technique <static_structure|static_strings|static_resources|disassembly|dynamic_behavior|unpacking> -FailureCommand "<你真跑过的那条命令>" -FailureOutputPath <product-state/ 下保存这条命令输出的文件>')
        Write-Output '     口说不算证据: 失败输出必须是 product-state/ 下真实存在且非空的文件，否则它拒绝写入。它也要求工具清单已经建好（先跑上面那条 discover-tools），因为「从没查过」不等于「查过没有」。'
        Write-Output '     真的什么都做不成时，blocked 就是合法结局: 如实停在这里比编一个 not_applicable 继续往前走更好，后面的门会拦住未解决的 blocking_items。'

        # The other half of the same moment. gap-classify records the capability the machine could not
        # deliver; learn-tool.ps1 records the tool that finally did. It is the only writer of the machine-local
        # learned layer, and it shipped with no callers at all -- the single mention anywhere in the tree was a
        # comment inside a test -- so an agent following SKILL.md never arrived at it and every product
        # re-searched for tools this machine had already found once. Printed beside the pending analysis
        # categories rather than stated in SKILL.md, for the reason this whole script exists: prose gets skimmed.
        #
        # Two conditions, both load-bearing. The inventory must exist, because "never ran discovery" is not
        # "discovery found nothing" -- the same distinction gap-classify enforces one step above. And at least
        # one role must actually be empty, because with every role filled there is nothing to learn and this
        # would just be a banner; a hint that prints on every run is one the agent stops reading.
        $inventoryJson = Join-Path $stateRoot 'tooling\TOOL-INVENTORY.json'
        if (Test-Path -LiteralPath $inventoryJson -PathType Leaf) {
            $missingRoles = New-Object System.Collections.Generic.List[string]
            try {
                $inventory = Get-Content -Raw -Encoding UTF8 -LiteralPath $inventoryJson | ConvertFrom-Json
                foreach ($row in @($inventory.tools)) {
                    if ($null -eq $row) { continue }
                    $rowProps = $row.PSObject.Properties
                    if ($null -eq $rowProps['tool_id']) { continue }
                    # A row with no available field predates it. Treating that as a gap would invent an
                    # errand out of an old snapshot, so only an explicit false counts.
                    if ($null -ne $rowProps['available'] -and -not $row.available) { [void]$missingRoles.Add([string]$row.tool_id) }
                }
            }
            catch {
                # A malformed inventory is discover-tools' error to report. This script is read-only and
                # always safe to re-run; a second error about the same file would only obscure the first.
                $missingRoles.Clear()
            }
            if ($missingRoles.Count -gt 0) {
                Write-Output ('     本机有 ' + $missingRoles.Count + ' 个角色还没有工具（例 ' + $missingRoles[0] + '）。如果你为其中哪一个找到并装上了工具、而且已经用它把活干完了，收尾补这一条，把它记进本机清单，否则下一个产品还要从头再找一遍:')
                Write-Output ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'learn-tool.ps1') + '" -RoleId ' + $missingRoles[0] + ' -Name <你装上的可执行文件名，例 innoextract.exe> -SourceUrl <你从哪儿拿到它的> -InstallRoute <winget|manual|already_present>')
                Write-Output '     顺序不能反: 先装、先用它把活真的干完，最后才记。记录是事后的副作用不是前置条件，所以这条命令即使失败也不会让已经完成的工作作废，它会把没记上的那条原样打出来让你手工补。'
                Write-Output '     它还能把「这个能力归这个角色」写进桥表，但那会改变本机算不算有能力做某事，所以必须带 -BridgeCapability <能力id> -BridgeApproved，并且只能并进用户决定装不装的那一次点头里，不要为它新开一次审批。'
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($readiness.NextStatus)) {
        $stepNumber++
        Write-Output ("  " + $stepNumber + ". 上面做完并且有证据之后，用这条命令写状态（不要手改 STATE.yaml 或 PRODUCT-INDEX.md）:")
        Write-Output ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'update-product-state.ps1') + '" -ProductRoot ' + $quotedRoot + ' -Status ' + $readiness.NextStatus + ' -Mode ' + $mode)
        Write-Output '     证据不够时这条命令会拒绝执行并列出还缺什么，这是正常的，不要绕过它。'
    }
}

$stepNumber++
Write-Output ("  " + $stepNumber + ". 每一步做完都重新跑一次检查，用它的输出决定下一步:")
Write-Output ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'validate-product-state.ps1') + '" -ProductRoot ' + $quotedRoot)

if ($readiness.Unmet.Count -gt 0) {
    Write-Output ''
    Write-Output '注意: 当前状态和证据对不上，说明之前有人跳过了步骤。先补齐下面这些，不要在这个基础上继续往前走:'
    foreach ($item in $readiness.Unmet) { Write-Output ('  - ' + $item.Why) }
}

if (Test-Path -LiteralPath (Join-Path $stateRoot '.state-journal.json') -PathType Leaf) {
    Write-Output ''
    Write-Output '注意: 上一次状态变更没有写完。先收尾，再做别的:'
    Write-Output ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $scriptDir 'update-product-state.ps1') + '" -ProductRoot ' + $quotedRoot + ' -ResumeJournal')
}

Write-Output ''
Write-Output '不要做:'
Write-Output '  - 不要重新初始化已有产品（会拒绝，但也别试）。'
Write-Output '  - 不要手改 STATE.yaml 或 PRODUCT-INDEX.md，用 update-product-state.ps1。'
if ($track -ne 'source') {
    # 下面两条是 EXE 二开轨道专属；源码复用轨道没有“新交来的 EXE”，前半段也没有逆向工具清单，故对源产品不打印。
    Write-Output '  - 不要把新交来的 EXE 当成当前版本，登记成新批次后再比较。'
    Write-Output '  - 不要因为 TOOL-INVENTORY.md 存在就认为工具清单是新的，一律带 -ReuseInventory 重跑。'
}
