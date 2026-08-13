#requires -Version 5

# suggest-tool-acquisition -- turn a missing capability into a message a human can act on. Print only.
#
# The user's rule for this chain is: need a capability -> search this machine first (whole disk, the tool
# may live on another drive) -> if it is there, just use it -> if it is not, TELL THE USER what is missing
# and what the command looks like -> they approve, then it gets installed. There is deliberately NO
# unattended-install tier, so this script never installs, downloads, or launches anything: it reads the
# tool inventory, asks the read-only resolve-capability bridge, and writes a suggestion to stdout. Nothing
# on disk is modified.
#
# Two failure modes it exists to prevent, both observed in practice:
#
#   1. Filling the slot with a made-up tool name. Every candidate below was pinned by running
#      `winget search` on a real machine; a role with nothing verified behind it returns no_candidate and
#      says so in plain words. Coming back empty-handed is a correct answer here -- when "I found nothing"
#      is not an available outcome, the next best thing a model produces is an invented package id.
#   2. Confusing "I did not find it" with "it does not exist". Two separate guards: the search-coverage
#      gate below refuses to claim anything is missing unless the snapshot actually covered every disk,
#      and upstream='frozen' marks a tool whose ceiling is inherent to its last release -- "go install a
#      newer version" can never clear it, so the user must not be sent to do that.
#
#   powershell -File suggest-tool-acquisition.ps1 -CapabilityId decompile.dotnet -ProductRoot <p>
#   powershell -File suggest-tool-acquisition.ps1 -CapabilityId unpack.pe.upx -ProductRoot <p> -FailedTool "upx.exe,7z.exe"
#
# NOT WIRED YET. gap-classify.ps1 is where this belongs -- its capability_gap branch already ends in the
# placeholder "待带外放行安装（后续 acquire 阶段）" -- but that file has another owner right now, so the
# hook-up is left to them. The low-risk shape is one extra footer line rather than an inlined call: this
# script prints its own `RESULT:` and `capability_id=` lines, so splicing its output into gap-classify's
# footer would give that contract a second set of them for any parser that reads the last match. Emitting
#
#     suggest_command=powershell -File <dir>\suggest-tool-acquisition.ps1 -CapabilityId <id> -ProductRoot <root> -FailedTool "<tools_tried joined by commas>"
#
# next to blocking_item= keeps both output contracts intact, and keeps a failure in here from ever landing
# after gap-classify has already written its three archive files.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CapabilityId,
    [string]$ProductRoot,
    [string]$InventoryPath,

    # Tools already tried for this capability -- normally CAPABILITY-ATTEMPTS.json's tools_tried, joined
    # with commas. They are removed from the suggestions: telling someone to install what they already have
    # and watched fail is exactly the wasted round trip this script exists to avoid.
    #
    # One string rather than [string[]] on purpose. Every caller here invokes through `powershell -File`,
    # and that path does not bind array parameters at all: `-FailedTool a,b,c` arrives as the single string
    # "a,b,c" and `-FailedTool a b c` silently keeps only "a" (measured, both hosts). A typed array would
    # therefore have dropped tools the caller did pass, and re-suggested them.
    [string]$FailedTool = '',

    # Where Everything's CLI lives, when it is not on PATH or in a conventional spot. Used only to verify
    # that an index-backed snapshot could really have consulted the index (see the coverage gate).
    [string]$EverythingExePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

trap {
    Write-Output 'RESULT: suggester_error'
    Write-Output ("detail=" + $_.Exception.Message)
    exit 4
}

