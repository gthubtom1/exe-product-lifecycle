#requires -Version 5

<#
Two different questions, deliberately kept apart:

  1. does sync-local-skill.ps1 reproduce the source tree faithfully  (self-contained, always run)
  2. is the copy the agent actually loads still current            (host-dependent, run when present)

Only the first one existed, and because it syncs into a fresh temp directory and then compares
against it, it is tautological -- it reported "73 installed file(s) match" for four consecutive
rounds during which thirteen files in the real install root were stale, including every script
that had just been fixed. A green regression proving nothing is worse than no regression.
#>

[CmdletBinding()]
param([string]$SkillRoot, [string]$InstalledRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$source = (Resolve-Path -LiteralPath $SkillRoot).Path.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($InstalledRoot)) {
    $codexHome = $env:CODEX_HOME
    if ([string]::IsNullOrWhiteSpace($codexHome)) { $codexHome = Join-Path $HOME '.codex' }
    $InstalledRoot = Join-Path $codexHome 'skills\exe-product-lifecycle'
}
# Listed the other way round on purpose: this repository is text apart from a handful of binaries,
# and an allow-list of text extensions silently mis-compares whatever nobody remembered to add --
# CODEOWNERS and .gitkeep both slipped through one.
$binaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.zip', '.exe', '.dll', '.bin')

