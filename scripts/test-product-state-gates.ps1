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

# SR -- a hand-edited or skip-polluted status the lifecycle table does not recognise used to yield
# only a prose ERROR line and no NEXT at all, so an agent re-improvised the order (the ISSUE-096
# relapse). The validator must now fail loud and MACHINE-READABLE: a STATE_REPAIR_REQUIRED line, a
# next action, and the legal values. Delete the repair branch and all three assertions go red.
$root = New-Fixture -Name 'sr-unknown-status'
Set-Status -Root $root -Status 'TOTALLY_BOGUS_STATUS'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'SR1-repair-required-emitted' -Text $run.Text -Pattern '(?m)^STATE_REPAIR_REQUIRED: '
Assert-Match -Name 'SR1-names-next-action' -Text $run.Text -Pattern '(?m)^NEXT-ACTION: '
Assert-Match -Name 'SR1-lists-legal-values' -Text $run.Text -Pattern '(?m)^BLOCKING-FACTS: .*BASELINE_CREATED'

# SR2 -- the mandatory entry point must self-heal a polluted status the same way the validator does.
# start-here used to derive every step from the status, so an unrecognised one produced empty
# "继续..." steps and no NEXT -- the same ISSUE-096 relapse, at the one place an agent looks first.
$root = New-Fixture -Name 'sr2-entry-unknown-status'
Set-Status -Root $root -Status 'TOTALLY_BOGUS_STATUS'
$run = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'SR2-entry-repair-required' -Text $run.Text -Pattern '(?m)^STATE_REPAIR_REQUIRED: '
Assert-Match -Name 'SR2-entry-names-next-action' -Text $run.Text -Pattern '(?m)^NEXT-ACTION: '

# SR3 -- the validator's recognised-status set is derived from the lifecycle table, not a second
# hardcoded copy that drifts from it (ISSUE-096's root: the table gained a state the copy lacked).
# A branch status that lives only in the table -- the kind a hardcoded copy forgets -- must be
# recognised: STATE present, and NOT flagged "no recognized status".
$root = New-Fixture -Name 'sr3-table-status-recognised'
Set-Status -Root $root -Status 'MIGRATION_REQUIRED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'SR3-status-recognised-anchor' -Text $run.Text -Pattern '(?m)^STATE: MIGRATION_REQUIRED'
Assert-Match -Name 'SR3-not-rejected-as-unknown' -Text $run.Text -Pattern 'has no recognized status' -Absent

# SR4 -- the writer validates -Status against the same table (not a [ValidateSet] second copy that
# drifts), refuses an unknown one in the user's language, writes nothing, and shows no stack trace.
$root = New-Fixture -Name 'sr4-writer-unknown-status'
$before = (Get-FileHash -LiteralPath (Join-Path $root 'product-state\STATE.yaml') -Algorithm SHA256).Hash
$run = Invoke-Script -Name 'update-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-Status', 'TOTALLY_BOGUS_STATUS')
$after = (Get-FileHash -LiteralPath (Join-Path $root 'product-state\STATE.yaml') -Algorithm SHA256).Hash
Assert-Match -Name 'SR4-writer-rejects-unknown' -Text $run.Text -Pattern '不认识的状态'
Add-Result -Name 'SR4-nothing-written' -Passed ($before -eq $after) -Expected 'unchanged' -Actual $(if ($before -eq $after) { 'unchanged' } else { 'modified' })
Add-Result -Name 'SR4-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })

# PB1 -- Phase B route/slice gate: a product cannot claim BUILD_READY (ready to build/package) until
# it has chosen a rebuild route AND defined a user-testable slice. This is the user's top anti-drift
# rule -- "no route decision + no user-testable slice -> no packaging". A freshly-initialised product
# has both scaffolds at their unsettled defaults, so forging BUILD_READY must name both as missing
# evidence. Remove either requirement from lifecycle-states.json and the matching assertion goes red.
$root = New-Fixture -Name 'pb1-route-slice-gate'
Set-Status -Root $root -Status 'BUILD_READY'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'PB1-route-decision-gates-build' -Text $run.Text -Pattern 'ROUTE-DECISION\.yaml'
Assert-Match -Name 'PB1-user-testable-slice-gates-build' -Text $run.Text -Pattern 'USER-TESTABLE-SLICE\.yaml'

# PB2 -- GAP-4 fidelity floor: a MODEL_ONLY / STUB / FIXTURE_ONLY core is a shell or a sample, never a
# real product, so it must never satisfy real VERIFIED (Codex counter-example C). A RECONSTRUCTED core
# must NOT trip this specific gate -- the mutation guard against a gate stuck on always-fire.
$root = New-Fixture -Name 'pb2-fidelity-floor'
Set-Status -Root $root -Status 'VERIFIED'
$maint = Join-Path $root 'product-state\MAINTENANCE-MODE.yaml'
Set-ContractField -Path $maint -Key 'core_fidelity' -Value 'MODEL_ONLY'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'PB2-model-only-blocks-verified' -Text $run.Text -Pattern 'cannot rest on a MODEL_ONLY core'
Set-ContractField -Path $maint -Key 'core_fidelity' -Value 'RECONSTRUCTED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'PB2-reconstructed-not-blocked' -Text $run.Text -Pattern 'cannot rest on a' -Absent

# PB3 -- the scoreboard: one honest distance number, computed from evidence, never self-declared. A
# fresh product reads 'none'; a product that has settled its route AND its user-testable slice reads
# 'slice-defined' -- NOT 'user-testable'. That gap is the whole point: a narrow rung must never read
# as the wide goal. Remove the emit and the first assertion goes red; misclassify and the second does.
$root = New-Fixture -Name 'pb3-scoreboard-none'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'PB3-fresh-is-none' -Text $run.Text -Pattern '(?m)^CURRENT-USER-TESTABILITY: none'
$root = New-Fixture -Name 'pb3-scoreboard-slice-defined'
Set-ContractField -Path (Join-Path $root 'product-state\analysis\ROUTE-DECISION.yaml') -Key 'chosen_route' -Value 'WRAPPER_LAUNCHER'
Set-ContractField -Path (Join-Path $root 'product-state\analysis\USER-TESTABLE-SLICE.yaml') -Key 'slice_status' -Value 'DEFINED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'PB3-route-slice-is-slice-defined' -Text $run.Text -Pattern '(?m)^CURRENT-USER-TESTABILITY: slice-defined'

# VT -- the through-line evidence gate (second half of RV-A#1). Nothing used to read
# VERIFICATION-RECORD.md, so a real VERIFIED could stand on the all-PENDING scaffold. Forging VERIFIED
# must be caught while the record is still scaffold; flipping the 关键验收 result column to PASS clears
# the row check but NOT while overall_result is still PENDING (the two are independent); settling both
# clears the gate -- the mutation guard proving it is not stuck always-firing. Delete either check in
# validate-product-state.ps1 and the matching assertion goes red.
$root = New-Fixture -Name 'vt-throughline-gate'
Set-Status -Root $root -Status 'VERIFIED'
$rec = Join-Path $root 'product-state\reports\VERIFICATION-RECORD.md'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'VT1-scaffold-rows-caught' -Text $run.Text -Pattern '关键验收 仍有未通过的行'
[IO.File]::WriteAllText($rec, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $rec) -replace '`PENDING` \|', '`PASS` |'), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'VT2-rows-pass-clears-row-check' -Text $run.Text -Pattern '关键验收 仍有未通过的行' -Absent
Assert-Match -Name 'VT2-overall-still-caught' -Text $run.Text -Pattern 'overall_result 不是 PASS'
[IO.File]::WriteAllText($rec, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $rec) -replace 'overall_result`: `PENDING`', 'overall_result`: `PASS`'), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'VT3-throughline-cleared' -Text $run.Text -Pattern 'VERIFICATION-RECORD\.md' -Absent

