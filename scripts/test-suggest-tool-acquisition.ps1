#requires -Version 5

# Behaviour + mutation guard for suggest-tool-acquisition.ps1 (the "tell the user, they approve, then it
# gets installed" chain). The script's whole value is that its output can be trusted enough to act on, so
# each case pins one way it could quietly become untrustworthy:
#
#   - claiming something is missing off a search that never covered the disk (SA2-SA5);
#   - inventing a tool name instead of coming back empty-handed (SA9-SA10, SA13);
#   - selling a frozen upstream as "go install a newer one" (SA11-SA12);
#   - suggesting a tool that rediscovery would not even detect (SA15);
#   - growing an unattended install path, which this chain must never have (SA16).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-suggest-tool-acquisition.ps1

[CmdletBinding()]
param(
    [string]$SkillRoot,
    [string]$FixtureRoot = (Join-Path $env:TEMP ('eplc-suggestacq-' + [guid]::NewGuid().ToString('N').Substring(0, 8))),
    [string]$PsHost,
    [switch]$KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
if ([string]::IsNullOrWhiteSpace($PsHost)) { $PsHost = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' } }
$script:Skill = (Resolve-Path -LiteralPath $SkillRoot).Path
$script:PsHost = $PsHost
$script:Results = New-Object System.Collections.Generic.List[psobject]
$script:StackTraceSeen = New-Object System.Collections.Generic.List[string]
New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null
Write-Output ('host under test: {0} ({1} {2})' -f $script:PsHost, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Expected, [string]$Actual)
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed })
    $label = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Output ('{0}   {1,-44} expected[{2}] actual[{3}]' -f $label, $Name, $Expected, $Actual)
}

function Invoke-Suggest {
    param([string]$Case, [string[]]$ScriptArgs)
    $path = Join-Path $script:Skill 'scripts\suggest-tool-acquisition.ps1'
    $raw = @(& $script:PsHost -NoProfile -ExecutionPolicy Bypass -File $path @ScriptArgs 2>&1 | ForEach-Object { [string]$_ })
    $exitVar = Get-Variable -Name 'LASTEXITCODE' -ErrorAction SilentlyContinue
    $exitCode = if ($null -eq $exitVar -or $null -eq $exitVar.Value) { -1 } else { [int]$exitVar.Value }
    $text = ($raw -join "`n")
    $verdictLine = @($raw | Where-Object { $_ -match '^RESULT:\s*' } | Select-Object -First 1)
    $hasStack = @($raw | Where-Object { $_ -match 'CategoryInfo|FullyQualifiedErrorId|At line:\d+ char:\d+' }).Count -gt 0
    if ($hasStack) { [void]$script:StackTraceSeen.Add($Case) }
    return [pscustomobject]@{
        Verdict  = $(if ($verdictLine.Count -eq 1) { ($verdictLine[0] -replace '^RESULT:\s*', '').Trim() } else { '(no-verdict)' })
        Reason   = $($m = @($raw | Where-Object { $_ -match '^reason=' } | Select-Object -First 1); if ($m.Count -eq 1) { ($m[0] -replace '^reason=', '') } else { '' })
        Scope    = $($m = @($raw | Where-Object { $_ -match '^search_scope=' } | Select-Object -First 1); if ($m.Count -eq 1) { ($m[0] -replace '^search_scope=', '') } else { '' })
        Command  = $($m = @($raw | Where-Object { $_ -match '^primary_command=' } | Select-Object -First 1); if ($m.Count -eq 1) { ($m[0] -replace '^primary_command=', '') } else { '' })
        ExitCode = $exitCode
        Text     = $text
    }
}

