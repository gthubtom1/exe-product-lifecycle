#requires -Version 5

<#
Negative-path regression for the protection assessment -- the verdict that decides whether a target
can be patched, only wrapped, or nothing yet.

    powershell -NoProfile -ExecutionPolicy Bypass -File test-detect-protections.ps1

Why this suite exists: detect-protections.ps1 was covered only by "the profile parsed and the
verdict is one of the legal enum values" (P2 in the gate suite). That assertion stays green when the
decision tree is broken -- flip 加壳->WRAPPER_ONLY into 加壳->CAN_PATCH and CAN_PATCH is still a
legal value, so nothing fires. The one decision the whole maintenance strategy hangs on had no test
that made a wrong verdict red. Each unit case below pins one branch by asserting the exact verdict a
given evidence shape must produce, so breaking that branch turns this suite red. The end-to-end cases
prove the same tree still drives the real script's signal-extraction and profile write without DIE.

Everything runs statically: the pure function touches no file, and the end-to-end fixtures are inert
bytes under $env:TEMP that are never executed.
#>

[CmdletBinding()]
param(
    [string]$SkillRoot,
    [string]$FixtureRoot = (Join-Path $env:TEMP ('eplc-protect-suite-' + [guid]::NewGuid().ToString('N').Substring(0, 8))),
    [switch]$KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$script:Skill = (Resolve-Path -LiteralPath $SkillRoot).Path
$script:Results = New-Object System.Collections.Generic.List[psobject]
New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null

. (Join-Path $script:Skill 'scripts\lib\product-state-common.ps1')

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Expected, [string]$Actual)

    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Expected = $Expected; Actual = $Actual })
    $label = 'FAIL'
    if ($Passed) { $label = 'PASS' }
    Write-Output ('{0}   {1,-42} expected[{2}] actual[{3}]' -f $label, $Name, $Expected, $Actual)
}

function Assert-Verdict {
    param([string]$Name, $Result, [string]$ExpectedVerdict)

    $actual = if ($null -ne $Result) { [string]$Result.Verdict } else { '(null)' }
    Add-Result -Name $Name -Passed ($actual -eq $ExpectedVerdict) -Expected $ExpectedVerdict -Actual $actual
}

function Assert-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)

    Add-Result -Name $Name -Passed ($Expected -eq $Actual) -Expected $Expected -Actual $Actual
}

function Assert-Match {
    param([string]$Name, [string]$Text, [string]$Pattern, [switch]$Absent)

    $found = [regex]::IsMatch($Text, $Pattern)
    $want = -not $Absent.IsPresent
    $shown = if ($found) { 'present' } else { 'absent' }
    $wantShown = if ($want) { 'present' } else { 'absent' }
    Add-Result -Name $Name -Passed ($found -eq $want) -Expected $wantShown -Actual $shown
}

