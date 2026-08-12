#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,

    [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

$root = Resolve-CanonicalPath -Path (Resolve-Path -LiteralPath $ProductRoot).Path
$stateRoot = Join-Path $root 'product-state'
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

# Check-coverage accounting. A validator that dies half way through has not found nothing --
# it has simply never run the rest of its checks, and a bare "RESULT:" line cannot tell the
# two apart. The summary is emitted from the trap as well, so it survives the abort path.
$checkGroupsPlanned = @(
    'required-layout', 'state-file-integrity', 'journal-residue', 'state-identity',
    'core-artifact-integrity', 'lifecycle-gates', 'product-index', 'learning-scaffold', 'tool-inventory',
    'input-manifest', 'unregistered-root-inputs', 'baseline-manifest', 'migration-manifests', 'orphan-preserved-inputs',
    'release-manifests', 'product-id-sweep', 'status-gates', 'critical-contracts',
    'blocking-items', 'maintenance-strategy', 'placeholder-sweep', 'host-docs', 'credential-sweep'
)
$checkGroupsDone = New-Object System.Collections.Generic.List[string]
$currentCheckGroup = ''
$coverageEmitted = $false
$verifiedStatuses = @('VERIFIED', 'VERIFIED_SIMULATION', 'RELEASED')

function Enter-CheckGroup {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)

    if (-not [string]::IsNullOrEmpty($script:currentCheckGroup)) {
        [void]$script:checkGroupsDone.Add($script:currentCheckGroup)
    }
    $script:currentCheckGroup = $Name
}

function Write-CoverageSummary {
    param([string]$AbortedIn = '')

    if ($script:coverageEmitted) { return }
    $script:coverageEmitted = $true
    $done = $script:checkGroupsDone.Count
    $total = $script:checkGroupsPlanned.Count
    $notRun = $total - $done
    $where = if ([string]::IsNullOrEmpty($AbortedIn)) { 'none' } else { $AbortedIn }
    Write-Output "COVERAGE: $done/$total check group(s) completed, $notRun not run, aborted in: $where"
}

function Read-StateText {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Thin alias over the shared reader. A truncated file is reported by the state-file-integrity
    # group, not by crashing whichever regex happens to read it first.
    return Read-TextFileSafe -Path $Path
}

function Get-JsonProperty {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)

    # StrictMode turns a missing property into a terminating error, and a journal written by an
    # older writer is exactly where a missing property shows up.
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Resolve-ProductRelativePath {
    param([Parameter(Mandatory = $true)][string]$Relative)

    # A recorded path is a claim about this product's own files. Unchecked, a leading "../" walks
    # the hash comparison right out of the product: the bytes still verify, they just are not the
    # product's bytes. An absolute path escapes the same way, which is why Combine is used here --
    # it returns the rooted path unchanged, and the containment test below then rejects it.
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($script:root, $Relative.Replace('/', '\')))
    $prefix = $script:root.TrimEnd('\') + '\'
    return [pscustomobject]@{
        FullPath = $full
        Inside   = $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    }
}

function Test-RegisteredInputHash {
    param([Parameter(Mandatory = $true)][string]$Hash)

    $manifests = New-Object System.Collections.Generic.List[string]
    $inputManifest = Join-Path $script:stateRoot 'artifacts/INPUT-MANIFEST.yaml'
    if (Test-Path -LiteralPath $inputManifest -PathType Leaf) { [void]$manifests.Add($inputManifest) }
    $migrationRoot = Join-Path $script:stateRoot 'migrations'
    if (Test-Path -LiteralPath $migrationRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $migrationRoot -File -Filter '*-INPUT-MANIFEST.yaml')) {
            [void]$manifests.Add($file.FullName)
        }
    }
    foreach ($manifest in $manifests) {
        if ((Read-StateText -Path $manifest) -match ('(?i)sha256:\s*["'']?' + [regex]::Escape($Hash))) {
            return $true
        }
    }
    return $false
}

trap {
    $abortedIn = $script:currentCheckGroup
    if ([string]::IsNullOrEmpty($abortedIn)) { $abortedIn = '(before first check group)' }
    foreach ($warning in $script:warnings) { Write-Output "WARN: $warning" }
    foreach ($validationError in $script:errors) { Write-Output "ERROR: $validationError" }
    Write-Output "ERROR: validation aborted in check group '$abortedIn': $($_.Exception.Message)"
    Write-CoverageSummary -AbortedIn $abortedIn
    Write-Output "RESULT: failed (aborted in $abortedIn; $($script:errors.Count) error(s) before abort, $($script:warnings.Count) warning(s))"
    exit 1
}

$requiredFiles = @(
    'PRODUCT-INDEX.md',
    'STATE.yaml',
    'PRODUCT-DOSSIER.md',
    'PROTECTION-PROFILE.yaml',
    'CUSTOMIZATION-MANIFEST.yaml',
    'MAINTENANCE-MODE.yaml',
    'OPERATION-MANIFEST.yaml',
    'EVIDENCE-LEDGER.yaml',
    'NETWORK-DATA-POLICY.yaml',
    'HOST-INTEGRATION-MANIFEST.yaml',
    'INPUT-SAFETY-POLICY.yaml',
    'UPSTREAM-VERSIONS.yaml',
    'MIGRATION-RUNBOOK.md',
    'TEST-MATRIX.md',
    'auth/AUTH-DISCOVERY.md',
    'auth/AUTH-PROFILE.yaml',
    'auth/AUTH-EVIDENCE-INDEX.yaml',
    'auth/AUTH-OPEN-QUESTIONS.md',
    'auth/AUTH-ADAPTER-REQUEST.md',
    'auth/LAUNCH-CONTRACT.yaml',
    'release/UPDATE-PROFILE.yaml',
    'release/RELEASE-MANIFEST.yaml',
    'release/COMPONENT-RELEASE-MANIFEST.yaml',
    'release/RELEASE-PUBLISH-REQUEST.md',
    'reports/CHANGES-AND-DIFF.md',
    'reports/VERIFICATION-RECORD.md',
    'rollback/ROLLBACK-RUNBOOK.md',
    'tooling/TOOL-PLAN.yaml'
)
$requiredDirs = @(
    'analysis', 'auth', 'release', 'migrations', 'reports', 'rollback', 'artifacts', 'tooling',
    'artifacts/upstream', 'artifacts/maintained', 'artifacts/patches',
    'artifacts/verification', 'artifacts/rollback', 'artifacts/incoming',
    'artifacts/quarantine', 'artifacts/reference-docs'
)

Enter-CheckGroup 'required-layout'
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    $errors.Add('product-state directory is missing')
}
else {
    foreach ($relative in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $stateRoot $relative) -PathType Leaf)) {
            $errors.Add("required file is missing: $relative")
        }
    }
    foreach ($relative in $requiredDirs) {
        if (-not (Test-Path -LiteralPath (Join-Path $stateRoot $relative) -PathType Container)) {
            $errors.Add("required directory is missing: $relative")
        }
    }
}

