#requires -Version 5

<#
Atomically move a product from one lifecycle status to the next.

    update-product-state.ps1 -ProductRoot <path> -Status ANALYZED -Mode resume -NextAction "..."
    update-product-state.ps1 -ProductRoot <path> -ResumeJournal

STATE.yaml and PRODUCT-INDEX.md carry the same three facts, and until now an agent updated them
with two independent writes. A crash between the two left the product claiming one status in one
file and another status in the other -- validate-product-state.ps1 could report the split but
nobody could repair it, because the journal it reads had no writer. This is that writer.

Every transition is journalled before it is applied and the journal is removed only after every
target has been verified on disk, so an interrupted transition is always either fully applied or
fully replayable.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,

    # No [ValidateSet] here: it would be a second hardcoded copy of the status list -- the ISSUE-096
    # drift. $Status is validated against the lifecycle table in the body instead (PowerShell 5.1
    # cannot feed a runtime source into a [ValidateSet] attribute).
    [string]$Status,

    [ValidateSet('bootstrap', 'update', 'status', 'resume', 'release', 'rollback')]
    [string]$Mode,

    [string]$NextAction,

    [string[]]$BlockingItems,

    [switch]$ClearBlockingItems,

    # Records the override in the output instead of pretending the gate passed. Use it only when a
    # human has decided the evidence exists somewhere the table cannot see.
    [switch]$Force,

    [switch]$ResumeJournal,

    [int]$LockTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

trap {
    Write-UserFacingFailure -Message $_.Exception.Message -ScriptName 'update-product-state.ps1' -ErrorRecord $_
    exit 1
}