# RB -- runnable rollback gate (RV-C-G3). requiredFiles only proved the runbook file exists; its content
# was never read, so a real VERIFIED could ship the <ROLLBACK_COMMAND> template with an UNVERIFIED
# target. Forging VERIFIED must be caught for BOTH the command placeholder AND the missing 64-hex
# package hash; filling a real command plus a real hash clears exactly this gate (mutation guard).
$root = New-Fixture -Name 'rb-rollback-runbook'
Set-Status -Root $root -Status 'VERIFIED'
$rb = Join-Path $root 'product-state\rollback\ROLLBACK-RUNBOOK.md'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RB1-command-placeholder-caught' -Text $run.Text -Pattern '还留着命令占位符'
Assert-Match -Name 'RB2-missing-package-hash-caught' -Text $run.Text -Pattern '没有登记回滚目标包的 SHA-256'
$rbText = Get-Content -Raw -Encoding UTF8 -LiteralPath $rb
$rbText = $rbText -replace '<[A-Za-z0-9_]+>', 'Copy-Item -Force product-state\artifacts\rollback\prev-release.bin app.exe'
$rbText = $rbText -replace 'UNVERIFIED', ('a' * 64)
[IO.File]::WriteAllText($rb, $rbText, (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
# RV-R2 bypass #4: placeholders gone and a 64-hex present, but no real package hashes to it -> theater.
Assert-Match -Name 'RB3-hash-without-package-caught' -Text $run.Text -Pattern '没有对应任何已保存的回滚包'
$rbPkgDir = Join-Path $root 'product-state\artifacts\rollback'
New-Item -ItemType Directory -Force -Path $rbPkgDir | Out-Null
[IO.File]::WriteAllText((Join-Path $rbPkgDir 'prev-release.bin'), 'previous verified release bytes', (New-Object Text.UTF8Encoding($false)))
$rbHash = (Get-FileHash -LiteralPath (Join-Path $rbPkgDir 'prev-release.bin') -Algorithm SHA256).Hash
[IO.File]::WriteAllText($rb, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $rb) -replace ('a' * 64), $rbHash), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RB4-real-package-clears-binding' -Text $run.Text -Pattern '没有对应任何已保存的回滚包' -Absent
Assert-Match -Name 'RB4-runbook-fully-clears' -Text $run.Text -Pattern 'ROLLBACK-RUNBOOK\.md' -Absent
# RB5 -- N1 hardening: a 0-byte rollback package (sha256 = empty-file constant) is not a real rollback
# target. Point the runbook only at an empty file's hash -> must be caught. Revert the 0-byte skip in the
# rollback binding of validate-product-state.ps1 and this goes red.
$rbEmpty = Join-Path $rbPkgDir 'empty-rb.bin'
[IO.File]::WriteAllText($rbEmpty, '', (New-Object Text.UTF8Encoding($false)))
$rbEmptyHash = (Get-FileHash -LiteralPath $rbEmpty -Algorithm SHA256).Hash
[IO.File]::WriteAllText($rb, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $rb) -replace $rbHash, $rbEmptyHash), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RB5-empty-rollback-package-caught' -Text $run.Text -Pattern '没有对应任何已保存的回滚包'

# NE -- N-EPLC-5 hardening: the product body itself (core/baseline) must not be a 0-byte empty file. Init a
# product whose core is literally 0 bytes (init-product records baseline_sha256 = the empty-file constant),
# force VERIFIED, and validate must catch the empty baseline. Revert the empty-constant baseline check in
# validate-product-state.ps1 (state-identity) and this goes red.
$neRoot = Join-Path $FixtureRoot 'ne-empty-core'
New-Item -ItemType Directory -Force -Path $neRoot | Out-Null
[IO.File]::WriteAllText((Join-Path $neRoot 'demo.exe'), '', (New-Object Text.UTF8Encoding($false)))
$null = Invoke-Script -Name 'init-product.ps1' -ScriptArgs @('-ProductRoot', $neRoot, '-ProductId', 'ne-product', '-CorePath', (Join-Path $neRoot 'demo.exe'))
Set-Status -Root $neRoot -Status 'VERIFIED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $neRoot)
Assert-Match -Name 'NE1-empty-core-baseline-caught' -Text $run.Text -Pattern 'baseline_sha256 是空文件常量'

# EL -- evidence ledger is real, not decorative (RV-C-G4). A forged VERIFIED with entries: [] must be
# caught; adding one static_present entry clears the empty check but NOT the runtime-level check;
# a dynamic_success entry clears the gate. static_present ("文件在") is never "it actually ran".
$root = New-Fixture -Name 'el-evidence-ledger'
Set-Status -Root $root -Status 'VERIFIED'
$ledger = Join-Path $root 'product-state\EVIDENCE-LEDGER.yaml'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'EL1-empty-entries-caught' -Text $run.Text -Pattern 'entries 为空'
[IO.File]::WriteAllText($ledger, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $ledger) -replace 'entries: \[\]', "entries:`n  - id: e1`n    evidence_level: static_present"), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'EL2-empty-cleared' -Text $run.Text -Pattern 'entries 为空' -Absent
Assert-Match -Name 'EL2-static-only-caught' -Text $run.Text -Pattern '没有任何运行期证据'
[IO.File]::WriteAllText($ledger, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $ledger) -replace 'static_present', 'dynamic_success'), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'EL3-runtime-evidence-clears' -Text $run.Text -Pattern '没有任何运行期证据' -Absent

# EB -- fabricate-from-nothing defense (RV-R2). The adversarial review pushed a fake product to a green
# VERIFIED using text-only evidence. A runtime ledger entry must now bind to a REAL hash-consistent
# artifact file, not just a typed level: forging VERIFIED with a text-only dynamic_success entry must
# fail; adding a real artifact whose sha256 matches clears exactly this binding (mutation guard).
$root = New-Fixture -Name 'eb-evidence-binding'
Set-Status -Root $root -Status 'VERIFIED'
$ledger = Join-Path $root 'product-state\EVIDENCE-LEDGER.yaml'
[IO.File]::WriteAllText($ledger, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $ledger) -replace 'entries: \[\]', "entries:`n  - id: e1`n    evidence_level: dynamic_success"), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'EB1-text-only-evidence-fabrication-caught' -Text $run.Text -Pattern '没有绑定真实产物'
$evidenceDir = Join-Path $root 'product-state\artifacts\verification'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
[IO.File]::WriteAllText((Join-Path $evidenceDir 'run-log.txt'), 'real run receipt: exit 0', (New-Object Text.UTF8Encoding($false)))
$evidenceHash = (Get-FileHash -LiteralPath (Join-Path $evidenceDir 'run-log.txt') -Algorithm SHA256).Hash
$ledgerBody = "entries:`n  - id: e1`n    evidence_level: dynamic_success`n    path: `"product-state/artifacts/verification/run-log.txt`"`n    sha256: `"$evidenceHash`""
[IO.File]::WriteAllText($ledger, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $ledger) -replace '(?s)entries:.*?(?=\r?\nrules:)', $ledgerBody), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'EB2-real-artifact-clears-binding' -Text $run.Text -Pattern '没有绑定真实产物' -Absent
# EB3 -- F1 hardening: a 0-byte evidence file is not a real artifact. Binding the ledger to an empty file
# must NOT clear the gate. Revert the non-empty check in Test-BoundEvidenceFile and this goes red.
[IO.File]::WriteAllText((Join-Path $evidenceDir 'empty-run.bin'), '', (New-Object Text.UTF8Encoding($false)))
$emptyEvidenceHash = (Get-FileHash -LiteralPath (Join-Path $evidenceDir 'empty-run.bin') -Algorithm SHA256).Hash
$ledgerZeroBody = "entries:`n  - id: e1`n    evidence_level: dynamic_success`n    path: `"product-state/artifacts/verification/empty-run.bin`"`n    sha256: `"$emptyEvidenceHash`""
[IO.File]::WriteAllText($ledger, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $ledger) -replace '(?s)entries:.*?(?=\r?\nrules:)', $ledgerZeroBody), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'EB3-empty-file-evidence-caught' -Text $run.Text -Pattern '没有绑定真实产物'