# A zero-byte YAML is the classic residue of a write that was killed mid-flight. This scan has
# to stay ahead of every read below: the crash such a file causes would otherwise stop the very
# check that is meant to report it.
Enter-CheckGroup 'state-file-integrity'
if (Test-Path -LiteralPath $stateRoot -PathType Container) {
    foreach ($stateFile in @(Get-ChildItem -LiteralPath $stateRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yaml', '.yml', '.json') })) {
        if ($stateFile.Length -eq 0) {
            $errors.Add("product state file is empty, which means a write was interrupted: $($stateFile.FullName.Substring($stateRoot.Length + 1))")
        }
    }
}

# Deliberately ahead of every other read: the residue this reports is a transition that was
# killed mid-flight, and that same residue is what crashes the checks further down. A detector
# its own target can stop from running is not a detector.
# Read-only by design: this reports what replay would do, it never deletes a journal or a .tmp.
# Deleting belongs to update-product-state.ps1 -- a read-only validator that grows a write path
# can no longer be run safely against a live repository.
Enter-CheckGroup 'journal-residue'
$journalPath = Join-Path $stateRoot '.state-journal.json'
$journalRelative = 'product-state/.state-journal.json'
if (Test-Path -LiteralPath $stateRoot -PathType Container) {
    $residue = @(Get-ChildItem -LiteralPath $stateRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.tmp', '.bak') } |
            ForEach-Object { ($_.FullName.Substring($stateRoot.Length + 1)) -replace '\\', '/' })
    if ($residue.Count -gt 0) {
        $warnings.Add("stale atomic-write residue: $($residue -join ', '); git cannot see these files, so they have to be cleaned up by hand")
    }
}
if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
    $journal = $null
    try { $journal = Read-StateText -Path $journalPath | ConvertFrom-Json }
    catch { $journal = $null }
    $journalSchema = Get-JsonProperty -Object $journal -Name 'schema_version'
    if ($null -eq $journal) {
        $errors.Add("state journal is unreadable: $journalRelative is not valid JSON")
    }
    elseif ([string]$journalSchema -ne '1') {
        $errors.Add("state journal is unreadable: $journalRelative has schema_version '$journalSchema', expected 1")
    }
    else {
        $journalId = [string](Get-JsonProperty -Object $journal -Name 'journal_id')
        $journalProduct = [string](Get-JsonProperty -Object $journal -Name 'product_id')
        $transition = Get-JsonProperty -Object $journal -Name 'transition'
        $fromStatus = [string](Get-JsonProperty -Object $transition -Name 'from_status')
        $toStatus = [string](Get-JsonProperty -Object $transition -Name 'to_status')
        $journalStateId = Get-YamlScalar -Text (Read-StateText -Path (Join-Path $stateRoot 'STATE.yaml')) -Key 'product_id'
        if (-not [string]::IsNullOrWhiteSpace($journalProduct) -and -not [string]::IsNullOrWhiteSpace($journalStateId) -and $journalProduct -ne $journalStateId) {
            $errors.Add("state journal belongs to another product ($journalProduct vs $journalStateId); journal=$journalRelative")
        }
        else {
            $committed = New-Object System.Collections.Generic.List[string]
            $pending = New-Object System.Collections.Generic.List[string]
            $conflicting = New-Object System.Collections.Generic.List[string]
            foreach ($target in @(Get-JsonProperty -Object $journal -Name 'targets')) {
                $targetPath = [string](Get-JsonProperty -Object $target -Name 'path')
                if ([string]::IsNullOrWhiteSpace($targetPath)) { continue }
                $before = [string](Get-JsonProperty -Object $target -Name 'sha256_before')
                $intended = [string](Get-JsonProperty -Object $target -Name 'sha256_intended')
                $targetResolved = Resolve-ProductRelativePath -Relative $targetPath
                $actual = ''
                if ($targetResolved.Inside -and (Test-Path -LiteralPath $targetResolved.FullPath -PathType Leaf)) {
                    $actual = (Get-FileHash -LiteralPath $targetResolved.FullPath -Algorithm SHA256).Hash.ToUpperInvariant()
                }
                if (-not [string]::IsNullOrWhiteSpace($intended) -and $actual -eq $intended.ToUpperInvariant()) { [void]$committed.Add($targetPath) }
                elseif ($actual -eq [string]$before.ToUpperInvariant()) { [void]$pending.Add($targetPath) }
                else { [void]$conflicting.Add($targetPath) }
            }
            $pendingText = if ($pending.Count -gt 0) { $pending -join ', ' } else { '(none)' }
            $context = "journal=$journalRelative, transition=$fromStatus -> $toStatus, pending=$pendingText"
            if ($conflicting.Count -gt 0) {
                $errors.Add("state journal $journalId conflicts with on-disk content: $($conflicting -join ', ') was modified outside the transition, so automatic replay is refused; $context")
            }
            elseif ($committed.Count -gt 0 -and $pending.Count -gt 0) {
                $errors.Add("state journal $journalId is partially applied (split brain): committed=$($committed -join ', '), pending=$pendingText; $context")
            }
            elseif ($pending.Count -eq 0) {
                $warnings.Add("state journal $journalId is complete but was not cleared; every target already matches the intended content, so this journal can be safely deleted by update-product-state.ps1; $context")
            }
            else {
                $warnings.Add("state journal $journalId has no committed target; the transition $fromStatus -> $toStatus never started; $context")
            }
        }
    }
}

