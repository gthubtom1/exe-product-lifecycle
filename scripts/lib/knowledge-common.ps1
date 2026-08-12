#requires -Version 5

Set-StrictMode -Version Latest

$script:KnowledgeCategories = @('intake', 'packaging', 'runtime', 'ui', 'authorization', 'update', 'migration', 'tooling', 'release')
$script:EvidenceLevels = @('static_present', 'entrypoint_present', 'locally_exercised', 'dynamic_success', 'failure_observed')

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "JSON file not found: $Path" }
    try { return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json }
    catch { throw "Invalid JSON: $Path`n$($_.Exception.Message)" }
}

function ConvertTo-CanonicalJsonString {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($char in $Value.ToCharArray()) {
        $code = [int]$char
        if ($char -eq '"') { [void]$builder.Append('\"') }
        elseif ($char -eq '\') { [void]$builder.Append('\\') }
        elseif ($code -eq 8) { [void]$builder.Append('\b') }
        elseif ($code -eq 9) { [void]$builder.Append('\t') }
        elseif ($code -eq 10) { [void]$builder.Append('\n') }
        elseif ($code -eq 12) { [void]$builder.Append('\f') }
        elseif ($code -eq 13) { [void]$builder.Append('\r') }
        elseif ($code -lt 32) { [void]$builder.Append(('\u{0:x4}' -f $code)) }
        else { [void]$builder.Append($char) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-CanonicalJson {
    param($Value, [int]$Depth = 0)

    # ConvertTo-Json is not the same function on both hosts: Windows PowerShell 5.1 emits
    # `"key":  1` with a four-space indent, PowerShell 7 emits `"key": 1` with two. The knowledge
    # index is a committed generated file, so whichever host regenerates it rewrites every byte and
    # the "generated files are committed" gate can never pass on the other one. Emit the bytes here
    # instead of asking the host to, so the same input is the same file everywhere.
    $pad = ' ' * (2 * $Depth)
    $padInner = ' ' * (2 * ($Depth + 1))
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return (ConvertTo-CanonicalJsonString -Value $Value) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) {
        return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return $Value.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys)
        if ($keys.Count -eq 0) { return '{}' }
        $parts = @(foreach ($key in $keys) {
                $padInner + (ConvertTo-CanonicalJsonString -Value ([string]$key)) + ': ' + (ConvertTo-CanonicalJson -Value $Value[$key] -Depth ($Depth + 1))
            })
        return "{`n" + ($parts -join ",`n") + "`n" + $pad + '}'
    }
    if ($Value -is [psobject] -and -not ($Value -is [System.Collections.IEnumerable])) {
        $properties = @($Value.PSObject.Properties)
        if ($properties.Count -eq 0) { return '{}' }
        $parts = @(foreach ($property in $properties) {
                $padInner + (ConvertTo-CanonicalJsonString -Value $property.Name) + ': ' + (ConvertTo-CanonicalJson -Value $property.Value -Depth ($Depth + 1))
            })
        return "{`n" + ($parts -join ",`n") + "`n" + $pad + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = @(foreach ($item in $items) { $padInner + (ConvertTo-CanonicalJson -Value $item -Depth ($Depth + 1)) })
        return "[`n" + ($parts -join ",`n") + "`n" + $pad + ']'
    }
    return (ConvertTo-CanonicalJsonString -Value ([string]$Value))
}

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $json = (ConvertTo-CanonicalJson -Value $Value) + "`n"
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = $temporary + '.bak'
            try { [System.IO.File]::Replace($temporary, $Path, $backup, $true) }
            catch { Move-Item -LiteralPath $temporary -Destination $Path -Force }
            if (Test-Path -LiteralPath $backup -PathType Leaf) { Remove-Item -LiteralPath $backup -Force }
        }
        else { Move-Item -LiteralPath $temporary -Destination $Path }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-IsoTimestamp { return [DateTimeOffset]::UtcNow.ToString('o') }

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-StringSha256 {
    param([Parameter(Mandatory = $true)][string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally { $sha.Dispose() }
}

function Get-ArtifactKind {
    param([Parameter(Mandatory = $true)][string]$Path)
    $extension = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($extension)) { return 'file' }
    if ($extension -notmatch '^[a-z0-9]{1,16}$') { return 'file' }
    return $extension
}

function Get-KnowledgeRoot {
    param([Parameter(Mandatory = $true)][string]$SkillRoot)
    $resolved = (Resolve-Path -LiteralPath $SkillRoot).Path
    $knowledge = Join-Path $resolved 'knowledge'
    if (-not (Test-Path -LiteralPath $knowledge -PathType Container)) { throw "Knowledge root not found: $knowledge" }
    return $knowledge
}

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    if ($resolvedPath -ne $resolvedRoot -and -not $resolvedPath.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the allowed root: $resolvedPath"
    }
    return $resolvedPath
}

function Get-PublicContentFindings {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string[]]$PrivateTerms = @()
    )
    $findings = New-Object System.Collections.Generic.List[string]
    $patterns = [ordered]@{
        'windows_absolute_path' = '(?i)(?:^|[\s"''])(?:[a-z]:\\|\\\\)[^\s"'']+'
        'url' = '(?i)\b(?:https?|wss?|ftp)://[^\s"'']+'
        'domain_name' = '(?i)\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:com|net|org|cn|io|dev|app|cloud|top|xyz)\b'
        'email' = '(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b'
        'ipv4' = '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])'
        'ipv6' = '(?i)(?<![a-f0-9:])(?=[a-f0-9:]*[a-f])(?:[a-f0-9]{1,4}:){2,7}[a-f0-9]{1,4}(?![a-f0-9:])'
        'unix_absolute_path' = '(?i)(?:^|[\s"''])/(?:home|users|var|tmp|etc|opt|srv)/[^\s"'']+'
        'phone_number' = '(?<![0-9])(?:1[3-9][0-9]{9}|\+[0-9]{1,3}[ -](?:[0-9][ -]?){7,13}|(?:[0-9]{3,4}[- ][0-9]{6,8}))(?![0-9])'
        'jwt' = '\beyJ[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,}\b'
        'github_token' = '\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b'
        'connection_string' = '(?i)\b(?:server|data source|host)\s*=.+(?:password|pwd)\s*='
        'token_query' = '(?i)[?&](?:token|key|secret|signature|sig|auth)=[^&\s"'']+'
        'device_identifier' = '(?i)\b(?:machine_id|device_id|hardware_id|hwid)\s*[:=]\s*["'']?(?!PLACEHOLDER|REDACTED)[^\s,"'']{4,}'
        'artifact_hash' = '(?i)(?<![a-f0-9])[a-f0-9]{64}(?![a-f0-9])'
        'binary_offset' = '(?i)\b0x[a-f0-9]{6,16}\b'
        'license_serial' = '(?i)\b[a-z0-9]{4,8}(?:-[a-z0-9]{4,8}){2,5}\b'
        'prompt_injection' = '(?i)\b(?:ignore|disregard)\s+(?:all\s+)?(?:previous|prior)\s+instructions\b'
        'private_key' = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
        'access_key' = '\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'
        'bearer_token' = '(?i)\bbearer\s+[a-z0-9._~+/-]{16,}={0,2}'
        'credential_assignment' = '(?i)\b(?:password|passwd|client_secret|admin_token|private_key|license_key)\s*[:=]\s*["'']?(?!UNVERIFIED|REDACTED|PLACEHOLDER)[^\s,"'']{4,}'
    }
    foreach ($entry in $patterns.GetEnumerator()) {
        if ([regex]::IsMatch($Text, $entry.Value)) { [void]$findings.Add($entry.Key) }
    }
    foreach ($term in @($PrivateTerms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Length -ge 3 })) {
        if ($Text.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            [void]$findings.Add('private_term_detected')
        }
    }
    return @($findings | Select-Object -Unique)
}

