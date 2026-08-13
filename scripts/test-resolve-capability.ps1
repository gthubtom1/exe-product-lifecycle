#requires -Version 5

# Behaviour + mutation guard for resolve-capability.ps1 (step 2, read-only capability -> tool bridge).
# The bridge must degrade to a legible verdict, never a crash or a false "no tools", because gap-classify
# (step 1) turns its answer into "real capability gap" vs "dead end". Each case pins one behaviour so that
# breaking it turns the suite red.
#
# RC6 is the exception to "one behaviour per case": it reconciles the bridge table against discover-tools'
# catalog by parsing both files, because the table's role ids are a cross-file contract that no runtime code
# ever validates.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-resolve-capability.ps1

[CmdletBinding()]
param(
    [string]$SkillRoot,
    [string]$FixtureRoot = (Join-Path $env:TEMP ('eplc-resolvecap-' + [guid]::NewGuid().ToString('N').Substring(0, 8))),
    # Which host runs the script under test. Defaults to the host running this suite: probing Windows
    # PowerShell while the suite itself runs under pwsh would report a PS7 pass that never covered the
    # resolver. Pass it explicitly to pin one host regardless of who invoked the suite.
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
New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null
Write-Output ('host under test: {0} ({1} {2})' -f $script:PsHost, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Expected, [string]$Actual)
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed })
    $label = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Output ('{0}   {1,-40} expected[{2}] actual[{3}]' -f $label, $Name, $Expected, $Actual)
}

function Invoke-Resolve {
    param([string[]]$ScriptArgs)
    $path = Join-Path $script:Skill 'scripts\resolve-capability.ps1'
    $raw = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $path @ScriptArgs 2>&1 | ForEach-Object { [string]$_ })
    # $LASTEXITCODE does not exist until a native command has actually run, and StrictMode makes reading it
    # in that state fatal. Falling back to -1 keeps "no exit code at all" distinguishable from a real 0.
    $exitVar = Get-Variable -Name 'LASTEXITCODE' -ErrorAction SilentlyContinue
    $exitCode = if ($null -eq $exitVar -or $null -eq $exitVar.Value) { -1 } else { [int]$exitVar.Value }
    $verdictLine = @($raw | Where-Object { $_ -match '^RESULT:\s*' } | Select-Object -First 1)
    $verdict = if ($verdictLine.Count -eq 1) { ($verdictLine[0] -replace '^RESULT:\s*', '').Trim() } else { '(no-verdict)' }
    $toolPath = ''
    $tp = @($raw | Where-Object { $_ -match '^tool_path=' } | Select-Object -First 1)
    if ($tp.Count -eq 1) { $toolPath = ($tp[0] -replace '^tool_path=', '') }
    return [pscustomobject]@{
        Verdict       = $verdict
        ExitCode      = $exitCode
        ToolPath      = $toolPath
        Text          = ($raw -join "`n")
        HasStackTrace = @($raw | Where-Object { $_ -match 'CategoryInfo|FullyQualifiedErrorId|At line:\d+ char:\d+' }).Count -gt 0
    }
}

function New-Inventory {
    param([string]$Name, [object[]]$Tools)
    $root = Join-Path $FixtureRoot $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'product-state\tooling') | Out-Null
    $inv = [pscustomobject]@{ schema_version = 1; tools = $Tools }
    [IO.File]::WriteAllText((Join-Path $root 'product-state\tooling\TOOL-INVENTORY.json'), ($inv | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    return $root
}

# Both tables are data now (catalog/*.builtin.json merged with knowledge/tools/*.learned.json), so RC6
# reconciles them through the same reader the scripts use. The AST reader below is still needed, but for
# the opposite job: TC3 uses it to prove the old PowerShell literals have not quietly come back as a
# second source of truth.
. (Join-Path $script:Skill 'scripts\lib\tool-catalog-common.ps1')

# The value catalog_fingerprint had BEFORE the tables moved out of PowerShell, measured on the literal
# $catalog at the parent commit and pasted here as a constant on purpose. Re-deriving it from the thing
# under test would assert nothing, and unlike a discovery diff it does not depend on this machine, so it
# means the same thing in CI, on a dev box, and on a clean export.
$script:BaselineCatalogFingerprint = '1e93b392788573a9b4629d399b586cdc3809e94b87bf10ddb0b317f466c6bd59'

function New-CatalogFixture {
    # A skill root holding only the two builtin data files, so a learned layer can be written and
    # measured without touching the real one.
    param([string]$Name)
    $root = Join-Path $FixtureRoot $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'catalog') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'knowledge\tools') | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:Skill 'catalog\tools.builtin.json') -Destination (Join-Path $root 'catalog') -Force
    Copy-Item -LiteralPath (Join-Path $script:Skill 'catalog\capabilities.builtin.json') -Destination (Join-Path $root 'catalog') -Force
    return $root
}

