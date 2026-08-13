#requires -Version 5

# resolve-capability -- read-only bridge from a capability_id to whether an installed tool can provide it.
#
# It answers ONE question for gap-classify (step 1) and the later acquire gate: "for this capability, does
# TOOL-INVENTORY.json already list an available tool, and where is it?" -- without re-implementing discovery.
#
# Strictly read-only and non-installing: it NEVER downloads, installs, executes a tool, changes the
# inventory, or touches discover-tools.ps1's catalog. A missing inventory or an all-unavailable capability
# is reported as 'unavailable' (a normal answer, not an error); an id not in the bridge table is a clean
# 'unknown_capability' verdict, never a crash.
#
#   powershell -File resolve-capability.ps1 -CapabilityId decompile.dotnet -ProductRoot <product>
#   powershell -File resolve-capability.ps1 -CapabilityId unpack.pe.upx -InventoryPath <TOOL-INVENTORY.json>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CapabilityId,
    [string]$ProductRoot,
    [string]$InventoryPath,
    # Print the fixed three-part "I need a tool that can do X" brief after the verdict, for the two
    # verdicts that mean the table cannot help: 'unavailable' and 'unknown_capability'. Opt-in so the
    # machine-readable lines above it are byte-identical for every existing caller.
    [switch]$EmitToolRequest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')
. (Join-Path $PSScriptRoot 'lib\tool-catalog-common.ps1')

trap {
    # A resolver crash must not read as "no tools" (that would mislabel a real capability_gap) nor take the
    # caller down. Fail closed to a legible verdict line and a non-zero-but-not-crash exit.
    Write-Output 'RESULT: resolver_error'
    Write-Output ("detail=" + $_.Exception.Message)
    exit 4
}

# capability_id -> acceptable discover-tools catalog roles (tool_id). "available" iff ANY listed role has an
# available=true tool in TOOL-INVENTORY.json. The role ids here MUST match the tool catalog's role ids;
# both tables are now plain data (catalog/*.builtin.json merged with knowledge/tools/*.learned.json) and
# are loaded through the one shared reader. Covers both tracks: EXE reverse engineering and source-reuse /
# rebuild (a language/build chain being present == that build capability).
$script:CapabilityToolMap = Get-CapabilityBridgeTable

function Resolve-Capability {
    param(
        [Parameter(Mandatory = $true)][string]$CapabilityId,
        [AllowEmptyString()][string]$InventoryPath
    )

    if (-not $script:CapabilityToolMap.Contains($CapabilityId)) {
        return [pscustomobject]@{ capability_id = $CapabilityId; verdict = 'unknown_capability'; available = $false; matched_tool_id = ''; tool_path = ''; roles = @() }
    }
    $roles = @($script:CapabilityToolMap[$CapabilityId])
    $available = $false
    $matchedId = ''
    $toolPath = ''
    if (-not [string]::IsNullOrWhiteSpace($InventoryPath) -and (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
        $inv = $null
        try { $inv = Read-TextFileSafe -Path $InventoryPath | ConvertFrom-Json } catch { $inv = $null }
        if ($null -ne $inv) {
            foreach ($role in $roles) {
                foreach ($row in @($inv.tools)) {
                    if ([string](Get-PropertyValue $row 'tool_id' '') -ne $role) { continue }
                    if ((Get-PropertyValue $row 'available' $false) -ne $true) { continue }
                    $p = [string](Get-PropertyValue $row 'path' '')
                    if ([string]::IsNullOrWhiteSpace($p)) { continue }
                    $available = $true; $matchedId = $role; $toolPath = $p; break
                }
                if ($available) { break }
            }
        }
    }
    $verdict = if ($available) { 'available' } else { 'unavailable' }
    return [pscustomobject]@{ capability_id = $CapabilityId; verdict = $verdict; available = $available; matched_tool_id = $matchedId; tool_path = $toolPath; roles = $roles }
}

if ([string]::IsNullOrWhiteSpace($InventoryPath)) {
    if (-not [string]::IsNullOrWhiteSpace($ProductRoot) -and (Test-Path -LiteralPath $ProductRoot -PathType Container)) {
        $InventoryPath = Join-Path (Resolve-Path -LiteralPath $ProductRoot).Path 'product-state\tooling\TOOL-INVENTORY.json'
    }
}

$result = Resolve-Capability -CapabilityId $CapabilityId -InventoryPath $InventoryPath
Write-Output ("RESULT: " + $result.verdict)
Write-Output ("capability_id=" + $result.capability_id)
Write-Output ("matched_tool_id=" + $result.matched_tool_id)
Write-Output ("tool_path=" + $result.tool_path)
Write-Output ("roles=" + (@($result.roles) -join ','))
foreach ($catalogWarning in @(Get-ToolCatalogWarning)) { Write-Output ("catalogwarning=" + $catalogWarning) }
# "The table cannot answer" is the entrance to looking for a tool, not a dead end. Emitting the brief
# here keeps the ask in one place: what is needed, which candidates have a real provenance, and the
# fixed wording for coming back empty-handed. Empty-handed is a first-class outcome -- when it has no
# legitimate shape, the next best-sounding thing to produce is an invented tool name.
if ($EmitToolRequest -and $result.verdict -in @('unavailable', 'unknown_capability')) {
    Write-Output ''
    # InventoryPath is passed so the brief can tell "searched and missed" from "never searched": both
    # arrive here as 'unavailable', and conflating them is how a missing snapshot becomes a confident
    # "this machine does not have it".
    foreach ($line in @(Get-ToolRequestBrief -CapabilityId $CapabilityId -InventoryPath $InventoryPath)) { Write-Output $line }
}
# Every outcome here is a legible verdict, not a failure: 'unavailable' (incl. missing inventory) and
# 'unknown_capability' are normal answers the caller must be able to act on, so exit 0 and let the RESULT
# line carry the verdict. Only the trap above (an actual crash) returns non-zero.
exit 0
