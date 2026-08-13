#requires -Version 5

<#
CI dual-host suite-parity guard.

validate-skill.yml runs its regressions twice on purpose: once under Windows
PowerShell 5.1 (job windows-powershell-51) and once under PowerShell 7 (job
windows-powershell-7). The entire value of paying for two jobs is that a
behaviour which only breaks on one host is caught -- but that only holds while
BOTH jobs actually run the SAME set of test-*.ps1 suites. The pwsh7 job has
silently fallen behind the 5.1 job before (it was missing test-detect-protections.ps1
and test-tool-inventory-reuse.ps1: green on the dashboard, but that green only
meant "green on 5.1", and 26 freshly added detect-protections cases never ran on 7).

This guard turns that silent gap into a red step. Two assertions, and the second
is the one that matters:

  1. the two jobs run the identical set of test-*.ps1 suites; and
  2. that set equals every test-*.ps1 that actually exists in scripts/.

Assertion (2) closes the obvious loophole in (1): a divergence could be "fixed"
by DELETING the extra suite from the longer job -- the two lists would then match,
(1) would pass, and coverage would have quietly dropped. Aligning by deletion
fails (2), because the suite still exists on disk and is now run on neither host.
The only way to satisfy this guard is to run every suite on both hosts. This is
the same anti-pattern test-install-parity.ps1 already refuses ("counting it as
drift would push a maintainer to fix it by deleting it").

The guard is itself a test-*.ps1 in scripts/ and is wired into both jobs, so it
is subject to the very rule it enforces: it cannot be dropped from one host
without failing its own coverage check.

Deliberately a line scanner rather than a YAML parser: neither Windows PowerShell
5.1 nor PowerShell 7 ships ConvertFrom-Yaml, and a guard for the dual-host jobs
must run on the very hosts it protects.
#>

[CmdletBinding()]
param([string]$WorkflowPath, [string]$ScriptsDir)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptsDir)) { $ScriptsDir = $PSScriptRoot }
$ScriptsDir = (Resolve-Path -LiteralPath $ScriptsDir).Path
if ([string]::IsNullOrWhiteSpace($WorkflowPath)) {
    $WorkflowPath = Join-Path $ScriptsDir '..\.github\workflows\validate-skill.yml'
}
$WorkflowPath = (Resolve-Path -LiteralPath $WorkflowPath).Path

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Expected, [string]$Actual)
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed })
    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Output ("{0}   {1,-38} expected[{2}] actual[{3}]" -f $status, $Name, $Expected, $Actual)
}

# Collect the test-*.ps1 suites invoked inside one job block. A job header sits at
# exactly two-space indent under `jobs:`; the block runs until the next two-space
# `key:` (the following job) or end of file. Comment lines are skipped so a test
# name mentioned in prose is never miscounted as an invocation.
function Get-JobTestSuites {
    param([string[]]$Lines, [string]$JobName)
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match ('^  ' + [regex]::Escape($JobName) + ':\s*$')) { $start = $i + 1; break }
    }
    if ($start -lt 0) { return $null }
    $suites = New-Object System.Collections.Generic.List[string]
    for ($i = $start; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^  [A-Za-z0-9_.-]+:\s*$') { break }
        if ($Lines[$i].TrimStart().StartsWith('#')) { continue }
        foreach ($m in [regex]::Matches($Lines[$i], '(test-[A-Za-z0-9._-]+\.ps1)')) {
            $name = $m.Groups[1].Value
            if (-not $suites.Contains($name)) { [void]$suites.Add($name) }
        }
    }
    return ,$suites.ToArray()
}

$lines = [IO.File]::ReadAllLines($WorkflowPath)
$job51 = Get-JobTestSuites -Lines $lines -JobName 'windows-powershell-51'
$job7  = Get-JobTestSuites -Lines $lines -JobName 'windows-powershell-7'

Add-Result -Name 'job-51-block-found' -Passed ($null -ne $job51) -Expected 'found' -Actual $(if ($null -ne $job51) { 'found' } else { 'missing' })
Add-Result -Name 'job-7-block-found'  -Passed ($null -ne $job7)  -Expected 'found' -Actual $(if ($null -ne $job7)  { 'found' } else { 'missing' })

if ($null -eq $job51 -or $null -eq $job7) {
    Write-Output ''
    Write-Output 'RESULT: 0 passed, 1 failed (could not locate both host jobs in the workflow)'
    exit 1
}

$cmp    = [System.StringComparer]::OrdinalIgnoreCase
$set51  = [System.Collections.Generic.HashSet[string]]::new([string[]]$job51, $cmp)
$set7   = [System.Collections.Generic.HashSet[string]]::new([string[]]$job7, $cmp)
$onDisk = @(Get-ChildItem -LiteralPath $ScriptsDir -Filter 'test-*.ps1' -File | ForEach-Object { $_.Name })
$setDisk = [System.Collections.Generic.HashSet[string]]::new([string[]]$onDisk, $cmp)

# 1. the two jobs must run the identical set of suites
$only51 = @($set51 | Where-Object { -not $set7.Contains($_) } | Sort-Object)
$only7  = @($set7  | Where-Object { -not $set51.Contains($_) } | Sort-Object)
$parity = ($only51.Count -eq 0 -and $only7.Count -eq 0)
Add-Result -Name 'both-hosts-run-identical-set' -Passed $parity -Expected 'identical' -Actual $(if ($parity) { 'identical' } else { "only51[$($only51 -join ',')] only7[$($only7 -join ',')]" })

# 2. neither job may drop a suite that exists on disk -- aligning by deletion fails here
$missing51 = @($setDisk | Where-Object { -not $set51.Contains($_) } | Sort-Object)
$missing7  = @($setDisk | Where-Object { -not $set7.Contains($_) } | Sort-Object)
Add-Result -Name '51-covers-every-disk-suite' -Passed ($missing51.Count -eq 0) -Expected 'all-covered' -Actual $(if ($missing51.Count -eq 0) { 'all-covered' } else { "missing[$($missing51 -join ',')]" })
Add-Result -Name '7-covers-every-disk-suite'  -Passed ($missing7.Count -eq 0)  -Expected 'all-covered' -Actual $(if ($missing7.Count -eq 0)  { 'all-covered' } else { "missing[$($missing7 -join ',')]" })

# a suite wired into CI that no longer exists on disk is a dangling step
$extra51 = @($set51 | Where-Object { -not $setDisk.Contains($_) } | Sort-Object)
$extra7  = @($set7  | Where-Object { -not $setDisk.Contains($_) } | Sort-Object)
$noDangling = ($extra51.Count -eq 0 -and $extra7.Count -eq 0)
Add-Result -Name 'no-suite-wired-that-is-missing-on-disk' -Passed $noDangling -Expected 'none' -Actual $(if ($noDangling) { 'none' } else { "51[$($extra51 -join ',')] 7[$($extra7 -join ',')]" })

$failed = @($script:Results | Where-Object { -not $_.Passed })
Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed (disk={2}, 51={3}, 7={4})" -f @($script:Results | Where-Object { $_.Passed }).Count, $failed.Count, $setDisk.Count, $set51.Count, $set7.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
