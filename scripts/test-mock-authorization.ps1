#requires -Version 5

# Regression for the local temporary authorization mock (acceptance tier 1).
#
# Every case below is a "break it and this goes red" guard for one clause of the
# handoff acceptance list in references/auth-handoff.md: a wrong key, an expired
# key, a revoked key, a device change, a repeated activation and a cross-product
# key must each produce a distinct, stable reason code -- never a bare yes/no and
# never a silent pass.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\mock-auth-core.ps1')

$script:PassCount = 0
$script:FailCount = 0

function Assert-Value {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) {
        $script:PassCount++
        Write-Output ("PASS   {0,-42} expected[{1}] actual[{2}]" -f $Name, $Expected, $Actual)
    } else {
        $script:FailCount++
        Write-Output ("FAIL   {0,-42} expected[{1}] actual[{2}]" -f $Name, $Expected, $Actual)
    }
}

function New-Req {
    param(
        [string]$LicenseKey = 'DEMO-VALID-0001',
        [string]$DeviceId = 'device-A',
        [string]$SessionToken,
        [string]$ProductId = 'DEMO-PRODUCT',
        [string]$ProfileId = 'default',
        [string]$ProtocolVersion = 'authorization.v1'
    )
    $r = @{
        protocol_version = $ProtocolVersion
        request_id       = [guid]::NewGuid().ToString('N')
        sent_at          = '2026-01-01T00:00:00Z'
        product_id       = $ProductId
        profile_id       = $ProfileId
        client_id        = 'mock-launcher'
        client_version   = '1.0.0'
        target           = 'windows'
        arch             = 'x64'
        channel          = 'stable'
        installation_id  = 'install-1'
    }
    if ($LicenseKey) { $r['license_key'] = $LicenseKey }
    if ($DeviceId) { $r['device_id'] = $DeviceId }
    if ($SessionToken) { $r['session_token'] = $SessionToken }
    return $r
}

# --- happy path -------------------------------------------------------------
$state = New-MockAuthState
$ok = Invoke-MockAuthorization -Operation activate -Request (New-Req) -State $state
Assert-Value 'A1-valid-activate-ok' 'ok' $ok.body.reason_code
Assert-Value 'A1-status-200' '200' "$($ok.status_code)"
Assert-Value 'A1-session-issued' 'yes' $(if ($ok.body.session_token) { 'yes' } else { 'no' })
Assert-Value 'A1-entitlement-returned' 'DEMO-PRODUCT' $ok.body.entitlement.product_id
# A-tier strong binding needs the server to hand back run-required material,
# not just a yes/no. The real platform does not implement this yet.
Assert-Value 'A1-release-material-present' 'yes' $(if ($ok.body.release_material.material) { 'yes' } else { 'no' })
$goodToken = $ok.body.session_token

# --- protocol / request shape ----------------------------------------------
$bad = Invoke-MockAuthorization -Operation activate -Request (New-Req -ProtocolVersion 'authorization.v0') -State (New-MockAuthState)
Assert-Value 'A2-wrong-protocol-refused' 'unsupported_protocol_version' $bad.body.reason_code

$noKey = New-Req
$noKey.Remove('license_key') | Out-Null
$bad = Invoke-MockAuthorization -Operation activate -Request $noKey -State (New-MockAuthState)
Assert-Value 'A3-missing-license-refused' 'invalid_request' $bad.body.reason_code

# --- license state ----------------------------------------------------------
$bad = Invoke-MockAuthorization -Operation activate -Request (New-Req -LicenseKey 'NOPE-9999') -State (New-MockAuthState)
Assert-Value 'A4-unknown-license' 'license_not_found' $bad.body.reason_code

$bad = Invoke-MockAuthorization -Operation activate -Request (New-Req -LicenseKey 'DEMO-EXPIRED-0002') -State (New-MockAuthState)
Assert-Value 'A5-expired-license' 'license_expired' $bad.body.reason_code

