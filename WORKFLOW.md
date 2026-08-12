# EXE Product Lifecycle Workflow

This file is the vendor-neutral entry point for agents that do not load Codex
`SKILL.md`. Load it only when the user asks to maintain, customize, authorize,
release, or update a Windows EXE product. It is not a global router and it does
not replace the host agent's own instructions.

Load `references/knowledge-lifecycle.md` only when the task asks to reuse cross-product experience or the current product has matching reusable-learning tags. Product evidence stays in that product's `product-state/`; shared candidates are sanitized and reviewed separately. Only `knowledge/verified/` may be queried as an analysis hint, and every match must be reverified on the current EXE.

## 先运行这一条

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start-here.ps1 -ProductRoot <产品文件夹> -UserRequest "<用户原话>"
```

Read-only, repeatable, and it prints the ordered list of commands to run next. Follow that list
instead of re-deriving the order from this document: prose gets skimmed and reordered, which is how
analysis ends up happening before the baseline is preserved and how "继续维护" turns into a
read-only status report.

## 零基础快速开始

用户不需要选择技术方案，也不需要运行命令。最少只要把一个 EXE 交给 Agent；安装包、DLL、截图和说明文件有就一起提供，没有也先开始。再用一句话描述目标即可。

| 用户说什么 | Agent 自动做什么 |
|---|---|
| “接入这个 EXE，保留 UI、联系方式和功能” | 建档、保存基线、分析程序、记录定制项并给出第一份报告 |
| “继续维护这个产品” | 读取旧档案，找到第一个未完成步骤并继续 |
| “把新版迁移进来” | 保存新版、比较新旧版本、迁移定制、测试并保留回滚 |
| “准备测试版” | 检查发布条件、生成候选包和验证记录，不直接替用户发布 |
| “回滚到上一版” | 找到已验证的旧版本，执行恢复并验证结果 |

Agent 负责推断产品编号、主 EXE、文件角色和内部工具；未知内容记录为待确认项。只有会改变结果、隐私、外部服务或不可逆发布行为的问题才向用户提问，并且一次只问一个最小问题。

## User contract

The beginner normally provides only one executable. Notes and other files are
helpful but optional for the first intake:

```text
product-root/
└── TARGET.exe
# optional: any-reference-document.md, installer, DLLs, screenshots
```

The agent creates the durable product record in that same product root. The
Markdown filename is not part of the protocol: preserve the supplied name,
detect additional explicit/top-level reference documents, and record all of
them in `product-state/artifacts/INPUT-MANIFEST.yaml`. After the first intake,
the user only needs to put a new upstream EXE/package and its notes in
`incoming/` and say that the current product should be updated.
Re-running initialization may add documents only when the product ID and
baseline hash are unchanged. A different baseline must be registered as a new
immutable `incoming/` bundle.

Do not make the user choose an adapter, schema, framework, reverse-engineering
tool, product ID, or server field. Discover the actual program first and record
unknowns as `UNVERIFIED` with the evidence needed to resolve them. Technical
commands belong to the Agent's execution log, not to the beginner's checklist.

If no file is attached to the conversation, ask only:

```text
请直接上传 EXE，或告诉我它所在的产品文件夹；有说明文件就一起放进去。
```

## Isolation rule

Each product has its own `product-state/`. Read these files before changing an
existing product:

```text
product-state/PRODUCT-INDEX.md
product-state/STATE.yaml
product-state/PRODUCT-DOSSIER.md
product-state/CUSTOMIZATION-MANIFEST.yaml
product-state/MAINTENANCE-MODE.yaml
product-state/OPERATION-MANIFEST.yaml
product-state/EVIDENCE-LEDGER.yaml
product-state/NETWORK-DATA-POLICY.yaml
product-state/HOST-INTEGRATION-MANIFEST.yaml
product-state/INPUT-SAFETY-POLICY.yaml
product-state/auth/
product-state/release/
```

Do not use another product's dossier, an unrelated root `docs/` folder, or
another agent's instruction file as evidence about this product. The root
`docs/` folder is host-level and is not created by this workflow. Host
instructions still apply, but product facts stay inside this product's
`product-state/`.

## Tool discovery

Before saying that an analysis tool is missing, run
`scripts/discover-tools.ps1 -ProductRoot <product-root> -ReuseInventory`. It checks PATH,
common user/tool directories, and an adjacent `skills/tool-index.json` when the
skill is inside the reverse-skill repository. Read the generated
`product-state/tooling/TOOL-INVENTORY.md`, choose a tool by role from
`references/toolchain.md`, optionally pass `-AdditionalSearchRoot`, and invoke
the recorded path. This prevents a tool from being marked missing only because
its directory is not on PATH.

Always go through the script; never treat an existing `TOOL-INVENTORY.md` as current on its own.
With `-ReuseInventory` the script re-checks every recorded path and falls back to a full discovery
when the snapshot is older than `-MaxInventoryAgeHours` (24 by default), when a recorded tool has
disappeared, or when the discovery inputs changed. Passing `-AdditionalSearchRoot` is itself a
changed input, so the most common repair -- "the tool is in D:\Tools" -- always triggers a real
rescan instead of silently reusing the snapshot that said the tool was missing.

The search covers every fixed drive, not just the system one: environment-derived program
directories, conventional tool folder names probed per drive, per-user tool directories, WinGet,
everything on PATH, and installed-program locations from the registry. No drive letter is written
down anywhere, so a machine that keeps its toolchain on D: is handled by the same code as one that
does not.

A `not-found` row is not yet a conclusion. Before telling the user a tool is missing, rerun with
`-DeepScan` (whole-drive sweep, minutes rather than seconds), then fall back to another tool in the
same role. When the user names a location, use `-AdditionalSearchRoot` for the current run *and*
append it to `%CODEX_HOME%\exe-lifecycle-tool-roots.txt` or
`product-state/tooling/EXTRA-TOOL-ROOTS.txt` so the next session does not ask again. Those files
live outside the skill folder because syncing the skill deletes anything in the install directory
that the source does not contain. See `references/toolchain.md`.

The inventory is a host snapshot, not a global routing table. It is safe to copy
the skill to another Agent because the new host will generate its own snapshot.

## Automatic mode selection

Select the first matching mode:

Normalize the input first, then select the mode. "A new file in `incoming/`" and "a new file
dropped straight into the product folder" are the same event; only the second one is what a
beginner actually does, and keying mode selection off `incoming/` alone made it invisible.

| Mode | Condition | First result |
|---|---|---|
| `bootstrap` | No usable `product-state/` exists | Create the record, preserve the input, and inventory the product |
| `update` | Existing record plus an unregistered upstream artifact, wherever it was dropped | Register it as an immutable bundle, then compare old reference, current customized build, and new reference |
| `resume` | The user says continue / keep maintaining / carry on, with no new input | Execute the first unfinished stage reported by `validate-product-state.ps1` |
| `status` | The user asks what is complete or what is missing | Read state and produce a beginner-readable status report, and change nothing |
| `release` | The user asks for a test or production package | Verify the release contract, then create a draft package |
| `rollback` | The user asks to restore a previous release | Select a verified prior release and record the rollback |

`status` and `resume` are deliberately separate: `status` only reports, `resume` acts. Mapping
"继续维护" onto `status` produces a report and no progress, which reads to the user as the agent
having ignored the request. If the mode is unclear and there is no unregistered input, use
`status`. Do not reinitialize a product that already has a valid `product-state/`.

## Required sequence

### 0. Mode-first loading

Do not pre-read every reference or run every validator. Use the smallest useful set:

- `bootstrap`: initialize the product record, register inputs, then discover tools only if the first stage needs analysis or a tool inventory.
- `update`: read `PRODUCT-INDEX.md`, `STATE.yaml`, and the immutable input manifest before loading migration/update references.
- `resume`: read `PRODUCT-INDEX.md` and `STATE.yaml`, run `validate-product-state.ps1`, and execute the stage its `NEXT-ACTION` names. Do not re-derive the order from prose: the order lives in `assets/lifecycle-states.json` so that two agents cannot pick two different next steps.
- `status`: read `PRODUCT-INDEX.md` and `STATE.yaml`, then only the report or contract named by the user's question. Write nothing.
- `release` / `rollback`: read state plus the relevant release or rollback files; load build, authorization, or update references only when their contract is in scope.
- Reusable learning: only then run `scripts/validate-knowledge.ps1` and query relevant `verified` patterns with `scripts/find-verified-patterns.ps1`. Ignore `candidate` and `deprecated` during product operations. A verified pattern narrows the next evidence check; it does not make a current-product claim true.

### 1. Preserve and register the input

Hash the supplied EXE, installer/package, DLL/resource set, and every supplied
document. Keep source artifacts read-only under `product-state/artifacts/` or
another clearly recorded path, and write the complete input list to
`artifacts/INPUT-MANIFEST.yaml`.
This step runs before mode selection, not after it. `validate-product-state.ps1` reports any
top-level file in the product root whose hash is in no manifest, which is how a new upstream build
dropped next to the old one gets noticed instead of sitting there unread.
Never treat a newly received EXE as the customized release. Do not execute an
unknown artifact merely to obtain a version string; use static metadata first
and record the evidence mode for any controlled run.

### 2. Build the product dossier

Record the actual product identity, entrypoint, architecture, dependencies,
visible windows, user flow, files, configuration, external endpoints, update
behavior, data locations, and failure behavior. Separate:

```text
observed fact
inference
UNVERIFIED question
```

The dossier is a map, not a claim that every capability exists. At the end of
the first analysis, summarize the result for the beginner as exactly one of:
`可自动迁移`、`部分内容需要确认`、`需要重新实现`.

Assess protections before deciding anything can be modified. Run
`scripts/detect-protections.ps1 -ProductRoot <product-root>` to fill
`PROTECTION-PROFILE.yaml`: file format, language/framework, packer and entropy,
anti-debug and self-check hints, code signature, and a modifiability verdict
(`CAN_PATCH` / `OVERLAY_ONLY` / `WRAPPER_ONLY` / `REBUILD_REQUIRED` / `UNKNOWN`).
This is static -- the target is never executed. The verdict is not a preference:
it is what the maintenance strategy must obey, because "去除/绕过原授权入口"
silently bricks the core when the target is packed, self-checking or signed.
`ANALYZED` requires this profile to be assessed.

### 3. Record customizations as rules

Every requested change must have an ID, category, stable anchor, operation,
source of truth, applicable versions, and a verification check. Cover all of:

```text
branding: name, logo, icon, strings, contact details
ui: windows, pages, menus, controls, layout, theme
features: enabled, disabled, added, replaced, or configured
runtime: paths, arguments, dependencies, data and startup behavior
auth: entrypoint, session, product mapping, failure and offline behavior
release: package, update channel, migration and rollback behavior
```

If a stable anchor cannot be found, mark the rule as a migration conflict. Do
not silently let a new upstream UI or contact string replace a recorded rule.

Before implementation, record the component strategy in
`MAINTENANCE-MODE.yaml`. Use `SOURCE_AVAILABLE`, `RESOURCE_OVERLAY`,
`BINARY_PATCH_RECORD`, `WRAPPER_LAUNCHER`, `REBUILD_REQUIRED`, or `UNKNOWN` per
component. An EXE-only input does not prove that the entire product can be
rebuilt.

### 4. Prepare the authorization handoff

Inspect the program's authorization surfaces and write product-specific facts
to `product-state/auth/`. This may include a login window, local license file,
device identifier, server request, entitlement, expiry, offline cache, or a
launch gate. A visible original authorization screen is a product fact to map,
not a universal assumption.

Write `AUTH-ADAPTER-REQUEST.md` for the separate authorization-system agent.
That agent returns a versioned contract and adapter specification in the same
directory. Keep administrator credentials, private keys, and live customer
tokens outside the product record and client package.

Write `auth/LAUNCH-CONTRACT.yaml` for the actual Launcher path, arguments,
working directory, environment, session handoff, core path, child processes,
failure behavior, and whether the original authorization surface remains
visible or gates the core. A launcher screen alone does not prove the original
authorization gate has gone away.

The product workflow owns how the EXE is started and verified. The authorization
platform owns users, products, entitlements, devices, release access, audit, and
revocation. Connect them through a product-specific adapter rather than
hard-coding one EXE's fields into the shared platform.

### 5. Policies, build, and package

Before G3, fill the product-specific operation manifest, evidence ledger,
network/data policy, host integration manifest, and input safety policy. A
material that does not apply must say `not_applicable`; an unknown material must
remain `UNVERIFIED` and block the affected implementation.

Keep the upstream baseline, customized source or patch records, adapter, build
output, and release manifest separate. Start with a complete package. Use an
incremental package only after the product has a tested delta and rollback
strategy.

A release remains `DRAFT` until startup, authorization, core flows, custom UI,
custom contact information, update behavior, data preservation, and rollback
are evidenced. Verify hashes and signatures before installation or publication.
Also create the component-level release manifest and
`release/RELEASE-PUBLISH-REQUEST.md`; the platform owns registration, visibility,
channel push, withdrawal, and publication audit, while this workflow owns the
local package and evidence.

Every modification or release has four linked deliverables: the modified
artifact, a Patch/Diff or reproducible overlay/patch record, a verification
record with exact commands/inputs/literal outputs/exit statuses, and a runnable
rollback record.

### 6. Migrate a new upstream version

For an existing product, do not replace the current release with the new EXE.
Run `scripts/register-input-bundle.ps1 -ProductRoot <product-root> -InputRoot incoming`
to preserve and hash every new file; do not require the old Markdown filename.
Do not reuse a `BundleId`; every migration input manifest is immutable.
Perform this comparison:

```text
A_old -> A_new: what changed in the supplied upstream product
B_old -> B_new: what must change in the maintained product
platform contract: whether authorization, release, or update integration changed
```

Reapply the customization manifest only through the recorded component
strategy, update the product adapter and Launcher contract, and run the test
matrix, especially checks that the user's logo, name, contact details, custom
pages, enabled features, and launcher flow remain present. Stop at
`MIGRATION_REQUIRED` when a rule cannot be mapped or a compatibility meaning is
uncertain.

After each evidence-producing analysis or migration, decide whether the result contains a genuinely cross-product method. Keep the draft and full provenance in `product-state/learning/`. Export only through `capture-experience.ps1`; require a second real product plus positive and negative fixtures, current-payload sanitization, and current-payload review before promotion.

## Product-local files

The initial scaffold is intentionally small and generic:

```text
product-state/
├── PRODUCT-INDEX.md
├── STATE.yaml
├── PRODUCT-DOSSIER.md
├── PROTECTION-PROFILE.yaml
├── CUSTOMIZATION-MANIFEST.yaml
├── MAINTENANCE-MODE.yaml
├── OPERATION-MANIFEST.yaml
├── EVIDENCE-LEDGER.yaml
├── NETWORK-DATA-POLICY.yaml
├── HOST-INTEGRATION-MANIFEST.yaml
├── INPUT-SAFETY-POLICY.yaml
├── UPSTREAM-VERSIONS.yaml
├── MIGRATION-RUNBOOK.md
├── TEST-MATRIX.md
├── learning/                 # private reusable-learning draft and export provenance
├── auth/
│   ├── AUTH-PROFILE.yaml
│   ├── AUTH-ADAPTER-REQUEST.md
│   └── LAUNCH-CONTRACT.yaml
├── tooling/
│   ├── TOOL-INVENTORY.md
│   ├── TOOL-INVENTORY.json
│   └── TOOL-PLAN.yaml
└── release/
    ├── UPDATE-PROFILE.yaml
    ├── RELEASE-MANIFEST.yaml
    ├── COMPONENT-RELEASE-MANIFEST.yaml
    └── RELEASE-PUBLISH-REQUEST.md
