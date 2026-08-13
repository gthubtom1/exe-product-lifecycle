#requires -Version 5

# gap-classify -- honest hard-stop + mechanical dead-end classification (self-evolution step 1, read-mostly).
#
# When a reverse-engineering category cannot produce its required evidence, this turns the old failure mode
# ("quietly fill the category not_applicable / leave it blank -> drift into a shell -> claim done") into an
# evidence-bound `blocked` decision plus a STATE.yaml blocking item, and mechanically decides whether the
# failure is (a) a real capability gap (a tool could later be acquired) or (c) a real dead end (packed /
# over budget / installed tool already failed / a bypass attempt -- stop hunting for tools). The existing
# state_no_blocking_items gate then holds BUILD_READY/VERIFIED/RELEASED until the block is honestly resolved.
#
# It NEVER downloads / installs / winget / git clone / Start-Process a tool, never runs a research-derived
# command, never writes knowledge/, and never touches discover-tools.ps1's catalog. Its only writes are the
# three product-archive files below. Anti-fabrication: the caller MUST pass the failing command AND the file
# that command's output was saved to (under product-state/, non-empty, real hash) -- typed prose is refused.
# Second anti-fabrication rule, same spirit: "no tool exists" may only be claimed on a real answer from the
# resolve-capability bridge. A resolver_error / unknown_capability / non-zero exit / missing bridge / never
# built tool inventory is "we could not find out", and is refused (RESULT: rejected_resolver_unusable,
# exit 3, nothing written) instead of being laundered into a capability_gap.
#
#   powershell -File gap-classify.ps1 -ProductRoot <p> -CapabilityId unpack.pe.upx -Technique unpacking `
#       -FailureCommand "upx -d core.exe" -FailureOutputPath product-state/analysis/unpack-fail.txt

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProductRoot,
    [Parameter(Mandatory = $true)][string]$CapabilityId,
    [Parameter(Mandatory = $true)][ValidateSet('static_structure', 'static_strings', 'static_resources', 'disassembly', 'dynamic_behavior', 'unpacking')][string]$Technique,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FailureCommand,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FailureOutputPath,
    [string]$ToolTried = 'none-available',
    [ValidateSet('analysis', 'bypass')][string]$FailureNature = 'analysis',
    [switch]$InputProblem,
    [switch]$Transient,
    [int]$MaxToolsPerCapability = 2,
    [int]$MaxGateCount = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\product-state-common.ps1')
# ConvertTo-CanonicalJson is a required library primitive (build plan §2); it lives in knowledge-common and
# is sourced read-only to canonical-write the attempts ledger. This does NOT modify it, Test-ExperienceRecord,
# the evidence/category constants, or any knowledge/ writer.
. (Join-Path $PSScriptRoot 'lib\knowledge-common.ps1')

$script:EmptyFileSha256 = 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'

# Two innoextract failure strings that read alike and mean opposite things. Pinned as named constants so
# each is consumed by exactly one rule below and neither can be reworded into the other's meaning.
# Source: innoextract 1.9 tag literals -- setup/info.cpp and cli/main.cpp's top-level catch. Read out of
# the source, NOT observed on a run here; do not restate either as runtime-verified.
$script:InnoUnknownDataVersion = 'Unexpected setup data version:'
$script:InnoNotAnInnoInstaller = 'Not a supported Inno Setup installer!'

trap {
    # A classifier crash must be a legible verdict line (mirrors the invalid_index/invalid_query shape the
    # other gates use), not a bare stack trace -- a crash is not a classification.
    Write-Output 'RESULT: classifier_error'
    Write-Output ("detail=" + $_.Exception.Message)
    exit 4
}

$root = Resolve-CanonicalPath -Path (Resolve-Path -LiteralPath $ProductRoot).Path
$stateRoot = Join-Path $root 'product-state'
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    Write-Output 'RESULT: rejected_no_evidence'
    Write-Output "detail=没有产品档案（product-state 不存在）: $ProductRoot"
    exit 2
}