function Get-AssignedValueAst {
    param([string]$Path, [string]$VariableName, [switch]$AllowMissing)
    $tokens = $null
    $errors = $null
    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    # Not @($errors).Count directly: @($null) is a one-element array, which would report a parse error on
    # any host that leaves the ref null instead of assigning an empty collection.
    $parseErrors = @()
    if ($null -ne $errors) { $parseErrors = @($errors) }
    if ($parseErrors.Count -gt 0) { throw ('{0} has {1} parse error(s), first: {2}' -f (Split-Path -Leaf $Path), $parseErrors.Count, $parseErrors[0].Message) }
    # UserPath keeps any scope prefix ($script:CapabilityToolMap) and is the only name property Windows
    # PowerShell 5.1 exposes here, so the scope is dropped by hand.
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

function Get-BridgeRoleMap {
    param([string]$SkillPath)
    $bridge = Get-CapabilityBridgeTable -SkillRoot $SkillPath
    $map = [ordered]@{}
    foreach ($key in @($bridge.Keys)) { $map[[string]$key] = @($bridge[$key]) }
    return [pscustomobject]@{ Source = 'catalog\capabilities.builtin.json (+ learned)'; Map = $map }
}

function Get-CatalogRoleId {
    param([string]$SkillPath)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($role in @(Get-ToolRoleTable -SkillRoot $SkillPath)) { [void]$ids.Add([string]$role.id) }
    return $ids.ToArray()
}

# RC1 -- no inventory at all must read as 'unavailable' (a normal answer), never a crash.
$rc1 = Join-Path $FixtureRoot 'rc1-no-inventory'
New-Item -ItemType Directory -Force -Path $rc1 | Out-Null
$r = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $rc1)
Add-Result -Name 'RC1-missing-inventory-unavailable' -Passed ($r.Verdict -eq 'unavailable') -Expected 'unavailable' -Actual $r.Verdict
Add-Result -Name 'RC1-no-stack-trace' -Passed (-not $r.HasStackTrace) -Expected 'clean' -Actual $(if ($r.HasStackTrace) { 'stack-trace' } else { 'clean' })

# RC2 -- capability whose only role is present but available=false must read 'unavailable'.
$rc2 = New-Inventory -Name 'rc2-unavailable' -Tools @([pscustomobject]@{ tool_id = 'dotnet-static'; available = $false; path = '' })
$r = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $rc2)
Add-Result -Name 'RC2-role-unavailable-unavailable' -Passed ($r.Verdict -eq 'unavailable') -Expected 'unavailable' -Actual $r.Verdict

# RC3 -- an id not in the bridge table must be a clean 'unknown_capability', never a crash.
$r = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'totally.made.up.capability', '-ProductRoot', $rc2)
Add-Result -Name 'RC3-unknown-capability' -Passed ($r.Verdict -eq 'unknown_capability') -Expected 'unknown_capability' -Actual $r.Verdict
Add-Result -Name 'RC3-no-stack-trace' -Passed (-not $r.HasStackTrace) -Expected 'clean' -Actual $(if ($r.HasStackTrace) { 'stack-trace' } else { 'clean' })

