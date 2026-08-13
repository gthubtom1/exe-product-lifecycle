#requires -Version 5
<#
Behaviour suite for discover-tools.ps1 reuse + atomic inventory write.
Runs the same twelve scenarios against any copy of the script, so the landed version and a
candidate version can be compared line by line.

    powershell -NoProfile -ExecutionPolicy Bypass -File test-tool-inventory-reuse.ps1 [-ScriptPath <discover-tools.ps1>]

ScriptPath defaults to the sibling discover-tools.ps1 so the suite runs argument-free in CI,
matching the other regression entry points; pass it explicitly only to compare a candidate copy.

Every scenario works inside a throwaway product root under $env:TEMP. Nothing outside that
fixture root is written, and the target EXE catalogue is never executed.
#>

[CmdletBinding()]
param(
    [string]$ScriptPath,
    [string]$FixtureRoot = (Join-Path $env:TEMP ('eplc-reuse-suite-' + [guid]::NewGuid().ToString('N').Substring(0, 8))),
    # The suite itself runs under either host; this selects the host the script under test runs in,
    # so the same file can cover the Windows PowerShell 5.1 and the pwsh 7 CI lane.
    [string]$PowerShellHost = 'powershell',
    # Caps how deep every discovery walk descends. 0 means "do not pass it", so the script keeps its
    # own default of 10 and a local run is unchanged. CI passes a small value: the machine-wide sweep
    # is still real and full-MODE (every drive and every conventional tool-folder name is still
    # crossed, so R1/R7/R15 stay meaningful and the very sweep that hid the 8.3-path and drive bugs
    # is still exercised), it just does not descend ten levels into C:\Program Files -- which is the
    # documented reason a cold discovery cost minutes on the runner. Forwarded to EVERY call so the
    # whole suite shares one depth and the reuse fingerprint stays internally consistent.
    [ValidateRange(0, 16)][int]$MaxSearchDepth = 0,
    [switch]$KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($ScriptPath)) { $ScriptPath = Join-Path $PSScriptRoot 'discover-tools.ps1' }
$script:Script = (Resolve-Path -LiteralPath $ScriptPath).Path
$script:Results = New-Object System.Collections.Generic.List[psobject]
# Prepended to every discovery so one depth governs the whole run; empty when -MaxSearchDepth is 0.
$script:CommonDiscoverArgs = if ($MaxSearchDepth -gt 0) { @('-MaxSearchDepth', [string]$MaxSearchDepth) } else { @() }
New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null