$bad = Invoke-MockAuthorization -Operation activate -Request (New-Req -LicenseKey 'DEMO-REVOKED-0003') -State (New-MockAuthState)
Assert-Value 'A6-revoked-license' 'license_revoked' $bad.body.reason_code

$bad = Invoke-MockAuthorization -Operation activate -Request (New-Req -ProductId 'OTHER-PRODUCT') -State (New-MockAuthState)
Assert-Value 'A7-cross-product-refused' 'product_mismatch' $bad.body.reason_code

# --- device binding ---------------------------------------------------------
$devState = New-MockAuthState
$first = Invoke-MockAuthorization -Operation activate -Request (New-Req -LicenseKey 'DEMO-DEVLIMIT-0004' -DeviceId 'device-A') -State $devState
Assert-Value 'A8-first-device-ok' 'ok' $first.body.reason_code
$repeat = Invoke-MockAuthorization -Operation activate -Request (New-Req -LicenseKey 'DEMO-DEVLIMIT-0004' -DeviceId 'device-A') -State $devState
Assert-Value 'A8-same-device-repeat-ok' 'ok' $repeat.body.reason_code
$second = Invoke-MockAuthorization -Operation activate -Request (New-Req -LicenseKey 'DEMO-DEVLIMIT-0004' -DeviceId 'device-B') -State $devState
Assert-Value 'A9-second-device-refused' 'device_limit_reached' $second.body.reason_code

# --- session lifecycle ------------------------------------------------------
$v = Invoke-MockAuthorization -Operation validate -Request (New-Req -SessionToken $goodToken) -State $state
Assert-Value 'A10-validate-good-session' 'ok' $v.body.reason_code

$v = Invoke-MockAuthorization -Operation validate -Request (New-Req -SessionToken 'not-a-real-token') -State $state
Assert-Value 'A11-validate-bad-session' 'session_invalid' $v.body.reason_code

$h = Invoke-MockAuthorization -Operation heartbeat -Request (New-Req -SessionToken $goodToken) -State $state
Assert-Value 'A12-heartbeat-good-session' 'ok' $h.body.reason_code

# Revoking after activation must be visible to an already-issued session,
# otherwise a revoked key keeps running until the process exits.
$revokeState = New-MockAuthState
$act = Invoke-MockAuthorization -Operation activate -Request (New-Req) -State $revokeState
$revokeState.licenses['DEMO-VALID-0001'].status = 'revoked'
$v = Invoke-MockAuthorization -Operation validate -Request (New-Req -SessionToken $act.body.session_token) -State $revokeState
Assert-Value 'A13-revoke-hits-live-session' 'license_revoked' $v.body.reason_code

# --- deactivate frees the device slot ---------------------------------------
$freeState = New-MockAuthState
$act = Invoke-MockAuthorization -Operation activate -Request (New-Req -LicenseKey 'DEMO-DEVLIMIT-0004' -DeviceId 'device-A') -State $freeState
$blocked = Invoke-MockAuthorization -Operation activate -Request (New-Req -LicenseKey 'DEMO-DEVLIMIT-0004' -DeviceId 'device-B') -State $freeState
Assert-Value 'A14-blocked-before-deactivate' 'device_limit_reached' $blocked.body.reason_code
$d = Invoke-MockAuthorization -Operation deactivate -Request (New-Req -SessionToken $act.body.session_token) -State $freeState
Assert-Value 'A14-deactivate-ok' 'ok' $d.body.reason_code
$after = Invoke-MockAuthorization -Operation activate -Request (New-Req -LicenseKey 'DEMO-DEVLIMIT-0004' -DeviceId 'device-B') -State $freeState
Assert-Value 'A14-slot-freed' 'ok' $after.body.reason_code
$dead = Invoke-MockAuthorization -Operation validate -Request (New-Req -SessionToken $act.body.session_token) -State $freeState
Assert-Value 'A15-session-dead-after-deactivate' 'session_invalid' $dead.body.reason_code

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
