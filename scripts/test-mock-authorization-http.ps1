#requires -Version 5

# End-to-end regression for the local temporary authorization mock SERVER
# (acceptance tier 1, transport layer).
#
# test-mock-authorization.ps1 only exercises the in-memory contract core; it
# never loads mock-authorization-server.ps1. That gap is why a truncated server
# file once scored 22/22 while being unable to parse at all. This suite starts
# the real listener and asserts over real HTTP that every failure mode arrives
# as a distinct status code plus a stable reason_code in a NON-EMPTY body.
# A bare yes/no, an empty error body, a swallowed reason code, or a server that
# cannot start must go red here.
#
# Not covered on purpose: whether a non-elevated user can bind the listener.
# Both this machine and hosted Windows runners are elevated, so that remains
# UNVERIFIED rather than something this suite may claim.

[CmdletBinding()]
param([int]$Port = 0)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 6) { Add-Type -AssemblyName System.Net.Http }

$script:PassCount = 0
$script:FailCount = 0

function Assert-Value {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) {
        $script:PassCount++
        Write-Output ("PASS   {0,-40} expected[{1}] actual[{2}]" -f $Name, $Expected, $Actual)
    } else {
        $script:FailCount++
        Write-Output ("FAIL   {0,-40} expected[{1}] actual[{2}]" -f $Name, $Expected, $Actual)
    }
}

function Get-FreePort {
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    try { return $probe.LocalEndpoint.Port } finally { $probe.Stop() }
}

if ($Port -le 0) { $Port = Get-FreePort }
$serverScript = Join-Path $PSScriptRoot 'mock-authorization-server.ps1'
if (-not (Test-Path -LiteralPath $serverScript -PathType Leaf)) {
    Write-Output "FAIL   server script missing: $serverScript"
    Write-Output 'RESULT: 0 passed, 1 failed'
    exit 1
}

$psExe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
$stdout = Join-Path ([System.IO.Path]::GetTempPath()) ("mock-auth-http-{0}.out" -f [guid]::NewGuid().ToString('N'))
$base = "http://127.0.0.1:$Port/v1/client"
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(10)
$proc = $null

function Invoke-MockPost {
    param([string]$Path, $Body)
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Compress }
    $content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, 'application/json')
    $response = $client.PostAsync("$base/$Path", $content).GetAwaiter().GetResult()
    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $parsed = $null
    if ($text) { try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $null } }
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Text = $text; Json = $parsed }
}

# A swallowed or unparsable body must read as a plain failed expectation, not as
# a PowerShell stack trace: the failure mode this suite exists to catch is
# exactly "the error body went missing", so it has to stay legible when it hits.
function Get-Field {
    param($Response, [string]$Path)
    if ($null -eq $Response.Json) { return '(unparsable-body)' }
    $current = $Response.Json
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return '(missing)' }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return '(missing)' }
        $current = $property.Value
    }
    if ($null -eq $current) { return '(missing)' }
    return "$current"
}

function Test-Present {
    param([string]$Value)
    if ($Value -and -not $Value.StartsWith('(')) { return 'yes' }
    return 'no'
}

function New-Request {
    param([hashtable]$Extra)
    $request = @{
        protocol_version = 'authorization.v1'
        request_id       = [guid]::NewGuid().ToString('N')
        product_id       = 'DEMO-PRODUCT'
        profile_id       = 'default'
        client_id        = 'mock-launcher'
        device_id        = 'device-A'
    }
    if ($Extra) { foreach ($key in $Extra.Keys) { $request[$key] = $Extra[$key] } }
    return $request
}