# --- anti-fabrication: a blocked decision must bind to a real, non-empty tool-output file under
# product-state/. A missing command, a 0-byte file, the empty-file hash, or a path outside product-state/
# is refused WITHOUT writing anything (mirrors the EVIDENCE-LEDGER / RUN-EVIDENCE binding rule). --------
if ([string]::IsNullOrWhiteSpace($FailureCommand)) {
    Write-Output 'RESULT: rejected_no_evidence'
    Write-Output 'detail=缺失败命令（FailureCommand 为空）：口说不算证据，拒绝写 blocked。'
    exit 2
}
if ([string]::IsNullOrWhiteSpace($FailureOutputPath)) {
    Write-Output 'RESULT: rejected_no_evidence'
    Write-Output 'detail=缺失败输出文件（FailureOutputPath 为空）：必须绑定真实工具输出。'
    exit 2
}
$outFull = if ([IO.Path]::IsPathRooted($FailureOutputPath)) { $FailureOutputPath } else { Join-Path $root $FailureOutputPath }
if (-not (Test-Path -LiteralPath $outFull -PathType Leaf)) {
    Write-Output 'RESULT: rejected_no_evidence'
    Write-Output "detail=失败输出文件不存在: $FailureOutputPath"
    exit 2
}
$outFull = (Resolve-Path -LiteralPath $outFull).Path
if (-not $outFull.StartsWith($stateRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Output 'RESULT: rejected_no_evidence'
    Write-Output "detail=失败输出文件必须落在 product-state/ 内: $FailureOutputPath"
    exit 2
}
if ((Get-Item -LiteralPath $outFull).Length -le 0) {
    Write-Output 'RESULT: rejected_no_evidence'
    Write-Output "detail=失败输出文件为 0 字节: $FailureOutputPath"
    exit 2
}
$outHash = (Get-FileHash -LiteralPath $outFull -Algorithm SHA256).Hash.ToUpperInvariant()
if ($outHash -eq $script:EmptyFileSha256) {
    Write-Output 'RESULT: rejected_no_evidence'
    Write-Output "detail=失败输出文件哈希等于空文件常量（内容为空）: $FailureOutputPath"
    exit 2
}
$outRelative = $outFull.Substring($root.Length + 1).Replace('\', '/')

# --- gather the mechanical anchors (all read-only) ------------------------------------------------------
# What the tool itself said about the failure. Already proven to exist, be inside product-state/ and be
# non-empty by the checks above; the two innoextract signature rules are its first consumers.
$failureOutputText = Read-TextFileSafe -Path $outFull
$verdict = 'UNKNOWN'
$packed = $false
$protectionFull = Join-Path $stateRoot 'PROTECTION-PROFILE.yaml'
if (Test-Path -LiteralPath $protectionFull -PathType Leaf) {
    $protectionText = Read-TextFileSafe -Path $protectionFull
    $verdict = (Get-IndentedYamlScalar -Text $protectionText -Key 'verdict').Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($verdict)) { $verdict = 'UNKNOWN' }
    $packed = Test-ProtectionSaysPacked -Text $protectionText
}

# tool availability for this capability, via the read-only resolve-capability bridge (step 2). ONLY the two
# verdicts 'available' and 'unavailable' are answers about tools; everything else -- resolver_error, an id
# that is not in the bridge table (unknown_capability), a non-zero exit, a missing/silent bridge, or a tool
# inventory that was never built -- means "we could not find out", which is NOT "no tool exists". Reading
# those as "no available tool" is the laundering this classifier exists to stop: it would mint a
# capability_gap (and with it an out-of-band install request) out of a typo or broken wiring. They are
# collected into $resolveProblem and refused below, after the rules that do not need the bridge at all.
$resolveScript = Join-Path $PSScriptRoot 'resolve-capability.ps1'
$inventoryFull = Join-Path $stateRoot 'tooling\TOOL-INVENTORY.json'
# $resolveReason is the machine-readable half of a refusal (the detail= line is for humans and is not a
# stable contract). Callers and CI branch on it, and each code corresponds to exactly one check below.
$toolAvailable = $false
$resolveVerdict = ''
$resolveExit = -1
$resolveProblem = ''
$resolveReason = ''
if (-not (Test-Path -LiteralPath $resolveScript -PathType Leaf)) {
    $resolveReason = 'bridge_missing'
    $resolveProblem = "能力解析器不存在，无法判断有无对口工具（接线损坏）: $resolveScript"
}
else {
    $psHost = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
    $resolveOut = @()
    # The bridge reports its failures in-band (a RESULT line plus an exit code), so this must capture them
    # rather than let the host turn them into an exception. Under $ErrorActionPreference='Stop' both hosts
    # would do exactly that, differently: PS 5.1 throws on native stderr, PS 7 throws on a non-zero native
    # exit ($PSNativeCommandUseErrorActionPreference). Either would collapse every precise reason below into
    # a generic bridge_uninvokable, and differently per host. Read the streams and the code directly instead.
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $resolveOut = @(& $psHost -NoProfile -ExecutionPolicy Bypass -File $resolveScript -CapabilityId $CapabilityId -ProductRoot $root 2>&1 | ForEach-Object { [string]$_ })
        # $LASTEXITCODE does not exist until a native command has run in this session, and reading a
        # non-existent variable is fatal under Set-StrictMode. Absent means "the call did not report", which
        # is not zero.
        $resolveExit = if (Test-Path -LiteralPath 'Variable:LASTEXITCODE') { $LASTEXITCODE } else { -1 }
    }
    catch {
        $resolveReason = 'bridge_uninvokable'
        $resolveProblem = "调用能力解析器失败（$psHost 无法执行）: $($_.Exception.Message)"
    }
    finally { $ErrorActionPreference = $prevEap }
    if ($resolveProblem -eq '') {
        $vLine = @($resolveOut | Where-Object { $_ -match '^RESULT:\s*' } | Select-Object -First 1)
        if ($vLine.Count -eq 1) { $resolveVerdict = ($vLine[0] -replace '^RESULT:\s*', '').Trim() }
        if ($resolveExit -ne 0) {
            $resolveReason = 'nonzero_exit'
            $resolveProblem = "能力解析器退出码=$resolveExit（非 0），其答案不可信，不能当成「没有工具」"
        }
        elseif ([string]::IsNullOrWhiteSpace($resolveVerdict)) {
            $resolveReason = 'no_result_line'
            $resolveProblem = '能力解析器没有输出 RESULT 裁决行（静默失败），无法判断有无对口工具'
        }
        elseif ($resolveVerdict -eq 'resolver_error') {
            $resolveReason = 'resolver_error'
            $resolveProblem = '能力解析器自报 resolver_error（崩溃兜底）：这是解析器坏了，不是该能力没有工具'
        }
        elseif ($resolveVerdict -eq 'unknown_capability') {
            $resolveReason = 'unknown_capability'
            $resolveProblem = "能力 id 不在解析器桥表内（unknown_capability）：这是 id 写错或桥表漏登，不是该能力没有工具"
        }
        elseif ($resolveVerdict -ne 'available' -and $resolveVerdict -ne 'unavailable') {
            # Backstop for a verdict word this consumer has never heard of. It also covers each named case
            # above, on purpose: a future edit that drops one of them still refuses, just with a vaguer
            # reason. Their mutation guards therefore assert reason=, not merely "did it refuse".
            $resolveReason = 'unexpected_verdict'
            $resolveProblem = "能力解析器返回未知裁决「$resolveVerdict」，消费者不认，拒绝当成「没有工具」"
        }
        else {
            $toolAvailable = ($resolveVerdict -eq 'available')
        }
    }
}
# 「从没查过」不等于「查过没有」：解析器把「清单缺失」和「清单里没有对口工具」都答成 unavailable（其 RC1
# 契约如此），所以缺 TOOL-INVENTORY.json 时的 unavailable 必须由消费者挡掉——否则没跑过 discover-tools 就
# 能拿到 capability_gap，凭「没查过」去要带外装工具。
if ($resolveProblem -eq '' -and -not $toolAvailable -and -not (Test-Path -LiteralPath $inventoryFull -PathType Leaf)) {
    $resolveReason = 'no_tool_inventory'
    $resolveProblem = '工具清单 product-state/tooling/TOOL-INVENTORY.json 不存在：从没跑过 discover-tools 不等于没有工具，先做工具发现再来分类'
}

