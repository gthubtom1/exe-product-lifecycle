#requires -Version 5

# rebuild-capability-index -- regenerate capabilities/INDEX.json from the recipes on disk.
#
# Deterministic: same recipes in, byte-identical index out. CI runs this and then fails if git is dirty,
# which is what stops a hand-edited INDEX.json from surviving review.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File rebuild-capability-index.ps1 [-SkillRoot <root>]

[CmdletBinding()]
param([string]$SkillRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
. (Join-Path $PSScriptRoot 'lib\capability-common.ps1')

$indexPath = Update-CapabilityIndex -SkillRoot $SkillRoot
$count = @(Get-CapabilityRecipeFile -SkillRoot $SkillRoot).Count
Write-Output ("RESULT: rebuilt ({0} recipe(s)) -> {1}" -f $count, $indexPath)
exit 0
