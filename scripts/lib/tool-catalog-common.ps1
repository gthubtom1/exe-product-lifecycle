#requires -Version 5

# tool-catalog-common -- the single place that knows how the tool catalog and the capability bridge
# are stored, merged and fingerprinted.
#
# Both tables used to be PowerShell literals: $catalog in discover-tools.ps1 and $script:CapabilityToolMap
# in resolve-capability.ps1. Neither had any embedded logic, so they are plain data and now live in JSON:
#
#   catalog/tools.builtin.json          builtin roles, shipped, OVERWRITTEN by an upgrade (correct)
#   catalog/capabilities.builtin.json   builtin capability -> role bridge, same lifecycle
#   knowledge/tools/tools.learned.json         locally learned tool names
#   knowledge/tools/capabilities.learned.json  locally learned bridge entries
#
# Why the learned layer lives under knowledge/ and MUST NOT be shipped in the source tree:
# sync-local-skill.ps1 deletes any file in the installed copy that the source does not have, with one
# exception -- anything under knowledge\ is preserved. That exception only covers files the source does
# NOT have: a file that exists in both is plainly overwritten by the copy step. So shipping an empty
# tools.learned.json would silently wipe local learning on every sync. The learned files are therefore
# created on first write and never committed; only knowledge/tools/.gitkeep is.
#
# Read-only consumers dot-source this and call Get-ToolRoleTable / Get-CapabilityBridgeTable.

Set-StrictMode -Version Latest

# Collected rather than thrown: a broken learned layer must be loud but must not stop the run that is
# trying to use the builtin table. Callers surface these on their own summary line.
$script:ToolCatalogWarnings = New-Object System.Collections.Generic.List[string]

function Clear-ToolCatalogWarning { $script:ToolCatalogWarnings.Clear() }

function Get-ToolCatalogWarning {
    # .ToArray() rather than @($list): on this toolchain @() over a List[object] throws
    # "Argument types do not match", so every list in this file is typed and converted explicitly.
    return $script:ToolCatalogWarnings.ToArray()
}

function Add-ToolCatalogWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    [void]$script:ToolCatalogWarnings.Add($Message)
    Write-Warning $Message
}

function Get-ToolCatalogPath {
    param([string]$SkillRoot)

    if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path }
    $root = (Resolve-Path -LiteralPath $SkillRoot).Path
    $learnedDir = Join-Path (Join-Path $root 'knowledge') 'tools'
    return [pscustomobject]@{
        SkillRoot           = $root
        BuiltinTools        = Join-Path (Join-Path $root 'catalog') 'tools.builtin.json'
        BuiltinCapabilities = Join-Path (Join-Path $root 'catalog') 'capabilities.builtin.json'
        LearnedDir          = $learnedDir
        LearnedTools        = Join-Path $learnedDir 'tools.learned.json'
        LearnedCapabilities = Join-Path $learnedDir 'capabilities.learned.json'
    }
}

function Test-JsonProperty {
    # StrictMode makes reading an absent property fatal, and ConvertFrom-Json objects are shaped by
    # whatever the file happened to contain.
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $false }
    return (@($InputObject.PSObject.Properties.Name) -contains $Name)
}

function Get-JsonProperty {
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if (-not (Test-JsonProperty -InputObject $InputObject -Name $Name)) { return $Default }
    $value = $InputObject.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

function Read-ToolCatalogDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        # A missing builtin table is fatal: continuing with an empty catalog would report every tool on
        # the machine as not installed, and every capability as a gap, without a single error.
        [switch]$Required
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($Required) { throw "tool catalog data file is missing: $Path" }
        return $null
    }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($text)) {
        if ($Required) { throw "tool catalog data file is empty: $Path" }
        Add-ToolCatalogWarning "learned layer ignored (file is empty): $Path"
        return $null
    }
    try { return ($text | ConvertFrom-Json) }
    catch {
        if ($Required) { throw ("tool catalog data file is not valid JSON: {0} :: {1}" -f $Path, $_.Exception.Message) }
        # Silently dropping it would revert the fingerprint to builtin-only, which is exactly how a
        # learned tool becomes permanently invisible while every log line still reads green.
        Add-ToolCatalogWarning ("learned layer ignored (invalid JSON): {0} :: {1}" -f $Path, $_.Exception.Message)
        return $null
    }
}

