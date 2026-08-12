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
    [string]$UserRequest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows-only, said up front. On PowerShell 7 on macOS/Linux the very next line (dot-sourcing
# lib\product-state-common.ps1) fails with an opaque "cannot find path", because the PE analysis,
# registry lookups and System32 probes this skill relies on exist only on Windows. Fail fast with the
# message the README already promises, so an arbitrary agent that reads the URL and runs this on the
# wrong OS is told plainly instead of chasing a cryptic error. ($IsWindows exists only on PS6+; on 5.1
# the host is Windows by definition, and -and short-circuits so the variable is never referenced there.)
if (($PSVersionTable.PSVersion.Major -ge 6) -and -not $IsWindows) {
    Write-Output '错误: 这个 Skill 只能在 Windows 上运行（PowerShell 5.1 或 7）。它分析 Windows EXE，依赖注册表、System32 和 Windows 专用分析工具，在 macOS/Linux 上无法运行脚本。'
    exit 1
}

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

trap {
    Write-UserFacingFailure -Message $_.Exception.Message -ScriptName 'start-here.ps1' -ErrorRecord $_
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

Write-Output '=== EXE 产品生命周期 · 现在该做什么 ==='
Write-Output ("产品目录: " + $root)
Write-Output ("模式: " + $mode)

if (-not $hasState) {
    Write-Output '当前状态: 还没有产品档案'
    $exeCandidates = @($looseInputs | Where-Object { $_.Extension -eq '.exe' })
    Write-Output ''
    Write-Output '必须按顺序执行:'
    if ($exeCandidates.Count -eq 0) {
        Write-Output '  1. 这个文件夹里没有 EXE。用中文问用户要主程序，或者确认主程序在哪个文件夹。'
        Write-Output '     只问这一句: 请直接上传 EXE，或告诉我它所在的产品文件夹；有说明文件就一起放进去。'
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
$readiness = Get-LifecycleReadiness -StateRoot $stateRoot -Status $status
if (-not [string]::IsNullOrWhiteSpace($status) -and -not $readiness.Known) {
    # STATE.yaml carries a status the lifecycle table does not know -- hand-edited, or a skipped step
    # left it polluted. Every step below is derived from a status the table understands, so print the
    # one repair action machine-readably and stop, instead of empty "继续..." steps that send the
    # agent off to re-improvise the order (the ISSUE-096 relapse the validator now also guards).
    $legalStatuses = @((Get-LifecycleTable).states | ForEach-Object { [string]$_.status })
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
Write-Output '  - 不要把新交来的 EXE 当成当前版本，登记成新批次后再比较。'
Write-Output '  - 不要因为 TOOL-INVENTORY.md 存在就认为工具清单是新的，一律带 -ReuseInventory 重跑。'
