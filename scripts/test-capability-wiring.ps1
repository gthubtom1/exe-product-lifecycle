#requires -Version 5

<#
Wiring regression for the capability library: does the ORCHESTRATOR actually reach gap-classify.ps1?

    powershell -NoProfile -ExecutionPolicy Bypass -File test-capability-wiring.ps1

Why this suite exists, and why it asserts what it asserts.

The capability library shipped with 72 green tests of its own while nothing in the workflow ever
called it -- the installed copy of the skill simply lacked those files and nothing broke. Green
tests of a subsystem prove the subsystem works, not that anyone gets to it.

validate-skill-layout.ps1 already reds on an unreachable script, but its reachability roots are
TEXT MENTIONS in SKILL.md / WORKFLOW.md / references. Writing the five script names into SKILL.md
prose turns that gate green without an agent ever arriving at the classifier -- and worse, it
silences the one gate that found the hole. So reachability cannot be the acceptance signal here.

The acceptance signal is the executor's own output. start-here.ps1 is what enforces order in this
skill ("prose cannot enforce an order; a script that prints the next literal command can"), so
these cases run it against a throwaway product and assert on what it printed.

The pressure point is the pending-evidence list. When the six reverse-engineering categories are
still undecided, start-here.ps1 tells the agent what is missing; an agent that genuinely cannot
produce that evidence has only two ways out unless a third is offered -- write not_applicable, or
leave it blank. gap-classify.ps1 IS the third way out, so it has to be printed exactly there.

Nothing outside the fixture root is written and no target EXE is run.
#>

[CmdletBinding()]
param(
    [string]$SkillRoot,
    [string]$FixtureRoot = (Join-Path $env:TEMP ('eplc-cap-wiring-' + [guid]::NewGuid().ToString('N').Substring(0, 8))),
    [switch]$KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$script:Skill = (Resolve-Path -LiteralPath $SkillRoot).Path
$script:Results = New-Object System.Collections.Generic.List[psobject]

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Expected, [string]$Actual)

    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed })
    $label = 'FAIL'
    if ($Passed) { $label = 'PASS' }
    Write-Output ('{0}   {1,-44} expected[{2}] actual[{3}]' -f $label, $Name, $Expected, $Actual)
}

function Invoke-Script {
    param([Parameter(Mandatory = $true)][string]$Name, [string[]]$ScriptArgs = @())

    $path = Join-Path $script:Skill ('scripts\' + $Name)
    $raw = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $path @ScriptArgs 2>&1 | ForEach-Object { [string]$_ })
    return ($raw -join "`n")
}

function Get-GapClassifyLine {
    param([string]$Text)

    foreach ($line in ($Text -split "`n")) {
        if ($line -match 'gap-classify\.ps1') { return $line }
    }
    return ''
}