# A snapshot in exactly the shape discover-tools writes. The discovery_inputs flags are the whole point of
# several cases below, so they are set per fixture rather than defaulted.
function New-Snapshot {
    param(
        [string]$Name,
        [object[]]$Tools = @(),
        [bool]$DeepScan = $false,
        [bool]$UseEverything = $false,
        [bool]$RootsOnly = $false
    )
    $root = Join-Path $FixtureRoot $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'product-state\tooling') | Out-Null
    $snapshot = [pscustomobject]@{
        generated_at     = ([datetimeoffset]::Now).ToString('o')
        verified_at      = ([datetimeoffset]::Now).ToString('o')
        product_root     = $root
        discovery_inputs = [pscustomobject]@{
            host_tool_index         = ''
            additional_search_roots = @()
            max_search_depth        = 10
            search_generation       = 2
            deep_scan               = $DeepScan
            search_roots_only       = $RootsOnly
            use_everything          = $UseEverything
            extra_root_fingerprint  = 'fixture'
            catalog_fingerprint     = 'fixture'
        }
        tools            = $Tools
    }
    [IO.File]::WriteAllText((Join-Path $root 'product-state\tooling\TOOL-INVENTORY.json'), ($snapshot | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    return $root
}

# The reconciliation cases read the tables out of the source rather than dot-sourcing: every script here
# has mandatory parameters and does its real work at load, so importing one to read a variable is not an
# option. Same technique test-resolve-capability's RC6 uses.
function Get-AssignedValueAst {
    param([string]$Path, [string]$VariableName, [switch]$AllowMissing)
    $tokens = $null
    $errors = $null
    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @()
    if ($null -ne $errors) { $parseErrors = @($errors) }
    if ($parseErrors.Count -gt 0) { throw ('{0} has {1} parse error(s), first: {2}' -f (Split-Path -Leaf $Path), $parseErrors.Count, $parseErrors[0].Message) }
    $assignment = $fileAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (($node.Left.VariablePath.UserPath -split ':')[-1] -eq $VariableName)
        }, $true)
    if ($null -eq $assignment) {
        if ($AllowMissing) { return $null }
        throw ('no assignment to variable {0} in {1}' -f $VariableName, (Split-Path -Leaf $Path))
    }
    return $assignment.Right
}

function Get-OuterHashtableAst {
    param($Value)
    if ($Value -is [System.Management.Automation.Language.HashtableAst]) { return $Value }
    return $Value.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true)
}

function Get-StringLiteralKey {
    param($HashtableAst)
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($pair in $HashtableAst.KeyValuePairs) {
        if ($pair.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            throw ('key at line {0} is not a string literal' -f $pair.Item1.Extent.StartLineNumber)
        }
        [void]$keys.Add([string]$pair.Item1.Value)
    }
    return @($keys)
}

# Both tables are read through the product's own loader rather than by parsing a PowerShell literal out of
# a script. They stopped being literals when the catalog moved into catalog\*.json, and the AST readers that
# replaced them here returned an empty table instead of failing -- SA15 reported catalog=0 and SA14 died on a
# missing KeyValuePairs. A cross-table consistency check that cannot read one of the tables is not a weaker
# check, it is no check; going through the loader means the test reads exactly what the product reads, and a
# third home for the data cannot quietly desynchronise the two again.
. (Join-Path $script:Skill 'scripts\lib\tool-catalog-common.ps1')

# Builtin only, deliberately: both halves compare against tables that ship with the skill. The learned layer
# is grown on the user's machine, and requiring the shipped plain-language table to explain a capability the
# user taught it would be a false alarm on a working install.
function Get-BridgeCapabilityId {
    param([string]$SkillPath)
    $bridge = Get-CapabilityBridgeTable -SkillRoot $SkillPath -BuiltinOnly
    return @($bridge.Keys | ForEach-Object { [string]$_ })
}

# role id -> the filenames discover-tools will actually look for. Both halves of SA15 need it.
function Get-CatalogRoleName {
    param([string]$SkillPath)
    $map = @{}
    foreach ($role in @(Get-ToolRoleTable -SkillRoot $SkillPath -BuiltinOnly)) {
        $id = [string]$role.id
        if ($id -ne '') { $map[$id] = @($role.names) }
    }
    return $map
}