Enter-CheckGroup 'state-identity'
$statePath = Join-Path $stateRoot 'STATE.yaml'
$stateText = ''
$stateProductId = ''
$stateStatus = ''
$stateSimulationOnly = $false
$stateBaselineHash = ''
$stateCoreName = ''
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $stateText = Read-StateText -Path $statePath
    if ($stateText -match '__[A-Z0-9_]+__') {
        $errors.Add('STATE.yaml still contains scaffold placeholders')
    }
    $stateProductId = Get-YamlScalar -Text $stateText -Key 'product_id'
    if ([string]::IsNullOrWhiteSpace($stateProductId)) {
        # Without an identity there is nothing for the index, the auth profile or the learning
        # exports to be consistent with, so all three cross-file checks would pass vacuously.
        $errors.Add('STATE.yaml has no product_id; every cross-file identity check depends on it')
        $stateProductId = ''
    }
    $stateStatus = Get-YamlScalar -Text $stateText -Key 'status'
    $stateSimulationOnly = (Get-YamlScalar -Text $stateText -Key 'simulation_only') -match '^(?i)true$'
    $coreMatch = [regex]::Match($stateText, '(?m)^core_path:\s*["'']?([^"''\r\n]+?)["'']?\s*$')
    if ($coreMatch.Success) {
        $stateCoreName = $coreMatch.Groups[1].Value
    }
    $allowedStatuses = @('INIT', 'BASELINE_CREATED', 'ANALYZED', 'CUSTOMIZATION_RECORDED', 'AUTH_HANDOFF_READY', 'AUTH_CONTRACT_READY', 'BUILD_READY', 'VERIFIED_SIMULATION', 'VERIFIED', 'RELEASED', 'MIGRATION_REQUIRED', 'ROLLBACK_READY')
    if ($allowedStatuses -notcontains $stateStatus) {
        $errors.Add('STATE.yaml has no recognized status')
    }
    if ($stateSimulationOnly -and $stateStatus -in @('VERIFIED', 'RELEASED')) {
        $errors.Add('simulation_only product cannot use real VERIFIED or RELEASED status; use VERIFIED_SIMULATION')
    }
    if (-not $stateSimulationOnly -and $stateStatus -eq 'VERIFIED_SIMULATION') {
        $errors.Add('VERIFIED_SIMULATION requires simulation_only: true')
    }
    $hashMatch = [regex]::Match($stateText, '(?m)^baseline_sha256:\s*["'']?([0-9A-Fa-f]{64})["'']?\s*$')
    if (-not $hashMatch.Success) {
        $errors.Add('STATE.yaml baseline_sha256 is missing or invalid')
    }
    else {
        $stateBaselineHash = $hashMatch.Groups[1].Value.ToUpperInvariant()
        $baselineArtifact = Get-YamlScalar -Text $stateText -Key 'baseline_artifact'
        if ([string]::IsNullOrWhiteSpace($baselineArtifact)) {
            $errors.Add('STATE.yaml baseline_artifact is missing')
        }
        else {
            $baselineResolved = Resolve-ProductRelativePath -Relative $baselineArtifact
            $artifactPath = $baselineResolved.FullPath
            if (-not $baselineResolved.Inside) {
                $errors.Add("STATE.yaml baseline_artifact points outside the product directory: $baselineArtifact")
            }
            elseif (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                $errors.Add("baseline artifact is missing: $baselineArtifact")
            }
            else {
                $actual = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($actual -ne $hashMatch.Groups[1].Value.ToUpperInvariant()) {
                    $errors.Add("baseline hash mismatch: expected $($hashMatch.Groups[1].Value), actual $actual")
                }
            }
        }
    }
}

# `core_path` was a field that existed but was verified by nobody: only the preserved copy under
# artifacts/upstream was hashed, so swapping the live executable at the product root still
# reported "passed". A field the downstream trusts and no one checks is worse than a missing one.
Enter-CheckGroup 'core-artifact-integrity'
if (-not [string]::IsNullOrWhiteSpace($stateCoreName) -and -not [string]::IsNullOrWhiteSpace($stateBaselineHash)) {
    $coreAbsolute = if ([IO.Path]::IsPathRooted($stateCoreName)) { $stateCoreName } else { Join-Path $root ($stateCoreName.Replace('/', '\')) }
    if (-not (Test-Path -LiteralPath $coreAbsolute -PathType Leaf)) {
        # core_path holds a bare file name, so a product whose executable was handed over from
        # outside the product directory legitimately has nothing sitting at the product root.
        $warnings.Add("core artifact recorded in STATE.yaml is not present at the product root: $stateCoreName")
    }
    else {
        $coreActual = (Get-FileHash -LiteralPath $coreAbsolute -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($coreActual -ne $stateBaselineHash) {
            if (Test-RegisteredInputHash -Hash $coreActual) {
                # Dropping a new build at the product root is still a legitimate hand-over path, so
                # a replacement that has been registered as an input bundle stays non-fatal until a
                # verified state is claimed for it.
                $message = "core artifact differs from the recorded baseline: $stateCoreName; expected $stateBaselineHash, actual $coreActual. It is registered as an input but has not been consumed yet"
                if ($stateStatus -in $verifiedStatuses) { $errors.Add($message) } else { $warnings.Add($message) }
            }
            else {
                $errors.Add("core artifact does not match the recorded baseline and is not registered as an input: $stateCoreName; expected $stateBaselineHash, actual $coreActual. Register the replacement with register-input-bundle.ps1 instead of overwriting the file in place")
            }
        }
    }
}

# Every gate that existed before this one asked "having claimed you are finished, is anything
# left over" -- which never stopped a product from claiming a rung it had not climbed. A brand-new
# scaffold could be edited from INIT to BUILD_READY and the validator reported zero errors, so the
# one status that means "start building" required no evidence at all. The ladder is cumulative:
# claiming a status claims every status below it.
Enter-CheckGroup 'lifecycle-gates'
$lifecycleReadiness = $null
if (-not [string]::IsNullOrWhiteSpace($stateStatus) -and (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    $lifecycleReadiness = Get-LifecycleReadiness -StateRoot $stateRoot -Status $stateStatus
    foreach ($item in $lifecycleReadiness.Unmet) {
        $errors.Add("status $stateStatus is not backed by the evidence $($item.RequiredBy) requires: $($item.Why) [$($item.Detail)]")
    }
}

Enter-CheckGroup 'product-index'
$indexPath = Join-Path $stateRoot 'PRODUCT-INDEX.md'
if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
    $indexText = Read-StateText -Path $indexPath
    if ($indexText -match '__[A-Z0-9_]+__') {
        $errors.Add('PRODUCT-INDEX.md still contains scaffold placeholders')
    }
    $indexProductMatch = [regex]::Match($indexText, '(?m)^- `product_id`:\s*`([^`]+)`')
    if ($indexProductMatch.Success -and -not [string]::IsNullOrWhiteSpace($stateProductId) -and $indexProductMatch.Groups[1].Value -ne $stateProductId) {
        $errors.Add('PRODUCT-INDEX.md product_id does not match STATE.yaml')
    }
    $indexStatusMatch = [regex]::Match($indexText, '(?m)^- 当前状态:\s*`([^`]+)`')
    if ($indexStatusMatch.Success -and -not [string]::IsNullOrWhiteSpace($stateStatus) -and $indexStatusMatch.Groups[1].Value -ne $stateStatus) {
        $errors.Add('PRODUCT-INDEX.md current status does not match STATE.yaml')
    }
    # `mode` was the third copy of the truth and the only one nobody compared, so a product could
    # sit in the index as `bootstrap` forever while STATE.yaml had long since moved to `update`.
    $stateMode = Get-YamlScalar -Text $stateText -Key 'mode'
    $indexModeMatch = [regex]::Match($indexText, '(?m)^- 当前模式:\s*`([^`]+)`')
    if ($indexModeMatch.Success -and -not [string]::IsNullOrWhiteSpace($stateMode) -and $indexModeMatch.Groups[1].Value -ne $stateMode) {
        $errors.Add("PRODUCT-INDEX.md current mode does not match STATE.yaml: $($indexModeMatch.Groups[1].Value) vs $stateMode")
    }
    $allowedModes = @('bootstrap', 'update', 'status', 'resume', 'release', 'rollback')
    if (-not [string]::IsNullOrWhiteSpace($stateMode) -and $allowedModes -notcontains $stateMode) {
        $errors.Add("STATE.yaml mode is not one of $($allowedModes -join '/'): $stateMode")
    }
}

Enter-CheckGroup 'learning-scaffold'
$learningFiles = @('learning/CANDIDATE-DRAFT.json', 'learning/EXPERIENCE-EXPORTS.json', 'learning/SHARING-REVIEW.md')
$missingLearning = @($learningFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $stateRoot $_) -PathType Leaf) })
if ($missingLearning.Count -gt 0) {
    $warnings.Add('product predates the reusable-learning scaffold; rerun init-product.ps1 with the same product_id and baseline to add it without overwriting product facts')
}
else {
    try {
        $exportMap = Read-StateText -Path (Join-Path $stateRoot 'learning/EXPERIENCE-EXPORTS.json') | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace($stateProductId) -and [string]$exportMap.product_id -ne $stateProductId) {
            $errors.Add('learning/EXPERIENCE-EXPORTS.json product_id does not match STATE.yaml')
        }
    }
    catch { $errors.Add('learning/EXPERIENCE-EXPORTS.json is invalid JSON') }
}