# attempts ledger (the only new state file). Read current, and -- only on the (a) path below -- record the
# attempt so the budget in rule 2 is real across runs.
$attemptsFull = Join-Path $stateRoot 'tooling\CAPABILITY-ATTEMPTS.json'
$attempts = [ordered]@{}
if (Test-Path -LiteralPath $attemptsFull -PathType Leaf) {
    try {
        $parsed = Read-TextFileSafe -Path $attemptsFull | ConvertFrom-Json
        foreach ($p in $parsed.PSObject.Properties) { $attempts[$p.Name] = $p.Value }
    }
    catch { $attempts = [ordered]@{} }
}
$toolsTried = New-Object System.Collections.Generic.List[string]
$gateCount = 0
if ($attempts.Contains($CapabilityId)) {
    $entry = $attempts[$CapabilityId]
    foreach ($t in @((Get-PropertyValue $entry 'tools_tried' @()))) { if (-not [string]::IsNullOrWhiteSpace([string]$t)) { [void]$toolsTried.Add([string]$t) } }
    $gc = 0; if ([int]::TryParse([string](Get-PropertyValue $entry 'gate_count' 0), [ref]$gc)) { $gateCount = $gc }
}

# --- classification: exactly one of (a) capability_gap / (b) input_problem / (c) dead_end / (d) transient,
# or -- when the tool bridge could not answer and the verdict would have to rest on that answer -- a
# no-write refusal. Mechanical, in priority order; each records the anchor it fired on. ------------------
$anchoredTechniques = @('unpacking', 'disassembly')
$classification = ''
$anchor = ''
if ($Transient) {
    $classification = 'transient'; $anchor = '调用方声明为瞬时/可重试失败'
}
elseif ($FailureNature -eq 'bypass') {
    # Rule 4: bypassing protection / de-authorising / cracking a signature is never a capability gap.
    $classification = 'dead_end'; $anchor = '失败性质=绕过保护/去授权/破解签名，永不判缺工具'
}
elseif ($failureOutputText.Contains($script:InnoNotAnInnoInstaller)) {
    # Rule 5a: the target is not an Inno Setup installer at all. That is a statement about our TOOL CHOICE,
    # not about our tooling coverage or about the target being unopenable -- so it is neither dead_end nor
    # capability_gap. Refuse, write nothing, and send the caller back to triage to re-identify the
    # container; any archive write here would record a wrong conclusion about the target.
    #
    # Both signature rules sit ahead of the packed/budget rules deliberately, and 5a ahead of 5b, because
    # the two errors' costs are asymmetric: reading "unexpected data version" as a selection error wastes
    # one triage pass, while reading "not an Inno installer" as a dead end permanently abandons a target
    # that a different tool would have opened. If an evidence file somehow carries both strings, the same
    # asymmetry decides -- the branch that does not abandon the target wins.
    Write-Output 'RESULT: rejected_wrong_tool_for_target'
    Write-Output 'reason=not_an_inno_setup_installer'
    Write-Output ("detail=工具报「" + $script:InnoNotAnInnoInstaller + "」：目标根本不是 Inno Setup 安装包。这是选型错误，不是能力缺口，也不是死路——回 triage 重新识别封装类型再选工具。")
    Write-Output ("capability_id=" + $CapabilityId)
    Write-Output ("technique=" + $Technique)
    Write-Output ("evidence=" + $outRelative)
    Write-Output 'note=未写入任何档案文件：选型错误若记成 dead_end，会永久放弃一个换个工具就能解的目标'
    exit 3
}
elseif ($failureOutputText.Contains($script:InnoUnknownDataVersion)) {
    # Rule 5b: innoextract ran, the target IS an Inno Setup installer, but its setup DATA version is above
    # the highest entry this release knows. Upstream has shipped nothing since, so no acquirable tool
    # clears that ceiling -- a real dead end rather than a missing tool.
    $classification = 'dead_end'
    $anchor = "工具输出含「$($script:InnoUnknownDataVersion)」：目标确是 Inno Setup，但 setup data 版本高于该工具已知上界，换/装工具也解不开"
}
elseif ($packed -and ($Technique -in $anchoredTechniques)) {
    # Rule 1: a packed/rebuild target's unpacking (or disassembly of the packed body) failing is a dead end,
    # not a missing tool (mirrors unpacking_consistent_with_protection).
    $classification = 'dead_end'; $anchor = "保护判定=$verdict/可能加壳，且类别=$Technique（脱壳/改二进制），默认死路"
}
elseif ($toolsTried.Count -ge $MaxToolsPerCapability -or $gateCount -ge $MaxGateCount) {
    # Rule 2: hard attempt budget -- "install tools forever" is structurally impossible.
    $classification = 'dead_end'; $anchor = "已超尝试预算（tools_tried=$($toolsTried.Count)>=N=$MaxToolsPerCapability 或 gate_count=$gateCount>=M=$MaxGateCount）"
}
elseif ($resolveProblem -ne '') {
    # Bridge unusable. Every rule above decided WITHOUT asking about tools, so they were still allowed to
    # fire; both remaining branches (rule 3 "an available tool already failed" and the capability_gap path
    # "no tool exists") are claims about tool availability, and an untrustworthy bridge answer supports
    # neither. Refuse with a legible verdict and write nothing -- a broken/unmapped bridge must go red here,
    # not quietly become a capability_gap.
    Write-Output 'RESULT: rejected_resolver_unusable'
    Write-Output ("reason=" + $resolveReason)
    Write-Output ("detail=" + $resolveProblem)
    Write-Output ("capability_id=" + $CapabilityId)
    Write-Output ("technique=" + $Technique)
    Write-Output ("resolve_verdict=" + $(if ([string]::IsNullOrWhiteSpace($resolveVerdict)) { '(none)' } else { $resolveVerdict }))
    Write-Output ("resolve_exit=" + $resolveExit)
    Write-Output 'note=未写入任何档案文件：解析器答案不可信时不得判 capability_gap，请先修桥表/接线或补跑工具发现'
    exit 3
}
elseif ($toolAvailable) {
    # Rule 3: an installed tool for this capability already failed on this target -> not a missing tool.
    if ($InputProblem) { $classification = 'input_problem'; $anchor = "对口工具 available 但失败，调用方判定为输入问题（resolve=$resolveVerdict）" }
    else { $classification = 'dead_end'; $anchor = "对口工具 available=true 却仍产不出证据（resolve=$resolveVerdict），不是缺工具" }
}
else {
    # The only capability_gap path: no available tool, target not packed/rebuild, budget not exceeded.
    $classification = 'capability_gap'; $anchor = "该能力无任何可用对口工具（resolve=$resolveVerdict）且非加壳/重建、未超预算"
}

