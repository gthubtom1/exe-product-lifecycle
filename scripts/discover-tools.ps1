#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,

    [string]$HostToolIndexPath,

    [string[]]$AdditionalSearchRoot,

    [ValidateRange(1, 16)]
    [int]$MaxSearchDepth = 10,

    # Every fixed drive, walked to -DeepScanDepth. Minutes rather than seconds, so it is opt-in:
    # use it before telling the user a tool is missing, not on every run.
    [switch]$DeepScan,

    [ValidateRange(1, 24)]
    [int]$DeepScanDepth = 12,

    # Plain-text files, one directory per line. They live outside the skill folder on purpose, so
    # that syncing or reinstalling the skill cannot wipe the user's own tool locations.
    [string[]]$ExtraRootFile,

    [switch]$ReuseInventory,

    [ValidateRange(1, 8760)]
    [int]$MaxInventoryAgeHours = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Write-InventoryFile below is a thin alias over the shared atomic writer. Keeping a second copy
# of the swap logic here is how the rest of this skill ended up with three YAML parsers.
. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')

$root = (Resolve-Path -LiteralPath $ProductRoot).Path
$stateRoot = Join-Path $root 'product-state'
$toolingRoot = Join-Path $stateRoot 'tooling'
New-Item -ItemType Directory -Force -Path $toolingRoot | Out-Null

$inventoryPath = Join-Path $toolingRoot 'TOOL-INVENTORY.md'
$jsonPath = Join-Path $toolingRoot 'TOOL-INVENTORY.json'

