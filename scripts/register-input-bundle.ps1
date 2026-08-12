#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,

    [string]$InputRoot = 'incoming',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$')]
    [string]$BundleId,

    [int]$LockTimeoutSeconds = 60
)

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

trap {
    Write-UserFacingFailure -Message $_.Exception.Message -ScriptName 'register-input-bundle.ps1' -ErrorRecord $_
    exit 1
}

$root = (Resolve-Path -LiteralPath $ProductRoot).Path
$stateRoot = Join-Path $root 'product-state'
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    throw (New-UserFacingError -Message "这个文件夹还没有产品档案: $ProductRoot" `
        -Hint '先做一次首次接入建立档案，再登记新版本。')
}
$statePath = Join-Path $stateRoot 'STATE.yaml'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw (New-UserFacingError -Message "产品档案缺少状态文件 STATE.yaml: $ProductRoot" `
        -Hint '档案不完整，先恢复上一个可用备份再登记新输入。')
}
$stateText = Read-TextFileSafe -Path $statePath
# Shared tolerant reader: the quoted-only regex used to reject `product_id: foo`, which is valid
# YAML and which validate-product-state.ps1 accepts without complaint.
$productId = Get-YamlScalar -Text $stateText -Key 'product_id'
if ([string]::IsNullOrWhiteSpace($productId)) {
    throw (New-UserFacingError -Message "产品档案里读不出产品编号: $ProductRoot" `
        -Hint '打开 product-state/STATE.yaml 确认 product_id 有值，或恢复上一个可用备份。')
}

$inputPath = $InputRoot
if (-not [IO.Path]::IsPathRooted($inputPath)) {
    $inputPath = Join-Path $root $inputPath
}
$inputPath = (Resolve-Path -LiteralPath $inputPath).Path
if (-not (Test-Path -LiteralPath $inputPath -PathType Container)) {
    throw (New-UserFacingError -Message "存放新输入的位置不是一个文件夹: $InputRoot" `
        -Hint '把新版程序和说明文件放进产品文件夹下的 incoming/ 里，再重试。')
}

