#requires -Version 5

# Mutation guard for gap-classify.ps1 (self-evolution step 1). Each case pins one mechanical rule so that
# breaking it turns the suite red; the failure shape is always a clean RESULT verdict line, never a crash.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-gap-classify.ps1

[CmdletBinding()]
param(
    [string]$SkillRoot,
    [string]$FixtureRoot = (Join-Path $env:TEMP ('eplc-gapclassify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))),
    [switch]$KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$script:Skill = (Resolve-Path -LiteralPath $SkillRoot).Path
$script:Results = New-Object System.Collections.Generic.List[psobject]
New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Expected, [string]$Actual)
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed })
    $label = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Output ('{0}   {1,-42} expected[{2}] actual[{3}]' -f $label, $Name, $Expected, $Actual)
}

function Invoke-Gap {
    param([string[]]$ScriptArgs, [string]$SkillOverride)
    $skill = if ([string]::IsNullOrWhiteSpace($SkillOverride)) { $script:Skill } else { $SkillOverride }
    $path = Join-Path $skill 'scripts\gap-classify.ps1'
    $raw = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $path @ScriptArgs 2>&1 | ForEach-Object { [string]$_ })
    # Same StrictMode hazard as in gap-classify: $LASTEXITCODE does not exist before the first native call.
    # This suite runs under both Windows PowerShell 5.1 and pwsh in CI, so do not assume it is defined.
    $code = if (Test-Path -LiteralPath 'Variable:LASTEXITCODE') { $LASTEXITCODE } else { -1 }
    $vLine = @($raw | Where-Object { $_ -match '^RESULT:\s*' } | Select-Object -First 1)
    $verdict = if ($vLine.Count -eq 1) { ($vLine[0] -replace '^RESULT:\s*', '').Trim() } else { '(no-verdict)' }
    $rLine = @($raw | Where-Object { $_ -match '^reason=' } | Select-Object -First 1)
    $reason = if ($rLine.Count -eq 1) { ($rLine[0] -replace '^reason=', '').Trim() } else { '(no-reason)' }
    return [pscustomobject]@{
        Verdict       = $verdict
        Reason        = $reason
        ExitCode      = $code
        Text          = ($raw -join "`n")
        HasStackTrace = @($raw | Where-Object { $_ -match 'CategoryInfo|FullyQualifiedErrorId|At line:\d+ char:\d+' }).Count -gt 0
    }
}

# A copy of scripts/ whose resolve-capability.ps1 is replaced by a stub (or deleted). Only gap-classify is
# run from it -- products are still built by the real skill -- so no asset tree is needed. This is the only
# way to drive the bridge's failure shapes (crash verdict / bad exit code / silence / absent) from the
# consumer side without editing resolve-capability.ps1, which is not this suite's subject.
function New-StubSkill {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$ResolverBody, [switch]$NoResolver)
    $dst = Join-Path $FixtureRoot $Name
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:Skill 'scripts') -Destination $dst -Recurse -Force
    $stub = Join-Path $dst 'scripts\resolve-capability.ps1'
    if ($NoResolver) { Remove-Item -LiteralPath $stub -Force }
    else { [IO.File]::WriteAllText($stub, $ResolverBody, (New-Object Text.UTF8Encoding($false))) }
    return $dst
}

$id = 0
function New-GapProduct {
    param([string]$Verdict = 'CAN_PATCH', [object[]]$Tools = @(), [hashtable]$Attempts = $null, [switch]$NoFailFile, [switch]$EmptyFailFile, [switch]$NoInventory, [string]$FailContent)
    $script:id++
    $root = Join-Path $FixtureRoot ('p' + $script:id)
    $core = Join-Path $root 'core.exe'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    [IO.File]::WriteAllText($core, 'MZ inert core', [Text.Encoding]::ASCII)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Skill 'scripts\init-product.ps1') -ProductRoot $root -ProductId ('gap-' + $script:id) -CorePath $core | Out-Null
    $packer = if ($Verdict -eq 'WRAPPER_ONLY') { 'UPX(4.0)' } else { 'none-detected' }
    $entropy = if ($Verdict -eq 'WRAPPER_ONLY') { '7.95' } else { '5.10' }
    $profile = @"
