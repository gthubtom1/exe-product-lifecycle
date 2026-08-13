#requires -Version 5

[CmdletBinding()]
param(
    [string]$Category,
    [string[]]$Tag,
    [string]$SkillRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\knowledge-common.ps1')
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }

function Get-EntryField {
    param($Entry, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Entry -or $Entry.PSObject.Properties.Name -notcontains $Name) { return $null }
    return $Entry.$Name
}

function Format-MatchField {
    param([string]$Value)
    return ([regex]::Replace($Value, '[\p{C}|]', ' ')).Trim()
}

function Get-VerifiedEntryErrors {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$KnowledgeRoot
    )
    $issues = New-Object System.Collections.Generic.List[string]
    foreach ($field in @('experience_id', 'status', 'category', 'title', 'tags', 'path', 'sha256', 'updated_at')) {
        if ($Entry.PSObject.Properties.Name -notcontains $field) { [void]$issues.Add("missing field: $field") }
    }
    if ($issues.Count -gt 0) { return @($issues) }

    $experienceId = [string]$Entry.experience_id
    if ($experienceId -notmatch '^exp-[a-f0-9]{32}$') { [void]$issues.Add('experience_id format is invalid') }
    if ([string]$Entry.sha256 -notmatch '^[A-F0-9]{64}$') { [void]$issues.Add('sha256 format is invalid') }
    if ([string]$Entry.category -notin $script:KnowledgeCategories) { [void]$issues.Add("category is invalid: $($Entry.category)") }
    if ([string]::IsNullOrWhiteSpace([string]$Entry.title) -or ([string]$Entry.title).Length -gt 120) { [void]$issues.Add('title is empty or too long') }
    if ([string]::IsNullOrWhiteSpace([string]$Entry.updated_at)) { [void]$issues.Add('updated_at is empty') }
    if (-not (Test-StringArray $Entry.tags)) { [void]$issues.Add('tags must contain strings') }
    if ($issues.Count -gt 0) { return @($issues) }

    # A verified entry may only ever point at its own record inside knowledge/verified,
    # so the generated relative path is fully determined by the experience_id.
    $expectedPath = "knowledge/verified/$experienceId.json"
    if ([string]$Entry.path -ne $expectedPath) {
        [void]$issues.Add("path must be $expectedPath")
        return @($issues)
    }
    $recordPath = Join-Path $KnowledgeRoot "verified\$experienceId.json"
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        [void]$issues.Add("record file is missing: $expectedPath")
        return @($issues)
    }
    if ((Get-Sha256 -Path $recordPath) -ne [string]$Entry.sha256) {
        [void]$issues.Add('record file no longer matches the indexed sha256')
        return @($issues)
    }
    $record = Read-JsonFile -Path $recordPath
    if ([string](Get-EntryField -Entry $record -Name 'experience_id') -ne $experienceId) { [void]$issues.Add('record experience_id does not match the index entry') }
    if ([string](Get-EntryField -Entry $record -Name 'status') -ne 'verified') { [void]$issues.Add('record status is not verified') }
    if ($issues.Count -gt 0) { return @($issues) }

    # Consistency with the publish gate: find-verified must never serve a "verified" record that
    # validate-knowledge would reject. Re-run the same shape + independent-evidence threshold here, so the
    # consumer side is not looser than the publish side. (RV evolution find-vs-validate gap.)
    foreach ($shapeError in @(Test-ExperienceRecord -Record $record -ExpectedStatus 'verified')) {
        [void]$issues.Add("record fails publish-gate shape: $shapeError")
    }
    $evidenceItems = @()
    if ($record.PSObject.Properties.Name -contains 'source_evidence' -and $null -ne $record.source_evidence) {
        $evidenceItems = @($record.source_evidence | Where-Object { $null -ne $_ })
    }
    $realSources = @($evidenceItems | Where-Object { (Get-EntryField -Entry $_ -Name 'source_kind') -eq 'real_product' -and (Get-EntryField -Entry $_ -Name 'evidence_role') -eq 'supporting' } | ForEach-Object { Get-EntryField -Entry $_ -Name 'source_id' } | Where-Object { $_ } | Select-Object -Unique)
    $positiveFixtures = @($evidenceItems | Where-Object { (Get-EntryField -Entry $_ -Name 'source_kind') -eq 'fixture' -and (Get-EntryField -Entry $_ -Name 'evidence_role') -eq 'positive_fixture' })
    $negativeFixtures = @($evidenceItems | Where-Object { (Get-EntryField -Entry $_ -Name 'source_kind') -eq 'fixture' -and (Get-EntryField -Entry $_ -Name 'evidence_role') -eq 'negative_fixture' })
    if ($realSources.Count -lt 2 -or $positiveFixtures.Count -lt 1 -or $negativeFixtures.Count -lt 1) {
        [void]$issues.Add('record does not meet independent evidence threshold (same bar as validate-knowledge)')
    }
    return @($issues)
}