function Invoke-Script {
    param([Parameter(Mandatory = $true)][string]$Name, [string[]]$ScriptArgs = @())

    $path = Join-Path $script:Skill ('scripts\' + $Name)
    $raw = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $path @ScriptArgs 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{
        Text = ($raw -join "`n")
        HasStackTrace = @($raw | Where-Object { $_ -match 'CategoryInfo|FullyQualifiedErrorId|At line:\d+ char:\d+' }).Count -gt 0
    }
}

# --- unit cases: one evidence shape -> one required verdict ---------------------------------------

# V1 -- a named packer signature hides the real code; wrapping is the only safe default.
Assert-Verdict -Name 'V1-named-packer-is-wrapper' -ExpectedVerdict 'WRAPPER_ONLY' -Result (
    Get-ModifiabilityVerdict -Packer 'UPX(3.96)' -AntiDebug 'no')

# V2 -- high entropy is a packer even with no signature: custom packers show as entropy first.
Assert-Verdict -Name 'V2-high-entropy-is-wrapper' -ExpectedVerdict 'WRAPPER_ONLY' -Result (
    Get-ModifiabilityVerdict -Packer 'none-detected' -EntropyTotal 7.5 -AntiDebug 'no')

# V3 -- DIE's own packed status counts too, independent of the entropy number we parsed.
Assert-Verdict -Name 'V3-die-status-packed-is-wrapper' -ExpectedVerdict 'WRAPPER_ONLY' -Result (
    Get-ModifiabilityVerdict -Packer 'none-detected' -StatusSaysPacked $true -AntiDebug 'no')

# V4 -- the entropy threshold is > 7.2, not >= : exactly 7.2 must NOT read as packed. Pins the
# boundary so tightening it to >= or loosening it to a higher cutoff turns this case red.
Assert-Verdict -Name 'V4-entropy-boundary-not-packed' -ExpectedVerdict 'CAN_PATCH' -Result (
    Get-ModifiabilityVerdict -Packer 'none-detected' -EntropyTotal 7.2 -AntiDebug 'no')

# V5 -- anti-debug means bytes may be self-checked at runtime; overlay/wrapper before patching.
Assert-Verdict -Name 'V5-anti-debug-is-overlay' -ExpectedVerdict 'OVERLAY_ONLY' -Result (
    Get-ModifiabilityVerdict -Packer 'none-detected' -AntiDebug 'yes')

# V6 -- integrity self-check is the same risk from a different marker set.
Assert-Verdict -Name 'V6-self-check-is-overlay' -ExpectedVerdict 'OVERLAY_ONLY' -Result (
    Get-ModifiabilityVerdict -Packer 'none-detected' -AntiDebug 'no' -SelfCheck 'yes')

# V7 -- a valid signature breaks on any byte edit; overlay first, evaluate signing separately.
Assert-Verdict -Name 'V7-signed-is-overlay' -ExpectedVerdict 'OVERLAY_ONLY' -Result (
    Get-ModifiabilityVerdict -Packer 'none-detected' -AntiDebug 'no' -CodeSigning 'signed')

# V8 -- managed .NET can be decompiled and edited at IL level: patchable (still verify).
Assert-Verdict -Name 'V8-dotnet-format-can-patch' -ExpectedVerdict 'CAN_PATCH' -Result (
    Get-ModifiabilityVerdict -Packer 'none-detected' -AntiDebug 'no' -FileFormat 'PE32 .NET assembly')
Assert-Verdict -Name 'V9-dotnet-language-can-patch' -ExpectedVerdict 'CAN_PATCH' -Result (
    Get-ModifiabilityVerdict -Packer 'none-detected' -AntiDebug 'no' -LanguageFramework 'C#')

# V10 -- nothing protecting it: patchable.
$clean = Get-ModifiabilityVerdict -Packer 'none-detected' -AntiDebug 'no'
Assert-Verdict -Name 'V10-clean-can-patch' -ExpectedVerdict 'CAN_PATCH' -Result $clean
Assert-Equal -Name 'V10-clean-hardening-yes' -Expected 'yes' -Actual ([string]$clean.Hardening)

# V11 -- no DIE (packer stays 'unknown') and no string evidence must NOT be read as clean/patchable.
# 'unknown' is not 'none-detected', so the clean branch must not fire -- it falls through to UNKNOWN.
# This is the guard that a bare machine without DIE cannot produce an over-optimistic verdict.
Assert-Verdict -Name 'V11-no-evidence-is-unknown' -ExpectedVerdict 'UNKNOWN' -Result (
    Get-ModifiabilityVerdict -Packer 'unknown' -AntiDebug 'unknown')

# V12..V14 -- precedence. Packing dominates every softer signal; anti-debug dominates signing.
Assert-Verdict -Name 'V12-packed-beats-signed' -ExpectedVerdict 'WRAPPER_ONLY' -Result (
    Get-ModifiabilityVerdict -Packer 'Themida' -CodeSigning 'signed' -AntiDebug 'no')
Assert-Verdict -Name 'V13-packed-beats-anti-debug' -ExpectedVerdict 'WRAPPER_ONLY' -Result (
    Get-ModifiabilityVerdict -Packer 'ASPack' -AntiDebug 'yes')
$overSigned = Get-ModifiabilityVerdict -Packer 'none-detected' -AntiDebug 'yes' -CodeSigning 'signed'
Assert-Verdict -Name 'V14-anti-debug-beats-signed' -ExpectedVerdict 'OVERLAY_ONLY' -Result $overSigned
Assert-Match -Name 'V14-reason-cites-anti-debug' -Text ([string]$overSigned.Reason) -Pattern '反调试或自校验'

# V15 -- a packed target must never be told hardening is feasible (re-packing collides).
Assert-Equal -Name 'V15-wrapper-hardening-no' -Expected 'no' -Actual ([string](
    Get-ModifiabilityVerdict -Packer 'UPX').Hardening)

# --- end-to-end: the real script still extracts signals, applies the tree, and writes the profile.
# Deliberately runs without DIE (none is on CI), so it exercises the string-scan fallback path.

# E1 -- no product dossier yet: a friendly refusal, not a stack trace.
$e1 = Join-Path $FixtureRoot 'e1-no-state'
New-Item -ItemType Directory -Force -Path $e1 | Out-Null
$run = Invoke-Script -Name 'detect-protections.ps1' -ScriptArgs @('-ProductRoot', $e1)
Assert-Match -Name 'E1-refuses-without-dossier' -Text $run.Text -Pattern '还没有产品档案'
Add-Result -Name 'E1-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })

# E2 -- an inert file whose plaintext carries an anti-debug API name. No DIE, no execution: the
# script's fallback string scan must see it and the tree must return OVERLAY_ONLY, written to disk.
$e2 = Join-Path $FixtureRoot 'e2-anti-debug'
New-Item -ItemType Directory -Force -Path $e2 | Out-Null
$e2Core = Join-Path $e2 'core.exe'
[IO.File]::WriteAllText($e2Core, 'MZ inert fixture with marker IsDebuggerPresent embedded as plaintext', [Text.Encoding]::ASCII)
$null = Invoke-Script -Name 'init-product.ps1' -ScriptArgs @('-ProductRoot', $e2, '-ProductId', 'protect-e2', '-CorePath', $e2Core)
$run = Invoke-Script -Name 'detect-protections.ps1' -ScriptArgs @('-ProductRoot', $e2)
Assert-Match -Name 'E2-runs-clean' -Text $run.Text -Pattern '"status":\s+"assessed"'
Add-Result -Name 'E2-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })
$e2Profile = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $e2 'product-state\PROTECTION-PROFILE.yaml')
Assert-Match -Name 'E2-anti-debug-recorded' -Text $e2Profile -Pattern 'anti_debug:\s*"yes"'
Assert-Match -Name 'E2-verdict-is-overlay' -Text $e2Profile -Pattern 'verdict:\s*"OVERLAY_ONLY"'

