# kmd 2.5.6 (19) acceptance ledger

Updated 2026-10-20. This is an implementation/evidence ledger, **not release
approval**. Do not create a positive acceptance JSON from this document.

## Baseline and integration

- Repository: `https://github.com/ksamint/kmd01`.
- Worktree: `kmd01-stabilize`; branch `codex/stabilize-2.5.6`.
- PR #14 baseline: `5eedf263cc36a172929b767bfa7b97db40b322a4`.
- Preserved installed-only commits: `4ecbf6c`, `05a1f10`, `0d388e1`, `40bac91`.
- Preserved original dirty worktrees; entitlement / manifest-cleanup source
  patches copied to integration, generated assets rebuilt from integrated source.
- Installed App remains **2.5.5 (18)**, commit
  `40bac9139f371e808cc861480a7afe65d109f6d7`. No installation performed.
- Crash evidence: 2026-10-19 17:28:15 NSDocument background-write executor trap;
  17:28:19 NSDocumentController restore/open initializer on background queue.
  Raw user crash reports are kept local, not published.

## Implemented versus tested

| Area | Source implemented | Evidence / remaining check |
| --- | --- | --- |
| Installed fixes + PR #14 | Integrated | Local tests below; full Xcode CI pending |
| AppKit read/write isolation | Concurrent read/write disabled; synchronous read completion; Save As refresh and awaited autosave failures | Actual crash stacks traced; immediate Save All regression; full lifecycle matrix pending |
| Agent/MCP/process pipes | Concurrent stdout/stderr drains, bounded cleanup/cancel/disconnect | Actual Swift transport/process harness; complete app CI pending |
| Web sync | Read-only interval, common write guard, fresh stored snapshot, network deadline, late-result rejection | Automated failure/concurrency tests; live cloud/manual browser pending |
| Manifest cleanup | Orphans only removed after manifest save | Notes and attachments failure regression tests |
| Failed editor saves | Retain per-file edits until successfully written | Cross-file failure + newer-edit regressions |
| Persistent access | Per-process bookmarks, scope balancing, stale refresh/revocation generations, recoverable error statuses and explicit retry | Injected-operation/error tests and Swift typechecks; real signed/reboot matrix pending |
| Final signing verifier | Exact source SHA, all component identity/version/SHA, entitlements/profile grants/expiry, hardened runtime, all Mach-O architectures | Synthetic positive/negative profile tests; real new candidate pending |
| CI/release gates | Hosted Linux, automatic Mac matrix, fail-closed aggregate, protected-main signing, exact-asset acceptance | Local actionlint/shellcheck/unit tests; remote matrix pending |

Local completed checks (record only actual completed results):

- CoreEditor: build and **180 tests** passed.
- WebApp: **78 tests across 16 files**, lint, build, build:mac and bundle validation
  passed; dependency audit reports **0 vulnerabilities**. A single writer tab
  per workspace prevents competing recovery; unsupported browsers fail closed.
- AgentSDK: lint, build and **2 tests** passed after targeted Vitest,
  brace-expansion and source-map-js patch updates; audit **0 vulnerabilities**.
- ResourceModules: **5 signed modules** verified and **10 tests** passed.
- Cloud: formatting, clippy (`-D warnings`), **19 tests** and strict dependency
  audit passed after minimal lockfile patches; the pre-existing RSA exception
  remains unchanged. No protocol or encryption-format changes.
- Identity: **2.5.6 (19)**; **2736 localized catalog entries** validated.
- Clipboard decoder/history harness and helper Swift typecheck passed after
  cross-process grant changes. Independent review added stale-refresh generation
  and long-lived Quick Action scope ownership regressions; tests/typechecks passed.
- CI gates: **6 tests**; profile verifier: **9 tests** (normal and optimized
  Python); installer rollback/draft selection: **5 tests**; exact-document/PID mocks passed.
  Actionlint and ShellCheck passed on the integrated source.
- Local default Homebrew Python 3.14 has an unrelated pyexpat linker error;
  `/usr/bin/python3` works. No host Python installation was changed.
- Local host has Command Line Tools only: full Xcode app/package verification
  has **not** been substituted by the standalone Swift checks.