# RC4 -- an available tool for the capability must read 'available' and surface its path. This is the
# mutation guard against a resolver stuck always-'unavailable': break the availability match and RC4 reds.
$toolExe = Join-Path $FixtureRoot 'fake-dnspy.exe'
[IO.File]::WriteAllText($toolExe, 'inert', [Text.Encoding]::ASCII)
$rc4 = New-Inventory -Name 'rc4-available' -Tools @(
    [pscustomobject]@{ tool_id = 'pe-triage'; available = $true; path = 'C:\nope\die.exe' },
    [pscustomobject]@{ tool_id = 'dotnet-static'; available = $true; path = $toolExe })
$r = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $rc4)
Add-Result -Name 'RC4-available-when-tool-present' -Passed ($r.Verdict -eq 'available') -Expected 'available' -Actual $r.Verdict
Add-Result -Name 'RC4-surfaces-tool-path' -Passed ($r.ToolPath -eq $toolExe) -Expected 'matched-path' -Actual $(if ($r.ToolPath -eq $toolExe) { 'matched-path' } else { $r.ToolPath })

# RC5 -- a capability with several roles resolves via a later role when the earlier one is unavailable
# (guards the per-role loop from stopping at the first miss).
$upx = Join-Path $FixtureRoot 'fake-upx.exe'
[IO.File]::WriteAllText($upx, 'inert', [Text.Encoding]::ASCII)
$rc5 = New-Inventory -Name 'rc5-second-role' -Tools @([pscustomobject]@{ tool_id = 'package-inspect'; available = $true; path = $upx })
$r = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'unpack.pe.generic', '-ProductRoot', $rc5)
Add-Result -Name 'RC5-resolves-via-any-role' -Passed ($r.Verdict -eq 'available' -and $r.ToolPath -eq $upx) -Expected 'available' -Actual ("$($r.Verdict)/$($r.ToolPath -eq $upx)")

# RC6 -- every role id in the bridge table must still be an id discover-tools publishes. The table's own
# comment calls this a "MUST match" contract, but nothing enforces it: a drifted or renamed role id makes
# that capability permanently 'unavailable' -> permanently a capability_gap -> permanently pushed at the
# install gate for a tool the machine may already have, with every behavioural case above still green.
$bridge = $null
$bridgeSource = ''
$catalogIds = @()
$parseError = ''
try {
    $bridgeTable = Get-BridgeRoleMap -SkillPath $script:Skill
    $bridge = $bridgeTable.Map
    $bridgeSource = $bridgeTable.Source
    $catalogIds = Get-CatalogRoleId -SkillPath $script:Skill
} catch {
    $parseError = $_.Exception.Message
}
$capabilityCount = 0
$bridgeRoles = @()
if ($null -ne $bridge) {
    $capabilityCount = $bridge.Count
    $bridgeRoles = @($bridge.Keys | ForEach-Object { $bridge[$_] } | Sort-Object -Unique)
}
# Floors rather than exact counts: they exist only so that a reader which silently finds nothing cannot make
# the set comparisons below pass vacuously. Today the real numbers are 26 / 24 / 23.
$tablesRead = ($parseError -eq '' -and $catalogIds.Count -ge 20 -and $capabilityCount -ge 20 -and $bridgeRoles.Count -ge 20)
Add-Result -Name 'RC6-tables-readable' -Passed $tablesRead -Expected '>=20 each' -Actual $(if ($parseError -ne '') { $parseError } else { 'catalog={0} caps={1} roles={2} from={3}' -f $catalogIds.Count, $capabilityCount, $bridgeRoles.Count, (Split-Path -Leaf $bridgeSource) })

$orphanRoles = @($bridgeRoles | Where-Object { $catalogIds -notcontains $_ })
Add-Result -Name 'RC6-no-orphan-bridge-roles' -Passed ($tablesRead -and $orphanRoles.Count -eq 0) -Expected 'none' -Actual $(if (-not $tablesRead) { 'tables-unreadable' } elseif ($orphanRoles.Count -eq 0) { 'none' } else { $orphanRoles -join ',' })

