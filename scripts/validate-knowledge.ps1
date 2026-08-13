#requires -Version 5

[CmdletBinding()]
param(
    [string]$SkillRoot,
    [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\knowledge-common.ps1')
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$seenIds = @{}
$actualEntries = New-Object System.Collections.Generic.List[object]
$coverage = New-Object System.Collections.Generic.List[object]
$plannedSections = @('schemas', 'records', 'deprecated', 'index', 'lock')

# A malformed record must not be able to hide the checks that come after it.
# Under Set-StrictMode -Version Latest, reading an absent property raises a
# terminating PropertyNotFoundException, so one bad file used to abort the whole
# script before the report block ever ran -- the errors already collected were
# discarded along with every check that had not happened yet.
#
# Three defences, in order of how much they cover:
#   1. these helpers read optional data without throwing;
#   2. every section is wrapped, so a failure inside one is recorded and the
#      rest still run;
#   3. each coverage line is written the moment its section ends, and the whole
#      body sits in try/catch/finally, so a crash anywhere -- including outside
#      every section -- still leaves the progress so far on stdout and still
#      produces a RESULT line.
# Buffering the report to the end and printing it in one go is what made the
# original failure invisible; it must not be reintroduced here.
function Get-OptionalValue {
    param($InputObject, [Parameter(Mandatory = $true)][string[]]$Name)
    $node = $InputObject
    foreach ($segment in $Name) {
        if ($null -eq $node) { return $null }
        $property = $node.PSObject.Properties[$segment]
        if ($null -eq $property) { return $null }
        $node = $property.Value
    }
    return $node
}

function Get-OptionalArray {
    param($InputObject, [Parameter(Mandatory = $true)][string[]]$Name)
    $value = Get-OptionalValue -InputObject $InputObject -Name $Name
    if ($null -eq $value) { return @() }
    return @($value | Where-Object { $null -ne $_ })
}

function Add-Coverage {
    param(
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][ValidateSet('executed', 'skipped', 'aborted', 'not_reached')][string]$Status,
        [string]$Detail = ''
    )
    [void]$coverage.Add([pscustomobject]@{ Section = $Section; Status = $Status; Detail = $Detail })
    $suffix = if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { " $Detail" }
    # Emitted immediately: a line already on stdout cannot be lost by a later crash.
    Write-Output "COVERAGE: section=$Section status=$Status$suffix"
}

try {
    $root = (Resolve-Path -LiteralPath $SkillRoot).Path.TrimEnd('\')
    $knowledge = Get-KnowledgeRoot -SkillRoot $root

    $schemaCount = 0
    try {
        foreach ($schema in @(Get-ChildItem -LiteralPath (Join-Path $root 'schemas') -File -Filter '*.json')) {
            $schemaCount++
            try { $null = Read-JsonFile -Path $schema.FullName }
            catch { [void]$errors.Add($_.Exception.Message) }
        }
        Add-Coverage -Section 'schemas' -Status 'executed' -Detail "files=$schemaCount"
    }
    catch {
        [void]$errors.Add("validation section 'schemas' aborted: $($_.Exception.Message)")
        Add-Coverage -Section 'schemas' -Status 'aborted' -Detail "files=$schemaCount"
    }

    $allowedRecordProperties = @('schema_version', 'record_type', 'experience_id', 'status', 'created_at', 'updated_at', 'payload_sha256', 'title', 'summary', 'category', 'tags', 'source_evidence', 'pattern', 'sanitization', 'reviews', 'promotion', 'deprecation')
    $folders = [ordered]@{ candidates = 'candidate'; verified = 'verified'; deprecated = 'deprecated' }
    $recordCount = 0
    try {
        foreach ($folderEntry in $folders.GetEnumerator()) {
            $folder = Join-Path $knowledge $folderEntry.Key
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [void]$errors.Add("missing knowledge folder: $($folderEntry.Key)"); continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $folder -File)) {
                if ($file.Name -eq '.gitkeep') { continue }
                if ($file.Extension -ne '.json') { [void]$errors.Add("non-JSON file in public knowledge: $($file.FullName)"); continue }
                if ($file.Length -gt 262144) { [void]$errors.Add("knowledge record exceeds 256 KiB: $($file.Name)") }
                try { $record = Read-JsonFile -Path $file.FullName }
                catch { [void]$errors.Add($_.Exception.Message); continue }
                $recordCount++
                foreach ($property in $record.PSObject.Properties.Name) {
                    if ($property -notin $allowedRecordProperties) { [void]$errors.Add("unknown record field '$property' in $($file.Name)") }
                }
                $shapeErrors = @(Test-ExperienceRecord -Record $record -ExpectedStatus $folderEntry.Value)
                foreach ($shapeError in $shapeErrors) { [void]$errors.Add("$($file.Name): $shapeError") }
                try {
                    $currentPayloadHash = Get-ExperiencePayloadHash -Record $record
                    if ($record.payload_sha256 -ne $currentPayloadHash) { [void]$errors.Add("$($file.Name): payload hash mismatch") }
                    if ($record.sanitization.payload_sha256 -ne $record.payload_sha256) { [void]$errors.Add("$($file.Name): sanitization belongs to another payload") }
                }
                catch { [void]$errors.Add("$($file.Name): payload validation failed: $($_.Exception.Message)") }
                if ($folderEntry.Value -ne 'candidate') {
                    $evidenceItems = @(Get-OptionalArray -InputObject $record -Name 'source_evidence')
                    $realSources = @($evidenceItems | Where-Object { (Get-OptionalValue -InputObject $_ -Name 'source_kind') -eq 'real_product' -and (Get-OptionalValue -InputObject $_ -Name 'evidence_role') -eq 'supporting' } | ForEach-Object { Get-OptionalValue -InputObject $_ -Name 'source_id' } | Select-Object -Unique)
                    $positiveFixtures = @($evidenceItems | Where-Object { (Get-OptionalValue -InputObject $_ -Name 'source_kind') -eq 'fixture' -and (Get-OptionalValue -InputObject $_ -Name 'evidence_role') -eq 'positive_fixture' } | ForEach-Object { Get-OptionalValue -InputObject $_ -Name 'source_id' } | Select-Object -Unique)
                    $negativeFixtures = @($evidenceItems | Where-Object { (Get-OptionalValue -InputObject $_ -Name 'source_kind') -eq 'fixture' -and (Get-OptionalValue -InputObject $_ -Name 'evidence_role') -eq 'negative_fixture' } | ForEach-Object { Get-OptionalValue -InputObject $_ -Name 'source_id' } | Select-Object -Unique)
                    if ($realSources.Count -lt 2 -or $positiveFixtures.Count -lt 1 -or $negativeFixtures.Count -lt 1) { [void]$errors.Add("$($file.Name): shared pattern does not meet independent evidence threshold") }
                    if ((Get-OptionalValue -InputObject $record -Name 'category') -in @('ui', 'authorization', 'update', 'migration', 'release')) {
                        $exercised = @($evidenceItems | Where-Object { (Get-OptionalValue -InputObject $_ -Name 'source_kind') -eq 'real_product' -and (Get-OptionalValue -InputObject $_ -Name 'evidence_level') -in @('locally_exercised', 'dynamic_success', 'failure_observed') })
                        if ($exercised.Count -lt 1) { [void]$errors.Add("$($file.Name): behavior-changing shared pattern has no exercised real-product evidence") }
                    }
                }
                $recordId = [string](Get-OptionalValue -InputObject $record -Name 'experience_id')
                if ($file.BaseName -ne $recordId) { [void]$errors.Add("record filename does not match experience_id: $($file.Name)") }
                if ($seenIds.ContainsKey($recordId)) { [void]$errors.Add("duplicate experience_id: $recordId") }
                else { $seenIds[$recordId] = $file.FullName }
                $text = Get-ExperiencePublicText -Record $record
                # The privacy gate must cover the WHOLE published record, not just the human projection:
                # publish-knowledge pushes the entire JSON, so sensitive data hidden in created_at/updated_at/
                # sanitization.* (or any other field) would otherwise leak to the public repo. Scan the full
                # canonical record too, masking only the record's own payload_sha256 self-hashes (validated
                # separately) so they do not trip the artifact_hash finding. (RV evolution HIGH leak.)
                $fullRecordText = ConvertTo-CanonicalJson -Value $record
                # Mask the VALUES of every structural integrity-hash field (payload_sha256, candidate_sha256,
                # sanitization.payload_sha256, any *_sha256): those are self-referential hashes the skill
                # computes and validates separately, not artifact hashes leaked from a target, so they must
                # not trip the artifact_hash finding. A hash actually leaked from a sample sits in free text
                # (title/summary/created_at/findings/notes), which is NOT a "...sha256": "<hex>" field and so
                # is still scanned and still caught below. (RV evolution HIGH leak; fixes an over-broad mask.)
                $fullRecordText = [regex]::Replace($fullRecordText, '("[A-Za-z0-9_]*sha256"\s*:\s*")[A-Fa-f0-9]{64}(")', '${1}SHA256_FIELD_OK${2}')
                $privacyFindings = @(Get-PublicContentFindings -Text $text) + @(Get-PublicContentFindings -Text $fullRecordText)
                if (($text + "`n" + $fullRecordText) -match '(?i)UNVERIFIED|__PRODUCT_|__BASELINE_|__CORE_') { $privacyFindings += 'placeholder_or_unverified' }
                foreach ($finding in @($privacyFindings | Select-Object -Unique)) { [void]$errors.Add("$($file.Name): public knowledge privacy finding: $finding") }
                $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
                [void]$actualEntries.Add([pscustomobject]@{
                    experience_id = $recordId
                    status = [string](Get-OptionalValue -InputObject $record -Name 'status')
                    category = [string](Get-OptionalValue -InputObject $record -Name 'category')
                    title = [string](Get-OptionalValue -InputObject $record -Name 'title')
                    tags = @(Get-OptionalArray -InputObject $record -Name 'tags')
                    path = $relative
                    sha256 = Get-Sha256 -Path $file.FullName
                    updated_at = [string](Get-OptionalValue -InputObject $record -Name 'updated_at')
                })
            }
        }
        Add-Coverage -Section 'records' -Status 'executed' -Detail "records=$recordCount"
    }
    catch {
        [void]$errors.Add("validation section 'records' aborted: $($_.Exception.Message)")
        Add-Coverage -Section 'records' -Status 'aborted' -Detail "records=$recordCount"
    }

    $deprecatedCount = 0
    try {
        foreach ($deprecatedFile in @(Get-ChildItem -LiteralPath (Join-Path $knowledge 'deprecated') -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $deprecatedCount++
            try { $deprecatedRecord = Read-JsonFile -Path $deprecatedFile.FullName }
            catch { [void]$errors.Add("$($deprecatedFile.Name): $($_.Exception.Message)"); continue }
            if ($null -eq (Get-OptionalValue -InputObject $deprecatedRecord -Name 'deprecation')) {
                [void]$errors.Add("$($deprecatedFile.Name): deprecated record has no deprecation block, so its replacement cannot be checked")
                continue
            }
            $replacementId = [string](Get-OptionalValue -InputObject $deprecatedRecord -Name 'deprecation', 'replacement_id')
            if ($replacementId -eq [string](Get-OptionalValue -InputObject $deprecatedRecord -Name 'experience_id')) { [void]$errors.Add("$($deprecatedFile.Name): deprecated pattern replaces itself") }
            if (-not [string]::IsNullOrWhiteSpace($replacementId) -and -not $seenIds.ContainsKey($replacementId)) { [void]$errors.Add("$($deprecatedFile.Name): replacement_id does not exist: $replacementId") }
        }
        Add-Coverage -Section 'deprecated' -Status 'executed' -Detail "files=$deprecatedCount"
    }
    catch {
        [void]$errors.Add("validation section 'deprecated' aborted: $($_.Exception.Message)")
        Add-Coverage -Section 'deprecated' -Status 'aborted' -Detail "files=$deprecatedCount"
    }

    $indexPath = Join-Path $knowledge 'INDEX.json'
    $lockPath = Join-Path $knowledge 'knowledge.lock.json'
    try { $index = Read-JsonFile -Path $indexPath }
    catch { [void]$errors.Add($_.Exception.Message); $index = $null }
    try { $knowledgeLock = Read-JsonFile -Path $lockPath }
    catch { [void]$errors.Add($_.Exception.Message); $knowledgeLock = $null }

    if ($null -eq $index) {
        Add-Coverage -Section 'index' -Status 'skipped' -Detail 'reason=INDEX.json unreadable'
    }
    else {
        $indexEntryCount = 0
        $indexDrift = 0
        $indexMissing = 0
        try {
            $indexEntries = @(Get-OptionalArray -InputObject $index -Name 'entries')
            $indexEntryCount = $indexEntries.Count
            $indexIds = @($indexEntries | ForEach-Object { [string](Get-OptionalValue -InputObject $_ -Name 'experience_id') })
            foreach ($actual in $actualEntries) {
                $matched = @($indexEntries | Where-Object { [string](Get-OptionalValue -InputObject $_ -Name 'experience_id') -eq $actual.experience_id })
                if ($matched.Count -ne 1) { [void]$errors.Add("index entry count is not 1 for $($actual.experience_id)"); $indexDrift++; continue }
                $entry = $matched[0]
                if ((Get-OptionalValue -InputObject $entry -Name 'path') -ne $actual.path -or (Get-OptionalValue -InputObject $entry -Name 'status') -ne $actual.status -or (Get-OptionalValue -InputObject $entry -Name 'sha256') -ne $actual.sha256) {
                    [void]$errors.Add("index drift for $($actual.experience_id)")
                    $indexDrift++
                }
            }
            foreach ($indexedId in $indexIds) {
                if (-not $seenIds.ContainsKey($indexedId)) { [void]$errors.Add("index references missing record: $indexedId"); $indexMissing++ }
            }
            Add-Coverage -Section 'index' -Status 'executed' -Detail "entries=$indexEntryCount drift=$indexDrift missing_record=$indexMissing"
        }
        catch {
            [void]$errors.Add("validation section 'index' aborted: $($_.Exception.Message)")
            Add-Coverage -Section 'index' -Status 'aborted' -Detail "entries=$indexEntryCount drift=$indexDrift missing_record=$indexMissing"
        }
    }

    if ($null -eq $knowledgeLock) {
        Add-Coverage -Section 'lock' -Status 'skipped' -Detail 'reason=knowledge.lock.json unreadable'
    }
    else {
        $lockRecordCount = 0
        $lockMissing = 0
        $lockMismatch = 0
        try {
            $actualByPath = @{}
            foreach ($actual in $actualEntries) { $actualByPath[$actual.path] = $actual.sha256 }
            $lockRecords = @(Get-OptionalArray -InputObject $knowledgeLock -Name 'records')
            $lockRecordCount = $lockRecords.Count
            foreach ($locked in $lockRecords) {
                $lockedPath = [string](Get-OptionalValue -InputObject $locked -Name 'path')
                if (-not $actualByPath.ContainsKey($lockedPath)) { [void]$errors.Add("knowledge lock references missing path: $lockedPath"); $lockMissing++ }
                elseif ($actualByPath[$lockedPath] -ne [string](Get-OptionalValue -InputObject $locked -Name 'sha256')) { [void]$errors.Add("knowledge lock hash mismatch: $lockedPath"); $lockMismatch++ }
            }
            if ($lockRecordCount -ne $actualEntries.Count) { [void]$errors.Add('knowledge lock record count differs from knowledge files') }
            Add-Coverage -Section 'lock' -Status 'executed' -Detail "records=$lockRecordCount missing_path=$lockMissing hash_mismatch=$lockMismatch"
        }
        catch {
            [void]$errors.Add("validation section 'lock' aborted: $($_.Exception.Message)")
            Add-Coverage -Section 'lock' -Status 'aborted' -Detail "records=$lockRecordCount missing_path=$lockMissing hash_mismatch=$lockMismatch"
        }
    }
}
catch {
    [void]$errors.Add("validation aborted outside any section: $($_.Exception.Message)")
}
finally {
    $reachedSections = @($coverage | ForEach-Object { $_.Section })
    foreach ($plannedSection in $plannedSections) {
        if ($reachedSections -notcontains $plannedSection) { Add-Coverage -Section $plannedSection -Status 'not_reached' }
    }

    if (@($actualEntries | Where-Object { $_.status -eq 'verified' }).Count -eq 0) {
        [void]$warnings.Add('no verified shared pattern exists yet; normal product analysis remains the only runtime path')
    }
    foreach ($warning in $warnings) { Write-Output "WARN: $warning" }
    foreach ($validationError in $errors) { Write-Output "ERROR: $validationError" }
    $executedSections = @($coverage | Where-Object { $_.Status -eq 'executed' }).Count
    $skippedSections = @($coverage | Where-Object { $_.Status -eq 'skipped' }).Count
    $abortedSections = @($coverage | Where-Object { $_.Status -eq 'aborted' }).Count
    $notReachedSections = @($coverage | Where-Object { $_.Status -eq 'not_reached' }).Count
    Write-Output "COVERAGE: sections=$($coverage.Count) executed=$executedSections skipped=$skippedSections aborted=$abortedSections not_reached=$notReachedSections"
    if ($errors.Count -gt 0) { Write-Output "RESULT: failed ($($errors.Count) error(s), $($warnings.Count) warning(s))"; exit 1 }
    if ($Strict -and $warnings.Count -gt 0) { Write-Output "RESULT: failed in strict mode (0 error(s), $($warnings.Count) warning(s))"; exit 1 }
    Write-Output "RESULT: passed (0 error(s), $($warnings.Count) warning(s))"
}