# --- what the capability means to a person -------------------------------------------------------------
# Keyed by the same capability ids resolve-capability's bridge table uses; the guard suite reconciles the
# two key sets in both directions. `what` is the capability in plain words and `blocked` is what stops
# being possible without it -- a user who is asked to approve an install is owed both, not an id.
$script:CapabilityPlainLanguage = @{
    'triage.pe'             = @{ what = '先看一眼这个 EXE 到底是什么东西'; blocked = '认不出目标的格式、编译语言和有没有加壳，后面每一步分析都只能靠猜' }
    'inspect.pe.structure'  = @{ what = '读 EXE 的节区、导入导出表和依赖'; blocked = '说不出它依赖哪些 DLL、带不带 .NET 运行时，改造范围无法界定' }
    'inspect.resources'     = @{ what = '看和改 EXE 里的图标、版本信息、内嵌文件'; blocked = '改不了图标、公司名、联系方式这类品牌定制' }
    'disassemble.pe.native' = @{ what = '把原生机器码翻成汇编来读逻辑'; blocked = '定位不到授权校验、启动流程这些关键函数' }
    'decompile.pe.native'   = @{ what = '把原生机器码还原成接近源码的形式'; blocked = '只能读汇编，读不出接近源码的逻辑，改造成本会高一大截' }
    'decompile.dotnet'      = @{ what = '把 .NET 程序集还原成 C# 源码'; blocked = '看不到托管代码的类型和入口，.NET 目标基本没法二次开发' }
    'deobfuscate.dotnet'    = @{ what = '还原被混淆过的 .NET 程序集'; blocked = '反编译出来全是乱码般的符号，读不出真实逻辑' }
    'unpack.pe.upx'         = @{ what = '解开 UPX 压缩壳'; blocked = '拿不到壳里的真实 PE，静态分析全部落空' }
    'unpack.pe.generic'     = @{ what = '解开安装包或压缩壳，取出里面的真实文件'; blocked = '拿不到安装包内部的程序文件，连该分析哪个 EXE 都定不下来' }
    'debug.dynamic'         = @{ what = '把目标跑起来单步调试'; blocked = '只能静态看，验证不了它运行时的实际行为' }
    'observe.system'        = @{ what = '观察它运行时读写了哪些文件、注册表和进程'; blocked = '说不清它把配置和授权信息存在哪里' }
    'instrument.runtime'    = @{ what = '在运行时挂钩子，看函数的真实参数和返回值'; blocked = '观察不到函数级的真实调用，只能从外部猜行为' }
    'observe.network'       = @{ what = '抓它的网络请求'; blocked = '看不到它跟哪个服务器通信、授权接口长什么样' }
    'diff.binary'           = @{ what = '比较上下游两个版本的二进制差异'; blocked = '说不出新版改了哪里，已有定制项没法安全搬到新版' }
    'build.dotnet'          = @{ what = '编译 .NET / C# 项目'; blocked = '代码改完编不出成品，只能停在读代码阶段' }
    'build.java'            = @{ what = '编译 Java / Kotlin 项目'; blocked = '代码改完编不出成品，只能停在读代码阶段' }
    'build.python'          = @{ what = '运行和打包 Python 项目'; blocked = '跑不起来也打不了包，改动无法验证' }
    'build.node'            = @{ what = '构建 Node / Electron 项目'; blocked = '装不了依赖也打不了包，改动无法验证' }
    'build.go'              = @{ what = '编译 Go 项目'; blocked = '代码改完编不出成品，只能停在读代码阶段' }
    'build.rust'            = @{ what = '编译 Rust 项目'; blocked = '代码改完编不出成品，只能停在读代码阶段' }
    'build.native'          = @{ what = '编译 C / C++ 项目'; blocked = '代码改完编不出成品，只能停在读代码阶段' }
    'build.delphi'          = @{ what = '编译 Delphi / C++Builder 项目'; blocked = '代码改完编不出成品，Delphi 目标通常只能外壳包裹' }
    'build.qt'              = @{ what = '构建 Qt 项目'; blocked = '代码改完编不出成品，Qt 目标通常只能外壳包裹' }
    'build.scripting'       = @{ what = '编译 AutoHotkey / AutoIt / Flutter 这类脚本或跨端项目'; blocked = '改完脚本产不出可分发的成品' }
}