function Get-ToolRoleTable {
    <#
      The merged role table, in the order the fingerprint depends on:
        - builtin roles first, in file order;
        - learned names appended after the builtin names of the same role, in file order;
        - roles that exist only in the learned layer appended last.

      Builtin names are reproduced VERBATIM -- not de-duplicated. The builtin catalog deliberately
      carries case variants (exeinfope.exe / ExeinfoPe.exe, Procmon.exe / procmon.exe, pe-bear.exe /
      PE-bear.exe, BinDiff.exe / bindiff.exe). Folding them looks harmless because Windows matches
      file names case-insensitively anyway, but it changes catalog_fingerprint, which would invalidate
      every cached inventory in existence and make this migration a behaviour change. De-duplication
      applies only to the learned layer, where it does the job it is actually for: appending a name
      that is already known must be a no-op, not fingerprint churn on every run.

      The learned layer may only ADD names. It can never remove or rewrite a builtin role.
    #>
    param([string]$SkillRoot, [switch]$BuiltinOnly)

    $paths = Get-ToolCatalogPath -SkillRoot $SkillRoot
    $builtin = Read-ToolCatalogDocument -Path $paths.BuiltinTools -Required

    $roles = New-Object System.Collections.Generic.List[psobject]
    $index = @{}
    foreach ($role in @(Get-JsonProperty -InputObject $builtin -Name 'roles' -Default @())) {
        $id = [string](Get-JsonProperty -InputObject $role -Name 'id' -Default '')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $names = New-Object System.Collections.Generic.List[string]
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @(Get-JsonProperty -InputObject $role -Name 'names' -Default @())) {
            $trimmed = ([string]$name).Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            # Added to $seen for the learned layer to test against, but never filtered out here.
            [void]$seen.Add($trimmed)
            [void]$names.Add($trimmed)
        }
        $entry = [pscustomobject]@{
            id       = $id
            category = [string](Get-JsonProperty -InputObject $role -Name 'category' -Default '')
            names    = $names.ToArray()
            notes    = [string](Get-JsonProperty -InputObject $role -Name 'notes' -Default '')
            _names   = $names
            _seen    = $seen
        }
        [void]$roles.Add($entry)
        $index[$id] = $entry
    }
    if ($roles.Count -eq 0) { throw "tool catalog has no roles: $($paths.BuiltinTools)" }

    if (-not $BuiltinOnly) {
        $learned = Read-ToolCatalogDocument -Path $paths.LearnedTools
        foreach ($role in @(Get-JsonProperty -InputObject $learned -Name 'roles' -Default @())) {
            $id = [string](Get-JsonProperty -InputObject $role -Name 'id' -Default '')
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if (-not $index.ContainsKey($id)) {
                # Kept rather than dropped: the append helper refuses to invent a role, so a role that
                # is only in the learned layer was put there by a human on purpose. Dropping it here
                # would hide it from discovery AND from the fingerprint, which is the silent failure
                # this whole layer exists to avoid. Announced so it can be adjudicated into the builtin
                # table rather than living forever as a local-only class.
                $names = New-Object System.Collections.Generic.List[string]
                $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                $entry = [pscustomobject]@{
                    id       = $id
                    category = [string](Get-JsonProperty -InputObject $role -Name 'category' -Default '（学来层新增，未归类）')
                    names    = @()
                    notes    = [string](Get-JsonProperty -InputObject $role -Name 'notes' -Default '')
                    _names   = $names
                    _seen    = $seen
                }
                [void]$roles.Add($entry)
                $index[$id] = $entry
                Add-ToolCatalogWarning "learned layer defines a role the builtin catalog does not have: $id （需人裁定是否并入内置分类）"
            }
            $target = $index[$id]
            foreach ($name in @(Get-JsonProperty -InputObject $role -Name 'names' -Default @())) {
                $trimmed = ([string]$name).Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
                if (-not $target._seen.Add($trimmed)) { continue }
                [void]$target._names.Add($trimmed)
            }
        }
    }

    $result = New-Object System.Collections.Generic.List[psobject]
    foreach ($role in $roles) {
        [void]$result.Add([pscustomobject]@{
                id       = $role.id
                category = $role.category
                names    = $role._names.ToArray()
                notes    = $role.notes
            })
    }
    return $result.ToArray()
}

