#requires -Version 5

# Mock of the authorization.v1 CLIENT contract for the EXE product lifecycle.
#
# Purpose: the first acceptance tier -- "local temporary authorization". It lets
# a rebuilt/wrapped product run under a real authorization handshake BEFORE the
# universal platform is finished, so the Launcher <-> core wiring and the three
# acceptance tiers can be exercised locally. Point the product Launcher at the
# local mock server, hand out a DEMO license, and the same client that will later
# talk to the real platform runs unchanged; only base_url changes at cutover.
#
# This is NOT a real authorization server:
#   * it is in-memory and deterministic,
#   * its DEMO licenses and keys are fixed sample data,
#   * it must never be packaged into an end-user release.
#
# It mirrors the real contract shape observed in
# clients/node/authorization-client.mjs of the authorization platform:
#   operations: activate | validate | heartbeat | deactivate
#   stable machine reason codes, never a bare yes/no.

Set-StrictMode -Version Latest

$script:MockProtocolVersion = 'authorization.v1'

function New-MockAuthState {
    [CmdletBinding()]
    param([string]$NowUtc = '2026-01-01T00:00:00Z')
    return [pscustomobject]@{
        protocol_version = $script:MockProtocolVersion
        now_utc          = $NowUtc
        licenses         = @{
            'DEMO-VALID-0001'    = @{ status = 'active';  expires_at = '2099-01-01T00:00:00Z'; max_devices = 1; product_id = 'DEMO-PRODUCT'; profile_id = 'default'; features = @('core') }
            'DEMO-EXPIRED-0002'  = @{ status = 'active';  expires_at = '2000-01-01T00:00:00Z'; max_devices = 1; product_id = 'DEMO-PRODUCT'; profile_id = 'default'; features = @('core') }
            'DEMO-REVOKED-0003'  = @{ status = 'revoked'; expires_at = '2099-01-01T00:00:00Z'; max_devices = 1; product_id = 'DEMO-PRODUCT'; profile_id = 'default'; features = @('core') }
            'DEMO-DEVLIMIT-0004' = @{ status = 'active';  expires_at = '2099-01-01T00:00:00Z'; max_devices = 1; product_id = 'DEMO-PRODUCT'; profile_id = 'default'; features = @('core') }
        }
        bound_devices = @{}
        sessions      = @{}
    }
}

function _Utc([string]$s) {
    return [System.DateTimeOffset]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
}

function _Resp {
    param([int]$Code, [string]$Reason, [bool]$Ok, [hashtable]$Extra)
    $body = @{ protocol_version = $script:MockProtocolVersion; reason_code = $Reason; ok = $Ok }
    if ($Extra) { foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] } }
    return [pscustomobject]@{ status_code = $Code; body = $body }
}

function _Has {
    param([hashtable]$Request, [string]$Key)
    return ($Request.ContainsKey($Key) -and $null -ne $Request[$Key] -and "$($Request[$Key])".Trim().Length -gt 0)
}

function _DeriveReleaseMaterial {
    # Deterministic, mock-only stand-in for "the server hands the core the key/
    # config it needs to run" (A-tier strong binding). The REAL platform must add
    # this capability; today its client API only returns activate/validate
    # judgements. See references/auth-handoff.md, section "平台能力缺口".
    param([string]$LicenseKey)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("mock-release-material::$LicenseKey"))
    } finally { $sha.Dispose() }
    return [System.Convert]::ToBase64String($bytes)
}

function Invoke-MockAuthorization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('activate','validate','heartbeat','deactivate')][string]$Operation,
        [Parameter(Mandatory)][hashtable]$Request,
        [Parameter(Mandatory)][psobject]$State
    )

    if (-not (_Has $Request 'protocol_version') -or $Request['protocol_version'] -ne $script:MockProtocolVersion) {
        return (_Resp -Code 400 -Reason 'unsupported_protocol_version' -Ok $false)
    }
    foreach ($required in @('product_id','profile_id')) {
        if (-not (_Has $Request $required)) { return (_Resp -Code 400 -Reason 'invalid_request' -Ok $false) }
    }

    switch ($Operation) {
        'activate' {
            foreach ($required in @('license_key','device_id')) {
                if (-not (_Has $Request $required)) { return (_Resp -Code 400 -Reason 'invalid_request' -Ok $false) }
            }
            $key = $Request['license_key']
            if (-not $State.licenses.ContainsKey($key)) { return (_Resp -Code 404 -Reason 'license_not_found' -Ok $false) }
            $lic = $State.licenses[$key]
            if ($lic.product_id -ne $Request['product_id'] -or $lic.profile_id -ne $Request['profile_id']) {
                return (_Resp -Code 409 -Reason 'product_mismatch' -Ok $false)
            }
            if ($lic.status -eq 'revoked') { return (_Resp -Code 403 -Reason 'license_revoked' -Ok $false) }
            if ((_Utc $lic.expires_at) -lt (_Utc $State.now_utc)) { return (_Resp -Code 403 -Reason 'license_expired' -Ok $false) }

            $device = $Request['device_id']
            if (-not $State.bound_devices.ContainsKey($key)) { $State.bound_devices[$key] = @() }
            $bound = @($State.bound_devices[$key])
            if ($bound -notcontains $device) {
                if ($bound.Count -ge [int]$lic.max_devices) { return (_Resp -Code 403 -Reason 'device_limit_reached' -Ok $false) }
                $bound += $device
                $State.bound_devices[$key] = $bound
            }

            $token = [guid]::NewGuid().ToString('N')
            $State.sessions[$token] = @{ license_key = $key; device_id = $device }
            $extra = @{
                session_token    = $token
                entitlement      = @{ product_id = $lic.product_id; profile_id = $lic.profile_id; expires_at = $lic.expires_at; features = $lic.features }
                release_material = @{ material = (_DeriveReleaseMaterial $key); note = 'MOCK-ONLY: real platform must issue run-required key/config here' }
            }
            return (_Resp -Code 200 -Reason 'ok' -Ok $true -Extra $extra)
        }
        { $_ -in @('validate','heartbeat') } {
            if (-not (_Has $Request 'session_token')) { return (_Resp -Code 400 -Reason 'invalid_request' -Ok $false) }
            $token = $Request['session_token']
            if (-not $State.sessions.ContainsKey($token)) { return (_Resp -Code 401 -Reason 'session_invalid' -Ok $false) }
            $sess = $State.sessions[$token]
            $lic = $State.licenses[$sess.license_key]
            if ($lic.status -eq 'revoked') { return (_Resp -Code 403 -Reason 'license_revoked' -Ok $false) }
            if ((_Utc $lic.expires_at) -lt (_Utc $State.now_utc)) { return (_Resp -Code 403 -Reason 'license_expired' -Ok $false) }
            return (_Resp -Code 200 -Reason 'ok' -Ok $true -Extra @{ session_token = $token })
        }
        'deactivate' {
            if (-not (_Has $Request 'session_token')) { return (_Resp -Code 400 -Reason 'invalid_request' -Ok $false) }
            $token = $Request['session_token']
            if (-not $State.sessions.ContainsKey($token)) { return (_Resp -Code 401 -Reason 'session_invalid' -Ok $false) }
            $sess = $State.sessions[$token]
            $key = $sess.license_key
            $device = $sess.device_id
            $State.sessions.Remove($token) | Out-Null
            if ($State.bound_devices.ContainsKey($key)) {
                $State.bound_devices[$key] = @($State.bound_devices[$key] | Where-Object { $_ -ne $device })
            }
            return (_Resp -Code 200 -Reason 'ok' -Ok $true)
        }
    }
}