function Get-ManifestFieldValue {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $match = [regex]::Match($Line, ('^\s+{0}:\s*(.*?)\s*$' -f [regex]::Escape($Key)))
    if (-not $match.Success) { return $null }
    $value = $match.Groups[1].Value
    if ($value.StartsWith('#')) { return $null }
    $value = ($value -replace '\s+#.*$', '').Trim()
    if ($value.Length -ge 2) {
        $first = $value.Substring(0, 1)
        $last = $value.Substring($value.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Get-ManifestRecords {
    param([Parameter(Mandatory = $true)][string]$Text)

    # Record boundaries used to be keyed off three specific field names, so a manifest that wrote
    # any other field first -- "- path:" being the common one -- yielded zero records, and zero
    # records then skipped every hash comparison. Any list item now opens a record, and the field
    # patterns no longer depend on which key happens to be written first.
    $records = New-Object System.Collections.Generic.List[object]
    $current = $null
    $recordIndent = -1
    $nestedIndent = -1
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $indent = [regex]::Match($line, '^(\s*)').Groups[1].Value.Length
        if ($nestedIndent -ge 0) {
            if ($indent -gt $nestedIndent) { continue }
            $nestedIndent = -1
        }
        if ($line -match '^\s*-\s+\S') {
            if ($recordIndent -lt 0 -or $indent -lt $recordIndent) { $recordIndent = $indent }
            if ($indent -gt $recordIndent) {
                # A list nested inside a record never opens a sibling record, and its own fields
                # must not leak into the parent record either.
                $nestedIndent = $indent
                continue
            }
            if ($null -ne $current) {
                [void]$records.Add([pscustomobject]$current)
            }
            $current = @{}
        }
        if ($null -eq $current) {
            continue
        }
        # A record's opening line carries "- key: value"; dropping the dash lets the field lookups
        # below treat it exactly like any other field line.
        $normalized = $line -replace '^(\s*)-\s+', '$1  '
        $preserved = Get-ManifestFieldValue -Line $normalized -Key 'preserved_path'
        if ($null -ne $preserved) { $current.preserved_path = $preserved; continue }
        $recordPath = Get-ManifestFieldValue -Line $normalized -Key 'path'
        if ($null -ne $recordPath) { $current.path = $recordPath; continue }
        $recordHash = Get-ManifestFieldValue -Line $normalized -Key 'sha256'
        if ($null -ne $recordHash) {
            if ($recordHash -match '^[0-9A-Fa-f]{64}$') { $current.sha256 = $recordHash.ToUpperInvariant() }
            else { $current.sha256 = $recordHash }
            continue
        }
        $recordSize = Get-ManifestFieldValue -Line $normalized -Key 'size'
        if ($null -ne $recordSize -and $recordSize -match '^[0-9]+$') { $current.size = [int64]$recordSize }
    }
    if ($null -ne $current) {
        [void]$records.Add([pscustomobject]$current)
    }
    foreach ($record in $records) {
        # A bare scalar list item ("- some/path") parses into nothing. Emitting it would make an
        # unreadable manifest look like a readable one that merely holds empty records.
        if (@($record.PSObject.Properties).Count -gt 0) {
            Write-Output $record
        }
    }
}

function Get-ManifestListItemCount {
    param([Parameter(Mandatory = $true)][string]$Text)

    # How many file records the manifest claims to hold, counted without the record parser, so
    # "the parser understood nothing" can be told apart from "there was nothing to understand".
    $recordKeys = @('artifacts', 'components', 'inputs', 'files', 'records', 'entries')
    $count = 0
    $inList = $false
    $listIndent = -1
    foreach ($line in ($Text -split "`r?`n")) {
        $blockKey = [regex]::Match($line, '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*$')
        if ($blockKey.Success) {
            $inList = $recordKeys -contains $blockKey.Groups[1].Value
            $listIndent = -1
            continue
        }
        if ($line -match '^[A-Za-z_][A-Za-z0-9_]*\s*:') {
            $inList = $false
            continue
        }
        if (-not $inList) { continue }
        $item = [regex]::Match($line, '^(\s*)-\s+\S')
        if (-not $item.Success) { continue }
        $indent = $item.Groups[1].Value.Length
        if ($listIndent -lt 0) { $listIndent = $indent }
        if ($indent -eq $listIndent) { $count++ }
    }
    return $count
}

function Get-MatrixFailRows {
    param([Parameter(Mandatory = $true)][string]$Text)

    # Judged cell by cell rather than by searching the page for "FAIL", so that a column header
    # reading "PASS/FAIL" or a scenario description cannot masquerade as a failing row.
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '^\s*\|') { continue }
        $cells = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim().Trim('`').Trim() })
        if ($cells.Count -lt 2) { continue }
        foreach ($cell in $cells) {
            if ($cell -match '^(?i)FAIL(ED|URE)?$' -or $cell -match '^(?i)FAIL[_\- ]') {
                $label = $cells[0]
                if ([string]::IsNullOrWhiteSpace($label)) { $label = $line.Trim() }
                [void]$rows.Add($label)
                break
            }
        }
    }
    return $rows
}