# The same drift seen from the catalog side. The three roles named here are deliberately unmapped because
# they are not analysis capabilities; a NEW unmapped role means discover-tools grew something the bridge can
# never surface, so it has to be either mapped or added to this list on purpose.
$nonCapabilityRoles = @('automation', 'file-hash', 'sign-release')
$unmappedRoles = @($catalogIds | Where-Object { $bridgeRoles -notcontains $_ -and $nonCapabilityRoles -notcontains $_ })
Add-Result -Name 'RC6-no-unmapped-catalog-roles' -Passed ($tablesRead -and $unmappedRoles.Count -eq 0) -Expected 'none' -Actual $(if (-not $tablesRead) { 'tables-unreadable' } elseif ($unmappedRoles.Count -eq 0) { 'none' } else { $unmappedRoles -join ',' })

# RC7 -- every verdict is a normal answer the caller must act on, so it must exit 0; the script's footer
# states that as a contract but no test read $LASTEXITCODE, leaving callers free to start failing on a
# verdict they are supposed to handle.
$exitCases = @(
    @{ Verdict = 'available'; ScriptArgs = @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $rc4) },
    @{ Verdict = 'unavailable'; ScriptArgs = @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $rc1) },
    @{ Verdict = 'unknown_capability'; ScriptArgs = @('-CapabilityId', 'totally.made.up.capability', '-ProductRoot', $rc2) }
)
foreach ($case in $exitCases) {
    $r = Invoke-Resolve -ScriptArgs $case.ScriptArgs
    Add-Result -Name ('RC7-exit0-' + $case.Verdict) -Passed ($r.Verdict -eq $case.Verdict -and $r.ExitCode -eq 0) -Expected ($case.Verdict + '/0') -Actual ('{0}/{1}' -f $r.Verdict, $r.ExitCode)
}

# RC8 -- valid JSON in the wrong shape (no 'tools' key) must stay a loud 'resolver_error' with the non-zero
# exit the footer reserves for a crash. Both halves matter: the verdict is what keeps a broken inventory
# from being sold to gap-classify as "this machine has no such tool", and the exit code is the only signal
# left if the caller reads status instead of stdout.
$rc8 = Join-Path $FixtureRoot 'rc8-corrupt-envelope.json'
[IO.File]::WriteAllText($rc8, '{"schema_version":1,"items":[]}', (New-Object Text.UTF8Encoding($false)))
$r = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-InventoryPath', $rc8)
Add-Result -Name 'RC8-corrupt-inventory-resolver-error' -Passed ($r.Verdict -eq 'resolver_error') -Expected 'resolver_error' -Actual $r.Verdict
Add-Result -Name 'RC8-corrupt-inventory-exit-4' -Passed ($r.ExitCode -eq 4) -Expected '4' -Actual ([string]$r.ExitCode)

# RC9 -- -InventoryPath is the form the acquire gate will call with, and it must resolve exactly like
# -ProductRoot does.
$r = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-InventoryPath', (Join-Path $rc4 'product-state\tooling\TOOL-INVENTORY.json'))
Add-Result -Name 'RC9-inventorypath-available' -Passed ($r.Verdict -eq 'available' -and $r.ToolPath -eq $toolExe) -Expected 'available/matched-path' -Actual ('{0}/{1}' -f $r.Verdict, $(if ($r.ToolPath -eq $toolExe) { 'matched-path' } else { $r.ToolPath }))

# --- TC: the tables as data ------------------------------------------------------------------------
# TC1 is the migration's hard gate. The tables moved out of PowerShell and into JSON; the one thing that
# must NOT have moved is what the reuse gate computes from them. Asserting against a constant measured
# before the move is what makes this a migration proof rather than a restatement: it does not care what
# is installed here, so it means the same thing on every machine.
$tc1Actual = ''
try { $tc1Actual = Get-ToolCatalogFingerprint -Roles (Get-ToolRoleTable -SkillRoot $script:Skill -BuiltinOnly) }
catch { $tc1Actual = 'threw: ' + $_.Exception.Message }
Add-Result -Name 'TC1-fingerprint-unchanged-by-migration' -Passed ($tc1Actual -eq $script:BaselineCatalogFingerprint) -Expected $script:BaselineCatalogFingerprint.Substring(0, 16) -Actual $(if ($tc1Actual.Length -ge 16) { $tc1Actual.Substring(0, 16) } else { $tc1Actual })