$knowledge = Get-KnowledgeRoot -SkillRoot $SkillRoot
$queryErrors = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($Category) -and $Category -notin $script:KnowledgeCategories) {
    [void]$queryErrors.Add("unknown category: $Category (allowed: $($script:KnowledgeCategories -join ', '))")
}
$requestedTags = @($Tag | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Select-Object -Unique)
foreach ($requestedTag in $requestedTags) {
    if ($requestedTag -notmatch '^[a-z0-9][a-z0-9._-]{1,31}$') { [void]$queryErrors.Add("unusable tag filter: $requestedTag") }
}
if ($queryErrors.Count -gt 0) {
    foreach ($queryError in $queryErrors) { Write-Output "INVALID: $queryError" }
    Write-Output "RESULT: invalid_query ($($queryErrors.Count) problem(s))"
    exit 1
}

$index = Read-JsonFile -Path (Join-Path $knowledge 'INDEX.json')
$invalid = New-Object System.Collections.Generic.List[string]
$results = @()
if ($index.PSObject.Properties.Name -notcontains 'entries') { [void]$invalid.Add('INDEX.json has no entries array') }
else {
    foreach ($entry in @($index.entries)) {
        $status = [string](Get-EntryField -Entry $entry -Name 'status')
        if ($status -eq 'candidate' -or $status -eq 'deprecated') { continue }
        $label = [string](Get-EntryField -Entry $entry -Name 'experience_id')
        if ([string]::IsNullOrWhiteSpace($label)) { $label = '<entry without experience_id>' }
        if ($status -ne 'verified') {
            [void]$invalid.Add("$label | status is missing or unknown")
            continue
        }
        $entryErrors = @(Get-VerifiedEntryErrors -Entry $entry -KnowledgeRoot $knowledge)
        if ($entryErrors.Count -gt 0) {
            foreach ($entryError in $entryErrors) { [void]$invalid.Add("$label | $entryError") }
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($Category) -and [string]$entry.category -ne $Category) { continue }
        if ($requestedTags.Count -gt 0) {
            $entryTags = @($entry.tags | ForEach-Object { [string]$_ })
            $missingTags = @($requestedTags | Where-Object { $_ -notin $entryTags })
            if ($missingTags.Count -gt 0) { continue }
        }
        $results += $entry
    }
}

# Never emit a partially trusted result set: a damaged verified entry fails the whole lookup.
if ($invalid.Count -gt 0) {
    foreach ($item in $invalid) { Write-Output "INVALID: $item" }
    Write-Output "RESULT: invalid_index ($($invalid.Count) problem(s)); run scripts/validate-knowledge.ps1"
    exit 1
}
if ($results.Count -eq 0) {
    Write-Output 'RESULT: no_verified_pattern'
    exit 0
}
foreach ($entry in $results) {
    Write-Output "MATCH: $(Format-MatchField ([string]$entry.experience_id)) | $(Format-MatchField ([string]$entry.category)) | $(Format-MatchField ([string]$entry.title)) | $(Format-MatchField ([string]$entry.path))"
}
Write-Output "RESULT: $($results.Count) verified pattern(s)"