function Get-MatrixPassRows {
    param([Parameter(Mandatory = $true)][string]$Text)

    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '^\s*\|') { continue }
        $cells = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim().Trim('`').Trim() })
        if ($cells.Count -lt 2) { continue }
        foreach ($cell in $cells) {
            if ($cell -match '^(?i)(PASS|PASSED|PASS_SIMULATION)$') {
                [void]$rows.Add($cells[0])
                break
            }
        }
    }
    return $rows
}

function Get-YamlListItems {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $items = New-Object System.Collections.Generic.List[string]
    $lines = @($Text -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $keyMatch = [regex]::Match($lines[$i], ('^(\s*){0}\s*:\s*(.*?)\s*$' -f [regex]::Escape($Key)))
        if (-not $keyMatch.Success) { continue }
        $inline = $keyMatch.Groups[2].Value
        $inlineList = [regex]::Match($inline, '^\[(.*)\]$')
        if ($inlineList.Success) {
            foreach ($piece in ($inlineList.Groups[1].Value -split ',')) {
                $entry = $piece.Trim().Trim('"').Trim("'").Trim()
                if (-not [string]::IsNullOrWhiteSpace($entry)) { [void]$items.Add($entry) }
            }
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($inline)) { continue }
        $keyIndent = $keyMatch.Groups[1].Value.Length
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ([string]::IsNullOrWhiteSpace($lines[$j])) { continue }
            $itemMatch = [regex]::Match($lines[$j], '^(\s*)-\s*(.*?)\s*$')
            if (-not $itemMatch.Success -or $itemMatch.Groups[1].Value.Length -le $keyIndent) { break }
            $entry = $itemMatch.Groups[2].Value.Trim().Trim('"').Trim("'").Trim()
            if (-not [string]::IsNullOrWhiteSpace($entry)) { [void]$items.Add($entry) }
        }
    }
    return $items
}

function Test-ManifestFileHashes {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$PathProperty
    )

    if ($Records.Count -eq 0) {
        $errors.Add("manifest has no file records: $ManifestPath")
        return
    }
    foreach ($record in $Records) {
        $relative = [string]$record.$PathProperty
        $expectedHash = [string]$record.sha256
        if ([string]::IsNullOrWhiteSpace($relative) -or [string]::IsNullOrWhiteSpace($expectedHash)) {
            $errors.Add("manifest record is missing path or sha256: $ManifestPath")
            continue
        }
        if ($expectedHash -notmatch '^[0-9A-Fa-f]{64}$') {
            $errors.Add("manifest sha256 is invalid: $ManifestPath -> $relative")
            continue
        }
        $resolved = Resolve-ProductRelativePath -Relative $relative
        if (-not $resolved.Inside) {
            $errors.Add("manifest record points outside the product directory: $relative")
            continue
        }
        $absolute = $resolved.FullPath
        if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
            $errors.Add("manifest file is missing: $relative")
            continue
        }
        $actualHash = (Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
            $errors.Add("manifest hash mismatch: $relative; expected $expectedHash, actual $actualHash")
        }
        if ($record.PSObject.Properties.Name -contains 'size') {
            $actualSize = (Get-Item -LiteralPath $absolute).Length
            if ([int64]$record.size -ne [int64]$actualSize) {
                $errors.Add("manifest size mismatch: $relative; expected $($record.size), actual $actualSize")
            }
        }
    }
}

Enter-CheckGroup 'tool-inventory'
$inventoryPath = Join-Path $stateRoot 'tooling/TOOL-INVENTORY.md'
if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
    $warnings.Add('tool inventory is not generated yet; run discover-tools.ps1 before analysis')
}

Enter-CheckGroup 'input-manifest'
$inputManifestPath = Join-Path $stateRoot 'artifacts/INPUT-MANIFEST.yaml'
if (-not (Test-Path -LiteralPath $inputManifestPath -PathType Leaf)) {
    if ($stateStatus -in $verifiedStatuses) {
        # Deleting the manifest used to be the cheapest way past this file's hash checks: with no
        # records there is nothing to compare, and the missing manifest was only a warning.
        $errors.Add('input manifest is missing while product state is verified; the preserved inputs are then under no hash constraint at all')
    }
    else {
        $warnings.Add('input manifest is not generated yet; preserve and register all supplied files before analysis')
    }
}
else {
    $inputManifestText = Read-StateText -Path $inputManifestPath
    if ($inputManifestText -match '__[A-Z0-9_]+__') {
        $errors.Add('INPUT-MANIFEST.yaml still contains scaffold placeholders')
    }
    $inputRecords = Get-ManifestRecords -Text $inputManifestText | Where-Object {
        $_.PSObject.Properties.Name -contains 'preserved_path'
    }
    Test-ManifestFileHashes -ManifestPath $inputManifestPath -Records @($inputRecords) -PathProperty 'preserved_path'
}

