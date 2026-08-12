#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^exp-[a-f0-9]{32}$')][string]$ExperienceId,
    [Parameter(Mandatory = $true)][ValidateSet('approve', 'reject')][string]$Decision,
    [Parameter(Mandatory = $true)][ValidateLength(2, 80)][string]$Reviewer,
    [Parameter(Mandatory = $true)][ValidateLength(3, 500)][string]$Notes,
    [string]$SkillRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\knowledge-common.ps1')
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }

$knowledge = Get-KnowledgeRoot -SkillRoot $SkillRoot
$candidatePath = Join-Path $knowledge "candidates\$ExperienceId.json"
$record = Read-JsonFile -Path $candidatePath
$shapeErrors = @(Test-ExperienceRecord -Record $record -ExpectedStatus candidate)
if ($shapeErrors.Count -gt 0) { throw "Candidate is invalid: $($shapeErrors -join '; ')" }
$reviewText = [ordered]@{ reviewer = $Reviewer; notes = $Notes } | ConvertTo-Json
$reviewFindings = @(Get-PublicContentFindings -Text $reviewText)
if ($reviewFindings.Count -gt 0) { throw "Review metadata failed sanitization: $($reviewFindings -join ', ')" }
$recordText = Get-ExperiencePublicText -Record $record
$findings = @(Get-PublicContentFindings -Text $recordText)
if ($recordText -match '(?i)UNVERIFIED|__PRODUCT_|__BASELINE_|__CORE_') { $findings += 'placeholder_or_unverified' }
$findings = @($findings | Select-Object -Unique)
if ($Decision -eq 'approve' -and $findings.Count -gt 0) { throw "Candidate failed sanitization review: $($findings -join ', ')" }

$now = Get-IsoTimestamp
$review = [ordered]@{ reviewer = $Reviewer; decision = $Decision; reviewed_at = $now; payload_sha256 = (Get-ExperiencePayloadHash -Record $record); notes = $Notes }
$record.reviews = @($record.reviews) + $review
$record.updated_at = $now
$record.sanitization.automatic_scan = if ($findings.Count -eq 0) { 'passed' } else { 'failed' }
$record.sanitization.reviewed_status = if ($Decision -eq 'approve') { 'approved' } else { 'rejected' }
$record.sanitization.checked_at = $now
$record.sanitization.payload_sha256 = $record.payload_sha256
$record.sanitization.findings = $findings
$lock = Enter-KnowledgeWriteLock -KnowledgeRoot $knowledge
try {
    Write-Utf8Json -Value $record -Path $candidatePath
    Update-KnowledgeIndex -SkillRoot $SkillRoot
}
finally { $lock.Dispose() }

Write-Output "RESULT: review_recorded"
Write-Output "experience_id=$ExperienceId"
Write-Output "decision=$Decision"
Write-Output "sanitization=$($record.sanitization.automatic_scan)"
