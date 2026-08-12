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
    $skill = Get-Content -Raw -LiteralPath $skillPath
    if ($skill -notmatch '(?s)^---\r?\nname:\s*exe-product-lifecycle\r?\ndescription:\s*.+?\r?\n---\r?\n') { [void]$errors.Add('SKILL.md frontmatter is invalid') }
    if ((Get-Content -LiteralPath $skillPath).Count -gt 500) { [void]$errors.Add('SKILL.md exceeds 500 lines') }
}

foreach ($required in @('WORKFLOW.md', 'agents/openai.yaml', 'references/knowledge-lifecycle.md', 'knowledge/INDEX.json', 'knowledge/knowledge.lock.json', 'assets/lifecycle-states.json', 'scripts/lib/product-state-common.ps1', 'scripts/update-product-state.ps1', 'scripts/start-here.ps1', 'scripts/detect-protections.ps1', 'scripts/lib/mock-auth-core.ps1', 'scripts/mock-authorization-server.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) { [void]$errors.Add("required skill file is missing: $required") }
}

foreach ($script in @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Recurse -File -Filter '*.ps1')) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in @($parseErrors)) { [void]$errors.Add("PowerShell parse error $($script.Name):$($parseError.Extent.StartLineNumber): $($parseError.Message)") }
}

foreach ($json in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })) {
    try { $null = Get-Content -Raw -LiteralPath $json.FullName | ConvertFrom-Json }
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