- Hosted run `39414437185` passed all Linux jobs, including Cloud dependency
  audit. Both Mac jobs passed clipboard/bookmark/transport harnesses, then failed
  strict SwiftLint after the SQLite actor cleanup compile error was fixed.
  Follow-up formatting/test-structure corrections pass the pinned SwiftLint
  0.65.0 rules locally across all 319 Swift files; full Mac CI remains pending.
- The manual `Signed candidate runtime` workflow verifies an existing stapled
  draft's exact DMG hash, commit, signatures and profiles before running the
  dedicated lifecycle test on fresh macOS 26 ARM and macOS 15 ARM/Intel runners.
  Provenance regressions (3 tests), actionlint and ShellCheck passed. No candidate
  exists yet, so signed runtime execution remains pending.
- Hosted run `39416948995`: both Universal App builds, MarkEditKit and
  MarkEditCore tests passed. macOS 26 Modules ran 120 tests with no failures and
  two existing material-view skips (backdrop unavailable in the runner).
  macOS 15 had one obsolete private-class assertion; its actual titlebar accessor
  test passed. That assertion now follows the existing cross-version behavior.
  macOS 26's dedicated lifecycle test reached the first save request and timed
  out; no crash report was produced. Automation diagnostics and a fresh complete
  run are required before signing. These results are not a lifecycle pass.
- Workspace failure messages classify existing errors without additional disk
  probes. Unknown failures retain bookmarks and offer retry; permission errors
  offer an explicit folder selection. Capture sharing reports an unavailable
  existing container result without inferring its cause or changing fallback
  storage. Local injected-error/queue/tree checks passed; full App CI is pending.
- Hosted run `39419061409`: all Linux checks passed. Both macOS 15 and 26
  Universal builds, MarkEditKit, MarkEditCore and Modules passed (120 Modules
  tests, the same two material-view skips on each OS). Both lifecycle runners
  stopped at nonprompting Automation preflight with OSStatus `-1744`, before
  editing the fixture. This identifies the earlier save timeout as missing
  runner Automation consent, not a demonstrated application save deadlock.
  The harness now uses existing System Events/Accessibility grants only after
  checking them, and requires the exact process, fixture window and complete
  editable text. No TCC changes or permission-dialog clicks are made; hosted
  accessibility behavior still requires a new run.
- Final source review found that asynchronous decoding could return an empty
  document to AppKit before Save All. Reading now finishes decoding and
  publishing state before returning. A harness compiling the actual read,
  serialization and Save All method bodies fails against the prior code and
  passes with the fix, including replacement reads, empty files and >200 KB
  Unicode content. Decoding can occupy the main thread; performance work is
  deferred. The changed source requires another full hosted build.
- Signing now preserves exact signed bytes before contacting Apple and retains
  each returned submission response even if the second submission fails.
  Four signing regressions, including partial submission failure and draft-only
  success, pass locally. This is recovery preparation, not a signed release.
- Hosted run `39421305857` passed both new Universal builds and all Swift
  suites, including the read-completion regression. The first UI fallback
  exposed an incorrect System Events property name. A temporary diagnostic
  branch then reused the unchanged macOS 15 artifact while recording only the
  two test-harness overlays, their hashes and original source commit.
- Diagnostic `39424255863` passed **all 30 consecutive lifecycle cycles**, with
  30 distinct restored process IDs and no main/helper crash reports. It verified
  copied editor source and exact saved bytes. A restored window must be raised
  before inspecting its WebKit accessibility subtree; the prior order failed
  after seven cycles although the app remained responsive. No app source or
  privacy settings changed between those diagnostic runs. The original artifact
  remained commit `e7a6152a558b5461ce24910cc970a6a8d9e64880`, ZIP SHA256
  `af0752e7d06a19e3b46fbc9de791e0153fcce5b523b70237d99e156032a57510`.
  This diagnostic is not final CI or signed-artifact acceptance. The integrated
  harness still requires the complete macOS 26/15 and cross-version matrix.

## Repository disclosure and settings

The public-readiness review used a complete mirror (50 refs including PR refs,
1644 reachable commits; gitleaks scanned 1593 non-merge changes, ~34 MB), avoiding
an incomplete initial partial-clone scan that failed during lazy blob fetch.
All branches/tags were included, ignoring no gitleaks suppressions.

