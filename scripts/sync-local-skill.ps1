#requires -Version 5

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourceRoot,
    [string]$DestinationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $DestinationRoot = Join-Path $codexHome 'skills\exe-product-lifecycle'
}
$source = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
$destinationParent = Split-Path -Parent $DestinationRoot
if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) { New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null }
if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) { New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null }
$destination = (Resolve-Path -LiteralPath $DestinationRoot).Path.TrimEnd('\')
if ($destination -eq $source -or $destination.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'DestinationRoot must be outside SourceRoot' }

$excludedTop = @('.git')
$sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    ($relative.Split('\')[0] -notin $excludedTop) -and $_.Name -ne '.knowledge-write.lock'
})
$sourceRelative = @($sourceFiles | ForEach-Object { $_.FullName.Substring($source.Length + 1) })

# This script overwrites the copy the Agent actually loads. Publishing a source
# tree that cannot pass its own gate is how a half-written script becomes the
# live version while sync still reports success, so the gate runs first and a
# failure refuses the copy outright rather than warning about it.
$layoutGate = Join-Path $source 'scripts\validate-skill-layout.ps1'
if (-not (Test-Path -LiteralPath $layoutGate -PathType Leaf)) {
    Write-Output "错误: 找不到技能自检脚本，已拒绝同步: $layoutGate"
    exit 1
}
$gateHost = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
$gateOutput = & $gateHost -NoProfile -ExecutionPolicy Bypass -File $layoutGate -SkillRoot $source 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Output '错误: 源目录没有通过技能自检，已拒绝同步（一个文件都没有覆盖）。'
    Write-Output '原因: 同步会覆盖 Agent 实际加载的那份副本。带语法错误或缺文件的版本一旦装进去，之后每一次加载都会失败。'
    foreach ($line in @($gateOutput)) { Write-Output "  $line" }
    Write-Output '怎么办: 先修好上面列出的问题，再重新运行本脚本。'
    exit 1
}

if ($PSCmdlet.ShouldProcess($destination, 'Synchronize EXE lifecycle skill files')) {
    foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($source.Length + 1)
        $target = Join-Path $destination $relative
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    foreach ($targetFile in @(Get-ChildItem -LiteralPath $destination -Recurse -File)) {
        $relative = $targetFile.FullName.Substring($destination.Length + 1)
        if ($relative -notin $sourceRelative) { Remove-Item -LiteralPath $targetFile.FullName -Force }
    }
}

$mismatches = New-Object System.Collections.Generic.List[string]
foreach ($file in $sourceFiles) {
    $relative = $file.FullName.Substring($source.Length + 1)
    $target = Join-Path $destination $relative
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { [void]$mismatches.Add("missing:$relative"); continue }
    if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) { [void]$mismatches.Add("hash:$relative") }
}
if ($mismatches.Count -gt 0) { $mismatches | ForEach-Object { Write-Output "ERROR: $_" }; exit 1 }
Write-Output 'RESULT: local_skill_synchronized'
Write-Output "source=$source"
Write-Output "destination=$destination"
Write-Output "file_count=$($sourceFiles.Count)"
