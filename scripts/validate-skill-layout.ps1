#requires -Version 5

[CmdletBinding()]
param([string]$SkillRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$root = (Resolve-Path -LiteralPath $SkillRoot).Path
$errors = New-Object System.Collections.Generic.List[string]

$skillPath = Join-Path $root 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) { [void]$errors.Add('SKILL.md is missing') }
else {
    $skill = Get-Content -Raw -Encoding UTF8 -LiteralPath $skillPath
    # Validate the PORTABLE trigger every agent reads (Agent Skills open standard: name + description),
    # tolerating extra standard fields such as compatibility / license. The old regex demanded exactly
    # "name then description then ---", so adding a standard field would have read as invalid frontmatter,
    # and it never enforced name == directory. openai.yaml is a Codex-only mirror, no longer required here.
    $frontmatter = [regex]::Match($skill, '(?s)^---\r?\n(.*?)\r?\n---\r?\n')
    if (-not $frontmatter.Success) { [void]$errors.Add('SKILL.md frontmatter block is missing (--- ... ---)') }
    else {
        $frontmatterBody = $frontmatter.Groups[1].Value
        if ($frontmatterBody -notmatch '(?m)^name:\s*exe-product-lifecycle\s*$') { [void]$errors.Add('SKILL.md frontmatter name must equal the skill directory name (exe-product-lifecycle)') }
        if ($frontmatterBody -notmatch '(?m)^description:[ \t]*\S') { [void]$errors.Add('SKILL.md frontmatter description is empty (it is the portable trigger every agent reads)') }
    }
    if ((Get-Content -Encoding UTF8 -LiteralPath $skillPath).Count -gt 500) { [void]$errors.Add('SKILL.md exceeds 500 lines') }
}

foreach ($required in @('WORKFLOW.md', 'references/knowledge-lifecycle.md', 'knowledge/INDEX.json', 'knowledge/knowledge.lock.json', 'assets/lifecycle-states.json', 'scripts/lib/product-state-common.ps1', 'scripts/update-product-state.ps1', 'scripts/start-here.ps1', 'scripts/detect-protections.ps1', 'scripts/lib/mock-auth-core.ps1', 'scripts/mock-authorization-server.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) { [void]$errors.Add("required skill file is missing: $required") }
}

foreach ($script in @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Recurse -File -Filter '*.ps1')) {
    $tokens = $null
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in @($parseErrors)) { [void]$errors.Add("PowerShell parse error $($script.Name):$($parseError.Extent.StartLineNumber): $($parseError.Message)") }

    # Assigning to a reserved automatic variable ($pid, $args, ...) silently shadows it and has
    # repeatedly broken scripts; a clean parse never flagged it (the assignment is valid syntax). The
    # AST is already in hand, so walk it for assignments whose left-hand side is a reserved automatic.
    if ($null -ne $scriptAst) {
        $reservedAuto = @('pid', 'args', 'input', 'error', 'host', 'home', 'pwd', 'matches', 'this', 'psitem')
        foreach ($assignment in @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
            $lhs = $assignment.Left
            if ($lhs -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $variableName = $lhs.VariablePath.UserPath
                if ($reservedAuto -contains $variableName.ToLowerInvariant()) {
                    [void]$errors.Add("assigns to reserved automatic variable `$$variableName (shadows it; breaks on Windows PowerShell): scripts/$($script.Name):$($assignment.Extent.StartLineNumber)")
                }
            }
        }
    }

    # Windows PowerShell 5.1 decodes a BOM-less .ps1 with the machine's ANSI codepage, so a script
    # holding Chinese text parses here (ACP 65001) and dies with "Missing ')'" on an ordinary
    # English or GBK Windows. Parsing this file cannot catch it -- the host that reads it decides.
    $bytes = [IO.File]::ReadAllBytes($script.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $hasNonAscii = $false
    foreach ($byte in $bytes) { if ($byte -gt 127) { $hasNonAscii = $true; break } }
    if ($hasNonAscii -and -not $hasBom) { [void]$errors.Add("non-ASCII script without UTF-8 BOM (breaks Windows PowerShell 5.1 on a non-UTF-8 codepage): scripts/$($script.Name)") }
}

foreach ($json in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })) {
    try { $null = Get-Content -Raw -Encoding UTF8 -LiteralPath $json.FullName | ConvertFrom-Json }
    catch { [void]$errors.Add("invalid JSON: $($json.FullName.Substring($root.Length + 1))") }
}

