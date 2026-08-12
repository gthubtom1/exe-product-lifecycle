#requires -Version 5

<#
Publish what this machine learned, so it survives this machine.

    powershell -NoProfile -ExecutionPolicy Bypass -File publish-knowledge.ps1

Experience is captured next to whichever copy of the skill is running, and the copy an agent runs
is the installed one. If that copy is not a clone, everything it learns lives in exactly one place
on one disk, and nothing else has it -- which is the opposite of a knowledge base. This script is
the other half of that loop: rebuild the index, run the public-content gate, then commit and push
knowledge/ and nothing else.

Only knowledge/ is ever staged. Publishing learning must never quietly carry along whatever else
happened to be edited in the working tree.
#>

[CmdletBinding()]
param(
    [string]$SkillRoot,
    [string]$Remote = 'origin',
    [string]$Branch,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$root = Resolve-CanonicalPath -Path (Resolve-Path -LiteralPath $SkillRoot).Path.TrimEnd('\')

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs)

    # git writes ordinary notices, and "this is not a git repository", to stderr. Under
    # $ErrorActionPreference = 'Stop' a redirected stderr line becomes a terminating error, so the
    # user would get a PowerShell stack trace instead of the sentence written for them below --
    # and a stack trace reaching someone who does not know PowerShell is itself a defect here.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $root @GitArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ ExitCode = $code; Text = (@($output | ForEach-Object { [string]$_ }) -join "`n") }
}

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Output '错误: 这台机器上没有 git，无法发布。'
    Write-Output '怎么办: 装好 git 后重试；在此之前这台机器学到的经验只存在本地。'
    exit 1
}

$topLevel = Invoke-Git -GitArgs @('rev-parse', '--show-toplevel')
if ($topLevel.ExitCode -ne 0) {
    Write-Output "错误: 这份技能副本不是一个 git 仓库，没有地方可以发布: $root"
    Write-Output '原因: 它是被复制进来的，不是 clone 出来的。复制来的副本没有历史，学到的经验只存在这一块硬盘上。'
    Write-Output '怎么办: 换成 clone 装一次（先备份现有 knowledge/ 里的 json，装完再放回去）:'
    Write-Output '  git clone https://github.com/gthubtom1/exe-product-lifecycle.git <安装目录>'
    exit 1
}
$repoRoot = Resolve-CanonicalPath -Path ($topLevel.Text.Trim().Replace('/', '\'))
if ($repoRoot -ne $root -and -not $root.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Output "错误: 技能目录不在它所属仓库的下面，无法确定要提交哪些路径。技能=$root 仓库=$repoRoot"
    exit 1
}
# Relative to the skill directory, because every git call here runs with -C $root. Spelling it as
# a repo-root-relative path instead would resolve against the skill directory a second time and
# look for knowledge/ underneath itself -- which is how the skill-inside-a-monorepo layout breaks.
$knowledgePathspec = 'knowledge'

$psHost = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }

# Rebuild before validating, not after: the validator checks that the index and lock agree with the
# records on disk, so validating a stale index only proves the index is stale.
Write-Output '--- 重建索引 ---'
& $psHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\rebuild-knowledge-index.ps1') -SkillRoot $root | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output '错误: 重建知识索引失败，已停止，什么都没有发布。'; exit 1 }

# The gate that makes publishing safe at all: it refuses records carrying product identity, hashes,
# addresses, placeholders or unverified claims. It runs before anything leaves this machine.
Write-Output '--- 公开内容门禁 ---'
$gate = & $psHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\validate-knowledge.ps1') -SkillRoot $root 2>&1
if ($LASTEXITCODE -ne 0) {
    foreach ($line in @($gate)) { Write-Output "  $line" }
    Write-Output '错误: 知识库没有通过公开内容门禁，已停止，什么都没有发布。'
    Write-Output '怎么办: 按上面的 ERROR 逐条修好再重试。带产品身份、哈希、地址或占位符的记录不能公开。'
    exit 1
}
Write-Output '  通过'

$status = Invoke-Git -GitArgs @('status', '--porcelain', '--', $knowledgePathspec)
if ($status.ExitCode -ne 0) { Write-Output "错误: 读不出 git 状态: $($status.Text)"; exit 1 }
if ([string]::IsNullOrWhiteSpace($status.Text)) {
    Write-Output 'RESULT: nothing_to_publish'
    Write-Output '知识库和已发布的版本一致，没有新东西要发。'
    exit 0
}

Write-Output '--- 将要发布 ---'
foreach ($line in @($status.Text -split "`n")) { Write-Output "  $line" }

$counts = [ordered]@{}
foreach ($folder in @('verified', 'candidates', 'deprecated')) {
    $path = Join-Path $root ('knowledge\' + $folder)
    $counts[$folder] = @(Get-ChildItem -LiteralPath $path -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
}
$summary = "knowledge: verified=$($counts['verified']) candidates=$($counts['candidates']) deprecated=$($counts['deprecated'])"

if ($DryRun) {
    Write-Output 'RESULT: dry_run'
    Write-Output "  本来会提交: $summary"
    Write-Output '  去掉 -DryRun 才会真的提交并推送。'
    exit 0
}

$add = Invoke-Git -GitArgs @('add', '--', $knowledgePathspec)
if ($add.ExitCode -ne 0) { Write-Output "错误: git add 失败: $($add.Text)"; exit 1 }

# Commit the pathspec explicitly rather than whatever is staged: on a machine where the skill lives
# inside a bigger repository, someone else's staged work must not ride along with the knowledge.
$commitMessage = "chore(knowledge): 发布本机学到的经验`n`n$summary"
$commit = Invoke-Git -GitArgs @('commit', '-m', $commitMessage, '--', $knowledgePathspec)
if ($commit.ExitCode -ne 0) { Write-Output "错误: git commit 失败: $($commit.Text)"; exit 1 }
Write-Output '--- 已提交 ---'
foreach ($line in @($commit.Text -split "`n")) { Write-Output "  $line" }

if ([string]::IsNullOrWhiteSpace($Branch)) {
    $current = Invoke-Git -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')
    if ($current.ExitCode -ne 0) { Write-Output "错误: 读不出当前分支: $($current.Text)"; exit 1 }
    $Branch = $current.Text.Trim()
}

Write-Output "--- 推送到 $Remote/$Branch ---"
$push = Invoke-Git -GitArgs @('push', $Remote, ('HEAD:refs/heads/' + $Branch))
if ($push.ExitCode -ne 0) {
    foreach ($line in @($push.Text -split "`n")) { Write-Output "  $line" }
    Write-Output '错误: 推送被拒绝，但提交已经在本地，不会丢。'
    Write-Output '怎么办: 多半是别的机器先发布过。先 git pull 把远端的经验取回来，再重新运行本脚本。'
    Write-Output '不要用强制推送: 那会把别人发布的经验直接抹掉。'
    exit 1
}
foreach ($line in @($push.Text -split "`n")) { Write-Output "  $line" }
Write-Output 'RESULT: knowledge_published'
Write-Output "  $summary"
