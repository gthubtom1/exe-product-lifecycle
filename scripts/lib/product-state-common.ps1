#requires -Version 5

<#
Shared product-state primitives for init-product.ps1, register-input-bundle.ps1,
update-product-state.ps1 and validate-product-state.ps1.

Dot-source it:

    . (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

Why this file exists: the same three fields (product_id, status, baseline_sha256) used to be
parsed by three hand-written regexes with three different notions of what valid YAML is. The
validator accepted `product_id: foo`; both writer scripts demanded `product_id: "foo"` and threw
a raw PowerShell stack trace at a user who is not supposed to know what YAML is. One reader, one
writer, one error shape.
#>

Set-StrictMode -Version Latest

# Captured at dot-source time: $PSScriptRoot is this file's directory, so the skill root stays
# correct no matter which script dot-sources it or from which working directory it runs.
$ProductStateSkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path

function Resolve-CanonicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Every containment check in this skill is a string prefix test, and Windows gives the same
    # directory two names: C:\Users\RUNNER~1\x and C:\Users\runneradmin\x. Resolve-Path keeps
    # whichever spelling it was handed, while enumeration hands back the long one, so a product
    # reached through a short path is reported as escaping its own directory and the relative
    # paths come out sliced mid-name. Fold every root to the long spelling before comparing.
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '~[0-9]') { return $full }
    $qualifier = [IO.Path]::GetPathRoot($full)
    $rest = $full.Substring($qualifier.Length).Trim('\')
    if ([string]::IsNullOrEmpty($rest)) { return $full }
    $current = $qualifier
    foreach ($segment in $rest.Split('\')) {
        # -Filter reaches FindFirstFile, which matches an 8.3 alias and returns the long name.
        $match = @(Get-ChildItem -LiteralPath $current -Force -Filter $segment -ErrorAction SilentlyContinue)
        if ($match.Count -eq 1) { $current = Join-Path $current $match[0].Name }
        else { $current = Join-Path $current $segment }
    }
    return $current
}

function Read-TextFileSafe {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Get-Content -Raw yields $null for a zero-byte file, and every regex downstream would then
    # throw under StrictMode. A truncated file is a finding to report, not a reason to crash.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
    if ($null -eq $text) { return '' }
    return $text
}

function Get-PropertyValue {
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)

    # Set-StrictMode turns a missing property into a terminating error, and every property read that
    # uses this is against a file a human may have edited or an older skill version may have written.
    # Reading such a file must degrade gracefully, never abort the run.
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function ConvertTo-BooleanValue {
    param($Value)

    # "False" read back from a hand-edited JSON is a non-empty string, and [bool] would call it true.
    if ($Value -is [string]) { return ($Value -match '^(?i)\s*true\s*$') }
    return [bool]$Value
}

function Get-YamlScalar {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key
    )

    # Reads a top-level scalar whether or not it is quoted, and with any trailing comment
    # removed. Requiring quotes is how the identity and simulation gates used to collapse:
    # `product_id: foo` and `simulation_only: true  # note` are both valid YAML, matched
    # nothing, and every comparison downstream then quietly compared against an empty string.
    $match = [regex]::Match($Text, ('(?m)^{0}:[ \t]*(.*?)[ \t\r]*$' -f [regex]::Escape($Key)))
    if (-not $match.Success) { return '' }
    $value = $match.Groups[1].Value
    if ($value.StartsWith('#')) { return '' }
    $value = ($value -replace '[ \t]+#.*$', '').Trim()
    if ($value.Length -ge 2) {
        $first = $value.Substring(0, 1)
        $last = $value.Substring($value.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }
    return $value.Trim()
}

function Get-IndentedYamlScalar {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key
    )

    # Like Get-YamlScalar but tolerates leading indentation, so a field one level under a block
    # (e.g. binding_strength.claimed_tier) can be read without a full nested parser. Safe only
    # because the keys it is used for are globally unique in the file; do not point it at a key
    # that also appears at top level.
    $match = [regex]::Match($Text, ('(?m)^[ \t]*{0}:[ \t]*(.*?)[ \t\r]*$' -f [regex]::Escape($Key)))
    if (-not $match.Success) { return '' }
    $value = $match.Groups[1].Value
    if ($value.StartsWith('#')) { return '' }
    $value = ($value -replace '[ \t]+#.*$', '').Trim()
    if ($value.Length -ge 2) {
        $first = $value.Substring(0, 1)
        $last = $value.Substring($value.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }
    return $value.Trim()
}

function Test-BindingStrengthEvidence {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$UnsettledValues,
        [string]$ProtectionVerdict = ''
    )

    # The whole point of tiered binding is to stop "claimed strong, proven nothing". A claimed
    # tier is only honoured when the evidence THAT tier needs is settled, and every tier must
    # spell out how it can be bypassed -- silence about the bypass is itself the failure.
    $isSettled = {
        param($value)
        $trimmed = ([string]$value).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { return $false }
        return ($UnsettledValues -notcontains $trimmed)
    }

    $claimed = (Get-IndentedYamlScalar -Text $Text -Key 'claimed_tier').ToUpperInvariant()
    if ($claimed -notin @('A', 'B', 'C')) { return $false }
    if (-not (& $isSettled (Get-IndentedYamlScalar -Text $Text -Key 'verified_tier'))) { return $false }
    if (-not (& $isSettled (Get-IndentedYamlScalar -Text $Text -Key 'bypass_risk'))) { return $false }

    $required = switch ($claimed) {
        'A' { @('evidence_a_server_issued_material', 'evidence_a_core_fails_without_material') }
        'B' { @('evidence_b_core_checkpoint_patched', 'evidence_b_launcher_injected_token') }
        'C' { @('evidence_c_wrapper_only_ack') }
    }
    foreach ($field in $required) {
        if (-not (& $isSettled (Get-IndentedYamlScalar -Text $Text -Key $field))) { return $false }
    }
    # Honesty ceiling: a claimed/verified tier must not exceed the binding the target can actually bear.
    # A settled protection_ceiling caps the tier (a contract that writes ceiling C yet claims A is exactly
    # the over-claim to reject), and a WRAPPER_ONLY protection verdict independently caps at C. Nothing here
    # can raise the ceiling. (RV auth-handoff F-AH-1/3.)
    $rank = @{ 'A' = 3; 'B' = 2; 'C' = 1 }
    $ceiling = 3
    $ceilingField = (Get-IndentedYamlScalar -Text $Text -Key 'protection_ceiling').Trim().ToUpperInvariant()
    if ($ceilingField -in @('A', 'B', 'C')) { $ceiling = [Math]::Min($ceiling, $rank[$ceilingField]) }
    if ($ProtectionVerdict -match '(?i)WRAPPER_ONLY') { $ceiling = [Math]::Min($ceiling, $rank['C']) }
    if ($rank[$claimed] -gt $ceiling) { return $false }
    $verifiedTier = (Get-IndentedYamlScalar -Text $Text -Key 'verified_tier').Trim().ToUpperInvariant()
    if (($verifiedTier -in @('A', 'B', 'C')) -and ($rank[$verifiedTier] -gt $ceiling)) { return $false }
    return $true
}