# AF -- reverse-engineering findings must be real, not typed (提高 EXE 二开 + 反捏造, mirrors EB). Forging
# VERIFIED with empty findings must be caught; a text-only finding (path/sha256 pointing at nothing) must
# be caught; a finding bound to a real hash-consistent tool output clears exactly this gate. Delete the
# ANALYSIS-FINDINGS binding block in validate-product-state.ps1 and the first two assertions go red;
# make the gate impossible to satisfy and the last (Absent) assertion goes red.
$root = New-Fixture -Name 'af-analysis-findings'
Set-Status -Root $root -Status 'VERIFIED'
$findings = Join-Path $root 'product-state\analysis\ANALYSIS-FINDINGS.yaml'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'AF1-empty-findings-caught' -Text $run.Text -Pattern 'findings 为空'
$afTextOnly = "findings:`n  - id: f1`n    technique: static_structure`n    path: `"product-state/artifacts/analysis/nope.txt`"`n    sha256: `"$('a' * 64)`""
[IO.File]::WriteAllText($findings, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $findings) -replace 'findings: \[\]', $afTextOnly), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'AF2-empty-cleared' -Text $run.Text -Pattern 'findings 为空' -Absent
Assert-Match -Name 'AF2-text-only-finding-caught' -Text $run.Text -Pattern '没有落到真实工具输出'
$afDir = Join-Path $root 'product-state\artifacts\analysis'
New-Item -ItemType Directory -Force -Path $afDir | Out-Null
[IO.File]::WriteAllText((Join-Path $afDir 'dumpbin-headers.txt'), 'FILE HEADER VALUES: machine (x64), 6 number of sections', (New-Object Text.UTF8Encoding($false)))
$afHash = (Get-FileHash -LiteralPath (Join-Path $afDir 'dumpbin-headers.txt') -Algorithm SHA256).Hash
$afBody = "findings:`n  - id: f1`n    technique: static_structure`n    tool: dumpbin`n    path: `"product-state/artifacts/analysis/dumpbin-headers.txt`"`n    sha256: `"$afHash`""
[IO.File]::WriteAllText($findings, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $findings) -replace '(?s)findings:.*?(?=\r?\nsource_of_truth:)', $afBody), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'AF3-real-artifact-clears-binding' -Text $run.Text -Pattern '没有落到真实工具输出' -Absent
# AF4 -- F1 hardening: a 0-byte tool-output file is not a real finding. Binding to an empty file must NOT
# clear the gate. Revert the non-empty check in Test-BoundEvidenceFile and this goes red.
[IO.File]::WriteAllText((Join-Path $afDir 'empty-dump.txt'), '', (New-Object Text.UTF8Encoding($false)))
$emptyFindingHash = (Get-FileHash -LiteralPath (Join-Path $afDir 'empty-dump.txt') -Algorithm SHA256).Hash
$afZeroBody = "findings:`n  - id: f1`n    technique: static_structure`n    tool: dumpbin`n    path: `"product-state/artifacts/analysis/empty-dump.txt`"`n    sha256: `"$emptyFindingHash`""
[IO.File]::WriteAllText($findings, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $findings) -replace '(?s)findings:.*?(?=\r?\nsource_of_truth:)', $afZeroBody), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'AF4-empty-file-finding-caught' -Text $run.Text -Pattern '没有落到真实工具输出'

