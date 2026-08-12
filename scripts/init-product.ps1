#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$')]
    [string]$ProductId,

    [Parameter(Mandatory = $true)]
    [string]$CorePath,

    [string]$ProductName,

    [string]$StartDocumentPath,

    [Alias('InputPaths', 'ReferenceDocuments')]
    [string[]]$AdditionalInputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

trap {
    Write-UserFacingFailure -Message $_.Exception.Message -ScriptName 'init-product.ps1' -ErrorRecord $_
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ProductName)) {
    $ProductName = $ProductId
}

if (-not (Test-Path -LiteralPath $ProductRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $ProductRoot | Out-Null
}
$root = (Resolve-Path -LiteralPath $ProductRoot).Path
$core = (Resolve-Path -LiteralPath $CorePath).Path
$scaffold = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\assets\product-scaffold')).Path

if (-not (Test-Path -LiteralPath $core -PathType Leaf)) {
    throw (New-UserFacingError -Message "指定的主程序不是一个文件: $CorePath" `
        -Hint '确认这个路径指向 EXE 本身，而不是它所在的文件夹。')
}

$stateRoot = Join-Path $root 'product-state'
$inputCoreHash = (Get-FileHash -LiteralPath $core -Algorithm SHA256).Hash.ToUpperInvariant()
$existingStatePath = Join-Path $stateRoot 'STATE.yaml'
$existingStateText = ''
if (Test-Path -LiteralPath $existingStatePath -PathType Leaf) {
    # Every field below is read with the shared tolerant reader. The old quoted-only regexes
    # rejected `product_id: foo` -- valid YAML that the validator accepts -- and the user saw a
    # PowerShell stack trace for a file the tooling itself considered healthy.
    $existingStateText = Read-TextFileSafe -Path $existingStatePath
    $existingProductId = Get-YamlScalar -Text $existingStateText -Key 'product_id'
    if ([string]::IsNullOrWhiteSpace($existingProductId)) {
        throw (New-UserFacingError -Message "这个文件夹里已有的产品档案读不出产品编号: $existingStatePath" `
            -Hint '打开该文件确认第一行附近有 product_id，或把这个 EXE 换到一个空文件夹重新接入。')
    }
    if ($existingProductId -ne $ProductId) {
        throw (New-UserFacingError -Message "这个文件夹已经属于产品「$existingProductId」，不是「$ProductId」。" `
            -Hint "继续维护原产品请改用产品编号 $existingProductId；这是另一个产品就换一个空文件夹。")
    }
    $existingBaseline = Get-YamlScalar -Text $existingStateText -Key 'baseline_sha256'
    if ($existingBaseline -notmatch '^[0-9A-Fa-f]{64}$') {
        throw (New-UserFacingError -Message "已有产品档案里的基线校验值不完整: $existingStatePath" `
            -Hint '这份档案可能被中断的写入损坏了，先恢复上一个可用备份再继续。')
    }
    if ($existingBaseline.ToUpperInvariant() -ne $inputCoreHash) {
        throw (New-UserFacingError -Message '这个文件夹已经用另一个程序建过档，不能用新程序覆盖它。' `
            -Hint '把新版程序放进 incoming/ 文件夹，然后按「更新到新版本」继续，原版本会被完整保留。')
    }
}

$externalDirs = @('incoming')
$stateDirs = @(
    'analysis', 'auth', 'release', 'migrations', 'reports', 'rollback', 'tooling', 'learning', 'learning\candidates',
    'artifacts', 'artifacts\upstream', 'artifacts\maintained', 'artifacts\patches',
    'artifacts\verification', 'artifacts\rollback', 'artifacts\incoming',
    'artifacts\quarantine', 'artifacts\reference-docs'
)
foreach ($relative in @($externalDirs) + @($stateDirs | ForEach-Object { Join-Path 'product-state' $_ })) {
    $path = Join-Path $root $relative
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

$createdFiles = New-Object System.Collections.Generic.List[string]
$scaffoldFiles = Get-ChildItem -LiteralPath $scaffold -Recurse -File
foreach ($file in $scaffoldFiles) {
    $relative = $file.FullName.Substring($scaffold.Length).TrimStart('\', '/')
    $destination = Join-Path $stateRoot $relative
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        $createdFiles.Add($destination)
    }
}

function Copy-PreservedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        if ($sourceHash -ne $destinationHash) {
            throw (New-UserFacingError -Message "已保存的原始文件和这次交来的同名文件内容不同，拒绝覆盖: $Destination" `
                -Hint '原始文件必须只读保留。把新文件放进 incoming/ 登记成新版本，不要替换已保存的基线。')
        }
        return
    }
    Copy-Item -LiteralPath $Source -Destination $Destination
}