$script:SuggestScript = Join-Path $script:Skill 'scripts\suggest-tool-acquisition.ps1'

# --- fixtures --------------------------------------------------------------------------------------------
$noSnapshot = Join-Path $FixtureRoot 'sa-no-snapshot'
New-Item -ItemType Directory -Force -Path $noSnapshot | Out-Null
$narrow = New-Snapshot -Name 'sa-narrow'
$rootsOnly = New-Snapshot -Name 'sa-rootsonly' -DeepScan $true -RootsOnly $true
$indexed = New-Snapshot -Name 'sa-indexed' -UseEverything $true
$deep = New-Snapshot -Name 'sa-deep' -DeepScan $true
$fakeEs = Join-Path $FixtureRoot 'es.exe'
[IO.File]::WriteAllText($fakeEs, 'inert', [Text.Encoding]::ASCII)
$dnspy = Join-Path $FixtureRoot 'fake-dnspy.exe'
[IO.File]::WriteAllText($dnspy, 'inert', [Text.Encoding]::ASCII)
$haveDotnet = New-Snapshot -Name 'sa-have-dotnet' -DeepScan $true -Tools @([pscustomobject]@{ tool_id = 'dotnet-static'; available = $true; path = $dnspy })

# --- SA1: never searched is not "searched and missing" ----------------------------------------------------
$r = Invoke-Suggest -Case 'SA1' -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $noSnapshot)
Add-Result -Name 'SA1-no-inventory-refuses' -Passed ($r.Verdict -eq 'rejected_no_discovery' -and $r.ExitCode -eq 3) -Expected 'rejected_no_discovery/3' -Actual ('{0}/{1}' -f $r.Verdict, $r.ExitCode)

# --- SA2-SA5: the search-coverage gate. The user's standing worry is a tool on another drive, so a
# suggestion may only rest on a snapshot that actually covered every disk. -------------------------------
$r = Invoke-Suggest -Case 'SA2' -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $narrow)
Add-Result -Name 'SA2-narrow-scan-refuses' -Passed ($r.Verdict -eq 'rejected_search_incomplete' -and $r.Reason -eq 'not_whole_disk' -and $r.ExitCode -eq 3) -Expected 'rejected_search_incomplete/not_whole_disk/3' -Actual ('{0}/{1}/{2}' -f $r.Verdict, $r.Reason, $r.ExitCode)
Add-Result -Name 'SA2-narrow-scan-offers-rescan' -Passed ($r.Text -match 'discover-tools\.ps1') -Expected 'names the rescan command' -Actual $(if ($r.Text -match 'discover-tools\.ps1') { 'named' } else { 'absent' })

$r = Invoke-Suggest -Case 'SA3' -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $rootsOnly)
Add-Result -Name 'SA3-rootsonly-beats-deepscan' -Passed ($r.Verdict -eq 'rejected_search_incomplete' -and $r.Reason -eq 'search_roots_only') -Expected 'rejected/search_roots_only' -Actual ('{0}/{1}' -f $r.Verdict, $r.Reason)

# discovery_inputs.use_everything records that the index was REQUESTED; discover-tools silently falls back
# to the directory walk when es.exe is absent and only says so on stdout. Trusting the flag alone would let
# a walk-only snapshot pass as whole-disk evidence -- the exact wrong answer this gate exists to prevent.
$r = Invoke-Suggest -Case 'SA4' -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $indexed, '-EverythingExePath', (Join-Path $FixtureRoot 'no-such-es.exe'))
Add-Result -Name 'SA4-everything-claim-unverified' -Passed ($r.Verdict -eq 'rejected_search_incomplete' -and $r.Reason -eq 'everything_unverifiable') -Expected 'rejected/everything_unverifiable' -Actual ('{0}/{1}' -f $r.Verdict, $r.Reason)