function ConvertTo-YamlScalar {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('\', '/').Replace('"', '\"') + '"'
}

function Set-YamlScalar {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    # Rewrites a top-level scalar in place, preserving the rest of the file byte for byte and the
    # original line ending. A key that is not present is appended, because a caller that asks to
    # set a field and gets silence back has no way to tell "written" from "quietly dropped".
    $replacement = ('{0}: {1}' -f $Key, (ConvertTo-YamlScalar $Value))
    $pattern = ('(?m)^{0}:[ \t]*.*?[ \t]*$' -f [regex]::Escape($Key))
    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, { param($m) $replacement }, 1)
    }
    $newline = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
    if (-not [string]::IsNullOrEmpty($Text) -and -not $Text.EndsWith("`n")) { $Text += $newline }
    return $Text + $replacement + $newline
}

function Set-YamlList {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowNull()][string[]]$Items
    )

    $newline = "`n"
    if ($Text -match "`r`n") { $newline = "`r`n" }
    $rendered = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Items -or @($Items).Count -eq 0) {
        [void]$rendered.Add(('{0}: []' -f $Key))
    }
    else {
        [void]$rendered.Add(('{0}:' -f $Key))
        foreach ($item in $Items) { [void]$rendered.Add('  - ' + (ConvertTo-YamlScalar $item)) }
    }
    $block = ($rendered -join $newline)

    $lines = $Text -split "`r?`n"
    $pattern = ('^{0}:[ \t]*(.*)$' -f [regex]::Escape($Key))
    $output = New-Object System.Collections.Generic.List[string]
    $replaced = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $match = [regex]::Match($lines[$i], $pattern)
        if (-not $match.Success -or $replaced) {
            [void]$output.Add($lines[$i])
            continue
        }
        [void]$output.Add($block)
        $replaced = $true
        # Swallow the previous list body so the old items do not survive underneath the new block.
        $inline = ($match.Groups[1].Value -replace '[ \t]+#.*$', '').Trim()
        if ([string]::IsNullOrWhiteSpace($inline)) {
            while ($i + 1 -lt $lines.Count) {
                $peek = $lines[$i + 1]
                if ([string]::IsNullOrWhiteSpace($peek)) { break }
                if ($peek -notmatch '^\s') { break }
                $i++
            }
        }
    }
    if (-not $replaced) {
        [void]$output.Add($block)
    }
    return ($output -join $newline)
}

