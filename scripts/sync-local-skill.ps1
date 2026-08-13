#requires -Version 5

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourceRoot,
    [string]$DestinationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $DestinationRoot = Join-Path $codexHome 'skills\exe-product-lifecycle'
}
$source = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
$destinationParent = Split-Path -Parent $DestinationRoot
if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) { New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null }
if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) { New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null }
$destination = (Resolve-Path -LiteralPath $DestinationRoot).Path.TrimEnd('\')
if ($destination -eq $source -or $destination.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'DestinationRoot must be outside SourceRoot' }

$excludedTop = @('.git')
$preservedLearning = New-Object System.Collections.Generic.List[string]
$sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    ($relative.Split('\')[0] -notin $excludedTop) -and $_.Name -ne '.knowledge-write.lock'
})
$sourceRelative = @($sourceFiles | ForEach-Object { $_.FullName.Substring($source.Length + 1) })

# This script overwrites the copy the Agent actually loads. Publishing a source
# tree that cannot pass its own gate is how a half-written script becomes the
# live version while sync still reports success, so the gate runs first and a
# failure refuses the copy outright rather than warning about it.
# A destination that is a clone updates itself with git pull, and its history is what makes the
# experience captured there survivable. Copying files over it would leave it permanently dirty and
# make the next publish ambiguous about what is actually being published.
if (Test-Path -LiteralPath (Join-Path $destination '.git')) {
    # -PathType Container was wrong: a git worktree/submodule checkout has .git as a FILE ("gitdir: ...")
    # not a directory, so it slipped past this guard and got copied over -- overwriting tracked files and
    # deleting uncommitted work, the exact dirty-clone outcome this guard exists to prevent. (RV sync F3.)
    Write-Output "错误: 目标是一个 git clone，不能用复制的方式覆盖它: $destination"
    Write-Output '原因: clone 靠 git pull 更新；复制会把它变成一直有改动的状态，之后也说不清发布的到底是什么。'
    Write-Output '怎么办: 更新代码用 git pull；发布这台机器学到的经验用 scripts/publish-knowledge.ps1。'
    exit 1
}

# RV-R4 L2: this script deletes destination files the source does not have. If -DestinationRoot is
# mis-pointed at an ordinary non-empty directory that is not a skill install, that delete would eat
# unrelated files. A non-empty destination must therefore look like a skill install (contain SKILL.md);
# an empty/new destination is fine (a fresh install). A clone was already refused above.
$destinationEntries = @(Get-ChildItem -LiteralPath $destination -Force -ErrorAction SilentlyContinue)
if ($destinationEntries.Count -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $destination 'SKILL.md') -PathType Leaf)) {
    Write-Output "错误: 目标目录非空且不含 SKILL.md，看起来不是一个技能安装目录，已拒绝同步（避免误删无关文件）: $destination"
    Write-Output '怎么办: 确认 -DestinationRoot 指向的是本技能的安装目录；要装到全新位置就指向一个空目录。'
    exit 1
}
# RV sync F1: "has a SKILL.md" is too weak a proxy for "is THIS skill's install dir" -- another skill's
# install also has one. Mis-pointing -DestinationRoot at it would delete that skill's files and report
# success. Before deleting anything, require the SKILL.md to actually be exe-product-lifecycle (frontmatter
# name), so a non-empty destination must be an empty dir OR a genuine exe-product-lifecycle install.
$destSkillMd = Join-Path $destination 'SKILL.md'
if ($destinationEntries.Count -gt 0 -and (Test-Path -LiteralPath $destSkillMd -PathType Leaf)) {
    $destSkillName = ''
    $destFrontmatter = [regex]::Match((Get-Content -Raw -Encoding UTF8 -LiteralPath $destSkillMd), '(?s)^\s*---\r?\n(.*?)\r?\n---')
    if ($destFrontmatter.Success) {
        $destNameLine = [regex]::Match($destFrontmatter.Groups[1].Value, '(?m)^name:[ \t]*(\S+)[ \t]*$')
        if ($destNameLine.Success) { $destSkillName = $destNameLine.Groups[1].Value.Trim().Trim('"').Trim("'") }
    }
    if ($destSkillName -ne 'exe-product-lifecycle') {
        Write-Output "错误: 目标目录有 SKILL.md 但其 name 不是 exe-product-lifecycle（读到: '$destSkillName'），看起来是另一个技能的安装目录，已拒绝同步（避免删掉别的技能的文件）: $destination"
        Write-Output '怎么办: 确认 -DestinationRoot 指向的是 exe-product-lifecycle 的安装目录；要装到全新位置就指向一个空目录。'
        exit 1
    }
}