$r = Invoke-Suggest -Case 'SA5' -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $indexed, '-EverythingExePath', $fakeEs)
Add-Result -Name 'SA5-everything-verified-proceeds' -Passed ($r.Verdict -eq 'suggest_install' -and $r.Scope -eq 'everything-index') -Expected 'suggest_install/everything-index' -Actual ('{0}/{1}' -f $r.Verdict, $r.Scope)

# --- SA6: do not ask for what the machine already has -----------------------------------------------------
$r = Invoke-Suggest -Case 'SA6' -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $haveDotnet)
Add-Result -Name 'SA6-available-no-install-ask' -Passed ($r.Verdict -eq 'already_available' -and $r.ExitCode -eq 0 -and $r.Text -notmatch 'winget install') -Expected 'already_available/0/no-command' -Actual ('{0}/{1}/{2}' -f $r.Verdict, $r.ExitCode, $(if ($r.Text -match 'winget install') { 'has-command' } else { 'no-command' }))

# --- SA7: the four things the message must always carry ---------------------------------------------------
$r = Invoke-Suggest -Case 'SA7' -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $deep)
Add-Result -Name 'SA7-suggests-install' -Passed ($r.Verdict -eq 'suggest_install' -and $r.ExitCode -eq 0) -Expected 'suggest_install/0' -Actual ('{0}/{1}' -f $r.Verdict, $r.ExitCode)
$sections = @('【1/4 缺什么】', '【2/4 我已经找过哪些地方】', '【3/4 具体怎么拿到它】', '【4/4 你点头之后会发生什么】')
$missingSections = @($sections | Where-Object { -not $r.Text.Contains($_) })
Add-Result -Name 'SA7-all-four-sections' -Passed ($missingSections.Count -eq 0) -Expected 'four sections' -Actual $(if ($missingSections.Count -eq 0) { 'all present' } else { 'missing: ' + ($missingSections -join ',') })
Add-Result -Name 'SA7-plain-language-not-id' -Passed ($r.Text -match '把 \.NET 程序集还原成 C# 源码') -Expected 'capability in plain words' -Actual $(if ($r.Text -match '把 \.NET 程序集还原成 C# 源码') { 'present' } else { 'absent' })
Add-Result -Name 'SA7-says-whole-disk-searched' -Passed ($r.Text -match '覆盖磁盘' -and $r.Text -match '不是只搜 C 盘') -Expected 'states whole-disk coverage' -Actual $(if ($r.Text -match '不是只搜 C 盘') { 'stated' } else { 'absent' })
Add-Result -Name 'SA7-command-is-pinned' -Passed ($r.Command -match '^winget install --exact --id dnSpyEx\.dnSpy --version 6\.6\.0\b') -Expected 'pinned winget command' -Actual $r.Command
Add-Result -Name 'SA7-says-what-happens-next' -Passed ($r.Text -match 'discover-tools\.ps1' -and $r.Text -match 'resolve-capability') -Expected 'rediscover + confirm named' -Actual $(if ($r.Text -match 'resolve-capability') { 'named' } else { 'absent' })
Add-Result -Name 'SA7-declares-nothing-installed' -Passed ($r.Text -match '(?m)^installed=no$') -Expected 'installed=no' -Actual $(if ($r.Text -match '(?m)^installed=no$') { 'declared' } else { 'absent' })

# --- SA8: no winget package -> an official page, not an invented package id -------------------------------
$r = Invoke-Suggest -Case 'SA8' -ScriptArgs @('-CapabilityId', 'instrument.runtime', '-ProductRoot', $deep)
Add-Result -Name 'SA8-manual-download-verdict' -Passed ($r.Verdict -eq 'suggest_manual_download' -and $r.Command -match '^https://') -Expected 'suggest_manual_download/url' -Actual ('{0}/{1}' -f $r.Verdict, $r.Command)
Add-Result -Name 'SA8-no-fabricated-winget-id' -Passed ($r.Text -notmatch 'winget install') -Expected 'no winget command' -Actual $(if ($r.Text -match 'winget install') { 'has-command' } else { 'none' })