function Get-ToolCatalogFingerprintText {
    # The exact recipe the reuse gate has always used. Kept as its own function so that the migration
    # test can assert the text, not just the hash, and so there is one definition rather than one per
    # caller.
    param([Parameter(Mandatory = $true)]$Roles)
    return ((@($Roles) | ForEach-Object { '{0}={1}' -f $_.id, ((@($_.names)) -join ',') }) -join ';')
}

function Get-ToolCatalogFingerprint {
    param([Parameter(Mandatory = $true)]$Roles)

    $text = Get-ToolCatalogFingerprintText -Roles $Roles
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        return (([System.BitConverter]::ToString($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
}

function Get-CapabilityBridgeTable {
    <#
      capability_id -> acceptable role ids, builtin merged with learned. Same append-only rule as the
      tool table: the learned layer may add a capability or add roles to one, never remove.
      Returns an OrderedDictionary so callers keep a stable, file-ordered listing.
    #>
    param([string]$SkillRoot, [switch]$BuiltinOnly)

    $paths = Get-ToolCatalogPath -SkillRoot $SkillRoot
    $builtin = Read-ToolCatalogDocument -Path $paths.BuiltinCapabilities -Required

    $map = New-Object System.Collections.Specialized.OrderedDictionary
    $order = New-Object System.Collections.Generic.List[string]
    $roleLists = @{}

    foreach ($capability in @(Get-JsonProperty -InputObject $builtin -Name 'capabilities' -Default @())) {
        $id = [string](Get-JsonProperty -InputObject $capability -Name 'id' -Default '')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $roles = New-Object System.Collections.Generic.List[string]
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($role in @(Get-JsonProperty -InputObject $capability -Name 'roles' -Default @())) {
            $trimmed = ([string]$role).Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or -not $seen.Add($trimmed)) { continue }
            [void]$roles.Add($trimmed)
        }
        $roleLists[$id] = [pscustomobject]@{ Roles = $roles; Seen = $seen }
        [void]$order.Add($id)
    }
    if ($order.Count -eq 0) { throw "capability bridge has no entries: $($paths.BuiltinCapabilities)" }

    if (-not $BuiltinOnly) {
        $learned = Read-ToolCatalogDocument -Path $paths.LearnedCapabilities
        foreach ($capability in @(Get-JsonProperty -InputObject $learned -Name 'capabilities' -Default @())) {
            $id = [string](Get-JsonProperty -InputObject $capability -Name 'id' -Default '')
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if (-not $roleLists.ContainsKey($id)) {
                $roleLists[$id] = [pscustomobject]@{
                    Roles = (New-Object System.Collections.Generic.List[string])
                    Seen  = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))
                }
                [void]$order.Add($id)
            }
            foreach ($role in @(Get-JsonProperty -InputObject $capability -Name 'roles' -Default @())) {
                $trimmed = ([string]$role).Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed) -or -not $roleLists[$id].Seen.Add($trimmed)) { continue }
                [void]$roleLists[$id].Roles.Add($trimmed)
            }
        }
    }

    foreach ($id in $order) { $map.Add($id, $roleLists[$id].Roles.ToArray()) }
    return $map
}