# Overwriting the core executable in place was already caught; dropping the new version next to it
# under a new name was not. That is the more natural of the two actions -- the user copies
# "app-v2.exe" into the product folder and says "update this" -- and the whole intake was blind to
# it: incoming/ stayed empty, so mode selection saw nothing to do and the validator said passed.
Enter-CheckGroup 'unregistered-root-inputs'
if (Test-Path -LiteralPath $stateRoot -PathType Container) {
    $hostInstructionNames = @('AGENTS.md', 'CLAUDE.md', 'GEMINI.md', 'RULES.md', 'RULES_zh.md')
    $unregistered = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)) {
        if ($hostInstructionNames -contains $candidate.Name) { continue }
        $candidateHash = (Get-FileHash -LiteralPath $candidate.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($candidateHash -eq $stateBaselineHash) { continue }
        if (Test-RegisteredInputHash -Hash $candidateHash) { continue }
        [void]$unregistered.Add($candidate.Name)
    }
    if ($unregistered.Count -gt 0) {
        $message = "产品文件夹里有还没有登记的文件: $($unregistered -join ', ')。把它们放进 incoming/ 并运行 register-input-bundle.ps1 登记成新版本输入，或者作为补充材料登记；在登记之前不要把它们当成当前版本"
        if ($stateStatus -in $verifiedStatuses) { $errors.Add($message) } else { $warnings.Add($message) }
    }
}

Enter-CheckGroup 'baseline-manifest'
$baselineManifestPath = Join-Path $stateRoot 'artifacts/BASELINE-MANIFEST.yaml'
if (Test-Path -LiteralPath $baselineManifestPath -PathType Leaf) {
    $baselineText = Read-StateText -Path $baselineManifestPath
    $baselinePathMatch = [regex]::Match($baselineText, '(?m)^artifact_path:\s*["'']([^"'']+)["'']')
    $baselineHashMatch = [regex]::Match($baselineText, '(?m)^sha256:\s*["'']([0-9A-Fa-f]{64})["'']')
    if (-not $baselinePathMatch.Success -or -not $baselineHashMatch.Success) {
        $errors.Add("baseline manifest is missing artifact_path or sha256: $baselineManifestPath")
    }
    else {
        $baselinePath = $baselinePathMatch.Groups[1].Value
        $baselineManifestResolved = Resolve-ProductRelativePath -Relative $baselinePath
        $baselineAbsolute = $baselineManifestResolved.FullPath
        if (-not $baselineManifestResolved.Inside) {
            $errors.Add("baseline manifest artifact_path points outside the product directory: $baselinePath")
        }
        elseif (-not (Test-Path -LiteralPath $baselineAbsolute -PathType Leaf)) {
            $errors.Add("baseline manifest artifact is missing: $baselinePath")
        }
        else {
            $baselineActual = (Get-FileHash -LiteralPath $baselineAbsolute -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($baselineActual -ne $baselineHashMatch.Groups[1].Value.ToUpperInvariant()) {
                $errors.Add("baseline manifest hash mismatch: $baselinePath; expected $($baselineHashMatch.Groups[1].Value), actual $baselineActual")
            }
        }
    }
}

Enter-CheckGroup 'migration-manifests'
$migrationDir = Join-Path $stateRoot 'migrations'
if (Test-Path -LiteralPath $migrationDir -PathType Container) {
    # Recursive: a manifest one directory down used to be enumerated by nobody, so filing it
    # under migrations/2026-08/ was enough to exempt it from every check below.
    foreach ($migrationManifest in @(Get-ChildItem -LiteralPath $migrationDir -File -Filter '*-INPUT-MANIFEST.yaml' -Recurse)) {
        $migrationText = Read-StateText -Path $migrationManifest.FullName
        $migrationProductId = Get-YamlScalar -Text $migrationText -Key 'product_id'
        if ([string]::IsNullOrWhiteSpace($migrationProductId) -or $migrationProductId -ne $stateProductId) {
            $errors.Add("migration manifest product_id is missing or mismatched: $($migrationManifest.FullName)")
        }
        $migrationRecords = Get-ManifestRecords -Text $migrationText | Where-Object {
            $_.PSObject.Properties.Name -contains 'preserved_path'
        }
        $inputCountMatch = [regex]::Match($migrationText, '(?m)^input_count:\s*([0-9]+)\s*$')
        if (-not $inputCountMatch.Success -or [int]$inputCountMatch.Groups[1].Value -ne @($migrationRecords).Count) {
            $errors.Add("migration manifest input_count is missing or incorrect: $($migrationManifest.FullName)")
        }
        Test-ManifestFileHashes -ManifestPath $migrationManifest.FullName -Records @($migrationRecords) -PathProperty 'preserved_path'
    }
}

# The mirror image of the manifest hash checks. Those ask "is every recorded file still there";
# this asks "is every preserved file recorded". The two do not overlap: a tampered file is in the
# manifest and this check cannot see it, while a file left behind by a concurrent registration is
# in no manifest at all and the hash checks cannot see that. An unrecorded input is worse than a
# missing one, because an idempotent rescan will never match it again and will keep re-importing.
Enter-CheckGroup 'orphan-preserved-inputs'
$incomingRoot = Join-Path $stateRoot 'artifacts\incoming'
if (Test-Path -LiteralPath $incomingRoot -PathType Container) {
    $recordedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $inputManifests = New-Object System.Collections.Generic.List[string]
    $rootInputManifest = Join-Path $stateRoot 'artifacts\INPUT-MANIFEST.yaml'
    if (Test-Path -LiteralPath $rootInputManifest -PathType Leaf) { [void]$inputManifests.Add($rootInputManifest) }
    $migrationsRoot = Join-Path $stateRoot 'migrations'
    if (Test-Path -LiteralPath $migrationsRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $migrationsRoot -File -Filter '*.yaml' -Recurse)) { [void]$inputManifests.Add($file.FullName) }
    }
    foreach ($manifest in $inputManifests) {
        foreach ($record in @(Get-ManifestRecords -Text (Read-StateText -Path $manifest))) {
            foreach ($key in @('preserved_path', 'path')) {
                if ($record.PSObject.Properties.Name -contains $key) {
                    [void]$recordedPaths.Add(([string]$record.$key).Replace('/', '\').TrimStart('\'))
                }
            }
        }
    }
    $orphans = @(Get-ChildItem -LiteralPath $incomingRoot -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName.Substring($root.Length + 1) } |
            Where-Object { -not $recordedPaths.Contains($_) } |
            ForEach-Object { $_ -replace '\\', '/' })
    if ($orphans.Count -gt 0) {
        $orphanMessage = "preserved input files that no manifest records: $($orphans -join ', '); an unrecorded input is never matched again by an idempotent rescan, so the same file keeps being imported as new"
        # Warning outside the verified states, matching the shape already used for products that
        # predate the learning scaffold: an existing product carrying old orphans is not a reason
        # to turn it red, but claiming a verified state over unrecorded inputs is.
        if ($stateStatus -in $verifiedStatuses) { $errors.Add($orphanMessage) } else { $warnings.Add($orphanMessage) }
    }
}

