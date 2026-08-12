#requires -Version 5

# Local temporary authorization server -- MOCK ONLY (acceptance tier 1).
#
# Serves the authorization.v1 client contract on localhost so a rebuilt product
# can actually run under an authorization handshake before the universal
# platform is finished. The Launcher talks to this exactly as it will talk to the
# real platform; at cutover only base_url changes.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/mock-authorization-server.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/mock-authorization-server.ps1 -Port 9001
#
# Never package this with a product release, and never treat a green run here as
# real authorization verification: it proves the wiring, not the platform.

[CmdletBinding()]
param(
    [int]$Port = 8787,
    [string]$BindAddress = '127.0.0.1',
    [switch]$AllowNonLoopback,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# RV-R4 L1: this is an UNAUTHENTICATED mock that hands a session token and release material to anyone
# who asks. Bound to loopback that is a local test convenience; bound to 0.0.0.0 it is an open endpoint
# on the network. Refuse a non-loopback bind unless the caller explicitly opts in and owns the risk.
if ($BindAddress -notin @('127.0.0.1', 'localhost', '::1') -and -not $AllowNonLoopback) {
    Write-Output "错误: -BindAddress $BindAddress 不是回环地址。这是一个无鉴权的 MOCK 授权服务器，绑到非回环地址会把它暴露到网络。"
    Write-Output '怎么办: 用默认的 127.0.0.1；确有必要暴露时显式加 -AllowNonLoopback 并自负其责（切勿用于生产或打包）。'
    exit 1
}

. (Join-Path $PSScriptRoot 'lib\mock-auth-core.ps1')

function ConvertTo-HashtableDeep {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) { $result[[string]$key] = ConvertTo-HashtableDeep $InputObject[$key] }
        return $result
    }
    if ($InputObject -is [array]) {
        return @($InputObject | ForEach-Object { ConvertTo-HashtableDeep $_ })
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) { $result[$property.Name] = ConvertTo-HashtableDeep $property.Value }
        return $result
    }
    return $InputObject
}

$state = New-MockAuthState -NowUtc ([System.DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
$prefix = "http://${BindAddress}:${Port}/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Output "ERROR: cannot listen on $prefix"
    Write-Output $_.Exception.Message
    Write-Output 'HINT: pick another port with -Port, or check that nothing else owns this address.'
    exit 1
}

Write-Output 'RESULT: mock_authorization_server_started'
Write-Output "base_url=http://${BindAddress}:${Port}"
Write-Output 'protocol=authorization.v1  operations=activate|validate|heartbeat|deactivate'
Write-Output 'demo licenses:'
Write-Output '  DEMO-VALID-0001    -> ok (binds 1 device, returns session + release_material)'
Write-Output '  DEMO-EXPIRED-0002  -> license_expired'
Write-Output '  DEMO-REVOKED-0003  -> license_revoked'
Write-Output '  DEMO-DEVLIMIT-0004 -> device_limit_reached on the 2nd device'
Write-Output 'MOCK ONLY -- never ship this with a release. Ctrl+C to stop.'

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $statusCode = 404
        $payload = @{ protocol_version = 'authorization.v1'; reason_code = 'not_found'; ok = $false }
        try {
            $path = $request.Url.AbsolutePath.TrimEnd('/')
            if ($request.HttpMethod -eq 'POST' -and $path -match '^/v1/client/(activate|validate|heartbeat|deactivate)$') {
                $operation = $Matches[1]
                $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $parsed = $null
                try { $parsed = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json) } catch { $parsed = $null }
                if ($null -eq $parsed) {
                    $statusCode = 400
                    $payload = @{ protocol_version = 'authorization.v1'; reason_code = 'invalid_request'; ok = $false }
                } else {
                    $result = Invoke-MockAuthorization -Operation $operation -Request $parsed -State $state
                    $statusCode = $result.status_code
                    $payload = $result.body
                }
                if (-not $Quiet) { Write-Output ("{0} {1} -> {2} {3}" -f (Get-Date -Format 'HH:mm:ss'), $operation, $statusCode, $payload['reason_code']) }
            }
        } catch {
            $statusCode = 500
            $payload = @{ protocol_version = 'authorization.v1'; reason_code = 'mock_internal_error'; ok = $false }
            if (-not $Quiet) { Write-Output ("ERROR: {0}" -f $_.Exception.Message) }
        }
        $json = $payload | ConvertTo-Json -Depth 6 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.StatusCode = $statusCode
        $response.ContentType = 'application/json; charset=utf-8'
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $response.Close()
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}