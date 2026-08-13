#requires -Version 5

# validate-capabilities -- default-deny validator for the independent capabilities/ library (stage B).
#
# Validates every capabilities/recipes/*.json against Test-CapabilityRecord (fields, status/strength enums,
# integrity/payload hash, unsigned-ack logic, verified-requires-selftest, privacy) and checks that
# capabilities/INDEX.json matches the recipes on disk (path + sha256 + status). A crash is turned into a
# clean RESULT: capabilities_invalid line -- a crash is not a verdict (mirrors validate-knowledge).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File validate-capabilities.ps1 [-SkillRoot <root>]

[CmdletBinding()]
param([string]$SkillRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
. (Join-Path $PSScriptRoot 'lib\capability-common.ps1')

trap {
    Write-Output 'RESULT: capabilities_invalid'
    Write-Output ("detail=" + $_.Exception.Message)
    exit 1
}

$errors = New-Object System.Collections.Generic.List[string]
$files = @(Get-CapabilityRecipeFile -SkillRoot $SkillRoot)
$seen = @{}
$actual = @{}
foreach ($file in $files) {
    $record = $null
    try { $record = Read-JsonFile -Path $file.FullName } catch { [void]$errors.Add("$($file.Name): invalid JSON"); continue }
    # Contain the blast radius per record: one structurally broken recipe must yield its own ERROR line,
    # not trip the outer trap and take every other record's findings down with it.
    try { foreach ($e in @(Test-CapabilityRecord -Record $record -SkillRoot $SkillRoot)) { [void]$errors.Add("$($file.Name): $e") } }
    catch { [void]$errors.Add("$($file.Name): validation could not complete on this record: $($_.Exception.Message)") }
    $id = [string](Get-PropertyValue $record 'tool_capability_id' '')
    if (-not [string]::IsNullOrWhiteSpace($id)) {
        if ($seen.ContainsKey($id)) { [void]$errors.Add("duplicate tool_capability_id: $id ($($seen[$id]) and $($file.Name))") }
        else { $seen[$id] = $file.Name }
    }
    $actual['capabilities/recipes/' + $file.Name] = [pscustomobject]@{ status = [string](Get-PropertyValue $record 'status' ''); sha256 = (Get-Sha256 -Path $file.FullName) }
}

$indexPath = Join-Path (Get-CapabilityRoot -SkillRoot $SkillRoot) 'INDEX.json'
$indexExists = Test-Path -LiteralPath $indexPath -PathType Leaf
if ($files.Count -gt 0 -and -not $indexExists) {
    [void]$errors.Add('capabilities/INDEX.json is missing but recipes exist (run Update-CapabilityIndex)')
}
elseif ($indexExists) {
    $index = $null
    try { $index = Read-JsonFile -Path $indexPath } catch { [void]$errors.Add('capabilities/INDEX.json: invalid JSON') }
    if ($null -ne $index) {
        $indexPaths = @{}
        foreach ($entry in @($index.entries)) {
            $p = [string](Get-PropertyValue $entry 'path' '')
            $indexPaths[$p] = $true
            if (-not $actual.ContainsKey($p)) { [void]$errors.Add("INDEX.json has a stale entry with no recipe file: $p") }
            else {
                if (([string](Get-PropertyValue $entry 'sha256' '')).ToUpperInvariant() -ne $actual[$p].sha256.ToUpperInvariant()) { [void]$errors.Add("INDEX.json sha256 drift for $p") }
                if ([string](Get-PropertyValue $entry 'status' '') -ne $actual[$p].status) { [void]$errors.Add("INDEX.json status drift for $p") }
            }
        }
        foreach ($p in $actual.Keys) { if (-not $indexPaths.ContainsKey($p)) { [void]$errors.Add("recipe not listed in INDEX.json: $p") } }
    }
}

if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Output "ERROR: $e" }
    Write-Output ("RESULT: failed ({0} error(s), {1} recipe(s))" -f $errors.Count, $files.Count)
    exit 1
}
Write-Output ("RESULT: passed ({0} recipe(s), default-deny + integrity + index consistency)" -f $files.Count)
exit 0
