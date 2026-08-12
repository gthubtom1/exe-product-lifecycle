#requires -Version 5

[CmdletBinding()]
param([string]$SkillRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\knowledge-common.ps1')
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }

$knowledge = Get-KnowledgeRoot -SkillRoot $SkillRoot
$lock = Enter-KnowledgeWriteLock -KnowledgeRoot $knowledge
try { Update-KnowledgeIndex -SkillRoot $SkillRoot }
finally { $lock.Dispose() }
Write-Output 'RESULT: knowledge_index_rebuilt'
Write-Output "index=$(Join-Path $knowledge 'INDEX.json')"