Three findings were reviewed: two deterministic crypto test-vector auth tags
(`Cloud/test-vectors/vault-object-v1.json`, fixed 0x07 key/0x03 nonce) and a
Hugging Face tokenizer `unk_token` field in generated code. No live credential
was found. Reviewed PR metadata/content (14 PRs, 22 comments), all 7 available
Actions logs (~3.27 MB, no scanner findings), documentation/configuration paths
and screenshots (sample/readme content). No Actions artifacts, releases, wiki,
or discussions existed at review time. The review found no private customer or
business datasets. Redacted scan evidence is retained locally with mode-restricted
working files; credentials/profile downloads are never repository artifacts.
PR implementation: https://github.com/ksamint/kmd01/pull/15.

Repository is now public, Actions enabled, `main` requires a PR and strict
`Release readiness`, resolved conversations, no force pushes/deletion, enforced
for admins. `release` environment limits deployment to protected branches,
requires the owner review, and disables admin bypass. Signing workflows
additionally restrict the dispatch ref to `main` and exact successful main CI.

## Production provisioning configuration

The existing App Group `group.art.apuch.ksamint-markedit` is now associated with
main App, Capture Helper, Finder Extension and Quick Actions under the existing
Team `A64LJ32AZT`. Four new `MAC_APP_DIRECT` profiles named with suffix `2.5.6`
were generated and decoded locally. All are ACTIVE, explicitly authorize that
App Group, match the existing Developer ID certificate, and expire on
2031-08-12. Preview keeps its existing profile because it does not use the group.
Bundle IDs, Team ID, keychain group and data locations remain unchanged.

The seven signing/notarization secrets are configured in the protected `release`
environment from the existing controlled credential source. No new
Apple signing identity was created. A repository-scoped Homebrew deploy key is configured
in the same environment for `ksamint/homebrew-ksamint`; temporary private key
files were removed. Downloaded profiles and credentials remain outside the
repository. This configuration evidence does not replace verification of the
final signed bundle or real permission persistence tests.

## Required signed runtime acceptance — all pending

Use dedicated documents in an isolated test workspace/account. Never edit the
frontmost document by assumption. Save `.xcresult`, sanitized logs, crash
summaries, final SHA256s and exact component identities.

Perform the full lifecycle, permission-persistence, upgrade and 24-hour checks
below on the user's one designated acceptance Mac. That Mac may run macOS 15
or 26. On the other OS, run the same final signed Universal artifact and record
successful launch and dedicated-document open/save compatibility evidence.
The other OS does not require another 24-hour session or two full reboots.

- 30 open/edit/save/quit/restore cycles; recent files, restored windows, unsaved
  drafts, autosave, Save As, Save All. Compare saved bytes and crash-report times.
- Agent cancellation, process exit and peer disconnect; large stdout AND stderr
  ZIP/TAR listings; corrupt HTML; failed writes; temporarily unavailable volumes.
- Existing grant, 10 quit/relaunch cycles, logout/login, two full system reboots,
  same-production-identity upgrade. User schedules real reboots; never automate
  them on the working Mac. Valid grants must not prompt again.
- Existing text, drafts, clipboard history, labels, pins, attachments and encrypted
  data survive; note switching, Undo, >200 KB payloads, failed sync and conflicts.
- Verify source and final signed entitlements/profile authorization for existing
  App Group on main, Helper, Finder and Quick Action. Do not rename containers,
  reset TCC, request Full Disk Access, or click permission dialogs automatically.
- Exact same Xcode 26.6 Universal artifact runs on macOS 15 and 26 and passes
  Gatekeeper/notarization/staple/signature checks. The designated acceptance Mac
  remains healthy for at least 24 hours.
- Back up App/data with restrictive permissions; quit normally; defer replacing
  the App if unsaved documents remain. Roll back App only, keep new user data.

The finalizer only publishes hashes approved in a protected-main
`docs/release-acceptance/v2.5.6.json` record. Until all pending rows are evidenced,
**do not state that crashes or repeated authorization are solved in production**.

The acceptance record's commit and artifact SHA256 map apply to both `systems`
rows (one for `macOS: "15"`, one for `"26"`). Exactly one row has
`acceptanceHost: true`; it requires the full matrix, at least 24 completed hours,
30 lifecycle cycles, 10 quit/relaunch cycles and two user-arranged full reboots.
The other row has `acceptanceHost: false` and requires `launch` and
`document-open-save` checks to pass. Both rows require real evidence references
and timezone-qualified start/end timestamps showing completed testing. An
ad hoc CI smoke test alone is not evidence for the final signed artifact.