# TC2 is the other half, and it is the one that guards the failure this whole layer exists to prevent.
# If the fingerprint were computed over the builtin table alone, appending a learned tool would not change
# it, the cached inventory would stay valid, and the newly learned tool would never be discovered -- while
# the append succeeded, the file really did change, and nothing reported an error. Silent, and permanent.
$tc2Root = New-CatalogFixture -Name 'tc2-learned'
Clear-ToolCatalogWarning
$tc2Before = Get-ToolCatalogFingerprint -Roles (Get-ToolRoleTable -SkillRoot $tc2Root)
$tc2Append = Add-LearnedToolName -SkillRoot $tc2Root -RoleId 'package-inspect' -Name 'tc2-learned-tool.exe' -SourceUrl 'https://example.invalid/tc2'
$tc2After = Get-ToolCatalogFingerprint -Roles (Get-ToolRoleTable -SkillRoot $tc2Root)
Add-Result -Name 'TC2-append-succeeds' -Passed ($tc2Append.Status -eq 'appended') -Expected 'appended' -Actual ($tc2Append.Status + ' ' + $tc2Append.Reason)
Add-Result -Name 'TC2-learned-changes-fingerprint' -Passed ($tc2Before -ne $tc2After -and $tc2After -ne '') -Expected 'changed' -Actual $(if ($tc2Before -ne $tc2After) { 'changed' } else { 'UNCHANGED (learned layer is outside the fingerprint)' })
# ...and the learned layer must not have leaked into the builtin reading, or TC1 would start passing for
# the wrong reason once anything is ever learned.
$tc2Builtin = Get-ToolCatalogFingerprint -Roles (Get-ToolRoleTable -SkillRoot $tc2Root -BuiltinOnly)
Add-Result -Name 'TC2-builtin-view-still-baseline' -Passed ($tc2Builtin -eq $script:BaselineCatalogFingerprint) -Expected 'baseline' -Actual $(if ($tc2Builtin -eq $script:BaselineCatalogFingerprint) { 'baseline' } else { $tc2Builtin.Substring(0, 16) })
# The merged view must contain both layers, in builtin-then-learned order.
$tc2Names = @(@(Get-ToolRoleTable -SkillRoot $tc2Root | Where-Object { $_.id -eq 'package-inspect' })[0].names)
Add-Result -Name 'TC2-merged-keeps-builtin-and-learned' -Passed ($tc2Names[0] -eq 'asar.cmd' -and $tc2Names[-1] -eq 'tc2-learned-tool.exe') -Expected 'asar.cmd..tc2-learned-tool.exe' -Actual ('{0}..{1}' -f $tc2Names[0], $tc2Names[-1])

# TC3 keeps the migration from being undone by half. A PowerShell literal reappearing next to the data
# file is the two-sources-of-truth defect the move exists to end, and the reader would keep answering from
# the file while a maintainer edited the literal and saw nothing happen.
$tc3Literals = New-Object System.Collections.Generic.List[string]
foreach ($pair in @(
        @{ File = 'scripts\discover-tools.ps1'; Variable = 'catalog' },
        @{ File = 'scripts\resolve-capability.ps1'; Variable = 'CapabilityToolMap' },
        @{ File = 'scripts\lib\capability-common.ps1'; Variable = 'CapabilityToolMap' })) {
    $literalPath = Join-Path $script:Skill $pair.File
    if (-not (Test-Path -LiteralPath $literalPath -PathType Leaf)) { continue }
    $value = Get-AssignedValueAst -Path $literalPath -VariableName $pair.Variable -AllowMissing
    if ($null -eq $value) { continue }
    # An assignment is fine (it is how the loader result is stored); a literal table is not.
    $literal = $value.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true)
    if ($null -ne $literal) { [void]$tc3Literals.Add(('{0}:${1}' -f $pair.File, $pair.Variable)) }
}
Add-Result -Name 'TC3-no-literal-table-left-in-code' -Passed ($tc3Literals.Count -eq 0) -Expected 'none' -Actual $(if ($tc3Literals.Count -eq 0) { 'none' } else { ($tc3Literals.ToArray() -join ',') })