# --- how to acquire a tool for a role ------------------------------------------------------------------
# Keyed by discover-tools' catalog role ids. Every entry was pinned by an actual `winget search` /
# `winget show` on a real machine on 2026-08-13 -- nothing here is recalled or inferred, and a role with no
# verified route simply has no entry (which becomes an honest no_candidate rather than a plausible-looking
# package id). `exe` is the filename discover-tools looks for, and the guard suite asserts it is in that
# role's names list: suggesting a tool that rediscovery would not detect sends the user on a wasted trip.
#
# upstream='frozen' means the project has shipped nothing for years, so its capability ceiling belongs to
# that release. It may still be worth installing if never tried, but "install a newer one" is not a thing
# that exists, and a user who already hit its ceiling must be told to stop rather than to go install.
$script:RoleAcquisition = @{
    'pe-triage'               = @(
        @{ tool = 'Detect It Easy'; exe = 'die.exe'; via = 'winget'; id = 'horsicq.DIE-engine'; version = '3.21'; upstream = 'active' },
        @{ tool = 'Sysinternals Strings'; exe = 'strings.exe'; via = 'winget'; id = 'Microsoft.Sysinternals.Strings'; version = '2.54'; upstream = 'active' },
        @{ tool = '7-Zip'; exe = '7z.exe'; via = 'winget'; id = '7zip.7zip'; version = '26.02'; upstream = 'active' }
    )
    'pe-structure'            = @(
        @{ tool = 'Sysinternals Sigcheck'; exe = 'sigcheck.exe'; via = 'winget'; id = 'Microsoft.Sysinternals.Sigcheck'; version = '2.91'; upstream = 'active' },
        @{ tool = 'LLVM'; exe = 'llvm-readobj.exe'; via = 'winget'; id = 'LLVM.LLVM'; version = '22.1.8'; upstream = 'active' }
    )
    'resource-edit'           = @(
        @{ tool = 'Resource Hacker'; exe = 'ResourceHacker.exe'; via = 'winget'; id = 'AngusJohnson.ResourceHacker'; version = '5.2.8'; upstream = 'active' },
        @{ tool = '7-Zip'; exe = '7z.exe'; via = 'winget'; id = '7zip.7zip'; version = '26.02'; upstream = 'active' }
    )
    'native-static'           = @(
        @{ tool = 'Rizin'; exe = 'rizin.exe'; via = 'winget'; id = 'Rizin.Rizin'; version = '0.8.2'; upstream = 'active' },
        @{ tool = 'Cutter'; exe = 'cutter.exe'; via = 'winget'; id = 'Rizin.Cutter'; version = '2.5.0'; upstream = 'active' },
        @{ tool = 'Ghidra'; exe = 'ghidraRun.bat'; via = 'download'; url = 'https://ghidra-sre.org/'; upstream = 'active'; note = 'winget 源里没有 Ghidra（已实测搜不到），只能去官网下发行版 zip 解压；解压目录记得写进 tool-roots.txt，否则下次发现还是找不到' }
    )
    'dotnet-static'           = @(
        @{ tool = 'dnSpyEx'; exe = 'dnSpy.exe'; via = 'winget'; id = 'dnSpyEx.dnSpy'; version = '6.6.0'; upstream = 'active' },
        @{ tool = 'ILSpy'; exe = 'ILSpy.exe'; via = 'winget'; id = 'icsharpcode.ILSpy'; version = '10.1.1.8388'; upstream = 'active' }
    )
    'debugger'                = @(
        @{ tool = 'x64dbg'; exe = 'x64dbg.exe'; via = 'winget'; id = 'x64dbg.x64dbg'; version = '2026.05.27'; upstream = 'active' }
    )
    'system-observe'          = @(
        @{ tool = 'Process Monitor'; exe = 'Procmon.exe'; via = 'winget'; id = 'Microsoft.Sysinternals.ProcessMonitor'; version = '4.04'; upstream = 'active' },
        @{ tool = 'Process Explorer'; exe = 'procexp.exe'; via = 'winget'; id = 'Microsoft.Sysinternals.ProcessExplorer'; version = '17.12'; upstream = 'active' }
    )
    'network-observe'         = @(
        @{ tool = 'Wireshark'; exe = 'Wireshark.exe'; via = 'winget'; id = 'WiresharkFoundation.Wireshark'; version = '4.6.8'; upstream = 'active'; note = '装完同时带上命令行版 tshark.exe' }
    )
    'runtime-instrumentation' = @(
        @{ tool = 'Frida'; exe = 'frida.exe'; via = 'download'; url = 'https://frida.re/docs/installation/'; upstream = 'active'; note = 'winget 源里没有 frida（已实测搜不到，只搜出同名噪声），官方装法是 Python 包 frida-tools —— 那属于装依赖，同样要你点头' }
    )
    'package-inspect'         = @(
        @{ tool = 'UPX'; exe = 'upx.exe'; via = 'winget'; id = 'UPX.UPX'; version = '5.2.0'; upstream = 'active' },
        @{ tool = '7-Zip'; exe = '7z.exe'; via = 'winget'; id = '7zip.7zip'; version = '26.02'; upstream = 'active' },
        @{ tool = 'innoextract'; exe = 'innoextract.exe'; via = 'winget'; id = 'dscharrer.innoextract'; version = '1.9'; upstream = 'frozen'; frozen_note = '上游 2020 年发布 1.9 之后再没有新版本。它能解的 Inno Setup setup data 版本上限是这一版固有的，装新版或升级都提不了这个上限（gap-classify 规则 5b 记的就是这条）。' }
    )
    'language-dotnet'         = @(
        @{ tool = '.NET SDK 8 (LTS)'; exe = 'dotnet.exe'; via = 'winget'; id = 'Microsoft.DotNet.SDK.8'; version = '8.0.424'; upstream = 'active' }
    )
    'language-java'           = @(
        @{ tool = 'Eclipse Temurin JDK 21'; exe = 'javac.exe'; via = 'winget'; id = 'EclipseAdoptium.Temurin.21.JDK'; version = '21.0.12.8'; upstream = 'active' }
    )
    'language-python'         = @(
        @{ tool = 'Python 3.13'; exe = 'python.exe'; via = 'winget'; id = 'Python.Python.3.13'; version = '3.13.15'; upstream = 'active' }
    )
    'language-node'           = @(
        @{ tool = 'Node.js'; exe = 'node.exe'; via = 'winget'; id = 'OpenJS.NodeJS'; version = '26.7.0'; upstream = 'active' }
    )
    'language-go'             = @(
        @{ tool = 'Go'; exe = 'go.exe'; via = 'winget'; id = 'GoLang.Go'; version = '1.26.5'; upstream = 'active' }
    )
    'language-rust'           = @(
        @{ tool = 'Rustup'; exe = 'cargo.exe'; via = 'winget'; id = 'Rustlang.Rustup'; version = '1.29.0'; upstream = 'active'; note = '装的是工具链安装器，它会把 cargo.exe / rustc.exe 放到 %USERPROFILE%\.cargo\bin —— 那个目录发现脚本会扫' }
    )
    'language-native'         = @(
        @{ tool = 'LLVM'; exe = 'clang.exe'; via = 'winget'; id = 'LLVM.LLVM'; version = '22.1.8'; upstream = 'active'; note = '这是 clang 工具链。目标若必须用 MSVC 编，要装 Visual Studio Build Tools 并额外指定 VCTools 工作负载 —— 那条命令我没实测过，所以没写进来，需要时单独确认' }
    )
    'language-scripting'      = @(
        @{ tool = 'AutoHotkey'; exe = 'AutoHotkey.exe'; via = 'winget'; id = 'AutoHotkey.AutoHotkey'; version = '2.0.26'; upstream = 'active' }
    )
    'build'                   = @(
        @{ tool = '.NET SDK 8 (LTS)'; exe = 'dotnet.exe'; via = 'winget'; id = 'Microsoft.DotNet.SDK.8'; version = '8.0.424'; upstream = 'active' }
    )
}