function Test-StringArray {
    param($Value, [int]$Minimum = 1)
    $items = @($Value)
    if ($items.Count -lt $Minimum) { return $false }
    foreach ($item in $items) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) { return $false }
    }
    return $true
}

function Add-UnknownPropertyErrors {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)]$Errors
    )
    foreach ($property in $Value.PSObject.Properties.Name) {
        if ($property -notin $Allowed) { [void]$Errors.Add("unknown field: $Prefix.$property") }
    }
}

function Get-ExperiencePublicText {
    param([Parameter(Mandatory = $true)]$Record)
    $content = [ordered]@{
        title = [string]$Record.title
        summary = [string]$Record.summary
        category = [string]$Record.category
        tags = @($Record.tags)
        pattern = $Record.pattern
        reviews = @($Record.reviews | ForEach-Object { [ordered]@{ reviewer = $_.reviewer; notes = $_.notes } })
    }
    if ($Record.PSObject.Properties.Name -contains 'promotion') {
        $content.promotion = [ordered]@{ promoted_by = $Record.promotion.promoted_by }
    }
    if ($Record.PSObject.Properties.Name -contains 'deprecation') {
        $content.deprecation = [ordered]@{ deprecated_by = $Record.deprecation.deprecated_by; reason = $Record.deprecation.reason }
    }
    return ($content | ConvertTo-Json -Depth 20)
}

