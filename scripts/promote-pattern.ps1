#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^exp-[a-f0-9]{32}$')][string]$ExperienceId,
    [Parameter(Mandatory = $true)][ValidateLength(2, 80)][string]$PromotedBy,
    [string]$SkillRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\knowledge-common.ps1')
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }

$knowledge = Get-KnowledgeRoot -SkillRoot $SkillRoot
$candidatePath = Join-Path $knowledge "candidates\$ExperienceId.json"
$verifiedPath = Join-Path $knowledge "verified\$ExperienceId.json"
$record = Read-JsonFile -Path $candidatePath
$shapeErrors = @(Test-ExperienceRecord -Record $record -ExpectedStatus candidate)
if ($shapeErrors.Count -gt 0) { throw "Candidate is invalid: $($shapeErrors -join '; ')" }
if ($record.sanitization.automatic_scan -ne 'passed' -or $record.sanitization.reviewed_status -ne 'approved') { throw 'Candidate has not passed sanitization review' }
$currentPayloadHash = Get-ExperiencePayloadHash -Record $record
if ($record.payload_sha256 -ne $currentPayloadHash) { throw "Candidate payload hash does not match current content: stored=$($record.payload_sha256), actual=$currentPayloadHash" }
if ($record.sanitization.payload_sha256 -ne $record.payload_sha256) { throw 'Sanitization review belongs to an older payload' }
if (@($record.reviews | Where-Object { $_.decision -eq 'approve' -and $_.payload_sha256 -eq $record.payload_sha256 }).Count -lt 1) { throw 'Candidate has no approving review for the current payload' }

$realSources = @($record.source_evidence | Where-Object { $_.source_kind -eq 'real_product' -and $_.evidence_role -eq 'supporting' } | ForEach-Object { $_.source_id } | Select-Object -Unique)
$positiveFixtures = @($record.source_evidence | Where-Object { $_.source_kind -eq 'fixture' -and $_.evidence_role -eq 'positive_fixture' } | ForEach-Object { $_.source_id } | Select-Object -Unique)
$negativeFixtures = @($record.source_evidence | Where-Object { $_.source_kind -eq 'fixture' -and $_.evidence_role -eq 'negative_fixture' } | ForEach-Object { $_.source_id } | Select-Object -Unique)
if ($realSources.Count -lt 2) { throw 'Promotion requires two independent real product sources' }
if ($positiveFixtures.Count -lt 1) { throw 'Promotion requires at least one independent positive fixture' }
if ($negativeFixtures.Count -lt 1) { throw 'Promotion requires at least one independent negative fixture' }
$behaviorCategories = @('ui', 'authorization', 'update', 'migration', 'release')
if ($record.category -in $behaviorCategories) {
    $exercised = @($record.source_evidence | Where-Object { $_.source_kind -eq 'real_product' -and $_.evidence_level -in @('locally_exercised', 'dynamic_success', 'failure_observed') })
    if ($exercised.Count -lt 1) { throw 'Behavior-changing patterns require exercised real-product evidence' }
}
$evidenceRule = 'two_real_products_plus_fixtures'

$candidateHash = Get-Sha256 -Path $candidatePath
$now = Get-IsoTimestamp
$record.record_type = 'shared_pattern'
$record.status = 'verified'
$record.updated_at = $now
$record | Add-Member -NotePropertyName promotion -NotePropertyValue ([pscustomobject][ordered]@{
    promoted_at = $now
    promoted_by = $PromotedBy
    evidence_rule = $evidenceRule
    candidate_sha256 = $candidateHash
    payload_sha256 = $record.payload_sha256
})
$verifiedErrors = @(Test-ExperienceRecord -Record $record -ExpectedStatus verified)
if ($verifiedErrors.Count -gt 0) { throw "Promoted pattern is invalid: $($verifiedErrors -join '; ')" }

$lock = Enter-KnowledgeWriteLock -KnowledgeRoot $knowledge
try {
    if (Test-Path -LiteralPath $verifiedPath) { throw "Verified pattern already exists: $verifiedPath" }
    Write-Utf8Json -Value $record -Path $verifiedPath
    Remove-Item -LiteralPath $candidatePath
    Update-KnowledgeIndex -SkillRoot $SkillRoot
}
finally { $lock.Dispose() }

Write-Output 'RESULT: pattern_promoted'
Write-Output "experience_id=$ExperienceId"
Write-Output "evidence_rule=$evidenceRule"
Write-Output "verified_pattern=$verifiedPath"