$verdictWord = switch ($classification) {
    'capability_gap' { 'gap' }
    'input_problem' { 'input_problem' }
    'dead_end' { 'dead_end' }
    'transient' { 'transient' }
}

# --- writes (exactly three product-archive files) -------------------------------------------------------
# 1) ANALYSIS-FINDINGS.yaml: set the category to blocked + append an evidence-bound finding.
$findingsFull = Join-Path $stateRoot 'analysis\ANALYSIS-FINDINGS.yaml'
if (-not (Test-Path -LiteralPath $findingsFull -PathType Leaf)) {
    Write-Output 'RESULT: rejected_no_evidence'
    Write-Output "detail=找不到 ANALYSIS-FINDINGS.yaml，无法记录 blocked: $findingsFull"
    exit 2
}
$findingsText = Read-TextFileSafe -Path $findingsFull
$findingsText = Set-YamlScalar -Text $findingsText -Key $Technique -Value 'blocked'
$summary = "卡点[$Technique] 分类=$classification($verdictWord) 能力=$CapabilityId 依据：$anchor"
$findingId = ('gap-{0}-{1}' -f $Technique, ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
$newline = if ($findingsText -match "`r`n") { "`r`n" } else { "`n" }
$item = @(
    ('  - id: ' + (ConvertTo-YamlScalar $findingId)),
    ('    technique: ' + (ConvertTo-YamlScalar $Technique)),
    ('    tool: ' + (ConvertTo-YamlScalar $ToolTried)),
    ('    summary: ' + (ConvertTo-YamlScalar $summary)),
    ('    path: ' + (ConvertTo-YamlScalar $outRelative)),
    ('    sha256: ' + (ConvertTo-YamlScalar $outHash))
) -join $newline
# Splice the item into the findings: block, handling both the empty `findings: []` and existing-items forms.
$lines = $findingsText -split "`r?`n"
$out = New-Object System.Collections.Generic.List[string]
$spliced = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if (-not $spliced -and $line -match '^findings:\s*(.*)$') {
        $inline = $Matches[1].Trim()
        [void]$out.Add('findings:')
        if ($inline -ne '' -and $inline -ne '[]') {
            # An unusual inline scalar; keep it as a first comment-free line is not expected here, so just
            # drop the '[]'/empty and re-add nothing. (Scaffold always ships `findings: []`.)
        }
        # Re-emit any already-present indented item lines, then append the new item at the block's end.
        $j = $i + 1
        while ($j -lt $lines.Count -and ($lines[$j] -match '^\s+\S' -or [string]::IsNullOrWhiteSpace($lines[$j]))) {
            if ($lines[$j] -match '^\s+#') { [void]$out.Add($lines[$j]); $j++; continue }
            if ([string]::IsNullOrWhiteSpace($lines[$j])) { break }
            [void]$out.Add($lines[$j]); $j++
        }
        foreach ($il in ($item -split "`r?`n")) { [void]$out.Add($il) }
        $i = $j - 1
        $spliced = $true
        continue
    }
    [void]$out.Add($line)
}
if (-not $spliced) {
    [void]$out.Add('findings:')
    foreach ($il in ($item -split "`r?`n")) { [void]$out.Add($il) }
}
Write-FileAtomic -Path $findingsFull -Content (($out -join $newline))

