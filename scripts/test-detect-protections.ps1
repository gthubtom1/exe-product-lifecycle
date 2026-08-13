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

# --- Q1: containers ------------------------------------------------------------------------------
# This block is the one that must not be allowed to rot. Every other misroute is loud or cheap: this
# one ships. Rebrand an installer and the artifact installs, launches, and satisfies every evidence
# gate while the real application is byte-for-byte untouched -- nothing anywhere else goes red.

# V16 -- THE kill-test for the container branch. Installer names arrive on DIE's Protector/Packer
# line, so before Q1 existed this exact input read as WRAPPER_ONLY. Delete the CONTAINER branch, or
# move it below the packed test, and this goes red.
Assert-Verdict -Name 'V16-inno-is-container-not-wrapper' -ExpectedVerdict 'CONTAINER' -Result (
    Get-ModifiabilityVerdict -Packer 'Inno Setup' -AntiDebug 'no')
Assert-Verdict -Name 'V17-nsis-is-container' -ExpectedVerdict 'CONTAINER' -Result (
    Get-ModifiabilityVerdict -Packer 'Nullsoft Scriptable Install System (NSIS)' -AntiDebug 'no')
Assert-Verdict -Name 'V18-msi-extension-is-container' -ExpectedVerdict 'CONTAINER' -Result (
    Get-ModifiabilityVerdict -TargetName 'C:\x\setup.msi' -Packer 'none-detected' -AntiDebug 'no')

# V18b -- the branch must survive a caller that never passes -ContainerKind at all. Make the
# parameter default to 'none' instead of deriving it and this goes red, which is the point: a
# forgotten argument must not be able to silently disable the only quietly-failing branch.
Assert-Verdict -Name 'V18b-derives-container-when-arg-omitted' -ExpectedVerdict 'CONTAINER' -Result (
    Get-ModifiabilityVerdict -Packer 'Inno Setup 6.2.2' -AntiDebug 'no' -CodeSigning 'signed')

# V19 -- container outranks a real packer signature on the same target. An installer that is itself
# UPX-compressed is still an installer: unpacking it in place would leave you holding the installer.
Assert-Verdict -Name 'V19-container-beats-packer' -ExpectedVerdict 'CONTAINER' -Result (
    Get-ModifiabilityVerdict -ContainerKind 'inno' -Packer 'UPX(3.96)' -EntropyTotal 7.9 -StatusSaysPacked $true)

# V20 -- a container is re-entrant, not terminal: open it and ask Q1 again about what came out.
$v20 = Get-ModifiabilityVerdict -Packer 'Inno Setup' -AntiDebug 'no'
Assert-Equal -Name 'V20-container-reenter-true' -Expected 'True' -Actual ([string]$v20.ReEnter)
Assert-Equal -Name 'V20-container-kind-echoed' -Expected 'inno' -Actual ([string]$v20.ContainerKind)

# V21 -- Inno is the only container with a genuine dead end (innoextract 1.9 is the last release, so
# "install a newer one" is not a fix). NSIS must NOT inherit it, or every container reads as hopeless.
Assert-Equal -Name 'V21-inno-dead-end-recorded' -Expected 'inno-data-version-above-innoextract-1.9-ceiling' -Actual ([string]$v20.DeadEndCondition)
Assert-Equal -Name 'V21-nsis-has-no-dead-end' -Expected '' -Actual ([string](
    Get-ModifiabilityVerdict -Packer 'NSIS' -AntiDebug 'no').DeadEndCondition)

# V22 -- Get-ContainerKind must not over-classify: a real packer is not a container. Loosen the
# patterns until UPX matches and every packed target gets routed away from unpacking.
Assert-Equal -Name 'V22-upx-is-not-a-container' -Expected 'none' -Actual (Get-ContainerKind -Packer 'UPX(3.96)')
Assert-Equal -Name 'V22-themida-is-not-a-container' -Expected 'none' -Actual (Get-ContainerKind -Packer 'Themida/WinLicense')
Assert-Equal -Name 'V22-empty-is-none' -Expected 'none' -Actual (Get-ContainerKind -Packer '')

# --- re-entry and dead ends on the existing branches ----------------------------------------------

# V23 -- UPX is unpackable, so WRAPPER_ONLY here means "unpack, then re-route", not "stop".
Assert-Equal -Name 'V23-upx-wrapper-reenter-true' -Expected 'True' -Actual ([string](
    Get-ModifiabilityVerdict -Packer 'UPX(3.96)' -AntiDebug 'no').ReEnter)