# --- SA9-SA10: coming back empty-handed is a correct answer, and must stay one ----------------------------
$r = Invoke-Suggest -Case 'SA9' -ScriptArgs @('-CapabilityId', 'diff.binary', '-ProductRoot', $deep)
Add-Result -Name 'SA9-no-candidate-verdict' -Passed ($r.Verdict -eq 'no_candidate' -and $r.Reason -eq 'no_verified_route') -Expected 'no_candidate/no_verified_route' -Actual ('{0}/{1}' -f $r.Verdict, $r.Reason)
Add-Result -Name 'SA9-empty-handed-is-exit-0' -Passed ($r.ExitCode -eq 0) -Expected '0' -Actual ([string]$r.ExitCode)
Add-Result -Name 'SA9-says-found-no-candidate' -Passed ($r.Text -match '我没找到候选' -and $r.Text -notmatch 'winget install') -Expected 'admits it, names nothing' -Actual $(if ($r.Text -match 'winget install') { 'named a tool anyway' } else { 'admitted' })

$r = Invoke-Suggest -Case 'SA10' -ScriptArgs @('-CapabilityId', 'debug.dynamic', '-ProductRoot', $deep, '-FailedTool', 'x64dbg.exe')
Add-Result -Name 'SA10-tried-tool-not-resuggested' -Passed ($r.Verdict -eq 'no_candidate' -and $r.Reason -eq 'all_candidates_already_tried' -and $r.Text -notmatch 'winget install') -Expected 'no_candidate/all_candidates_already_tried' -Actual ('{0}/{1}' -f $r.Verdict, $r.Reason)

# --- SA11-SA12: "I did not find it" is not "it does not exist". A frozen upstream has no newer release to
# go and get, so sending the user to install one is an errand that can never succeed. --------------------
# The comma-joined form is the only one that survives `powershell -File`: measured on both hosts, an array
# parameter binds "a,b,c" as one string and drops everything after the first token of "a b c". So this case
# also pins that all three tools really did register, not just the first.
$r = Invoke-Suggest -Case 'SA11' -ScriptArgs @('-CapabilityId', 'unpack.pe.upx', '-ProductRoot', $deep, '-FailedTool', 'upx.exe,7z.exe,innoextract.exe')
Add-Result -Name 'SA11-frozen-ceiling-verdict' -Passed ($r.Verdict -eq 'not_acquirable' -and $r.Reason -eq 'upstream_frozen_ceiling') -Expected 'not_acquirable/upstream_frozen_ceiling' -Actual ('{0}/{1}' -f $r.Verdict, $r.Reason)
Add-Result -Name 'SA11-frozen-sends-nobody-shopping' -Passed ($r.Text -notmatch 'winget install' -and $r.Text -match '不存在') -Expected 'no install errand' -Actual $(if ($r.Text -match 'winget install') { 'sent shopping' } else { 'held' })
$allThree = @('upx.exe', '7z.exe', 'innoextract.exe' | Where-Object { $r.Text -notmatch [regex]::Escape($_) })
Add-Result -Name 'SA11-every-tried-tool-registered' -Passed ($allThree.Count -eq 0) -Expected 'all three listed' -Actual $(if ($allThree.Count -eq 0) { 'all listed' } else { 'dropped: ' + ($allThree -join ',') })

$r = Invoke-Suggest -Case 'SA12' -ScriptArgs @('-CapabilityId', 'unpack.pe.generic', '-ProductRoot', $deep, '-FailedTool', 'innoextract')
Add-Result -Name 'SA12-others-remain-suggestable' -Passed ($r.Verdict -eq 'suggest_install') -Expected 'suggest_install' -Actual $r.Verdict
Add-Result -Name 'SA12-frozen-tool-not-reoffered' -Passed ($r.Text -notmatch 'dscharrer\.innoextract') -Expected 'innoextract not re-offered' -Actual $(if ($r.Text -match 'dscharrer\.innoextract') { 're-offered' } else { 'withheld' })
Add-Result -Name 'SA12-frozen-caveat-still-said' -Passed ($r.Text -match '装新版是不存在的事') -Expected 'ceiling stated' -Actual $(if ($r.Text -match '装新版是不存在的事') { 'stated' } else { 'silent' })