function Write-FileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    # Set-Content truncates the destination before it writes, so an interruption leaves a
    # half-written file behind that the next run reads back as authoritative. Write a sibling temp
    # file and swap it in, so the previous content stays intact until the new one is complete.
    #
    # The swap must be File::Replace, not Move-Item -Force. Move-Item -Force is NOT a single
    # replace: FileSystemWatcher shows it emit "Deleted:<name>" and only then "Renamed:<name>",
    # i.e. there is a window in which the file does not exist at all. File::Replace emits
    # "Renamed:<backup>" then "Renamed:<name>" -- the destination name always resolves to a
    # complete file. Its third argument must be a real backup path: Windows PowerShell binds $null
    # to the [string] parameter as "" and the call then fails with "The path is not of a legal form."
    #
    # Encoding is deliberately UTF-8 *with* BOM plus a trailing newline, byte-for-byte what
    # Set-Content -Encoding utf8 produced under Windows PowerShell 5.1.
    $directory = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $stamp = [guid]::NewGuid().ToString('N')
    $temp = Join-Path $directory ('.{0}.tmp-{1}' -f $leaf, $stamp)
    $backup = Join-Path $directory ('.{0}.bak-{1}' -f $leaf, $stamp)
    try {
        [System.IO.File]::WriteAllText($temp, ($Content + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($true)))
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                if (Test-Path -LiteralPath $Path -PathType Leaf) {
                    [System.IO.File]::Replace($temp, $Path, $backup)
                }
                else {
                    [System.IO.File]::Move($temp, $Path)
                }
                break
            }
            catch {
                # A virus scanner, indexer or an editor holding the file open is transient.
                if ($attempt -ge 3) { throw }
                Start-Sleep -Milliseconds (150 * $attempt)
            }
        }
    }
    finally {
        foreach ($leftover in @($temp, $backup)) {
            if (Test-Path -LiteralPath $leftover -PathType Leaf) {
                Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-ProductStateField {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Key
    )

    return Get-YamlScalar -Text (Read-TextFileSafe -Path (Join-Path $StateRoot 'STATE.yaml')) -Key $Key
}

function Get-YamlListCount {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key
    )

    # Returns -1 when the key is absent, 0 for an explicitly empty list, otherwise the number of
    # list items found. "Key absent" and "key present but empty" are different findings: the first
    # means the file is not the one we think it is, the second means nobody filled it in yet.
    $lines = $Text -split "`r?`n"
    $pattern = ('^{0}:[ \t]*(.*)$' -f [regex]::Escape($Key))
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $match = [regex]::Match($lines[$i], $pattern)
        if (-not $match.Success) { continue }
        $inline = ($match.Groups[1].Value -replace '[ \t]+#.*$', '').Trim()
        if ($inline -eq '[]') { return 0 }
        if (-not [string]::IsNullOrWhiteSpace($inline)) { return 1 }
        $count = 0
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^\s*#') { continue }
            if ($line -notmatch '^\s') { break }
            if ($line -match '^\s+-\s') { $count++ }
        }
        return $count
    }
    return -1
}