# V24 -- a commercial protector is terminal for re-entry and carries the dead-end judgement. The
# condition is deliberately requirement-coupled: judging by the shell alone would kill a product
# that a Launcher-only delivery could still have shipped.
$v24 = Get-ModifiabilityVerdict -Packer 'Themida' -AntiDebug 'no'
Assert-Equal -Name 'V24-themida-reenter-false' -Expected 'False' -Actual ([string]$v24.ReEnter)
Assert-Equal -Name 'V24-themida-dead-end-recorded' -Expected 'commercial-protector-and-core-logic-change-required' -Actual ([string]$v24.DeadEndCondition)

# V25 -- CAN_PATCH is terminal and has no dead end: a failed smoke edit downgrades to OVERLAY_ONLY,
# it does not stop the job. Writing a dead-end string here would turn a detour into an abandonment.
$v25 = Get-ModifiabilityVerdict -Packer 'none-detected' -AntiDebug 'no'
Assert-Equal -Name 'V25-can-patch-reenter-false' -Expected 'False' -Actual ([string]$v25.ReEnter)
Assert-Equal -Name 'V25-can-patch-no-dead-end' -Expected '' -Actual ([string]$v25.DeadEndCondition)

# V26 -- CAN_PATCH must tell the caller to smoke-test first. The self-check detector never returns
# 'no' and knows only five API names, so an inlined CRC lands here; the early minimal edit is the
# only thing standing between that and a full round of customisation thrown away.
Assert-Match -Name 'V26-can-patch-demands-smoke-run' -Text ([string]$v25.Reason) -Pattern '最小改动'

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

# E5 -- the routing fields have to reach the FILE, not just the returned object. Deleting the three
# container_kind / re_enter / dead_end_condition writes from detect-protections.ps1 left all 45 cases
# green, because every assertion about them went through the in-memory function. Downstream nobody
# reads that object: the layer gate parses the profile, and so does the next person. A verdict whose
# re-entry and stop condition never got written is a verdict that silently became terminal.
Assert-Match -Name 'E5-profile-carries-container-kind' -Text $e2Profile -Pattern 'container_kind:\s*"none"'
Assert-Match -Name 'E5-profile-carries-re-enter' -Text $e2Profile -Pattern 're_enter:\s*"no"'
Assert-Match -Name 'E5-profile-carries-dead-end' -Text $e2Profile -Pattern 'dead_end_condition:\s*"whole-image-self-check-with-vendor-signature"'

# E6 -- end-to-end twin of V16, covering the one misroute in the table that ships successfully.
# V16 pins the pure function; this pins the wiring. Stop passing -TargetName from
# detect-protections.ps1 and V16 stays green while an installer quietly routes as patchable.
$e5 = Join-Path $FixtureRoot 'e5-container'
New-Item -ItemType Directory -Force -Path $e5 | Out-Null
$e5Core = Join-Path $e5 'setup.msi'
[IO.File]::WriteAllText($e5Core, 'MZ inert installer fixture, never executed', [Text.Encoding]::ASCII)
$null = Invoke-Script -Name 'init-product.ps1' -ScriptArgs @('-ProductRoot', $e5, '-ProductId', 'protect-e5', '-CorePath', $e5Core)
$run = Invoke-Script -Name 'detect-protections.ps1' -ScriptArgs @('-ProductRoot', $e5)
Add-Result -Name 'E6-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })
$e5Profile = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $e5 'product-state\PROTECTION-PROFILE.yaml')
Assert-Match -Name 'E6-installer-routed-as-container' -Text $e5Profile -Pattern 'verdict:\s*"CONTAINER"'
Assert-Match -Name 'E6-container-kind-written' -Text $e5Profile -Pattern 'container_kind:\s*"msi"'
Assert-Match -Name 'E6-container-is-re-enterable' -Text $e5Profile -Pattern 're_enter:\s*"yes"'
# The profile is where the operator learns what to do next; "CONTAINER" alone does not say
# "open it and ask again", nor that touching the installer's own resources is the trap.
Assert-Match -Name 'E6-container-note-names-next-step' -Text $e5Profile -Pattern '先解开容器'

$failed = @($script:Results | Where-Object { -not $_.Passed })
Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f @($script:Results | Where-Object { $_.Passed }).Count, $failed.Count)
if (-not $KeepFixture -and (Test-Path -LiteralPath $FixtureRoot -PathType Container)) {
    Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed.Count -gt 0) { exit 1 }