function Save-LearnedDocument {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Document)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = ($Document | ConvertTo-Json -Depth 8)
    $temp = $Path + '.tmp'
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Add-LearnedToolName {
    <#
      Append one executable name to an existing role's learned names. This is the AUTOMATIC half of the
      policy: enriching names can at worst make discovery notice a tool that should not be used, so it
      does not need a human. Creating a role is refused -- that is a change to the capability taxonomy
      and has to be adjudicated.

      Never throws. A failed append is a warning plus the entry printed verbatim, because appending is
      a side effect AFTER the work is already done; losing a lesson is survivable, losing it without
      knowing what was lost is not.
    #>
    param(
        [string]$SkillRoot,
        [Parameter(Mandatory = $true)][string]$RoleId,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$AddedForCapability = '',
        [ValidateSet('web', 'winget', 'user_supplied')][string]$FoundVia = 'web',
        [string]$SourceUrl = '',
        [ValidateSet('winget', 'manual', 'already_present')][string]$InstallRoute = 'manual',
        [string[]]$UsedByProducts = @()
    )

    $entryEcho = "role=$RoleId name=$Name capability=$AddedForCapability found_via=$FoundVia source_url=$SourceUrl install_route=$InstallRoute"
    try {
        $paths = Get-ToolCatalogPath -SkillRoot $SkillRoot
        $builtinRoles = Get-ToolRoleTable -SkillRoot $SkillRoot -BuiltinOnly
        if (-not (@($builtinRoles | ForEach-Object { $_.id }) -contains $RoleId)) {
            # Refusing to invent a role is right, but a bare refusal is a gate with no exit: someone whose
            # real situation is "none of the 26 classes fit this tool" could only give up or file it under
            # a role where it does not belong -- a quiet, plausible-looking lie in the data. So the refusal
            # carries a filled-in escalation instead: the true statement gets a legitimate, visible form,
            # and a human decides whether the taxonomy should grow.
            $escalation = New-Object System.Collections.Generic.List[string]
            [void]$escalation.Add('需要人裁定：这个工具装不进现有的 26 类。')
            [void]$escalation.Add("  想登记的工具：$Name")
            [void]$escalation.Add("  想归到的新类：$RoleId（不存在，本脚本不自行加类）")
            if (-not [string]::IsNullOrWhiteSpace($AddedForCapability)) { [void]$escalation.Add("  当初为哪个能力去找的：$AddedForCapability") }
            if (-not [string]::IsNullOrWhiteSpace($SourceUrl)) { [void]$escalation.Add("  出处：$SourceUrl") }
            [void]$escalation.Add("  现有 26 类：" + ((@($builtinRoles | ForEach-Object { $_.id })) -join ', '))
            [void]$escalation.Add('  请裁定：并入上面某一类（给出类名），还是确实要新增一类（给出类名与分类说明）。')
            [void]$escalation.Add('  在裁定之前不要硬塞进不合适的类——塞进去之后没人看得出它塞错了。')
            return [pscustomobject]@{
                Status     = 'needs_new_role'
                Reason     = "role id is not in the builtin catalog: $RoleId"
                Entry      = $entryEcho
                Escalation = $escalation.ToArray()
            }
        }

        $document = Read-ToolCatalogDocument -Path $paths.LearnedTools
        if ($null -eq $document) { $document = [pscustomobject]@{ schema_version = 1; layer = 'learned'; roles = @() } }
        if (-not (Test-JsonProperty -InputObject $document -Name 'roles')) {
            $document | Add-Member -NotePropertyName 'roles' -NotePropertyValue @()
        }

        $existing = @(@(Get-JsonProperty -InputObject $document -Name 'roles' -Default @()) | Where-Object { [string](Get-JsonProperty -InputObject $_ -Name 'id' -Default '') -eq $RoleId })
        $merged = Get-ToolRoleTable -SkillRoot $SkillRoot
        $current = @($merged | Where-Object { $_.id -eq $RoleId })
        if ($current.Count -eq 1 -and (@($current[0].names) -contains $Name)) {
            return [pscustomobject]@{ Status = 'already_present'; Reason = "name already in the merged table: $Name"; Entry = $entryEcho; Escalation = @() }
        }

        $learnedMeta = [pscustomobject]@{
            added_at             = ([datetimeoffset]::Now).ToString('o')
            added_for_capability = $AddedForCapability
            found_via            = $FoundVia
            source_url           = $SourceUrl
            install_route        = $InstallRoute
            used_by_products     = @($UsedByProducts)
        }

        if ($existing.Count -ge 1) {
            $target = $existing[0]
            $names = New-Object System.Collections.Generic.List[string]
            foreach ($n in @(Get-JsonProperty -InputObject $target -Name 'names' -Default @())) { [void]$names.Add([string]$n) }
            [void]$names.Add($Name)
            $target.names = $names.ToArray()
            if (Test-JsonProperty -InputObject $target -Name 'learned') { $target.learned = $learnedMeta }
            else { $target | Add-Member -NotePropertyName 'learned' -NotePropertyValue $learnedMeta }
        }
        else {
            $roles = New-Object System.Collections.Generic.List[psobject]
            foreach ($r in @(Get-JsonProperty -InputObject $document -Name 'roles' -Default @())) { [void]$roles.Add($r) }
            [void]$roles.Add([pscustomobject]@{ id = $RoleId; names = @($Name); learned = $learnedMeta })
            $document.roles = $roles.ToArray()
        }

        Save-LearnedDocument -Path $paths.LearnedTools -Document $document
        return [pscustomobject]@{ Status = 'appended'; Reason = ''; Entry = $entryEcho; Escalation = @() }
    }
    catch {
        return [pscustomobject]@{ Status = 'failed'; Reason = $_.Exception.Message; Entry = $entryEcho; Escalation = @() }
    }
}