function Invoke-Discover {
    param([string]$Root, [string[]]$ExtraArgs = @())

    $callArgs = @($script:CommonDiscoverArgs) + @($ExtraArgs)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $raw = @(& $PowerShellHost -NoProfile -ExecutionPolicy Bypass -File $script:Script -ProductRoot $Root @callArgs 2>&1)
    $stopwatch.Stop()
    $text = @($raw | ForEach-Object { [string]$_ })
    $map = @{}
    foreach ($line in $text) {
        if ($line -match '^\s*([a-z_]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
    }
    return [pscustomobject]@{
        Seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        Keys = $map
        Text = ($text -join ' ; ')
        Crashed = @($text | Where-Object { $_ -match 'CategoryInfo|Exception|FullyQualifiedErrorId' }).Count -gt 0
    }
}

function Get-Key {
    param($Run, [string]$Name)
    if ($Run.Keys.ContainsKey($Name)) { return [string]$Run.Keys[$Name] }
    return '<none>'
}

function Get-Json {
    param([string]$Root)
    $path = Join-Path $Root 'product-state\tooling\TOOL-INVENTORY.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json } catch { return $null }
}

function Set-Json {
    param([string]$Root, $Value)
    $path = Join-Path $Root 'product-state\tooling\TOOL-INVENTORY.json'
    ($Value | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding utf8
}

function New-Product {
    param([string]$Name, [string]$SeedFrom)

    $target = Join-Path $FixtureRoot $Name
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    if ($SeedFrom) {
        Copy-Item -LiteralPath (Join-Path $SeedFrom 'product-state') -Destination (Join-Path $target 'product-state') -Recurse -Force
    }
    return $target
}

function Add-Result {
    param([string]$Id, [string]$Expected, [string]$Actual)

    $status = if ($Actual -eq $Expected) { 'PASS' } else { 'FAIL' }
    [void]$script:Results.Add([pscustomobject]@{ Id = $Id; Status = $status; Expected = $Expected; Actual = $Actual })
    "{0,-6} {1,-34} expected[{2}] actual[{3}]" -f $status, $Id, $Expected, $Actual
}

# R0 -SearchRootsOnly searches only what the caller named. The machine-wide sweep is what makes a
# cold discovery cost minutes, and most questions -- "is the toolchain in this folder" -- do not
# need it. Asserted on the scope the run reports rather than on which tools turned up: PATH lookup
# still applies in both modes, so a tool on PATH cannot tell them apart.
$seed = New-Product -Name 'seed'
$narrowRoot = Join-Path $FixtureRoot 'narrow-tools'
New-Item -ItemType Directory -Force -Path $narrowRoot | Out-Null
$narrowArgs = @('-SearchRootsOnly', '-AdditionalSearchRoot', $narrowRoot)
$narrow = Invoke-Discover -Root $seed -ExtraArgs $narrowArgs
Add-Result -Id 'R0-narrow-declared' -Expected 'yes' -Actual (Get-Key $narrow 'searchrootsonly')
# Exactly the one directory named, and no drive walked: a full run reports many roots and every
# fixed drive, so removing the switch's effect turns both of these red immediately.
Add-Result -Id 'R0-searches-only-named-root' -Expected '1' -Actual (Get-Key $narrow 'searchroots')
Add-Result -Id 'R0-probes-no-drive' -Expected '0' -Actual (Get-Key $narrow 'probeddrives')
"       R0 narrow run took $($narrow.Seconds)s"

# R1 cold discovery establishes the seed snapshot every later scenario copies. It asks for reuse on
# purpose: the only thing in the cache is R0's narrow snapshot, and a narrow snapshot must never be
# accepted as evidence about the whole machine -- otherwise one fast scoped run would poison every
# later full run into reporting tools as missing. Refusing it here is what makes this a cold run.
$cold = Invoke-Discover -Root $seed -ExtraArgs @('-ReuseInventory')
Add-Result -Id 'R1-cold-discovery' -Expected 'full-discovery' -Actual (Get-Key $cold 'reuse')
Add-Result -Id 'R1-narrow-snapshot-not-reused-by-full-run' -Expected 'full-discovery' -Actual (Get-Key $cold 'reuse')
"       R1 cold run took $($cold.Seconds)s, available=$(Get-Key $cold 'available') total=$(Get-Key $cold 'total')"

# R2 a reuse hit must be fast and must say so.
$p2 = New-Product -Name 'reuse-hit' -SeedFrom $seed
$hit = Invoke-Discover -Root $p2 -ExtraArgs @('-ReuseInventory')
Add-Result -Id 'R2-reuse-applied' -Expected 'applied' -Actual (Get-Key $hit 'reuse')
Add-Result -Id 'R2-reuse-is-faster' -Expected 'yes' -Actual $(if ($hit.Seconds -lt ($cold.Seconds / 2)) { 'yes' } else { "no($($hit.Seconds)s)" })
Add-Result -Id 'R2-rows-preserved' -Expected (Get-Key $cold 'total') -Actual (Get-Key $hit 'total')

# R3 the host tool index that produced the reused rows must survive the reuse run.
$seedJson = Get-Json -Root $seed
$hitJson = Get-Json -Root $p2
$seedHost = if ($seedJson) { [string]$seedJson.host_tool_index } else { '<no json>' }
$hitHost = if ($hitJson) { [string]$hitJson.host_tool_index } else { '<no json>' }
Add-Result -Id 'R3-host-index-kept' -Expected 'kept' -Actual $(if ([string]::IsNullOrWhiteSpace($seedHost) -or $hitHost -eq $seedHost) { 'kept' } else { "lost([$hitHost])" })

# R4 reuse must not restamp generated_at, or a snapshot renews its own freshness forever.
$seedStamp = if ($seedJson) { [string]$seedJson.generated_at } else { '' }
$hitStamp = if ($hitJson) { [string]$hitJson.generated_at } else { '' }
Add-Result -Id 'R4-generated-at-stable' -Expected 'stable' -Actual $(if ($hitStamp -eq $seedStamp) { 'stable' } else { 'restamped' })

# R5 adding a search root is the standard repair for a missing tool: it must never be ignored.
$fakeTools = Join-Path $FixtureRoot 'fake-tools'
New-Item -ItemType Directory -Force -Path $fakeTools | Out-Null
Set-Content -LiteralPath (Join-Path $fakeTools 'ida64.exe') -Value 'fixture placeholder, never executed' -Encoding ascii
$p5 = New-Product -Name 'new-search-root' -SeedFrom $seed
$withRoot = Invoke-Discover -Root $p5 -ExtraArgs @('-ReuseInventory', '-AdditionalSearchRoot', $fakeTools)
$p5json = Get-Json -Root $p5
$native = if ($p5json) { @($p5json.tools | Where-Object { $_.tool_id -eq 'native-static' })[0] } else { $null }
$nativeFound = if ($native -and $native.available) { 'found' } else { 'still-missing' }
Add-Result -Id 'R5-new-root-not-ignored' -Expected 'found' -Actual $nativeFound
"       R5 reuse=$(Get-Key $withRoot 'reuse') reason=$(Get-Key $withRoot 'reuserejected')"

# R6 an ancient snapshot must not be reusable just because its files still exist.
$p6 = New-Product -Name 'ancient' -SeedFrom $seed
$anc = Get-Json -Root $p6
$anc.generated_at = '2020-01-01T00:00:00.0000000+08:00'
Set-Json -Root $p6 -Value $anc
$ancient = Invoke-Discover -Root $p6 -ExtraArgs (@('-ReuseInventory') + $narrowArgs)
Add-Result -Id 'R6-stale-rejected' -Expected 'full-discovery' -Actual (Get-Key $ancient 'reuse')

# R7 the required same-batch existence spot-check: an uninstalled tool forces rediscovery.
$p7 = New-Product -Name 'uninstalled' -SeedFrom $seed
$broken = Get-Json -Root $p7
$victim = @($broken.tools | Where-Object { $_.available -eq $true -and $_.source -ne 'PowerShell built-in' })[0]
$victim.path = 'C:\definitely-not-here\removed-tool.exe'
Set-Json -Root $p7 -Value $broken
# Deliberately a full-mode run: the existence spot-check is the last gate, so narrowing the scan
# here would reject the cache one step earlier on changed inputs and the spot-check would never
# fire -- the assertion below would then pass without testing anything. It cost one full scan and
# it caught exactly that when this suite was first sped up.
$uninstalled = Invoke-Discover -Root $p7 -ExtraArgs @('-ReuseInventory')
Add-Result -Id 'R7-spotcheck-catches-removal' -Expected 'full-discovery' -Actual (Get-Key $uninstalled 'reuse')
Add-Result -Id 'R7-reports-missing-count' -Expected '1' -Actual (Get-Key $uninstalled 'spotmissing')

# R8 spotchecked must be a coverage figure, not a row count.
$expectedChecked = @($seedJson.tools | Where-Object { $_.available -eq $true -and $_.source -ne 'PowerShell built-in' }).Count
Add-Result -Id 'R8-spotchecked-is-coverage' -Expected ([string]$expectedChecked) -Actual (Get-Key $hit 'spotchecked')

# R9 a row written by an older format must degrade to rediscovery, not kill the run.
$p9 = New-Product -Name 'malformed-row' -SeedFrom $seed
Set-Content -LiteralPath (Join-Path $p9 'product-state\tooling\TOOL-INVENTORY.json') -Encoding utf8 -Value '{ "generated_at": "2026-08-11T00:00:00.0000000+08:00", "product_root": "x", "host_tool_index": null, "tools": [ { "tool_id": "legacy-row" } ] }'
$malformed = Invoke-Discover -Root $p9 -ExtraArgs (@('-ReuseInventory') + $narrowArgs)
Add-Result -Id 'R9-malformed-row-survives' -Expected 'full-discovery' -Actual (Get-Key $malformed 'reuse')
Add-Result -Id 'R9-no-crash' -Expected 'clean' -Actual $(if ($malformed.Crashed) { 'crashed' } else { 'clean' })

# R10 same for a null tools array.
$p10 = New-Product -Name 'null-tools' -SeedFrom $seed
Set-Content -LiteralPath (Join-Path $p10 'product-state\tooling\TOOL-INVENTORY.json') -Encoding utf8 -Value '{ "generated_at": "2026-08-11T00:00:00.0000000+08:00", "product_root": "x", "host_tool_index": null, "tools": null }'
$nullTools = Invoke-Discover -Root $p10 -ExtraArgs (@('-ReuseInventory') + $narrowArgs)
Add-Result -Id 'R10-null-tools-survives' -Expected 'full-discovery' -Actual (Get-Key $nullTools 'reuse')
Add-Result -Id 'R10-no-crash' -Expected 'clean' -Actual $(if ($nullTools.Crashed) { 'crashed' } else { 'clean' })

# R11 a torn/truncated JSON must be rejected rather than half-read.
$p11 = New-Product -Name 'truncated' -SeedFrom $seed
$truncPath = Join-Path $p11 'product-state\tooling\TOOL-INVENTORY.json'
$full = Get-Content -Raw -Encoding UTF8 -LiteralPath $truncPath
[System.IO.File]::WriteAllText($truncPath, $full.Substring(0, [int]($full.Length / 3)))
$truncated = Invoke-Discover -Root $p11 -ExtraArgs (@('-ReuseInventory') + $narrowArgs)
Add-Result -Id 'R11-truncated-rejected' -Expected 'full-discovery' -Actual (Get-Key $truncated 'reuse')

# R12 the inventory must never be observed as absent while it is being rewritten, and no temp
# file may survive the run.
$p12 = New-Product -Name 'atomic-write' -SeedFrom $seed
$toolingDir = Join-Path $p12 'product-state\tooling'
Get-Event | Remove-Event -ErrorAction SilentlyContinue
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $toolingDir
$watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName
Register-ObjectEvent -InputObject $watcher -EventName Deleted -SourceIdentifier 'invDeleted' | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier 'invRenamed' | Out-Null
$watcher.EnableRaisingEvents = $true
Start-Sleep -Milliseconds 300
$null = Invoke-Discover -Root $p12 -ExtraArgs @('-ReuseInventory')
Start-Sleep -Milliseconds 800
$watcher.EnableRaisingEvents = $false
$events = @(Get-Event | ForEach-Object { '{0}:{1}' -f $_.SourceEventArgs.ChangeType, $_.SourceEventArgs.Name })
Get-Event | Remove-Event -ErrorAction SilentlyContinue
Unregister-Event -SourceIdentifier 'invDeleted'
Unregister-Event -SourceIdentifier 'invRenamed'
$watcher.Dispose()
$destinationDeleted = @($events | Where-Object { $_ -match '^Deleted:TOOL-INVENTORY\.(md|json)$' }).Count
Add-Result -Id 'R12-destination-never-deleted' -Expected '0' -Actual ([string]$destinationDeleted)
"       R12 observed: $($events -join ' -> ')"
$leftovers = @(Get-ChildItem -LiteralPath $toolingDir -Force -File | Where-Object { $_.Name -like '.*tmp-*' -or $_.Name -like '.*bak-*' }).Count
Add-Result -Id 'R12-no-temp-leftovers' -Expected '0' -Actual ([string]$leftovers)

# R13 two consecutive reuse runs must not walk generated_at forward.
$p13 = New-Product -Name 'immortality' -SeedFrom $seed
$null = Invoke-Discover -Root $p13 -ExtraArgs @('-ReuseInventory')
$first = Get-Json -Root $p13
$null = Invoke-Discover -Root $p13 -ExtraArgs @('-ReuseInventory')
$second = Get-Json -Root $p13
$firstStamp = if ($first) { [string]$first.generated_at } else { 'a' }
$secondStamp = if ($second) { [string]$second.generated_at } else { 'b' }
Add-Result -Id 'R13-no-cache-immortality' -Expected 'stable' -Actual $(if ($firstStamp -eq $secondStamp) { 'stable' } else { 'restamped' })

# R14 the durable version of R5: a location written into the product's own extra-roots file must be
# searched on every later run, and editing that file must invalidate an otherwise valid snapshot.
# -AdditionalSearchRoot only helps the person who remembers to pass it; this is the mechanism that
# survives the next session, the next agent and the next skill update.
$p14 = New-Product -Name 'extra-root-file' -SeedFrom $seed
$extraRootDir = Join-Path $FixtureRoot 'extra-root-tools'
New-Item -ItemType Directory -Force -Path $extraRootDir | Out-Null
Set-Content -LiteralPath (Join-Path $extraRootDir 'frida.exe') -Value 'fixture placeholder, never executed' -Encoding ascii
$extraRootList = Join-Path $p14 'product-state\tooling\EXTRA-TOOL-ROOTS.txt'
Set-Content -LiteralPath $extraRootList -Value @('# 用户自己的工具目录，一行一个', $extraRootDir) -Encoding utf8
$withFile = Invoke-Discover -Root $p14 -ExtraArgs @('-ReuseInventory')
Add-Result -Id 'R14-extra-root-file-invalidates' -Expected 'full-discovery' -Actual (Get-Key $withFile 'reuse')
$p14json = Get-Json -Root $p14
$instrumentation = if ($p14json) { @($p14json.tools | Where-Object { $_.tool_id -eq 'runtime-instrumentation' })[0] } else { $null }
$instrumentationFound = 'still-missing'
if ($instrumentation -and $instrumentation.available) { $instrumentationFound = 'found' }
Add-Result -Id 'R14-extra-root-file-searched' -Expected 'found' -Actual $instrumentationFound
Add-Result -Id 'R14-extra-root-file-counted' -Expected '1' -Actual (Get-Key $withFile 'extrarootfiles')
$reuseAfter = Invoke-Discover -Root $p14 -ExtraArgs @('-ReuseInventory')
Add-Result -Id 'R14-stable-file-reuses' -Expected 'applied' -Actual (Get-Key $reuseAfter 'reuse')

# R15 every fixed drive is in scope. Hard-coding C: made a machine that keeps its toolchain on
# another drive report tools it actually has as not installed. Assert on the drives discovery
# probed, not on the drives that survived into the search roots: a drive that holds none of the
# conventional tool folder names contributes no root, and that is correct behaviour rather than a
# skipped drive. Asserting on the survivors made this red on any machine with an empty second
# drive -- a property of that machine's disks, not of the code under test.
$driveCount = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }).Count
Add-Result -Id 'R15-all-fixed-drives-probed' -Expected ([string]$driveCount) -Actual (Get-Key $cold 'probeddrives')
$reportedDrives = @((Get-Key $cold 'searchdrives') -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
$withinFixed = if ($reportedDrives -ge 1 -and $reportedDrives -le $driveCount) { 'yes' } else { 'no' }
Add-Result -Id 'R15-searched-drives-within-fixed' -Expected 'yes' -Actual $withinFixed

# EV -- Everything (es.exe) integration. Opt-in and graceful: it must not crash whether or not es.exe is
# installed, and the run must report which path it took -- never silently 'off' when the flag was passed.
# Without the flag the feature is off; with it under -SearchRootsOnly it is skipped (scope-limited mode);
# with it in a full sweep it is either 'used' (es.exe available) or 'unavailable' (not installed).
$evProduct = New-Product -Name 'ev'
$evOff = Invoke-Discover -Root $evProduct -ExtraArgs @('-SearchRootsOnly', '-AdditionalSearchRoot', $narrowRoot)
Add-Result -Id 'EV1-off-without-flag' -Expected 'off' -Actual (Get-Key $evOff 'everything')
$evScoped = Invoke-Discover -Root $evProduct -ExtraArgs @('-UseEverything', '-SearchRootsOnly', '-AdditionalSearchRoot', $narrowRoot)
Add-Result -Id 'EV2-skipped-under-searchrootsonly' -Expected 'skipped-searchrootsonly' -Actual (Get-Key $evScoped 'everything')
Add-Result -Id 'EV2-no-crash' -Expected 'no' -Actual $(if ($evScoped.Crashed) { 'yes' } else { 'no' })
$evFull = Invoke-Discover -Root $evProduct -ExtraArgs @('-UseEverything')
Add-Result -Id 'EV3-full-uses-or-unavailable' -Expected 'yes' -Actual $(if ((Get-Key $evFull 'everything') -in @('used', 'unavailable')) { 'yes' } else { 'no' })
Add-Result -Id 'EV3-no-crash' -Expected 'no' -Actual $(if ($evFull.Crashed) { 'yes' } else { 'no' })

# R16 the learned tool layer, end to end. The catalog is data now: catalog/tools.builtin.json merged with
# knowledge/tools/tools.learned.json. Everything about "this machine can learn a tool" rests on one link --
# an appended name must change catalog_fingerprint, because that is what invalidates the cached snapshot
# and forces the rediscovery that finds the new tool. If the fingerprint were computed over the builtin
# table alone the append would still succeed, the file would still change, the log would still be clean,
# and the tool would simply never be found again -- so this asserts the whole chain, not just the write.
#
# Run against a COPY of the skill: writing a learned file into the real one would leave state behind, and
# on a developer machine that file is the accumulated local memory this feature exists to protect.
# -SearchRootsOnly keeps all three runs to one named directory, so the chain is exercised in seconds.
$skillSource = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$skillCopy = Join-Path $FixtureRoot 'skill-copy'
New-Item -ItemType Directory -Force -Path $skillCopy | Out-Null
foreach ($part in @('scripts', 'catalog', 'knowledge')) {
    Copy-Item -LiteralPath (Join-Path $skillSource $part) -Destination (Join-Path $skillCopy $part) -Recurse -Force
}
$copiedScript = Join-Path $skillCopy 'scripts\discover-tools.ps1'
$learnedPath = Join-Path $skillCopy 'knowledge\tools\tools.learned.json'

function Invoke-CopiedDiscover {
    param([string]$Root, [string[]]$ExtraArgs = @())
    $callArgs = @($script:CommonDiscoverArgs) + @($ExtraArgs)
    $raw = @(& $PowerShellHost -NoProfile -ExecutionPolicy Bypass -File $copiedScript -ProductRoot $Root @callArgs 2>&1)
    $map = @{}
    foreach ($line in @($raw | ForEach-Object { [string]$_ })) {
        if ($line -match '^\s*([a-z_]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
    }
    return [pscustomobject]@{ Keys = $map; Text = (@($raw | ForEach-Object { [string]$_ }) -join ' ; ') }
}

$p16 = New-Product -Name 'learned-layer'
$narrowOnly = @('-SearchRootsOnly', '-AdditionalSearchRoot', $narrowRoot)
$r16Cold = Invoke-CopiedDiscover -Root $p16 -ExtraArgs $narrowOnly
Add-Result -Id 'R16-copy-runs-from-data' -Expected '26' -Actual (Get-Key $r16Cold 'catalogroles')
Add-Result -Id 'R16-no-learned-layer-is-clean' -Expected 'ok' -Actual (Get-Key $r16Cold 'learnedlayer')
$r16Reuse = Invoke-CopiedDiscover -Root $p16 -ExtraArgs (@('-ReuseInventory') + $narrowOnly)
Add-Result -Id 'R16-reuses-before-learning' -Expected 'applied' -Actual (Get-Key $r16Reuse 'reuse')
$fingerprintBefore = ''
$json16 = Get-Json -Root $p16
if ($json16) { $fingerprintBefore = [string]$json16.discovery_inputs.catalog_fingerprint }

# Written directly rather than through learn-tool.ps1: this case is about discover-tools honouring the
# learned layer, and routing it through the writer would let a broken reader hide behind a broken writer.
$learnedDocument = '{"schema_version":1,"layer":"learned","roles":[{"id":"package-inspect","names":["r16-learned-probe.exe"],"learned":{"added_at":"2026-08-13T00:00:00Z","found_via":"web","source_url":"https://example.invalid/r16","install_route":"manual"}}]}'
[IO.File]::WriteAllText($learnedPath, $learnedDocument, (New-Object Text.UTF8Encoding($false)))

$r16After = Invoke-CopiedDiscover -Root $p16 -ExtraArgs (@('-ReuseInventory') + $narrowOnly)
Add-Result -Id 'R16-learned-append-invalidates-cache' -Expected 'full-discovery' -Actual (Get-Key $r16After 'reuse')
Add-Result -Id 'R16-rejected-for-changed-inputs' -Expected 'discovery inputs changed since the previous inventory' -Actual (Get-Key $r16After 'reuserejected')
$fingerprintAfter = ''
$json16After = Get-Json -Root $p16
if ($json16After) { $fingerprintAfter = [string]$json16After.discovery_inputs.catalog_fingerprint }
$fingerprintMoved = if ($fingerprintBefore -ne '' -and $fingerprintAfter -ne '' -and $fingerprintBefore -ne $fingerprintAfter) { 'changed' } else { 'unchanged' }
Add-Result -Id 'R16-learned-append-changes-fingerprint' -Expected 'changed' -Actual $fingerprintMoved
Add-Result -Id 'R16-role-count-unchanged-by-name-append' -Expected '26' -Actual (Get-Key $r16After 'catalogroles')

# A learned layer that cannot be parsed must be reported, not skipped: skipping it silently returns the
# fingerprint to its builtin value and every learned tool becomes invisible again with nothing said.
[IO.File]::WriteAllText($learnedPath, '{ not json at all', (New-Object Text.UTF8Encoding($false)))
$r16Corrupt = Invoke-CopiedDiscover -Root $p16 -ExtraArgs $narrowOnly
Add-Result -Id 'R16-corrupt-learned-layer-warns' -Expected 'warn:1' -Actual (Get-Key $r16Corrupt 'learnedlayer')
Add-Result -Id 'R16-corrupt-learned-still-discovers' -Expected '26' -Actual (Get-Key $r16Corrupt 'catalogroles')

''
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
"RESULT: $(@($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count) passed, $($failed.Count) failed"
foreach ($item in $failed) { "FAILED: $($item.Id) expected[$($item.Expected)] actual[$($item.Actual)]" }

if (-not $KeepFixture) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($failed.Count -gt 0) { exit 1 }