# --- Reachability: a shipped script nobody can reach is dead weight -------------------------
# The whole capability library (gap-classify, resolve-capability, validate-capabilities,
# rebuild-capability-index, lib/capability-common) shipped without ever being named in SKILL.md.
# The installed copy simply lacked those files and nothing broke, while their own 72 tests stayed
# green -- the green is what hid it. So the question is not "is this file referenced somewhere"
# (CI references everything, and a dry run of that criterion flagged 0 of 40 scripts, including
# the dead ones). The question is "does anything actually reach here".
#
# Three classes, because the right proof differs, and each proof has to be one that rots loudly:
#   - a normal script must be reachable from the agent entry (SKILL.md / WORKFLOW.md / references)
#     through the script call graph. Prose is a weak proof -- writing a filename into a sentence
#     satisfies it -- so this is only the dead-weight check. Whether a chain is really wired is a
#     question for a behaviour test on the executor's own output, and cannot be asked here.
#   - a build-time gate (validate-*, rebuild-*) is invoked by a CI step and by nothing else, and for
#     it that IS the right proof: CI running it is its whole job, not merely evidence that it
#     compiles. This proof also maintains itself -- delete the step and the script goes red the same
#     day, which neither a doc sentence nor a hand-written declaration would do.
#   - a test script must be named by CI; for a test, that IS the right proof.
#
# Reachability never propagates *through* a test script. A test proves the code can run, not that
# anything uses it; seeding from tests is precisely the 0-of-40 criterion, since
# test-resolve-capability names resolve-capability and would have made the dead library green on
# the day it shipped.
#
# Known limitation, and the second reason the escape hatch below exists: a script invoked through a
# dynamically assembled path is not visible to this text scan and would be misjudged. Zero such
# cases at the time of writing; when one appears, declare it rather than inventing a reference.
$entryDocs = New-Object System.Collections.Generic.List[string]
foreach ($doc in @('SKILL.md', 'WORKFLOW.md')) {
    $docPath = Join-Path $root $doc
    if (Test-Path -LiteralPath $docPath -PathType Leaf) { [void]$entryDocs.Add($docPath) }
}
$referencesDir = Join-Path $root 'references'
if (Test-Path -LiteralPath $referencesDir -PathType Container) {
    foreach ($ref in @(Get-ChildItem -LiteralPath $referencesDir -File -Filter '*.md')) { [void]$entryDocs.Add($ref.FullName) }
}

$allScripts = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Recurse -File -Filter '*.ps1')
$scriptText = @{}
foreach ($item in $allScripts) { $scriptText[$item.Name] = (Get-Content -Raw -Encoding UTF8 -LiteralPath $item.FullName) }

# A bare Contains() lets test-foo.ps1 vouch for foo.ps1, because the production name is a suffix of
# its own test's name. That hands reachability back to test scripts through the side door -- exactly
# the 0-of-40 criterion this gate replaced -- so a hit must not begin inside a longer filename.
function Test-TextNamesScript {
    param([string]$Text, [string]$Name)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [regex]::IsMatch($Text, '(?<![\w-])' + [regex]::Escape($Name))
}

function Get-MentionedScripts {
    param([string]$Text, [string]$ExcludeName)
    $hits = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Text)) { return $hits }
    foreach ($candidate in $allScripts) {
        if ($candidate.Name -eq $ExcludeName) { continue }
        if (Test-TextNamesScript -Text $Text -Name $candidate.Name) { [void]$hits.Add($candidate.Name) }
    }
    return $hits
}

# CI reachability must come from actual invocations, not from any text in the workflow. A filename
# that appears only in a step's `name:` label (or any non-`run:` line) is documentation, not
# execution -- the CI-channel twin of the test-name mention-vs-use hole (RG6). So $ciText is built
# ONLY from `run:` command content: the value on a single-line `run:` and the indented body of a
# `run: |` block scalar. Comments are dropped for the same reason.
$ciText = ''
$workflowDir = Join-Path $root '.github\workflows'
if (Test-Path -LiteralPath $workflowDir -PathType Container) {
    foreach ($workflow in @(Get-ChildItem -LiteralPath $workflowDir -File)) {
        $inRunBlock = $false
        $runBlockIndent = -1
        foreach ($line in @(Get-Content -LiteralPath $workflow.FullName)) {
            if ($line -match '^\s*#') { continue }
            $indent = $line.Length - $line.TrimStart().Length
            if ($inRunBlock) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($indent -gt $runBlockIndent) { $ciText += ($line + "`n"); continue }
                $inRunBlock = $false
            }
            $runMatch = [regex]::Match($line, '^\s*run:\s*(.*)$')
            if (-not $runMatch.Success) { continue }
            $runValue = $runMatch.Groups[1].Value.Trim()
            if ($runValue -in @('|', '|-', '|+', '>', '>-', '>+', '')) {
                $inRunBlock = $true
                $runBlockIndent = $indent
            } else {
                $ciText += ($runValue + "`n")
            }
        }
    }
}