function Get-ToolMatchKey {
    param([AllowEmptyString()][string]$Value)

    # A tool is named three ways across this skill: 'innoextract', 'innoextract.exe' and a full path from
    # the inventory. Fold all three to one key so -FailedTool matches whichever form the caller has.
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $leaf = [IO.Path]::GetFileName($Value.Trim())
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $Value.Trim() }
    return [IO.Path]::GetFileNameWithoutExtension($leaf).ToLowerInvariant()
}

function Get-EverythingCli {
    param([AllowEmptyString()][string]$Explicit)

    # A deliberate second copy of discover-tools' lookup: that script runs its real work at load and takes
    # mandatory parameters, so it cannot be dot-sourced to borrow the function. Merge the two when the
    # discovery helpers move into lib\.
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return $Explicit }
        return ''
    }
    $onPath = @(Get-Command 'es.exe' -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' -and -not [string]::IsNullOrWhiteSpace($_.Source) })
    if ($onPath.Count -gt 0) { return [string]$onPath[0].Source }
    foreach ($candidate in @(
            (Join-Path ([string]$env:ProgramFiles) 'Everything\es.exe'),
            (Join-Path ([string]${env:ProgramFiles(x86)}) 'Everything\es.exe'),
            (Join-Path ([string]$env:LOCALAPPDATA) 'Programs\Everything\es.exe'))) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return ''
}

function Get-FixedDriveLetter {
    $letters = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq 'Fixed' -and $drive.IsReady) { [void]$letters.Add($drive.Name.Substring(0, 2).ToUpperInvariant()) }
        }
    }
    catch { }
    return @($letters | Sort-Object -Unique)
}

function Write-Refusal {
    param([string]$Verdict, [string]$Reason, [string[]]$Body, [int]$Exit)

    Write-Output ("RESULT: " + $Verdict)
    foreach ($line in @($Body)) { Write-Output $line }
    Write-Output ("capability_id=" + $CapabilityId)
    Write-Output ("reason=" + $Reason)
    Write-Output 'installed=no'
    exit $Exit
}

# --- locate the inventory ------------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($InventoryPath)) {
    if (-not [string]::IsNullOrWhiteSpace($ProductRoot) -and (Test-Path -LiteralPath $ProductRoot -PathType Container)) {
        $ProductRoot = Resolve-CanonicalPath -Path (Resolve-Path -LiteralPath $ProductRoot).Path
        $InventoryPath = Join-Path $ProductRoot 'product-state\tooling\TOOL-INVENTORY.json'
    }
}
$discoverHint = "powershell -File `"$PSScriptRoot\discover-tools.ps1`" -ProductRoot `"$(if ([string]::IsNullOrWhiteSpace($ProductRoot)) { '<产品目录>' } else { $ProductRoot })`" -UseEverything"

