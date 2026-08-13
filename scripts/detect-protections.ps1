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

    [switch]$Force,

    # RV-R4 M1: refuse to execute ANY discovered analysis tool (even PATH-installed) whose Authenticode
    # signature is not Valid. Stricter than the default F1 gate below; hardens the box end to end.
    [switch]$RequireSignedTools,

    # RV F1: by DEFAULT, a tool located by scanning the disk (source=fallback-search) that is NOT validly
    # signed is refused execution -- planting an unsigned diec.exe/strings.exe in a scanned directory is
    # the demonstrated risk. This switch is the explicit "I trust this unsigned, disk-discovered tool"
    # override. Tools resolved from PATH / the registry (deliberately installed) still run either way.
    [switch]$AllowUnsignedDiscoveredTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

trap {
    Write-UserFacingFailure -Message $_.Exception.Message -ScriptName 'detect-protections.ps1' -ErrorRecord $_
    exit 1
}

function Approve-DiscoveredTool {
    # RV-R4 M1: DIE/strings are discovered by scanning the disk and then EXECUTED. Nothing verified the
    # binary first, so a malicious diec.exe/strings.exe planted in a scanned directory would run with
    # the user's rights. Record every tool's path + sha256 + Authenticode status (so a swapped tool is
    # visible in the evidence), and under -RequireSignedTools refuse to run one whose signature is not
    # Valid. A determined attacker can still plant an unsigned tool; requiring a signature by default
    # would break legitimate unsigned tools, so the hard gate is opt-in and the record is always kept.
    param(
        [AllowEmptyString()][string]$ToolPath,
        [Parameter(Mandatory = $true)][string]$Purpose,
        [AllowEmptyString()][string]$Source,
        [bool]$RequireSigned,
        [bool]$AllowUnsignedDiscovered,
        [Parameter(Mandatory = $true)]$Notes
    )

    if ([string]::IsNullOrWhiteSpace($ToolPath) -or -not (Test-Path -LiteralPath $ToolPath -PathType Leaf)) { return '' }
    $toolHash = (Get-FileHash -LiteralPath $ToolPath -Algorithm SHA256).Hash
    $sigStatus = 'unknown'
    try { $sigStatus = [string](Get-AuthenticodeSignature -LiteralPath $ToolPath).Status } catch { $sigStatus = 'unknown' }
    $sourceLabel = if ([string]::IsNullOrWhiteSpace($Source)) { 'unknown' } else { $Source }
    [void]$Notes.Add("将执行分析工具 ${Purpose}: $ToolPath（来源 $sourceLabel, 签名状态 $sigStatus, sha256 $toolHash）")
    if ($RequireSigned -and $sigStatus -ne 'Valid') {
        [void]$Notes.Add("已按 -RequireSignedTools 跳过未通过签名校验的工具（签名状态 $sigStatus）: $ToolPath")
        return ''
    }
    # RV F1: a disk-scanned (fallback-search) tool that is not validly signed is the planted-binary risk;
    # refuse it by default. PATH/registry-sourced tools are deliberately installed and still run.
    if ($sourceLabel -eq 'fallback-search' -and $sigStatus -ne 'Valid' -and -not $AllowUnsignedDiscovered) {
        [void]$Notes.Add("已默认跳过磁盘扫描发现、且未通过签名校验的工具（来源 fallback-search, 签名状态 $sigStatus）: $ToolPath。确认可信可加 -AllowUnsignedDiscoveredTools 显式放行；或把工具装到 PATH。")
        return ''
    }
    return $ToolPath
}

$root = Resolve-CanonicalPath -Path (Resolve-Path -LiteralPath $ProductRoot).Path
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
$target = Resolve-CanonicalPath -Path (Resolve-Path -LiteralPath $TargetPath).Path

# --- find DIE from the tool inventory -------------------------------------------------------
function Get-InventoryTool {
    param([string[]]$PreferLeaf)

    $empty = [pscustomobject]@{ Path = ''; Source = '' }
    $jsonPath = Join-Path $stateRoot 'tooling\TOOL-INVENTORY.json'
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { return $empty }
    try { $inv = Read-TextFileSafe -Path $jsonPath | ConvertFrom-Json } catch { return $empty }
    foreach ($row in @($inv.tools)) {
        $rowPath = [string](Get-PropertyValue $row 'path' '')
        if ([string]::IsNullOrWhiteSpace($rowPath)) { continue }
        $leaf = [IO.Path]::GetFileName($rowPath)
        if ($PreferLeaf -contains $leaf -and (Test-Path -LiteralPath $rowPath -PathType Leaf)) {
            return [pscustomobject]@{ Path = $rowPath; Source = [string](Get-PropertyValue $row 'source' '') }
        }
    }
    return $empty
}