# TC4 pins the location, because the location IS the mechanism. sync-local-skill.ps1 deletes anything in
# the installed copy the source does not have, and preserves exactly one thing: files under knowledge\.
# That exception only covers files the source does NOT have -- a learned file shipped in the source tree
# would be plainly overwritten by the copy step on every sync, wiping local learning without a word.
$tc4Paths = Get-ToolCatalogPath -SkillRoot $script:Skill
$tc4UnderKnowledge = ($tc4Paths.LearnedTools -like '*\knowledge\tools\*' -and $tc4Paths.LearnedCapabilities -like '*\knowledge\tools\*')
Add-Result -Name 'TC4-learned-layer-under-knowledge' -Passed $tc4UnderKnowledge -Expected 'knowledge\tools' -Actual $(if ($tc4UnderKnowledge) { 'knowledge\tools' } else { $tc4Paths.LearnedTools })
$tc4Shipped = @(@($tc4Paths.LearnedTools, $tc4Paths.LearnedCapabilities) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
Add-Result -Name 'TC4-learned-layer-not-shipped' -Passed ($tc4Shipped.Count -eq 0) -Expected 'absent-from-source' -Actual $(if ($tc4Shipped.Count -eq 0) { 'absent-from-source' } else { ($tc4Shipped -join ',') })

# TC5 -- "not in the table" must produce a request, not a dead end and not an invented tool name. All three
# sections have to be reachable, especially the empty-handed one: if coming back empty has no legitimate
# shape, the next best-sounding thing to emit is a confident, plausible, non-existent tool.
$tc5 = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $rc1, '-EmitToolRequest')
foreach ($section in @('[1/3]', '[2/3]', '[3/3]')) {
    Add-Result -Name ("TC5-brief-has-section-" + $section.Trim('[', ']')) -Passed ($tc5.Text -like ('*' + $section + '*')) -Expected 'present' -Actual $(if ($tc5.Text -like ('*' + $section + '*')) { 'present' } else { 'missing' })
}
Add-Result -Name 'TC5-brief-does-not-change-verdict' -Passed ($tc5.Verdict -eq 'unavailable' -and $tc5.ExitCode -eq 0) -Expected 'unavailable/0' -Actual ('{0}/{1}' -f $tc5.Verdict, $tc5.ExitCode)
# Off by default: every existing caller parses the lines above, so the brief must be opt-in.
$tc5Off = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $rc1)
Add-Result -Name 'TC5-brief-off-by-default' -Passed ($tc5Off.Text -notlike '*[1/3]*') -Expected 'absent' -Actual $(if ($tc5Off.Text -like '*[1/3]*') { 'present' } else { 'absent' })

# TC5c -- the brief must not claim the machine was searched when it was not. 'unavailable' is ALSO the
# verdict when no tool snapshot exists, so an unconditional "looked here, found nothing" would convert
# "never looked" into "confirmed absent" -- the exact not-found-means-not-there mistake this brief exists
# to prevent, committed by the brief itself. $rc1 is a product root with no inventory at all.
$tc5NoInventory = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $rc1, '-EmitToolRequest')
Add-Result -Name 'TC5c-no-inventory-admits-not-searched' -Passed ($tc5NoInventory.Text -like '*没查过*') -Expected 'says-not-searched' -Actual $(if ($tc5NoInventory.Text -like '*没查过*') { 'says-not-searched' } else { 'MISSING' })
Add-Result -Name 'TC5c-no-inventory-claims-no-search' -Passed ($tc5NoInventory.Text -notlike '*已在本机找过*') -Expected 'no-false-claim' -Actual $(if ($tc5NoInventory.Text -like '*已在本机找过*') { 'CLAIMS A SEARCH THAT NEVER RAN' } else { 'no-false-claim' })
# ...and with a real snapshot that genuinely lists the role as unavailable, it must say so plainly.
$tc5Searched = Invoke-Resolve -ScriptArgs @('-CapabilityId', 'decompile.dotnet', '-ProductRoot', $rc2, '-EmitToolRequest')
Add-Result -Name 'TC5c-real-snapshot-reports-searched' -Passed ($tc5Searched.Text -like '*已在本机找过*') -Expected 'says-searched' -Actual $(if ($tc5Searched.Text -like '*已在本机找过*') { 'says-searched' } else { 'MISSING' })

