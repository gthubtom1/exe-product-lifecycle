#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProductRoot,
    [Parameter(Mandatory = $true)][ValidatePattern('^exp-[a-f0-9]{32}$')][string]$ExperienceId,
    [Parameter(Mandatory = $true)][string[]]$EvidencePath,
    [string]$SkillRoot,
    [ValidateSet('real_product', 'fixture')][string]$SourceKind = 'real_product',
    [ValidateSet('supporting', 'positive_fixture', 'negative_fixture')][string]$EvidenceRole = 'supporting',
    [ValidateSet('static_present', 'entrypoint_present', 'locally_exercised', 'dynamic_success', 'failure_observed')][string]$EvidenceLevel = 'locally_exercised'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\knowledge-common.ps1')
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }

if ($SourceKind -eq 'real_product' -and $EvidenceRole -ne 'supporting') { throw 'Real product evidence must use the supporting role' }
if ($SourceKind -eq 'fixture' -and $EvidenceRole -eq 'supporting') { throw 'Fixture evidence must be positive_fixture or negative_fixture' }
$identity = Get-ProductIdentity -ProductRoot $ProductRoot
if ($identity.Status -in @('INIT', 'BASELINE_CREATED')) { throw "Product evidence is not ready; current status is $($identity.Status)" }
$knowledge = Get-KnowledgeRoot -SkillRoot $SkillRoot
$candidatePath = Join-Path $knowledge "candidates\$ExperienceId.json"
$record = Read-JsonFile -Path $candidatePath
$shapeErrors = @(Test-ExperienceRecord -Record $record -ExpectedStatus candidate)
if ($shapeErrors.Count -gt 0) { throw "Candidate is invalid: $($shapeErrors -join '; ')" }

$exportMap = Read-ExportMap -Identity $identity
$sourceId = Get-OrCreateSourceId -ExportMap $exportMap -ExperienceId $ExperienceId
$evidence = New-PublicEvidenceRecords -EvidencePath $EvidencePath -AllowedRoot $identity.StateRoot -SourceId $sourceId -SourceKind $SourceKind -EvidenceRole $EvidenceRole -EvidenceLevel $EvidenceLevel
$existingProofIds = @($record.source_evidence | ForEach-Object { [string]$_.evidence_proof_id })
$existingLocalHashes = @($exportMap.Value.exports | Where-Object { $_.experience_id -eq $ExperienceId } | ForEach-Object { @($_.local_evidence) } | ForEach-Object { [string]$_.sha256 })
$newEvidence = @()
for ($i = 0; $i -lt @($evidence.Public).Count; $i++) {
    if ($existingLocalHashes -notcontains [string]@($evidence.Local)[$i].sha256 -and $existingProofIds -notcontains [string]@($evidence.Public)[$i].evidence_proof_id) {
        $newEvidence += @($evidence.Public)[$i]
    }
}
if ($newEvidence.Count -eq 0) {
    Write-Output 'RESULT: evidence_already_registered'
    Write-Output "experience_id=$ExperienceId"
    exit 0
}

$record.source_evidence = @($record.source_evidence) + $newEvidence
$record.updated_at = Get-IsoTimestamp
$record.payload_sha256 = Get-ExperiencePayloadHash -Record $record
$record.sanitization.reviewed_status = 'pending'
$record.sanitization.checked_at = Get-IsoTimestamp
$record.sanitization.payload_sha256 = $record.payload_sha256
$lock = Enter-KnowledgeWriteLock -KnowledgeRoot $knowledge
try {
    Write-Utf8Json -Value $record -Path $candidatePath
    Add-ExportMapRecord -ExportMap $exportMap -ExperienceId $ExperienceId -SourceId $sourceId -SourceKind $SourceKind -EvidenceRecords @($evidence.Local)
    Update-KnowledgeIndex -SkillRoot $SkillRoot
}
finally { $lock.Dispose() }

Write-Output 'RESULT: evidence_added'
Write-Output "experience_id=$ExperienceId"
Write-Output "source_id=$sourceId"
Write-Output "evidence_role=$EvidenceRole"
Write-Output "added=$($newEvidence.Count)"