function Add-LearnedCapabilityRole {
    <#
      Append a capability -> role mapping. This is the half that is NOT automatic: it changes the
      verdict of "can anything on this machine do X", which gap-classify and the install gate consume
      directly. It must ride on the approval the user already gives when deciding whether to install,
      so -Approved is required; without it the caller reports a pending mapping rather than dropping it.
    #>
    param(
        [string]$SkillRoot,
        [Parameter(Mandatory = $true)][string]$CapabilityId,
        [Parameter(Mandatory = $true)][string]$RoleId,
        [switch]$Approved,
        [string]$ApprovedNote = ''
    )

    $entryEcho = "capability=$CapabilityId role=$RoleId"
    if (-not $Approved) {
        return [pscustomobject]@{ Status = 'pending_approval'; Reason = '桥表变更改变裁决，必须并进用户那一次点头'; Entry = $entryEcho }
    }
    try {
        $paths = Get-ToolCatalogPath -SkillRoot $SkillRoot
        $roleIds = @((Get-ToolRoleTable -SkillRoot $SkillRoot) | ForEach-Object { $_.id })
        if (-not ($roleIds -contains $RoleId)) {
            return [pscustomobject]@{ Status = 'refused'; Reason = "role id is in neither the builtin nor the learned catalog: $RoleId"; Entry = $entryEcho }
        }

        $bridge = Get-CapabilityBridgeTable -SkillRoot $SkillRoot
        if ($bridge.Contains($CapabilityId) -and (@($bridge[$CapabilityId]) -contains $RoleId)) {
            return [pscustomobject]@{ Status = 'already_present'; Reason = "mapping already in the merged bridge"; Entry = $entryEcho }
        }

        $document = Read-ToolCatalogDocument -Path $paths.LearnedCapabilities
        if ($null -eq $document) { $document = [pscustomobject]@{ schema_version = 1; layer = 'learned'; capabilities = @() } }
        if (-not (Test-JsonProperty -InputObject $document -Name 'capabilities')) {
            $document | Add-Member -NotePropertyName 'capabilities' -NotePropertyValue @()
        }

        $existing = @(@(Get-JsonProperty -InputObject $document -Name 'capabilities' -Default @()) | Where-Object { [string](Get-JsonProperty -InputObject $_ -Name 'id' -Default '') -eq $CapabilityId })
        $approval = [pscustomobject]@{ approved_at = ([datetimeoffset]::Now).ToString('o'); note = $ApprovedNote }
        if ($existing.Count -ge 1) {
            $target = $existing[0]
            $roles = New-Object System.Collections.Generic.List[string]
            foreach ($r in @(Get-JsonProperty -InputObject $target -Name 'roles' -Default @())) { [void]$roles.Add([string]$r) }
            [void]$roles.Add($RoleId)
            $target.roles = $roles.ToArray()
            if (Test-JsonProperty -InputObject $target -Name 'approval') { $target.approval = $approval }
            else { $target | Add-Member -NotePropertyName 'approval' -NotePropertyValue $approval }
        }
        else {
            $capabilities = New-Object System.Collections.Generic.List[psobject]
            foreach ($c in @(Get-JsonProperty -InputObject $document -Name 'capabilities' -Default @())) { [void]$capabilities.Add($c) }
            [void]$capabilities.Add([pscustomobject]@{ id = $CapabilityId; roles = @($RoleId); approval = $approval })
            $document.capabilities = $capabilities.ToArray()
        }

        Save-LearnedDocument -Path $paths.LearnedCapabilities -Document $document
        return [pscustomobject]@{ Status = 'appended'; Reason = ''; Entry = $entryEcho }
    }
    catch {
        return [pscustomobject]@{ Status = 'failed'; Reason = $_.Exception.Message; Entry = $entryEcho }
    }
}