function Test-ExperienceRecord {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][ValidateSet('candidate', 'verified', 'deprecated')][string]$ExpectedStatus
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $required = @('schema_version', 'record_type', 'experience_id', 'status', 'created_at', 'updated_at', 'payload_sha256', 'title', 'summary', 'category', 'tags', 'source_evidence', 'pattern', 'sanitization', 'reviews')
    foreach ($name in $required) {
        if ($Record.PSObject.Properties.Name -notcontains $name) { [void]$errors.Add("missing field: $name") }
    }
    if ($errors.Count -gt 0) { return @($errors) }
    if ([int]$Record.schema_version -ne 1) { [void]$errors.Add('schema_version must be 1') }
    if ([string]$Record.status -ne $ExpectedStatus) { [void]$errors.Add("status must be $ExpectedStatus") }
    $expectedType = if ($ExpectedStatus -eq 'candidate') { 'experience_candidate' } else { 'shared_pattern' }
    if ([string]$Record.record_type -ne $expectedType) { [void]$errors.Add("record_type must be $expectedType") }
    if ([string]$Record.experience_id -notmatch '^exp-[a-f0-9]{32}$') { [void]$errors.Add('experience_id format is invalid') }
    if ([string]$Record.payload_sha256 -notmatch '^[A-F0-9]{64}$') { [void]$errors.Add('payload_sha256 format is invalid') }
    if ([string]$Record.category -notin $script:KnowledgeCategories) { [void]$errors.Add('category is invalid') }
    if (-not (Test-StringArray $Record.tags)) { [void]$errors.Add('tags must contain strings') }
    foreach ($tag in @($Record.tags)) {
        if ([string]$tag -notmatch '^[a-z0-9][a-z0-9._-]{1,31}$') { [void]$errors.Add("invalid tag: $tag") }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Record.title) -or ([string]$Record.title).Length -gt 120) { [void]$errors.Add('title is empty or too long') }
    if ([string]::IsNullOrWhiteSpace([string]$Record.summary) -or ([string]$Record.summary).Length -gt 500) { [void]$errors.Add('summary is empty or too long') }

    $patternFields = @('applicability', 'detection', 'negative_indicators', 'procedure', 'verification', 'rollback', 'failure_signals', 'stop_conditions', 'limitations')
    Add-UnknownPropertyErrors -Value $Record.pattern -Allowed $patternFields -Prefix 'pattern' -Errors $errors
    foreach ($field in $patternFields) {
        if ($Record.pattern.PSObject.Properties.Name -notcontains $field -or -not (Test-StringArray $Record.pattern.$field)) {
            [void]$errors.Add("pattern.$field must contain strings")
        }
    }

    $evidence = @($Record.source_evidence)
    if ($evidence.Count -lt 1) { [void]$errors.Add('source_evidence is empty') }
    foreach ($item in $evidence) {
        Add-UnknownPropertyErrors -Value $item -Allowed @('source_id', 'source_kind', 'evidence_role', 'artifact_kind', 'evidence_proof_id', 'evidence_level') -Prefix 'source_evidence' -Errors $errors
        if ([string]$item.source_id -notmatch '^src-[a-f0-9]{32}$') { [void]$errors.Add('source_id format is invalid') }
        if ([string]$item.source_kind -notin @('real_product', 'fixture')) { [void]$errors.Add('source_kind is invalid') }
        if ([string]$item.evidence_proof_id -notmatch '^proof-[a-f0-9]{32}$') { [void]$errors.Add('evidence_proof_id is invalid') }
        if ([string]$item.evidence_role -notin @('supporting', 'positive_fixture', 'negative_fixture')) { [void]$errors.Add('evidence_role is invalid') }
        if ([string]$item.evidence_level -notin $script:EvidenceLevels) { [void]$errors.Add('evidence_level is invalid') }
        if ([string]$item.artifact_kind -notmatch '^[a-z0-9._-]{2,40}$') { [void]$errors.Add('artifact_kind is invalid') }
    }

    if ($Record.sanitization.PSObject.Properties.Name -notcontains 'automatic_scan' -or [string]$Record.sanitization.automatic_scan -notin @('passed', 'failed')) { [void]$errors.Add('sanitization.automatic_scan is invalid') }
    if ($Record.sanitization.PSObject.Properties.Name -notcontains 'reviewed_status' -or [string]$Record.sanitization.reviewed_status -notin @('pending', 'approved', 'rejected')) { [void]$errors.Add('sanitization.reviewed_status is invalid') }
    Add-UnknownPropertyErrors -Value $Record.sanitization -Allowed @('automatic_scan', 'reviewed_status', 'scan_version', 'checked_at', 'payload_sha256', 'findings') -Prefix 'sanitization' -Errors $errors
    if ([string]$Record.sanitization.payload_sha256 -notmatch '^[A-F0-9]{64}$') { [void]$errors.Add('sanitization.payload_sha256 is invalid') }
    foreach ($review in @($Record.reviews)) {
        Add-UnknownPropertyErrors -Value $review -Allowed @('reviewer', 'decision', 'reviewed_at', 'payload_sha256', 'notes') -Prefix 'reviews' -Errors $errors
        if ([string]$review.payload_sha256 -notmatch '^[A-F0-9]{64}$') { [void]$errors.Add('review payload_sha256 is invalid') }
    }

    if ($ExpectedStatus -ne 'candidate') {
        if ($Record.PSObject.Properties.Name -notcontains 'promotion') { [void]$errors.Add('verified/deprecated pattern has no promotion record') }
        else { Add-UnknownPropertyErrors -Value $Record.promotion -Allowed @('promoted_at', 'promoted_by', 'evidence_rule', 'candidate_sha256', 'payload_sha256') -Prefix 'promotion' -Errors $errors }
        if ([string]$Record.sanitization.reviewed_status -ne 'approved') { [void]$errors.Add('shared pattern sanitization is not approved') }
        if (@($Record.reviews | Where-Object { $_.decision -eq 'approve' -and $_.payload_sha256 -eq $Record.payload_sha256 }).Count -lt 1) { [void]$errors.Add('shared pattern has no approving review for the current payload') }
    }
    if ($ExpectedStatus -eq 'deprecated' -and $Record.PSObject.Properties.Name -notcontains 'deprecation') { [void]$errors.Add('deprecated pattern has no deprecation record') }
    elseif ($ExpectedStatus -eq 'deprecated') { Add-UnknownPropertyErrors -Value $Record.deprecation -Allowed @('deprecated_at', 'deprecated_by', 'reason', 'replacement_id') -Prefix 'deprecation' -Errors $errors }
    return @($errors | Select-Object -Unique)
}

