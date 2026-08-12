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
        return
    }
    $installed = (Resolve-Path -LiteralPath $InstalledRoot).Path.TrimEnd('\')
    $drift = New-Object System.Collections.Generic.List[string]
    foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($source.Length + 1)
        $target = Join-Path $installed $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { [void]$drift.Add("missing:$relative"); continue }
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) { [void]$drift.Add("stale:$relative") }
    }
    foreach ($targetFile in @(Get-ChildItem -LiteralPath $installed -Recurse -File)) {
        $relative = $targetFile.FullName.Substring($installed.Length + 1)
        if ($relative -notin @($sourceFiles | ForEach-Object { $_.FullName.Substring($source.Length + 1) })) { [void]$drift.Add("extra:$relative") }
    }
    if ($drift.Count -gt 0) {
        foreach ($item in $drift) { Write-Output "DRIFT: $item" }
        Write-Output "ERROR: 已安装副本和源目录不一致，Agent 实际加载的是旧版本。运行 scripts/sync-local-skill.ps1 同步后重试。"
        Write-Output "RESULT: failed ($($drift.Count) drifted file(s) at $installed)"
        exit 1
    }
    Write-Output "DRIFT: none ($installed matches source)"
}
finally {
    if ((Test-Path -LiteralPath $temp -PathType Container) -and $temp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