schema_version: 1
product_id: "gap-$($script:id)"
status: "ASSESSED"
packing:
  detector: "DIE"
  packer: "$packer"
  entropy_total: "$entropy"
modifiability:
  verdict: "$Verdict"
  reason: "fixture"
"@
    [IO.File]::WriteAllText((Join-Path $root 'product-state\PROTECTION-PROFILE.yaml'), $profile, (New-Object Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'product-state\tooling') | Out-Null
    if (-not $NoInventory) {
        $inv = [pscustomobject]@{ schema_version = 1; tools = $Tools }
        [IO.File]::WriteAllText((Join-Path $root 'product-state\tooling\TOOL-INVENTORY.json'), ($inv | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    }
    if ($null -ne $Attempts) {
        [IO.File]::WriteAllText((Join-Path $root 'product-state\tooling\CAPABILITY-ATTEMPTS.json'), ($Attempts | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    }
    if (-not $NoFailFile) {
        $failRel = 'product-state\analysis\gap-fail.txt'
        $content = if ($EmptyFailFile) { '' } elseif ($PSBoundParameters.ContainsKey('FailContent')) { $FailContent } else { "tool run failed`nerror: could not produce evidence for this category" }
        [IO.File]::WriteAllText((Join-Path $root $failRel), $content, (New-Object Text.UTF8Encoding($false)))
    }
    return $root
}

function Get-State { param([string]$Root) Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'product-state\STATE.yaml') }
function Get-Findings { param([string]$Root) Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'product-state\analysis\ANALYSIS-FINDINGS.yaml') }

# A refusal is only pinned if it names WHY. gap-classify has a catch-all "unexpected verdict" branch that
# backstops every named check, so asserting "did it refuse" alone would stay green after deleting the very
# branch the case exists to protect (measured: it did). Asserting reason= makes each case fail on its own
# branch. Verdict + exit code + reason are the machine-readable contract; detail= prose is not.
function Test-Refused {
    param([object]$Run, [string]$Reason)
    return ($Run.Verdict -eq 'rejected_resolver_unusable' -and $Run.ExitCode -eq 3 -and $Run.Reason -eq $Reason)
}
function Format-Refusal { param([object]$Run) return "$($Run.Verdict)/$($Run.ExitCode)/$($Run.Reason)" }

# A refusal must leave the archive exactly as it was: no blocked category, no STATE blocking item, and no
# attempts-ledger entry burning this capability's budget.
function Test-NoGapWrites {
    param([string]$Root, [string]$CapabilityId, [string]$Technique = 'disassembly')
    $blocked = (Get-Findings $Root) -match ('(?m)^' + [regex]::Escape($Technique) + ':\s*"blocked"')
    $item = (Get-State $Root) -match [regex]::Escape($CapabilityId)
    $ledger = Test-Path -LiteralPath (Join-Path $Root 'product-state\tooling\CAPABILITY-ATTEMPTS.json') -PathType Leaf
    return (-not $blocked -and -not $item -and -not $ledger)
}

$failRel = 'product-state/analysis/gap-fail.txt'

# GC1 -- anti-fabrication: no failure command, a 0-byte output, and a missing output must each be refused
# WITHOUT writing blocked. Break the evidence check and one of these writes a blocked with no evidence.
$r1a = New-GapProduct
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r1a, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', 'product-state/analysis/does-not-exist.txt')
Add-Result -Name 'GC1a-missing-output-file-rejected' -Passed ($run.Verdict -eq 'rejected_no_evidence') -Expected 'rejected_no_evidence' -Actual $run.Verdict
Add-Result -Name 'GC1a-no-blocked-written' -Passed ((Get-Findings $r1a) -notmatch '(?m)^disassembly:\s*"blocked"') -Expected 'not-blocked' -Actual $(if ((Get-Findings $r1a) -match '(?m)^disassembly:\s*"blocked"') { 'blocked' } else { 'not-blocked' })
$r1b = New-GapProduct -EmptyFailFile
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r1b, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC1b-empty-output-rejected' -Passed ($run.Verdict -eq 'rejected_no_evidence') -Expected 'rejected_no_evidence' -Actual $run.Verdict
Add-Result -Name 'GC1b-no-blocked-written' -Passed ((Get-Findings $r1b) -notmatch '(?m)^disassembly:\s*"blocked"') -Expected 'not-blocked' -Actual $(if ((Get-Findings $r1b) -match '(?m)^disassembly:\s*"blocked"') { 'blocked' } else { 'not-blocked' })

# GC2 -- packed (WRAPPER_ONLY) + unpacking failure must be dead_end, never gap (mirrors CU1). Break rule 1
# and this becomes gap.
$r2 = New-GapProduct -Verdict 'WRAPPER_ONLY'
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r2, '-CapabilityId', 'unpack.pe.upx', '-Technique', 'unpacking', '-FailureCommand', 'upx -d core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC2-packed-unpacking-is-dead-end' -Passed ($run.Verdict -eq 'dead_end') -Expected 'dead_end' -Actual $run.Verdict

# GC3 -- an available tool that still failed must be dead_end, never gap. Break rule 3 and this becomes gap.
$avail = Join-Path $FixtureRoot 'fake-ida.exe'; [IO.File]::WriteAllText($avail, 'inert', [Text.Encoding]::ASCII)
$r3 = New-GapProduct -Verdict 'CAN_PATCH' -Tools @([pscustomobject]@{ tool_id = 'native-static'; available = $true; path = $avail })
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r3, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC3-available-tool-failed-is-dead-end' -Passed ($run.Verdict -eq 'dead_end') -Expected 'dead_end' -Actual $run.Verdict

# GC4 -- over the attempt budget must force dead_end. Break rule 2 and this becomes gap.
$r4 = New-GapProduct -Verdict 'CAN_PATCH' -Attempts @{ 'decompile.pe.native' = @{ tools_tried = @('ida', 'ghidra'); gate_count = 2; verdict_anchor = 'CAN_PATCH' } }
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r4, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'r2 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC4-over-budget-is-dead-end' -Passed ($run.Verdict -eq 'dead_end') -Expected 'dead_end' -Actual $run.Verdict

# GC5 -- a classification must both set the category blocked AND append a STATE blocking item, or the
# state_no_blocking_items gate can't hold and a shell still level-jumps. Break either write and this reds.
$r5 = New-GapProduct -Verdict 'CAN_PATCH'
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r5, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC5-category-set-blocked' -Passed ((Get-Findings $r5) -match '(?m)^disassembly:\s*"blocked"') -Expected 'blocked' -Actual $(if ((Get-Findings $r5) -match '(?m)^disassembly:\s*"blocked"') { 'blocked' } else { 'not-blocked' })
Add-Result -Name 'GC5-blocking-item-appended' -Passed ((Get-State $r5) -match 'decompile\.pe\.native') -Expected 'present' -Actual $(if ((Get-State $r5) -match 'decompile\.pe\.native') { 'present' } else { 'absent' })

# GC6 -- reverse guard: a clean (CAN_PATCH, not packed) target with NO available tool and no prior attempts
# must still be able to classify gap, or the rules are stuck always-dead_end (mirrors CU3).
$r6 = New-GapProduct -Verdict 'CAN_PATCH'
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r6, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC6-clean-real-gap-is-gap' -Passed ($run.Verdict -eq 'gap') -Expected 'gap' -Actual $run.Verdict
Add-Result -Name 'GC6-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })

# GC7 -- a bypass/de-auth/crack failure is never a capability gap (rule 4). Break it and this becomes gap.
$r7 = New-GapProduct -Verdict 'CAN_PATCH'
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r7, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'patch out license check', '-FailureOutputPath', $failRel, '-FailureNature', 'bypass')
Add-Result -Name 'GC7-bypass-is-dead-end' -Passed ($run.Verdict -eq 'dead_end') -Expected 'dead_end' -Actual $run.Verdict

# GC8..GC13 -- the bridge answer must be an answer. resolve-capability only tells us something about tools
# when it says 'available' or 'unavailable'; every other shape means "we could not find out". Reading those
# as "no available tool" mints a capability_gap -- and with it a request to install a tool out of band --
# out of a typo or broken wiring, which is the same fabrication the evidence checks above exist to stop. So
# each shape must refuse with RESULT: rejected_resolver_unusable, exit 3, its own reason=, and no writes.
# Revert the whole consumer fix and all six turn red as gap; revert one branch and only its case reds.
$stubParam = 'param([string]$CapabilityId, [string]$ProductRoot, [string]$InventoryPath)'

# GC8 -- an id that is not in the bridge table (resolver says unknown_capability). Not-in-the-table is a
# mapping bug, not evidence that the capability has no tool.
$bogusId = 'totally.made.up.capability'
$r8 = New-GapProduct -Verdict 'CAN_PATCH'
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r8, '-CapabilityId', $bogusId, '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC8-unknown-capability-refused' -Passed (Test-Refused -Run $run -Reason 'unknown_capability') -Expected 'refused/3/unknown_capability' -Actual (Format-Refusal $run)
Add-Result -Name 'GC8-nothing-written' -Passed (Test-NoGapWrites -Root $r8 -CapabilityId $bogusId) -Expected 'no-writes' -Actual $(if (Test-NoGapWrites -Root $r8 -CapabilityId $bogusId) { 'no-writes' } else { 'wrote' })

# GC9 -- the bridge self-reports resolver_error (its own crash fallback). A broken resolver is not a
# missing tool. The stub exits 0 on purpose so this case pins the verdict branch alone; GC10 covers the
# exit code. (The real resolver exits 4 here, i.e. in production both guards catch it.)
$sk9 = New-StubSkill -Name 'stub-resolver-error' -ResolverBody ($stubParam + "`nWrite-Output 'RESULT: resolver_error'`nWrite-Output 'detail=stubbed crash'`nexit 0`n")
$r9 = New-GapProduct -Verdict 'CAN_PATCH'
$run = Invoke-Gap -SkillOverride $sk9 -ScriptArgs @('-ProductRoot', $r9, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC9-resolver-error-refused' -Passed (Test-Refused -Run $run -Reason 'resolver_error') -Expected 'refused/3/resolver_error' -Actual (Format-Refusal $run)
Add-Result -Name 'GC9-nothing-written' -Passed (Test-NoGapWrites -Root $r9 -CapabilityId 'decompile.pe.native') -Expected 'no-writes' -Actual $(if (Test-NoGapWrites -Root $r9 -CapabilityId 'decompile.pe.native') { 'no-writes' } else { 'wrote' })

# GC10 -- the exit-code guard. The bridge prints a perfectly plausible 'unavailable' but exits non-zero, so
# the verdict line is not trustworthy. Stop reading the exit code and this reads as "no tool" -> gap.
$sk10 = New-StubSkill -Name 'stub-bad-exit' -ResolverBody ($stubParam + "`nWrite-Output 'RESULT: unavailable'`nWrite-Output 'capability_id=decompile.pe.native'`nexit 7`n")
$r10 = New-GapProduct -Verdict 'CAN_PATCH'
$run = Invoke-Gap -SkillOverride $sk10 -ScriptArgs @('-ProductRoot', $r10, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC10-nonzero-exit-refused' -Passed (Test-Refused -Run $run -Reason 'nonzero_exit') -Expected 'refused/3/nonzero_exit' -Actual (Format-Refusal $run)
Add-Result -Name 'GC10-nothing-written' -Passed (Test-NoGapWrites -Root $r10 -CapabilityId 'decompile.pe.native') -Expected 'no-writes' -Actual $(if (Test-NoGapWrites -Root $r10 -CapabilityId 'decompile.pe.native') { 'no-writes' } else { 'wrote' })

# GC11 -- the bridge is not on disk at all (broken wiring). Absent must be red, not silently "no tool".
$sk11 = New-StubSkill -Name 'stub-no-resolver' -NoResolver
$r11 = New-GapProduct -Verdict 'CAN_PATCH'
$run = Invoke-Gap -SkillOverride $sk11 -ScriptArgs @('-ProductRoot', $r11, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC11-missing-bridge-refused' -Passed (Test-Refused -Run $run -Reason 'bridge_missing') -Expected 'refused/3/bridge_missing' -Actual (Format-Refusal $run)
Add-Result -Name 'GC11-nothing-written' -Passed (Test-NoGapWrites -Root $r11 -CapabilityId 'decompile.pe.native') -Expected 'no-writes' -Actual $(if (Test-NoGapWrites -Root $r11 -CapabilityId 'decompile.pe.native') { 'no-writes' } else { 'wrote' })

# GC12 -- the bridge exits 0 but prints no RESULT line (silent failure). No verdict is not 'unavailable'.
$sk12 = New-StubSkill -Name 'stub-silent' -ResolverBody ($stubParam + "`nexit 0`n")
$r12 = New-GapProduct -Verdict 'CAN_PATCH'
$run = Invoke-Gap -SkillOverride $sk12 -ScriptArgs @('-ProductRoot', $r12, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC12-silent-bridge-refused' -Passed (Test-Refused -Run $run -Reason 'no_result_line') -Expected 'refused/3/no_result_line' -Actual (Format-Refusal $run)
Add-Result -Name 'GC12-nothing-written' -Passed (Test-NoGapWrites -Root $r12 -CapabilityId 'decompile.pe.native') -Expected 'no-writes' -Actual $(if (Test-NoGapWrites -Root $r12 -CapabilityId 'decompile.pe.native') { 'no-writes' } else { 'wrote' })

# GC13 -- never-ran-discovery is not no-tool. The bridge answers 'unavailable' for a missing TOOL-INVENTORY
# exactly as it does for an inventory with no match (its own RC1 contract), so the consumer must tell the
# two apart. GC6 is the paired positive control: same call with an inventory present still classifies gap.
$r13 = New-GapProduct -Verdict 'CAN_PATCH' -NoInventory
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r13, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC13-no-inventory-refused' -Passed (Test-Refused -Run $run -Reason 'no_tool_inventory') -Expected 'refused/3/no_tool_inventory' -Actual (Format-Refusal $run)
Add-Result -Name 'GC13-nothing-written' -Passed (Test-NoGapWrites -Root $r13 -CapabilityId 'decompile.pe.native') -Expected 'no-writes' -Actual $(if (Test-NoGapWrites -Root $r13 -CapabilityId 'decompile.pe.native') { 'no-writes' } else { 'wrote' })

# GC14/GC15 -- two innoextract strings that read alike and mean opposite things (1.9 tag: setup/info.cpp and
# cli/main.cpp). Swap the two treatments and both cases red.
#
# GC14: the target IS an Inno installer whose setup data version is above this unmaintained release's
# ceiling, so acquiring another tool cannot help. The fixture is otherwise a textbook gap -- clean target,
# no available tool, no prior attempts -- and GC6 proves that same shape classifies gap, so this only
# passes if the signature rule fired.
$innoId = 'unpack.installer.innosetup'
$r14 = New-GapProduct -Verdict 'CAN_PATCH' -FailContent "innoextract 1.9`nUnexpected setup data version: Inno Setup Setup Data (6.4.0)"
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r14, '-CapabilityId', $innoId, '-Technique', 'unpacking', '-FailureCommand', 'innoextract -e setup.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC14-unknown-data-version-is-dead-end' -Passed ($run.Verdict -eq 'dead_end') -Expected 'dead_end' -Actual $run.Verdict
Add-Result -Name 'GC14-anchor-names-the-signature' -Passed ($run.Text -match 'Unexpected setup data version') -Expected 'present' -Actual $(if ($run.Text -match 'Unexpected setup data version') { 'present' } else { 'absent' })

# GC15: the target is not an Inno installer at all -- a tool-selection error, so refuse and write nothing
# rather than record a verdict about the target. The fixture is packed + unpacking, which rule 1 would
# otherwise call dead_end (GC2 proves it), so this reds the moment the signature stops taking precedence.
# The asymmetry is the point: a wrong dead_end here permanently abandons a target another tool would open.
$r15 = New-GapProduct -Verdict 'WRAPPER_ONLY' -FailContent "innoextract 1.9`nNot a supported Inno Setup installer!"
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r15, '-CapabilityId', $innoId, '-Technique', 'unpacking', '-FailureCommand', 'innoextract -e setup.exe', '-FailureOutputPath', $failRel)
$gc15refused = ($run.Verdict -eq 'rejected_wrong_tool_for_target' -and $run.ExitCode -eq 3 -and $run.Reason -eq 'not_an_inno_setup_installer')
Add-Result -Name 'GC15-not-inno-goes-back-to-triage' -Passed $gc15refused -Expected 'refused/3/not_an_inno_setup_installer' -Actual (Format-Refusal $run)
Add-Result -Name 'GC15-nothing-written' -Passed (Test-NoGapWrites -Root $r15 -CapabilityId $innoId -Technique 'unpacking') -Expected 'no-writes' -Actual $(if (Test-NoGapWrites -Root $r15 -CapabilityId $innoId -Technique 'unpacking') { 'no-writes' } else { 'wrote' })

# GC16..GC19 -- the acquisition-suggestion footer. It must appear on the one verdict that means "a tool could
# be acquired" and on no other, and the line it prints has to survive being copy-pasted and run.
function Measure-Line { param([object]$Run, [string]$Prefix) return @($Run.Text -split "`n" | Where-Object { $_.TrimEnd() -like ($Prefix + '*') }).Count }
function Get-LastLine {
    param([object]$Run, [string]$Prefix)
    $m = @($Run.Text -split "`n" | Where-Object { $_.TrimEnd() -like ($Prefix + '*') })
    if ($m.Count -eq 0) { return '' }
    return $m[-1].TrimEnd().Substring($Prefix.Length).Trim()
}

# A scripts/ copy whose suggest-tool-acquisition.ps1 is a parameter mirror that echoes what it was bound to.
# The real resolver is kept, so classification still runs for real. Overwriting rather than requiring the
# real suggester keeps GC19 hermetic and keeps it meaning the same thing once that script reaches this branch.
function New-SuggestStubSkill {
        param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Body)
        $dst = Join-Path $FixtureRoot $Name
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Skill 'scripts') -Destination $dst -Recurse -Force
        # The resolver reads its tables from <skill root>\catalog, not from scripts\ -- they stopped being
        # PowerShell literals when the catalog moved into data files. A scripts-only stub therefore leaves the
        # real resolver unusable, and every case built on this stub degrades into rejected_resolver_unusable:
        # still a "verdict", still no error, and no longer testing the footer it claims to test.
        foreach ($dataDir in @('catalog', 'knowledge', 'schemas')) {
            $srcDir = Join-Path $script:Skill $dataDir
            if (Test-Path -LiteralPath $srcDir -PathType Container) {
                Copy-Item -LiteralPath $srcDir -Destination $dst -Recurse -Force
            }
        }
        # Fail loudly at fixture-build time if the resolver's inputs move again. Without this the next move
        # reads as a product verdict instead of a broken fixture, which is how this one survived a merge.
        $required = Join-Path $dst 'catalog\tools.builtin.json'
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw ("stub skill is missing the resolver's catalog input: $required -- the tables moved again; " +
                   'copy the new location here rather than letting every case return rejected_resolver_unusable')
        }
        [IO.File]::WriteAllText((Join-Path $dst 'scripts\suggest-tool-acquisition.ps1'), $Body, (New-Object Text.UTF8Encoding($false)))
        return $dst
    }

# GC16 -- the gap path carries a suggestion naming the suggester and this product. Drop the footer and this reds.
$r16 = New-GapProduct -Verdict 'CAN_PATCH'
$run16 = Invoke-Gap -ScriptArgs @('-ProductRoot', $r16, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
$sc16 = Get-LastLine -Run $run16 -Prefix 'suggest_command='
Add-Result -Name 'GC16-gap-emits-suggest-command' -Passed ((Measure-Line -Run $run16 -Prefix 'suggest_command=') -eq 1) -Expected '1-line' -Actual ('{0}-line' -f (Measure-Line -Run $run16 -Prefix 'suggest_command='))
Add-Result -Name 'GC16-names-the-suggester' -Passed ($sc16 -match 'suggest-tool-acquisition\.ps1') -Expected 'present' -Actual $(if ($sc16 -match 'suggest-tool-acquisition\.ps1') { 'present' } else { 'absent' })
Add-Result -Name 'GC16-carries-capability-and-root' -Passed (($sc16 -match '-CapabilityId\s+decompile\.pe\.native\b') -and ($sc16 -match ('-ProductRoot\s+"' + [regex]::Escape($r16) + '"'))) -Expected 'both' -Actual $(if (($sc16 -match '-CapabilityId\s+decompile\.pe\.native\b') -and ($sc16 -match ('-ProductRoot\s+"' + [regex]::Escape($r16) + '"'))) { 'both' } else { 'missing' })

# GC17 -- and on nothing else. dead_end means "stop looking for tools", and the two refusals mean the wiring
# or the tool choice is wrong, not that a tool is missing; an acquisition command next to any of them is the
# same category confusion 8672568/541d91c removed from the classifier. Move the footer out of the gap branch
# and all four of these red at once.
$r17a = New-GapProduct -Verdict 'WRAPPER_ONLY'
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r17a, '-CapabilityId', 'unpack.pe.upx', '-Technique', 'unpacking', '-FailureCommand', 'upx -d core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC17a-dead-end-has-no-suggestion' -Passed (($run.Verdict -eq 'dead_end') -and (Measure-Line -Run $run -Prefix 'suggest_command=') -eq 0) -Expected 'dead_end/none' -Actual ('{0}/{1}' -f $run.Verdict, (Measure-Line -Run $run -Prefix 'suggest_command='))

$avail17 = Join-Path $FixtureRoot 'fake-ida-17.exe'; [IO.File]::WriteAllText($avail17, 'inert', [Text.Encoding]::ASCII)
$r17b = New-GapProduct -Verdict 'CAN_PATCH' -Tools @([pscustomobject]@{ tool_id = 'native-static'; available = $true; path = $avail17 })
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r17b, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel, '-InputProblem')
Add-Result -Name 'GC17b-input-problem-has-no-suggestion' -Passed (($run.Verdict -eq 'input_problem') -and (Measure-Line -Run $run -Prefix 'suggest_command=') -eq 0) -Expected 'input_problem/none' -Actual ('{0}/{1}' -f $run.Verdict, (Measure-Line -Run $run -Prefix 'suggest_command='))

# The resolver-fault refusal: "we could not find out whether a tool exists" must never hand out a command to
# go acquire one.
$r17c = New-GapProduct -Verdict 'CAN_PATCH' -NoInventory
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r17c, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ida64 core.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC17c-resolver-refusal-has-no-suggestion' -Passed ((Test-Refused -Run $run -Reason 'no_tool_inventory') -and (Measure-Line -Run $run -Prefix 'suggest_command=') -eq 0) -Expected 'refused/none' -Actual ('{0}/{1}' -f (Format-Refusal $run), (Measure-Line -Run $run -Prefix 'suggest_command='))

# The tool-selection refusal: the answer there is "go re-identify the container", not "go install something".
$r17d = New-GapProduct -Verdict 'WRAPPER_ONLY' -FailContent "innoextract 1.9`nNot a supported Inno Setup installer!"
$run = Invoke-Gap -ScriptArgs @('-ProductRoot', $r17d, '-CapabilityId', 'unpack.installer.innosetup', '-Technique', 'unpacking', '-FailureCommand', 'innoextract -e setup.exe', '-FailureOutputPath', $failRel)
Add-Result -Name 'GC17d-wrong-tool-refusal-has-no-suggestion' -Passed (($run.Verdict -eq 'rejected_wrong_tool_for_target') -and (Measure-Line -Run $run -Prefix 'suggest_command=') -eq 0) -Expected 'refused/none' -Actual ('{0}/{1}' -f $run.Verdict, (Measure-Line -Run $run -Prefix 'suggest_command='))

# GC18 -- the footer must not deform the existing output contract. The suggester prints its own RESULT: and
# capability_id= lines, so inlining a call instead of printing one line would give this contract a second set
# of both and any parser reading the last match would report the suggester's verdict as the classification.
Add-Result -Name 'GC18-single-result-line' -Passed ((Measure-Line -Run $run16 -Prefix 'RESULT:') -eq 1) -Expected '1' -Actual ([string](Measure-Line -Run $run16 -Prefix 'RESULT:'))
Add-Result -Name 'GC18-single-capability-id-line' -Passed ((Measure-Line -Run $run16 -Prefix 'capability_id=') -eq 1) -Expected '1' -Actual ([string](Measure-Line -Run $run16 -Prefix 'capability_id='))
$lastVerdict = (Get-LastLine -Run $run16 -Prefix 'RESULT:')
$lastCap = (Get-LastLine -Run $run16 -Prefix 'capability_id=')
Add-Result -Name 'GC18-last-match-parse-still-correct' -Passed (($lastVerdict -eq 'gap') -and ($lastCap -eq 'decompile.pe.native')) -Expected 'gap/decompile.pe.native' -Actual ('{0}/{1}' -f $lastVerdict, $lastCap)

# GC19 -- the emitted line has to actually run, and -FailedTool has to arrive as ONE comma-joined string.
# `powershell -File` binds no array parameters, so a "tidy-up" into separate arguments silently delivers only
# the first tool and re-suggests the rest. Asserted by running the emitted command against a parameter mirror
# rather than by matching text, so it fails on real binding rather than on formatting.
$sk19 = New-SuggestStubSkill -Name 'stub-suggester' -Body @'
param([string]$CapabilityId, [string]$ProductRoot, [string]$InventoryPath, [string]$FailedTool = '', [string]$EverythingExePath)
Write-Output 'RESULT: stub_suggester'
Write-Output ("bound_capability=" + $CapabilityId)
Write-Output ("bound_root=" + $ProductRoot)
Write-Output ("bound_failedtool=" + $FailedTool)
exit 0
'@
$r19 = New-GapProduct -Verdict 'CAN_PATCH' -Attempts @{ 'decompile.pe.native' = @{ tools_tried = @('ida'); gate_count = 1; verdict_anchor = 'CAN_PATCH' } }
$run19 = Invoke-Gap -SkillOverride $sk19 -ScriptArgs @('-ProductRoot', $r19, '-CapabilityId', 'decompile.pe.native', '-Technique', 'disassembly', '-FailureCommand', 'ghidra headless core.exe', '-FailureOutputPath', $failRel, '-ToolTried', 'ghidra')
$sc19 = Get-LastLine -Run $run19 -Prefix 'suggest_command='
Add-Result -Name 'GC19-still-gap-under-budget' -Passed ($run19.Verdict -eq 'gap') -Expected 'gap' -Actual $run19.Verdict
$echo = if ([string]::IsNullOrWhiteSpace($sc19)) { '(no suggest_command)' } else { (@(Invoke-Expression $sc19 2>&1 | ForEach-Object { [string]$_ }) -join "`n") }
Add-Result -Name 'GC19-emitted-command-runs' -Passed ($echo -match '(?m)^RESULT:\s*stub_suggester') -Expected 'ran' -Actual $(if ($echo -match '(?m)^RESULT:\s*stub_suggester') { 'ran' } else { 'did-not-run' })
$boundTools = if ($echo -match '(?m)^bound_failedtool=(.*)$') { $Matches[1].Trim() } else { '(unbound)' }
Add-Result -Name 'GC19-failedtool-is-one-comma-string' -Passed ($boundTools -eq 'ida,ghidra') -Expected 'ida,ghidra' -Actual $boundTools
$boundRoot = if ($echo -match '(?m)^bound_root=(.*)$') { $Matches[1].Trim() } else { '(unbound)' }
Add-Result -Name 'GC19-productroot-binds-intact' -Passed ($boundRoot -eq $r19) -Expected 'exact-root' -Actual $(if ($boundRoot -eq $r19) { 'exact-root' } else { $boundRoot })

$failed = @($script:Results | Where-Object { -not $_.Passed })
Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f @($script:Results | Where-Object { $_.Passed }).Count, $failed.Count)
if (-not $KeepFixture -and (Test-Path -LiteralPath $FixtureRoot -PathType Container)) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($failed.Count -gt 0) { exit 1 }
# GC13 asserts a refusal exit code, so $LASTEXITCODE is still 3 when the run succeeds. The pwsh CI shell
# appends `exit $LASTEXITCODE`, which would report a fully green run as a failed step without this line.
exit 0
