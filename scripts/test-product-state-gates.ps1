#requires -Version 5

<#
Negative-path regression for the product state machine.

    powershell -NoProfile -ExecutionPolicy Bypass -File test-product-state-gates.ps1

test-product-scaffold.ps1 only ever proved that a brand-new product passes. Every gate in
validate-product-state.ps1 -- twenty-two check groups' worth -- had no test that made it fire, and
a gate nobody fires is indistinguishable from a gate that is not there: that is exactly how
INIT -> BUILD_READY stayed wide open while the validator reported zero errors.

Each scenario builds a throwaway product under $env:TEMP, breaks exactly one thing, and asserts
that the tooling says so. Nothing outside the fixture root is written and no target EXE is run.
#>

[CmdletBinding()]
param(
    [string]$SkillRoot,
    [string]$FixtureRoot = (Join-Path $env:TEMP ('eplc-gate-suite-' + [guid]::NewGuid().ToString('N').Substring(0, 8))),
    [switch]$KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$script:Skill = (Resolve-Path -LiteralPath $SkillRoot).Path
$script:Results = New-Object System.Collections.Generic.List[psobject]
New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null

function Invoke-Script {
    param([Parameter(Mandatory = $true)][string]$Name, [string[]]$ScriptArgs = @())

    $path = Join-Path $script:Skill ('scripts\' + $Name)
    $raw = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $path @ScriptArgs 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{
        Text = ($raw -join "`n")
        Lines = $raw
        # A PowerShell stack trace reaching a user who does not know PowerShell is itself a defect,
        # so every scenario can assert on it rather than only on the exit status.
        HasStackTrace = @($raw | Where-Object { $_ -match 'CategoryInfo|FullyQualifiedErrorId|At line:\d+ char:\d+' }).Count -gt 0
    }
}

function New-Fixture {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$ProductId = 'suite-product')

    $root = Join-Path $FixtureRoot $Name
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $core = Join-Path $root 'demo.exe'
    [IO.File]::WriteAllText($core, 'fixture executable bytes for ' + $Name, [Text.Encoding]::ASCII)
    $null = Invoke-Script -Name 'init-product.ps1' -ScriptArgs @('-ProductRoot', $root, '-ProductId', $ProductId, '-CorePath', $core)
    return $root
}

function Set-Status {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Status)

    # Deliberately edits both files by hand: this is the forged-status path the gate has to catch,
    # not the supported update-product-state.ps1 path.
    $statePath = Join-Path $Root 'product-state\STATE.yaml'
    $indexPath = Join-Path $Root 'product-state\PRODUCT-INDEX.md'
    $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath
    $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath
    [IO.File]::WriteAllText($statePath, ([regex]::Replace($state, '(?m)^status:.*$', ('status: "' + $Status + '"'))), (New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText($indexPath, ([regex]::Replace($index, '(?m)^(- 当前状态:\s*`)[^`]*(`)', ('${1}' + $Status + '${2}'))), (New-Object Text.UTF8Encoding($true)))
}

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Expected, [string]$Actual)

    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Expected = $Expected; Actual = $Actual })
    $label = 'FAIL'
    if ($Passed) { $label = 'PASS' }
    Write-Output ('{0}   {1,-38} expected[{2}] actual[{3}]' -f $label, $Name, $Expected, $Actual)
}

function Assert-Match {
    param([string]$Name, [string]$Text, [string]$Pattern, [switch]$Absent)

    $found = [regex]::IsMatch($Text, $Pattern)
    $want = -not $Absent.IsPresent
    $shown = 'absent'
    if ($found) { $shown = 'present' }
    $wantShown = 'absent'
    if ($want) { $wantShown = 'present' }
    Add-Result -Name $Name -Passed ($found -eq $want) -Expected $wantShown -Actual $shown
    # A gate that fails without showing what it saw is only debuggable on the machine it fails on.
    # Capped so a runaway script cannot flood the log.
    if ($found -ne $want) {
        Write-Output ('       pattern: ' + $Pattern)
        foreach ($line in @(($Text -split "`n") | Select-Object -First 40)) { Write-Output ('       | ' + $line.TrimEnd()) }
    }
}

# G1 -- the happy path still passes, and now also answers "what next".
$root = New-Fixture -Name 'g1-fresh'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G1-fresh-passes' -Text $run.Text -Pattern 'RESULT: passed'
Assert-Match -Name 'G1-emits-next-action' -Text $run.Text -Pattern '(?m)^NEXT-ACTION: '