function Get-ExperiencePayloadHash {
    param([Parameter(Mandatory = $true)]$Record)
    # Normalize dictionaries and single-item arrays through JSON so Windows PowerShell
    # and PowerShell 7 hash the same logical payload after a file round trip.
    $normalized = ($Record | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $evidence = @($normalized.source_evidence | Sort-Object source_id, evidence_role, evidence_proof_id | ForEach-Object {
        [ordered]@{
            source_id = [string]$_.source_id
            source_kind = [string]$_.source_kind
            evidence_role = [string]$_.evidence_role
            artifact_kind = [string]$_.artifact_kind
            evidence_proof_id = [string]$_.evidence_proof_id
            evidence_level = [string]$_.evidence_level
        }
    })
    $payload = [ordered]@{
        title = [string]$normalized.title
        summary = [string]$normalized.summary
        category = [string]$normalized.category
        tags = @($normalized.tags | Sort-Object)
        source_evidence = $evidence
        pattern = $normalized.pattern
    }
    # ConvertTo-Json is host-dependent for non-ASCII: Windows PowerShell 5.1 escapes CJK as \uXXXX,
    # PowerShell 7 emits it raw. So a record whose payload carried Chinese hashed to one value on the
    # host that wrote it and a different value on the host that re-validated it -- green on 5.1, a
    # "payload hash mismatch" on the pwsh 7 lane. ConvertTo-CanonicalJson emits the same bytes on
    # both hosts (the guarantee the knowledge index already leans on), so the payload hash is
    # reproducible across hosts regardless of the language in the record.
    $json = ConvertTo-CanonicalJson -Value $payload
    return Get-StringSha256 -Value $json
}

function Enter-KnowledgeWriteLock {
    param([Parameter(Mandatory = $true)][string]$KnowledgeRoot)
    $lockPath = Join-Path $KnowledgeRoot '.knowledge-write.lock'
    try {
        return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch { throw "Knowledge repository is being modified by another process: $lockPath" }
}

function Update-KnowledgeIndex {
    param(
        [Parameter(Mandatory = $true)][string]$SkillRoot,
        [string]$SkillVersion = '0.2.0'
    )
    $root = (Resolve-Path -LiteralPath $SkillRoot).Path.TrimEnd('\')
    $knowledge = Get-KnowledgeRoot -SkillRoot $root
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($status in @('candidate', 'verified', 'deprecated')) {
        $folderName = if ($status -eq 'candidate') { 'candidates' } else { $status }
        $folder = Join-Path $knowledge $folderName
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $record = Read-JsonFile -Path $file.FullName
            [void]$entries.Add([ordered]@{
                experience_id = [string]$record.experience_id
                status = [string]$record.status
                category = [string]$record.category
                title = [string]$record.title
                tags = @($record.tags)
                path = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
                sha256 = Get-Sha256 -Path $file.FullName
                updated_at = [string]$record.updated_at
            })
        }
    }
    $sorted = @($entries | Sort-Object experience_id)
    $stableTime = '1970-01-01T00:00:00.0000000+00:00'
    if ($sorted.Count -gt 0) {
        $stableTime = [string](@($sorted | Sort-Object updated_at -Descending | Select-Object -First 1)[0].updated_at)
    }
    $index = [ordered]@{
        schema_version = 1
        skill_version = $SkillVersion
        generated_at = $stableTime
        entries = $sorted
    }
    Write-Utf8Json -Value $index -Path (Join-Path $knowledge 'INDEX.json')
    $lock = [ordered]@{
        schema_version = 1
        skill_version = $SkillVersion
        records = @($sorted | ForEach-Object { [ordered]@{ path = $_.path; sha256 = $_.sha256 } })
    }
    Write-Utf8Json -Value $lock -Path (Join-Path $knowledge 'knowledge.lock.json')
}

function Get-ProductIdentity {
    param([Parameter(Mandatory = $true)][string]$ProductRoot)
    $root = (Resolve-Path -LiteralPath $ProductRoot).Path
    $statePath = Join-Path $root 'product-state\STATE.yaml'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw "Product state not found: $statePath" }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath
    $id = [regex]::Match($text, '(?m)^product_id:\s*["'']?([^"''\r\n]+)')
    $name = [regex]::Match($text, '(?m)^product_name:\s*["'']?([^"''\r\n]+)')
    $status = [regex]::Match($text, '(?m)^status:\s*["'']?([^"''\s]+)')
    $corePath = [regex]::Match($text, '(?m)^core_path:\s*["'']?([^"''\r\n]+)')
    if (-not $id.Success -or -not $status.Success) { throw 'STATE.yaml has no product_id or status' }
    return [pscustomobject]@{
        Root = $root
        StateRoot = Join-Path $root 'product-state'
        ProductId = $id.Groups[1].Value.Trim()
        ProductName = if ($name.Success) { $name.Groups[1].Value.Trim() } else { '' }
        CorePath = if ($corePath.Success) { $corePath.Groups[1].Value.Trim() } else { '' }
        Status = $status.Groups[1].Value.Trim()
    }
}

function Read-ExportMap {
    param([Parameter(Mandatory = $true)]$Identity)
    $path = Join-Path $Identity.StateRoot 'learning\EXPERIENCE-EXPORTS.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $value = [ordered]@{ schema_version = 1; product_id = $Identity.ProductId; exports = @() }
        Write-Utf8Json -Value $value -Path $path
    }
    $map = Read-JsonFile -Path $path
    if ([string]$map.product_id -ne $Identity.ProductId) { throw 'EXPERIENCE-EXPORTS.json belongs to another product' }
    return [pscustomobject]@{ Path = $path; Value = $map }
}

