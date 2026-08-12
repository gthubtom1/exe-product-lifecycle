#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProductRoot,
    [Parameter(Mandatory = $true)][string[]]$EvidencePath,
    [string]$DraftPath,
    [string]$SkillRoot,
    [ValidateSet('real_product', 'fixture')][string]$SourceKind = 'real_product'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\knowledge-common.ps1')
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }

$identity = Get-ProductIdentity -ProductRoot $ProductRoot
if ($identity.Status -in @('INIT', 'BASELINE_CREATED')) {
    throw "Product evidence is not ready; current status is $($identity.Status)"
}
$ledger = Join-Path $identity.StateRoot 'EVIDENCE-LEDGER.yaml'
if (-not (Test-Path -LiteralPath $ledger -PathType Leaf)) { throw "Evidence ledger not found: $ledger" }
if ([string]::IsNullOrWhiteSpace($DraftPath)) {
    $DraftPath = Join-Path $identity.StateRoot 'learning\CANDIDATE-DRAFT.json'
}
$draftPathResolved = Assert-PathWithinRoot -Path $DraftPath -Root $identity.StateRoot
$draft = Read-JsonFile -Path $draftPathResolved

$required = @('schema_version', 'title', 'summary', 'category', 'tags', 'evidence_level', 'pattern')
foreach ($name in $required) {
    if ($draft.PSObject.Properties.Name -notcontains $name) { throw "Draft is missing field: $name" }
}
if ([int]$draft.schema_version -ne 1) { throw 'Draft schema_version must be 1' }
if ([string]$draft.category -notin $script:KnowledgeCategories) { throw 'Draft category is invalid' }
if ([string]$draft.evidence_level -notin $script:EvidenceLevels) { throw 'Draft evidence_level is invalid' }
if (-not (Test-StringArray $draft.tags)) { throw 'Draft tags are empty' }
$patternFields = @('applicability', 'detection', 'negative_indicators', 'procedure', 'verification', 'rollback', 'failure_signals', 'stop_conditions', 'limitations')
foreach ($field in $patternFields) {
    if ($draft.pattern.PSObject.Properties.Name -notcontains $field -or -not (Test-StringArray $draft.pattern.$field)) {
        throw "Draft pattern.$field must contain at least one string"
    }
}

$publicPayload = [ordered]@{
    title = [string]$draft.title
    summary = [string]$draft.summary
    category = [string]$draft.category
    tags = @($draft.tags)
    pattern = $draft.pattern
}
$payloadText = $publicPayload | ConvertTo-Json -Depth 20
if ($payloadText -match '(?i)UNVERIFIED|__PRODUCT_|__BASELINE_|__CORE_') { throw 'Draft still contains placeholders or UNVERIFIED text' }
$coreName = if ([string]::IsNullOrWhiteSpace($identity.CorePath)) { '' } else { [IO.Path]::GetFileName($identity.CorePath) }
$coreStem = if ([string]::IsNullOrWhiteSpace($coreName)) { '' } else { [IO.Path]::GetFileNameWithoutExtension($coreName) }
$privateTerms = @($identity.ProductId, $identity.ProductName, $coreName, $coreStem) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$findings = @(Get-PublicContentFindings -Text $payloadText -PrivateTerms $privateTerms)
if ($findings.Count -gt 0) { throw "Draft failed sanitization: $($findings -join ', ')" }

$experienceId = 'exp-' + [Guid]::NewGuid().ToString('N')
$sourceId = 'src-' + [Guid]::NewGuid().ToString('N')
$evidence = New-PublicEvidenceRecords -EvidencePath $EvidencePath -AllowedRoot $identity.StateRoot -SourceId $sourceId -SourceKind $SourceKind -EvidenceRole 'supporting' -EvidenceLevel ([string]$draft.evidence_level)
$now = Get-IsoTimestamp
$record = [pscustomobject][ordered]@{
    schema_version = 1
    record_type = 'experience_candidate'
    experience_id = $experienceId
    status = 'candidate'
    created_at = $now
    updated_at = $now
    payload_sha256 = ('0' * 64)
    title = [string]$draft.title
    summary = [string]$draft.summary
    category = [string]$draft.category
    tags = @($draft.tags)
    source_evidence = @($evidence.Public)
    pattern = $draft.pattern
    sanitization = [pscustomobject][ordered]@{
        automatic_scan = 'passed'
        reviewed_status = 'pending'
        scan_version = 1
        checked_at = $now
        payload_sha256 = ('0' * 64)
        findings = @()
    }
    reviews = @()
}
$record = ($record | ConvertTo-Json -Depth 30) | ConvertFrom-Json
$record.payload_sha256 = Get-ExperiencePayloadHash -Record $record
$record.sanitization.payload_sha256 = $record.payload_sha256
$shapeErrors = @(Test-ExperienceRecord -Record $record -ExpectedStatus candidate)
if ($shapeErrors.Count -gt 0) { throw "Generated candidate is invalid: $($shapeErrors -join '; ')" }

$knowledge = Get-KnowledgeRoot -SkillRoot $SkillRoot
$destination = Join-Path $knowledge "candidates\$experienceId.json"
$localCandidateDir = Join-Path $identity.StateRoot 'learning\candidates'
$localCandidatePath = Join-Path $localCandidateDir "$experienceId.private.json"
$localCandidate = [ordered]@{
    schema_version = 1
    experience_id = $experienceId
    product_id = $identity.ProductId
    source_id = $sourceId
    shared_candidate = $destination
    created_at = $now
    evidence = @($evidence.Local)
    generalized_payload = $publicPayload
}
$exportMap = Read-ExportMap -Identity $identity
$lock = Enter-KnowledgeWriteLock -KnowledgeRoot $knowledge
try {
    if (Test-Path -LiteralPath $destination) { throw "Candidate already exists: $destination" }
    Write-Utf8Json -Value $record -Path $destination
    Write-Utf8Json -Value $localCandidate -Path $localCandidatePath
    Add-ExportMapRecord -ExportMap $exportMap -ExperienceId $experienceId -SourceId $sourceId -SourceKind $SourceKind -EvidenceRecords @($evidence.Local)
    Update-KnowledgeIndex -SkillRoot $SkillRoot
}
finally { $lock.Dispose() }

Write-Output "RESULT: candidate_created"
Write-Output "experience_id=$experienceId"
Write-Output "shared_candidate=$destination"
Write-Output "local_receipt=$localCandidatePath"
Write-Output "next=add independent evidence, run review-experience.ps1, then promote-pattern.ps1"
