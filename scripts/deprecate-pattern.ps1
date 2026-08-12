#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^exp-[a-f0-9]{32}$')][string]$ExperienceId,
    [Parameter(Mandatory = $true)][ValidateLength(2, 80)][string]$DeprecatedBy,
    [Parameter(Mandatory = $true)][ValidateLength(5, 500)][string]$Reason,
    [string]$ReplacementId = '',
    [string]$SkillRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\knowledge-common.ps1')
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }

if (-not [string]::IsNullOrWhiteSpace($ReplacementId) -and $ReplacementId -notmatch '^exp-[a-f0-9]{32}$') { throw 'ReplacementId format is invalid' }
if ($ReplacementId -eq $ExperienceId) { throw 'A deprecated pattern cannot replace itself' }
$metadataFindings = @(Get-PublicContentFindings -Text "$DeprecatedBy`n$Reason")
if ($metadataFindings.Count -gt 0) { throw "Deprecation metadata failed sanitization: $($metadataFindings -join ', ')" }
$knowledge = Get-KnowledgeRoot -SkillRoot $SkillRoot
$verifiedPath = Join-Path $knowledge "verified\$ExperienceId.json"
$deprecatedPath = Join-Path $knowledge "deprecated\$ExperienceId.json"
$record = Read-JsonFile -Path $verifiedPath
$shapeErrors = @(Test-ExperienceRecord -Record $record -ExpectedStatus verified)
if ($shapeErrors.Count -gt 0) { throw "Verified pattern is invalid: $($shapeErrors -join '; ')" }
$now = Get-IsoTimestamp
$record.status = 'deprecated'
$record.updated_at = $now
$record | Add-Member -NotePropertyName deprecation -NotePropertyValue ([pscustomobject][ordered]@{
    deprecated_at = $now
    deprecated_by = $DeprecatedBy
    reason = $Reason
    replacement_id = $ReplacementId
})
$lock = Enter-KnowledgeWriteLock -KnowledgeRoot $knowledge
try {
    if (Test-Path -LiteralPath $deprecatedPath) { throw "Deprecated pattern already exists: $deprecatedPath" }
    Write-Utf8Json -Value $record -Path $deprecatedPath
    Remove-Item -LiteralPath $verifiedPath
    Update-KnowledgeIndex -SkillRoot $SkillRoot
}
finally { $lock.Dispose() }

Write-Output 'RESULT: pattern_deprecated'
Write-Output "experience_id=$ExperienceId"
Write-Output "deprecated_pattern=$deprecatedPath"