# TC5b -- a candidate with no provenance is a guess, not a candidate, and must never reach the output.
# A tool name is the easiest thing here to invent and the most expensive to disprove.
$tc5Root = New-CatalogFixture -Name 'tc5-candidates'
$tc5Doc = '{"schema_version":1,"layer":"learned","capabilities":[{"id":"tc5.capability","roles":["package-inspect"],"candidates":[{"name":"sourced-tool","source_url":"https://example.invalid/real"},{"name":"unsourced-tool"}]}]}'
[IO.File]::WriteAllText((Join-Path $tc5Root 'knowledge\tools\capabilities.learned.json'), $tc5Doc, (New-Object Text.UTF8Encoding($false)))
$tc5Lines = @(Get-ToolRequestBrief -SkillRoot $tc5Root -CapabilityId 'tc5.capability')
$tc5Brief = ($tc5Lines -join "`n")
Add-Result -Name 'TC5b-sourced-candidate-shown' -Passed ($tc5Brief -like '*sourced-tool*' -and $tc5Brief -like '*https://example.invalid/real*') -Expected 'shown-with-url' -Actual $(if ($tc5Brief -like '*https://example.invalid/real*') { 'shown-with-url' } else { 'missing' })
# A name with no provenance must never appear as a numbered candidate...
$tc5CandidateLines = @($tc5Lines | Where-Object { $_ -match '^\s+\d+\.\s' })
$tc5UnsourcedAsCandidate = @($tc5CandidateLines | Where-Object { $_ -like '*unsourced-tool*' })
Add-Result -Name 'TC5b-unsourced-not-a-candidate' -Passed ($tc5UnsourcedAsCandidate.Count -eq 0) -Expected 'not-a-candidate' -Actual $(if ($tc5UnsourcedAsCandidate.Count -gt 0) { 'OFFERED AS CANDIDATE' } else { 'not-a-candidate' })
# ...but it must still have somewhere honest to go. Deleting it outright is a gate with no exit: the
# cheapest way to satisfy "candidates need a URL" would then be to invent one, and a fabricated source is
# worse than an unsourced name because it reads as already verified.
$tc5LeadHeader = @($tc5Lines | Where-Object { $_ -like '*无出处的线索*' })
$tc5LeadListed = @($tc5Lines | Where-Object { $_ -match '^\s+-\s' -and $_ -like '*unsourced-tool*' })
Add-Result -Name 'TC5b-unsourced-has-a-legitimate-place' -Passed ($tc5LeadHeader.Count -eq 1 -and $tc5LeadListed.Count -eq 1) -Expected 'listed-as-lead' -Actual ('header={0} listed={1}' -f $tc5LeadHeader.Count, $tc5LeadListed.Count)

# TC6 -- appending a tool NAME is data enrichment and is automatic; mapping a capability to a role changes
# the verdict gap-classify and the install gate consume, so it rides on the approval the user already
# gives. Unapproved must report pending, never silently apply and never silently drop.
$tc6Root = New-CatalogFixture -Name 'tc6-bridge'
$tc6Pending = Add-LearnedCapabilityRole -SkillRoot $tc6Root -CapabilityId 'tc6.capability' -RoleId 'package-inspect'
$tc6BridgeAfterPending = Get-CapabilityBridgeTable -SkillRoot $tc6Root
Add-Result -Name 'TC6-unapproved-bridge-is-pending' -Passed ($tc6Pending.Status -eq 'pending_approval') -Expected 'pending_approval' -Actual $tc6Pending.Status
Add-Result -Name 'TC6-unapproved-bridge-not-applied' -Passed (-not $tc6BridgeAfterPending.Contains('tc6.capability')) -Expected 'not-applied' -Actual $(if ($tc6BridgeAfterPending.Contains('tc6.capability')) { 'APPLIED WITHOUT APPROVAL' } else { 'not-applied' })
$tc6Approved = Add-LearnedCapabilityRole -SkillRoot $tc6Root -CapabilityId 'tc6.capability' -RoleId 'package-inspect' -Approved
$tc6BridgeAfterApproval = Get-CapabilityBridgeTable -SkillRoot $tc6Root
Add-Result -Name 'TC6-approved-bridge-applied' -Passed ($tc6Approved.Status -eq 'appended' -and $tc6BridgeAfterApproval.Contains('tc6.capability')) -Expected 'applied' -Actual ('{0}/{1}' -f $tc6Approved.Status, $tc6BridgeAfterApproval.Contains('tc6.capability'))