# AN -- 六类逆向必须逐类决定 (opening b). ANALYZED used to gate only ANALYSIS-FINDINGS' overall status, so an
# agent could type status: ASSESSED while disassembly/dynamic_behavior/unpacking stayed PENDING -- the
# "reverse engineering was done" claim the gate accepted was a lie. Each of the six category fields is now
# its own yaml_settled requirement: leaving any one PENDING must be named; settling it clears exactly that
# line. Delete a category requirement from lifecycle-states.json and AN1 goes red; make it unsatisfiable and
# AN2 goes red (mutation guard against a gate stuck always-firing).
$root = New-Fixture -Name 'an-findings-per-category'
Set-Status -Root $root -Status 'ANALYZED'
$af = Join-Path $root 'product-state\analysis\ANALYSIS-FINDINGS.yaml'
$afText = Get-Content -Raw -Encoding UTF8 -LiteralPath $af
$afText = $afText -replace '(?m)^status:.*$', 'status: "ASSESSED"'
foreach ($k in @('static_structure', 'static_strings', 'static_resources', 'dynamic_behavior', 'unpacking')) {
    $afText = [regex]::Replace($afText, ('(?m)^(' + $k + '):.*$'), ('$1: "done"'))
}
[IO.File]::WriteAllText($af, $afText, (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'AN1-missing-category-caught' -Text $run.Text -Pattern '\(disassembly\)'
[IO.File]::WriteAllText($af, ([regex]::Replace($afText, '(?m)^(disassembly):.*$', '$1: "done"')), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'AN2-category-settled-clears' -Text $run.Text -Pattern '\(disassembly\)' -Absent

# CU -- 脱壳是动作不是探测 (opening c). detect-protections only *detects* packing; nothing tied that detection
# to the unpacking decision, so a packed target (WRAPPER_ONLY / high entropy / named packer) could still
# mark unpacking: not_applicable and pass ANALYZED. unpacking_consistent_with_protection now forces a packed
# target's unpacking to be done or blocked. CU1: packed + not_applicable must be named; CU2: flipping it to
# done clears exactly that line; CU3: a not-packed target may keep not_applicable (mutation guard against a
# rule stuck always-firing). Delete the requirement/kind and CU1 goes red; make it fire on clean and CU3 does.
$cuPacked = @'
schema_version: 1
product_id: "suite-product"
status: "ASSESSED"
packing:
  detector: "DIE"
  packer: "UPX(4.0)[NRV,best]"
  entropy_total: "7.95"
modifiability:
  verdict: "WRAPPER_ONLY"
  reason: "packed"
'@
$cuClean = @'
schema_version: 1
product_id: "suite-product"
status: "ASSESSED"
packing:
  detector: "DIE"
  packer: "none-detected"
  entropy_total: "5.10"
modifiability:
  verdict: "CAN_PATCH"
  reason: "clean"
'@
function Set-CuFindings {
    param([string]$Root, [string]$Unpacking)
    $af = Join-Path $Root 'product-state\analysis\ANALYSIS-FINDINGS.yaml'
    $t = Get-Content -Raw -Encoding UTF8 -LiteralPath $af
    $t = $t -replace '(?m)^status:.*$', 'status: "ASSESSED"'
    foreach ($k in @('static_structure', 'static_strings', 'static_resources', 'disassembly', 'dynamic_behavior')) {
        $t = [regex]::Replace($t, ('(?m)^(' + $k + '):.*$'), ('$1: "done"'))
    }
    $t = [regex]::Replace($t, '(?m)^(unpacking):.*$', ('$1: "' + $Unpacking + '"'))
    [IO.File]::WriteAllText($af, $t, (New-Object Text.UTF8Encoding($false)))
}
$root = New-Fixture -Name 'cu-unpack-packed-na'
Set-Status -Root $root -Status 'ANALYZED'
[IO.File]::WriteAllText((Join-Path $root 'product-state\PROTECTION-PROFILE.yaml'), $cuPacked, (New-Object Text.UTF8Encoding($false)))
Set-CuFindings -Root $root -Unpacking 'not_applicable'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'CU1-packed-na-caught' -Text $run.Text -Pattern '脱壳必须是显式动作'
Set-CuFindings -Root $root -Unpacking 'done'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'CU2-packed-done-clears' -Text $run.Text -Pattern '脱壳必须是显式动作' -Absent
$root = New-Fixture -Name 'cu-unpack-clean-na'
Set-Status -Root $root -Status 'ANALYZED'
[IO.File]::WriteAllText((Join-Path $root 'product-state\PROTECTION-PROFILE.yaml'), $cuClean, (New-Object Text.UTF8Encoding($false)))
Set-CuFindings -Root $root -Unpacking 'not_applicable'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'CU3-clean-na-not-flagged' -Text $run.Text -Pattern '脱壳必须是显式动作' -Absent
# CU4 -- P-1 fail-safe: a DIE-blind profile (verdict UNKNOWN / packer unknown / entropy UNVERIFIED) must NOT
# read as not-packed. A possibly-packed target left at unpacking:not_applicable must still be caught, so
# "no DIE" cannot silently dodge the unpacking decision. Revert the fail-safe in Test-ProtectionSaysPacked
# (product-state-common.ps1) and this goes red.
$cuBlind = @'
schema_version: 1
product_id: "suite-product"
status: "ASSESSED"
packing:
  detector: "entropy-only"
  packer: "unknown"
  entropy_total: "UNVERIFIED"
modifiability:
  verdict: "UNKNOWN"
  reason: "no DIE available"
'@
$root = New-Fixture -Name 'cu-unpack-blind-na'
Set-Status -Root $root -Status 'ANALYZED'
[IO.File]::WriteAllText((Join-Path $root 'product-state\PROTECTION-PROFILE.yaml'), $cuBlind, (New-Object Text.UTF8Encoding($false)))
Set-CuFindings -Root $root -Unpacking 'not_applicable'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'CU4-blind-detector-na-caught' -Text $run.Text -Pattern '脱壳必须是显式动作'

# TR/AT -- opening (a): a static gate cannot prove a hash-consistent bound artifact was really produced by
# exercising the product (a determined forger authors a matching fake). Two honest responses. TR: a real
# VERIFIED/RELEASED emits EVIDENCE-TRUST: self-asserted so a green light never reads as independently proven;
# a fresh INIT emits no such line (guard against always-emitting). AT: -RequireAttestation opts into a named
# human endorsement -- without a valid product-state/attestation/ATTESTATION.yaml a real VERIFIED is refused
# under the flag (AT1); a complete attestation clears it (AT2); WITHOUT the flag the attestation is not
# required, so the default zero-config flow is unchanged (AT3, mutation guard). The attestation block only
# reads a name from a YAML file -- it verifies no identity and no signature, and this very test writes a
# made-up 张三 that clears it -- so the earned trust line must NOT claim "externally-attested" (one fake
# name would buy that strong claim); it must name the approver AND carry "identity NOT verified" inline.
# Re-label it back to externally-attested and AT2-no-external-claim reds; drop the honest ceiling from the
# label and AT2-identity-not-verified-marked reds.
$root = New-Fixture -Name 'tr-evidence-trust'
Set-Status -Root $root -Status 'VERIFIED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'TR1-verified-marks-self-asserted' -Text $run.Text -Pattern '(?m)^EVIDENCE-TRUST: self-asserted'
$root = New-Fixture -Name 'tr-fresh-no-trust-line'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'TR2-fresh-has-no-trust-line' -Text $run.Text -Pattern '(?m)^EVIDENCE-TRUST:' -Absent

$root = New-Fixture -Name 'at-attestation-gate'
Set-Status -Root $root -Status 'VERIFIED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-RequireAttestation')
Assert-Match -Name 'AT1-require-attestation-missing-caught' -Text $run.Text -Pattern '已要求人工背书'
$attDir = Join-Path $root 'product-state\attestation'
New-Item -ItemType Directory -Force -Path $attDir | Out-Null
[IO.File]::WriteAllText((Join-Path $attDir 'ATTESTATION.yaml'), "schema_version: 1`napproved_by: `"张三 <zhangsan@example.com>`"`nattested_status: `"VERIFIED`"`nattested_at: `"2026-08-13`"`n", (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-RequireAttestation')
Assert-Match -Name 'AT2-valid-attestation-clears' -Text $run.Text -Pattern '已要求人工背书' -Absent
Assert-Match -Name 'AT2-trust-names-approver' -Text $run.Text -Pattern '(?m)^EVIDENCE-TRUST: named-attestation by 张三'
Assert-Match -Name 'AT2-no-external-claim' -Text $run.Text -Pattern 'externally-attested' -Absent
Assert-Match -Name 'AT2-identity-not-verified-marked' -Text $run.Text -Pattern 'identity NOT verified'
$root = New-Fixture -Name 'at-attestation-off-by-default'
Set-Status -Root $root -Status 'VERIFIED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'AT3-not-required-without-flag' -Text $run.Text -Pattern '已要求人工背书' -Absent

# RG -- RELEASED 需平台登记回执，不能只凭自写发布请求 (opening d, prose-vs-gate). RELEASED used to need only a
# self-written RELEASE-PUBLISH-REQUEST.md plus a self-set manifest status, with zero platform-response
# evidence -- yet the skill's own prose says a local candidate is not released until the platform returns a
# record. RELEASED now also requires a settled registration_id in release/RELEASE-REGISTRATION.yaml: forging
# RELEASED without it must be named (RG1); adding the registration record clears exactly that line (RG2,
# mutation guard). Delete the requirement from lifecycle-states.json and RG1 goes red.
$root = New-Fixture -Name 'rg-release-registration'
Set-Status -Root $root -Status 'RELEASED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RG1-missing-registration-caught' -Text $run.Text -Pattern '平台登记回执'
[IO.File]::WriteAllText((Join-Path $root 'product-state\release\RELEASE-REGISTRATION.yaml'), "schema_version: 1`nregistration_id: `"PLAT-2026-000123`"`nregistered_at: `"2026-08-13`"`n", (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RG2-registration-present-clears' -Text $run.Text -Pattern '平台登记回执' -Absent

# RE -- 真机运行证据硬门 (用户加需求). A real VERIFIED/RELEASED must bind screenshot/recording evidence of an
# ACTUAL launch + offline-rejected + bad-key-rejected, not a typed claim. Empty (RE1) and text-only pointing
# at files that do not exist (RE2) must be caught; binding all three to real hash-consistent files clears
# (RE3, mutation guard). A screenshot is far harder to forge than a line of text -- the direct counter to the
# static-gate fabrication ceiling. Delete the gate in validate-product-state.ps1 and RE1 goes red; make it
# impossible to satisfy and RE3 goes red.
$root = New-Fixture -Name 're-run-evidence'
Set-Status -Root $root -Status 'VERIFIED'
$reFile = Join-Path $root 'product-state\reports\RUN-EVIDENCE.yaml'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RE1-empty-run-evidence-caught' -Text $run.Text -Pattern 'RUN-EVIDENCE\.yaml 的 launch'
$reTextOnly = @"
schema_version: 1
product_id: "suite-product"
launch:
  summary: "launched"
  path: "product-state/artifacts/verification/launch.png"
  sha256: "$('a' * 64)"
offline_rejected:
  summary: "offline"
  path: "product-state/artifacts/verification/offline.png"
  sha256: "$('b' * 64)"
badkey_rejected:
  summary: "badkey"
  path: "product-state/artifacts/verification/badkey.png"
  sha256: "$('c' * 64)"
"@
[IO.File]::WriteAllText($reFile, $reTextOnly, (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RE2-text-only-run-evidence-caught' -Text $run.Text -Pattern '没有绑定真实文件'
$reDir = Join-Path $root 'product-state\artifacts\verification'
New-Item -ItemType Directory -Force -Path $reDir | Out-Null
$reHashes = @{}
foreach ($n in @('launch', 'offline', 'badkey')) {
    $f = Join-Path $reDir "$n.png"
    [IO.File]::WriteAllText($f, "screenshot bytes for $n run", (New-Object Text.UTF8Encoding($false)))
    $reHashes[$n] = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
}
$reBound = @"
schema_version: 1
product_id: "suite-product"
launch:
  summary: "launched"
  path: "product-state/artifacts/verification/launch.png"
  sha256: "$($reHashes['launch'])"
offline_rejected:
  summary: "offline"
  path: "product-state/artifacts/verification/offline.png"
  sha256: "$($reHashes['offline'])"
badkey_rejected:
  summary: "badkey"
  path: "product-state/artifacts/verification/badkey.png"
  sha256: "$($reHashes['badkey'])"
"@
[IO.File]::WriteAllText($reFile, $reBound, (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RE3-bound-run-evidence-clears' -Text $run.Text -Pattern '没有绑定真实文件' -Absent
# RE4/RE5 -- F1 hardening. A 0-byte file is not a screenshot: binding a run kind to an empty file must be
# caught (RE4). Reusing one file for all three kinds is not three real runs: it must be caught (RE5). Revert
# the non-empty check in Test-BoundEvidenceFile and RE4 goes red; revert the distinct-hash check and RE5 goes red.
$reZero = Join-Path $reDir 'zero.png'
[IO.File]::WriteAllText($reZero, '', (New-Object Text.UTF8Encoding($false)))
$reZeroHash = (Get-FileHash -LiteralPath $reZero -Algorithm SHA256).Hash
$reZeroBody = @"
schema_version: 1
product_id: "suite-product"
launch:
  summary: "launched"
  path: "product-state/artifacts/verification/zero.png"
  sha256: "$reZeroHash"
offline_rejected:
  summary: "offline"
  path: "product-state/artifacts/verification/offline.png"
  sha256: "$($reHashes['offline'])"
badkey_rejected:
  summary: "badkey"
  path: "product-state/artifacts/verification/badkey.png"
  sha256: "$($reHashes['badkey'])"
"@
[IO.File]::WriteAllText($reFile, $reZeroBody, (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RE4-empty-file-run-evidence-caught' -Text $run.Text -Pattern '没有绑定真实文件'
$reSameBody = @"
schema_version: 1
product_id: "suite-product"
launch:
  summary: "launched"
  path: "product-state/artifacts/verification/launch.png"
  sha256: "$($reHashes['launch'])"
offline_rejected:
  summary: "offline"
  path: "product-state/artifacts/verification/launch.png"
  sha256: "$($reHashes['launch'])"
badkey_rejected:
  summary: "badkey"
  path: "product-state/artifacts/verification/launch.png"
  sha256: "$($reHashes['launch'])"
"@
[IO.File]::WriteAllText($reFile, $reSameBody, (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RE5-same-file-three-kinds-caught' -Text $run.Text -Pattern '三个互不相同'
# RE6 -- F2 hardening: evidence must live under product-state/, not just anywhere in the product root. Bind
# launch to a real non-empty file at the PRODUCT ROOT (outside product-state/) -> must be caught. Revert the
# state-root containment in Test-BoundEvidenceFile and this goes red.
$reRootFile = Join-Path $root 'rootproof.png'
[IO.File]::WriteAllText($reRootFile, 'screenshot bytes at product root', (New-Object Text.UTF8Encoding($false)))
$reRootHash = (Get-FileHash -LiteralPath $reRootFile -Algorithm SHA256).Hash
$reRootBody = @"
schema_version: 1
product_id: "suite-product"
launch:
  summary: "launched"
  path: "rootproof.png"
  sha256: "$reRootHash"
offline_rejected:
  summary: "offline"
  path: "product-state/artifacts/verification/offline.png"
  sha256: "$($reHashes['offline'])"
badkey_rejected:
  summary: "badkey"
  path: "product-state/artifacts/verification/badkey.png"
  sha256: "$($reHashes['badkey'])"
"@
[IO.File]::WriteAllText($reFile, $reRootBody, (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RE6-evidence-outside-state-root-caught' -Text $run.Text -Pattern '没有绑定真实文件'

# AR -- 授权交接『呈现层』机读摘要 (用户加需求 2). AUTH-ADAPTER-REQUEST now carries a top binding_summary block
# (claimed_tier/verified_tier/bypass_risk) so the authorization platform gate can machine-read the launcher↔
# core binding tier without parsing the whole doc. This is presentation only: the sole grading source and
# evidence check for A/B/C is still Test-BindingStrengthEvidence over LAUNCH-CONTRACT.yaml (untouched), so
# BS1/BS2/BS3 above must stay green. Remove the machine-readable block and AR1 goes red; touch the grading
# logic and the BS trio goes red -- the two together guard "presentation added, logic unchanged".
$arScaffold = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Skill 'assets\product-scaffold\auth\AUTH-ADAPTER-REQUEST.md')
Assert-Match -Name 'AR1-adapter-request-machine-readable-tiers' -Text $arScaffold -Pattern '(?s)binding_summary.*claimed_tier.*verified_tier.*bypass_risk'

# GO -- override is not verification (RV-R2 hole B). A -Force transition must leave gate_overridden:
# true ON DISK (not only in the JSON), and a real VERIFIED/RELEASED carrying that mark must be refused
# -- a forced state cannot ship as genuinely verified. Clearing the mark clears the error.
$root = New-Fixture -Name 'go-force-recorded'
$null = Invoke-Script -Name 'update-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-Status', 'ANALYZED', '-Force')
$goState = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'product-state\STATE.yaml')
Assert-Match -Name 'GO1-force-recorded-on-disk' -Text $goState -Pattern '(?im)^gate_overridden:\s*"?true"?'
$root = New-Fixture -Name 'go-forced-verified'
Set-Status -Root $root -Status 'VERIFIED'
$goPath = Join-Path $root 'product-state\STATE.yaml'
[IO.File]::WriteAllText($goPath, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $goPath) -replace '(?im)^gate_overridden:.*$', 'gate_overridden: "true"'), (New-Object Text.UTF8Encoding($true)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'GO2-forced-verified-flagged' -Text $run.Text -Pattern '强推'
[IO.File]::WriteAllText($goPath, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $goPath) -replace '(?im)^gate_overridden:.*$', 'gate_overridden: "false"'), (New-Object Text.UTF8Encoding($true)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'GO3-cleared-override-not-flagged' -Text $run.Text -Pattern '强推' -Absent

# WL -- win-hardening lint (RV-D-D1): assigning to a reserved automatic variable ($pid/$args/...)
# silently shadows it and has repeatedly broken scripts on plain Windows; validate-skill-layout
# parsed scripts but never flagged this. A fixture script that assigns $pid must be caught; renaming
# it to $processId clears -- the mutation guard against a lint that fires on any variable at all.
$wlRoot = Join-Path $FixtureRoot 'wl-reserved-var'
New-Item -ItemType Directory -Force -Path (Join-Path $wlRoot 'scripts') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $wlRoot 'knowledge') | Out-Null
[IO.File]::WriteAllText((Join-Path $wlRoot 'scripts\validate-knowledge.ps1'), "exit 0`n", (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $wlRoot 'scripts\demo.ps1'), "`$pid = 123`n", (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-skill-layout.ps1' -ScriptArgs @('-SkillRoot', $wlRoot)
Assert-Match -Name 'WL1-reserved-var-assignment-caught' -Text $run.Text -Pattern 'reserved automatic variable'
[IO.File]::WriteAllText((Join-Path $wlRoot 'scripts\demo.ps1'), "`$processId = 123`n", (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-skill-layout.ps1' -ScriptArgs @('-SkillRoot', $wlRoot)
Assert-Match -Name 'WL2-normal-var-not-flagged' -Text $run.Text -Pattern 'reserved automatic variable' -Absent

# LP -- portable frontmatter + host-neutral layout (R1-G1/G5/G6). The layout gate must validate the
# open-standard SKILL.md frontmatter (name + description, extra fields like compatibility allowed)
# rather than demand the Codex-only agents/openai.yaml, so any agent installing from a URL passes. A
# SKILL.md with an extra compatibility field must not trip the frontmatter check; a missing
# agents/openai.yaml must not be a required-file error; an empty description must be caught.
$lpRoot = Join-Path $FixtureRoot 'lp-portable-layout'
New-Item -ItemType Directory -Force -Path (Join-Path $lpRoot 'scripts') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $lpRoot 'knowledge') | Out-Null
[IO.File]::WriteAllText((Join-Path $lpRoot 'scripts\validate-knowledge.ps1'), "exit 0`n", (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $lpRoot 'SKILL.md'), "---`nname: exe-product-lifecycle`ndescription: `"does a thing`"`ncompatibility: `"Windows; PowerShell 5.1 or 7`"`n---`n`n# x`n", (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-skill-layout.ps1' -ScriptArgs @('-SkillRoot', $lpRoot)
Assert-Match -Name 'LP1-extra-frontmatter-field-ok' -Text $run.Text -Pattern 'frontmatter' -Absent
Assert-Match -Name 'LP2-openai-yaml-not-required' -Text $run.Text -Pattern 'openai\.yaml' -Absent
[IO.File]::WriteAllText((Join-Path $lpRoot 'SKILL.md'), "---`nname: exe-product-lifecycle`ndescription:`n---`n`n# x`n", (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-skill-layout.ps1' -ScriptArgs @('-SkillRoot', $lpRoot)
Assert-Match -Name 'LP3-empty-description-caught' -Text $run.Text -Pattern 'description is empty'
# LP4 -- F5b: an empty description FOLLOWED BY another frontmatter field must also be caught. The old
# '^description:\s*\S' let \s* cross the newline and match the next field's first char (thinking it was
# non-empty). Revert to \s* and this goes red.
[IO.File]::WriteAllText((Join-Path $lpRoot 'SKILL.md'), "---`nname: exe-product-lifecycle`ndescription:`ncompatibility: `"Windows`"`n---`n`n# x`n", (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-skill-layout.ps1' -ScriptArgs @('-SkillRoot', $lpRoot)
Assert-Match -Name 'LP4-empty-description-followed-by-field-caught' -Text $run.Text -Pattern 'description is empty'

# S1..S4 -- the mandatory entry point. It is the mechanism that keeps an agent on the rails, so it
# needs the same coverage as the gates it dispatches to: pick the right mode, put input
# registration before everything else, and never write to the product while doing it.
$root = Join-Path $FixtureRoot 's-entry'
New-Item -ItemType Directory -Force -Path $root | Out-Null
[IO.File]::WriteAllText((Join-Path $root 'MyApp.exe'), 'entry fixture bytes', [Text.Encoding]::ASCII)
$run = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'S1-bootstrap-detected' -Text $run.Text -Pattern '(?m)^模式: bootstrap'
Assert-Match -Name 'S1-names-init-command' -Text $run.Text -Pattern 'init-product\.ps1'
# R3-D1: the Windows-only guard must not false-fire on the (Windows) host running the suite.
Assert-Match -Name 'S1-windows-guard-no-false-fire' -Text $run.Text -Pattern '只能在 Windows 上运行' -Absent

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

# MT -- tool integrity (RV-R4 M1): detect-protections discovers analysis tools by scanning disk and
# then executes them. It now records each tool's path+sha256+signature into PROTECTION-PROFILE.yaml
# before running it, and -RequireSignedTools refuses one whose signature is not Valid. Point the
# inventory at an unsigned dummy: strict mode must RECORD it and then SKIP it (never execute it).
$mtRoot = New-Fixture -Name 'mt-tool-integrity'
$mtTool = Join-Path $mtRoot 'diec.exe'
[IO.File]::WriteAllBytes($mtTool, [byte[]](0x4D, 0x5A, 0x90, 0x00, 0x03))
$mtInv = Join-Path $mtRoot 'product-state\tooling\TOOL-INVENTORY.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $mtInv) | Out-Null
[IO.File]::WriteAllText($mtInv, ('{"tools":[{"path":' + (ConvertTo-Json $mtTool) + ',"leaf":"diec.exe"}]}'), (New-Object Text.UTF8Encoding($false)))
$null = Invoke-Script -Name 'detect-protections.ps1' -ScriptArgs @('-ProductRoot', $mtRoot, '-RequireSignedTools', '-Force')
$mtProfile = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $mtRoot 'product-state\PROTECTION-PROFILE.yaml')
Assert-Match -Name 'MT1-tool-recorded-before-exec' -Text $mtProfile -Pattern '将执行分析工具'
Assert-Match -Name 'MT2-unsigned-tool-skipped-in-strict' -Text $mtProfile -Pattern '跳过未通过签名校验'

# BS -- the binding-strength gate on AUTH_CONTRACT_READY. "The launcher is bound to the core" is
# exactly where "claimed strong, proved nothing" hides, so the gate honours a claimed tier only
# when the evidence THAT tier needs is settled. The ladder is cumulative, so this fixture keeps
# failing on the rungs below it; every assertion looks only at whether binding_strength_backed is
# the requirement firing, which is the single thing this gate controls.
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

# BS4 -- F-AH-1/3 ceiling: a claimed tier above the protection_ceiling must be caught even when that tier's
# own evidence fields are filled (the demonstrated over-claim was "ceiling C but claimed A"). Fill A-evidence
# so the gate cannot fail on evidence, set protection_ceiling C, claim A -> only the ceiling can fire it.
# Revert the ceiling check in Test-BindingStrengthEvidence and this goes red.
Set-ContractField -Path $contract -Key 'protection_ceiling' -Value 'C'
Set-ContractField -Path $contract -Key 'evidence_a_server_issued_material' -Value 'server issues the runtime key; launcher injects it into the core'
Set-ContractField -Path $contract -Key 'evidence_a_core_fails_without_material' -Value 'withholding the key makes the core exit immediately'
Set-ContractField -Path $contract -Key 'verified_tier' -Value 'A'
Set-ContractField -Path $contract -Key 'claimed_tier' -Value 'A'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'BS4-tier-above-ceiling-caught' -Text $run.Text -Pattern 'binding_strength_backed'

# BS5 -- F-AH-2 consistency: the machine-read binding_summary in AUTH-ADAPTER-REQUEST.md must match the sole
# grading source. Set the contract to honest C (binding gate clears) but the summary claimed_tier to A ->
# the mismatch must be caught. Revert the consistency gate in validate-product-state.ps1 and this goes red.
Set-ContractField -Path $contract -Key 'claimed_tier' -Value 'C'
Set-ContractField -Path $contract -Key 'verified_tier' -Value 'C'
$adapterReq = Join-Path $root 'product-state\auth\AUTH-ADAPTER-REQUEST.md'
$adapterReqText = Get-Content -Raw -Encoding UTF8 -LiteralPath $adapterReq
$adapterReqText = $adapterReqText -replace '(?m)^(\s*claimed_tier:\s*")[^"]*(")', '${1}A${2}'
[IO.File]::WriteAllText($adapterReq, $adapterReqText, (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'BS5-summary-mismatch-caught' -Text $run.Text -Pattern 'binding_summary'

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

# PK -- publishing is what turns "this machine learned something" into "the knowledge base learned
# something". A copy that was installed by copying files has no history to publish into, and the
# person hitting that needs the clone command, not a PowerShell stack trace.
$pk = Join-Path $FixtureRoot 'pk-not-a-repo'
New-Item -ItemType Directory -Force -Path $pk | Out-Null
$run = Invoke-Script -Name 'publish-knowledge.ps1' -ScriptArgs @('-SkillRoot', $script:Skill, '-DryRun')
Assert-Match -Name 'PK1-dry-run-publishes-nothing' -Text $run.Text -Pattern 'RESULT: (nothing_to_publish|dry_run)'
Add-Result -Name 'PK1-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })
$run = Invoke-Script -Name 'publish-knowledge.ps1' -ScriptArgs @('-SkillRoot', $pk, '-DryRun')
Assert-Match -Name 'PK2-non-repo-names-clone' -Text $run.Text -Pattern 'git clone'
Add-Result -Name 'PK2-no-stack-trace' -Passed (-not $run.HasStackTrace) -Expected 'clean' -Actual $(if ($run.HasStackTrace) { 'stack-trace' } else { 'clean' })

# MB -- mock authorization server L1 (RV-R4): an unauthenticated mock must refuse a non-loopback bind
# unless explicitly opted in, and must refuse BEFORE opening any socket (so this assertion never hangs).
$run = Invoke-Script -Name 'mock-authorization-server.ps1' -ScriptArgs @('-BindAddress', '0.0.0.0')
Assert-Match -Name 'MB1-nonloopback-bind-refused' -Text $run.Text -Pattern '不是回环地址'

# SG -- sync target guard L2 (RV-R4): sync deletes destination files the source lacks, so pointing it
# at an ordinary non-empty directory that is not a skill install must be refused before any copy/delete
# -- otherwise it eats unrelated files. The stray file must survive the refused sync.
$sgDest = Join-Path $FixtureRoot 'sg-not-a-skill'
New-Item -ItemType Directory -Force -Path $sgDest | Out-Null
[IO.File]::WriteAllText((Join-Path $sgDest 'important.txt'), 'unrelated user file', (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'sync-local-skill.ps1' -ScriptArgs @('-SourceRoot', $script:Skill, '-DestinationRoot', $sgDest)
Assert-Match -Name 'SG1-non-skill-dest-refused' -Text $run.Text -Pattern '看起来不是一个技能安装目录'
Add-Result -Name 'SG1-unrelated-file-survived' -Passed (Test-Path -LiteralPath (Join-Path $sgDest 'important.txt')) -Expected 'kept' -Actual $(if (Test-Path -LiteralPath (Join-Path $sgDest 'important.txt')) { 'kept' } else { 'deleted' })

# RA -- "每阶段必须能收工". A long task drags when an agent keeps working a stage it has already
# finished instead of landing a checkpoint. The moment a stage's exit is earned, the tooling must
# say so; and it must stay silent on a stage that is not finished, or the affordance becomes a nag.
# A freshly-initialised product has already earned INIT -> BASELINE_CREATED (init writes the
# baseline/input manifests those requirements ask for), so READY-TO-ADVANCE must fire here.
$root = New-Fixture -Name 'ra-ready-to-advance'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RA1-ready-signal-when-earned' -Text $run.Text -Pattern '(?m)^READY-TO-ADVANCE: BASELINE_CREATED'
# BASELINE_CREATED still needs the tool inventory, the protection profile and a first-analysis
# conclusion, so its next rung is NOT earned: the signal must be absent. The NEXT-NEEDS anchor
# proves the fixture really is on an unfinished stage, so the Absent assertion is not vacuous.
$root = New-Fixture -Name 'ra-not-ready'
$null = Invoke-Script -Name 'update-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-Status', 'BASELINE_CREATED', '-Mode', 'resume')
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'RA2-silent-when-unfinished-anchor' -Text $run.Text -Pattern '(?m)^NEXT-NEEDS: '
Assert-Match -Name 'RA2-silent-when-unfinished' -Text $run.Text -Pattern '(?m)^READY-TO-ADVANCE:' -Absent

# L1 -- the structural guarantee under "每阶段必须能收工": from any stage the ladder can always name
# where you are and the single next step, so stopping and resuming is always well defined. Every
# state carries a meaning and a next_action; every declared next_status resolves to a real state;
# and the main path from INIT reaches RELEASED without a dead end in the middle.
$lifecycle = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Skill 'assets\lifecycle-states.json') | ConvertFrom-Json
$states = @($lifecycle.states)
$byStatus = @{}
foreach ($s in $states) { $byStatus[[string]$s.status] = $s }
$missingAction = @($states | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.meaning) -or [string]::IsNullOrWhiteSpace([string]$_.next_action) } | ForEach-Object { [string]$_.status })
Add-Result -Name 'L1-every-stage-names-next-step' -Passed ($missingAction.Count -eq 0) -Expected 'all-named' -Actual $(if ($missingAction.Count -eq 0) { 'all-named' } else { "blank: $($missingAction -join ',')" })
$dangling = @($states | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.next_status) -and -not $byStatus.ContainsKey([string]$_.next_status) } | ForEach-Object { [string]$_.status })
Add-Result -Name 'L1-no-dangling-next-status' -Passed ($dangling.Count -eq 0) -Expected 'all-resolve' -Actual $(if ($dangling.Count -eq 0) { 'all-resolve' } else { "dangling: $($dangling -join ',')" })
$cursor = 'INIT'
$walked = New-Object System.Collections.Generic.List[string]
$reachedReleased = $false
while ($byStatus.ContainsKey($cursor) -and -not $walked.Contains($cursor)) {
    [void]$walked.Add($cursor)
    if ($cursor -eq 'RELEASED') { $reachedReleased = $true; break }
    $cursor = [string]$byStatus[$cursor].next_status
    if ([string]::IsNullOrWhiteSpace($cursor)) { break }
}
Add-Result -Name 'L1-main-path-reaches-released' -Passed $reachedReleased -Expected 'INIT..RELEASED' -Actual $(if ($reachedReleased) { 'INIT..RELEASED' } else { "stops at $cursor" })

# L2 -- ladder orders must be unique. The readiness ladder is cumulative over `order <= current`,
# so two states sharing an order silently inherit each other's requires. VERIFIED_SIMULATION and
# VERIFIED both sat on order 7, which meant any real-evidence gate added to VERIFIED would also
# have blocked the simulation stopover (and vice versa) -- simulation and real are different axes,
# not the same rung. Give any two ladder states the same order again and this goes red.
$laddered = @($states | Where-Object { $null -ne $_.order })
$duplicated = @($laddered | Group-Object { [int]$_.order } | Where-Object { $_.Count -gt 1 } | ForEach-Object { ('order {0}: {1}' -f $_.Name, (@($_.Group | ForEach-Object { [string]$_.status }) -join '+')) })
Add-Result -Name 'L2-ladder-orders-are-unique' -Passed ($duplicated.Count -eq 0) -Expected 'all-distinct' -Actual $(if ($duplicated.Count -eq 0) { 'all-distinct' } else { $duplicated -join '; ' })

# SL -- source-reuse (Phase 2) ladder structural + drift-parity guards. The source track has its own front
# half (SOURCE_INTAKE→REFERENCES_GATHERED→CAPABILITY_MAPPED→IMPLEMENTED) then MERGES into the shared
# downstream. SL1: every source stage names meaning+next_action, no dangling next_status, main path reaches
# RELEASED. SL2: source ladder orders unique. SL3 (drift guard, the important one): the shared-downstream
# states' requires in lifecycle-states-source.json are byte-for-byte identical to lifecycle-states.json, so
# the reused downstream can never silently drift into a second divergent copy (the ISSUE-096 failure mode).
$sourcePath = Join-Path $script:Skill 'assets\lifecycle-states-source.json'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    Add-Result -Name 'SL0-source-table-present' -Passed $false -Expected 'present' -Actual 'missing'
}
else {
    $sourceLc = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePath | ConvertFrom-Json
    $sourceStates = @($sourceLc.states)
    $sourceByStatus = @{}
    foreach ($s in $sourceStates) { $sourceByStatus[[string]$s.status] = $s }
    $srcMissingAction = @($sourceStates | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.meaning) -or [string]::IsNullOrWhiteSpace([string]$_.next_action) } | ForEach-Object { [string]$_.status })
    Add-Result -Name 'SL1-source-every-stage-names-next-step' -Passed ($srcMissingAction.Count -eq 0) -Expected 'all-named' -Actual $(if ($srcMissingAction.Count -eq 0) { 'all-named' } else { "blank: $($srcMissingAction -join ',')" })
    $srcDangling = @($sourceStates | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.next_status) -and -not $sourceByStatus.ContainsKey([string]$_.next_status) } | ForEach-Object { [string]$_.status })
    Add-Result -Name 'SL1-source-no-dangling-next-status' -Passed ($srcDangling.Count -eq 0) -Expected 'all-resolve' -Actual $(if ($srcDangling.Count -eq 0) { 'all-resolve' } else { "dangling: $($srcDangling -join ',')" })
    $srcCursor = 'SOURCE_INTAKE'
    $srcWalked = New-Object System.Collections.Generic.List[string]
    $srcReachedReleased = $false
    while ($sourceByStatus.ContainsKey($srcCursor) -and -not $srcWalked.Contains($srcCursor)) {
        [void]$srcWalked.Add($srcCursor)
        if ($srcCursor -eq 'RELEASED') { $srcReachedReleased = $true; break }
        $srcCursor = [string]$sourceByStatus[$srcCursor].next_status
        if ([string]::IsNullOrWhiteSpace($srcCursor)) { break }
    }
    Add-Result -Name 'SL1-source-main-path-reaches-released' -Passed $srcReachedReleased -Expected 'SOURCE_INTAKE..RELEASED' -Actual $(if ($srcReachedReleased) { 'SOURCE_INTAKE..RELEASED' } else { "stops at $srcCursor" })
    $srcLaddered = @($sourceStates | Where-Object { $null -ne $_.order })
    $srcDup = @($srcLaddered | Group-Object { [int]$_.order } | Where-Object { $_.Count -gt 1 } | ForEach-Object { [string]$_.Name })
    Add-Result -Name 'SL2-source-ladder-orders-are-unique' -Passed ($srcDup.Count -eq 0) -Expected 'all-distinct' -Actual $(if ($srcDup.Count -eq 0) { 'all-distinct' } else { "dup: $($srcDup -join ',')" })
    $sharedDownstream = @('CUSTOMIZATION_RECORDED', 'AUTH_HANDOFF_READY', 'AUTH_CONTRACT_READY', 'BUILD_READY', 'VERIFIED_SIMULATION', 'VERIFIED', 'RELEASED', 'MIGRATION_REQUIRED', 'ROLLBACK_READY')
    $driftedStatuses = New-Object System.Collections.Generic.List[string]
    foreach ($sharedStatus in $sharedDownstream) {
        $exeState = @($states | Where-Object { [string]$_.status -eq $sharedStatus }) | Select-Object -First 1
        $srcState = @($sourceStates | Where-Object { [string]$_.status -eq $sharedStatus }) | Select-Object -First 1
        if ($null -eq $exeState -or $null -eq $srcState) { [void]$driftedStatuses.Add($sharedStatus + '(missing)'); continue }
        $exeReq = ($exeState.requires | ConvertTo-Json -Depth 6 -Compress)
        $srcReq = ($srcState.requires | ConvertTo-Json -Depth 6 -Compress)
        if ($exeReq -ne $srcReq) { [void]$driftedStatuses.Add($sharedStatus) }
    }
    Add-Result -Name 'SL3-shared-downstream-requires-no-drift' -Passed ($driftedStatuses.Count -eq 0) -Expected 'in-sync' -Actual $(if ($driftedStatuses.Count -eq 0) { 'in-sync' } else { "drifted: $($driftedStatuses -join ',')" })
}

# SU -- source-reuse (Phase 2) track end-to-end on the SAME engine. init-source-product.ps1 creates a source
# product (no EXE, no baseline). The one validator accepts it at SOURCE_INTAKE by reading the source ladder
# (STATE track: source), and the EXE-baseline / reverse-engineering checks are correctly SKIPPED. Forging a
# source product to VERIFIED must still be caught by the SHARED downstream gates (proving downstream reuse),
# but NOT by EXE-only baseline/reverse-findings errors (proving the track guards). Break track selection and
# SU1/SU2 go red; drop a downstream reuse and SU3-shared goes red; over-apply an EXE guard and SU3-no-* go red.
function New-SourceFixture {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$ProductId = 'suite-source-product')
    $root = Join-Path $FixtureRoot $Name
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $null = Invoke-Script -Name 'init-source-product.ps1' -ScriptArgs @('-ProductRoot', $root, '-ProductId', $ProductId, '-Goal', '做一个演示小工具')
    return $root
}
$root = New-SourceFixture -Name 'su-source-intake'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'SU1-fresh-source-product-passes' -Text $run.Text -Pattern 'RESULT: passed'
Assert-Match -Name 'SU2-source-ladder-in-use' -Text $run.Text -Pattern '(?m)^STATE: SOURCE_INTAKE'
Assert-Match -Name 'SU2-source-next-is-references' -Text $run.Text -Pattern '(?m)^NEXT-STATUS: REFERENCES_GATHERED'
Set-Status -Root $root -Status 'VERIFIED'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'SU3-forged-source-verified-fails' -Text $run.Text -Pattern 'RESULT: failed'
Assert-Match -Name 'SU3-shared-downstream-gate-fires' -Text $run.Text -Pattern 'CUSTOMIZATION-MANIFEST\.yaml'
Assert-Match -Name 'SU3-no-exe-baseline-error' -Text $run.Text -Pattern 'baseline_sha256 is missing' -Absent
Assert-Match -Name 'SU3-no-reverse-findings-error' -Text $run.Text -Pattern 'findings 为空' -Absent

# CM -- 学写法不硬合并门 (Phase 2). CAPABILITY_MAPPED needs every capability to carry self_implementation
# (how you built it yourself in your own project) -- the "learn the idea, write it yourself" evidence.
# reference_ids is OPTIONAL (user decision: 合规/来源登记 softened). Empty (CM1) and self_implementation-missing
# (CM2) must be named; a capability with self_implementation but NO reference_ids clears it (CM3) -- proving
# reference_ids is optional while self_implementation is required.
$root = New-SourceFixture -Name 'cm-capability-mapping'
Set-Status -Root $root -Status 'CAPABILITY_MAPPED'
$capMap = Join-Path $root 'product-state\source\CAPABILITY-MAP.yaml'
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
# Anchor on the capabilities-gate why (unique), not the file name: the file name also appears in the
# NEXT-NEEDS line for IMPLEMENTED (which reads CAPABILITY-MAP status), so a file-name anchor never clears.
Assert-Match -Name 'CM1-empty-capabilities-caught' -Text $run.Text -Pattern '能力映射不完整'
[IO.File]::WriteAllText($capMap, "schema_version: 1`nproduct_id: `"suite-source-product`"`ncapabilities:`n  - id: c1`n    capability: `"demo`"`n    reference_ids: [`"r1`"]`n", (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'CM2-capability-missing-impl-caught' -Text $run.Text -Pattern '能力映射不完整'
[IO.File]::WriteAllText($capMap, "schema_version: 1`nproduct_id: `"suite-source-product`"`ncapabilities:`n  - id: c1`n    capability: `"demo`"`n    self_implementation: `"importlib scan plugins dir`"`n", (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'validate-product-state.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'CM3-self-impl-only-clears' -Text $run.Text -Pattern '能力映射不完整' -Absent

# KN -- 已知不强校的门必须老实标注 (用户判据：会误伤合法情况的门不硬加，改为在技能里明写"已知不强校 + 原因").
# Two openings I deliberately did NOT hard-gate (rules per-item anchor; selected_strategy vs PROTECTION
# verdict) have legitimate counterexamples that a hard gate would false-flag. The honest disclosure in
# SKILL.md is the deliverable; if someone deletes it, KN goes red -- so "not strictly gated" stays an
# explicit, recorded trade-off rather than a silent omission.
$knSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Skill 'SKILL.md')
Assert-Match -Name 'KN1-known-not-gated-section-present' -Text $knSkill -Pattern '已知不强校的门'
Assert-Match -Name 'KN2-rules-anchor-noted' -Text $knSkill -Pattern '定制规则未逐条强校 anchor'
Assert-Match -Name 'KN3-strategy-verdict-noted' -Text $knSkill -Pattern '维护策略未强制与保护判定一致'

# WU -- the WRITER (update-product-state.ps1) track-aware forward gate for the SOURCE track. The SU tests
# forged status by hand-editing; this proves update-product-state itself governs source transitions against
# the source ladder: it REFUSES SOURCE_INTAKE->REFERENCES_GATHERED while SOURCE-INTAKE is unsettled (WU1, and
# writes nothing), and ALLOWS it once SOURCE-INTAKE is DEFINED -- references left EMPTY on purpose (optional
# after the user's softening). Break the track->table selection and WU2 reds (EXE table would reject the
# source status); re-add a url/commit/license reference hard gate and WU2 reds too (empty refs then refused).
$root = New-SourceFixture -Name 'wu-writer-source-transition'
$wuStatePath = Join-Path $root 'product-state\STATE.yaml'
$wuBefore = (Get-FileHash -LiteralPath $wuStatePath -Algorithm SHA256).Hash
$run = Invoke-Script -Name 'update-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-Status', 'REFERENCES_GATHERED')
$wuAfter = (Get-FileHash -LiteralPath $wuStatePath -Algorithm SHA256).Hash
Assert-Match -Name 'WU1-source-transition-refused-when-unmet' -Text $run.Text -Pattern '还不能把状态改成'
Add-Result -Name 'WU1-nothing-written' -Passed ($wuBefore -eq $wuAfter) -Expected 'unchanged' -Actual $(if ($wuBefore -eq $wuAfter) { 'unchanged' } else { 'modified' })
$wuIntake = Join-Path $root 'product-state\source\SOURCE-INTAKE.yaml'
[IO.File]::WriteAllText($wuIntake, ((Get-Content -Raw -Encoding UTF8 -LiteralPath $wuIntake) -replace '(?m)^status:.*$', 'status: "DEFINED"'), (New-Object Text.UTF8Encoding($false)))
$run = Invoke-Script -Name 'update-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-Status', 'REFERENCES_GATHERED', '-Mode', 'resume')
Assert-Match -Name 'WU2-source-transition-allowed-empty-refs' -Text $run.Text -Pattern '"to_status":\s+"REFERENCES_GATHERED"'

# SH -- start-here (the mandatory entry point) is track-aware with the SAME track->table selection the
# validator (SU) and the writer (WU) already use. It used to judge every product against the EXE table:
# a legitimate source product at SOURCE_INTAKE read as unknown, so the one script every agent runs first
# printed STATE_REPAIR_REQUIRED and told the agent to "repair" the status back to an EXE value --
# following that advice corrupts a legal source product. And a no-EXE folder was always answered with
# "upload the EXE", closing the source-reuse door at the front desk. Break start-here's track->table
# selection and SH1/SH2 go red (the EXE table does not know SOURCE_INTAKE, so the repair branch fires
# and no source step is printed); drop the source-entry option from the no-EXE bootstrap and SH3 reds.
$root = New-SourceFixture -Name 'sh-entry-source-track'
$run = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'SH1-source-not-misrepaired' -Text $run.Text -Pattern 'STATE_REPAIR_REQUIRED' -Absent
Assert-Match -Name 'SH1-no-exe-upload-ask' -Text $run.Text -Pattern '请直接上传 EXE' -Absent
Assert-Match -Name 'SH2-source-status-recognised' -Text $run.Text -Pattern '(?m)^当前状态: SOURCE_INTAKE'
Assert-Match -Name 'SH2-source-next-action-printed' -Text $run.Text -Pattern '联网找同类开源参考'
Assert-Match -Name 'SH2-source-next-status-command' -Text $run.Text -Pattern '-Status REFERENCES_GATHERED'
$root = Join-Path $FixtureRoot 'sh-empty-two-entries'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$run = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root)
Assert-Match -Name 'SH3-bootstrap-offers-source-entry' -Text $run.Text -Pattern 'init-source-product\.ps1'
Assert-Match -Name 'SH3-bootstrap-keeps-exe-entry' -Text $run.Text -Pattern '请直接上传 EXE'

$failed = @($script:Results | Where-Object { -not $_.Passed })
Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f @($script:Results | Where-Object { $_.Passed }).Count, $failed.Count)
if (-not $KeepFixture -and (Test-Path -LiteralPath $FixtureRoot -PathType Container)) {
    Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed.Count -gt 0) { exit 1 }
# Explicit, because several scenarios deliberately run a script that exits non-zero and the last
# one of those leaves $LASTEXITCODE set. Launched with -File that is harmless, but CI runs this as
# `pwsh -command ". 'file'"`, where the leftover code becomes the step's result -- which reported
# a failing step directly under a line saying every assertion passed.
exit 0