if ([string]::IsNullOrWhiteSpace($InventoryPath) -or -not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
    # Never searched is not the same as searched and missing. Without a snapshot there is nothing to base a
    # "you are missing X" claim on, and asking the user to install on that basis is how they end up
    # installing what they already have.
    Write-Refusal -Verdict 'rejected_no_discovery' -Reason 'no_tool_inventory' -Exit 3 -Body @(
        '这台机器还没做过工具发现，我不能凭「没查过」说你缺什么。先跑一次发现：',
        ('  ' + $discoverHint),
        '跑完再问我一次，我才有资格说缺不缺。')
}
$inventory = Read-TextFileSafe -Path $InventoryPath | ConvertFrom-Json
$discoveryInputs = Get-PropertyValue $inventory 'discovery_inputs'

# --- ask the read-only bridge --------------------------------------------------------------------------
$resolveScript = Join-Path $PSScriptRoot 'resolve-capability.ps1'
if (-not (Test-Path -LiteralPath $resolveScript -PathType Leaf)) {
    Write-Refusal -Verdict 'unknown_capability' -Reason 'bridge_missing' -Exit 3 -Body @(
        "能力解析器不在位（$resolveScript），我说不出这个能力对应哪些工具，就不给你猜一个。")
}
$psHost = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
$resolveOut = @()
$resolveExit = -1
$prevEap = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $resolveOut = @(& $psHost -NoProfile -ExecutionPolicy Bypass -File $resolveScript -CapabilityId $CapabilityId -InventoryPath $InventoryPath 2>&1 | ForEach-Object { [string]$_ })
    $resolveExit = if (Test-Path -LiteralPath 'Variable:LASTEXITCODE') { $LASTEXITCODE } else { -1 }
}
finally { $ErrorActionPreference = $prevEap }
$resolveVerdict = ''
$vLine = @($resolveOut | Where-Object { $_ -match '^RESULT:\s*' } | Select-Object -First 1)
if ($vLine.Count -eq 1) { $resolveVerdict = ($vLine[0] -replace '^RESULT:\s*', '').Trim() }
$roles = @()
$rLine = @($resolveOut | Where-Object { $_ -match '^roles=' } | Select-Object -First 1)
if ($rLine.Count -eq 1) { $roles = @(($rLine[0] -replace '^roles=', '') -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }

if ($resolveExit -ne 0 -or $resolveVerdict -eq '' -or $resolveVerdict -eq 'resolver_error') {
    Write-Refusal -Verdict 'unknown_capability' -Reason 'bridge_unusable' -Exit 3 -Body @(
        "能力解析器没给出可用答案（exit=$resolveExit verdict=$(if ($resolveVerdict -eq '') { '(none)' } else { $resolveVerdict })）。解析器坏了不等于这台机器缺工具，我不在这种基础上要你装东西。")
}
if ($resolveVerdict -eq 'unknown_capability' -or -not $script:CapabilityPlainLanguage.ContainsKey($CapabilityId)) {
    $why = if ($resolveVerdict -eq 'unknown_capability') { 'not_in_bridge_table' } else { 'no_plain_language_entry' }
    Write-Refusal -Verdict 'unknown_capability' -Reason $why -Exit 3 -Body @(
        "能力 id「$CapabilityId」我说不出人话解释，也就说不清你缺的到底是什么。",
        '这是 id 写错或表漏登，不是这台机器缺工具 —— 先把 id 对上，我不给你编一个工具名充数。')
}
$plain = $script:CapabilityPlainLanguage[$CapabilityId]

if ($resolveVerdict -eq 'available') {
    $toolPath = ''
    $tLine = @($resolveOut | Where-Object { $_ -match '^tool_path=' } | Select-Object -First 1)
    if ($tLine.Count -eq 1) { $toolPath = ($tLine[0] -replace '^tool_path=', '') }
    Write-Output 'RESULT: already_available'
    Write-Output ("这台机器已经有能做「$($plain.what)」的工具了，不用装任何东西：" + $toolPath)
    Write-Output ("capability_id=" + $CapabilityId)
    Write-Output 'reason=inventory_says_available'
    Write-Output ("tool_path=" + $toolPath)
    Write-Output 'installed=no'
    exit 0
}

# --- search-coverage gate ------------------------------------------------------------------------------
# The user's standing worry is a tool sitting on a drive the search never visited. A snapshot that only
# walked the conventional folders cannot support "this machine does not have it", so it does not get to
# reach the suggestion below. Note the asymmetry with discovery_inputs.use_everything: that field records
# that the index was REQUESTED, not that es.exe answered (discover-tools falls back to the walk and only
# says so on stdout, which the JSON does not keep). So an index-backed snapshot is accepted only when the
# CLI is still resolvable here.
$deepScan = ConvertTo-BooleanValue (Get-PropertyValue $discoveryInputs 'deep_scan' $false)
$askedEverything = ConvertTo-BooleanValue (Get-PropertyValue $discoveryInputs 'use_everything' $false)
$rootsOnly = ConvertTo-BooleanValue (Get-PropertyValue $discoveryInputs 'search_roots_only' $false)
$everythingCli = ''
if ($askedEverything) { $everythingCli = Get-EverythingCli -Explicit $EverythingExePath }
$fixedDrives = @(Get-FixedDriveLetter)
$driveText = if ($fixedDrives.Count -gt 0) { $fixedDrives -join ' ' } else { '(读不到盘符列表)' }

$scopeKind = ''
$scopeText = ''
if ($rootsOnly) {
    Write-Refusal -Verdict 'rejected_search_incomplete' -Reason 'search_roots_only' -Exit 3 -Body @(
        '上一次发现只扫了指定的几个目录，没做全机搜索 —— 这种快照里的「没找到」只代表那几个目录里没有。',
        '你担心的正是这种情况（工具在别的盘），所以我不拿它当依据。先全盘重扫：',
        ('  ' + $discoverHint))
}
elseif ($deepScan) {
    $scopeKind = 'deep-scan'
    $depth = [string](Get-PropertyValue $discoveryInputs 'max_search_depth' '?')
    $scopeText = "整盘深度遍历（每个固定盘逐层走到底，目录深度上限 $depth）"
}
elseif ($askedEverything -and $everythingCli -ne '') {
    $scopeKind = 'everything-index'
    $scopeText = "Everything 全盘索引（es.exe：$everythingCli），按文件名直查整盘，不受默认目录限制"
}
elseif ($askedEverything) {
    Write-Refusal -Verdict 'rejected_search_incomplete' -Reason 'everything_unverifiable' -Exit 3 -Body @(
        '上一次发现声明要用 Everything 全盘索引，但我现在找不到 es.exe —— 那次很可能是静默退回了普通目录遍历。',
        '（快照里只记了「要用索引」，没记「索引真的答了」，所以这条不能信。）',
        '在确认全盘搜过之前我不会说你缺工具。请改用整盘深度扫描重跑一次：',
        ('  ' + $discoverHint + ' -DeepScan'))
}
else {
    Write-Refusal -Verdict 'rejected_search_incomplete' -Reason 'not_whole_disk' -Exit 3 -Body @(
        '上一次发现只走了常规目录，没有覆盖整盘 —— 工具很可能就在别的盘上，只是没被扫到。',
        '在全盘搜过之前我不会说你缺工具。先全盘重扫，二选一：',
        ('  ' + $discoverHint + '   ← 有 Everything 时最快'),
        ('  ' + $discoverHint + ' -DeepScan   ← 没有 Everything 时用这条，慢但彻底'))
}

$generatedAt = [string](Get-PropertyValue $inventory 'generated_at' '')
$ageText = '(时间戳读不出)'
$parsedStamp = [datetimeoffset]::MinValue
if ([datetimeoffset]::TryParse($generatedAt, [ref]$parsedStamp)) {
    $ageText = '{0}（距今 {1} 小时）' -f $parsedStamp.ToString('yyyy-MM-dd HH:mm'), [math]::Round(([datetimeoffset]::Now - $parsedStamp).TotalHours, 1)
}
$extraRoots = @(@(Get-PropertyValue $discoveryInputs 'additional_search_roots' @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

# --- pick candidates ------------------------------------------------------------------------------------
$failedTools = @(($FailedTool -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$failedKeys = @($failedTools | ForEach-Object { Get-ToolMatchKey -Value $_ } | Where-Object { $_ -ne '' })
$candidates = New-Object System.Collections.Generic.List[object]
$excluded = New-Object System.Collections.Generic.List[object]
$rolesWithNoRoute = New-Object System.Collections.Generic.List[string]
foreach ($role in $roles) {
    if (-not $script:RoleAcquisition.ContainsKey($role)) { [void]$rolesWithNoRoute.Add($role); continue }
    foreach ($entry in @($script:RoleAcquisition[$role])) {
        $row = [pscustomobject]@{
            Role       = $role
            Tool       = [string]$entry['tool']
            Exe        = [string]$entry['exe']
            Via        = [string]$entry['via']
            Id         = $(if ($entry.ContainsKey('id')) { [string]$entry['id'] } else { '' })
            Version    = $(if ($entry.ContainsKey('version')) { [string]$entry['version'] } else { '' })
            Url        = $(if ($entry.ContainsKey('url')) { [string]$entry['url'] } else { '' })
            Upstream   = [string]$entry['upstream']
            Note       = $(if ($entry.ContainsKey('note')) { [string]$entry['note'] } else { '' })
            FrozenNote = $(if ($entry.ContainsKey('frozen_note')) { [string]$entry['frozen_note'] } else { '' })
        }
        if ($failedKeys -contains (Get-ToolMatchKey -Value $row.Exe) -or $failedKeys -contains (Get-ToolMatchKey -Value $row.Tool)) { [void]$excluded.Add($row); continue }
        if (@($candidates | Where-Object { $_.Tool -eq $row.Tool }).Count -gt 0) { continue }
        [void]$candidates.Add($row)
    }
}
$frozenAlreadyTried = @($excluded | Where-Object { $_.Upstream -eq 'frozen' })

# --- assemble the message --------------------------------------------------------------------------------
$searchedLines = New-Object System.Collections.Generic.List[string]
[void]$searchedLines.Add("- 快照: $InventoryPath")
[void]$searchedLines.Add("- 扫描时间: $ageText")
[void]$searchedLines.Add("- 搜索方式: $scopeText")
[void]$searchedLines.Add("- 覆盖磁盘: 本机固定盘 $driveText 全部在内（不是只搜 C 盘）")
if ($extraRoots.Count -gt 0) { [void]$searchedLines.Add("- 额外指定目录: " + ($extraRoots -join '; ')) }
[void]$searchedLines.Add("- 该能力对应的工具角色 " + ($roles -join ' / ') + " 在快照里全部是 available=no")
if ($failedTools.Count -gt 0) { [void]$searchedLines.Add("- 你已经试过并失败的: " + ($failedTools -join '、') + "（不会再让你装一遍）") }

$verdict = ''
$reason = ''
$whatLines = New-Object System.Collections.Generic.List[string]
$howLines = New-Object System.Collections.Generic.List[string]
$afterLines = New-Object System.Collections.Generic.List[string]
$primaryTool = ''
$primaryCommand = ''

[void]$whatLines.Add("缺的能力: 「$($plain.what)」（id: $CapabilityId）")
[void]$whatLines.Add("缺了它做不了: $($plain.blocked)")

if ($candidates.Count -eq 0 -and $frozenAlreadyTried.Count -gt 0) {
    # The ceiling case. The failing tool is the last thing its upstream ever shipped, so there is no newer
    # version to go get -- reporting this as "install something newer" is what makes a user run the same
    # errand repeatedly and come back to the same wall.
    $verdict = 'not_acquirable'
    $reason = 'upstream_frozen_ceiling'
    foreach ($f in $frozenAlreadyTried) {
        [void]$howLines.Add("没有命令可给 —— $($f.Tool) 装新版是不存在的事：")
        [void]$howLines.Add("  $($f.FrozenNote)")
    }
    [void]$howLines.Add('这不是「我没找到工具」，是「更强的版本不存在」。再找工具、再装一次都不会改变结果。')
    [void]$afterLines.Add('不需要你点头装任何东西。这条能力应该按死路处理：换外壳包裹 / 换别的分析路径，或者如实记成无法复现。')
    [void]$afterLines.Add('如果你手上有别的能开这种格式的工具，把它的目录逐行写进 tool-roots.txt，我下次发现就能扫到它。')
}
elseif ($candidates.Count -eq 0) {
    # Empty-handed on purpose. When "found nothing" is not an allowed outcome, the next thing a model
    # produces is a confident, invented package id -- which costs the user a real wasted errand.
    $verdict = 'no_candidate'
    $reason = if ($excluded.Count -gt 0) { 'all_candidates_already_tried' } else { 'no_verified_route' }
    [void]$howLines.Add("我需要一个能做「$($plain.what)」的工具，我没找到候选。")
    if ($excluded.Count -gt 0) {
        [void]$howLines.Add("你已经试过 " + (@($excluded | ForEach-Object { $_.Tool }) -join '、') + "，除此之外我这边没有第二个经过核实的选项。")
    }
    if ($rolesWithNoRoute.Count -gt 0) {
        [void]$howLines.Add("工具角色 " + ($rolesWithNoRoute -join ' / ') + " 在我这张表里没有任何实测过的获取途径。")
    }
    [void]$howLines.Add('我不会随口给一个工具名让你去装 —— 名字给错了，你白跑一趟，而且后面每一步都会建立在一个不存在的前提上。')
    [void]$afterLines.Add('可以做的三件事，都不需要我先装东西：')
    [void]$afterLines.Add('  1) 你要是知道该用什么工具，告诉我名字，我去核实它的获取方式；')
    [void]$afterLines.Add('  2) 你机器上要是已经装过、只是放在冷门目录，把目录逐行写进 tool-roots.txt，我重扫就能认出来；')
    [void]$afterLines.Add('  3) 都没有的话，这条能力按缺口挂着，走不依赖它的分析路径。')
}
else {
    $primary = $candidates[0]
    $primaryTool = $primary.Tool
    $verdict = if ($primary.Via -eq 'winget') { 'suggest_install' } else { 'suggest_manual_download' }
    if (@($candidates | Where-Object { $_.Via -eq 'winget' }).Count -eq 0) { $verdict = 'suggest_manual_download' }
    $reason = 'verified_route_available'
    if ($frozenAlreadyTried.Count -gt 0) {
        foreach ($f in $frozenAlreadyTried) {
            [void]$howLines.Add("先说清楚一件事: 你失败在 $($f.Tool) 上，而它装新版是不存在的事 —— $($f.FrozenNote)")
        }
        [void]$howLines.Add('所以下面这些是**别的**工具，不是它的新版本。')
        [void]$howLines.Add('')
    }
    $index = 0
    foreach ($c in $candidates) {
        $index++
        $label = if ($index -eq 1) { '首选' } else { "备选 $index" }
        if ($c.Via -eq 'winget') {
            $command = "winget install --exact --id $($c.Id) --version $($c.Version) --source winget --accept-package-agreements --accept-source-agreements"
            [void]$howLines.Add("$label $($c.Tool)（角色 $($c.Role)，装完落地为 $($c.Exe)）:")
            [void]$howLines.Add("  $command")
            [void]$howLines.Add("  这个版本号是我在本机实测过的；万一它已经下架，去掉 --version 那一段就是装最新版。")
            if ($index -eq 1) { $primaryCommand = $command }
        }
        else {
            [void]$howLines.Add("$label $($c.Tool)（角色 $($c.Role)，装完落地为 $($c.Exe)）: winget 源里没有它，要手动下")
            [void]$howLines.Add("  官方下载页: $($c.Url)")
            if ($index -eq 1) { $primaryCommand = $c.Url }
        }
        if ($c.Upstream -eq 'frozen') { [void]$howLines.Add("  注意: $($c.FrozenNote)") }
        if ($c.Note -ne '') { [void]$howLines.Add("  说明: $($c.Note)") }
    }
    [void]$afterLines.Add('你点头（或自己跑完上面的命令）之后，剩下的我来做，你不用再动手：')
    [void]$afterLines.Add(('  1) 重新发现: ' + $discoverHint + '   ← 不带 -ReuseInventory，强制重扫'))
    [void]$afterLines.Add("  2) 确认真的能用: 用 resolve-capability 核对 $CapabilityId 变成 available，并把工具的实际路径贴给你看；")
    [void]$afterLines.Add("  3) 回到卡住的那一步: 继续「$($plain.what)」，重跑之前失败的那条命令。")
    [void]$afterLines.Add('  4) 万一装完仍然认不出来: 我不会再要你装第二次 —— 那说明是发现或选型的问题，按死路重新分类。')
}

Write-Output ("RESULT: " + $verdict)
Write-Output ''
Write-Output '【1/4 缺什么】'
foreach ($line in $whatLines) { Write-Output ('  ' + $line) }
Write-Output ''
Write-Output '【2/4 我已经找过哪些地方】'
foreach ($line in $searchedLines) { Write-Output ('  ' + $line) }
Write-Output ''
Write-Output '【3/4 具体怎么拿到它】'
foreach ($line in $howLines) { Write-Output ('  ' + $line) }
Write-Output ''
Write-Output '【4/4 你点头之后会发生什么】'
foreach ($line in $afterLines) { Write-Output ('  ' + $line) }
Write-Output ''
Write-Output ("capability_id=" + $CapabilityId)
Write-Output ("reason=" + $reason)
Write-Output ("roles=" + ($roles -join ','))
Write-Output ("search_scope=" + $scopeKind)
Write-Output ("candidates=" + $candidates.Count)
Write-Output ("primary_tool=" + $primaryTool)
Write-Output ("primary_command=" + $primaryCommand)
Write-Output ("inventory=" + $InventoryPath)
# Said on every path, including the ones that print a command: this script prints and exits. The install
# itself is the user's call and nothing here performs it.
Write-Output 'installed=no'
exit 0
