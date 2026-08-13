#requires -Version 5

<#
Initialize a SOURCE-REUSE (二开 from source) product. Phase 2 entry: the user states a need, the agent
finds like-kind open-source references, learns their approach (never bulk-merging a repo), and implements
it in the user's own project -- then flows into the SAME shared downstream as the EXE track.

    init-source-product.ps1 -ProductRoot <path> -ProductId my-tool [-ProductName "My Tool"] [-Goal "一句话需求"]

Unlike init-product.ps1 there is no -CorePath: a source product has no handed-over EXE and no baseline
hash. It reuses the shared product-state downstream scaffold (customization/auth/release/rollback/evidence)
plus a source front half (source/SOURCE-INTAKE.yaml, REFERENCE-INVENTORY.yaml, CAPABILITY-MAP.yaml) and is
governed by assets/lifecycle-states-source.json via STATE.yaml `track: source`.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$')]
    [string]$ProductId,

    [string]$ProductName,

    [string]$Goal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

trap {
    Write-UserFacingFailure -Message $_.Exception.Message -ScriptName 'init-source-product.ps1' -ErrorRecord $_
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ProductName)) { $ProductName = $ProductId }

if (-not (Test-Path -LiteralPath $ProductRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $ProductRoot | Out-Null
}
$root = Resolve-CanonicalPath -Path (Resolve-Path -LiteralPath $ProductRoot).Path
$skillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$sharedScaffold = (Resolve-Path -LiteralPath (Join-Path $skillRoot 'assets\product-scaffold')).Path
$sourceScaffold = (Resolve-Path -LiteralPath (Join-Path $skillRoot 'assets\source-scaffold')).Path

$stateRoot = Join-Path $root 'product-state'
$existingStatePath = Join-Path $stateRoot 'STATE.yaml'
if (Test-Path -LiteralPath $existingStatePath -PathType Leaf) {
    $existingText = Read-TextFileSafe -Path $existingStatePath
    $existingId = Get-YamlScalar -Text $existingText -Key 'product_id'
    if (-not [string]::IsNullOrWhiteSpace($existingId) -and $existingId -ne $ProductId) {
        throw (New-UserFacingError -Message "这个文件夹已经属于产品「$existingId」，不是「$ProductId」。" `
            -Hint "继续维护原产品请改用产品编号 $existingId；这是另一个产品就换一个空文件夹。")
    }
    $existingTrack = (Get-YamlScalar -Text $existingText -Key 'track').Trim()
    if ($existingTrack -ne 'source') {
        throw (New-UserFacingError -Message '这个文件夹已经是一个 EXE 二开产品（不是源码入口），不能用源码入口重新初始化。' `
            -Hint '源码入口请换一个空文件夹；要维护原 EXE 产品请用它对应的 EXE 流程。')
    }
}

$externalDirs = @('incoming')
$stateDirs = @(
    'source', 'analysis', 'auth', 'release', 'migrations', 'reports', 'rollback', 'tooling', 'learning', 'learning\candidates',
    'artifacts', 'artifacts\upstream', 'artifacts\maintained', 'artifacts\patches',
    'artifacts\verification', 'artifacts\rollback', 'artifacts\incoming',
    'artifacts\quarantine', 'artifacts\reference-docs', 'artifacts\analysis'
)
foreach ($relative in @($externalDirs) + @($stateDirs | ForEach-Object { Join-Path 'product-state' $_ })) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $relative) | Out-Null
}

# 1) shared downstream scaffold: only create what is not already there (never clobber existing product facts)
$createdFiles = New-Object System.Collections.Generic.List[string]
foreach ($file in @(Get-ChildItem -LiteralPath $sharedScaffold -Recurse -File)) {
    $relative = $file.FullName.Substring($sharedScaffold.Length).TrimStart('\', '/')
    $destination = Join-Path $stateRoot $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        [void]$createdFiles.Add($destination)
    }
}

# 2) source overlay: STATE.yaml + PRODUCT-INDEX.md (source-flavored) win over the EXE versions; source/ files added
foreach ($file in @(Get-ChildItem -LiteralPath $sourceScaffold -Recurse -File)) {
    $relative = $file.FullName.Substring($sourceScaffold.Length).TrimStart('\', '/')
    $destination = Join-Path $stateRoot $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    $isOverlayRoot = @('STATE.yaml', 'PRODUCT-INDEX.md') -contains $relative
    if ($isOverlayRoot -or -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        if (-not $createdFiles.Contains($destination)) { [void]$createdFiles.Add($destination) }
    }
}

# 3) placeholder replacement across the freshly-created product state. A source product has no EXE, so the
# EXE-only baseline placeholders are filled with an explicit source-track sentinel rather than left blank.
$date = Get-Date -Format 'yyyy-MM-dd'
$replacements = @{
    '__PRODUCT_ID__'        = $ProductId
    '__PRODUCT_NAME__'      = $ProductName
    '__DATE__'              = $date
    '__CORE_FILE__'         = '(source track: 无独立 EXE 输入)'
    '__BASELINE_ARTIFACT__' = '(source track: 无上游二进制基线)'
    '__BASELINE_SHA256__'   = '(source track: 无基线哈希)'
    '__START_DOCUMENT__'    = 'UNVERIFIED'
}
foreach ($file in @(Get-ChildItem -LiteralPath $stateRoot -Recurse -File | Where-Object { $_.Extension -in @('.md', '.yaml', '.yml', '.json', '.txt') })) {
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
    if ($null -eq $text) { continue }
    $changed = $false
    foreach ($key in $replacements.Keys) {
        if ($text.Contains($key)) { $text = $text.Replace($key, [string]$replacements[$key]); $changed = $true }
    }
    if ($changed) { $text | Set-Content -LiteralPath $file.FullName -Encoding utf8 }
}

# 4) optional one-line goal into the intake
if (-not [string]::IsNullOrWhiteSpace($Goal)) {
    $intakePath = Join-Path $stateRoot 'source\SOURCE-INTAKE.yaml'
    if (Test-Path -LiteralPath $intakePath -PathType Leaf) {
        $intakeText = Read-TextFileSafe -Path $intakePath
        $intakeText = [regex]::Replace($intakeText, '(?m)^goal:\s*.*$', ('goal: ' + (ConvertTo-YamlScalar $Goal)), 1)
        Write-FileAtomic -Path $intakePath -Content $intakeText
    }
}

[pscustomobject]@{
    status = 'initialized'
    track = 'source'
    product_id = $ProductId
    product_root = $root
    entry_state = 'SOURCE_INTAKE'
    lifecycle_table = 'assets/lifecycle-states-source.json'
    created_template_files = $createdFiles.Count
    next_action = '录入需求(source/SOURCE-INTAKE.yaml 的 status 置 DEFINED)，再联网找同类开源参考登记到 source/REFERENCE-INVENTORY.yaml'
} | ConvertTo-Json -Depth 4