$coreName = [IO.Path]::GetFileName($core)
$coreArtifact = Join-Path $stateRoot (Join-Path 'artifacts\upstream' $coreName)
Copy-PreservedFile -Source $core -Destination $coreArtifact
$baselineHash = $inputCoreHash
$baselineRelative = ('product-state/artifacts/upstream/' + $coreName.Replace('\', '/'))

$inputRecords = New-Object System.Collections.Generic.List[object]

# Kind must be derived, never defaulted. Labelling an installer or a DLL as a
# reference-document is not a cosmetic error: downstream steps read kind to
# decide what may be opened, diffed or shipped, so a wrong label is worse than
# the silent drop it replaces -- the record exists, so nobody goes looking.
$inputKindByExtension = @{
    '.md' = 'reference-document'; '.txt' = 'reference-document'; '.rtf' = 'reference-document'
    '.pdf' = 'reference-document'; '.doc' = 'reference-document'; '.docx' = 'reference-document'
    '.msi' = 'installer'; '.appx' = 'installer'; '.msix' = 'installer'
    '.exe' = 'executable'
    '.dll' = 'library'; '.so' = 'library'; '.dylib' = 'library'; '.pyd' = 'library'
    '.png' = 'screenshot'; '.jpg' = 'screenshot'; '.jpeg' = 'screenshot'
    '.gif' = 'screenshot'; '.bmp' = 'screenshot'; '.webp' = 'screenshot'
    '.zip' = 'archive'; '.7z' = 'archive'; '.rar' = 'archive'; '.tar' = 'archive'; '.gz' = 'archive'
    '.json' = 'configuration'; '.yaml' = 'configuration'; '.yml' = 'configuration'
    '.xml' = 'configuration'; '.ini' = 'configuration'; '.cfg' = 'configuration'
    '.config' = 'configuration'; '.toml' = 'configuration'
}

function Get-InputKind {
    param([Parameter(Mandatory = $true)][string]$Path)

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($inputKindByExtension.ContainsKey($extension)) {
        return $inputKindByExtension[$extension]
    }
    # An unknown extension is recorded as unclassified rather than guessed into
    # reference-document, so that "we do not know what this is" stays visible.
    return 'unclassified-input'
}

function Add-InputRecord {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$Kind,
        [bool]$Primary = $false
    )

    $resolved = (Resolve-Path -LiteralPath $SourcePath).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw (New-UserFacingError -Message "要登记的输入不是一个文件: $SourcePath" `
            -Hint '只登记具体文件；文件夹请逐个把里面的文件交过来，或整个放进 incoming/。')
    }
    $bucket = if ($Kind -eq 'reference-document') { 'artifacts\reference-docs' } else { 'artifacts\incoming' }
    $bucketRelative = $bucket.Replace('\', '/')
    $name = [IO.Path]::GetFileName($resolved)
    $destination = Join-Path $stateRoot (Join-Path $bucket $name)
    $hash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToUpperInvariant()
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($destinationHash -ne $hash) {
            $stem = [IO.Path]::GetFileNameWithoutExtension($name)
            $extension = [IO.Path]::GetExtension($name)
            $name = $stem + '-' + $hash.Substring(0, 12).ToLowerInvariant() + $extension
            $destination = Join-Path $stateRoot (Join-Path $bucket $name)
        }
    }
    Copy-PreservedFile -Source $resolved -Destination $destination
    $relative = 'product-state/' + $bucketRelative + '/' + $name.Replace('\', '/')
    $inputRecords.Add([pscustomobject]@{
        kind = $Kind
        source_path = $resolved.Replace('\', '/')
        preserved_path = $relative
        sha256 = $hash
        primary = $Primary
    })
}

$explicitDocuments = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($StartDocumentPath)) {
    $explicitDocuments.Add((Resolve-Path -LiteralPath $StartDocumentPath).Path)
}
foreach ($additional in @($AdditionalInputPath)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$additional)) {
        $explicitDocuments.Add((Resolve-Path -LiteralPath $additional).Path)
    }
}

# A host project may contain AGENTS/RULES files. They are instructions for the
# host, not product input, unless the user explicitly passes them.
$hostInstructionNames = @('AGENTS.md', 'CLAUDE.md', 'GEMINI.md', 'RULES.md', 'RULES_zh.md')

# Every top-level file is a candidate, not just *.md. The old filter dropped
# installers, DLLs, screenshots and .txt notes without saying so, which is the
# failure mode this whole round exists to remove: the user handed over five
# files, one got registered, and nothing reported the other four.
$skipReasons = [ordered]@{ 'host-instruction' = 0; 'core-executable' = 0; 'already-explicit' = 0 }
$coreFullPath = $core
$automaticInputs = New-Object System.Collections.Generic.List[string]
$scannedCandidates = 0
foreach ($candidate in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)) {
    $scannedCandidates++
    if ($hostInstructionNames -contains $candidate.Name) {
        $skipReasons['host-instruction']++
        continue
    }
    if ($candidate.FullName -ieq $coreFullPath) {
        # Already registered as the baseline executable; a second record would
        # make the same bytes look like two separate inputs.
        $skipReasons['core-executable']++
        continue
    }
    if (@($explicitDocuments) | Where-Object { $_ -ieq $candidate.FullName }) {
        $skipReasons['already-explicit']++
        continue
    }
    $automaticInputs.Add($candidate.FullName)
}

# Explicit input now ADDS to automatic discovery instead of switching it off.
# Naming one file was never a request to forget the rest of the folder.
$inputCandidates = New-Object System.Collections.Generic.List[string]
foreach ($item in @(@($explicitDocuments) + @($automaticInputs))) {
    if ([string]::IsNullOrWhiteSpace([string]$item)) {
        continue
    }
    $resolvedItem = (Resolve-Path -LiteralPath $item).Path
    if (-not (@($inputCandidates) | Where-Object { $_ -ieq $resolvedItem })) {
        $inputCandidates.Add($resolvedItem)
    }
}

# README is only de-prioritised for "which document is the starting point",
# never excluded from registration. Dropping it was losing an input to answer
# a question about ordering.
$documentCandidates = @($inputCandidates | Where-Object { (Get-InputKind -Path $_) -eq 'reference-document' })

$primaryDocument = $null
if ($explicitDocuments.Count -gt 0) {
    $primaryDocument = $explicitDocuments[0]
}
else {
    $preferred = @($documentCandidates | Where-Object { [IO.Path]::GetFileName($_) -ieq '00-START-HERE.md' })
    if ($preferred.Count -eq 0) {
        $preferred = @($documentCandidates | Where-Object { [IO.Path]::GetFileName($_) -match '(?i)(START|需求|requirement|brief)' })
    }
    if ($preferred.Count -eq 0) {
        $preferred = @($documentCandidates | Where-Object { [IO.Path]::GetFileName($_) -notmatch '^README(?:_[^.]*)?\.md$' })
    }
    if ($preferred.Count -gt 0) {
        $primaryDocument = $preferred[0]
    }
    elseif ($documentCandidates.Count -gt 0) {
        $primaryDocument = $documentCandidates[0]
    }
}

foreach ($item in $inputCandidates) {
    $kind = Get-InputKind -Path $item
    Add-InputRecord -SourcePath $item -Kind $kind -Primary ($null -ne $primaryDocument -and $item -ieq $primaryDocument)
}

$startRelative = 'UNVERIFIED'
$primaryRecord = @($inputRecords | Where-Object { $_.primary -eq $true }) | Select-Object -First 1
if ($null -ne $primaryRecord) {
    $startRelative = [string]$primaryRecord.preserved_path
}
if (-not [string]::IsNullOrWhiteSpace($existingStateText)) {
    $existingIndexPath = Join-Path $stateRoot 'PRODUCT-INDEX.md'
    if (Test-Path -LiteralPath $existingIndexPath -PathType Leaf) {
        $existingIndexText = Get-Content -Raw -Encoding UTF8 -LiteralPath $existingIndexPath
        $existingStartMatch = [regex]::Match($existingIndexText, '(?m)^- 首次说明文件:\s*`([^`]+)`')
        if ($existingStartMatch.Success) {
            $startRelative = $existingStartMatch.Groups[1].Value
        }
    }
}

$date = Get-Date -Format 'yyyy-MM-dd'
$replacements = @{
    '__PRODUCT_ID__' = $ProductId
    '__PRODUCT_NAME__' = $ProductName
    '__BASELINE_ARTIFACT__' = $baselineRelative
    '__BASELINE_SHA256__' = $baselineHash
    '__CORE_FILE__' = $coreName
    '__START_DOCUMENT__' = $startRelative
    '__DATE__' = $date
}
foreach ($file in $createdFiles) {
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $file
    foreach ($key in $replacements.Keys) {
        $text = $text.Replace($key, [string]$replacements[$key])
    }
    $text | Set-Content -LiteralPath $file -Encoding utf8
}

$baselineManifest = Join-Path $stateRoot 'artifacts\BASELINE-MANIFEST.yaml'
if (-not (Test-Path -LiteralPath $baselineManifest -PathType Leaf)) {
    @(
        'schema_version: 1',
        ('product_id: "' + $ProductId + '"'),
        ('artifact_path: "' + $baselineRelative + '"'),
        ('source_path: "' + $core.Replace('\', '/') + '"'),
        ('sha256: "' + $baselineHash + '"'),
        ('received_at: "' + $date + '"'),
        'preservation: "copy kept separate from customized output"'
    ) | Set-Content -LiteralPath $baselineManifest -Encoding utf8
}

$inputManifest = Join-Path $stateRoot 'artifacts\INPUT-MANIFEST.yaml'
if (-not (Test-Path -LiteralPath $inputManifest -PathType Leaf)) {
    $manifestLines = @(
        'schema_version: 2',
        ('product_id: ' + (ConvertTo-YamlScalar $ProductId)),
        ('received_at: ' + (ConvertTo-YamlScalar $date)),
        'execution: "not run by initialization script"',
        'inputs:',
        ('  - kind: "executable"'),
        ('    source_path: ' + (ConvertTo-YamlScalar $core.Replace('\', '/'))),
        ('    preserved_path: ' + (ConvertTo-YamlScalar $baselineRelative)),
        ('    sha256: ' + (ConvertTo-YamlScalar $baselineHash)),
        '    primary: true'
    )
    foreach ($record in $inputRecords) {
        $manifestLines += ('  - kind: ' + (ConvertTo-YamlScalar ([string]$record.kind)))
        $manifestLines += ('    source_path: ' + (ConvertTo-YamlScalar ([string]$record.source_path)))
        $manifestLines += ('    preserved_path: ' + (ConvertTo-YamlScalar ([string]$record.preserved_path)))
        $manifestLines += ('    sha256: ' + (ConvertTo-YamlScalar ([string]$record.sha256)))
        $manifestLines += ('    primary: ' + $(if ($record.primary) { 'true' } else { 'false' }))
    }
    $manifestLines | Set-Content -LiteralPath $inputManifest -Encoding utf8
}
else {
    # Re-running intake is not a new product initialization. If the caller
    # explicitly adds a document, merge only new preserved records so the
    # product input manifest cannot silently lag behind reference-docs.
    $existingManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $inputManifest
    foreach ($record in $inputRecords) {
        $preservedPath = [string]$record.preserved_path
        if ($existingManifest -match [regex]::Escape($preservedPath)) {
            continue
        }
        @(
            ('  - kind: ' + (ConvertTo-YamlScalar ([string]$record.kind))),
            ('    source_path: ' + (ConvertTo-YamlScalar ([string]$record.source_path))),
            ('    preserved_path: ' + (ConvertTo-YamlScalar $preservedPath)),
            ('    sha256: ' + (ConvertTo-YamlScalar ([string]$record.sha256))),
            ('    primary: ' + $(if ($record.primary) { 'true' } else { 'false' }))
        ) | Add-Content -LiteralPath $inputManifest -Encoding utf8
        $existingManifest += "`n$preservedPath"
    }
}

$kindCounts = [ordered]@{}
foreach ($record in $inputRecords) {
    $k = [string]$record.kind
    if (-not $kindCounts.Contains($k)) { $kindCounts[$k] = 0 }
    $kindCounts[$k]++
}

# Coverage is reported, not just the verdict. "Scanned N, registered M,
# skipped K and here is why" is what makes a silent drop impossible to
# repeat: a caller who handed over five files can now see all five accounted
# for without having to go and count the folder themselves.
[pscustomobject]@{
    status = 'initialized'
    product_id = $ProductId
    product_root = $root
    baseline_artifact = $baselineRelative
    baseline_sha256 = $baselineHash
    start_document = $startRelative
    reference_documents = @($inputRecords | Where-Object { $_.kind -eq 'reference-document' }).Count
    created_template_files = $createdFiles.Count
    scanned_top_level_files = $scannedCandidates
    explicit_inputs = $explicitDocuments.Count
    registered_inputs = $inputRecords.Count
    registered_by_kind = $kindCounts
    skipped_inputs = ($skipReasons.Values | Measure-Object -Sum).Sum
    skipped_reasons = $skipReasons
    unclassified_inputs = @($inputRecords | Where-Object { $_.kind -eq 'unclassified-input' }).Count
} | ConvertTo-Json -Depth 4