# 2) STATE.yaml blocking_items: append a human-readable item so the existing state_no_blocking_items gate
# holds. Read the current list and re-write it with the new item appended (Set-YamlList).
$stateFull = Join-Path $stateRoot 'STATE.yaml'
$stateText = Read-TextFileSafe -Path $stateFull
$existingItems = New-Object System.Collections.Generic.List[string]
$stateLines = $stateText -split "`r?`n"
for ($i = 0; $i -lt $stateLines.Count; $i++) {
    if ($stateLines[$i] -match '^blocking_items:\s*(.*)$') {
        $inline = $Matches[1].Trim()
        if ($inline -ne '' -and $inline -ne '[]') { break }
        $j = $i + 1
        while ($j -lt $stateLines.Count -and $stateLines[$j] -match '^\s*-\s*(.*)$') {
            $v = $Matches[1].Trim()
            if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) { $v = $v.Substring(1, $v.Length - 2) }
            [void]$existingItems.Add($v); $j++
        }
        break
    }
}
$nextStep = switch ($classification) {
    'capability_gap' { "缺能力 $CapabilityId：该类无任何可用对口工具，待带外放行安装（后续 acquire 阶段），不要漂成外壳" }
    'dead_end' { "死路（$anchor）：不再找工具，转 WRAPPER/REBUILD 策略或如实标记无法复现" }
    'input_problem' { "输入问题（$CapabilityId）：对口工具在位但输入不满足，修正输入后重试，勿再要更多工具" }
    'transient' { "瞬时失败（$CapabilityId）：可重试；重试仍失败再按缺工具/死路重新分类" }
}
$blockItem = "[$verdictWord] $Technique / $CapabilityId -> $nextStep（证据 $outRelative）"
[void]$existingItems.Add($blockItem)
$stateText = Set-YamlList -Text $stateText -Key 'blocking_items' -Items $existingItems.ToArray()
Write-FileAtomic -Path $stateFull -Content $stateText

