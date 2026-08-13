#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,

    [switch]$Strict,

    # RV-R2 opening (a): a static gate can prove a bound evidence artifact's hash matches its record, but
    # it can never prove that artifact was really produced by exercising/analysing the product -- a
    # determined forger can author a hash-consistent fake. That ceiling is out of a static gate's reach.
    # -RequireAttestation opts a real VERIFIED/RELEASED into requiring a recorded named endorsement
    # (product-state/attestation/ATTESTATION.yaml). The gate checks the record is complete and matches the
    # status; it verifies NO identity and NO signature -- one made-up name produces the same record -- so
    # the trust label it earns says exactly that instead of claiming external attestation.
    [switch]$RequireAttestation
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
    'analysis-brainstorm', 'blocking-items', 'maintenance-strategy', 'placeholder-sweep', 'host-docs', 'credential-sweep',
    'attestation'
)
$checkGroupsDone = New-Object System.Collections.Generic.List[string]
$currentCheckGroup = ''
$coverageEmitted = $false
$verifiedStatuses = @('VERIFIED', 'VERIFIED_SIMULATION', 'RELEASED')
# Canonical maintenance/reproduction route set. ROUTE-DECISION.chosen_route and MAINTENANCE-MODE.selected_strategy
# share EXACTLY this set, so it lives here as the single source of truth: a gate must never read legality from a
# product file's own allowed_* list (a product could empty that list to switch the check off -- RV brainstorm
# red-team #2). UNKNOWN is the not-decided sentinel and is intentionally excluded from the legal routes.
$script:CanonicalRoutes = @('SOURCE_AVAILABLE', 'RESOURCE_OVERLAY', 'BINARY_PATCH_RECORD', 'WRAPPER_LAUNCHER', 'REBUILD_REQUIRED')
# Project-wide "not settled / not decided" sentinels (mirrors lifecycle-states.json unsettled_values). A field
# carrying any of these has decided nothing, so a "settled" check that rejects only UNVERIFIED is too narrow.
$script:UnsettledScalars = @('UNVERIFIED', 'PENDING', 'UNKNOWN', 'DISCOVERY_PENDING', 'TBD')

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

# An empty (0-byte) file is no more evidence than a typed line -- its SHA-256 is the well-known constant
# below -- so "bound to a real file" must also mean "a real, non-empty file". Without this the
# run-evidence / evidence-ledger / analysis-findings hard gates accept a 0-byte file (or the same file
# reused for all three run kinds), silently breaking the "空必红" promise. (RV attack finding F1.)
$script:EmptyFileSha256 = 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
function Test-BoundEvidenceFile {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][string]$RecordedSha256
    )

    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $FullPath).Length -le 0) { return $false }
    if ($RecordedSha256.ToUpperInvariant() -eq $script:EmptyFileSha256) { return $false }
    # Evidence must live under product-state/ (as the binding comments promise), not merely somewhere in the
    # product root -- otherwise evidence can be scattered outside the state dir. (RV attack finding F2.)
    $stateRootPrefix = $script:stateRoot.TrimEnd('\') + '\'
    if (-not $FullPath.StartsWith($stateRootPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return ((Get-FileHash -LiteralPath $FullPath -Algorithm SHA256).Hash.ToUpperInvariant() -eq $RecordedSha256.ToUpperInvariant())
}

function Test-IsEmptyFileBypass {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][string]$RecordedSha256
    )

    # A real product artifact (core / baseline / registered input) must be a non-empty file, and its recorded
    # sha256 must not be the well-known empty-file constant. Returns $true if this binding is the 0-byte /
    # empty-constant bypass -- the product body must not be a literal empty file. (RV final finding N-EPLC-5,
    # same family as F1/N1: "空必红" must hold on the baseline/core/manifest hash bindings too.)
    if ($RecordedSha256.ToUpperInvariant() -eq $script:EmptyFileSha256) { return $true }
    if ((Test-Path -LiteralPath $FullPath -PathType Leaf) -and ((Get-Item -LiteralPath $FullPath).Length -le 0)) { return $true }
    return $false
}