$layoutGate = Join-Path $source 'scripts\validate-skill-layout.ps1'
if (-not (Test-Path -LiteralPath $layoutGate -PathType Leaf)) {
    Write-Output "错误: 找不到技能自检脚本，已拒绝同步: $layoutGate"
    exit 1
}
$gateHost = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
$gateOutput = & $gateHost -NoProfile -ExecutionPolicy Bypass -File $layoutGate -SkillRoot $source 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Output '错误: 源目录没有通过技能自检，已拒绝同步（一个文件都没有覆盖）。'
    Write-Output '原因: 同步会覆盖 Agent 实际加载的那份副本。带语法错误或缺文件的版本一旦装进去，之后每一次加载都会失败。'
    foreach ($line in @($gateOutput)) { Write-Output "  $line" }
    Write-Output '怎么办: 先修好上面列出的问题，再重新运行本脚本。'
    exit 1
}

if ($PSCmdlet.ShouldProcess($destination, 'Synchronize EXE lifecycle skill files')) {
    foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($source.Length + 1)
        $target = Join-Path $destination $relative
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    foreach ($targetFile in @(Get-ChildItem -LiteralPath $destination -Recurse -File)) {
        $relative = $targetFile.FullName.Substring($destination.Length + 1)
        if ($relative -in $sourceRelative) { continue }
        # The installed copy is where the agent actually works, so it is where new experience is
        # first written. Mirroring a delete for anything the source happens not to have would throw
        # away the one thing this skill is supposed to accumulate -- and it is unrecoverable,
        # because until it is published nothing else has a copy. Keep it and say so.
        # RV sync F2: preservation used to be shape-sensitive -- only knowledge/{candidates,verified,
        # deprecated}/<single>.json survived, while a knowledge file at the knowledge/ root, in a deeper
        # subdir, or a non-json note was silently deleted (output only ever listed what it kept). Preserve
        # ANY file under knowledge/ that the source does not have, matching the README's broad promise, so
        # local learning is never lost without a word.
        if ($relative -match '^knowledge\\') {
            [void]$preservedLearning.Add($relative)
            continue
        }
        # Belt and braces: a hidden directory is not enumerated above today, so a clone's history
        # is not actually at risk right now. It is one -Force away from being deleted file by file,
        # and an installed copy that is a clone is exactly what makes learning survive.
        if ($relative.Split('\')[0] -in $excludedTop) { continue }
        Remove-Item -LiteralPath $targetFile.FullName -Force
    }
}

$mismatches = New-Object System.Collections.Generic.List[string]
foreach ($file in $sourceFiles) {
    $relative = $file.FullName.Substring($source.Length + 1)
    $target = Join-Path $destination $relative
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { [void]$mismatches.Add("missing:$relative"); continue }
    if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) { [void]$mismatches.Add("hash:$relative") }
}
if ($mismatches.Count -gt 0) { $mismatches | ForEach-Object { Write-Output "ERROR: $_" }; exit 1 }
Write-Output 'RESULT: local_skill_synchronized'
Write-Output "source=$source"
Write-Output "destination=$destination"
Write-Output "file_count=$($sourceFiles.Count)"
Write-Output "preserved_learning=$($preservedLearning.Count)"
foreach ($item in $preservedLearning) {
    Write-Output "  保留（安装副本独有的经验，源目录没有）: $item"
}
if ($preservedLearning.Count -gt 0) {
    Write-Output '  这些经验只存在于这台机器上。运行 scripts/publish-knowledge.ps1 把它们发布出去，否则换台机器就没有。'
}
