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
        if ($frontmatterBody -notmatch '(?m)^description:\s*\S') { [void]$errors.Add('SKILL.md frontmatter description is empty (it is the portable trigger every agent reads)') }
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