function Get-LifecycleTableFileForTrack {
    param([AllowEmptyString()][string]$Track)

    # One place decides which lifecycle table a track uses, so the validator, the writer and the
    # readiness engine can never disagree. Source-reuse (Phase 2) products carry track: source and run
    # the source ladder; everything else (including a legacy product with no track field) uses the EXE
    # ladder. A single JSON name is returned, never a path, so callers stay SkillRoot-relative.
    if (([string]$Track).Trim().ToLowerInvariant() -eq 'source') { return 'lifecycle-states-source.json' }
    return 'lifecycle-states.json'
}

function Get-LifecycleTable {
    param([string]$SkillRoot, [string]$TableFile = 'lifecycle-states.json')

    if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = $ProductStateSkillRoot }
    if ([string]::IsNullOrWhiteSpace($TableFile)) { $TableFile = 'lifecycle-states.json' }
    $path = Join-Path $SkillRoot (Join-Path 'assets' $TableFile)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw (New-UserFacingError -Message "生命周期状态表缺失: $path" `
            -Hint '这个 Skill 的安装不完整，重新同步一次 Skill 文件。')
    }
    return (Read-TextFileSafe -Path $path | ConvertFrom-Json)
}

function Test-ProtectionSaysPacked {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    # Read a written PROTECTION-PROFILE.yaml and answer the one question the unpacking decision hangs on:
    # does the static evidence say this target is packed/encrypted. Mirrors Get-ModifiabilityVerdict's
    # isPacked signal -- a WRAPPER_ONLY verdict, a named packer, or high total entropy -- so the detector
    # and this gate cannot disagree about what "packed" means. Ambiguous reads as not-packed: the
    # six-category settlement gate already forces unpacking to be a real decision either way, and this rule
    # only exists to stop the specific "packed target, unpacking dodged as not_applicable" lie.
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ((Get-IndentedYamlScalar -Text $Text -Key 'verdict') -match '(?i)WRAPPER_ONLY') { return $true }
    $packer = (Get-IndentedYamlScalar -Text $Text -Key 'packer').Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($packer) -and $packer -notin @('none-detected', 'none', 'unknown', 'unverified')) { return $true }
    $entropyRaw = (Get-IndentedYamlScalar -Text $Text -Key 'entropy_total').Trim()
    $entropy = 0.0
    $entropyParsed = [double]::TryParse($entropyRaw, [ref]$entropy)
    if ($entropyParsed -and $entropy -gt 7.2) { return $true }
    # Fail-safe on insufficient evidence: a blind detector (no DIE -> verdict UNKNOWN, packer unknown,
    # entropy UNVERIFIED) must NOT read as "not packed", or the unpacking gate silently accepts
    # not_applicable on a possibly-packed target. Treat "could not assess" as "possibly packed" so the
    # unpacking decision stays a real done/blocked. A genuinely-assessed clean target has a real verdict
    # (OVERLAY_ONLY/CAN_PATCH), a named/none-detected packer and a parsed entropy, so it still reads
    # not-packed and is unaffected. (RV protections finding P-1 fail-open.)
    $verdict = (Get-IndentedYamlScalar -Text $Text -Key 'verdict').Trim().ToUpperInvariant()
    if ($verdict -in @('UNKNOWN', 'UNVERIFIED', 'PENDING', '')) { return $true }
    if (($packer -in @('unknown', 'unverified')) -and (-not $entropyParsed -or $entropyRaw -match '(?i)UNVERIFIED')) { return $true }
    return $false
}

function Get-YamlListRecords {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$ListKey
    )

    # Generic "list of maps" reader for a top-level block list (references:, capabilities:, ...). Returns one
    # hashtable of scalar fields per item, capturing both the "- field: value" opener and the item's
    # subsequent indented "field: value" lines; a nested list inside an item is ignored. The source
    # registration/learn gates use this to check each reference/capability field by field, not just count it.
    $stripValue = {
        param($v)
        $x = ([string]$v)
        if ($x.StartsWith('#')) { return '' }
        $x = ($x -replace '\s+#.*$', '').Trim()
        if ($x.Length -ge 2) {
            $first = $x.Substring(0, 1); $last = $x.Substring($x.Length - 1, 1)
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) { $x = $x.Substring(1, $x.Length - 2) }
        }
        return $x.Trim()
    }
    $records = New-Object System.Collections.Generic.List[hashtable]
    $inList = $false
    $listIndent = -1
    $current = $null
    foreach ($line in ($Text -split "`r?`n")) {
        $topKey = [regex]::Match($line, '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$')
        if ($topKey.Success) {
            if ($null -ne $current) { [void]$records.Add($current); $current = $null }
            if ($topKey.Groups[1].Value -eq $ListKey) {
                $inList = ($topKey.Groups[2].Value.Trim() -ne '[]')
                $listIndent = -1
            }
            else { $inList = $false }
            continue
        }
        if (-not $inList) { continue }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*#') { continue }
        $item = [regex]::Match($line, '^(\s*)-\s+(.*)$')
        if ($item.Success) {
            $indent = $item.Groups[1].Value.Length
            if ($listIndent -lt 0) { $listIndent = $indent }
            if ($indent -ne $listIndent) { continue }
            if ($null -ne $current) { [void]$records.Add($current) }
            $current = @{}
            $opener = [regex]::Match($item.Groups[2].Value, '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$')
            if ($opener.Success) { $current[$opener.Groups[1].Value] = (& $stripValue $opener.Groups[2].Value) }
            continue
        }
        if ($null -ne $current) {
            $field = [regex]::Match($line, '^\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$')
            if ($field.Success) { $current[$field.Groups[1].Value] = (& $stripValue $field.Groups[2].Value) }
        }
    }
    if ($null -ne $current) { [void]$records.Add($current) }
    return $records
}

function Test-LifecycleRequirement {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Requirement,
        [Parameter(Mandatory = $true)][string[]]$UnsettledValues
    )

    $kind = [string]$Requirement.kind
    $relative = if ($Requirement.PSObject.Properties.Name -contains 'path') { [string]$Requirement.path } else { '' }
    $full = if ([string]::IsNullOrWhiteSpace($relative)) { '' } else { Join-Path $StateRoot ($relative.Replace('/', '\')) }

    switch ($kind) {
        'file_present' {
            return (Test-Path -LiteralPath $full -PathType Leaf)
        }
        'yaml_settled' {
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
            $value = (Get-YamlScalar -Text (Read-TextFileSafe -Path $full) -Key ([string]$Requirement.key)).Trim()
            # A missing key is unsettled for the same reason a PENDING one is: nobody decided yet.
            # It is kept out of the table's value list because a Mandatory [string[]] parameter
            # refuses an empty element, and a silently dropped entry is a silently opened gate.
            if ([string]::IsNullOrWhiteSpace($value)) { return $false }
            return ($UnsettledValues -notcontains $value)
        }
        'yaml_list_not_empty' {
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
            return ((Get-YamlListCount -Text (Read-TextFileSafe -Path $full) -Key ([string]$Requirement.key)) -gt 0)
        }
        'text_contains_any' {
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
            $text = Read-TextFileSafe -Path $full
            foreach ($candidate in @($Requirement.values)) {
                if ($text -like ('*' + [string]$candidate + '*')) { return $true }
            }
            return $false
        }
        'state_no_blocking_items' {
            $statePath = Join-Path $StateRoot 'STATE.yaml'
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $false }
            return ((Get-YamlListCount -Text (Read-TextFileSafe -Path $statePath) -Key 'blocking_items') -le 0)
        }
        'binding_strength_backed' {
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
            $bsProtVerdict = ''
            $bsProtPath = Join-Path $StateRoot 'PROTECTION-PROFILE.yaml'
            if (Test-Path -LiteralPath $bsProtPath -PathType Leaf) { $bsProtVerdict = (Get-IndentedYamlScalar -Text (Read-TextFileSafe -Path $bsProtPath) -Key 'verdict') }
            return (Test-BindingStrengthEvidence -Text (Read-TextFileSafe -Path $full) -UnsettledValues $UnsettledValues -ProtectionVerdict $bsProtVerdict)
        }
        'list_records_have_fields' {
            # (Phase 2 source gates) A block list under $Requirement.key must be non-empty AND every item
            # must carry each field in $Requirement.fields, settled. references_registered: url/commit/license
            # (缺任一或空登记判失败 -> 来源可追溯). capabilities_mapped: self_implementation/reference_ids
            # (学写法而非整包搬运 -> 每个能力都要写清自己怎么实现、参考了谁). Fails closed on a missing file.
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
            $records = @(Get-YamlListRecords -Text (Read-TextFileSafe -Path $full) -ListKey ([string]$Requirement.key))
            if ($records.Count -eq 0) { return $false }
            $isSettled = {
                param($value)
                $trimmed = ([string]$value).Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { return $false }
                return ($UnsettledValues -notcontains $trimmed)
            }
            foreach ($record in $records) {
                foreach ($field in @($Requirement.fields)) {
                    $fieldName = [string]$field
                    if (-not $record.ContainsKey($fieldName)) { return $false }
                    if (-not (& $isSettled $record[$fieldName])) { return $false }
                }
            }
            return $true
        }
        'unpacking_consistent_with_protection' {
            # (opening c) Unpacking must be an ACTION decision, not just a detector probe. When the
            # protection profile says the target is packed/high-entropy, ANALYSIS-FINDINGS.unpacking cannot
            # be not_applicable (nor left unsettled): it has to be done (unpacked/dumped, evidence saved) or
            # blocked (tried, couldn't). A not-packed target may legitimately mark it not_applicable, so the
            # gate is silent there -- that is the mutation guard against a rule stuck always-firing.
            $findingsFull = Join-Path $StateRoot 'analysis\ANALYSIS-FINDINGS.yaml'
            if (-not (Test-Path -LiteralPath $findingsFull -PathType Leaf)) { return $false }
            $protectionFull = Join-Path $StateRoot 'PROTECTION-PROFILE.yaml'
            $packed = $false
            if (Test-Path -LiteralPath $protectionFull -PathType Leaf) {
                $packed = Test-ProtectionSaysPacked -Text (Read-TextFileSafe -Path $protectionFull)
            }
            if (-not $packed) { return $true }
            $unpacking = (Get-YamlScalar -Text (Read-TextFileSafe -Path $findingsFull) -Key 'unpacking').Trim().ToLowerInvariant()
            return ($unpacking -in @('done', 'blocked'))
        }
        default {
            # An unknown check kind must fail closed. Returning "satisfied" for a rule nobody
            # implemented is how a gate quietly stops being a gate.
            return $false
        }
    }
}

function Get-LifecycleReadiness {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Status,
        [string]$SkillRoot,
        [string]$TableFile = 'lifecycle-states.json'
    )

    $table = Get-LifecycleTable -SkillRoot $SkillRoot -TableFile $TableFile
    $unsettled = @($table.unsettled_values | ForEach-Object { [string]$_ })
    $states = @($table.states)
    $current = @($states | Where-Object { [string]$_.status -eq $Status }) | Select-Object -First 1

    $unmet = New-Object System.Collections.Generic.List[object]
    if ($null -ne $current -and $null -ne $current.order) {
        # Cumulative by design: claiming a rung of the ladder claims every rung below it. Checking
        # only the declared status is what let a brand-new product jump straight to BUILD_READY.
        $reached = @($states | Where-Object { $null -ne $_.order -and [int]$_.order -le [int]$current.order })
        foreach ($state in ($reached | Sort-Object { [int]$_.order })) {
            foreach ($requirement in @($state.requires)) {
                if (-not (Test-LifecycleRequirement -StateRoot $StateRoot -Requirement $requirement -UnsettledValues $unsettled)) {
                    [void]$unmet.Add([pscustomobject]@{
                        RequiredBy = [string]$state.status
                        Why = [string]$requirement.why
                        Detail = ('{0} / {1}' -f [string]$requirement.kind, [string]$requirement.path)
                    })
                }
            }
        }
    }

    $next = $null
    if ($null -ne $current -and -not [string]::IsNullOrWhiteSpace([string]$current.next_status)) {
        $next = @($states | Where-Object { [string]$_.status -eq [string]$current.next_status }) | Select-Object -First 1
    }

    $pendingForNext = New-Object System.Collections.Generic.List[object]
    if ($null -ne $next) {
        foreach ($requirement in @($next.requires)) {
            if (-not (Test-LifecycleRequirement -StateRoot $StateRoot -Requirement $requirement -UnsettledValues $unsettled)) {
                [void]$pendingForNext.Add([pscustomobject]@{
                    RequiredBy = [string]$next.status
                    Why = [string]$requirement.why
                    Detail = ('{0} / {1}' -f [string]$requirement.kind, [string]$requirement.path)
                })
            }
        }
    }

    $meaning = ''
    $nextStatus = ''
    $nextAction = ''
    if ($null -ne $current) {
        $meaning = [string]$current.meaning
        $nextStatus = [string]$current.next_status
        $nextAction = [string]$current.next_action
    }

    # ToArray() rather than @($list): under Windows PowerShell 5.1, wrapping an *empty* generic
    # List in @() inside a [pscustomobject] literal throws "Argument types do not match". The
    # happy path -- a product with nothing unmet -- was the only path that hit it, so the gate
    # aborted precisely when it had nothing to report.
    $unmetItems = [object[]]$unmet.ToArray()
    $pendingItems = [object[]]$pendingForNext.ToArray()

    # "This stage is a clean stopping point you have already earned the exit from." True only when
    # there is a next rung to climb ($next), the current status is fully backed (nothing unmet) and
    # everything the next rung needs is already present (nothing pending). It is the anti-drag
    # signal: the moment a stage is complete the tooling can say "land it and move on" instead of
    # letting an agent keep piling work onto a stage that is already done. A terminal or branch
    # state has no $next, so it is never reported ready-to-advance.
    $readyToAdvance = ($null -ne $next) -and ($unmetItems.Count -eq 0) -and ($pendingItems.Count -eq 0)

    return [pscustomobject]@{
        Known = ($null -ne $current)
        Status = $Status
        Meaning = $meaning
        NextStatus = $nextStatus
        NextAction = $nextAction
        Unmet = $unmetItems
        PendingForNext = $pendingItems
        ReadyToAdvance = $readyToAdvance
    }
}

function Get-UserTestability {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Status
    )

    # One honest distance-to-goal number, computed from evidence on disk and never self-declared, so a
    # status that merely looks close (BUILD_READY) still reads 'slice-defined', not 'user-testable': a
    # narrow rung can never masquerade as the wide goal of "user can install, authorize, operate,
    # observe and cancel/rollback a rebuild that matches the original".
    $unsettled = @('PENDING', 'UNVERIFIED', 'UNKNOWN', 'DISCOVERY_PENDING', 'TBD')
    $settled = {
        param($value)
        $trimmed = ([string]$value).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { return $false }
        return ($unsettled -notcontains $trimmed)
    }
    if ($Status -eq 'RELEASED') { return 'verified' }
    $fidelity = (Get-YamlScalar -Text (Read-TextFileSafe -Path (Join-Path $StateRoot 'MAINTENANCE-MODE.yaml')) -Key 'core_fidelity').Trim()
    if ($Status -eq 'VERIFIED' -and (@('OBSERVED', 'REPLAYED', 'RECONSTRUCTED') -contains $fidelity)) { return 'user-testable' }
    if ($Status -eq 'VERIFIED_SIMULATION') { return 'slice-built' }
    $route = Get-YamlScalar -Text (Read-TextFileSafe -Path (Join-Path $StateRoot 'analysis\ROUTE-DECISION.yaml')) -Key 'chosen_route'
    $slice = Get-YamlScalar -Text (Read-TextFileSafe -Path (Join-Path $StateRoot 'analysis\USER-TESTABLE-SLICE.yaml')) -Key 'slice_status'
    if ((& $settled $route) -and (& $settled $slice)) { return 'slice-defined' }
    return 'none'
}

function New-UserFacingError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Hint
    )

    # The audience of this skill is explicitly a user who does not know PowerShell. A message
    # they cannot act on is the same as no message, so a hint is part of the contract, not decoration.
    if ([string]::IsNullOrWhiteSpace($Hint)) { return $Message }
    return ($Message + [Environment]::NewLine + '怎么办: ' + $Hint)
}

function Write-UserFacingFailure {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [AllowNull()]$ErrorRecord
    )

    # Emitted from a trap, so it replaces the PowerShell stack trace rather than accompanying it.
    # One compact location line survives: swallowing it entirely made an unexpected internal fault
    # indistinguishable from an expected refusal, and left a maintainer with nothing to grep for.
    Write-Output ('错误: ' + $Message)
    $where = ''
    if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.InvocationInfo) {
        $where = ' 第 ' + [string]$ErrorRecord.InvocationInfo.ScriptLineNumber + ' 行'
    }
    Write-Output ('出错脚本: ' + $ScriptName + $where + '（这一步没有修改任何文件，可以修正后重跑）')
}

function Get-ModifiabilityVerdict {
    param(
        [string]$Packer = 'unknown',
        [double]$EntropyTotal = 0.0,
        [bool]$StatusSaysPacked = $false,
        [string]$AntiDebug = 'unknown',
        [string]$SelfCheck = 'unknown',
        [string]$CodeSigning = 'unknown',
        [string]$FileFormat = 'UNVERIFIED',
        [string]$LanguageFramework = 'UNVERIFIED'
    )

    # The one decision the whole maintenance strategy hangs on: given the static evidence, can the
    # target be patched, only wrapped, or nothing yet. It lives here as a pure function -- no file,
    # no DIE, no target execution -- so every branch can be pinned by a test that fires when the
    # branch is broken. Detecting protections but leaving the verdict untested is how a packed
    # binary silently gets a "just patch it" strategy. Conservative on purpose: protection earns
    # wrapping by default, and patching has to be earned by the absence of protection, never assumed.
    $entropyHigh = ($EntropyTotal -gt 7.2)
    $isPacked = ($Packer -notin @('none-detected', 'none', 'unknown', '')) -or $entropyHigh -or $StatusSaysPacked
    if ($isPacked) {
        return [pscustomobject]@{
            Verdict = 'WRAPPER_ONLY'
            Reason = '目标被加壳或高度加密，脱壳前看不到也改不动真实代码；默认只做外壳包裹，脱壳后另行评估。'
            Hardening = 'no'
        }
    }
    if ($AntiDebug -eq 'yes' -or $SelfCheck -eq 'yes') {
        return [pscustomobject]@{
            Verdict = 'OVERLAY_ONLY'
            Reason = '存在反调试或自校验迹象，直接改字节可能被程序自己发现而拒绝运行；优先资源覆盖与外壳，改字节需先确认校验范围。'
            Hardening = 'unknown'
        }
    }
    if ($CodeSigning -eq 'signed') {
        return [pscustomobject]@{
            Verdict = 'OVERLAY_ONLY'
            Reason = '目标有数字签名，改字节会使签名失效；优先资源覆盖与外壳，必须改核心时单独评估签名处置。'
            Hardening = 'unknown'
        }
    }
    if ($FileFormat -match '(?i)\.NET' -or $LanguageFramework -match '(?i)\.NET|C#|VB\.NET') {
        return [pscustomobject]@{
            Verdict = 'CAN_PATCH'
            Reason = '.NET 托管程序，可用 dnSpy/ILSpy 反编译并在 IL 层修改；仍需在测试环境验证。'
            Hardening = 'yes'
        }
    }
    if ($Packer -eq 'none-detected' -and $AntiDebug -eq 'no') {
        return [pscustomobject]@{
            Verdict = 'CAN_PATCH'
            Reason = '未发现加壳、反调试或签名阻碍，具备直接二进制补丁的条件；具体改动仍需在测试环境逐条验证。'
            Hardening = 'yes'
        }
    }
    return [pscustomobject]@{
        Verdict = 'UNKNOWN'
        Reason = '证据不足以判定可改性，需要人工用反汇编工具进一步确认后再定策略。'
        Hardening = 'unknown'
    }
}