function Get-OrCreateSourceId {
    param(
        [Parameter(Mandatory = $true)]$ExportMap,
        [Parameter(Mandatory = $true)][string]$ExperienceId
    )
    $existing = @($ExportMap.Value.exports | Where-Object { $_.experience_id -eq $ExperienceId } | Select-Object -First 1)
    if ($existing.Count -gt 0) { return [string]$existing[0].source_id }
    return 'src-' + [Guid]::NewGuid().ToString('N')
}

function Add-ExportMapRecord {
    param(
        [Parameter(Mandatory = $true)]$ExportMap,
        [Parameter(Mandatory = $true)][string]$ExperienceId,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][string]$SourceKind,
        [Parameter(Mandatory = $true)][object[]]$EvidenceRecords
    )
    $existing = @($ExportMap.Value.exports | Where-Object { $_.experience_id -eq $ExperienceId } | Select-Object -First 1)
    $existingEvidence = @()
    if ($existing.Count -gt 0) { $existingEvidence = @($existing[0].local_evidence) }
    if ($existing.Count -gt 0 -and [string]$existing[0].source_id -ne $SourceId) { throw 'Product export map source_id conflict' }
    if ($existing.Count -gt 0 -and [string]$existing[0].source_kind -ne $SourceKind) { throw 'Product export map source_kind conflict' }
    $mergedEvidence = @($existingEvidence + $EvidenceRecords | Group-Object sha256 | ForEach-Object { $_.Group[0] })
    $others = @($ExportMap.Value.exports | Where-Object { $_.experience_id -ne $ExperienceId })
    $entry = [ordered]@{
        experience_id = $ExperienceId
        source_id = $SourceId
        source_kind = $SourceKind
        exported_at = Get-IsoTimestamp
        local_evidence = $mergedEvidence
    }
    $ExportMap.Value.exports = @($others + $entry)
    Write-Utf8Json -Value $ExportMap.Value -Path $ExportMap.Path
}

