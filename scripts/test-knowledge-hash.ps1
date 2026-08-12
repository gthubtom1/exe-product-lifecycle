#requires -Version 5
<#
Cross-host guard for the experience payload hash.

    powershell -NoProfile -ExecutionPolicy Bypass -File test-knowledge-hash.ps1
    pwsh       -File test-knowledge-hash.ps1

Get-ExperiencePayloadHash must produce the same hash for the same record on Windows PowerShell 5.1
and PowerShell 7. It did not: it serialized the payload with ConvertTo-Json, which escapes non-ASCII
as \uXXXX on 5.1 and emits it raw on 7. So a record whose payload carried Chinese hashed to two
different values, and validation on the other host failed with "payload hash mismatch" -- green on
5.1, red on the pwsh 7 lane, invisible until a non-ASCII record existed. This pins the canonical
hash of a deliberately Chinese record: revert the hash to a host-dependent serializer and it
reddens (on at least one host, both in practice). The record is built once and reused, so the pin
is a property of the hashing, not of any file on disk.
#>
[CmdletBinding()] param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\knowledge-common.ps1')

$expected = '034DF8B69A38B0D7060D80AC997FBC199E3C3B2C43D7B189814B768BEC72CA18'
$record = [pscustomobject][ordered]@{
    title = '中文标题：跨宿主哈希'
    summary = '含中文的摘要，用来固定非 ASCII 载荷的哈希。'
    category = 'tooling'
    tags = @('windows', '中文标签')
    source_evidence = @([pscustomobject][ordered]@{
            source_id = 'src-' + ('a' * 32)
            source_kind = 'fixture'
            evidence_role = 'supporting'
            artifact_kind = 'ps1'
            evidence_proof_id = 'proof-' + ('b' * 32)
            evidence_level = 'failure_observed'
        })
    pattern = [pscustomobject][ordered]@{
        applicability = @('甲'); detection = @('乙'); negative_indicators = @('丙')
        procedure = @('丁'); verification = @('戊'); rollback = @('己')
        failure_signals = @('庚'); stop_conditions = @('辛'); limitations = @('壬')
    }
}
# The same round-trip capture-experience.ps1 does, so the object shape matches the real path.
$record = ($record | ConvertTo-Json -Depth 30) | ConvertFrom-Json
$actual = Get-ExperiencePayloadHash -Record $record

$failed = 0
if ($actual -eq $expected) {
    Write-Output "PASS  chinese-payload-hash-is-host-independent expected[$expected] actual[$actual]"
}
else {
    Write-Output "FAIL  chinese-payload-hash-is-host-independent expected[$expected] actual[$actual]"
    $failed++
}

$again = Get-ExperiencePayloadHash -Record $record
if ($again -eq $actual) {
    Write-Output 'PASS  payload-hash-is-stable-within-host'
}
else {
    Write-Output "FAIL  payload-hash-is-stable-within-host first[$actual] second[$again]"
    $failed++
}

Write-Output ("RESULT: {0} passed, {1} failed" -f (2 - $failed), $failed)
if ($failed -gt 0) { exit 1 }
# Explicit, per the leftover-exit-code lesson: CI runs this as `pwsh -command`, where a stray
# non-zero $LASTEXITCODE from any earlier sub-call would otherwise become the step's result.
exit 0