# G2 -- the defect this suite exists for: a virgin scaffold edited to BUILD_READY used to report
# zero errors, so the one status meaning "start building" required no evidence at all.
$root = New-Fixture -Name 'g2-forged-build-ready'
Set-Status -Root $root -Status 'BUILD_READY'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G2-forged-build-ready-fails' -Text $run.Text -Pattern 'RESULT: failed'
Assert-Match -Name 'G2-names-missing-evidence' -Text $run.Text -Pattern 'is not backed by the evidence'

# G3 -- the far end of the ladder must stay closed too.
$root = New-Fixture -Name 'g3-forged-released'
Set-Status -Root $root -Status 'RELEASED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G3-forged-released-fails' -Text $run.Text -Pattern 'RESULT: failed'

# G4 -- dropping the new upstream build into the product folder under a new name. The most natural
# thing a beginner does, and previously invisible: incoming/ stayed empty and validation passed.
$root = New-Fixture -Name 'g4-unregistered-input'
[IO.File]::WriteAllText((Join-Path $root 'demo-v2.exe'), 'a brand new upstream build', [Text.Encoding]::ASCII)
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G4-unregistered-input-seen' -Text $run.Text -Pattern 'demo-v2\.exe'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'incoming') | Out-Null
Move-Item -LiteralPath (Join-Path $root 'demo-v2.exe') -Destination (Join-Path $root 'incoming\demo-v2.exe')
$null = Invoke-Script -Name 'register-input-bundle.ps1' -ScriptArgs @('-ProductRoot', $root, '-InputRoot', 'incoming')
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G4-clean-after-register' -Text $run.Text -Pattern 'demo-v2\.exe' -Absent