# --- SA13: an id it cannot explain must not become a tool name -------------------------------------------
$r = Invoke-Suggest -Case 'SA13' -ScriptArgs @('-CapabilityId', 'totally.made.up.capability', '-ProductRoot', $deep)
Add-Result -Name 'SA13-unknown-capability-refuses' -Passed ($r.Verdict -eq 'unknown_capability' -and $r.ExitCode -eq 3 -and $r.Text -notmatch 'winget install') -Expected 'unknown_capability/3/no-command' -Actual ('{0}/{1}/{2}' -f $r.Verdict, $r.ExitCode, $(if ($r.Text -match 'winget install') { 'has-command' } else { 'no-command' }))

# --- SA14: the plain-language table must cover exactly the bridge's capabilities. A capability the bridge
# gained and this table did not would reach a user as a bare id, which is what the table exists to end. ---
$tableError = ''
$bridgeIds = @()
$plainIds = @()
try {
    $bridgeIds = @(Get-BridgeCapabilityId -SkillPath $script:Skill)
    $plainIds = @(Get-StringLiteralKey -HashtableAst (Get-OuterHashtableAst -Value (Get-AssignedValueAst -Path $script:SuggestScript -VariableName 'CapabilityPlainLanguage')))
}
catch { $tableError = $_.Exception.Message }
$tablesRead = ($tableError -eq '' -and $bridgeIds.Count -ge 20 -and $plainIds.Count -ge 20)
Add-Result -Name 'SA14-tables-readable' -Passed $tablesRead -Expected '>=20 each' -Actual $(if ($tableError -ne '') { $tableError } else { 'bridge={0} plain={1}' -f $bridgeIds.Count, $plainIds.Count })
$unexplained = @($bridgeIds | Where-Object { $plainIds -notcontains $_ })
$orphanPlain = @($plainIds | Where-Object { $bridgeIds -notcontains $_ })
Add-Result -Name 'SA14-every-capability-explained' -Passed ($tablesRead -and $unexplained.Count -eq 0) -Expected 'none' -Actual $(if (-not $tablesRead) { 'tables-unreadable' } elseif ($unexplained.Count -eq 0) { 'none' } else { $unexplained -join ',' })
Add-Result -Name 'SA14-no-orphan-explanations' -Passed ($tablesRead -and $orphanPlain.Count -eq 0) -Expected 'none' -Actual $(if (-not $tablesRead) { 'tables-unreadable' } elseif ($orphanPlain.Count -eq 0) { 'none' } else { $orphanPlain -join ',' })