$catalog = @(
    [pscustomobject]@{ id = 'file-hash'; category = '完整性'; names = @('Get-FileHash'); notes = '保存输入和发布物 SHA-256' },
    [pscustomobject]@{ id = 'pe-triage'; category = 'PE 初筛'; names = @('die.exe', 'diec.exe', 'diec', 'Detect-It-Easy.exe', 'exeinfope.exe', 'ExeinfoPe.exe', 'peid.exe', 'strings.exe', 'strings', 'strings64.exe', '7z.exe', '7z', '7zz.exe', 'bz.exe', 'tar.exe', 'tar'); notes = '识别格式、字符串、压缩和资源' },
    [pscustomobject]@{ id = 'pe-structure'; category = 'PE 结构'; names = @('dumpbin.exe', 'dumpbin', 'editbin.exe', 'llvm-readobj.exe', 'llvm-readobj', 'llvm-objdump.exe', 'llvm-objdump', 'objdump.exe', 'objdump', 'rabin2.exe', 'rabin2', 'pe-bear.exe', 'PE-bear.exe', 'CFF Explorer.exe', 'sigcheck.exe', 'sigcheck', 'sigcheck64.exe'); notes = '读取节、导入导出、CLR 和依赖' },
    [pscustomobject]@{ id = 'native-static'; category = '原生静态'; names = @('ida.exe', 'ida64.exe', 'idat.exe', 'idat64.exe', 'ghidraRun.bat', 'analyzeHeadless.bat', 'r2.exe', 'r2', 'rizin.exe', 'rizin', 'rz.exe', 'cutter.exe', 'cutter-cli.exe'); notes = '函数、交叉引用、调用关系和差分' },
    [pscustomobject]@{ id = 'dotnet-static'; category = '.NET'; names = @('dnSpyEx.exe', 'dnSpy-x86.exe', 'dnSpy.exe', 'ILSpy.exe', 'ilspycmd.exe', 'ilspycmd', 'ildasm.exe', 'ildasm', 'dotPeek.exe', 'de4dot.exe', 'de4dot', 'dotnet.exe', 'dotnet'); notes = '程序集、类型、资源和托管入口' },
    [pscustomobject]@{ id = 'resource-edit'; category = '资源'; names = @('ResourceHacker.exe', 'rcedit.exe', 'ResEdit.exe', 'Restorator.exe', 'XNResourceEditor.exe', 'rc.exe', 'mt.exe', '7z.exe', '7z', '7zz.exe'); notes = '图标、版本资源和嵌入文件' },
    [pscustomobject]@{ id = 'debugger'; category = '动态调试'; names = @('x64dbg.exe', 'x32dbg.exe', 'WinDbgX.exe', 'cdb.exe'); notes = '启动、异常、加载顺序和关键调用' },
    [pscustomobject]@{ id = 'system-observe'; category = '系统行为'; names = @('Procmon.exe', 'procmon.exe', 'procexp.exe', 'ProcessExplorer.exe'); notes = '文件、注册表、进程、DLL 和权限' },
    [pscustomobject]@{ id = 'runtime-instrumentation'; category = '运行时插桩'; names = @('frida.exe', 'frida-ps.exe', 'frida', 'frida-ps'); notes = '受控运行时参数和行为确认' },
    [pscustomobject]@{ id = 'network-observe'; category = '网络观察'; names = @('tshark.exe', 'tshark', 'Wireshark.exe', 'wireshark', 'mitmproxy.exe', 'mitmdump.exe', 'Fiddler.exe', 'HTTPDebuggerUI.exe'); notes = '授权、更新、配置和端点证据' },
    # Language / framework runtimes. Their purpose is to answer "the target is written in X -- does
    # this machine have what it takes to analyse or rebuild X". Every id here starts with 'language-'
    # so the summary line can list the detected stacks without re-classifying the whole catalog.
    [pscustomobject]@{ id = 'language-dotnet'; category = '语言/框架'; names = @('dotnet.exe', 'dotnet', 'csc.exe', 'vbc.exe', 'fsc.exe'); notes = '.NET / C# / VB.NET / F#（配合 dnSpy/ILSpy 反编译）' },
    [pscustomobject]@{ id = 'language-java'; category = '语言/框架'; names = @('java.exe', 'java', 'javac.exe', 'javac', 'jar.exe', 'kotlin.bat', 'kotlinc.bat'); notes = 'Java / Kotlin（配合 jadx/CFR 反编译）' },
    [pscustomobject]@{ id = 'language-python'; category = '语言/框架'; names = @('python.exe', 'python', 'python3.exe', 'py.exe', 'py', 'pyinstaller.exe', 'pyinstxtractor.py'); notes = 'Python（PyInstaller/py2exe 打包需先解包）' },
    [pscustomobject]@{ id = 'language-node'; category = '语言/框架'; names = @('node.exe', 'node', 'electron.exe', 'electron', 'npm.cmd', 'pnpm.cmd', 'yarn.cmd', 'asar.cmd', 'asar'); notes = 'Node / Electron（asar 解包 app 资源）' },
    [pscustomobject]@{ id = 'language-go'; category = '语言/框架'; names = @('go.exe', 'go'); notes = 'Go（静态大体积单文件，符号常保留）' },
    [pscustomobject]@{ id = 'language-rust'; category = '语言/框架'; names = @('rustc.exe', 'rustc', 'cargo.exe', 'cargo'); notes = 'Rust（静态链接，panic 字符串可定位）' },
    [pscustomobject]@{ id = 'language-native'; category = '语言/框架'; names = @('cl.exe', 'gcc.exe', 'gcc', 'g++.exe', 'g++', 'clang.exe', 'clang', 'windres.exe'); notes = 'C / C++（MSVC / MinGW / Clang）' },
    [pscustomobject]@{ id = 'language-delphi'; category = '语言/框架'; names = @('dcc32.exe', 'dcc64.exe', 'bds.exe', 'brcc32.exe'); notes = 'Delphi / C++Builder（VCL 窗体特征明显）' },
    [pscustomobject]@{ id = 'language-qt'; category = '语言/框架'; names = @('qmake.exe', 'qmake', 'windeployqt.exe', 'moc.exe'); notes = 'Qt（qt 运行时 DLL 和资源系统）' },
    [pscustomobject]@{ id = 'language-scripting'; category = '语言/框架'; names = @('AutoHotkey.exe', 'AutoHotkeyU64.exe', 'Aut2Exe.exe', 'AutoIt3.exe', 'flutter.bat', 'dart.exe'); notes = 'AutoHotkey / AutoIt / Flutter 等脚本或跨端框架' },
    [pscustomobject]@{ id = 'build'; category = '构建'; names = @('MSBuild.exe', 'msbuild', 'cl.exe', 'link.exe', 'lib.exe', 'dotnet.exe', 'dotnet', 'cargo.exe', 'cargo', 'go.exe', 'go', 'node.exe', 'node', 'npm.cmd', 'npm', 'npx.cmd', 'npx', 'java.exe', 'javac.exe'); notes = '构建 Launcher、Adapter、资源和测试' },
    [pscustomobject]@{ id = 'sign-release'; category = '签名发布'; names = @('signtool.exe', 'signtool', 'MakeCert.exe', 'makecert.exe', 'osslsigncode.exe', 'openssl.exe', 'openssl', '7z.exe', '7z', '7zz.exe'); notes = '签名、打包、校验和回滚包' },
    [pscustomobject]@{ id = 'binary-diff'; category = '二进制差分'; names = @('radiff2.exe', 'radiff2', 'ghidriff.exe', 'ghidriff', 'BinDiff.exe', 'bindiff.exe', 'diaphora.py', 'diaphora'); notes = '比较上下游版本并定位变更' },
    [pscustomobject]@{ id = 'managed-cleanup'; category = '.NET 清理'; names = @('de4dot.exe', 'de4dot'); notes = '仅在产品分析需要时处理托管混淆产物' },
    [pscustomobject]@{ id = 'package-inspect'; category = '程序包'; names = @('asar.cmd', 'asar', 'upx.exe', 'upx', '7zFM.exe', '7z.exe', '7z', '7zz.exe', '7zr.exe', 'bz.exe', 'Bandizip.exe', 'innoextract.exe', 'innounp.exe', 'unzip.exe', 'unzip'); notes = 'Electron/压缩包/打包痕迹和资源' },
    [pscustomobject]@{ id = 'automation'; category = '自动化'; names = @('python.exe', 'python', 'py.exe', 'py', 'uv.exe', 'pip.exe', 'pip3.exe', 'powershell.exe', 'powershell', 'pwsh.exe', 'pwsh', 'git.exe', 'git', 'curl.exe', 'jq.exe'); notes = '解析、差分、报告和测试' }
)

