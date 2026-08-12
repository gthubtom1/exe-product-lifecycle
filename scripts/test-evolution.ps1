#requires -Version 5

[CmdletBinding()]
param([string]$SkillRoot, [switch]$KeepTemporaryFiles)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$source = (Resolve-Path -LiteralPath $SkillRoot).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('exe-lifecycle-evolution-' + [Guid]::NewGuid().ToString('N'))
$testSkill = Join-Path $temp 'skill'
$passes = New-Object System.Collections.Generic.List[string]
$shellExe = (Get-Process -Id $PID).Path

function Invoke-TestScript {
    param([string]$Name, [string]$Script, [hashtable]$Arguments, [bool]$ExpectFailure = $false)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $shellExe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($ExpectFailure -and $exitCode -eq 0) { throw "$Name unexpectedly succeeded`n$($output -join "`n")" }
    if (-not $ExpectFailure -and $exitCode -ne 0) { throw "$Name failed with exit $exitCode`n$($output -join "`n")" }
    [void]$passes.Add($Name)
    return @($output)
}

function New-FixtureProduct {
    param([string]$Path, [string]$Id, [string]$EvidenceText)
    $state = Join-Path $Path 'product-state'
    New-Item -ItemType Directory -Force -Path (Join-Path $state 'learning'), (Join-Path $state 'analysis') | Out-Null
    @"
schema_version: 1
product_id: "$Id"
product_name: "$Id"
status: "ANALYZED"
"@ | Set-Content -LiteralPath (Join-Path $state 'STATE.yaml') -Encoding UTF8
    @"
schema_version: 1
product_id: "$Id"
entries:
  - id: "EV-001"
    claim: "fixture evidence"
"@ | Set-Content -LiteralPath (Join-Path $state 'EVIDENCE-LEDGER.yaml') -Encoding UTF8
    $EvidenceText | Set-Content -LiteralPath (Join-Path $state 'analysis\evidence.txt') -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Force -Path $testSkill | Out-Null
    foreach ($name in @('scripts', 'schemas', 'knowledge', 'fixtures')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $testSkill -Recurse
    }
    Get-ChildItem -LiteralPath (Join-Path $testSkill 'knowledge\candidates') -File -Filter '*.json' | Remove-Item -Force
    Get-ChildItem -LiteralPath (Join-Path $testSkill 'knowledge\verified') -File -Filter '*.json' | Remove-Item -Force
    Get-ChildItem -LiteralPath (Join-Path $testSkill 'knowledge\deprecated') -File -Filter '*.json' | Remove-Item -Force
    & $shellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testSkill 'scripts\rebuild-knowledge-index.ps1') -SkillRoot $testSkill | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Initial knowledge index rebuild failed' }

    $real = Join-Path $temp 'real-product'
    $realTwo = Join-Path $temp 'real-product-two'
    $positive = Join-Path $temp 'positive-fixture'
    $negative = Join-Path $temp 'negative-fixture'
    $private = Join-Path $temp 'privacy-product'
    New-FixtureProduct -Path $real -Id 'sample-real-product' -EvidenceText 'Observed nested executable inventory in a preserved package.'
    New-FixtureProduct -Path $realTwo -Id 'sample-real-product-two' -EvidenceText 'A second product independently confirmed nested executable classification.'
    New-FixtureProduct -Path $positive -Id 'sample-positive-fixture' -EvidenceText 'Positive fixture reproduces nested executable classification.'
    New-FixtureProduct -Path $negative -Id 'sample-negative-fixture' -EvidenceText 'Negative fixture confirms a plain executable must not match.'
    New-FixtureProduct -Path $private -Id 'private-product-name' -EvidenceText 'Privacy fixture evidence.'
    Copy-Item -LiteralPath (Join-Path $source 'fixtures\evolution\candidate-draft.json') -Destination (Join-Path $real 'product-state\learning\CANDIDATE-DRAFT.json')

    $capture = Invoke-TestScript -Name 'capture_real_candidate' -Script (Join-Path $testSkill 'scripts\capture-experience.ps1') -Arguments @{
        ProductRoot = $real
        EvidencePath = (Join-Path $real 'product-state\analysis\evidence.txt')
        SkillRoot = $testSkill
    }
    $idLine = @($capture | Where-Object { [string]$_ -match '^experience_id=' } | Select-Object -First 1)
    if ($idLine.Count -ne 1) { throw 'Capture output has no experience_id' }
    $experienceId = ([string]$idLine[0]).Substring('experience_id='.Length)

    Invoke-TestScript -Name 'reject_early_promotion' -Script (Join-Path $testSkill 'scripts\promote-pattern.ps1') -Arguments @{ ExperienceId = $experienceId; PromotedBy = 'fixture-reviewer'; SkillRoot = $testSkill } -ExpectFailure $true | Out-Null
    Invoke-TestScript -Name 'add_positive_fixture' -Script (Join-Path $testSkill 'scripts\add-experience-evidence.ps1') -Arguments @{
        ProductRoot = $positive; ExperienceId = $experienceId; EvidencePath = (Join-Path $positive 'product-state\analysis\evidence.txt'); SkillRoot = $testSkill; SourceKind = 'fixture'; EvidenceRole = 'positive_fixture'
    } | Out-Null
    Invoke-TestScript -Name 'add_second_real_product' -Script (Join-Path $testSkill 'scripts\add-experience-evidence.ps1') -Arguments @{
        ProductRoot = $realTwo; ExperienceId = $experienceId; EvidencePath = (Join-Path $realTwo 'product-state\analysis\evidence.txt'); SkillRoot = $testSkill; SourceKind = 'real_product'; EvidenceRole = 'supporting'
    } | Out-Null
    Invoke-TestScript -Name 'add_negative_fixture' -Script (Join-Path $testSkill 'scripts\add-experience-evidence.ps1') -Arguments @{
        ProductRoot = $negative; ExperienceId = $experienceId; EvidencePath = (Join-Path $negative 'product-state\analysis\evidence.txt'); SkillRoot = $testSkill; SourceKind = 'fixture'; EvidenceRole = 'negative_fixture'
    } | Out-Null
    Invoke-TestScript -Name 'review_candidate' -Script (Join-Path $testSkill 'scripts\review-experience.ps1') -Arguments @{ ExperienceId = $experienceId; Decision = 'approve'; Reviewer = 'fixture-reviewer'; Notes = 'Two product sources and both fixtures confirm applicability boundaries.'; SkillRoot = $testSkill } | Out-Null
    'Additional independent observation from the second product.' | Set-Content -LiteralPath (Join-Path $realTwo 'product-state\analysis\evidence-two.txt') -Encoding UTF8
    Invoke-TestScript -Name 'change_invalidates_review' -Script (Join-Path $testSkill 'scripts\add-experience-evidence.ps1') -Arguments @{
        ProductRoot = $realTwo; ExperienceId = $experienceId; EvidencePath = (Join-Path $realTwo 'product-state\analysis\evidence-two.txt'); SkillRoot = $testSkill; SourceKind = 'real_product'; EvidenceRole = 'supporting'
    } | Out-Null
    Invoke-TestScript -Name 'reject_stale_review_promotion' -Script (Join-Path $testSkill 'scripts\promote-pattern.ps1') -Arguments @{ ExperienceId = $experienceId; PromotedBy = 'fixture-reviewer'; SkillRoot = $testSkill } -ExpectFailure $true | Out-Null
    Invoke-TestScript -Name 'review_changed_candidate' -Script (Join-Path $testSkill 'scripts\review-experience.ps1') -Arguments @{ ExperienceId = $experienceId; Decision = 'approve'; Reviewer = 'fixture-reviewer'; Notes = 'Re-reviewed the current payload after additional evidence.'; SkillRoot = $testSkill } | Out-Null
    Invoke-TestScript -Name 'promote_candidate' -Script (Join-Path $testSkill 'scripts\promote-pattern.ps1') -Arguments @{ ExperienceId = $experienceId; PromotedBy = 'fixture-reviewer'; SkillRoot = $testSkill } | Out-Null
    $find = Invoke-TestScript -Name 'verified_pattern_is_matchable' -Script (Join-Path $testSkill 'scripts\find-verified-patterns.ps1') -Arguments @{ Category = 'packaging'; Tag = 'nested-runtime'; SkillRoot = $testSkill }
    if (($find -join "`n") -notmatch [regex]::Escape($experienceId)) { throw 'Verified pattern was not returned by lookup' }

    $findScript = Join-Path $testSkill 'scripts\find-verified-patterns.ps1'
    $indexPath = Join-Path $testSkill 'knowledge\INDEX.json'
    $originalIndex = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath
    $unfiltered = Invoke-TestScript -Name 'verified_pattern_is_matchable_without_filters' -Script $findScript -Arguments @{ SkillRoot = $testSkill }
    if (($unfiltered -join "`n") -notmatch [regex]::Escape($experienceId)) { throw 'Unfiltered lookup did not return the verified pattern' }
    $badFilter = Invoke-TestScript -Name 'reject_unknown_category_filter' -Script $findScript -Arguments @{ Category = 'packagin'; SkillRoot = $testSkill } -ExpectFailure $true
    if (@($badFilter | Where-Object { [string]$_ -match '^RESULT: invalid_query' }).Count -ne 1) { throw 'Unknown category filter did not print a clean invalid_query verdict' }
    foreach ($damage in @(
        @{ Name = 'reject_index_entry_missing_path'; Apply = { param($entry) $entry.PSObject.Properties.Remove('path') } },
        @{ Name = 'reject_index_entry_outside_verified'; Apply = { param($entry) $entry.path = '../../SKILL.md' } },
        @{ Name = 'reject_index_entry_hash_drift'; Apply = { param($entry) $entry.sha256 = ('0' * 64) } }
    )) {
        $damaged = $originalIndex | ConvertFrom-Json
        $verifiedEntries = @($damaged.entries | Where-Object { $_.status -eq 'verified' })
        if ($verifiedEntries.Count -ne 1) { throw 'Fixture index does not hold exactly one verified entry' }
        & $damage.Apply $verifiedEntries[0]
        [System.IO.File]::WriteAllText($indexPath, ($damaged | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
        # Query with the filters that would otherwise match, so the damaged entry really reaches the gate
        # instead of being dropped earlier for an unrelated reason.
        $damagedOutput = Invoke-TestScript -Name $damage.Name -Script $findScript -Arguments @{ Category = 'packaging'; Tag = 'nested-runtime'; SkillRoot = $testSkill } -ExpectFailure $true
        if (@($damagedOutput | Where-Object { [string]$_ -match '^MATCH: ' }).Count -gt 0) { throw "$($damage.Name) still returned a pattern" }
        # A crash is not a rejection: the script has to print its own verdict line.
        if (@($damagedOutput | Where-Object { [string]$_ -match '^RESULT: invalid_index' }).Count -ne 1) { throw "$($damage.Name) did not print a clean invalid_index verdict" }
        [System.IO.File]::WriteAllText($indexPath, $originalIndex, (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-TestScript -Name 'deprecate_pattern' -Script (Join-Path $testSkill 'scripts\deprecate-pattern.ps1') -Arguments @{ ExperienceId = $experienceId; DeprecatedBy = 'fixture-reviewer'; Reason = 'Fixture lifecycle test'; SkillRoot = $testSkill } | Out-Null
    $findAfter = Invoke-TestScript -Name 'deprecated_pattern_not_matchable' -Script (Join-Path $testSkill 'scripts\find-verified-patterns.ps1') -Arguments @{ Category = 'packaging'; Tag = 'nested-runtime'; SkillRoot = $testSkill }
    if (($findAfter -join "`n") -match [regex]::Escape($experienceId)) { throw 'Deprecated pattern remained matchable' }

    $badDraft = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $source 'fixtures\evolution\candidate-draft.json') | ConvertFrom-Json
    $badDraft.summary = 'This deliberately private draft includes C:\private\customer\target.exe and must fail automatic export.'
    $badDraft | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $private 'product-state\learning\CANDIDATE-DRAFT.json') -Encoding UTF8
    Invoke-TestScript -Name 'reject_private_path' -Script (Join-Path $testSkill 'scripts\capture-experience.ps1') -Arguments @{
        ProductRoot = $private; EvidencePath = (Join-Path $private 'product-state\analysis\evidence.txt'); SkillRoot = $testSkill
    } -ExpectFailure $true | Out-Null

    Invoke-TestScript -Name 'validate_final_knowledge' -Script (Join-Path $testSkill 'scripts\validate-knowledge.ps1') -Arguments @{ SkillRoot = $testSkill } | Out-Null
    & $shellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testSkill 'scripts\rebuild-knowledge-index.ps1') -SkillRoot $testSkill | Out-Null
    $firstIndexHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
    & $shellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testSkill 'scripts\rebuild-knowledge-index.ps1') -SkillRoot $testSkill | Out-Null
    $secondIndexHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
    if ($firstIndexHash -ne $secondIndexHash) { throw 'Knowledge index is not deterministic' }
    [void]$passes.Add('deterministic_index')
    Write-Output "RESULT: passed ($($passes.Count) evolution checks)"
    foreach ($pass in $passes) { Write-Output "PASS: $pass" }
}
finally {
    if ($KeepTemporaryFiles) { Write-Output "TEMP_RETAINED: $temp" }
    elseif ((Test-Path -LiteralPath $temp -PathType Container) -and $temp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}