```

As evidence appears, add product-local files such as `AUTH-DISCOVERY.md`,
`AUTH-EVIDENCE-INDEX.yaml`, migration reports, test evidence, component release
records, and rollback records. A generic template must not be filled with
another product's facts.

## Required outputs

At the end of each action, update `STATE.yaml` and `PRODUCT-INDEX.md`, then
report in plain Chinese:

1. 当前模式和已确认的产品文件；
2. 已完成的动作和生成的文件；
3. 已验证的结果，包含命令、输入、输出和退出状态；
4. 未确认项和风险；
5. 唯一下一步或需要用户补充的最小资料。

For the first intake, the report must also show the migration conclusion in
plain Chinese: `可自动迁移`、`部分内容需要确认` or `需要重新实现`.

Do not claim that an EXE was updated, authorized, built, or released until the
artifact, Patch/Diff, verification record, and runnable rollback record exist.
For text fixtures or other simulations, set `simulation_only: true` and use
`VERIFIED_SIMULATION`. Reserve `VERIFIED` and `RELEASED` for real product
evidence with material `UNVERIFIED` contract fields resolved.

## Reference files

- `references/beginner-guide.md`: ordinary-language examples and directory use.
- `references/auth-handoff.md`: product-specific authorization discovery and
  the two-agent handoff contract.
- `references/release-update.md`: releases, signed metadata, update channels,
  migration, and rollback.
- `references/toolchain.md`: tool roles, EXE-type branching, and discovery rules.
- `references/knowledge-lifecycle.md`: evidence isolation, sanitization, candidate review, independent validation, promotion, deprecation, and GitHub sync.
- `scripts/start-here.ps1`: the mandatory read-only entry point. Inspects the folder, lists
  unregistered inputs, selects the mode and prints the next literal commands in order. Run it
  before anything else and again after each step.
- `scripts/init-product.ps1`: create a product-local scaffold without replacing
  existing files.
- `scripts/discover-tools.ps1`: discover local tools and languages across every
  fixed drive and write the product-local inventory without installing or
  executing the target.
- `scripts/detect-protections.ps1`: static protection assessment (packer,
  entropy, anti-debug, self-check, signature) and the modifiability verdict the
  maintenance strategy depends on. Never executes the target.
- `scripts/register-input-bundle.ps1`: preserve and hash a later `incoming/`
  bundle and write its migration input manifest.
- `scripts/update-product-state.ps1`: move the product to another status as one journalled
  transaction across `STATE.yaml` and `PRODUCT-INDEX.md`, refuse a status whose evidence is not
  there yet, and finish an interrupted transition with `-ResumeJournal`.
- `assets/lifecycle-states.json`: what each status means, the evidence it requires, and the next
  action. Read by the forward gate and by the agent; do not keep a second copy of this order.
- `scripts/validate-product-state.ps1`: validate structure, identity/status consistency, the forward status gate, unregistered inputs, preserved/release hashes, migration counts, simulation labels, and verified contracts. It also prints `NEXT-STATUS`, `NEXT-ACTION` and `NEXT-NEEDS`.
- `scripts/test-product-state-gates.ps1`: negative-path regression for the state machine.
- `scripts/test-tool-inventory-reuse.ps1`: behaviour regression for tool-inventory reuse and the atomic inventory write.
- `scripts/capture-experience.ps1`, `add-experience-evidence.ps1`, `review-experience.ps1`, `promote-pattern.ps1`, and `deprecate-pattern.ps1`: operate the reusable knowledge lifecycle.
- `scripts/validate-knowledge.ps1` and `find-verified-patterns.ps1`: validate shared knowledge and expose only verified patterns. The lookup fails closed: an incomplete index entry, a path outside `knowledge/verified/`, or a record whose hash no longer matches the index aborts the whole query instead of returning a partly trusted match set.