Enter-CheckGroup 'release-manifests'
$releaseDir = Join-Path $stateRoot 'release'
if (Test-Path -LiteralPath $releaseDir -PathType Container) {
    foreach ($releaseManifest in @(Get-ChildItem -LiteralPath $releaseDir -File -Filter '*.yaml' | Where-Object { $_.Name -match '^(RELEASE-MANIFEST|COMPONENT-RELEASE-MANIFEST)' })) {
        $releaseText = Read-StateText -Path $releaseManifest.FullName
        $releaseAllRecords = @(Get-ManifestRecords -Text $releaseText)
        $releaseRecords = @($releaseAllRecords | Where-Object {
            $_.PSObject.Properties.Name -contains 'path'
        })
        if ($releaseRecords.Count -gt 0) {
            Test-ManifestFileHashes -ManifestPath $releaseManifest.FullName -Records $releaseRecords -PathProperty 'path'
        }
        elseif ($releaseAllRecords.Count -eq 0 -and (Get-ManifestListItemCount -Text $releaseText) -gt 0) {
            # The old guard skipped the whole section whenever nothing parsed, which is exactly
            # what an unreadable manifest looks like. Unreadable now fails instead of passing.
            $errors.Add("manifest records could not be parsed: $($releaseManifest.FullName)")
        }
    }
}

Enter-CheckGroup 'product-id-sweep'
if (-not [string]::IsNullOrWhiteSpace($stateProductId)) {
    # -Include is silently ignored next to -LiteralPath, so this used to read every file under
    # product-state, executables included, and hand each one to a regex.
    foreach ($yamlFile in @(Get-ChildItem -LiteralPath $stateRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yaml', '.yml') })) {
        $yamlProduct = Get-YamlScalar -Text (Read-StateText -Path $yamlFile.FullName) -Key 'product_id'
        if (-not [string]::IsNullOrWhiteSpace($yamlProduct) -and $yamlProduct -notin @('UNVERIFIED', $stateProductId)) {
            $relativeYaml = $yamlFile.FullName.Substring($stateRoot.Length + 1)
            $errors.Add("product_id mismatch in product state: $relativeYaml")
        }
    }
}

Enter-CheckGroup 'status-gates'
$matrixPath = Join-Path $stateRoot 'TEST-MATRIX.md'
$toolPlanPath = Join-Path $stateRoot 'tooling/TOOL-PLAN.yaml'
$currentReleasePath = Join-Path $stateRoot 'release/RELEASE-MANIFEST.yaml'
if (Test-Path -LiteralPath $matrixPath -PathType Leaf) {
    $matrixText = Read-StateText -Path $matrixPath
    if ($stateStatus -in @('VERIFIED', 'RELEASED', 'VERIFIED_SIMULATION')) {
        if ($matrixText -match '(?i)PENDING') {
            $errors.Add('TEST-MATRIX still contains PENDING rows while product state is verified')
        }
        # Only PENDING and UNVERIFIED used to be looked for, so a matrix whose every row said
        # FAIL passed the gate: the one word that means "we tried and it broke" went unread.
        $matrixFailRows = @(Get-MatrixFailRows -Text $matrixText)
        if ($matrixFailRows.Count -gt 0) {
            $errors.Add("TEST-MATRIX contains FAIL rows while product state is verified: $($matrixFailRows -join ', ')")
        }
        # Every gate above asks whether something bad is present, which made deleting the evidence
        # cheaper than producing it: an empty matrix contains no PENDING, no UNVERIFIED and no
        # FAIL. This one asks the opposite question -- is any evidence actually here.
        if (@(Get-MatrixPassRows -Text $matrixText).Count -eq 0) {
            $errors.Add('TEST-MATRIX has no passing test evidence rows while product state is verified')
        }
        if ($stateStatus -eq 'VERIFIED_SIMULATION' -and $matrixText -notmatch '(?i)PASS_SIMULATION') {
            $errors.Add('VERIFIED_SIMULATION requires simulation test evidence in TEST-MATRIX.md')
        }
        if ($stateStatus -in @('VERIFIED', 'RELEASED') -and $matrixText -match '(?i)UNVERIFIED') {
            $errors.Add('real verified product TEST-MATRIX still contains UNVERIFIED evidence')
        }
    }
}
if (Test-Path -LiteralPath $toolPlanPath -PathType Leaf) {
    $toolPlanText = Read-StateText -Path $toolPlanPath
    $toolSelectionStatus = Get-YamlScalar -Text $toolPlanText -Key 'selection_status'
    if ($stateStatus -in @('VERIFIED', 'RELEASED', 'VERIFIED_SIMULATION') -and $toolSelectionStatus -match '^(?i)PENDING') {
        $errors.Add('TOOL-PLAN selection_status is PENDING while product state is verified')
    }
    if ($stateStatus -in @('VERIFIED', 'RELEASED', 'VERIFIED_SIMULATION') -and [string]::IsNullOrWhiteSpace($toolSelectionStatus)) {
        # Deleting the key was the way around the PENDING gate: no key, no PENDING, no error.
        $errors.Add('TOOL-PLAN has no selection_status while product state is verified')
    }
    if ($stateStatus -in @('VERIFIED', 'RELEASED') -and $toolPlanText -match '"UNVERIFIED"') {
        $errors.Add('real verified product TOOL-PLAN still contains UNVERIFIED selections')
    }
}
if (Test-Path -LiteralPath $currentReleasePath -PathType Leaf) {
    $currentReleaseText = Read-StateText -Path $currentReleasePath
    $releaseStatus = Get-YamlScalar -Text $currentReleaseText -Key 'status'
    if ($stateSimulationOnly -and $releaseStatus -in @('VERIFIED', 'RELEASED', 'ACTIVE')) {
        $errors.Add('simulation release cannot use real VERIFIED, RELEASED, or ACTIVE status')
    }
    if ($stateStatus -in @('VERIFIED', 'RELEASED') -and $currentReleaseText -match '(?i)UNVERIFIED') {
        $errors.Add('real verified release manifest still contains UNVERIFIED fields')
    }
    if ($stateStatus -eq 'RELEASED' -and $releaseStatus -notin @('RELEASED', 'ACTIVE')) {
        $errors.Add('STATE.yaml is RELEASED but current release manifest is not RELEASED or ACTIVE')
    }
}

Enter-CheckGroup 'critical-contracts'
if ($stateStatus -in @('VERIFIED', 'RELEASED')) {
    $criticalVerifiedFiles = @(
        'PRODUCT-DOSSIER.md',
        'CUSTOMIZATION-MANIFEST.yaml',
        'MAINTENANCE-MODE.yaml',
        'OPERATION-MANIFEST.yaml',
        'HOST-INTEGRATION-MANIFEST.yaml',
        'auth/AUTH-PROFILE.yaml',
        'auth/LAUNCH-CONTRACT.yaml',
        'release/UPDATE-PROFILE.yaml',
        'release/COMPONENT-RELEASE-MANIFEST.yaml'
    )
    foreach ($relative in $criticalVerifiedFiles) {
        $criticalPath = Join-Path $stateRoot $relative
        if ((Test-Path -LiteralPath $criticalPath -PathType Leaf) -and (Read-StateText -Path $criticalPath) -match '(?i)UNVERIFIED') {
            $errors.Add("real verified product has UNVERIFIED material in critical contract: $relative")
        }
    }
}

# A product that still lists what is blocking it, while claiming it is built or verified, is
# telling two stories at once. The state field existed; nothing read it.
Enter-CheckGroup 'blocking-items'
if (-not [string]::IsNullOrWhiteSpace($stateText) -and $stateStatus -in @('BUILD_READY', 'VERIFIED', 'VERIFIED_SIMULATION', 'RELEASED')) {
    $blockingItems = @(Get-YamlListItems -Text $stateText -Key 'blocking_items')
    if ($blockingItems.Count -gt 0) {
        $errors.Add("STATE.yaml still lists $($blockingItems.Count) blocking item(s) while status is ${stateStatus}: $($blockingItems -join '; ')")
    }
}

Enter-CheckGroup 'maintenance-strategy'
$maintenancePath = Join-Path $stateRoot 'MAINTENANCE-MODE.yaml'
if (Test-Path -LiteralPath $maintenancePath -PathType Leaf) {
    $maintenanceText = Read-StateText -Path $maintenancePath
    $selectedStrategy = Get-YamlScalar -Text $maintenanceText -Key 'selected_strategy'
    $allowedStrategies = @('SOURCE_AVAILABLE', 'RESOURCE_OVERLAY', 'BINARY_PATCH_RECORD', 'WRAPPER_LAUNCHER', 'REBUILD_REQUIRED', 'UNKNOWN')
    if (-not [string]::IsNullOrWhiteSpace($selectedStrategy) -and $allowedStrategies -notcontains $selectedStrategy) {
        $errors.Add('MAINTENANCE-MODE.yaml has an unknown selected_strategy')
    }
}

# Placeholders were only ever looked for in STATE.yaml, PRODUCT-INDEX.md and INPUT-MANIFEST.yaml,
# so an unfilled template anywhere else in the dossier read as a finished product. A freshly
# initialised product has none of these, so the sweep is safe in every state.
Enter-CheckGroup 'placeholder-sweep'
$placeholderChecked = @('STATE.yaml', 'PRODUCT-INDEX.md', 'artifacts\INPUT-MANIFEST.yaml')
if (Test-Path -LiteralPath $stateRoot -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $stateRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.md', '.yaml', '.yml', '.json', '.txt') })) {
        $relativeFile = $file.FullName.Substring($stateRoot.Length + 1)
        if ($placeholderChecked -contains $relativeFile) { continue }
        if ((Read-StateText -Path $file.FullName) -match '__[A-Z0-9_]+__') {
            $errors.Add("product state still contains unfilled scaffold placeholders: $relativeFile")
        }
    }
}

