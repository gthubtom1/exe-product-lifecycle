#requires -Version 5

# learn-tool -- record a tool this machine just used, so the next run does not have to search for it again.
#
# Ordering matters and is not negotiable: find -> ask the user -> install -> USE IT AND FINISH THE WORK ->
# append. Appending is a side effect after the fact, never a precondition, so this script never fails the
# caller: a write that does not land is a warning plus the entry echoed verbatim, on the summary line.
# Losing one lesson is survivable; losing it without knowing what was lost is not.
#
# Two different things with two different rules:
#   -Name              appends an executable name to an existing role. AUTOMATIC -- enriching names can at
#                      worst make discovery notice a tool nobody wanted; it does not change any verdict.
#   -BridgeCapability  maps a capability to a role. NOT automatic -- it changes whether this machine counts
#                      as able to do something, which gap-classify and the install gate consume directly.
#                      It rides on the approval the user already gives when deciding whether to install, so
#                      it needs -BridgeApproved. Without it the mapping is reported as pending, never
#                      silently dropped and never a second approval prompt.
#
#   powershell -File learn-tool.ps1 -RoleId package-inspect -Name innoextract.exe `
#       -AddedForCapability unpack.installer.innosetup -SourceUrl https://constexpr.org/innoextract `
#       -InstallRoute winget -BridgeCapability unpack.installer.innosetup -BridgeApproved

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RoleId,
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$SkillRoot,
    [string]$AddedForCapability = '',
    [ValidateSet('web', 'winget', 'user_supplied')][string]$FoundVia = 'web',
    [string]$SourceUrl = '',
    [ValidateSet('winget', 'manual', 'already_present')][string]$InstallRoute = 'manual',
    [string[]]$UsedByProducts = @(),
    [string]$BridgeCapability = '',
    [switch]$BridgeApproved,
    [string]$BridgeApprovalNote = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\tool-catalog-common.ps1')

trap {
    # Even a crash here must not read as "the work failed": the work is already done and committed.
    Write-Output 'RESULT: learn_tool_error'
    Write-Output ("tools_learned=0 appended, 1 failed")
    Write-Output ("failed_entry=role=$RoleId name=$Name")
    Write-Output ("detail=" + $_.Exception.Message)
    exit 0
}

if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }

$appended = 0
$failed = 0
$failedEntries = New-Object System.Collections.Generic.List[string]

$toolResult = Add-LearnedToolName -SkillRoot $SkillRoot -RoleId $RoleId -Name $Name `
    -AddedForCapability $AddedForCapability -FoundVia $FoundVia -SourceUrl $SourceUrl `
    -InstallRoute $InstallRoute -UsedByProducts $UsedByProducts

if ($toolResult.Status -eq 'appended') { $appended++ }
elseif ($toolResult.Status -eq 'already_present') { }
else { $failed++; [void]$failedEntries.Add($toolResult.Entry) }
$roleEscalation = @($toolResult.Escalation)

$bridgeState = 'not_requested'
$bridgeResult = $null
if (-not [string]::IsNullOrWhiteSpace($BridgeCapability)) {
    $bridgeResult = Add-LearnedCapabilityRole -SkillRoot $SkillRoot -CapabilityId $BridgeCapability `
        -RoleId $RoleId -Approved:$BridgeApproved -ApprovedNote $BridgeApprovalNote
    $bridgeState = $bridgeResult.Status
}

Write-Output ("RESULT: " + $(if ($failed -gt 0) { 'learn_tool_partial' } else { 'learn_tool_recorded' }))
Write-Output ("tool_status=" + $toolResult.Status)
if (-not [string]::IsNullOrWhiteSpace($toolResult.Reason)) { Write-Output ("tool_detail=" + $toolResult.Reason) }
Write-Output ("bridge_status=" + $bridgeState)
if ($null -ne $bridgeResult -and -not [string]::IsNullOrWhiteSpace($bridgeResult.Reason)) { Write-Output ("bridge_detail=" + $bridgeResult.Reason) }
foreach ($catalogWarning in @(Get-ToolCatalogWarning)) { Write-Output ("catalogwarning=" + $catalogWarning) }

# The three-state summary line the rest of this skill already uses. A run that prints one warning in the
# middle and then a clean summary is the exact shape that let two earlier defects ship unnoticed.
Write-Output ("tools_learned=$appended appended, $failed failed")
if ($bridgeState -eq 'pending_approval') {
    Write-Output 'bridge_pending=1'
    Write-Output "  待确认的桥表映射：$BridgeCapability -> $RoleId"
    Write-Output '  并进「找到候选、装不装」那一次点头里问，不要新开一次审批。'
}
# The exit for "none of the 26 classes fit". Without it the only ways out of the refusal are to give up
# or to file the tool under a role it does not belong to, and the second one is invisible afterwards.
if ($roleEscalation.Count -gt 0) {
    Write-Output 'role_escalation=1'
    foreach ($line in $roleEscalation) { Write-Output ("  " + $line) }
}
# Printed verbatim so a lost lesson can be pasted back in by hand.
foreach ($entry in $failedEntries) { Write-Output ("failed_entry=" + $entry) }
exit 0