# TC7 -- the append granularity is "add a name to an existing role", never "invent a role". A new role is a
# change to the capability taxonomy and has to be adjudicated, so the helper refuses it out loud...
$tc7 = Add-LearnedToolName -SkillRoot $tc6Root -RoleId 'role-that-does-not-exist' -Name 'whatever.exe' -AddedForCapability 'tc7.capability'
Add-Result -Name 'TC7-refuses-to-invent-a-role' -Passed ($tc7.Status -eq 'needs_new_role') -Expected 'needs_new_role' -Actual ($tc7.Status + ' ' + $tc7.Reason)
$tc7Roles = @(Get-ToolRoleTable -SkillRoot $tc6Root | ForEach-Object { $_.id })
Add-Result -Name 'TC7-role-not-created' -Passed ($tc7Roles -notcontains 'role-that-does-not-exist') -Expected 'not-created' -Actual $(if ($tc7Roles -contains 'role-that-does-not-exist') { 'CREATED' } else { 'not-created' })
# ...and it hands back a filled-in escalation rather than a bare "no". Whoever hits this gate is in a real
# situation -- none of the 26 classes fit -- and if that cannot be stated, the only other ways out are to
# give up or to file the tool under a role where it does not belong, which nobody can spot afterwards.
$tc7Escalation = @($tc7.Escalation)
$tc7Names = ($tc7Escalation -join "`n")
$tc7Usable = ($tc7Escalation.Count -ge 4 -and $tc7Names -like '*whatever.exe*' -and $tc7Names -like '*role-that-does-not-exist*' -and $tc7Names -like '*package-inspect*')
Add-Result -Name 'TC7-refusal-carries-an-exit' -Passed $tc7Usable -Expected 'escalation-with-tool-wanted-role-and-existing-classes' -Actual ('lines={0}' -f $tc7Escalation.Count)

# TC8 -- a corrupt learned layer must be loud. Skipping it silently would drop the fingerprint back to the
# builtin value, and every learned tool would become invisible again with nothing in the output to say so.
$tc8Root = New-CatalogFixture -Name 'tc8-corrupt'
[IO.File]::WriteAllText((Join-Path $tc8Root 'knowledge\tools\tools.learned.json'), '{ this is not json', (New-Object Text.UTF8Encoding($false)))
Clear-ToolCatalogWarning
# The WARNING this prints is the assertion below, not noise: being loud is the behaviour under test.
$tc8Roles = @(Get-ToolRoleTable -SkillRoot $tc8Root)
$tc8Warnings = @(Get-ToolCatalogWarning)
Add-Result -Name 'TC8-corrupt-learned-still-serves-builtin' -Passed ($tc8Roles.Count -eq 26) -Expected '26' -Actual ([string]$tc8Roles.Count)
Add-Result -Name 'TC8-corrupt-learned-is-announced' -Passed ($tc8Warnings.Count -ge 1) -Expected '>=1 warning' -Actual ([string]$tc8Warnings.Count)
Clear-ToolCatalogWarning

$failed = @($script:Results | Where-Object { -not $_.Passed })
Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f @($script:Results | Where-Object { $_.Passed }).Count, $failed.Count)
if (-not $KeepFixture -and (Test-Path -LiteralPath $FixtureRoot -PathType Container)) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($failed.Count -gt 0) { exit 1 }