# diec.exe is the command-line build; die.exe is the GUI and would hang. Prefer the console one and
# derive it from the discovered die.exe if only that was recorded.
$dieTool = Get-InventoryTool -PreferLeaf @('diec.exe')
$diePath = $dieTool.Path
$dieSource = $dieTool.Source
if ([string]::IsNullOrWhiteSpace($diePath)) {
    $dieGuiTool = Get-InventoryTool -PreferLeaf @('die.exe', 'Detect-It-Easy.exe')
    if (-not [string]::IsNullOrWhiteSpace($dieGuiTool.Path)) {
        $sibling = Join-Path (Split-Path -Parent $dieGuiTool.Path) 'diec.exe'
        # A sibling derived from a disk path is treated as disk-discovered for the F1 signature gate.
        if (Test-Path -LiteralPath $sibling -PathType Leaf) { $diePath = $sibling; $dieSource = 'fallback-search' }
    }
}
$stringsTool = Get-InventoryTool -PreferLeaf @('strings.exe', 'strings64.exe')
$stringsPath = $stringsTool.Path
$stringsSource = $stringsTool.Source

$notes = New-Object System.Collections.Generic.List[string]

# RV-R4 M1 + F1: verify + record each discovered tool before it is executed below; refuse unsigned
# disk-discovered tools by default (see Approve-DiscoveredTool).
$diePath = Approve-DiscoveredTool -ToolPath $diePath -Purpose 'DIE(加壳/编译器识别)' -Source $dieSource -RequireSigned:$RequireSignedTools -AllowUnsignedDiscovered:$AllowUnsignedDiscoveredTools -Notes $notes
$stringsPath = Approve-DiscoveredTool -ToolPath $stringsPath -Purpose 'strings(字符串扫描)' -Source $stringsSource -RequireSigned:$RequireSignedTools -AllowUnsignedDiscovered:$AllowUnsignedDiscoveredTools -Notes $notes

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
# Q1 before everything else: installer names arrive on the same DIE Protector/Packer line as real
# packers, so without this reclassification a setup package reads as WRAPPER_ONLY at best and as a
# patchable product at worst -- the one misroute that ships successfully with nothing changed.
$containerKind = Get-ContainerKind -Packer $packer -TargetName $target
$verdictResult = Get-ModifiabilityVerdict -Packer $packer -EntropyTotal $entropyValue -StatusSaysPacked $statusSaysPacked -AntiDebug $antiDebug -SelfCheck $selfCheck -CodeSigning $codeSigning -FileFormat $fileFormat -LanguageFramework $languageFramework -ContainerKind $containerKind
$verdict = $verdictResult.Verdict
$reason = $verdictResult.Reason
$hardening = $verdictResult.Hardening
$reEnter = $(if ($verdictResult.ReEnter) { 'yes' } else { 'no' })
$deadEndCondition = [string]$verdictResult.DeadEndCondition
if ([string]::IsNullOrWhiteSpace($deadEndCondition)) { $deadEndCondition = 'none' }
if ($verdict -eq 'WRAPPER_ONLY') {
    $notes.Add('加壳目标再加壳几乎必然冲突，加固应针对外壳 Launcher，不要对核心二次加壳。')
}
if ($verdict -eq 'CONTAINER') {
    $notes.Add('容器分支：先解开容器取出真正的产品 exe，再对它重新运行 detect-protections.ps1 重新路由。此刻登记的任何本体层（payload）分析发现都还看不到本体。')
}
if ($reEnter -eq 'yes') {
    $notes.Add('本判定可重入：解开/脱壳后请对解出来的目标从头重新路由，不要在当前判定上继续往下做。')
}
if ($deadEndCondition -ne 'none') {
    $notes.Add('死路判据（需连着定制需求一起判，不要只看目标）: ' + $deadEndCondition)
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
# re_enter says whether this verdict is terminal. The findings gate reads verdict; a human reads
# these two to know whether to open the thing and ask again, and what would actually count as stop.
[void]$lines.Add('  container_kind: ' + (ConvertTo-YamlScalar $containerKind))
[void]$lines.Add('  re_enter: ' + (ConvertTo-YamlScalar $reEnter))
[void]$lines.Add('  dead_end_condition: ' + (ConvertTo-YamlScalar $deadEndCondition))
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
