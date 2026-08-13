#requires -Version 5

<#
Mutation tests for the reachability gate in validate-skill-layout.ps1.

Why these and not "run it and see green": the gate exists because a whole subsystem shipped
unreachable while its own tests were green. A test that only asserts the current tree passes would
have been green on the day the hole opened. So each case breaks the gate in a specific way and
asserts it goes red -- plus one case that asserts it does NOT go red, because a gate that reds on
everything gets switched off.

The fixture is a temp copy of the real skill root; the real tree is never modified.
#>

[CmdletBinding()]
param([string]$SkillRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$source = (Resolve-Path -LiteralPath $SkillRoot).Path.TrimEnd('\')

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Expected, [string]$Actual)
    [void]$results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Expected = $Expected; Actual = $Actual })
    $tag = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Output ("{0}   {1,-46} expected[{2}] actual[{3}]" -f $tag, $Name, $Expected, $Actual)
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("skill-reach-" + [Guid]::NewGuid().ToString('N'))
$orphanName = 'zz-reachability-fixture.ps1'

try {
    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
    # robocopy rather than Copy-Item: another agent may hold a handle on a file in the tree, and
    # Copy-Item aborts the whole copy on the first locked file.
    $null = robocopy $source $fixtureRoot /E /NFL /NDL /NJH /NJS /NP /XD '.git' 2>&1
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with code $LASTEXITCODE" }
    $global:LASTEXITCODE = 0

    $validator = Join-Path $fixtureRoot 'scripts\validate-skill-layout.ps1'
    $orphanPath = Join-Path $fixtureRoot ('scripts\' + $orphanName)

    function Invoke-Layout {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $validator -SkillRoot $fixtureRoot 2>&1
        $global:LASTEXITCODE = 0
        return ($out | Out-String)
    }

    # RG1 -- a new script nobody can reach and that declares nothing must go red. This is the shape
    # that shipped unnoticed; if this case ever passes silently the gate is decorative.
    Set-Content -LiteralPath $orphanPath -Encoding ASCII -Value @(
        '# fixture: deliberately unreachable, deliberately undeclared',
        'Write-Output "fixture"'
    )
    $text = Invoke-Layout
    $hit = ($text -match [regex]::Escape($orphanName)) -and ($text -match 'unreachable')
    Add-Result -Name 'RG1-undeclared-orphan-is-red' -Passed $hit -Expected 'red' -Actual $(if ($hit) { 'red' } else { 'not-reported' })

    # RG2 -- the escape hatch must actually work. A gate with no legitimate way out teaches people to
    # fabricate a reference instead, and a fabricated reference is invisible.
    Set-Content -LiteralPath $orphanPath -Encoding ASCII -Value @(
        '# SKILL-ENTRYPOINT: invoked directly by the operator when reseeding a product folder',
        'Write-Output "fixture"'
    )
    $text = Invoke-Layout
    $clean = -not ($text -match [regex]::Escape($orphanName))
    Add-Result -Name 'RG2-declared-entrypoint-is-not-red' -Passed $clean -Expected 'not-reported' -Actual $(if ($clean) { 'not-reported' } else { 'red' })

    # RG3 -- a declaration with no real reason is a silencer, not a declaration. Without this the
    # hatch is strictly cheaper than fixing anything and everyone takes it.
    Set-Content -LiteralPath $orphanPath -Encoding ASCII -Value @(
        '# SKILL-ENTRYPOINT: TODO',
        'Write-Output "fixture"'
    )
    $text = Invoke-Layout
    $hit = ($text -match [regex]::Escape($orphanName)) -and ($text -match 'no real reason')
    Add-Result -Name 'RG3-placeholder-reason-is-red' -Passed $hit -Expected 'red' -Actual $(if ($hit) { 'red' } else { 'not-reported' })

    # RG4-RG6 cover the build-time-gate class: a validator whose only caller is a CI step. The class
    # exists so that maintainer-side gates do not have to buy their way past this check with a doc
    # sentence or a declaration, both of which keep reading true after the CI step is deleted.
    $workflow = Join-Path $fixtureRoot '.github\workflows\validate-skill.yml'
    $workflowBackup = Get-Content -Raw -LiteralPath $workflow
    $ciStep = @(
        '      - name: Fixture build-time gate',
        '        shell: pwsh',
        ('        run: ./scripts/' + $orphanName)
    ) -join "`n"

    # RG4 -- CI invocation is a legitimate proof on its own. Without this the maintainer-side gates
    # are pushed onto the escape hatch, and a hatch taken by a whole category stops being a signal.
    Set-Content -LiteralPath $orphanPath -Encoding ASCII -Value @(
        '# fixture: a build-time gate, run by CI and by nothing else',
        'Write-Output "fixture"'
    )
    Set-Content -LiteralPath $workflow -Encoding ASCII -Value ($workflowBackup.TrimEnd() + "`n" + $ciStep + "`n")
    $text = Invoke-Layout
    $clean = -not ($text -match [regex]::Escape($orphanName))
    Add-Result -Name 'RG4-ci-invoked-gate-is-not-red' -Passed $clean -Expected 'not-reported' -Actual $(if ($clean) { 'not-reported' } else { 'red' })

    # RG5 -- and that proof has to expire with the thing it proves. Delete the step and the script is
    # dead weight again the same day; this is the property a declaration cannot have.
    Set-Content -LiteralPath $workflow -Encoding ASCII -Value $workflowBackup
    $text = Invoke-Layout
    $hit = ($text -match [regex]::Escape($orphanName)) -and ($text -match 'unreachable')
    Add-Result -Name 'RG5-ci-step-removed-goes-red-again' -Passed $hit -Expected 'red' -Actual $(if ($hit) { 'red' } else { 'not-reported' })

    # RG6 -- the hole this whole gate was built for. A production script named only inside a test
    # that CI runs must still be red: the test proves the code can run, not that anything uses it.
    # That is the criterion which scored 0 of 40, so it is the one case worth pinning hardest.
    $testName = 'test-zz-reachability-fixture.ps1'
    $testPath = Join-Path $fixtureRoot ('scripts\' + $testName)
    Set-Content -LiteralPath $orphanPath -Encoding ASCII -Value @(
        '# fixture: production script whose only mention is inside a CI-run test',
        'Write-Output "fixture"'
    )
    Set-Content -LiteralPath $testPath -Encoding ASCII -Value @(
        ('# fixture test that exercises ' + $orphanName),
        ('& (Join-Path $PSScriptRoot ''' + $orphanName + ''')')
    )
    Set-Content -LiteralPath $workflow -Encoding ASCII -Value ($workflowBackup.TrimEnd() + "`n" + (@(
        '      - name: Fixture test',
        '        shell: pwsh',
        ('        run: ./scripts/' + $testName)
    ) -join "`n") + "`n")
    $text = Invoke-Layout
    $hit = ($text -match [regex]::Escape($orphanName)) -and ($text -match 'unreachable')
    Add-Result -Name 'RG6-test-does-not-confer-reachability' -Passed $hit -Expected 'red' -Actual $(if ($hit) { 'red' } else { 'not-reported' })

    # RG7 -- a build-time gate named ONLY in a decorative workflow `name:` label (its `run:` executes
    # echo, not the script) must still be red. CI reachability is seeded from `run:` invocations, not
    # from any workflow text, so a `name:` mention is documentation -- the CI-channel twin of RG6.
    Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $orphanPath -Encoding ASCII -Value @(
        '# fixture: a build-time gate mentioned only in a decorative name: label, never run',
        'Write-Output "fixture"'
    )
    $decorGateStep = @(
        ('      - name: Housekeeping note for scripts/' + $orphanName + ' (documentation only, never executed)'),
        '        shell: pwsh',
        '        run: echo "this step runs echo, it never invokes the script"'
    ) -join "`n"
    Set-Content -LiteralPath $workflow -Encoding ASCII -Value ($workflowBackup.TrimEnd() + "`n" + $decorGateStep + "`n")
    $text = Invoke-Layout
    $hit = ($text -match [regex]::Escape($orphanName)) -and ($text -match 'unreachable')
    Add-Result -Name 'RG7-decorative-ci-name-label-is-red' -Passed $hit -Expected 'red' -Actual $(if ($hit) { 'red' } else { 'not-reported' })

    # RG8 -- the same for a test: named only in a decorative `name:` label (never run) it must still
    # be 'not run by CI'. Otherwise a dead test buys a green by being mentioned, not executed.
    Remove-Item -LiteralPath $orphanPath -Force -ErrorAction SilentlyContinue
    $decorTestName = 'test-zz-decorative-fixture.ps1'
    $decorTestPath = Join-Path $fixtureRoot ('scripts\' + $decorTestName)
    Set-Content -LiteralPath $decorTestPath -Encoding ASCII -Value @(
        '# fixture: a test mentioned only in a decorative name: label, never run',
        'Write-Output "fixture"'
    )
    $decorTestStep = @(
        ('      - name: Note about scripts/' + $decorTestName + ' (documentation only, never executed)'),
        '        shell: pwsh',
        '        run: echo "this step runs echo, it never invokes the test"'
    ) -join "`n"
    Set-Content -LiteralPath $workflow -Encoding ASCII -Value ($workflowBackup.TrimEnd() + "`n" + $decorTestStep + "`n")
    $text = Invoke-Layout
    $hit = ($text -match [regex]::Escape($decorTestName)) -and ($text -match 'not run by CI')
    Add-Result -Name 'RG8-decorative-ci-test-label-is-red' -Passed $hit -Expected 'red' -Actual $(if ($hit) { 'red' } else { 'not-reported' })
    Remove-Item -LiteralPath $decorTestPath -Force -ErrorAction SilentlyContinue
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($results | Where-Object { -not $_.Passed })
Write-Output ("RESULT: {0} passed, {1} failed" -f @($results | Where-Object { $_.Passed }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