# Bumped whenever the search strategy itself changes. It is part of the reuse fingerprint, so an
# inventory produced by an older, narrower search is rejected once and rediscovered -- otherwise a
# machine that was scanned badly yesterday keeps reporting yesterday's misses forever.
$SearchGeneration = 2

$PrunedDirectoryFragments = @(
    '\$recycle.bin\', '\system volume information\', '\windows\winsxs\', '\windows\servicing\',
    '\windows\assembly\', '\windows\installer\', '\windows\softwaredistribution\',
    '\node_modules\', '\.git\', '\appdata\local\temp\', '\appdata\local\package cache\',
    '\programdata\package cache\', '\onedrive\', '\.cache\', '\gradle\caches\',
    '\.nuget\packages\', '\anaconda3\pkgs\', '\windowsapps\', '\steamapps\',
    '\microsoft\edgeupdate\', '\$windows.~bt\', '\$windows.~ws\'
)

function Test-PrunedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lower = ($Path.TrimEnd('\') + '\').ToLowerInvariant()
    foreach ($fragment in $PrunedDirectoryFragments) {
        if ($lower.Contains($fragment)) { return $true }
    }
    return $false
}

function Get-FixedDriveRoot {
    $roots = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq 'Fixed' -and $drive.IsReady) { [void]$roots.Add($drive.Name) }
        }
    }
    catch {
        # Falling back to the system drive is still better than assuming C:.
        if (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) { [void]$roots.Add($env:SystemDrive + '\') }
    }
    # Returned plainly, not as ,$array: the comma form emits the array as a single object, and every
    # caller here wraps the call in @(), which would then produce a one-element array of arrays.
    return $roots.ToArray()
}

function Read-ExtraRootFile {
    param([string[]]$Path)

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($Path)) {
        if ([string]::IsNullOrWhiteSpace([string]$file)) { continue }
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        foreach ($line in @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
            $entry = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($entry) -or $entry.StartsWith('#')) { continue }
            [void]$roots.Add([Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\'))
        }
    }
    return $roots.ToArray()
}

function Get-DiscoverySearchRoot {
    param(
        [string[]]$Additional,
        [Parameter(Mandatory = $true)][int]$DefaultDepth,
        [switch]$DeepScan,
        [string[]]$ExtraRootFile
    )

    # Roots are collected drive-agnostically. The previous list hard-coded C:\Program Files and
    # C:\Windows\System32, so a machine that keeps its toolchain on D: -- Python, Git and a JRE on
    # this one -- reported them as not installed and the agent then asked the user to install what
    # they already had.
    $seen = @{}
    $roots = New-Object System.Collections.Generic.List[object]
    function Add-SearchRoot {
        param([string]$Path, [int]$Depth, [switch]$Explicit)

        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $clean = [Environment]::ExpandEnvironmentVariables($Path).Trim().TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($clean)) { return }
        if ($clean -match '^[A-Za-z]:$') { $clean += '\' }
        if (-not (Test-Path -LiteralPath $clean -PathType Container)) { return }
        $key = $clean.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            if ($seen[$key].Depth -lt $Depth) { $seen[$key].Depth = $Depth }
            if ($Explicit) { $seen[$key].NoPrune = $true }
            return
        }
        # Explicit means the caller named this directory: -AdditionalSearchRoot or a line in the
        # user's extra-roots file. The prune list must not apply to it. Skipping pruning matters in
        # practice, not in theory: the noise patterns include temp and cache directories, and
        # "the tool is in my temp folder" is a perfectly ordinary thing for a user to say -- the
        # search would have silently ignored the one directory they explicitly pointed at.
        $entry = [pscustomobject]@{ Path = $clean; Depth = $Depth; NoPrune = [bool]$Explicit }
        $seen[$key] = $entry
        [void]$roots.Add($entry)
    }

    # 1. Program directories, from the environment rather than a literal drive letter.
    foreach ($variable in @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432')) {
        Add-SearchRoot -Path ([Environment]::GetEnvironmentVariable($variable)) -Depth $DefaultDepth
    }
    Add-SearchRoot -Path (Join-Path $env:SystemRoot 'System32') -Depth 1
    Add-SearchRoot -Path (Join-Path $env:SystemRoot 'SysWOW64') -Depth 1

    # 2. Per-user tool locations.
    foreach ($relative in @('Tools', 'tools', 'bin', 'scoop\shims', 'scoop\apps', '.cargo\bin', '.local\bin', 'go\bin', '.dotnet\tools')) {
        Add-SearchRoot -Path (Join-Path $env:USERPROFILE $relative) -Depth 6
    }
    Add-SearchRoot -Path (Join-Path $env:LOCALAPPDATA 'Programs') -Depth 6
    Add-SearchRoot -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links') -Depth 2
    Add-SearchRoot -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Depth 4

    # 3. Conventional tool folder names probed on every fixed drive. Names, not paths: this is what
    # keeps D:\Program and E:\Tools discoverable without writing either of them down.
    $toolFolderNames = @(
        'Program Files', 'Program Files (x86)', 'Program', 'Programs', 'ProgramData',
        'Tools', 'tool', 'Apps', 'App', 'bin', 'opt', 'dev', 'Dev', 'SDK', 'sdk',
        '开发', '软件', '工具', 'RE', 'Reverse', 'Security', 'green', '绿色软件'
    )
    foreach ($drive in @(Get-FixedDriveRoot)) {
        foreach ($name in $toolFolderNames) {
            Add-SearchRoot -Path (Join-Path $drive $name) -Depth $DefaultDepth
        }
    }

    # 4. Whatever is already on PATH; its own directory only, since PATH entries are leaf bins.
    foreach ($entry in @(($env:PATH -split ';'))) { Add-SearchRoot -Path $entry -Depth 1 }

    # 5. Installed-program locations from the registry. Drive-agnostic and survives the user moving
    # their install directory, which a written-down path does not.
    foreach ($hive in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        try {
            foreach ($key in @(Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue)) {
                $location = (Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue).InstallLocation
                Add-SearchRoot -Path $location -Depth 4
            }
        }
        catch { }
    }
    foreach ($hive in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths')) {
        try {
            foreach ($key in @(Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue)) {
                $registered = [string](Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue).'(default)'
                if ([string]::IsNullOrWhiteSpace($registered)) { continue }
                Add-SearchRoot -Path (Split-Path -Parent ($registered.Trim('"'))) -Depth 2
            }
        }
        catch { }
    }

    # 6. The user's own locations, and this run's explicit roots.
    foreach ($extra in @(Read-ExtraRootFile -Path $ExtraRootFile)) { Add-SearchRoot -Path $extra -Depth $DefaultDepth -Explicit }
    foreach ($extra in @($Additional)) { Add-SearchRoot -Path $extra -Depth $DefaultDepth -Explicit }

    # 7. Opt-in whole-machine sweep.
    if ($DeepScan) {
        foreach ($drive in @(Get-FixedDriveRoot)) { Add-SearchRoot -Path $drive -Depth $DeepScanDepth }
    }

    return $roots.ToArray()
}