function Get-ComparableHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    # An installed copy that is a clone gets its line endings from checkout, and the source tree
    # does not have to agree. Comparing raw bytes would then report every text file as drifted
    # forever, and the remedy it prints -- run the sync script -- is a command a clone refuses.
    # Compare what the file says, not how the checkout spelled its newlines.
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -in $binaryExtensions) {
        return [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
    }
    $text = [Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n"
    return [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '')
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('exe-lifecycle-install-' + [Guid]::NewGuid().ToString('N'))
$destination = Join-Path $temp 'exe-product-lifecycle'
try {
    & (Join-Path $source 'scripts\sync-local-skill.ps1') -SourceRoot $source -DestinationRoot $destination | Out-Null
    if (-not $?) { throw 'sync-local-skill.ps1 failed' }
    $sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Name -ne '.knowledge-write.lock'
    })
    $destinationFiles = @(Get-ChildItem -LiteralPath $destination -Recurse -File)
    if ($sourceFiles.Count -ne $destinationFiles.Count) { throw "file count mismatch: source=$($sourceFiles.Count), destination=$($destinationFiles.Count)" }
    foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($source.Length + 1)
        $target = Join-Path $destination $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "missing installed file: $relative" }
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) { throw "installed hash mismatch: $relative" }
    }
    Write-Output "RESULT: passed ($($sourceFiles.Count) installed file(s) match)"

    # Drift check against the copy the agent really loads. Absent on CI, which is why it reports
    # skipped rather than failing there; present on a maintainer's machine, which is exactly where
    # "I fixed it but never synced it" happens.
    if (-not (Test-Path -LiteralPath $InstalledRoot -PathType Container)) {
        Write-Output "DRIFT: skipped (no installed copy at $InstalledRoot)"
    }
    else {
        $installed = (Resolve-Path -LiteralPath $InstalledRoot).Path.TrimEnd('\')
        $installedIsClone = Test-Path -LiteralPath (Join-Path $installed '.git') -PathType Container
        $drift = New-Object System.Collections.Generic.List[string]
        foreach ($file in $sourceFiles) {
            $relative = $file.FullName.Substring($source.Length + 1)
            $target = Join-Path $installed $relative
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { [void]$drift.Add("missing:$relative"); continue }
            if ((Get-ComparableHash -Path $file.FullName) -ne (Get-ComparableHash -Path $target)) { [void]$drift.Add("stale:$relative") }
        }
        # Experience learned on this machine is expected to be here and not in the source, so it is
        # not drift. Counting it as drift would push a maintainer to "fix" it by deleting it.
        foreach ($targetFile in @(Get-ChildItem -LiteralPath $installed -Recurse -File)) {
            $relative = $targetFile.FullName.Substring($installed.Length + 1)
            if ($relative -match '^knowledge\\(candidates|verified|deprecated)\\[^\\]+\.json$') { continue }
            if ($targetFile.Name -eq '.knowledge-write.lock') { continue }
            if ($relative -notin @($sourceFiles | ForEach-Object { $_.FullName.Substring($source.Length + 1) })) { [void]$drift.Add("extra:$relative") }
        }
        if ($drift.Count -gt 0) {
            foreach ($item in $drift) { Write-Output "DRIFT: $item" }
            if ($installedIsClone) {
                Write-Output 'ERROR: 已安装副本和源目录不一致。装的那份是 clone，用 git pull 更新它（不要用同步脚本，它会拒绝）。'
            }
            else {
                Write-Output 'ERROR: 已安装副本和源目录不一致，Agent 实际加载的是旧版本。运行 scripts/sync-local-skill.ps1 同步后重试。'
            }
            Write-Output "RESULT: failed ($($drift.Count) drifted file(s) at $installed)"
            exit 1
        }
        Write-Output "DRIFT: none ($installed matches source)"
    }
}
finally {
    if ((Test-Path -LiteralPath $temp -PathType Container) -and $temp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

# What sync must NOT delete. The installed copy is where the agent works, so it is where new
# experience lands first; before it is published, that file exists nowhere else. Mirroring the
# source's absence onto it is silent, unrecoverable data loss, and it is invisible to the parity
# check above because that one only ever compares files the source already has.
$preserveTemp = Join-Path ([IO.Path]::GetTempPath()) ('exe-lifecycle-preserve-' + [Guid]::NewGuid().ToString('N'))
try {
    $learned = Join-Path $preserveTemp 'knowledge\verified\learned-here.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $learned) | Out-Null
    [IO.File]::WriteAllText($learned, '{"experience_id":"exp-learned-here"}')
    $stale = Join-Path $preserveTemp 'scripts\removed-upstream.ps1'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stale) | Out-Null
    [IO.File]::WriteAllText($stale, '# a script the source no longer has')

    & (Join-Path $source 'scripts\sync-local-skill.ps1') -SourceRoot $source -DestinationRoot $preserveTemp | Out-Null

    $failures = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $learned -PathType Leaf)) { [void]$failures.Add('sync deleted an experience that only the installed copy had') }
    # The other half of the contract: preserving must not turn into keeping everything, or the
    # drift protection that made this script exist is gone.
    if (Test-Path -LiteralPath $stale -PathType Leaf) { [void]$failures.Add('sync kept a stale script the source no longer has') }

    # A cloned destination updates itself with git pull. Copying over it would leave it dirty
    # forever, so sync must decline rather than half-work.
    $cloneDest = Join-Path $preserveTemp 'clone-destination'
    New-Item -ItemType Directory -Force -Path (Join-Path $cloneDest '.git') | Out-Null
    [IO.File]::WriteAllText((Join-Path $cloneDest '.git\config'), '[core]')
    $marker = Join-Path $cloneDest 'SKILL.md'
    [IO.File]::WriteAllText($marker, 'untouched')
    $refusal = & (Join-Path $source 'scripts\sync-local-skill.ps1') -SourceRoot $source -DestinationRoot $cloneDest 2>&1
    $refusalText = (@($refusal | ForEach-Object { [string]$_ }) -join "`n")
    if ($refusalText -notmatch 'git pull') { [void]$failures.Add('sync did not refuse a cloned destination, or did not say to use git pull') }
    if ((Get-Content -Raw -Encoding UTF8 -LiteralPath $marker) -ne 'untouched') { [void]$failures.Add('sync overwrote a cloned destination after refusing') }
    if ($failures.Count -gt 0) {
        foreach ($item in $failures) { Write-Output "PRESERVE: $item" }
        Write-Output "RESULT: failed ($($failures.Count) sync preservation failure(s))"
        exit 1
    }
    Write-Output 'PRESERVE: ok (learned experience survives sync, stale files still removed, cloned destination refused)'
}
finally {
    if ((Test-Path -LiteralPath $preserveTemp -PathType Container) -and $preserveTemp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $preserveTemp -Recurse -Force }
}

# Explicit, because the refusal scenario above deliberately runs a script that exits non-zero and
# leaves $LASTEXITCODE set. Launched with -File that is harmless; CI runs this as
# `pwsh -command ". 'file'"`, where the leftover code becomes the step's result.
exit 0