# FIX-1 (recursive engulfment guard). Registering from the product root must not
# swallow product-state/, otherwise every later intake re-preserves all previously
# preserved bundles and the input set grows without bound.
$stateRootTrimmed = $stateRoot.TrimEnd('\')
$inputTrimmed = $inputPath.TrimEnd('\')
if ($inputTrimmed -ieq $stateRootTrimmed -or
    $inputTrimmed.StartsWith($stateRootTrimmed + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw (New-UserFacingError -Message "新输入不能放在产品档案目录 product-state 里面: $InputRoot" `
        -Hint '把新版程序放进产品文件夹下的 incoming/，product-state 只保存已归档的事实。')
}
$excludePrefix = $stateRootTrimmed + '\'
$files = @(
    Get-ChildItem -LiteralPath $inputPath -Recurse -File -ErrorAction Stop |
        Where-Object {
            -not ($_.FullName.StartsWith($excludePrefix, [StringComparison]::OrdinalIgnoreCase))
        } |
        Sort-Object FullName
)
if ($files.Count -eq 0) {
    throw (New-UserFacingError -Message "这个位置里没有任何文件: $InputRoot" `
        -Hint '先把新版程序、安装包或说明文件放进去再登记。')
}

$sourceFingerprints = New-Object System.Collections.Generic.List[object]
foreach ($file in $files) {
    $relative = $file.FullName.Substring($inputPath.Length).TrimStart('\', '/').Replace('\', '/')
    $sourceFingerprints.Add([pscustomobject]@{
        relative_path = $relative
        size = [int64]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    })
}

$migrationRoot = Join-Path $stateRoot 'migrations'

# FIX-4 (TOCTOU). The idempotency scan, the immutability check and the manifest
# write must be one atomic section per product; otherwise two concurrent intakes
# can both pass the "not registered yet" check and the later writer wins.
$lockKey = $root.ToLowerInvariant()
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
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
        throw (New-UserFacingError -Message "另一个登记任务正在处理同一个产品，等待超时: $ProductRoot" `
            -Hint '等前一个登记结束后重试；同一个产品同一时间只能有一个登记在跑。')
    }

    if (Test-Path -LiteralPath $migrationRoot -PathType Container) {
        foreach ($existingManifest in @(Get-ChildItem -LiteralPath $migrationRoot -File -Filter '*-INPUT-MANIFEST.yaml')) {
            # FIX-5 (robustness). A truncated or empty manifest must not abort the
            # whole intake; treat it as "not a match" and keep scanning.
            $existingText = ''
            try { $existingText = Get-Content -Raw -Encoding UTF8 -LiteralPath $existingManifest.FullName }
            catch { continue }
            if ([string]::IsNullOrWhiteSpace($existingText)) { continue }

            # FIX-2. $matches is a PowerShell automatic variable; assigning to it
            # here silently collides with -match results elsewhere in the scope.
            $existingMatches = [regex]::Matches($existingText, '(?ms)^\s*-\s+relative_path:\s*["'']([^"'']+)["'']\s*$.*?^\s+size:\s*([0-9]+)\s*$.*?^\s+sha256:\s*["'']([0-9A-Fa-f]{64})["'']\s*$')
            if ($existingMatches.Count -ne $sourceFingerprints.Count) {
                continue
            }
            $sameBundle = $true
            foreach ($fingerprint in $sourceFingerprints) {
                $match = @($existingMatches | Where-Object {
                    $_.Groups[1].Value -eq $fingerprint.relative_path -and
                    [int64]$_.Groups[2].Value -eq $fingerprint.size -and
                    $_.Groups[3].Value.ToUpperInvariant() -eq $fingerprint.sha256
                }) | Select-Object -First 1
                if ($null -eq $match) {
                    $sameBundle = $false
                    break
                }
            }
            if ($sameBundle) {
                $existingBundleMatch = [regex]::Match($existingText, '(?m)^bundle_id:\s*["'']([^"'']+)["'']')
                [pscustomobject]@{
                    status = 'already_preserved'
                    product_root = $root
                    input_root = $inputPath
                    bundle_id = $(if ($existingBundleMatch.Success) { $existingBundleMatch.Groups[1].Value } else { 'UNVERIFIED' })
                    manifest = $existingManifest.FullName
                    inputs = $sourceFingerprints.Count
                } | ConvertTo-Json -Depth 5
                exit 0
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($BundleId)) {
        # FIX-3. A second-resolution stamp collides whenever two intakes land in the
        # same second. Milliseconds plus the process id keep the id unique without
        # changing its immutability or the idempotency contract above.
        $BundleId = 'incoming-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + $PID
    }

    $bundleRoot = Join-Path $stateRoot (Join-Path 'artifacts\incoming' $BundleId)
    $manifestPath = Join-Path $migrationRoot ($BundleId + '-INPUT-MANIFEST.yaml')
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        throw (New-UserFacingError -Message "批次编号「$BundleId」已经登记过，登记记录不可改写。" `
            -Hint '这是一批新输入就换一个新编号；不指定编号时系统会自动生成一个不重复的。')
    }
    New-Item -ItemType Directory -Force -Path $bundleRoot, $migrationRoot | Out-Null

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($inputPath.Length).TrimStart('\', '/')
        $destination = Join-Path $bundleRoot $relative
        $parent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $existingHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToUpperInvariant()
            $incomingHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($existingHash -ne $incomingHash) {
                throw (New-UserFacingError -Message "已保存的输入文件和这次交来的同名文件内容不同，拒绝覆盖: $destination" `
                    -Hint '换一个新的批次编号登记这批输入，已保存的原始文件必须原样保留。')
            }
        }
        else {
            Copy-Item -LiteralPath $file.FullName -Destination $destination
        }
        $records.Add([pscustomobject]@{
            relative_path = $relative.Replace('\', '/')
            source_path = $file.FullName.Replace('\', '/')
            preserved_path = ('product-state/artifacts/incoming/' + $BundleId + '/' + $relative.Replace('\', '/'))
            size = [int64]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        })
    }

    $lines = @(
        'schema_version: 1',
        ('product_id: ' + (ConvertTo-YamlScalar $productId)),
        ('bundle_id: ' + (ConvertTo-YamlScalar $BundleId)),
        ('product_root: ' + (ConvertTo-YamlScalar $root.Replace('\', '/'))),
        ('source_root: ' + (ConvertTo-YamlScalar $inputPath.Replace('\', '/'))),
        ('preserved_root: ' + (ConvertTo-YamlScalar ('product-state/artifacts/incoming/' + $BundleId))),
        ('received_at: ' + (ConvertTo-YamlScalar (Get-Date).ToString('o'))),
        'execution: "not run by input registration"',
        'status: "PRESERVED"',
        ('input_count: ' + ([string]$records.Count)),
        'inputs:'
    )
    foreach ($record in $records) {
        $lines += ('  - relative_path: ' + (ConvertTo-YamlScalar ([string]$record.relative_path)))
        $lines += ('    source_path: ' + (ConvertTo-YamlScalar ([string]$record.source_path)))
        $lines += ('    preserved_path: ' + (ConvertTo-YamlScalar ([string]$record.preserved_path)))
        $lines += ('    size: ' + ([string]$record.size))
        $lines += ('    sha256: ' + (ConvertTo-YamlScalar ([string]$record.sha256)))
    }
    $lines | Set-Content -LiteralPath $manifestPath -Encoding utf8

    [pscustomobject]@{
        status = 'preserved'
        product_root = $root
        input_root = $inputPath
        bundle_id = $BundleId
        manifest = $manifestPath
        inputs = $records.Count
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($lockHeld) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