# 3) CAPABILITY-ATTEMPTS.json: on the capability_gap path, record the attempt so the budget is real.
if ($classification -eq 'capability_gap') {
    if (-not [string]::IsNullOrWhiteSpace($ToolTried) -and $ToolTried -ne 'none-available' -and -not $toolsTried.Contains($ToolTried)) { [void]$toolsTried.Add($ToolTried) }
    $attempts[$CapabilityId] = [ordered]@{
        tools_tried    = @($toolsTried)
        gate_count     = $gateCount + 1
        verdict_anchor = $verdict
        updated_at     = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $attemptsFull) | Out-Null
    Write-FileAtomic -Path $attemptsFull -Content (ConvertTo-CanonicalJson -Value $attempts)
}

Write-Output ("RESULT: " + $verdictWord)
Write-Output ("capability_id=" + $CapabilityId)
Write-Output ("technique=" + $Technique)
Write-Output ("resolve_verdict=" + $(if ([string]::IsNullOrWhiteSpace($resolveVerdict)) { '(none)' } else { $resolveVerdict }))
Write-Output ("anchor=" + $anchor)
Write-Output ("evidence=" + $outRelative)
Write-Output ("blocking_item=" + $blockItem)

# capability_gap is the one verdict that ends in "a tool could be acquired", so it is the one verdict that
# gets a ready-to-run acquisition suggestion. Every other outcome must NOT carry this line: dead_end and the
# two refusals mean the opposite (stop hunting for tools / the wiring or the tool choice is wrong), and
# printing an acquisition command next to them re-creates exactly the "launder a parser fault into a
# capability gap" confusion that 8672568 and 541d91c had to unpick inside the classifier itself.
#
# Emitted as a footer line rather than by calling the suggester, because that script prints its own RESULT:
# and capability_id= lines: splicing its output in here would hand this contract a second set of both, and
# any parser taking the last match would silently read the wrong verdict. A footer line also keeps a fault
# in the suggester from ever landing after the three archive files above have already been written.
if ($classification -eq 'capability_gap') {
    $suggestScript = Join-Path $PSScriptRoot 'suggest-tool-acquisition.ps1'
    # Same host the operator is already running, resolved locally: the $psHost computed for the bridge above
    # only exists on the branch where the bridge was invokable, and StrictMode makes reading it fatal here.
    $suggestHost = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
    # Both paths are quoted (a product root may contain spaces); the capability id is a bridge-table key, and
    # reaching this branch already proved it is one, so it needs none.
    $suggestCommand = '{0} -NoProfile -ExecutionPolicy Bypass -File "{1}" -CapabilityId {2} -ProductRoot "{3}"' -f $suggestHost, $suggestScript, $CapabilityId, $root
    if ($toolsTried.Count -gt 0) {
        # One comma-joined string, never several arguments: `powershell -File` does not bind array parameters
        # at all, so `-FailedTool a b c` would silently arrive as just "a" and the rest of the tools would be
        # re-suggested to a user who already watched them fail.
        $suggestCommand += (' -FailedTool "{0}"' -f (($toolsTried.ToArray()) -join ','))
    }
    Write-Output ("suggest_command=" + $suggestCommand)
}
exit 0