function Get-CommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $commands = @(Get-Command $Name -All -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandType -in @('Application', 'ExternalScript') -and -not [string]::IsNullOrWhiteSpace($_.Source)
    })
    if ($commands.Count -gt 0) {
        return [string]$commands[0].Source
    }
    return ''
}

function Get-VersionText {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $values = @($info.ProductVersion, $info.FileVersion, $info.FileDescription) | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        }
        if ($values.Count -gt 0) {
            return ($values -join ' | ')
        }
    }
    catch {
        return ''
    }
    return ''
}

# Get-PropertyValue and ConvertTo-BooleanValue now live in lib\product-state-common.ps1 (dot-sourced
# above), so the inventory reader and the protection detector share one StrictMode-safe accessor.

function Get-TextFingerprint {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return (([System.BitConverter]::ToString($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function ConvertTo-ComparableText {
    param($Value)

    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim().TrimEnd('\').ToLowerInvariant()
}

function Get-RowPresenceStatus {
    param([AllowNull()]$Row)

    # Returns 'present', 'missing' or 'exempt'. A reused row is only worth anything if the thing it
    # points at is still on disk. Rows whose "path" is not a filesystem path are exempted by their
    # declared source, never by pattern-guessing the path text.
    if ($null -eq $Row) { return 'missing' }
    if ([string](Get-PropertyValue $Row 'source' '') -eq 'PowerShell built-in') { return 'exempt' }
    if (-not (ConvertTo-BooleanValue (Get-PropertyValue $Row 'available' $false))) { return 'exempt' }
    $recorded = [string](Get-PropertyValue $Row 'path' '')
    if ([string]::IsNullOrWhiteSpace($recorded)) { return 'missing' }
    if (Test-Path -LiteralPath $recorded -PathType Leaf) { return 'present' }
    return 'missing'
}

function ConvertTo-InventoryRow {
    param([AllowNull()]$Row)

    # Normalise a cached row into the exact seven-property shape the rest of the script and every
    # downstream reader expect, so one malformed row cannot crash the markdown/JSON rendering.
    return [pscustomobject]@{
        tool_id = [string](Get-PropertyValue $Row 'tool_id' '')
        category = [string](Get-PropertyValue $Row 'category' '')
        available = (ConvertTo-BooleanValue (Get-PropertyValue $Row 'available' $false))
        path = [string](Get-PropertyValue $Row 'path' '')
        version = [string](Get-PropertyValue $Row 'version' '')
        source = [string](Get-PropertyValue $Row 'source' '')
        purpose = [string](Get-PropertyValue $Row 'purpose' '')
    }
}

function Write-InventoryFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    # The atomic swap, the UTF-8-with-BOM encoding and the retry policy all live in
    # lib\product-state-common.ps1 so that the inventory and the product state files cannot drift
    # into two different durability guarantees. Behaviour is unchanged: the destination name always
    # resolves to a complete file, and -ReuseInventory can never read back a half-written snapshot.
    Write-FileAtomic -Path $Path -Content $Content
}

# The host tool index has to be resolved before the reuse gate, because which index was used is
# part of what makes a previous inventory reusable at all.
if ([string]::IsNullOrWhiteSpace($HostToolIndexPath)) {
    $siblingIndex = Join-Path $PSScriptRoot '..\..\tool-index.json'
    if (Test-Path -LiteralPath $siblingIndex -PathType Leaf) {
        $HostToolIndexPath = $siblingIndex
    }
}
if (-not [string]::IsNullOrWhiteSpace($HostToolIndexPath) -and (Test-Path -LiteralPath $HostToolIndexPath -PathType Leaf)) {
    $HostToolIndexPath = (Resolve-Path -LiteralPath $HostToolIndexPath).Path
}

$normalizedSearchRoots = @(@($AdditionalSearchRoot) |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
    ForEach-Object { ([string]$_).Trim().TrimEnd('\') } |
    Sort-Object -Unique)

# Extra-root files are resolved before the reuse gate, because which locations were searched is
# part of what makes a previous inventory reusable. Both defaults sit outside the skill folder:
# sync-local-skill.ps1 deletes anything in the install directory that is not in the source, so a
# list kept inside the skill would be erased by the next update.
$defaultExtraRootFiles = New-Object System.Collections.Generic.List[string]
$codexHome = $env:CODEX_HOME
if ([string]::IsNullOrWhiteSpace($codexHome)) { $codexHome = Join-Path $HOME '.codex' }
[void]$defaultExtraRootFiles.Add((Join-Path $codexHome 'exe-lifecycle-tool-roots.txt'))
[void]$defaultExtraRootFiles.Add((Join-Path $toolingRoot 'EXTRA-TOOL-ROOTS.txt'))
$resolvedExtraRootFiles = @(@(@($ExtraRootFile) + @($defaultExtraRootFiles)) |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
    ForEach-Object { (Resolve-Path -LiteralPath $_).Path } |
    Sort-Object -Unique)
$extraRootFingerprint = Get-TextFingerprint (($resolvedExtraRootFiles | ForEach-Object {
    '{0}={1}' -f $_, (Get-TextFingerprint ((Get-Content -Raw -LiteralPath $_ -ErrorAction SilentlyContinue) + ''))
}) -join ';')

$discoveryInputs = [pscustomobject]@{
    host_tool_index = $HostToolIndexPath
    additional_search_roots = $normalizedSearchRoots
    max_search_depth = $MaxSearchDepth
    search_generation = $SearchGeneration
    deep_scan = [bool]$DeepScan
    extra_root_fingerprint = $extraRootFingerprint
    catalog_fingerprint = Get-TextFingerprint (($catalog | ForEach-Object { '{0}={1}' -f $_.id, (($_.names) -join ',') }) -join ';')
}

function Test-DiscoveryInputsMatch {
    param($Cached, [Parameter(Mandatory = $true)]$Current)

    # Without this the most natural repair action silently does nothing: the user says "the tool is
    # in D:\Tools", the agent reruns with -AdditionalSearchRoot D:\Tools -ReuseInventory, every
    # recorded row still exists, reuse is applied, the new root is never searched and the tool is
    # still reported as not-found. Same for a changed host index, depth, or an extended catalog.
    if ($null -eq $Cached) { return $false }
    if ((ConvertTo-ComparableText (Get-PropertyValue $Cached 'catalog_fingerprint')) -ne (ConvertTo-ComparableText $Current.catalog_fingerprint)) { return $false }
    if ((ConvertTo-ComparableText (Get-PropertyValue $Cached 'host_tool_index')) -ne (ConvertTo-ComparableText $Current.host_tool_index)) { return $false }
    if ([string](Get-PropertyValue $Cached 'max_search_depth' -Default (-1)) -ne [string]$Current.max_search_depth) { return $false }
    # A snapshot taken by an older, narrower search strategy is not evidence about today's machine.
    if ([string](Get-PropertyValue $Cached 'search_generation' -Default (-1)) -ne [string]$Current.search_generation) { return $false }
    if ((ConvertTo-ComparableText (Get-PropertyValue $Cached 'extra_root_fingerprint')) -ne (ConvertTo-ComparableText $Current.extra_root_fingerprint)) { return $false }
    # A deep scan may be reused by a normal run, but never the other way round: the normal run
    # searched less, so its not-found rows say nothing about what a deep scan would have found.
    $cachedDeep = ConvertTo-BooleanValue (Get-PropertyValue $Cached 'deep_scan' $false)
    if ([bool]$Current.deep_scan -and -not $cachedDeep) { return $false }
    $cachedRoots = @(@(Get-PropertyValue $Cached 'additional_search_roots' -Default @()) | ForEach-Object { ConvertTo-ComparableText $_ } | Sort-Object -Unique)
    $currentRoots = @(@($Current.additional_search_roots) | ForEach-Object { ConvertTo-ComparableText $_ } | Sort-Object -Unique)
    return (($cachedRoots -join '|') -eq ($currentRoots -join '|'))
}

# --- optional reuse of a previous inventory -------------------------------------------------
# Full discovery walks ten roots recursively, so a rerun is expensive. Reuse is allowed, but only
# together with an existence spot-check of every reused row: without it an uninstalled or moved
# tool stays recorded as available forever and nothing ever reports an error. Reuse is additionally
# refused when the previous snapshot is too old or was produced from different discovery inputs.
$reuseApplied = $false
$reuseRejectReason = 'not requested'
$searchedRootCount = 0
$searchedDrives = @()
$spotChecked = 0
$spotExempt = 0
$spotMissing = 0
$allRows = @()
$generatedAt = [datetimeoffset]::Now
$verifiedAt = $generatedAt

if ($ReuseInventory) {
    $reuseRejectReason = 'no previous inventory'
    if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
        try {
            $cached = $null
            $cachedText = Get-Content -Raw -LiteralPath $jsonPath
            if ([string]::IsNullOrWhiteSpace($cachedText)) {
                $reuseRejectReason = 'previous inventory is empty'
            }
            else {
                try { $cached = $cachedText | ConvertFrom-Json }
                catch { $reuseRejectReason = 'previous inventory is not valid JSON' }
            }

            if ($null -ne $cached) {
                $cachedRows = @(Get-PropertyValue $cached 'tools' @())
                $cachedStamp = [string](Get-PropertyValue $cached 'generated_at' '')
                $parsedStamp = [datetimeoffset]::MinValue
                $ageHours = 0.0

                if ($cachedRows.Count -eq 0) {
                    # An empty inventory must never be reused: it would "succeed" while checking nothing.
                    $reuseRejectReason = 'previous inventory has no tool rows'
                }
                elseif (-not [datetimeoffset]::TryParse($cachedStamp, [ref]$parsedStamp)) {
                    $reuseRejectReason = 'previous inventory has no usable generated_at'
                }
                elseif (($ageHours = ([datetimeoffset]::Now - $parsedStamp).TotalHours) -gt $MaxInventoryAgeHours) {
                    $reuseRejectReason = 'previous inventory is {0}h old (limit {1}h)' -f [math]::Round($ageHours, 1), $MaxInventoryAgeHours
                }
                elseif ($ageHours -lt -1) {
                    $reuseRejectReason = 'previous inventory is stamped in the future'
                }
                elseif ($null -eq (Get-PropertyValue $cached 'discovery_inputs')) {
                    $reuseRejectReason = 'previous inventory predates discovery-input tracking'
                }
                elseif (-not (Test-DiscoveryInputsMatch -Cached (Get-PropertyValue $cached 'discovery_inputs') -Current $discoveryInputs)) {
                    $reuseRejectReason = 'discovery inputs changed since the previous inventory'
                }
                else {
                    # Every row is checked; the counters below separate real filesystem checks from
                    # rows that were exempt, so "spotchecked" is a coverage figure and not a row count.
                    $missingRows = New-Object System.Collections.Generic.List[string]
                    foreach ($cachedRow in $cachedRows) {
                        switch (Get-RowPresenceStatus -Row $cachedRow) {
                            'present' { $spotChecked++ }
                            'exempt' { $spotExempt++ }
                            default {
                                $spotChecked++
                                $spotMissing++
                                [void]$missingRows.Add([string](Get-PropertyValue $cachedRow 'tool_id' '(unnamed row)'))
                            }
                        }
                    }
                    if ($spotMissing -gt 0) {
                        $reuseRejectReason = 'spot-check failed for: ' + (($missingRows | Select-Object -First 8) -join ', ')
                    }
                    elseif ($spotChecked -eq 0) {
                        # Nothing was verifiable, so the spot-check proved nothing. Rediscover instead
                        # of reporting a verified reuse that verified zero paths.
                        $reuseRejectReason = 'previous inventory has no verifiable rows'
                    }
                    else {
                        $allRows = @($cachedRows | ForEach-Object { ConvertTo-InventoryRow -Row $_ })
                        $generatedAt = $parsedStamp
                        $reuseApplied = $true
                        $reuseRejectReason = ''
                    }
                }
            }
        }
        catch {
            $reuseApplied = $false
            $reuseRejectReason = 'previous inventory could not be evaluated: ' + $_.Exception.Message
        }
    }
    # The spot-check counters are deliberately kept after a rejected reuse: they are the evidence of
    # what the gate actually verified before it decided to rediscover.
    if (-not $reuseApplied) { $allRows = @() }
}

if (-not $reuseApplied) {
    $searchRoots = @(Get-DiscoverySearchRoot -Additional $AdditionalSearchRoot -DefaultDepth $MaxSearchDepth -DeepScan:$DeepScan -ExtraRootFile $resolvedExtraRootFiles)

    $candidateNames = @($catalog | ForEach-Object { $_.names }) | Select-Object -Unique
    $candidateFileNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $candidateNames) {
        [void]$candidateFileNames.Add($name)
        if ($name -notmatch '\.') {
            foreach ($extension in @('.exe', '.bat', '.cmd', '.ps1')) { [void]$candidateFileNames.Add($name + $extension) }
        }
    }

    # An explicit stack walk rather than Get-ChildItem -Recurse -Depth, because pruning is what
    # makes a deep search affordable: C:\Program Files alone contains WindowsApps, and package
    # caches and node_modules turn a ten-level walk into minutes. Depth is per root, so a shallow
    # bin directory is not walked as if it were a whole drive.
    $fallbackPaths = @{}
    foreach ($searchRoot in $searchRoots) {
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push([pscustomobject]@{ Path = $searchRoot.Path; Depth = 0 })
        while ($stack.Count -gt 0) {
            $node = $stack.Pop()
            if ($node.Depth -gt $searchRoot.Depth) { continue }
            if (-not $searchRoot.NoPrune -and (Test-PrunedDirectory -Path $node.Path)) { continue }
            try {
                foreach ($file in [System.IO.Directory]::EnumerateFiles($node.Path)) {
                    $leaf = [IO.Path]::GetFileName($file)
                    if ($candidateFileNames.Contains($leaf) -and -not $fallbackPaths.ContainsKey($leaf)) {
                        $fallbackPaths[$leaf] = $file
                    }
                }
            }
            catch {
                # A protected or unavailable directory is only a discovery miss.
            }
            try {
                foreach ($child in [System.IO.Directory]::EnumerateDirectories($node.Path)) {
                    $stack.Push([pscustomobject]@{ Path = $child; Depth = $node.Depth + 1 })
                }
            }
            catch {
                # Same: an unreadable subtree narrows the search, it does not fail it.
            }
        }
    }

    $rows = foreach ($entry in $catalog) {
        $path = ''
        $source = 'not-found'
        if ($entry.id -eq 'file-hash' -and (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
            $path = 'PowerShell:Get-FileHash'
            $source = 'PowerShell built-in'
        }
        else {
            foreach ($name in $entry.names) {
                $path = Get-CommandPath -Name $name
                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    $source = 'PATH/command'
                    break
                }
                if ($fallbackPaths.ContainsKey($name)) {
                    $path = [string]$fallbackPaths[$name]
                    $source = 'fallback-search'
                    break
                }
            }
        }
        [pscustomobject]@{
            tool_id = $entry.id
            category = $entry.category
            available = -not [string]::IsNullOrWhiteSpace($path)
            path = $path
            version = Get-VersionText -Path $path
            source = $source
            purpose = $entry.notes
        }
    }

    $hostRows = @()
    if (-not [string]::IsNullOrWhiteSpace($HostToolIndexPath) -and (Test-Path -LiteralPath $HostToolIndexPath -PathType Leaf)) {
        try {
            $hostIndex = Get-Content -Raw -LiteralPath $HostToolIndexPath | ConvertFrom-Json
            $hostRows = @($hostIndex.tools | Where-Object { $_.available -eq $true } | ForEach-Object {
                $hostPath = [string]$_.resolved_path
                if (-not [string]::IsNullOrWhiteSpace($hostPath) -and (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
                    [pscustomobject]@{
                        tool_id = [string]$_.name
                        category = '宿主工具索引'
                        available = $true
                        path = $hostPath
                        version = [string]$_.version
                        source = 'host-tool-index'
                        purpose = [string]$_.purpose
                    }
                }
            })
        }
        catch {
            $hostRows = @()
        }
    }

    $allRows = @($rows + $hostRows)
    $generatedAt = [datetimeoffset]::Now
    $searchedRootCount = @($searchRoots).Count
    $searchedDrives = @(@($searchRoots | ForEach-Object { ([string]$_.Path).Substring(0, 2).ToUpperInvariant() }) | Sort-Object -Unique)
}

$verifiedAt = [datetimeoffset]::Now
$scanScope = '复用上次的发现范围'
if (-not $reuseApplied) {
    $scanScope = "本次搜索了 $searchedRootCount 个目录根，覆盖磁盘 $($searchedDrives -join ' ')"
    if ($DeepScan) { $scanScope += "（深度扫描：整盘遍历到 $DeepScanDepth 层）" }
}
$markdown = @(
    '# 本机工具快照',
    '',
    "- 快照生成时间: $($generatedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))",
    "- 本次复核时间: $($verifiedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))",
    "- 快照来源: $(if ($reuseApplied) { "复用上次发现结果，已复核 $spotChecked 条记录路径仍然存在" } else { '本次全量发现' })",
    "- 搜索范围: $scanScope",
    "- 产品目录: $root",
    '- 规则: 只记录发现结果，不自动安装、不执行目标 EXE。',
    '- 某个角色显示 no 时：先加 `-DeepScan` 整盘重扫一次，仍然找不到才算这台机器没装。',
    "- 长期新增位置：把目录逐行写进 $((Join-Path $codexHome 'exe-lifecycle-tool-roots.txt')) 或产品目录下的 product-state/tooling/EXTRA-TOOL-ROOTS.txt，以后每次发现都会带上。",
    '',
    '| 工具角色 | 分类 | 可用 | 路径 | 版本/描述 | 来源 |',
    '|---|---|---:|---|---|---|'
)
foreach ($row in $allRows) {
    $available = if ($row.available) { 'yes' } else { 'no' }
    $path = ([string]$row.path).Replace('|', '\|')
    $version = ([string]$row.version).Replace('|', '\|')
    $purpose = ([string]$row.purpose).Replace('|', '\|')
    $markdown += "| $($row.tool_id) | $($row.category) | $available | $path | $version / $purpose | $($row.source) |"
}

# The detected development stacks, pulled out of the table so the agent does not have to eyeball
# fifteen rows to answer "what could this machine have been used to build". A language showing as
# not-available is kept in the list too, because "we do NOT have a Delphi toolchain" is exactly the
# fact that decides whether a Delphi target can be rebuilt or only wrapped.
$languageRows = @($allRows | Where-Object { ([string]$_.tool_id).StartsWith('language-') })
$languagesAvailable = @($languageRows | Where-Object { $_.available } | ForEach-Object { ([string]$_.tool_id) -replace '^language-', '' })
$languagesMissing = @($languageRows | Where-Object { -not $_.available } | ForEach-Object { ([string]$_.tool_id) -replace '^language-', '' })
$markdown += ''
$markdown += '## 本机可用的开发语言/框架'
if ($languagesAvailable.Count -gt 0) {
    $markdown += ('- 已装: ' + ($languagesAvailable -join ', '))
}
else {
    $markdown += '- 已装: （未发现，先加 -DeepScan 整盘重扫，仍为空才是真的没装）'
}
if ($languagesMissing.Count -gt 0) {
    $markdown += ('- 未发现: ' + ($languagesMissing -join ', ') + '（目标若用其中一种写成，通常只能外壳包裹，不能从源码重建）')
}
Write-InventoryFile -Path $inventoryPath -Content ($markdown -join [Environment]::NewLine)
Write-InventoryFile -Path $jsonPath -Content (([pscustomobject]@{
    # generated_at is when these rows were actually discovered. A reuse run must not move it
    # forward: doing so lets a snapshot renew its own freshness on every reuse and never expire.
    generated_at = $generatedAt.ToString('o')
    verified_at = $verifiedAt.ToString('o')
    product_root = $root
    host_tool_index = $HostToolIndexPath
    discovery_inputs = $discoveryInputs
    tools = $allRows
}) | ConvertTo-Json -Depth 6)

"inventory=$inventoryPath"
"json=$jsonPath"
"available=$(@($allRows | Where-Object available).Count)"
"total=$($allRows.Count)"
"reuse=$(if ($reuseApplied) { 'applied' } else { 'full-discovery' })"
"spotchecked=$spotChecked"
"spotexempt=$spotExempt"
"spotmissing=$spotMissing"
"generated_at=$($generatedAt.ToString('o'))"
"verified_at=$($verifiedAt.ToString('o'))"
"searchroots=$searchedRootCount"
"searchdrives=$($searchedDrives -join ',')"
"languages=$($languagesAvailable -join ',')"
"deepscan=$(if ($DeepScan) { 'yes' } else { 'no' })"
"extrarootfiles=$($resolvedExtraRootFiles.Count)"
if (-not $reuseApplied -and $ReuseInventory) { "reuserejected=$reuseRejectReason" }