function Get-RecordedCandidate {
    # Candidates recorded against a capability, in either layer. A name WITHOUT a source_url is never a
    # candidate: "I remember a tool called X" is a guess, and a confident-sounding tool name is the single
    # easiest thing for this pipeline to invent.
    #
    # But it is not discarded either, and that distinction matters more than it looks. A gate that simply
    # deletes unsourced names leaves someone whose real situation is "I have a lead and genuinely no
    # provenance" with nothing they can honestly say -- and the cheapest way out of that is to attach a
    # plausible URL, which is far worse than an unsourced name because it looks verified. So leads get
    # their own clearly-labelled place: true, sayable, and impossible to mistake for a candidate.
    param([string]$SkillRoot, [Parameter(Mandatory = $true)][string]$CapabilityId)

    $paths = Get-ToolCatalogPath -SkillRoot $SkillRoot
    $kept = New-Object System.Collections.Generic.List[psobject]
    $leads = New-Object System.Collections.Generic.List[psobject]
    $dropped = 0
    foreach ($path in @($paths.BuiltinCapabilities, $paths.LearnedCapabilities)) {
        $document = if ($path -eq $paths.BuiltinCapabilities) { Read-ToolCatalogDocument -Path $path -Required } else { Read-ToolCatalogDocument -Path $path }
        foreach ($capability in @(Get-JsonProperty -InputObject $document -Name 'capabilities' -Default @())) {
            if ([string](Get-JsonProperty -InputObject $capability -Name 'id' -Default '') -ne $CapabilityId) { continue }
            foreach ($candidate in @(Get-JsonProperty -InputObject $capability -Name 'candidates' -Default @())) {
                $sourceUrl = [string](Get-JsonProperty -InputObject $candidate -Name 'source_url' -Default '')
                $name = [string](Get-JsonProperty -InputObject $candidate -Name 'name' -Default '')
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
                    $dropped++
                    [void]$leads.Add([pscustomobject]@{
                            name = $name
                            note = [string](Get-JsonProperty -InputObject $candidate -Name 'note' -Default '')
                        })
                    continue
                }
                [void]$kept.Add([pscustomobject]@{
                        name             = $name
                        source_url       = $sourceUrl
                        usable           = [string](Get-JsonProperty -InputObject $candidate -Name 'usable' -Default '未验证')
                        headless_windows = [string](Get-JsonProperty -InputObject $candidate -Name 'headless_windows' -Default '未验证')
                        known_limit      = [string](Get-JsonProperty -InputObject $candidate -Name 'known_limit' -Default '')
                    })
            }
        }
    }
    return [pscustomobject]@{ Candidates = $kept.ToArray(); Leads = $leads.ToArray(); DroppedWithoutSource = $dropped }
}