function Test-RunEvidenceBound {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    # Read the indented block under "^<Kind>:" (up to the next top-level key) and pull its path + sha256.
    # Bound = a 64-hex sha256 plus a path that stays inside the product and whose file's actual Get-FileHash
    # matches. A screenshot/recording is far harder to fabricate than a typed line, so binding real-run
    # evidence to a real file is the direct counter to opening (a)'s static-gate ceiling.
    $lines = $Text -split "`r?`n"
    $inBlock = $false
    $blockPath = ''
    $blockHash = ''
    foreach ($line in $lines) {
        if ($line -match ('^' + [regex]::Escape($Kind) + ':\s*(#.*)?$')) { $inBlock = $true; continue }
        if (-not $inBlock) { continue }
        if ($line -match '^\S') { break }
        $pm = [regex]::Match($line, '^\s+path:\s*["'']?([^"''\r\n]+?)["'']?\s*$')
        if ($pm.Success) { $blockPath = $pm.Groups[1].Value.Trim(); continue }
        $hm = [regex]::Match($line, '^\s+sha256:\s*["'']?([0-9A-Fa-f]{64})["'']?\s*$')
        if ($hm.Success) { $blockHash = $hm.Groups[1].Value.Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($blockPath) -or [string]::IsNullOrWhiteSpace($blockHash)) { return '' }
    $resolved = Resolve-ProductRelativePath -Relative $blockPath
    if (-not $resolved.Inside) { return '' }
    if (-not (Test-BoundEvidenceFile -FullPath $resolved.FullPath -RecordedSha256 $blockHash)) { return '' }
    # Return the bound hash (not just $true) so the caller can require the three run kinds to be distinct.
    return $blockHash.ToUpperInvariant()
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
# Phase 2: which lifecycle ladder governs this product. A source-reuse product carries track: source and
# runs lifecycle-states-source.json; a legacy/EXE product has no track and runs the EXE ladder. Read here so
# every downstream group (lifecycle gate, EXE-baseline guards, the SR-repair legal-values) agrees on it.
$stateTrack = ''
$lifecycleFile = 'lifecycle-states.json'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $stateText = Read-StateText -Path $statePath
    $stateTrack = (Get-YamlScalar -Text $stateText -Key 'track').Trim()
    $lifecycleFile = Get-LifecycleTableFileForTrack -Track $stateTrack
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
    # Derived from the lifecycle table, never a second hardcoded copy: a status list kept in two
    # places is exactly how ISSUE-096 happened -- the table gained a state this copy lacked, so a
    # legitimate status read back as unrecognized. One source means a state added to
    # lifecycle-states.json is recognized here automatically.
    $allowedStatuses = @((Get-LifecycleTable -TableFile $lifecycleFile).states | ForEach-Object { [string]$_.status })
    if ($allowedStatuses -notcontains $stateStatus) {
        $errors.Add('STATE.yaml has no recognized status')
    }
    if ($stateSimulationOnly -and $stateStatus -in @('VERIFIED', 'RELEASED')) {
        $errors.Add('simulation_only product cannot use real VERIFIED or RELEASED status; use VERIFIED_SIMULATION')
    }
    if (-not $stateSimulationOnly -and $stateStatus -eq 'VERIFIED_SIMULATION') {
        $errors.Add('VERIFIED_SIMULATION requires simulation_only: true')
    }
    # A4: `track` is a self-asserted string that switches OFF the entire EXE baseline + reverse-
    # engineering evidence subsystem (six downstream checks key off `-ne 'source'`). Require positive,
    # machine-checkable evidence that a product claiming track:source really is a source-reuse product,
    # so an EXE intake cannot dodge those gates by relabeling itself: it must carry the source front-
    # half (source/SOURCE-INTAKE.yaml, which only a source intake creates) and must NOT carry EXE-
    # intake markers (a 64-hex baseline_sha256 or a core_path, which only a handed-over binary has).
    if ($stateTrack -eq 'source') {
        if (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'source\SOURCE-INTAKE.yaml') -PathType Leaf)) {
            $errors.Add('STATE.yaml 声称 track: source，但缺少 source/SOURCE-INTAKE.yaml——源码复用产品必须带源前半段档案；track 不能用来跳过 EXE 基线/逆向证据门')
        }
        if ([regex]::IsMatch($stateText, '(?m)^baseline_sha256:\s*["'']?[0-9A-Fa-f]{64}["'']?\s*$')) {
            $errors.Add('STATE.yaml 声称 track: source，却登记了 EXE 基线哈希 baseline_sha256——源码复用产品没有被交接的上游二进制；带基线就必须走 EXE 轨道，track:source 不能关掉基线/逆向门')
        }
        if (-not [string]::IsNullOrWhiteSpace($stateCoreName)) {
            $errors.Add('STATE.yaml 声称 track: source，却登记了 core_path（被交接的核心可执行文件）——源码复用产品从自己源码构建、无交接 EXE；带 core_path 就必须走 EXE 轨道')
        }
    }
    # EXE-baseline identity: only the EXE track hands over a baseline executable. A source-reuse product is
    # built from the user's own source, so it has no preserved upstream binary and no baseline_sha256 --
    # judging it by a missing baseline would be a false failure. The source track proves its reality through
    # build/run evidence (EVIDENCE-LEDGER) and the real-run gate instead, both of which still apply.
    if ($stateTrack -ne 'source') {
        $hashMatch = [regex]::Match($stateText, '(?m)^baseline_sha256:\s*["'']?([0-9A-Fa-f]{64})["'']?\s*$')
        if (-not $hashMatch.Success) {
            $errors.Add('STATE.yaml baseline_sha256 is missing or invalid')
        }
        else {
            $stateBaselineHash = $hashMatch.Groups[1].Value.ToUpperInvariant()
            if ($stateBaselineHash -eq $script:EmptyFileSha256) {
                $errors.Add('STATE.yaml baseline_sha256 是空文件常量（E3B0C442…）：被二次发行的核心/基线不能是 0 字节空文件，请登记真实的产品本体')
            }
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
}

# `core_path` was a field that existed but was verified by nobody: only the preserved copy under
# artifacts/upstream was hashed, so swapping the live executable at the product root still
# reported "passed". A field the downstream trusts and no one checks is worse than a missing one.
Enter-CheckGroup 'core-artifact-integrity'
# EXE-only: a source-reuse product has no handed-over core executable to hash against a baseline.
if ($stateTrack -ne 'source' -and -not [string]::IsNullOrWhiteSpace($stateCoreName) -and -not [string]::IsNullOrWhiteSpace($stateBaselineHash)) {
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
    $lifecycleReadiness = Get-LifecycleReadiness -StateRoot $stateRoot -Status $stateStatus -TableFile $lifecycleFile
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
        if ($null -ne $recordSize -and $recordSize -match '^[0-9]+$') { $current.size = [int64]$recordSize; continue }
        # Which layer the finding was actually observed on. Absent on every pre-existing dossier,
        # which is the whole reason the gate below treats "absent" as a third state instead of
        # picking a default: defaulting to payload passes the entire backlog silently, defaulting
        # to fail reddens it wholesale and the next person switches the gate off.
        $recordLayer = Get-ManifestFieldValue -Line $normalized -Key 'observed_layer'
        if ($null -ne $recordLayer) { $current.observed_layer = $recordLayer }
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

function Get-ThroughlineResultCells {
    param([Parameter(Mandatory = $true)][string]$Text)

    # The last cell of every data row in the 关键验收 table is its 结果/result verdict. Only rows whose
    # last cell is a recognized verdict are counted, so the header (结果) and the --- separator drop out
    # without hard-coding their position, and prose or code-fence lines never look like a row.
    $known = @('PASS', 'PASSED', 'PASS_SIMULATION', 'PENDING', 'FAIL', 'FAILED', 'UNVERIFIED')
    $results = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '^\s*\|') { continue }
        $cells = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim().Trim('`').Trim() })
        if ($cells.Count -lt 2) { continue }
        $last = $cells[$cells.Count - 1].ToUpperInvariant()
        if ($known -contains $last) { [void]$results.Add($last) }
    }
    return $results
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
        if (Test-IsEmptyFileBypass -FullPath $absolute -RecordedSha256 $expectedHash) {
            $errors.Add("manifest 记录指向 0 字节空文件或用空文件常量哈希蒙混，不算真实产物: $relative")
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
    # EXE-only: the input manifest records the handed-over EXE/installer/DLL bundle. A source-reuse product
    # has no such upstream bundle (it is built from the user's own source), so a missing manifest is neither
    # an error nor a to-do for it.
    if ($stateTrack -ne 'source') {
        if ($stateStatus -in $verifiedStatuses) {
            # Deleting the manifest used to be the cheapest way past this file's hash checks: with no
            # records there is nothing to compare, and the missing manifest was only a warning.
            $errors.Add('input manifest is missing while product state is verified; the preserved inputs are then under no hash constraint at all')
        }
        else {
            $warnings.Add('input manifest is not generated yet; preserve and register all supplied files before analysis')
        }
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
# EXE-only: this compares product-root files against the baseline/registered-input hashes to catch a new
# upstream build dropped next to the old one. A source-reuse product's root is the user's own project tree
# (many source files, no baseline), so this comparison does not apply and would false-flag project files.
if ($stateTrack -ne 'source' -and (Test-Path -LiteralPath $stateRoot -PathType Container)) {
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
        elseif (Test-IsEmptyFileBypass -FullPath $baselineAbsolute -RecordedSha256 $baselineHashMatch.Groups[1].Value) {
            $errors.Add("baseline manifest 指向 0 字节空文件或用空文件常量哈希蒙混: $baselinePath")
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

# Through-line evidence. Nothing read VERIFICATION-RECORD.md before this, so a real VERIFIED could
# stand on an all-PENDING scaffold -- a fidelity label plus some TEST-MATRIX text was enough. That is
# the second half of RV-A#1: the narrow gate stealing the wide goal. A real VERIFIED/RELEASED must
# show the user-operation through-line (启动 -> 授权 -> 进入核心 -> 观察 -> 回滚) actually PASSED, judged
# from the 关键验收 result column and the overall conclusion, so deleting the evidence cannot pass it.
$verificationRecordPath = Join-Path $stateRoot 'reports/VERIFICATION-RECORD.md'
if ($stateStatus -in @('VERIFIED', 'RELEASED')) {
    if (-not (Test-Path -LiteralPath $verificationRecordPath -PathType Leaf)) {
        $errors.Add('real verified product has no reports/VERIFICATION-RECORD.md through-line record')
    }
    else {
        $recordText = Read-StateText -Path $verificationRecordPath
        $throughResults = @(Get-ThroughlineResultCells -Text $recordText)
        if ($throughResults.Count -eq 0) {
            $errors.Add('VERIFICATION-RECORD.md 关键验收 表里没有任何可判定的结果行；真实 VERIFIED 需要逐条走通用户操作 through-line（启动/授权/进入核心/回滚）')
        }
        else {
            $throughNotPass = @($throughResults | Where-Object { $_ -ne 'PASS' })
            if ($throughNotPass.Count -gt 0) {
                $errors.Add("VERIFICATION-RECORD.md 关键验收 仍有未通过的行（$($throughNotPass -join ', ')）；真实 VERIFIED 的启动/授权/进入核心/回滚每一步都必须 PASS（PASS_SIMULATION 只算模拟）")
            }
        }
        $overallMatch = [regex]::Match($recordText, '(?im)overall_result`?\s*:\s*`?\s*([A-Za-z_]+)')
        $overallResult = if ($overallMatch.Success) { $overallMatch.Groups[1].Value.ToUpperInvariant() } else { '' }
        if ($overallResult -ne 'PASS') {
            $errors.Add("VERIFICATION-RECORD.md overall_result 不是 PASS（当前: $(if ([string]::IsNullOrWhiteSpace($overallResult)) { '缺失' } else { $overallResult })）；真实 VERIFIED 必须给出通过结论")
        }
    }
}

# Runnable rollback (RV-C-G3). requiredFiles only proved the runbook FILE exists; its content was never
# read, so a real VERIFIED could ship the <ROLLBACK_COMMAND> template with an UNVERIFIED target -- a
# rollback that is a promise, not a procedure. A real VERIFIED/RELEASED rollback must be runnable and
# pinned: no angle-bracket command placeholders left, and a real 64-hex package hash so it points at a
# saved, verified prior release rather than "just reinstall the old one". This is the runnable backing
# under the 回滚 row that the through-line gate already forces to PASS.
$rollbackRunbookPath = Join-Path $stateRoot 'rollback/ROLLBACK-RUNBOOK.md'
if ($stateStatus -in @('VERIFIED', 'RELEASED') -and (Test-Path -LiteralPath $rollbackRunbookPath -PathType Leaf)) {
    $rollbackText = Read-StateText -Path $rollbackRunbookPath
    $rollbackPlaceholders = @([regex]::Matches($rollbackText, '<[A-Za-z0-9_]+>') | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($rollbackPlaceholders.Count -gt 0) {
        $errors.Add("ROLLBACK-RUNBOOK.md 还留着命令占位符（$($rollbackPlaceholders -join ', ')）；真实 VERIFIED 的回滚必须是能真跑的命令，不能是模板")
    }
    $runbookHexes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($hexMatch in [regex]::Matches($rollbackText, '[0-9A-Fa-f]{64}')) { [void]$runbookHexes.Add($hexMatch.Value.ToUpperInvariant()) }
    if ($runbookHexes.Count -eq 0) {
        $errors.Add('ROLLBACK-RUNBOOK.md 没有登记回滚目标包的 SHA-256（64 位）——回滚必须指向已保存、已校验的上一条 Release，而不是“重新安装旧版”')
    }
    else {
        # RV-R2 bypass #4: "some 64-hex appears" was satisfiable by pasting any hex (rollback theater).
        # The rollback hash must point at a REAL preserved package: at least one 64-hex in the runbook
        # must equal the Get-FileHash of a file preserved under product-state/artifacts (rollback /
        # maintained / upstream / patches). A hash with no package behind it is not a rollback.
        $rollbackBound = $false
        foreach ($rollbackSub in @('artifacts\rollback', 'artifacts\maintained', 'artifacts\upstream', 'artifacts\patches')) {
            $rollbackSubDir = Join-Path $stateRoot $rollbackSub
            if (-not (Test-Path -LiteralPath $rollbackSubDir -PathType Container)) { continue }
            foreach ($rollbackPkg in @(Get-ChildItem -LiteralPath $rollbackSubDir -Recurse -File -ErrorAction SilentlyContinue)) {
                # A 0-byte "package" (whose sha256 is the empty-file constant) is not a real rollback target,
                # same rule as the evidence gates -- skip it so the empty-file bypass cannot reach 真回滚. (RV recheck N1.)
                if ($rollbackPkg.Length -le 0) { continue }
                $rollbackPkgHash = (Get-FileHash -LiteralPath $rollbackPkg.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($rollbackPkgHash -eq $script:EmptyFileSha256) { continue }
                if ($runbookHexes.Contains($rollbackPkgHash)) { $rollbackBound = $true; break }
            }
            if ($rollbackBound) { break }
        }
        if (-not $rollbackBound) {
            $errors.Add('ROLLBACK-RUNBOOK.md 里的 64 位哈希没有对应任何已保存的回滚包（product-state/artifacts/rollback|maintained|upstream|patches 下无文件与之哈希一致）——回滚必须指向真实存在的包')
        }
    }
}

# Evidence ledger is real, not decorative (RV-C-G4/G1). BUILD_READY only asked that its status be
# settled; entries: [] was never read and its own rule static_is_not_runtime_proof was never enforced.
# A real VERIFIED/RELEASED must carry at least one ledger entry at a RUNTIME evidence level
# (locally_exercised / dynamic_success): "the files are present" (static_present) is not "it ran".
$evidenceLedgerPath = Join-Path $stateRoot 'EVIDENCE-LEDGER.yaml'
if ($stateStatus -in @('VERIFIED', 'RELEASED') -and (Test-Path -LiteralPath $evidenceLedgerPath -PathType Leaf)) {
    $ledgerText = Read-StateText -Path $evidenceLedgerPath
    if ((Get-YamlListCount -Text $ledgerText -Key 'entries') -le 0) {
        $errors.Add('EVIDENCE-LEDGER.yaml 的 entries 为空——真实 VERIFIED 必须登记至少一条运行期证据，而不是空台账')
    }
    elseif ($ledgerText -notmatch '(?im)evidence_level\s*:\s*["'']?(locally_exercised|dynamic_success)\b') {
        $errors.Add('EVIDENCE-LEDGER.yaml 没有任何运行期证据（locally_exercised/dynamic_success）——static_present 只是“文件在”，不等于“真的跑起来了”')
    }
    else {
        # Fabricate-from-nothing defense (RV-R2). The two checks above only read text, so a runtime
        # level could be typed with nothing behind it -- exactly the bypass that pushed a 30-byte fake
        # core to a green VERIFIED. A runtime claim must now be BOUND to a real artifact: at least one
        # entry must carry path + sha256 pointing at a file under product-state/ that exists and whose
        # actual Get-FileHash equals the recorded one. This raises the bar from "type a line" to
        # "produce a hash-consistent artifact file" and leaves that file on disk for a human or a
        # downstream step to inspect. (A determined forger can still author a fake file that matches its
        # own recorded hash; defeating that needs trusted execution and is out of a static gate's reach.)
        $ledgerBound = 0
        foreach ($ledgerRecord in @(Get-ManifestRecords -Text $ledgerText | Where-Object { ($_.PSObject.Properties.Name -contains 'path') -and ($_.PSObject.Properties.Name -contains 'sha256') })) {
            $ledgerResolved = Resolve-ProductRelativePath -Relative ([string]$ledgerRecord.path)
            if (-not $ledgerResolved.Inside) { continue }
            if (Test-BoundEvidenceFile -FullPath $ledgerResolved.FullPath -RecordedSha256 ([string]$ledgerRecord.sha256)) { $ledgerBound++ }
        }
        if ($ledgerBound -eq 0) {
            $errors.Add('EVIDENCE-LEDGER.yaml 的运行期证据没有绑定真实产物：至少要有一条 entry 带 path + sha256，指向 product-state/ 下真实存在、非空且哈希一致的证据文件——纯文本声明（凭空捏造）或 0 字节空文件判失败')
        }
    }
}

# Reverse-engineering findings must be real, not a typed claim (提高 EXE 二开 + 反捏造, mirrors EB). A
# real VERIFIED/RELEASED 二开 rests on actual reverse engineering -- disassembly, static structure/
# strings/resources, dynamic behaviour, unpacking -- so ANALYSIS-FINDINGS must carry at least one
# finding BOUND to a real artifact under product-state/ whose Get-FileHash matches the recorded sha256.
# This is the same fabricate-from-nothing defence the evidence ledger uses: typing "反汇编过了" with no
# saved tool output is not evidence. (A determined forger can still author a fake file matching its own
# recorded hash; defeating that needs trusted execution and is out of a static gate's reach.)
$analysisFindingsPath = Join-Path $stateRoot 'analysis/ANALYSIS-FINDINGS.yaml'
# EXE-only: reverse-engineering findings are how an opaque EXE is understood. A source-reuse product already
# has the source, so disassembly/unpacking do not apply -- its reality is proven by build + real-run
# evidence (EVIDENCE-LEDGER + RUN-EVIDENCE), which still gate the source track's VERIFIED below.
if ($stateTrack -ne 'source' -and $stateStatus -in @('VERIFIED', 'RELEASED') -and (Test-Path -LiteralPath $analysisFindingsPath -PathType Leaf)) {
    $findingsText = Read-StateText -Path $analysisFindingsPath
    if ((Get-YamlListCount -Text $findingsText -Key 'findings') -le 0) {
        $errors.Add('ANALYSIS-FINDINGS.yaml 的 findings 为空——真实 VERIFIED 的 EXE 二开必须至少留下一条逆向分析发现（反汇编/静态结构/字符串/资源/动态行为/脱壳之一），而不是空记录')
    }
    else {
        # Same hash-binding shape as EVIDENCE-LEDGER above: at least one finding must carry path + sha256
        # pointing at a file under product-state/ that exists and whose actual hash equals the recorded one.
        $findingsBound = 0
        foreach ($findingRecord in @(Get-ManifestRecords -Text $findingsText | Where-Object { ($_.PSObject.Properties.Name -contains 'path') -and ($_.PSObject.Properties.Name -contains 'sha256') })) {
            $findingResolved = Resolve-ProductRelativePath -Relative ([string]$findingRecord.path)
            if (-not $findingResolved.Inside) { continue }
            if (Test-BoundEvidenceFile -FullPath $findingResolved.FullPath -RecordedSha256 ([string]$findingRecord.sha256)) { $findingsBound++ }
        }
        if ($findingsBound -eq 0) {
            $errors.Add('ANALYSIS-FINDINGS.yaml 的逆向发现没有落到真实工具输出：至少要有一条 finding 带 path + sha256，指向 product-state/ 下真实存在、非空且哈希一致的工具输出文件（如 dumpbin/DIE/IDA 导出）——只在档案里打字声称做过逆向或 0 字节空文件判失败')
        }
    }
}

# Layer gate: the findings count above says how many boxes were ticked, never which thing they were
# ticked ON. On a container or a packed target you can dump strings, export resources, read the
# static structure and trace runtime behaviour -- four real tool outputs, four real hashes, all four
# through the gate above -- and every one of them describes the installer or the shell. So when the
# router says the payload is not visible yet, a finding claiming to be ON the payload is wrong by
# construction. Runs for any status (not just VERIFIED): catching this at ANALYZED is the point.
$profilePathForLayer = Join-Path $stateRoot 'PROTECTION-PROFILE.yaml'
if ($stateTrack -ne 'source' -and (Test-Path -LiteralPath $analysisFindingsPath -PathType Leaf) -and (Test-Path -LiteralPath $profilePathForLayer -PathType Leaf)) {
    $layerProfileText = Read-StateText -Path $profilePathForLayer
    $routingVerdict = Get-YamlIndentedScalar -Text $layerProfileText -Parent 'modifiability' -Key 'verdict'
    $layerFindingsText = Read-StateText -Path $analysisFindingsPath
    $layerPayload = 0
    $layerPacker = 0
    $layerContainer = 0
    foreach ($layerRecord in @(Get-ManifestRecords -Text $layerFindingsText)) {
        $layerValue = ''
        if ($layerRecord.PSObject.Properties.Name -contains 'observed_layer') {
            $layerValue = ([string]$layerRecord.observed_layer).Trim().ToLowerInvariant()
        }
        switch ($layerValue) {
            'payload' { $layerPayload++ }
            'packer' { $layerPacker++ }
            'container' { $layerContainer++ }
        }
    }
    # Unknown is the remainder against an INDEPENDENT count of the list, not a tally of records the
    # parser produced. Get-ManifestRecords drops any record it extracted no known field from, so a
    # legacy finding carrying only id/technique/summary is invisible to it -- counting unknowns
    # inside that loop reported "findings=0 unknown=0" for a dossier full of unmeasured findings,
    # which is the silent pass this third state exists to prevent.
    $layerTotal = Get-YamlListCount -Text $layerFindingsText -Key 'findings'
    if ($layerTotal -lt ($layerPayload + $layerPacker + $layerContainer)) {
        $layerTotal = $layerPayload + $layerPacker + $layerContainer
    }
    $layerUnknown = $layerTotal - ($layerPayload + $layerPacker + $layerContainer)
    # Third state on the summary line with a denominator, same shape as validate-knowledge's
    # COVERAGE line. Unknown is neither counted as passing nor as failing -- it is reported, so a
    # dossier that predates the field is visibly unmeasured instead of invisibly green.
    Write-Output ("LAYER-COVERAGE: verdict={0} findings={1} payload={2} packer={3} container={4} unknown={5}" -f `
        $(if ([string]::IsNullOrWhiteSpace($routingVerdict)) { 'absent' } else { $routingVerdict }), `
        $layerTotal, $layerPayload, $layerPacker, $layerContainer, $layerUnknown)
    if ($routingVerdict -in @('CONTAINER', 'WRAPPER_ONLY') -and $layerPayload -gt 0) {
        # The error names the way out on purpose. Without it the cheapest move for someone who
        # legitimately DID unpack is to relabel observed_layer to 'packer' and walk through -- which
        # is precisely the behaviour this gate exists to stop. A gate whose exit is documented
        # somewhere else is a gate that manufactures the forgery it was built to catch.
        $errors.Add(('ANALYSIS-FINDINGS.yaml 有 ' + $layerPayload + ' 条 observed_layer=payload 的发现，但当前路由判定是 ' + $routingVerdict + '——此时本体还没有被看到，这些发现描述的只可能是容器或壳。出路（不要改标记蒙混）：如果你已经解开了容器 / 脱了壳，请对解出来的那个目标重新跑 detect-protections.ps1 重新路由（该判定的 re_enter 为 yes 即表示应当如此），第二轮判定不再是 ' + $routingVerdict + '，本体层发现自然合法；如果还没解开，请把这些发现改标为 container 或 packer'))
    }
}

# Real-run evidence (硬门). A real VERIFIED/RELEASED must show the product was ACTUALLY launched and gated,
# with evidence bound to real screenshot/recording files -- not a typed claim. Three kinds are required,
# each bound like the evidence ledger (path + sha256 -> a real file under product-state/ whose Get-FileHash
# matches): launch (启动→授权→真实操作→观察), offline_rejected (断网被拒), badkey_rejected (错卡密被拒).
# A screenshot/recording is far harder to fabricate than a line of text -- the direct counter to opening
# (a)'s static-gate ceiling -- and it makes the user-testable slice mandatory rather than merely defined.
$runEvidencePath = Join-Path $stateRoot 'reports/RUN-EVIDENCE.yaml'
if ($stateStatus -in @('VERIFIED', 'RELEASED')) {
    if (-not (Test-Path -LiteralPath $runEvidencePath -PathType Leaf)) {
        $errors.Add('缺少 reports/RUN-EVIDENCE.yaml：真实 VERIFIED/RELEASED 必须真启动一遍成品并留下截图/录屏，以及断网被拒、错卡密被拒的真实证据')
    }
    else {
        $runText = Read-StateText -Path $runEvidencePath
        $runKinds = @(
            @{ Key = 'launch'; Why = '启动→授权成功→进入核心→真实操作的截图/录屏' },
            @{ Key = 'offline_rejected'; Why = '断网/离线按授权档案被拒、未放行核心的截图/录屏' },
            @{ Key = 'badkey_rejected'; Why = '错误卡密/授权失败被明确拒绝、未进入核心的截图/录屏' }
        )
        $boundRunHashes = New-Object System.Collections.Generic.List[string]
        foreach ($rk in $runKinds) {
            $boundRunHash = Test-RunEvidenceBound -Text $runText -Kind $rk.Key
            if ([string]::IsNullOrEmpty($boundRunHash)) {
                $errors.Add("RUN-EVIDENCE.yaml 的 $($rk.Key)（$($rk.Why)）没有绑定真实文件：需要 path + sha256 指向 product-state/ 下真实存在、非空且哈希一致的截图/录屏——纯文本声称跑过了、或 0 字节空文件判失败")
            }
            else {
                [void]$boundRunHashes.Add($boundRunHash)
            }
        }
        # Three kinds = three distinct observations; one file reused for launch + offline + badkey is not
        # three real runs. Require the sha256 that did bind to be all-distinct. (RV attack finding F1.)
        if ($boundRunHashes.Count -ge 2) {
            $uniqueRunHashes = @($boundRunHashes | Select-Object -Unique)
            if ($uniqueRunHashes.Count -lt $boundRunHashes.Count) {
                $errors.Add('RUN-EVIDENCE.yaml 的 launch/offline_rejected/badkey_rejected 绑定了同一个文件：三类真机证据必须是三个互不相同的截图/录屏（sha256 各不相同），一文件多用判失败')
            }
        }
    }
}

# binding_summary in AUTH-ADAPTER-REQUEST.md is what the authorization platform machine-reads; it MUST match
# the sole grading source LAUNCH-CONTRACT.yaml binding_strength verbatim and may not report a higher tier.
# Only enforce once the summary actually asserts a tier (an unset UNKNOWN summary reports nothing, so there is
# no fake tier to catch -- which also keeps a fresh/unfilled summary from tripping the gate). (RV auth F-AH-2.)
$adapterReqPath = Join-Path $stateRoot 'auth/AUTH-ADAPTER-REQUEST.md'
$launchContractPath = Join-Path $stateRoot 'auth/LAUNCH-CONTRACT.yaml'
if ((Test-Path -LiteralPath $adapterReqPath -PathType Leaf) -and (Test-Path -LiteralPath $launchContractPath -PathType Leaf)) {
    $adapterReqText = Read-StateText -Path $adapterReqPath
    if ($adapterReqText -match '(?m)^\s*binding_summary:') {
        $summaryClaimedTier = (Get-IndentedYamlScalar -Text $adapterReqText -Key 'claimed_tier').Trim().ToUpperInvariant()
        if ($summaryClaimedTier -in @('A', 'B', 'C')) {
            $launchContractText = Read-StateText -Path $launchContractPath
            foreach ($bindingField in @('claimed_tier', 'verified_tier', 'bypass_risk')) {
                $summaryValue = (Get-IndentedYamlScalar -Text $adapterReqText -Key $bindingField).Trim()
                $contractValue = (Get-IndentedYamlScalar -Text $launchContractText -Key $bindingField).Trim()
                if ($summaryValue -ne $contractValue) {
                    $errors.Add("AUTH-ADAPTER-REQUEST.md 的 binding_summary.$bindingField 与 LAUNCH-CONTRACT.yaml 的 binding_strength.$bindingField 不一致（机读摘要必须与唯一判级真相源逐字一致、不得另报更高级别）")
                }
            }
        }
    }
}

# (License gate intentionally NOT implemented -- user decision.) The source-reuse workflow is "learn the
# approach, write your own code", not bulk-copying a repo, so upstream license obligations basically do not
# trigger. Copyright/license is out of scope entirely (no license field anywhere, no gate); only a lightweight
# supply-chain reminder remains (protect the machine, not copyright), and it never blocks. See SKILL.md.

# Override is not verification (RV-R2 hole B). update-product-state.ps1 -Force can move a product past
# a gate the evidence does not satisfy; it now records gate_overridden: true on disk. A real
# VERIFIED/RELEASED must NOT ship carrying that mark -- to reach it for real the evidence gates have to
# pass on their own (a clean transition resets the mark to false). A missing field reads as not-forced.
if ($stateStatus -in @('VERIFIED', 'RELEASED') -and (Get-YamlScalar -Text $stateText -Key 'gate_overridden') -match '^(?i)\s*true\s*$') {
    $errors.Add('STATE.yaml gate_overridden=true——这个 VERIFIED/RELEASED 是 -Force 强推的、没有真正满足证据门；真实发布必须让证据门自行通过（会把 gate_overridden 归 false），不能带着强推标记出厂')
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

# Analysis brainstorm (opt-in, off by default). BRAINSTORM-LOG.yaml is absent or status: open on a
# normal product, and then this checks nothing -- the mode costs nothing until it is used. But the
# moment an agent opens a brainstorm and marks it status: resolved, the discussion must have LANDED a
# real route: a resolved brainstorm whose ROUTE-DECISION still reads chosen_route: UNKNOWN (or
# route_rationale: UNVERIFIED) is "开了会但没决定" -- the exact 文档不是进度 anti-pattern this mode exists
# to prevent. So resolved => ROUTE-DECISION.yaml must exist and carry a decided route (in allowed_routes,
# not UNKNOWN) plus a real rationale. Runs in every status, not just VERIFIED: the point is to catch the
# empty brainstorm at ANALYZED, before it drifts into fixtures/packaging. Delete this block and a
# resolved-but-undecided brainstorm passes -- which is exactly what test-product-state-gates.ps1 BB1 reds on.
# Track-agnostic on purpose: source products may opt into a brainstorm too (they also ship
# analysis/ROUTE-DECISION.yaml via the shared product-scaffold), so this is NOT guarded by
# $stateTrack -ne 'source' like the neighbouring reverse-engineering gates. Do not "fix" it into an
# EXE-only guard to match its neighbours.
Enter-CheckGroup 'analysis-brainstorm'
$brainstormLogPath = Join-Path $stateRoot 'analysis/BRAINSTORM-LOG.yaml'
if (Test-Path -LiteralPath $brainstormLogPath -PathType Leaf) {
    $brainstormText = Read-StateText -Path $brainstormLogPath
    # Read status tolerant of indentation: BRAINSTORM-LOG has exactly one `status:` key, and anchoring at
    # column 0 (Get-YamlScalar) let a stray leading indent read as "absent" -> the whole gate skipped, a
    # careless-indent silencer of a protective gate (RV brainstorm red-team, indented-status edge).
    if ((Get-IndentedYamlScalar -Text $brainstormText -Key 'status') -match '^(?i)\s*resolved\s*$') {
        $routeDecisionPath = Join-Path $stateRoot 'analysis/ROUTE-DECISION.yaml'
        if (-not (Test-Path -LiteralPath $routeDecisionPath -PathType Leaf)) {
            $errors.Add('analysis/BRAINSTORM-LOG.yaml 标记为 resolved，却没有 analysis/ROUTE-DECISION.yaml——头脑风暴收尾必须落到一条已决路线，讨论结束不等于完成（"开会但不决定"正是本模式要挡的"文档不是进度"）')
        }
        else {
            $routeText = Read-StateText -Path $routeDecisionPath
            $chosenRoute = (Get-YamlScalar -Text $routeText -Key 'chosen_route').Trim().ToUpperInvariant()
            $routeRationale = (Get-YamlScalar -Text $routeText -Key 'route_rationale').Trim()
            # chosen_route legality is judged against the canonical route set held in THIS script, never the
            # file's own allowed_routes -- otherwise emptying/removing allowed_routes switches off the only
            # route-legality check in the whole validator (RV brainstorm red-team #2). UNKNOWN is not a legal route.
            if ($script:CanonicalRoutes -notcontains $chosenRoute) {
                $errors.Add('analysis/BRAINSTORM-LOG.yaml 标记为 resolved，但 ROUTE-DECISION.yaml 的 chosen_route 仍是 UNKNOWN 或不是合法路线（必须是 SOURCE_AVAILABLE/RESOURCE_OVERLAY/BINARY_PATCH_RECORD/WRAPPER_LAUNCHER/REBUILD_REQUIRED 之一）——resolved 的头脑风暴必须选定一条合法路线，否则就是没决定')
            }
            # route_rationale must be genuinely settled: reject the whole project-wide unsettled sentinel set,
            # not just UNVERIFIED, or a resolved brainstorm with route_rationale: PENDING/TBD/... slips through
            # having decided nothing (RV brainstorm red-team #1). Same set the lifecycle table's unsettled_values uses.
            if ([string]::IsNullOrWhiteSpace($routeRationale) -or ($script:UnsettledScalars -contains $routeRationale.ToUpperInvariant())) {
                $errors.Add('analysis/BRAINSTORM-LOG.yaml 标记为 resolved，但 ROUTE-DECISION.yaml 的 route_rationale 仍是未决占位（UNVERIFIED/PENDING/UNKNOWN/DISCOVERY_PENDING/TBD 之一）或空——收尾必须写清为什么选这条、否掉别条的理由，讨论才算落地')
            }
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
    # Same canonical set as ROUTE-DECISION.chosen_route (single source of truth above), plus UNKNOWN which is a
    # legal MAINTENANCE-MODE value ("strategy not yet chosen") even though it is not a legal decided route.
    $allowedStrategies = @($script:CanonicalRoutes) + @('UNKNOWN')
    if (-not [string]::IsNullOrWhiteSpace($selectedStrategy) -and $allowedStrategies -notcontains $selectedStrategy) {
        $errors.Add('MAINTENANCE-MODE.yaml has an unknown selected_strategy')
    }
    # GAP-4 fidelity floor: a MODEL_ONLY / STUB / FIXTURE_ONLY core is a shell or a sample, never a
    # real product, so it must never satisfy real VERIFIED/RELEASED -- Codex counter-example C, an
    # empty model claiming to be a finished client. A wrapper that replays the original core is a
    # legitimate candidate (REPLAYED) and is intentionally NOT blocked here.
    $coreFidelity = Get-YamlScalar -Text $maintenanceText -Key 'core_fidelity'
    $allowedFidelity = @('OBSERVED', 'REPLAYED', 'RECONSTRUCTED', 'FIXTURE_ONLY', 'MODEL_ONLY', 'STUB', 'UNKNOWN')
    if (-not [string]::IsNullOrWhiteSpace($coreFidelity) -and $allowedFidelity -notcontains $coreFidelity) {
        $errors.Add('MAINTENANCE-MODE.yaml has an unknown core_fidelity')
    }
    if ($stateStatus -in @('VERIFIED', 'RELEASED')) {
        if (@('MODEL_ONLY', 'STUB', 'FIXTURE_ONLY') -contains $coreFidelity) {
            $errors.Add("real verified product cannot rest on a $coreFidelity core: MODEL_ONLY/STUB/FIXTURE_ONLY 是空壳或样例，不是真实成品")
        }
        elseif ([string]::IsNullOrWhiteSpace($coreFidelity) -or $coreFidelity -eq 'UNKNOWN') {
            $errors.Add('real verified product has not declared core_fidelity in MAINTENANCE-MODE.yaml (需为 OBSERVED/REPLAYED/RECONSTRUCTED 之一)')
        }
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

# RV-R2 opening (a): the honest ceiling of a static evidence gate. Every binding above proves a recorded
# hash matches a file on disk; none can prove that file was really produced by exercising/analysing THIS
# product rather than authored to match its own recorded hash. So a real VERIFIED/RELEASED is, by default,
# self-asserted -- and saying so out loud (EVIDENCE-TRUST, below) keeps a green light from reading as
# "independently proven". -RequireAttestation records a named human endorsing the current status in
# product-state/attestation/ATTESTATION.yaml. What this block can actually verify is only that the record
# is complete (a settled approved_by, the matching attested_status, an attested_at) -- it verifies no
# identity and no signature, and one made-up name defeats it. Labelling that "externally-attested" would
# be the exact over-claim the self-asserted line exists to prevent, so the label carries its own ceiling:
# a named endorsement whose identity is NOT verified.
Enter-CheckGroup 'attestation'
$attestationTrust = 'n/a'
if ($stateStatus -in @('VERIFIED', 'RELEASED')) {
    $attestationPath = Join-Path $stateRoot 'attestation/ATTESTATION.yaml'
    $attestationValid = $false
    $attestApprover = ''
    if (Test-Path -LiteralPath $attestationPath -PathType Leaf) {
        $attestText = Read-StateText -Path $attestationPath
        $attestApprover = (Get-YamlScalar -Text $attestText -Key 'approved_by').Trim()
        $attestStatus = (Get-YamlScalar -Text $attestText -Key 'attested_status').Trim()
        $attestAt = (Get-YamlScalar -Text $attestText -Key 'attested_at').Trim()
        $approverSettled = (-not [string]::IsNullOrWhiteSpace($attestApprover)) -and
            ($attestApprover -notin @('UNVERIFIED', 'PENDING', 'TBD', 'UNKNOWN', 'DISCOVERY_PENDING')) -and
            ($attestApprover -notmatch '__[A-Z0-9_]+__')
        if ($approverSettled -and ($attestStatus -eq $stateStatus) -and -not [string]::IsNullOrWhiteSpace($attestAt)) {
            $attestationValid = $true
        }
    }
    $attestationTrust = if ($attestationValid) { "named-attestation by $attestApprover (identity NOT verified)" } else { 'self-asserted' }
    if ($RequireAttestation -and -not $attestationValid) {
        $errors.Add("已要求人工背书(-RequireAttestation)，但缺少有效的 product-state/attestation/ATTESTATION.yaml：需要 approved_by(具名审核人)、attested_status=$stateStatus、attested_at 三项齐全——静态门挡不住哈希自洽的假证据，具名背书是把一个名字押在当前状态上；注意本工具只核对记录完整，不验证签名或身份")
    }
}

Enter-CheckGroup ''
foreach ($warning in $warnings) { Write-Output "WARN: $warning" }
foreach ($validationError in $errors) { Write-Output "ERROR: $validationError" }

# The single deterministic answer to "what do I do next". Without it, every agent re-derives the
# order from prose and two agents derive two different orders; that is exactly how a product ends
# up half-migrated. These lines are emitted in every state, including a failing one.
if ($null -ne $lifecycleReadiness) {
    # The scoreboard: the single honest distance-to-goal number, emitted in every state (known or in
    # repair). Computed from evidence, so an agent cannot self-award it; a narrow rung reads low.
    Write-Output "CURRENT-USER-TESTABILITY: $(Get-UserTestability -StateRoot $stateRoot -Status $stateStatus)"
}
# RV-R2 opening (a): name the trust level of a real VERIFIED/RELEASED so a green light never reads as
# "independently proven". self-asserted = the bound evidence is hash-consistent but self-produced (a static
# gate cannot prove it was really produced by exercising/analysing this product; a determined forger can
# author a hash-consistent fake). named-attestation = a complete ATTESTATION.yaml names a human endorsing
# this exact status; the record's completeness is checked, the person's identity/signature is NOT (a fake
# name produces the same record), and the label says so inline so it can never read as identity-verified.
if ($stateStatus -in @('VERIFIED', 'RELEASED')) {
    if ($attestationTrust -eq 'self-asserted') {
        Write-Output "EVIDENCE-TRUST: self-asserted — 绑定证据哈希自洽但由本流程自产，静态门无法证明它真的来自运行/分析本产品；更高保证需外部签名或具名人工背书（-RequireAttestation）"
    }
    else {
        Write-Output "EVIDENCE-TRUST: $attestationTrust — ATTESTATION.yaml 的具名背书记录完整且指向当前状态，但本静态门不验证签名或身份（一行假名即可写出同样的记录）；它比 self-asserted 多的只是一条具名承诺记录，不是身份核验，更高保证需要真实签名或可信执行"
    }
}
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
    # A long task drags when an agent keeps working a stage it has already finished. The moment a
    # stage is a clean, earned stopping point, say so out loud: record the checkpoint and move on,
    # rather than piling more onto a stage whose exit is already paid for. Emitted only when the
    # next rung is fully earned (Get-LifecycleReadiness.ReadyToAdvance), so it is a "you may stop
    # here" affordance, never a nag on an unfinished stage.
    if ($lifecycleReadiness.ReadyToAdvance) {
        Write-Output "READY-TO-ADVANCE: $($lifecycleReadiness.NextStatus) 需要的证据已经齐了——现在就用 update-product-state.ps1 推进到 $($lifecycleReadiness.NextStatus) 落一个检查点（可以收工、可以换人接手），不要停在本阶段继续加工。"
    }
}
elseif ($null -ne $lifecycleReadiness -and -not $lifecycleReadiness.Known) {
    # A status the lifecycle table does not know means STATE.yaml was hand-edited or a skipped step
    # left it polluted. The Known branch above then emits no NEXT at all, so an agent re-improvises
    # the order from prose -- the ISSUE-096 relapse where an unrecognized status left the entry with
    # no next step. Fail loud and machine-readable instead: name the one repair action and the legal
    # values, read from the table so this list can never drift from the source of truth.
    $legalStatuses = @((Get-LifecycleTable -TableFile $lifecycleFile).states | ForEach-Object { [string]$_.status })
    Write-Output ("STATE_REPAIR_REQUIRED: STATE.yaml 的 status=" + $lifecycleReadiness.Status + " 不在生命周期表里，先修状态再谈下一步")
    Write-Output "NEXT-STATUS: STATE_REPAIR"
    Write-Output "NEXT-ACTION: 用 update-product-state.ps1 把 status 改回下列合法值之一，再重新运行本检查（不要手改 STATE.yaml）"
    Write-Output ("BLOCKING-FACTS: status=" + $lifecycleReadiness.Status + "; 合法值=" + ($legalStatuses -join ', '))
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