New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null
try {
    $root = Join-Path $FixtureRoot 'product'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $core = Join-Path $root 'demo.exe'
    [IO.File]::WriteAllText($core, 'fixture executable bytes for capability wiring', [Text.Encoding]::ASCII)
    $null = Invoke-Script -Name 'init-product.ps1' -ScriptArgs @('-ProductRoot', $root, '-ProductId', 'cap-wiring', '-CorePath', $core)

    # --- before the need exists ----------------------------------------------------------------
    # W1 -- at INIT the next transition asks for the baseline, not for the six analysis categories,
    # so there is no missing capability to classify yet. A branch that also fires here is not a
    # branch: it is a banner on every task, and a banner that is always on gets skimmed past. This
    # case is what keeps the hook honest about "the moment the agent needs a capability it lacks".
    $atInit = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root)
    $quiet = -not ($atInit -match 'gap-classify\.ps1')
    Add-Result -Name 'W1-silent-before-the-need-exists' -Passed $quiet -Expected 'absent' -Actual $(if ($quiet) { 'absent' } else { 'printed' })

    $null = Invoke-Script -Name 'update-product-state.ps1' -ScriptArgs @('-ProductRoot', $root, '-Status', 'BASELINE_CREATED', '-Mode', 'resume')

    # --- at the moment the pressure is applied ---------------------------------------------------
    # W2 -- the load-bearing case. BASELINE_CREATED is where start-here.ps1 lists the six undecided
    # categories as missing evidence. Remove the wiring from start-here.ps1 and this goes red, which
    # is the whole point: the subsystem's own tests stay green when it is unreachable, this one does
    # not. Note it asserts the EXECUTOR printed it, not that some file contains the string -- the
    # latter is equally green when the name only appears in a comment.
    $atAnalysis = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root)
    $printed = ($atAnalysis -match 'gap-classify\.ps1')
    Add-Result -Name 'W2-executor-reaches-gap-classify' -Passed $printed -Expected 'printed' -Actual $(if ($printed) { 'printed' } else { 'absent' })

    $gapLine = Get-GapClassifyLine -Text $atAnalysis

    # W3 -- a name the agent cannot act on is a mention, not wiring. gap-classify.ps1 refuses to
    # write anything without the failing command AND the file its output was saved to, so a printed
    # invocation that omits them sends the agent into a rejection it has no way to read as its own
    # mistake. These four are the evidence binding; -ProductRoot is what makes it a real command.
    $required = @('-ProductRoot', '-CapabilityId', '-Technique', '-FailureCommand', '-FailureOutputPath')
    $missing = @($required | Where-Object { $gapLine -notmatch [regex]::Escape($_) })
    Add-Result -Name 'W3-printed-command-carries-evidence-args' -Passed ($missing.Count -eq 0) -Expected 'complete' -Actual $(if ($missing.Count -eq 0) { 'complete' } else { 'missing ' + ($missing -join ' ') })

    # W4 -- the printed command has to keep matching the classifier it invokes. gap-classify.ps1 is
    # owned and edited elsewhere; a renamed parameter would leave start-here.ps1 printing a command
    # that fails at the prompt, and nothing else in the tree compares the two. So every switch on
    # the printed line is checked against the real param block instead of a copy of it.
    $gapPath = Join-Path $script:Skill 'scripts\gap-classify.ps1'
    $tokens = $null
    $parseErrors = $null
    $gapAst = [System.Management.Automation.Language.Parser]::ParseFile($gapPath, [ref]$tokens, [ref]$parseErrors)
    $declared = @()
    if ($null -ne $gapAst -and $null -ne $gapAst.ParamBlock) {
        $declared = @($gapAst.ParamBlock.Parameters | ForEach-Object { '-' + $_.Name.VariablePath.UserPath })
    }
    # Only the part after the script path: everything before it belongs to powershell.exe itself
    # (-NoProfile / -ExecutionPolicy / -File), which is not gap-classify.ps1's parameter surface.
    $tail = ''
    $split = [regex]::Match($gapLine, 'gap-classify\.ps1"?(.*)$')
    if ($split.Success) { $tail = $split.Groups[1].Value }
    $used = @([regex]::Matches($tail, '(?<![\w-])-([A-Za-z][A-Za-z0-9]*)') | ForEach-Object { '-' + $_.Groups[1].Value } | Select-Object -Unique)
    $unknown = @($used | Where-Object { $declared -notcontains $_ })
    $checked = ($used.Count -gt 0) -and ($declared.Count -gt 0)
    Add-Result -Name 'W4-printed-switches-exist-on-classifier' -Passed ($checked -and $unknown.Count -eq 0) -Expected 'all-declared' -Actual $(if (-not $checked) { 'nothing-to-check' } elseif ($unknown.Count -eq 0) { 'all-declared' } else { 'unknown ' + ($unknown -join ' ') })

    # W5 -- "how far along are we" is a read-only turn. Printing a write-capable classifier into an
    # answer the user only asked for information is how a status question turns into an unrequested
    # state change; the mode split already exists in start-here.ps1 and the hook must respect it.
    $asStatus = Invoke-Script -Name 'start-here.ps1' -ScriptArgs @('-ProductRoot', $root, '-UserRequest', 'status')
    $quietStatus = -not ($asStatus -match 'gap-classify\.ps1')
    Add-Result -Name 'W5-silent-on-a-read-only-status-turn' -Passed $quietStatus -Expected 'absent' -Actual $(if ($quietStatus) { 'absent' } else { 'printed' })
}
finally {
    if (-not $KeepFixture.IsPresent -and (Test-Path -LiteralPath $FixtureRoot -PathType Container)) {
        Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($script:Results | Where-Object { -not $_.Passed })
Write-Output ('RESULT: {0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Passed }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