function New-PublicEvidenceRecords {
    param(
        [Parameter(Mandatory = $true)][string[]]$EvidencePath,
        [Parameter(Mandatory = $true)][string]$AllowedRoot,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][ValidateSet('real_product', 'fixture')][string]$SourceKind,
        [Parameter(Mandatory = $true)][ValidateSet('supporting', 'positive_fixture', 'negative_fixture')][string]$EvidenceRole,
        [Parameter(Mandatory = $true)][string]$EvidenceLevel
    )
    $public = New-Object System.Collections.Generic.List[object]
    $local = New-Object System.Collections.Generic.List[object]
    foreach ($path in $EvidencePath) {
        $resolved = Assert-PathWithinRoot -Path $path -Root $AllowedRoot
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Evidence path is not a file: $resolved" }
        $hash = Get-Sha256 -Path $resolved
        $proofId = 'proof-' + [Guid]::NewGuid().ToString('N')
        [void]$public.Add([ordered]@{
            source_id = $SourceId
            source_kind = $SourceKind
            evidence_role = $EvidenceRole
            artifact_kind = Get-ArtifactKind -Path $resolved
            evidence_proof_id = $proofId
            evidence_level = $EvidenceLevel
        })
        [void]$local.Add([ordered]@{
            path = $resolved
            sha256 = $hash
            evidence_proof_id = $proofId
        })
    }
    return [pscustomobject]@{
        Public = @($public | ForEach-Object { $_ })
        Local = @($local | ForEach-Object { $_ })
    }
}