# G5 -- one YAML dialect across all three scripts. `product_id: foo` is valid YAML that the
# validator accepts; both writers used to reject it with a raw PowerShell stack trace.
$root = New-Fixture -Name 'g5-unquoted-id' -ProductId 'unquoted-product'
$statePath = Join-Path $root 'product-state\STATE.yaml'
$state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath
[IO.File]::WriteAllText($statePath, ($state -replace 'product_id: "unquoted-product"', 'product_id: unquoted-product'), (New-Object Text.UTF8Encoding($true)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G5-validator-accepts' -Text $run.Text -Pattern 'RESULT: passed'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'incoming') | Out-Null
[IO.File]::WriteAllText((Join-Path $root 'incoming\note.md'), '# later note', (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'register-input-bundle.ps1' -ScriptArgs @('-ProductRoot', $root, '-InputRoot', 'incoming')
Assert-Match -Name 'G5-register-accepts' -Text $run.Text -Pattern '"status":\s+"preserved"'
Add-Result -Name 'G5-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })

# G6 -- a refused operation must explain itself in the user's language, not in PowerShell's.
$root = New-Fixture -Name 'g6-friendly-error' -ProductId 'right-id'
$run = Invoke-Script -Name 'init-product.ps1' -ScriptArgs @('-ProductRoot', $root, '-ProductId', 'wrong-id', '-CorePath', (Join-Path $root 'demo.exe'))
Assert-Match -Name 'G6-explains-in-chinese' -Text $run.Text -Pattern '怎么办:'
Add-Result -Name 'G6-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })

# G7 -- mode was the third copy of the truth and the only one nobody compared.
$root = New-Fixture -Name 'g7-mode-drift'
$statePath = Join-Path $root 'product-state\STATE.yaml'
$state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath
[IO.File]::WriteAllText($statePath, ($state -replace 'mode: "bootstrap"', 'mode: "update"'), (New-Object Text.UTF8Encoding($true)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G7-mode-drift-caught' -Text $run.Text -Pattern 'current mode does not match'

# G8 -- the supported transition path updates both files together and stays valid.
$root = New-Fixture -Name 'g8-transition'
$run = Invoke-Script -Name 'update-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-Status', 'BASELINE_CREATED', '-Mode', 'resume')
Assert-Match -Name 'G8-transition-applied' -Text $run.Text -Pattern '"to_status":\s+"BASELINE_CREATED"'
$indexText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'product-state\PRODUCT-INDEX.md')
Assert-Match -Name 'G8-index-follows-state' -Text $indexText -Pattern '当前状态: `BASELINE_CREATED`'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G8-still-valid' -Text $run.Text -Pattern 'RESULT: passed'

# G9 -- the writer refuses the same jump the validator would flag, and refuses it before writing.
$root = New-Fixture -Name 'g9-illegal-jump'
$before = (Get-FileHash -LiteralPath (Join-Path $root 'product-state\STATE.yaml') -Algorithm SHA256).Hash
$run = Invoke-Script -Name 'update-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-Status', 'BUILD_READY')
$after = (Get-FileHash -LiteralPath (Join-Path $root 'product-state\STATE.yaml') -Algorithm SHA256).Hash
Assert-Match -Name 'G9-jump-refused' -Text $run.Text -Pattern '还不能把状态改成'
Add-Result -Name 'G9-nothing-written' -Passed ($before -eq $after) -Expected 'unchanged' -Actual $(if ($before -eq $after) { 'unchanged' } else { 'modified' })

# G10 -- an interrupted transition. The journal has a reader and, since this round, a writer; the
# pair is only worth anything if a half-finished transition can actually be finished.
$root = New-Fixture -Name 'g10-journal-replay'
$statePath = Join-Path $root 'product-state\STATE.yaml'
$stateText = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath
$intendedText = $stateText -replace '(?m)^status:.*$', 'status: "BASELINE_CREATED"'
$encoder = New-Object Text.UTF8Encoding($true)
$intendedBytes = $encoder.GetPreamble() + [Text.Encoding]::UTF8.GetBytes($intendedText + [Environment]::NewLine)
$sha = [Security.Cryptography.SHA256]::Create()
$intendedHash = ([BitConverter]::ToString($sha.ComputeHash($intendedBytes)) -replace '-', '').ToUpperInvariant()
$sha.Dispose()
$journal = [pscustomobject]@{
    schema_version = 1
    journal_id = 'txn-fixture'
    product_id = 'suite-product'
    created_at = (Get-Date).ToString('o')
    transition = [pscustomobject]@{ from_status = 'INIT'; to_status = 'BASELINE_CREATED' }
    targets = @([pscustomobject]@{
        path = 'product-state/STATE.yaml'
        sha256_before = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToUpperInvariant()
        sha256_intended = $intendedHash
        content_b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($intendedText))
    })
}
[IO.File]::WriteAllText((Join-Path $root 'product-state\.state-journal.json'), ($journal | ConvertTo-Json -Depth 6), $encoder)
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G10-interruption-reported' -Text $run.Text -Pattern 'state journal txn-fixture'
$run = Invoke-Script -Name 'update-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-ResumeJournal')
Assert-Match -Name 'G10-journal-replayed' -Text $run.Text -Pattern '"status":\s+"journal_replayed"'
$stateAfter = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath
Assert-Match -Name 'G10-transition-completed' -Text $stateAfter -Pattern 'status: "BASELINE_CREATED"'
Add-Result -Name 'G10-journal-cleared' -Passed (-not (Test-Path -LiteralPath (Join-Path $root 'product-state\.state-journal.json'))) -Expected 'cleared' -Actual $(if (Test-Path -LiteralPath (Join-Path $root 'product-state\.state-journal.json')) { 'still-there' } else { 'cleared' })

# G11 -- a new transition must not start on top of an unfinished one.
$root = New-Fixture -Name 'g11-journal-blocks'
[IO.File]::WriteAllText((Join-Path $root 'product-state\.state-journal.json'), ($journal | ConvertTo-Json -Depth 6), $encoder)
$run = Invoke-Script -Name 'update-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-Status', 'BASELINE_CREATED')
Assert-Match -Name 'G11-blocked-by-journal' -Text $run.Text -Pattern '未完成'