$reachable = New-Object System.Collections.Generic.HashSet[string]
$pending = New-Object System.Collections.Generic.Queue[string]
foreach ($doc in $entryDocs) {
    foreach ($named in (Get-MentionedScripts -Text (Get-Content -Raw -Encoding UTF8 -LiteralPath $doc) -ExcludeName '')) {
        if ($reachable.Add($named)) { $pending.Enqueue($named) }
    }
}
foreach ($item in $allScripts) {
    if ($item.BaseName -like 'test-*') { continue }
    if (Test-TextNamesScript -Text $ciText -Name $item.Name) {
        if ($reachable.Add($item.Name)) { $pending.Enqueue($item.Name) }
    }
}
while ($pending.Count -gt 0) {
    $current = $pending.Dequeue()
    if (-not $scriptText.ContainsKey($current)) { continue }
    if ($current -like 'test-*') { continue }
    foreach ($named in (Get-MentionedScripts -Text $scriptText[$current] -ExcludeName $current)) {
        if ($reachable.Add($named)) { $pending.Enqueue($named) }
    }
}

# The escape hatch (a legitimate standalone entry point says so in its own header). It has to be
# cheaper than fabricating a reference -- you are already editing this file, so it is one line --
# and it has to be visible, so it travels in that script's own diff. An empty or placeholder
# reason is not a declaration: without this the hatch degrades into a silencer.
$placeholderReason = '^(?i)\s*(todo|tbd|n/?a|none|placeholder|unverified|xxx+|\?+|-+)\s*$'
foreach ($item in $allScripts) {
    $relative = 'scripts/' + $item.FullName.Substring((Join-Path $root 'scripts').Length + 1).Replace('\', '/')
    if ($item.BaseName -like 'test-*') {
        if (-not (Test-TextNamesScript -Text $ciText -Name $item.Name)) {
            [void]$errors.Add("test script is not run by CI (nothing executes it): $relative")
        }
        continue
    }
    if ($reachable.Contains($item.Name)) { continue }
    $declaration = [regex]::Match($scriptText[$item.Name], '(?m)^\s*#\s*SKILL-ENTRYPOINT:(.*)$')
    if (-not $declaration.Success) {
        [void]$errors.Add("shipped script is unreachable from SKILL.md/WORKFLOW.md/references, is invoked by no CI step, and is not declared an entry point: $relative (wire it into the workflow, run it from CI if it is a build-time gate, or declare it with a '# SKILL-ENTRYPOINT: <why>' header line)")
        continue
    }
    $reason = $declaration.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($reason) -or $reason -match $placeholderReason) {
        [void]$errors.Add("SKILL-ENTRYPOINT declaration has no real reason (a placeholder is not a declaration): $relative")
    }
}

$knowledgeRoot = Join-Path $root 'knowledge'
foreach ($file in @(Get-ChildItem -LiteralPath $knowledgeRoot -Recurse -File)) {
    if ($file.Name -in @('INDEX.json', 'knowledge.lock.json', '.gitkeep', '.knowledge-write.lock')) { continue }
    if ($file.Extension -ne '.json') { [void]$errors.Add("non-JSON public knowledge file: $($file.FullName.Substring($root.Length + 1))") }
}

$knowledgeOutput = & (Join-Path $root 'scripts\validate-knowledge.ps1') -SkillRoot $root 2>&1
$knowledgeSucceeded = $?
if (-not $knowledgeSucceeded) { [void]$errors.Add("knowledge validation failed: $($knowledgeOutput -join '; ')") }
if ($errors.Count -gt 0) {
    foreach ($item in $errors) { Write-Output "ERROR: $item" }
    Write-Output "RESULT: failed ($($errors.Count) error(s))"
    exit 1
}
Write-Output "RESULT: passed (skill layout, PowerShell syntax, JSON syntax, public knowledge boundary)"