# --- SA15: a suggested tool must be one rediscovery will recognise. Suggesting something whose filename is
# not in that role's names list means the user installs it, the rescan still reports no, and they have made
# a wasted trip -- exactly the outcome this whole chain is built to avoid. --------------------------------
$catalogError = ''
$catalogNames = @{}
$acquisitionRoles = @()
$badExe = New-Object System.Collections.Generic.List[string]
try {
        $catalogNames = Get-CatalogRoleName -SkillPath $script:Skill
    $acquisitionAst = Get-OuterHashtableAst -Value (Get-AssignedValueAst -Path $script:SuggestScript -VariableName 'RoleAcquisition')
    foreach ($pair in $acquisitionAst.KeyValuePairs) {
        $role = [string]$pair.Item1.Value
        $acquisitionRoles += $role
        foreach ($entry in @($pair.Item2.FindAll({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true))) {
            foreach ($field in $entry.KeyValuePairs) {
                if ($field.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                if (([string]$field.Item1.Value) -ne 'exe') { continue }
                $value = $field.Item2.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
                $exe = if ($null -eq $value) { '' } else { [string]$value.Value }
                if (-not $catalogNames.ContainsKey($role) -or @($catalogNames[$role]) -notcontains $exe) { [void]$badExe.Add("$role/$exe") }
            }
        }
    }
}
catch { $catalogError = $_.Exception.Message }
$catalogRead = ($catalogError -eq '' -and $catalogNames.Count -ge 20 -and $acquisitionRoles.Count -ge 10)
Add-Result -Name 'SA15-catalog-readable' -Passed $catalogRead -Expected 'catalog>=20 roles>=10' -Actual $(if ($catalogError -ne '') { $catalogError } else { 'catalog={0} roles={1}' -f $catalogNames.Count, $acquisitionRoles.Count })
$orphanRoles = @($acquisitionRoles | Where-Object { -not $catalogNames.ContainsKey($_) })
Add-Result -Name 'SA15-no-orphan-roles' -Passed ($catalogRead -and $orphanRoles.Count -eq 0) -Expected 'none' -Actual $(if (-not $catalogRead) { 'unreadable' } elseif ($orphanRoles.Count -eq 0) { 'none' } else { $orphanRoles -join ',' })
Add-Result -Name 'SA15-suggested-exe-is-discoverable' -Passed ($catalogRead -and $badExe.Count -eq 0) -Expected 'none' -Actual $(if (-not $catalogRead) { 'unreadable' } elseif ($badExe.Count -eq 0) { 'none' } else { ($badExe | Select-Object -First 6) -join ',' })

# --- SA16: there is no unattended-install tier in this chain, by the user's explicit decision. The command
# text lives in string literals; anything that actually INVOKES an installer or a download is the tier
# reappearing, so this walks the AST for real command invocations rather than grepping the file. ---------
$bannedCommands = @('winget', 'start-process', 'invoke-webrequest', 'invoke-restmethod', 'iwr', 'irm', 'curl', 'wget', 'git', 'pip', 'pip3', 'npm', 'choco', 'scoop', 'msiexec', 'invoke-expression', 'iex', 'start-bitstransfer', 'remove-item', 'set-content', 'out-file')
$astError = ''
$invoked = @()
try {
    $tokens = $null
    $errors = $null
    $suggestAst = [System.Management.Automation.Language.Parser]::ParseFile($script:SuggestScript, [ref]$tokens, [ref]$errors)
    $invoked = @($suggestAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { [string]$_.GetCommandName() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.ToLowerInvariant() } |
        Sort-Object -Unique)
}
catch { $astError = $_.Exception.Message }
$forbidden = @($invoked | Where-Object { $bannedCommands -contains $_ })
Add-Result -Name 'SA16-script-parses' -Passed ($astError -eq '' -and $invoked.Count -gt 0) -Expected 'parsed' -Actual $(if ($astError -ne '') { $astError } else { "$($invoked.Count) commands" })
Add-Result -Name 'SA16-never-installs-or-writes' -Passed ($astError -eq '' -and $forbidden.Count -eq 0) -Expected 'none' -Actual $(if ($astError -ne '') { 'unparsed' } elseif ($forbidden.Count -eq 0) { 'none' } else { $forbidden -join ',' })

# --- SA17: every path above is a verdict, never a stack trace ---------------------------------------------
Add-Result -Name 'SA17-no-stack-traces' -Passed ($script:StackTraceSeen.Count -eq 0) -Expected 'clean' -Actual $(if ($script:StackTraceSeen.Count -eq 0) { 'clean' } else { ($script:StackTraceSeen | Sort-Object -Unique) -join ',' })

$failed = @($script:Results | Where-Object { -not $_.Passed })
Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f @($script:Results | Where-Object { $_.Passed }).Count, $failed.Count)
if (-not $KeepFixture -and (Test-Path -LiteralPath $FixtureRoot -PathType Container)) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($failed.Count -gt 0) { exit 1 }
exit 0