# G12 -- a truncated state file is the residue of a killed write. The validator must report it
# rather than crash on the first regex that reads it.
$root = New-Fixture -Name 'g12-truncated'
[IO.File]::WriteAllText((Join-Path $root 'product-state\EVIDENCE-LEDGER.yaml'), '', (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G12-truncation-reported' -Text $run.Text -Pattern 'file is empty'
Assert-Match -Name 'G12-coverage-complete' -Text $run.Text -Pattern 'COVERAGE: \d+/\d+ check group\(s\) completed, 0 not run'

# G13 -- a recorded path is a claim about this product's own files; "../" walks the hash check out
# of the product, where the bytes still verify and simply are not the product's bytes.
$root = New-Fixture -Name 'g13-traversal'
$statePath = Join-Path $root 'product-state\STATE.yaml'
$state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath
[IO.File]::WriteAllText($statePath, ([regex]::Replace($state, '(?m)^baseline_artifact:.*$', 'baseline_artifact: "../outside.exe"')), (New-Object Text.UTF8Encoding($true)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'G13-traversal-refused' -Text $run.Text -Pattern 'points outside the product directory'

# S1..S4 -- the mandatory entry point. It is the mechanism that keeps an agent on the rails, so it
# needs the same coverage as the gates it dispatches to: pick the right mode, put input
# registration before everything else, and never write to the product while doing it.
$root = Join-Path $FixtureRoot 's-entry'
New-Item -ItemType Directory -Force -Path $root | Out-Null
[IO.File]::WriteAllText((Join-Path $root 'MyApp.exe'), 'entry fixture bytes', [Text.Encoding]::ASCII)
$run = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'S1-bootstrap-detected' -Text $run.Text -Pattern '(?m)^模式: bootstrap'
Assert-Match -Name 'S1-names-init-command' -Text $run.Text -Pattern 'init-product\.ps1'

$null = Invoke-Script -Name 'init-product.ps1' -ScriptArgs @('-ProductRoot', $root, '-ProductId', 'entry-product', '-CorePath', (Join-Path $root 'MyApp.exe'))
$beforeState = @(Get-ChildItem -LiteralPath (Join-Path $root 'product-state') -Recurse -File | Sort-Object FullName |
    ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
$run = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root, '-UserRequest', '继续维护这个产品')
Assert-Match -Name 'S2-continue-is-resume' -Text $run.Text -Pattern '(?m)^模式: resume'
$afterState = @(Get-ChildItem -LiteralPath (Join-Path $root 'product-state') -Recurse -File | Sort-Object FullName |
    ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
Add-Result -Name 'S2-entry-point-is-read-only' -Passed (($beforeState -join '|') -eq ($afterState -join '|')) -Expected 'unchanged' -Actual $(if (($beforeState -join '|') -eq ($afterState -join '|')) { 'unchanged' } else { 'modified' })

[IO.File]::WriteAllText((Join-Path $root 'MyApp-v2.exe'), 'a newer upstream build', [Text.Encoding]::ASCII)
$run = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root, '-UserRequest', '把新版更新进来')
Assert-Match -Name 'S3-loose-input-switches-to-update' -Text $run.Text -Pattern '(?m)^模式: update'
Assert-Match -Name 'S3-registration-comes-first' -Text $run.Text -Pattern '1\. \[先做这个\].*MyApp-v2\.exe'
Remove-Item -LiteralPath (Join-Path $root 'MyApp-v2.exe') -Force

$run = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root, '-UserRequest', '现在做到哪一步了')
Assert-Match -Name 'S4-question-is-status' -Text $run.Text -Pattern '(?m)^模式: status'
Assert-Match -Name 'S4-status-forbids-writes' -Text $run.Text -Pattern '不要修改任何文件'

# P1 -- protection assessment is a precondition for ANALYZED. Whether the target can be patched,
# only wrapped, or must be rebuilt is decided by what protects it, so declaring "analysed" while the
# protection profile is still PENDING is the same false claim the lifecycle gate exists to stop.
$root = New-Fixture -Name 'p1-protection-gate'
Set-Status -Root $root -Status 'ANALYZED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'P1-protection-required-for-analyzed' -Text $run.Text -Pattern '保护机制'

# P2 -- detect-protections end to end against a real PE that exists everywhere (cmd.exe). It must not
# need DIE to be installed: without it the script falls back to entropy + string scanning and still
# produces an assessed profile, which is what lets it run on a bare CI machine.
$p2 = Join-Path $FixtureRoot 'p2-detect'
New-Item -ItemType Directory -Force -Path $p2 | Out-Null
$realExe = Join-Path $p2 'core.exe'
[IO.File]::Copy((Join-Path $env:SystemRoot 'System32\cmd.exe'), $realExe, $true)
$null = Invoke-Script -Name 'init-product.ps1' -ScriptArgs @('-ProductRoot', $p2, '-ProductId', 'detect-product', '-CorePath', $realExe)
$run = Invoke-Script -Name 'detect-protections.ps1' -ScriptArgs @('-ProductRoot', $p2)
Assert-Match -Name 'P2-detect-runs-clean' -Text $run.Text -Pattern '"status":\s+"assessed"'
Add-Result -Name 'P2-detect-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })
$profileText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $p2 'product-state\PROTECTION-PROFILE.yaml')
Assert-Match -Name 'P2-profile-assessed' -Text $profileText -Pattern 'status:\s*"ASSESSED"'
$verdict = [regex]::Match($profileText, '(?m)^\s*verdict:\s*"([^"]+)"')
$verdictOk = $verdict.Success -and $verdict.Groups[1].Value -in @('CAN_PATCH', 'OVERLAY_ONLY', 'WRAPPER_ONLY', 'REBUILD_REQUIRED', 'UNKNOWN')
Add-Result -Name 'P2-verdict-is-legal' -Passed $verdictOk -Expected 'legal-verdict' -Actual $(if ($verdict.Success) { $verdict.Groups[1].Value } else { '(none)' })

# P3 -- re-running without -Force must refuse rather than silently redo, so a manual assessment is
# not clobbered by an automatic pass.
$run = Invoke-Script -Name 'detect-protections.ps1' -ScriptArgs @('-ProductRoot', $p2)
Assert-Match -Name 'P3-reassess-refused-without-force' -Text $run.Text -Pattern '已经探测过'

# BS -- the binding-strength gate on AUTH_CONTRACT_READY. "The launcher is bound to the core" is
# exactly where "claimed strong, proved nothing" hides, so the gate honours a claimed tier only
# when the evidence THAT tier needs is settled. The ladder is cumulative, so this fixture keeps
# failing on the rungs below it; every assertion looks only at whether binding_strength_backed is
# the requirement firing, which is the single thing this gate controls.
function Set-ContractField {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
    $text = [regex]::Replace($text, ('(?m)^(\s*{0}:\s*")[^"]*(")' -f [regex]::Escape($Key)), ('${1}' + $Value + '${2}'))
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}

$root = New-Fixture -Name 'bs-binding-strength'
Set-Status -Root $root -Status 'AUTH_CONTRACT_READY'
$contract = Join-Path $root 'product-state\auth\LAUNCH-CONTRACT.yaml'
# A virgin scaffold claims tier UNKNOWN, which is no claim at all: the gate must fire.
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'BS1-unset-tier-caught' -Text $run.Text -Pattern 'binding_strength_backed'

# Claim the strongest tier (A) but produce only the wrapper-only acknowledgement tier C asks for.
# This is the approximation attack the tiering exists to stop -- a strong claim standing on weak
# evidence -- and using a near-miss (right shape, wrong tier) rather than blank fields is what
# proves the gate reads the claimed tier, not merely "some evidence is present".
Set-ContractField -Path $contract -Key 'verified_tier' -Value 'C'
Set-ContractField -Path $contract -Key 'bypass_risk' -Value '直接运行核心即可绕过登录门'
Set-ContractField -Path $contract -Key 'evidence_c_wrapper_only_ack' -Value '已确认仅外壳，核心可被直接运行'
Set-ContractField -Path $contract -Key 'claimed_tier' -Value 'A'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'BS2-claim-A-on-C-evidence-caught' -Text $run.Text -Pattern 'binding_strength_backed'

# Honestly declare tier C with the evidence C needs. The gate must clear -- and because the
# assertion is Absent, this is the mutation guard: it fails if the gate can never be satisfied
# (a gate stuck on always-fire is as broken as one that never fires).
Set-ContractField -Path $contract -Key 'claimed_tier' -Value 'C'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'BS3-honest-C-clears-gate' -Text $run.Text -Pattern 'binding_strength_backed' -Absent

# SN -- Windows gives one directory two names: C:\Users\RUNNER~1\x and C:\Users\runneradmin\x.
# Every containment check in the validator is a string prefix test, so a product reached through
# the 8.3 alias was reported as escaping its own directory and its relative paths came out sliced
# mid-name. It stayed invisible because it is green on any machine whose product path has no short
# name in it. Creating an alias needs an elevated shell, so this says SKIP rather than pass falsely.
$snParent = Join-Path $FixtureRoot 'sn-shortpath'
New-Item -ItemType Directory -Force -Path (Join-Path $snParent 'canonical-long-name') | Out-Null
$null = & fsutil file setshortname (Join-Path $snParent 'canonical-long-name') 'SHORTN~1' 2>&1
$snShort = Join-Path $snParent 'SHORTN~1'
if (Test-Path -LiteralPath $snShort -PathType Container) {
    $root = Join-Path $snShort 'product'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'demo.exe'), 'short path fixture bytes', [Text.Encoding]::ASCII)
    $null = Invoke-Script -Name 'init-product.ps1' -ScriptArgs @('-ProductRoot', $root, '-ProductId', 'shortpath-product', '-CorePath', (Join-Path $root 'demo.exe'))
    $run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
    Assert-Match -Name 'SN1-short-path-product-passes' -Text $run.Text -Pattern 'RESULT: passed'
    Assert-Match -Name 'SN2-no-false-escape' -Text $run.Text -Pattern 'points outside the product directory' -Absent
}
else {
    Write-Output 'SKIP   SN1-short-path-product-passes    could not create an 8.3 alias (needs an elevated shell)'
}

$failed = @($script:Results | Where-Object { -not $_.Passed })
Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f @($script:Results | Where-Object { $_.Passed }).Count, $failed.Count)
if (-not $KeepFixture -and (Test-Path -LiteralPath $FixtureRoot -PathType Container)) {
    Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed.Count -gt 0) { exit 1 }
