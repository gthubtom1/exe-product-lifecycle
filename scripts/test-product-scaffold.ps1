#requires -Version 5

[CmdletBinding()]
param([string]$SkillRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$tempBase = [IO.Path]::GetTempPath()
$temp = Join-Path $tempBase ('exe-lifecycle-product-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $core = Join-Path $temp 'sample.exe'
    $document = Join-Path $temp 'requirements.md'
    [IO.File]::WriteAllText($core, 'fixture executable bytes', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($document, '# Fixture requirement', (New-Object Text.UTF8Encoding($false)))
    & (Join-Path $SkillRoot 'scripts\init-product.ps1') -ProductRoot $temp -ProductId 'sample-product' -ProductName 'Sample Product' -CorePath $core -StartDocumentPath $document | Out-Null
    if (-not $?) { throw 'init-product.ps1 failed' }
    $output = & (Join-Path $SkillRoot 'scripts\validate-product-state.ps1') -ProductRoot $temp 2>&1
    if (-not $?) { throw "validate-product-state.ps1 failed: $($output -join '; ')" }
    foreach ($required in @('CANDIDATE-DRAFT.json', 'EXPERIENCE-EXPORTS.json', 'SHARING-REVIEW.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $temp "product-state\learning\$required") -PathType Leaf)) { throw "missing learning scaffold: $required" }
    }
    Write-Output 'RESULT: passed (new product includes valid reusable-learning scaffold)'
}
finally {
    if ((Test-Path -LiteralPath $temp -PathType Container) -and $temp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