$root = Resolve-CanonicalPath -Path (Resolve-Path -LiteralPath $ProductRoot).Path
$stateRoot = Join-Path $root 'product-state'
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    throw (New-UserFacingError -Message "这个文件夹还没有产品档案: $ProductRoot" `
        -Hint '先做一次首次接入建立档案，再更新状态。')
}
$statePath = Join-Path $stateRoot 'STATE.yaml'
$indexPath = Join-Path $stateRoot 'PRODUCT-INDEX.md'
foreach ($required in @($statePath, $indexPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw (New-UserFacingError -Message "产品档案不完整，缺少: $required" `
            -Hint '恢复上一个可用备份，或重新运行首次接入补齐模板文件。')
    }
}
# Phase 2 track selection: a source-reuse product (track: source) is validated against the source ladder,
# an EXE/legacy product against the EXE ladder. Read once here so both the -Status sanity check and the
# forward gate below judge the transition against the right lifecycle table.
$productTrack = (Get-YamlScalar -Text (Read-TextFileSafe -Path $statePath) -Key 'track').Trim()
$lifecycleFile = Get-LifecycleTableFileForTrack -Track $productTrack
if (-not [string]::IsNullOrWhiteSpace($Status)) {
    # Validated against the lifecycle table, not a [ValidateSet] literal: a second hardcoded copy of
    # the status list is the ISSUE-096 drift. Fires only for a non-empty -Status, so -ResumeJournal
    # and blocking-item-only calls are unaffected.
    $validStatuses = @((Get-LifecycleTable -TableFile $lifecycleFile).states | ForEach-Object { [string]$_.status })
    if ($validStatuses -notcontains $Status) {
        throw (New-UserFacingError -Message "不认识的状态: $Status" `
            -Hint ("状态必须是下列之一: " + ($validStatuses -join ', ')))
    }
}
$journalPath = Join-Path $stateRoot '.state-journal.json'

function Get-FileSha {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-ContentSha {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    # Must match what Write-FileAtomic actually puts on disk: UTF-8 with BOM plus a trailing
    # newline. Hashing the bare string would make every intended hash wrong by three bytes.
    $bytes = (New-Object System.Text.UTF8Encoding($true)).GetPreamble() +
        [System.Text.Encoding]::UTF8.GetBytes($Content + [Environment]::NewLine)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToUpperInvariant() }
    finally { $sha.Dispose() }
}

$lockKey = $root.ToLowerInvariant()
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    # Same lock name as register-input-bundle.ps1: an intake and a status transition touching the
    # same product must serialize, not interleave.
    $lockName = 'Local\exe-lifecycle-product-' +
        ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lockKey))).Replace('-', '').Substring(0, 32))
}
finally { $sha.Dispose() }
$mutex = New-Object System.Threading.Mutex($false, $lockName)
$lockHeld = $false

try {
    try { $lockHeld = $mutex.WaitOne([TimeSpan]::FromSeconds($LockTimeoutSeconds)) }
    catch [System.Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) {
        throw (New-UserFacingError -Message "另一个任务正在改同一个产品的档案，等待超时: $ProductRoot" `
            -Hint '等前一个任务结束后重试；同一个产品同一时间只能有一个写入者。')
    }

    # --- resume an interrupted transition -------------------------------------------------------
    if ($ResumeJournal) {
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            [pscustomobject]@{ status = 'no_journal'; product_root = $root; message = '没有未完成的状态变更，无需恢复' } | ConvertTo-Json -Depth 4
            exit 0
        }
        $journal = Read-TextFileSafe -Path $journalPath | ConvertFrom-Json
        $applied = New-Object System.Collections.Generic.List[string]
        $alreadyDone = New-Object System.Collections.Generic.List[string]
        $conflicting = New-Object System.Collections.Generic.List[string]
        foreach ($target in @($journal.targets)) {
            $targetFull = Join-Path $root ([string]$target.path).Replace('/', '\')
            $actual = Get-FileSha -Path $targetFull
            $intended = ([string]$target.sha256_intended).ToUpperInvariant()
            $before = ([string]$target.sha256_before).ToUpperInvariant()
            if ($actual -eq $intended) { [void]$alreadyDone.Add([string]$target.path); continue }
            if ($actual -ne $before) { [void]$conflicting.Add([string]$target.path); continue }
            $content = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$target.content_b64))
            Write-FileAtomic -Path $targetFull -Content $content
            if ((Get-FileSha -Path $targetFull) -ne $intended) {
                throw (New-UserFacingError -Message "恢复写入后校验值不符: $($target.path)" `
                    -Hint '磁盘或权限有问题，先确认文件可写再重试。')
            }
            [void]$applied.Add([string]$target.path)
        }
        if ($conflicting.Count -gt 0) {
            # Refusing beats guessing: these files were edited by something other than this
            # transition, so replaying would silently discard that edit.
            throw (New-UserFacingError -Message "这些文件在中断期间被别的操作改过，拒绝自动恢复: $($conflicting -join ', ')" `
                -Hint '人工确认这些文件的内容是否正确，确认后删除 product-state/.state-journal.json 再重新设置状态。')
        }
        Remove-Item -LiteralPath $journalPath -Force
        [pscustomobject]@{
            status = 'journal_replayed'
            product_root = $root
            transition = ('{0} -> {1}' -f [string]$journal.transition.from_status, [string]$journal.transition.to_status)
            replayed = @($applied.ToArray())
            already_applied = @($alreadyDone.ToArray())
        } | ConvertTo-Json -Depth 4
        exit 0
    }

    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        throw (New-UserFacingError -Message '上一次状态变更没有完成，档案里还留着未完成记录。' `
            -Hint '先运行同一个脚本加上 -ResumeJournal 把它收尾，再做新的状态变更。')
    }

    $stateText = Read-TextFileSafe -Path $statePath
    $indexText = Read-TextFileSafe -Path $indexPath
    $fromStatus = Get-YamlScalar -Text $stateText -Key 'status'
    $productId = Get-YamlScalar -Text $stateText -Key 'product_id'
    if ([string]::IsNullOrWhiteSpace($productId)) {
        throw (New-UserFacingError -Message "产品档案里读不出产品编号: $statePath" `
            -Hint '打开 product-state/STATE.yaml 确认 product_id 有值，或恢复上一个可用备份。')
    }

    $targetStatus = $fromStatus
    if (-not [string]::IsNullOrWhiteSpace($Status)) { $targetStatus = $Status }

    # --- forward gate ---------------------------------------------------------------------------
    # Checked before anything is written, against the evidence already on disk. The transition only
    # rewrites STATE.yaml and PRODUCT-INDEX.md, so evaluating the target status against the current
    # evidence is exactly the question "am I allowed to claim this".
    $gateOverridden = $false
    if ($targetStatus -ne $fromStatus) {
        $readiness = Get-LifecycleReadiness -StateRoot $stateRoot -Status $targetStatus -TableFile $lifecycleFile
        if (-not $readiness.Known) {
            throw (New-UserFacingError -Message "状态「$targetStatus」不在生命周期状态表里。" `
                -Hint '只能使用状态表里定义的状态；表在 assets/lifecycle-states.json。')
        }
        if ($readiness.Unmet.Count -gt 0) {
            if (-not $Force) {
                $reasons = @($readiness.Unmet | ForEach-Object { '  - ' + $_.Why + ' [' + $_.Detail + ']' })
                throw (New-UserFacingError -Message ("还不能把状态改成「$targetStatus」，下面这些证据还不成立:" + [Environment]::NewLine + ($reasons -join [Environment]::NewLine)) `
                    -Hint '先把上面列出的内容补齐再改状态；确实已经有证据但表看不到时，才用 -Force 并在报告里写明原因。')
            }
            $gateOverridden = $true
        }
    }

    # --- compute the intended content -----------------------------------------------------------
    $newStateText = $stateText
    $newIndexText = $indexText

    if ($targetStatus -ne $fromStatus) {
        $newStateText = Set-YamlScalar -Text $newStateText -Key 'status' -Value $targetStatus
        $newIndexText = [regex]::Replace($newIndexText, '(?m)^(- 当前状态:\s*`)[^`]*(`)', ('${1}' + $targetStatus + '${2}'))
        # RV-R2 hole B: a -Force override must leave a mark ON DISK, not only in the output JSON, so a
        # forced state is no longer byte-identical to an earned one. Written on every transition so it
        # cannot go stale -- a later clean (non-forced) transition resets it to false.
        $newStateText = Set-YamlScalar -Text $newStateText -Key 'gate_overridden' -Value $(if ($gateOverridden) { 'true' } else { 'false' })
        if ($targetStatus -in @('VERIFIED', 'VERIFIED_SIMULATION', 'RELEASED')) {
            $newStateText = Set-YamlScalar -Text $newStateText -Key 'last_verified_at' -Value (Get-Date -Format 'yyyy-MM-dd')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Mode)) {
        $newStateText = Set-YamlScalar -Text $newStateText -Key 'mode' -Value $Mode
        $newIndexText = [regex]::Replace($newIndexText, '(?m)^(- 当前模式:\s*`)[^`]*(`)', ('${1}' + $Mode + '${2}'))
    }
    if (-not [string]::IsNullOrWhiteSpace($NextAction)) {
        $newStateText = Set-YamlScalar -Text $newStateText -Key 'next_action' -Value $NextAction
        $newIndexText = [regex]::Replace($newIndexText, '(?m)^(- 唯一下一步:\s*).*$', ('${1}' + $NextAction))
    }
    if ($ClearBlockingItems) {
        $newStateText = Set-YamlList -Text $newStateText -Key 'blocking_items' -Items @()
    }
    elseif ($null -ne $BlockingItems) {
        $newStateText = Set-YamlList -Text $newStateText -Key 'blocking_items' -Items $BlockingItems
    }

    $targets = New-Object System.Collections.Generic.List[object]
    $pairs = @(
        [pscustomobject]@{ Relative = 'product-state/STATE.yaml'; Full = $statePath; Old = $stateText; New = $newStateText },
        [pscustomobject]@{ Relative = 'product-state/PRODUCT-INDEX.md'; Full = $indexPath; Old = $indexText; New = $newIndexText }
    )
    foreach ($pair in $pairs) {
        if ($pair.Old -eq $pair.New) { continue }
        [void]$targets.Add([pscustomobject]@{
            path = $pair.Relative
            sha256_before = (Get-FileSha -Path $pair.Full)
            sha256_intended = (Get-ContentSha -Content $pair.New)
            content_b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair.New))
        })
    }

    if ($targets.Count -eq 0) {
        [pscustomobject]@{ status = 'unchanged'; product_root = $root; product_status = $fromStatus; message = '没有需要修改的内容' } | ConvertTo-Json -Depth 4
        exit 0
    }

    $journalId = 'txn-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + $PID
    $journalObject = [pscustomobject]@{
        schema_version = 1
        journal_id = $journalId
        product_id = $productId
        created_at = (Get-Date).ToString('o')
        transition = [pscustomobject]@{ from_status = $fromStatus; to_status = $targetStatus }
        targets = @($targets.ToArray())
    }
    Write-FileAtomic -Path $journalPath -Content ($journalObject | ConvertTo-Json -Depth 6)

    foreach ($target in $targets) {
        $targetFull = Join-Path $root ([string]$target.path).Replace('/', '\')
        $content = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$target.content_b64))
        Write-FileAtomic -Path $targetFull -Content $content
        $actual = Get-FileSha -Path $targetFull
        if ($actual -ne [string]$target.sha256_intended) {
            # The journal deliberately survives this: a verified-failed write is exactly the case
            # -ResumeJournal exists for.
            throw (New-UserFacingError -Message "写入后校验值不符: $($target.path)" `
                -Hint '磁盘或权限有问题。修好之后运行同一个脚本加上 -ResumeJournal 收尾。')
        }
    }

    Remove-Item -LiteralPath $journalPath -Force

    $after = Get-LifecycleReadiness -StateRoot $stateRoot -Status $targetStatus -TableFile $lifecycleFile
    [pscustomobject]@{
        status = 'updated'
        product_root = $root
        product_id = $productId
        from_status = $fromStatus
        to_status = $targetStatus
        gate_overridden = $gateOverridden
        changed_files = @($targets | ForEach-Object { [string]$_.path })
        next_status = $after.NextStatus
        next_action = $after.NextAction
        next_needs = @($after.PendingForNext | ForEach-Object { $_.Why })
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($lockHeld) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