function Get-ToolRequestBrief {
    <#
      What to say when the merged table cannot answer. "Not in the table" is the entrance to looking,
      not a dead end, and the empty-handed answer is a first-class outcome with a fixed shape -- if
      "I did not find one" has nowhere to go, the model invents a tool name instead, and a plausible
      wrong tool name is cheap to believe and expensive to disprove.

      -InventoryPath decides whether this brief may claim the machine was searched. 'unavailable' is also
      the verdict when there is no tool snapshot at all, so saying "looked here, found nothing" without
      checking would turn "never looked" into "confirmed absent" -- the same not-found-means-not-there
      mistake this brief exists to stop, committed by the brief itself.
      Returns the lines; the caller decides where they go.
    #>
    param([string]$SkillRoot, [Parameter(Mandatory = $true)][string]$CapabilityId, [string]$InventoryPath)

    $lines = New-Object System.Collections.Generic.List[string]
    $roles = @()
    $roleTable = @()
    try {
        $bridge = Get-CapabilityBridgeTable -SkillRoot $SkillRoot
        if ($bridge.Contains($CapabilityId)) { $roles = @($bridge[$CapabilityId]) }
        $roleTable = Get-ToolRoleTable -SkillRoot $SkillRoot
    }
    catch {
        [void]$lines.Add("工具请求无法生成：读取表失败 :: $($_.Exception.Message)")
        return $lines.ToArray()
    }

    # $null means "no usable snapshot", which is different from "a snapshot that found nothing".
    $inventoryRows = $null
    if (-not [string]::IsNullOrWhiteSpace($InventoryPath) -and (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
        try {
            $inventory = Get-Content -Raw -Encoding UTF8 -LiteralPath $InventoryPath | ConvertFrom-Json
            if (Test-JsonProperty -InputObject $inventory -Name 'tools') { $inventoryRows = @($inventory.tools) }
        }
        catch { $inventoryRows = $null }
    }

    [void]$lines.Add('=== 工具请求（表里没有，需要去找）===')
    [void]$lines.Add('[1/3] 我需要一个能做什么的工具')
    [void]$lines.Add("  能力 id：$CapabilityId")
    if ($roles.Count -eq 0) {
        [void]$lines.Add('  对应角色：（桥表里没有这条能力）')
        [void]$lines.Add('  说明：加一条能力→角色映射会改变「这台机器算不算能干这活」的裁决，不自动做；')
        [void]$lines.Add('        并进「找到候选、装不装」那一次点头里一起确认。')
    }
    else {
        foreach ($roleId in $roles) {
            $match = @($roleTable | Where-Object { $_.id -eq $roleId })
            if ($match.Count -eq 1) {
                [void]$lines.Add("  对应角色：$roleId（$($match[0].category)）")
                [void]$lines.Add("  角色用途：$($match[0].notes)")
                if ($null -eq $inventoryRows) {
                    [void]$lines.Add("  本机找过没有：**没查过**——没有可用的工具快照，先跑一次 discover-tools 再下结论")
                }
                else {
                    $row = @($inventoryRows | Where-Object { [string](Get-JsonProperty -InputObject $_ -Name 'tool_id' -Default '') -eq $roleId })
                    if ($row.Count -eq 0) {
                        [void]$lines.Add("  本机找过没有：**没查过**——快照里没有这个角色的记录，重跑一次发现再下结论")
                    }
                    else {
                        [void]$lines.Add("  已在本机找过：该角色下 $(@($match[0].names).Count) 个可执行名，均未命中")
                    }
                }
            }
            else {
                [void]$lines.Add("  对应角色：$roleId（⚠ 该角色 id 不在工具表里，桥表与工具表已漂移）")
            }
        }
    }
    [void]$lines.Add('  运行环境：Windows，可无头（无 GUI 交互）')
    [void]$lines.Add('')

    $recorded = Get-RecordedCandidate -SkillRoot $SkillRoot -CapabilityId $CapabilityId
    [void]$lines.Add('[2/3] 带出处的候选（存在 ≠ 合用 ≠ Windows 能无头跑，分开标注）')
    if (@($recorded.Candidates).Count -eq 0) {
        [void]$lines.Add('  （本表没有记录任何带出处的候选——这不是「没有这个工具」，是「本表还没记过」）')
    }
    else {
        $ordinal = 0
        foreach ($candidate in @($recorded.Candidates)) {
            $ordinal++
            [void]$lines.Add("  $ordinal. $($candidate.name)")
            [void]$lines.Add("     出处：$($candidate.source_url)")
            [void]$lines.Add("     存在：已确认（有出处）  合用：$($candidate.usable)  Windows 无头：$($candidate.headless_windows)")
            if (-not [string]::IsNullOrWhiteSpace($candidate.known_limit)) { [void]$lines.Add("     ⚠ 已知上界：$($candidate.known_limit)") }
        }
    }
    [void]$lines.Add('  规则：绝对禁止献一个工具名充数。候选必须带出处 URL。')
    if (@($recorded.Leads).Count -gt 0) {
        # Listed, not deleted, and never under the candidate heading. If "I have a lead but no
        # provenance" had nowhere to go, the cheap way out would be to invent a URL -- and a fabricated
        # source is worse than an unsourced name, because it reads as already checked.
        [void]$lines.Add('')
        [void]$lines.Add("  无出处的线索（$(@($recorded.Leads).Count) 条，不是候选，不能据此安装）：")
        foreach ($lead in @($recorded.Leads)) {
            $suffix = if ([string]::IsNullOrWhiteSpace($lead.note)) { '' } else { "（$($lead.note)）" }
            [void]$lines.Add("    - $($lead.name)$suffix — 没有出处，要用它得先找到出处；找不到就当它不存在。")
        }
    }
    [void]$lines.Add('')

    [void]$lines.Add('[3/3] 找不到就照这个说（空手是正常结果，不算失败、不要重试）')
    [void]$lines.Add('  没有找到合用的候选。')
    [void]$lines.Add('  我确认的是：<搜了哪些地方 / 用了哪些关键词>')
    [void]$lines.Add('  我不确定的是：<可能存在但我没找到的方向>')
    [void]$lines.Add('  建议：<人工带外 / 换一条技术路线 / 这是死路，理由是……>')
    [void]$lines.Add('  措辞纪律：报「我没找到」，不报「没有这个工具」。真正的死路只有两种——')
    [void]$lines.Add('            没有任何已发行的工具能解决它，或目标自身的保护使需求不可能达成。')
    return $lines.ToArray()
}