Enter-CheckGroup 'host-docs'
$hostDocsPath = Join-Path $root 'docs'
if (Test-Path -LiteralPath $hostDocsPath -PathType Container) {
    $warnings.Add('root docs directory is host-level and is ignored as product memory; use product-state for product facts')
}

Enter-CheckGroup 'credential-sweep'
$textFiles = Get-ChildItem -LiteralPath $stateRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -in @('.md', '.yaml', '.yml', '.json', '.txt')
}
$credentialPattern = '^\s*(admin_token|private_key|client_secret|password)\s*:\s*(.+)$'
foreach ($file in $textFiles) {
    $content = Read-StateText -Path $file.FullName
    foreach ($line in ($content -split "`n")) {
        $match = [regex]::Match($line, $credentialPattern)
        if ($match.Success) {
            $value = $match.Groups[2].Value.Trim().Trim('"')
            if ($value -notin @('', 'UNVERIFIED', 'never', 'not stored')) {
                $warnings.Add("possible credential material in product state: $($file.FullName)")
                break
            }
        }
    }
}

Enter-CheckGroup ''
foreach ($warning in $warnings) { Write-Output "WARN: $warning" }
foreach ($validationError in $errors) { Write-Output "ERROR: $validationError" }

# The single deterministic answer to "what do I do next". Without it, every agent re-derives the
# order from prose and two agents derive two different orders; that is exactly how a product ends
# up half-migrated. These lines are emitted in every state, including a failing one.
if ($null -ne $lifecycleReadiness -and $lifecycleReadiness.Known) {
    Write-Output "STATE: $($lifecycleReadiness.Status) - $($lifecycleReadiness.Meaning)"
    if (-not [string]::IsNullOrWhiteSpace($lifecycleReadiness.NextStatus)) {
        Write-Output "NEXT-STATUS: $($lifecycleReadiness.NextStatus)"
    }
    if (-not [string]::IsNullOrWhiteSpace($lifecycleReadiness.NextAction)) {
        Write-Output "NEXT-ACTION: $($lifecycleReadiness.NextAction)"
    }
    foreach ($item in $lifecycleReadiness.PendingForNext) {
        Write-Output "NEXT-NEEDS: $($item.Why) [$($item.Detail)]"
    }
}
Write-CoverageSummary
if ($errors.Count -gt 0) {
    Write-Output "RESULT: failed ($($errors.Count) error(s), $($warnings.Count) warning(s))"
    exit 1
}
if ($Strict -and $warnings.Count -gt 0) {
    Write-Output "RESULT: failed in strict mode (0 error(s), $($warnings.Count) warning(s))"
    exit 1
}
Write-Output "RESULT: passed (0 error(s), $($warnings.Count) warning(s))"
