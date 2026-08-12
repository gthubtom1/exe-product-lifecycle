#requires -Version 5

<#
Static protection assessment for a target binary.

    detect-protections.ps1 -ProductRoot <path> [-TargetPath <file>]

Answers three questions before anyone tries to modify the target:
  1. what is it written in           (DIE compiler/linker/tool signatures)
  2. is it packed or encrypted       (DIE packer signatures + section entropy)
  3. will it fight being modified    (anti-debug strings, self-check hints, code signature)

and turns those into a modifiability verdict that the maintenance strategy depends on. Whether the
target can be patched, only wrapped, or must be rebuilt is not a preference -- it is decided by
what protects it, and guessing that answer is how a "bypass the license" patch silently bricks the
core.

STATIC ONLY. The target is never executed: DIE reads the file, entropy is computed from bytes,
strings scans bytes, and the signature check is Get-AuthenticodeSignature. Nothing here runs the
unknown binary, matching the skill's evidence rules.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,

    [string]$TargetPath,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

trap {
    Write-UserFacingFailure -Message $_.Exception.Message -ScriptName 'detect-protections.ps1' -ErrorRecord $_
    exit 1
}

$root = (Resolve-Path -LiteralPath $ProductRoot).Path
$stateRoot = Join-Path $root 'product-state'
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    throw (New-UserFacingError -Message "这个文件夹还没有产品档案: $ProductRoot" `
        -Hint '先做一次首次接入建立档案，再探测保护机制。')
}
$analysisRoot = Join-Path $stateRoot 'analysis'
New-Item -ItemType Directory -Force -Path $analysisRoot | Out-Null

$profilePath = Join-Path $stateRoot 'PROTECTION-PROFILE.yaml'
$existingStatus = ''
if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    $existingStatus = Get-YamlScalar -Text (Read-TextFileSafe -Path $profilePath) -Key 'status'
}
if ($existingStatus -eq 'ASSESSED' -and -not $Force) {
    throw (New-UserFacingError -Message '保护机制已经探测过（status: ASSESSED）。' `
        -Hint '要重新探测请加 -Force；否则直接读取现有 PROTECTION-PROFILE.yaml。')
}