# E3 -- a second assessment without -Force must refuse rather than clobber the recorded one.
$run = Invoke-Script -Name 'detect-protections.ps1' -ScriptArgs @('-ProductRoot', $e2)
Assert-Match -Name 'E3-reassess-refused-without-force' -Text $run.Text -Pattern '已经探测过'

# E4 -- RV F1: a disk-discovered (source=fallback-search), unsigned diec.exe must be refused execution by
# DEFAULT (planted-binary risk) and only run under -AllowUnsignedDiscoveredTools. Revert the default-skip
# branch in Approve-DiscoveredTool and the default run stops skipping, so E4-default goes red.
$e4 = Join-Path $FixtureRoot 'e4-unsigned-discovered'
New-Item -ItemType Directory -Force -Path $e4 | Out-Null
$e4Core = Join-Path $e4 'core.exe'
[IO.File]::WriteAllText($e4Core, 'MZ inert e4 fixture core', [Text.Encoding]::ASCII)
$null = Invoke-Script -Name 'init-product.ps1' -ScriptArgs @('-ProductRoot', $e4, '-ProductId', 'protect-e4', '-CorePath', $e4Core)
$e4Die = Join-Path $e4 'faketools\diec.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $e4Die) | Out-Null
[IO.File]::WriteAllText($e4Die, 'not a real DIE -- inert unsigned placeholder', [Text.Encoding]::ASCII)
$e4Inv = Join-Path $e4 'product-state\tooling\TOOL-INVENTORY.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $e4Inv) | Out-Null
[IO.File]::WriteAllText($e4Inv, ('{ "schema_version": 1, "tools": [ { "tool_id": "native-static", "available": true, "source": "fallback-search", "path": ' + (ConvertTo-Json $e4Die) + ' } ] }'), (New-Object Text.UTF8Encoding($false)))
$e4ProfilePath = Join-Path $e4 'product-state\PROTECTION-PROFILE.yaml'
$run = Invoke-Script -Name 'detect-protections.ps1' -ScriptArgs @('-ProductRoot', $e4, '-Force')
$e4Profile = Get-Content -Raw -Encoding UTF8 -LiteralPath $e4ProfilePath
Assert-Match -Name 'E4-default-skips-unsigned-discovered' -Text $e4Profile -Pattern '已默认跳过磁盘扫描发现'
Add-Result -Name 'E4-default-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })
$null = Invoke-Script -Name 'detect-protections.ps1' -ScriptArgs @('-ProductRoot', $e4, '-Force', '-AllowUnsignedDiscoveredTools')
$e4ProfileAllow = Get-Content -Raw -Encoding UTF8 -LiteralPath $e4ProfilePath
Assert-Match -Name 'E4-allow-flag-runs-unsigned-discovered' -Text $e4ProfileAllow -Pattern '已默认跳过磁盘扫描发现' -Absent

$failed = @($script:Results | Where-Object { -not $_.Passed })
Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f @($script:Results | Where-Object { $_.Passed }).Count, $failed.Count)
if (-not $KeepFixture -and (Test-Path -LiteralPath $FixtureRoot -PathType Container)) {
    Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed.Count -gt 0) { exit 1 }