try {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$serverScript`"", '-Port', "$Port", '-Quiet')
    $proc = Start-Process -FilePath $psExe -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout

    $started = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        if ($proc.HasExited) { break }
        try { $null = Invoke-MockPost -Path 'validate' -Body '{}'; $started = $true; break } catch { }
    }

    Assert-Value 'H1-server-listens' 'yes' $(if ($started) { 'yes' } else { 'no' })
    if (-not $started) {
        $reason = if (Test-Path -LiteralPath $stdout) { (Get-Content -Raw -Encoding UTF8 -LiteralPath $stdout) } else { '(no output captured)' }
        Write-Output '--- server output ---'
        Write-Output $reason
        Write-Output ''
        Write-Output ("RESULT: {0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
        exit 1
    }

    # Happy path must carry a session AND run-required material, not a bare ok.
    $valid = Invoke-MockPost -Path 'activate' -Body (New-Request @{ license_key = 'DEMO-VALID-0001' })
    $token = Get-Field $valid 'session_token'
    Assert-Value 'H2-valid-status' '200' "$($valid.Status)"
    Assert-Value 'H2-valid-reason' 'ok' (Get-Field $valid 'reason_code')
    Assert-Value 'H2-session-over-http' 'yes' (Test-Present $token)
    Assert-Value 'H2-material-over-http' 'yes' (Test-Present (Get-Field $valid 'release_material.material'))
    Assert-Value 'H2-entitlement-over-http' 'DEMO-PRODUCT' (Get-Field $valid 'entitlement.product_id')

    # Each failure mode must survive serialization as a distinct code, and the
    # body must never be empty -- an empty error body is how a client loses the
    # ability to tell "expired" from "revoked" and falls back to a yes/no.
    $cases = @(
        @{ Name = 'H3-unknown-key';   Path = 'activate'; Body = (New-Request @{ license_key = 'NOPE-9999' });          Status = '404'; Reason = 'license_not_found' },
        @{ Name = 'H4-expired-key';   Path = 'activate'; Body = (New-Request @{ license_key = 'DEMO-EXPIRED-0002' });  Status = '403'; Reason = 'license_expired' },
        @{ Name = 'H5-revoked-key';   Path = 'activate'; Body = (New-Request @{ license_key = 'DEMO-REVOKED-0003' });  Status = '403'; Reason = 'license_revoked' },
        @{ Name = 'H6-cross-product'; Path = 'activate'; Body = (New-Request @{ license_key = 'DEMO-VALID-0001'; product_id = 'OTHER-PRODUCT' }); Status = '409'; Reason = 'product_mismatch' },
        @{ Name = 'H7-bad-session';   Path = 'validate'; Body = (New-Request @{ session_token = 'not-a-real-token' }); Status = '401'; Reason = 'session_invalid' },
        @{ Name = 'H8-bad-protocol';  Path = 'activate'; Body = (New-Request @{ license_key = 'DEMO-VALID-0001'; protocol_version = 'authorization.v0' }); Status = '400'; Reason = 'unsupported_protocol_version' }
    )
    foreach ($case in $cases) {
        $result = Invoke-MockPost -Path $case.Path -Body $case.Body
        Assert-Value "$($case.Name)-status" $case.Status "$($result.Status)"
        Assert-Value "$($case.Name)-reason" $case.Reason (Get-Field $result 'reason_code')
        Assert-Value "$($case.Name)-body-not-empty" 'yes' $(if ($result.Text -and $result.Text.Trim().Length -gt 0) { 'yes' } else { 'no' })
    }

    # Transport-only branches: the in-memory suite cannot reach either of these.
    $malformed = Invoke-MockPost -Path 'activate' -Body 'this is not json'
    Assert-Value 'H9-malformed-json-status' '400' "$($malformed.Status)"
    Assert-Value 'H9-malformed-json-reason' 'invalid_request' (Get-Field $malformed 'reason_code')

    $unknownRoute = Invoke-MockPost -Path 'bogus-operation' -Body (New-Request @{ license_key = 'DEMO-VALID-0001' })
    Assert-Value 'H10-unknown-route-status' '404' "$($unknownRoute.Status)"
    Assert-Value 'H10-unknown-route-reason' 'not_found' (Get-Field $unknownRoute 'reason_code')

    # Device binding and session lifecycle must hold across separate requests,
    # i.e. the server keeps one state instead of rebuilding it per call.
    $deviceA = Invoke-MockPost -Path 'activate' -Body (New-Request @{ license_key = 'DEMO-DEVLIMIT-0004'; device_id = 'device-A' })
    Assert-Value 'H11-first-device-ok' 'ok' (Get-Field $deviceA 'reason_code')
    $deviceB = Invoke-MockPost -Path 'activate' -Body (New-Request @{ license_key = 'DEMO-DEVLIMIT-0004'; device_id = 'device-B' })
    Assert-Value 'H11-second-device-refused' 'device_limit_reached' (Get-Field $deviceB 'reason_code')

    $heartbeat = Invoke-MockPost -Path 'heartbeat' -Body (New-Request @{ session_token = $token })
    Assert-Value 'H12-heartbeat-ok' 'ok' (Get-Field $heartbeat 'reason_code')
    $deactivate = Invoke-MockPost -Path 'deactivate' -Body (New-Request @{ session_token = $token })
    Assert-Value 'H13-deactivate-ok' 'ok' (Get-Field $deactivate 'reason_code')
    $afterKill = Invoke-MockPost -Path 'validate' -Body (New-Request @{ session_token = $token })
    Assert-Value 'H13-session-dead-after-deactivate' 'session_invalid' (Get-Field $afterKill 'reason_code')
}
finally {
    $client.Dispose()
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $stdout -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