# --- locate the target ----------------------------------------------------------------------
$stateText = Read-TextFileSafe -Path (Join-Path $stateRoot 'STATE.yaml')
if ([string]::IsNullOrWhiteSpace($TargetPath)) {
    $baselineRelative = Get-YamlScalar -Text $stateText -Key 'baseline_artifact'
    if (-not [string]::IsNullOrWhiteSpace($baselineRelative)) {
        $candidate = Join-Path $root ($baselineRelative.Replace('/', '\'))
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $TargetPath = $candidate }
    }
}
if ([string]::IsNullOrWhiteSpace($TargetPath) -or -not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
    throw (New-UserFacingError -Message '找不到要探测的目标程序。' `
        -Hint '用 -TargetPath 指定 EXE，或确认 STATE.yaml 里 baseline_artifact 指向的文件还在。')
}
$target = (Resolve-Path -LiteralPath $TargetPath).Path

# --- find DIE from the tool inventory -------------------------------------------------------
function Get-InventoryToolPath {
    param([string[]]$PreferLeaf)

    $jsonPath = Join-Path $stateRoot 'tooling\TOOL-INVENTORY.json'
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { return '' }
    try { $inv = Read-TextFileSafe -Path $jsonPath | ConvertFrom-Json } catch { return '' }
    foreach ($row in @($inv.tools)) {
        $rowPath = [string](Get-PropertyValue $row 'path' '')
        if ([string]::IsNullOrWhiteSpace($rowPath)) { continue }
        $leaf = [IO.Path]::GetFileName($rowPath)
        if ($PreferLeaf -contains $leaf -and (Test-Path -LiteralPath $rowPath -PathType Leaf)) { return $rowPath }
    }
    return ''
}

# diec.exe is the command-line build; die.exe is the GUI and would hang. Prefer the console one and
# derive it from the discovered die.exe if only that was recorded.
$diePath = Get-InventoryToolPath -PreferLeaf @('diec.exe')
if ([string]::IsNullOrWhiteSpace($diePath)) {
    $dieGui = Get-InventoryToolPath -PreferLeaf @('die.exe', 'Detect-It-Easy.exe')
    if (-not [string]::IsNullOrWhiteSpace($dieGui)) {
        $sibling = Join-Path (Split-Path -Parent $dieGui) 'diec.exe'
        if (Test-Path -LiteralPath $sibling -PathType Leaf) { $diePath = $sibling }
    }
}
$stringsPath = Get-InventoryToolPath -PreferLeaf @('strings.exe', 'strings64.exe')

$notes = New-Object System.Collections.Generic.List[string]

# --- packer / compiler via DIE --------------------------------------------------------------
$packer = 'unknown'
$languageFramework = 'UNVERIFIED'
$fileFormat = 'UNVERIFIED'
$dieText = ''
if (-not [string]::IsNullOrWhiteSpace($diePath)) {
    try { $dieText = (& $diePath $target 2>&1 | ForEach-Object { [string]$_ }) -join "`n" } catch { $dieText = '' }
    if (-not [string]::IsNullOrWhiteSpace($dieText)) {
        Set-Content -LiteralPath (Join-Path $analysisRoot 'die-detection.txt') -Value $dieText -Encoding utf8
        $firstLine = @($dieText -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[0]
        if (-not [string]::IsNullOrWhiteSpace($firstLine)) { $fileFormat = $firstLine.Trim() }
        $compilerMatch = [regex]::Match($dieText, '(?im)^\s*(Compiler|Language):\s*(.+)$')
        if ($compilerMatch.Success) { $languageFramework = $compilerMatch.Groups[2].Value.Trim() }
        # A protector/packer line is the signal that the real code is hidden.
        $protectorMatch = [regex]::Match($dieText, '(?im)^\s*(Protector|Packer):\s*(.+)$')
        if ($protectorMatch.Success) {
            $packer = $protectorMatch.Groups[2].Value.Trim()
            $notes.Add("DIE 报告保护器/加壳器: $packer")
        }
        else {
            $packer = 'none-detected'
        }
    }
}
else {
    $notes.Add('未发现 DIE(diec.exe)，加壳与编译器判断降级为仅靠熵。先运行 discover-tools.ps1 -ReuseInventory 或安装 Detect It Easy。')
}

# --- entropy via DIE JSON -------------------------------------------------------------------
$entropyTotal = 'UNVERIFIED'
$packedSections = New-Object System.Collections.Generic.List[string]
$packedStatus = ''
if (-not [string]::IsNullOrWhiteSpace($diePath)) {
    $entropyJson = ''
    try { $entropyJson = (& $diePath -j -e $target 2>&1 | ForEach-Object { [string]$_ }) -join "`n" } catch { $entropyJson = '' }
    if (-not [string]::IsNullOrWhiteSpace($entropyJson)) {
        try {
            $parsed = $entropyJson | ConvertFrom-Json
            $entropyTotal = [string](Get-PropertyValue $parsed 'total' 'UNVERIFIED')
            $packedStatus = [string](Get-PropertyValue $parsed 'status' '')
            foreach ($rec in @(Get-PropertyValue $parsed 'records' @())) {
                $recStatus = [string](Get-PropertyValue $rec 'status' '')
                # DIE reports "not packed" for clean sections, and a bare 'packed' regex matches the
                # substring inside "not packed" -- so a clean binary read as fully packed. Exclude
                # the negated form explicitly.
                if ($recStatus -match '(?i)packed' -and $recStatus -notmatch '(?i)not\s*packed') {
                    [void]$packedSections.Add([string](Get-PropertyValue $rec 'name' '?'))
                }
            }
        }
        catch {
            $notes.Add('DIE 熵结果不是有效 JSON，已跳过熵解析。')
        }
    }
}
# A high total entropy is corroborating evidence even when no packer signature matched: custom or
# unknown packers show up as entropy long before they show up as a named signature.
$entropyHigh = $false
$entropyValue = 0.0
if ([double]::TryParse([string]$entropyTotal, [ref]$entropyValue) -and $entropyValue -gt 7.2) {
    $entropyHigh = $true
    $notes.Add("总熵 $([math]::Round($entropyValue,2)) 偏高（>7.2），即使没有已知加壳签名也要按可能加密/加壳处理。")
}

# --- anti-debug / self-check strings --------------------------------------------------------
$antiDebug = 'unknown'
$selfCheck = 'unknown'
$stringsBlob = ''
if (-not [string]::IsNullOrWhiteSpace($stringsPath)) {
    try { $stringsBlob = (& $stringsPath -n 6 $target 2>&1 | ForEach-Object { [string]$_ }) -join "`n" } catch { $stringsBlob = '' }
}
if ([string]::IsNullOrWhiteSpace($stringsBlob)) {
    # Fall back to the printable-ASCII runs in the file itself, so the check still runs without
    # Sysinternals strings. Capped so a huge binary does not blow up memory.
    try {
        $bytes = [System.IO.File]::ReadAllBytes($target)
        if ($bytes.Length -gt 0) {
            $limit = [Math]::Min($bytes.Length, 8MB)
            $sb = New-Object System.Text.StringBuilder
            $run = New-Object System.Text.StringBuilder
            for ($i = 0; $i -lt $limit; $i++) {
                $b = $bytes[$i]
                if ($b -ge 32 -and $b -lt 127) { [void]$run.Append([char]$b) }
                else {
                    if ($run.Length -ge 6) { [void]$sb.AppendLine($run.ToString()) }
                    [void]$run.Clear()
                }
            }
            # Flush the trailing run: a marker at the very end of the scanned region, with no
            # non-printable byte after it to close the run, would otherwise be silently dropped --
            # and a dropped anti-debug/self-check marker reads back as a falsely optimistic verdict.
            if ($run.Length -ge 6) { [void]$sb.AppendLine($run.ToString()) }
            $stringsBlob = $sb.ToString()
        }
    }
    catch { $stringsBlob = '' }
}
if (-not [string]::IsNullOrWhiteSpace($stringsBlob)) {
    $antiDebugMarkers = @('IsDebuggerPresent', 'CheckRemoteDebuggerPresent', 'NtQueryInformationProcess', 'OutputDebugString', 'NtSetInformationThread', 'DebugActiveProcess')
    $hitDebug = @($antiDebugMarkers | Where-Object { $stringsBlob -match [regex]::Escape($_) })
    $antiDebug = if ($hitDebug.Count -gt 0) { 'yes' } else { 'no' }
    if ($hitDebug.Count -gt 0) { $notes.Add('发现反调试相关 API: ' + ($hitDebug -join ', ')) }
    $selfCheckMarkers = @('CryptHashData', 'CheckSumMappedFile', 'MapFileAndCheckSum', 'WinVerifyTrust', 'RtlComputeCrc32')
    $hitSelf = @($selfCheckMarkers | Where-Object { $stringsBlob -match [regex]::Escape($_) })
    $selfCheck = if ($hitSelf.Count -gt 0) { 'yes' } else { 'unknown' }
    if ($hitSelf.Count -gt 0) { $notes.Add('发现可能的完整性/自校验 API: ' + ($hitSelf -join ', ')) }
}

# --- code signature (built-in, static) ------------------------------------------------------
$codeSigning = 'unknown'
$signatureSubject = 'UNVERIFIED'
try {
    $sig = Get-AuthenticodeSignature -LiteralPath $target
    if ($null -ne $sig) {
        if ([string]$sig.Status -eq 'Valid') {
            $codeSigning = 'signed'
            if ($null -ne $sig.SignerCertificate) { $signatureSubject = [string]$sig.SignerCertificate.Subject }
        }
        elseif ([string]$sig.Status -eq 'NotSigned') { $codeSigning = 'unsigned' }
        else {
            $codeSigning = 'invalid'
            $notes.Add("数字签名状态: $($sig.Status)（可能已被篡改或证书链不完整）。")
        }
    }
}
catch { $codeSigning = 'unknown' }
if ($codeSigning -eq 'signed') {
    $notes.Add('目标已数字签名：任何二进制修改都会使签名失效，替换或去除签名要单独记录并评估影响。')
}

# --- modifiability verdict ------------------------------------------------------------------
# The decision tree that turns the evidence above into the one strategy-defining verdict lives in
# Get-ModifiabilityVerdict (lib\product-state-common.ps1), so it can be unit-tested without DIE or a
# real target -- an untested verdict is how a packed binary silently gets a "just patch it" plan.
# The packed-status read stays here because it depends on DIE's raw entropy JSON.
$statusSaysPacked = ($packedStatus -match '(?i)packed') -and ($packedStatus -notmatch '(?i)not\s*packed')
$verdictResult = Get-ModifiabilityVerdict -Packer $packer -EntropyTotal $entropyValue -StatusSaysPacked $statusSaysPacked -AntiDebug $antiDebug -SelfCheck $selfCheck -CodeSigning $codeSigning -FileFormat $fileFormat -LanguageFramework $languageFramework
$verdict = $verdictResult.Verdict
$reason = $verdictResult.Reason
$hardening = $verdictResult.Hardening
if ($verdict -eq 'WRAPPER_ONLY') {
    $notes.Add('加壳目标再加壳几乎必然冲突，加固应针对外壳 Launcher，不要对核心二次加壳。')
}

# --- write the profile ----------------------------------------------------------------------
function Format-YamlList {
    param([string]$Key, [string[]]$Items, [int]$Indent = 0)
    $pad = ' ' * $Indent
    if ($null -eq $Items -or @($Items).Count -eq 0) { return @($pad + $Key + ': []') }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add($pad + $Key + ':')
    foreach ($item in $Items) { [void]$lines.Add($pad + '  - ' + (ConvertTo-YamlScalar $item)) }
    return $lines.ToArray()
}

$productId = Get-YamlScalar -Text $stateText -Key 'product_id'
$targetRelative = $target
if ($target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    $targetRelative = $target.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
}

$lines = New-Object System.Collections.Generic.List[string]
[void]$lines.Add('schema_version: 1')
[void]$lines.Add('product_id: ' + (ConvertTo-YamlScalar $productId))
[void]$lines.Add('status: "ASSESSED"')
[void]$lines.Add('assessed_at: ' + (ConvertTo-YamlScalar (Get-Date -Format 'yyyy-MM-dd')))
[void]$lines.Add('target_file: ' + (ConvertTo-YamlScalar $targetRelative))
[void]$lines.Add('file_format: ' + (ConvertTo-YamlScalar $fileFormat))
[void]$lines.Add('language_framework: ' + (ConvertTo-YamlScalar $languageFramework))
[void]$lines.Add('packing:')
[void]$lines.Add('  detector: ' + (ConvertTo-YamlScalar $(if ([string]::IsNullOrWhiteSpace($diePath)) { 'entropy-only' } else { 'DIE' })))
[void]$lines.Add('  packer: ' + (ConvertTo-YamlScalar $packer))
[void]$lines.Add('  entropy_total: ' + (ConvertTo-YamlScalar ([string]$entropyTotal)))
foreach ($line in (Format-YamlList -Key 'packed_sections' -Items $packedSections.ToArray() -Indent 2)) { [void]$lines.Add($line) }
[void]$lines.Add('protections:')
[void]$lines.Add('  self_integrity_check: ' + (ConvertTo-YamlScalar $selfCheck))
[void]$lines.Add('  anti_debug: ' + (ConvertTo-YamlScalar $antiDebug))
[void]$lines.Add('  anti_vm: ' + (ConvertTo-YamlScalar 'unknown'))
[void]$lines.Add('  code_signing: ' + (ConvertTo-YamlScalar $codeSigning))
[void]$lines.Add('  signature_subject: ' + (ConvertTo-YamlScalar $signatureSubject))
[void]$lines.Add('  license_check_surface: ' + (ConvertTo-YamlScalar 'UNVERIFIED'))
[void]$lines.Add('modifiability:')
[void]$lines.Add('  verdict: ' + (ConvertTo-YamlScalar $verdict))
[void]$lines.Add('  reason: ' + (ConvertTo-YamlScalar $reason))
[void]$lines.Add('  hardening_feasible: ' + (ConvertTo-YamlScalar $hardening))
[void]$lines.Add('  hardening_notes: ' + (ConvertTo-YamlScalar 'UNVERIFIED'))
foreach ($line in (Format-YamlList -Key 'evidence_refs' -Items @('product-state/analysis/die-detection.txt') -Indent 0)) { [void]$lines.Add($line) }
foreach ($line in (Format-YamlList -Key 'notes' -Items $notes.ToArray() -Indent 0)) { [void]$lines.Add($line) }
[void]$lines.Add('open_questions: []')
[void]$lines.Add('source_of_truth: "product-state/PROTECTION-PROFILE.yaml plus analysis/ evidence"')

Write-FileAtomic -Path $profilePath -Content ($lines -join [Environment]::NewLine)

[pscustomobject]@{
    status = 'assessed'
    product_root = $root
    target = $targetRelative
    file_format = $fileFormat
    language_framework = $languageFramework
    packer = $packer
    entropy_total = $entropyTotal
    anti_debug = $antiDebug
    self_integrity_check = $selfCheck
    code_signing = $codeSigning
    modifiability = $verdict
    hardening_feasible = $hardening
    profile = 'product-state/PROTECTION-PROFILE.yaml'
    die_used = (-not [string]::IsNullOrWhiteSpace($diePath))
} | ConvertTo-Json -Depth 4
