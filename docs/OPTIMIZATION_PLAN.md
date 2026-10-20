# kmd optimization and stabilization plan

This plan is written for a coding agent (or a developer) to execute end to end:
fix, verify, and ship. It lists what has already landed, what remains, in which
order to do it, how to prove each change, and how to deploy.

Every item below was confirmed by reading the code and, where possible, by
reproducing it with a script. Items marked **unverified** are suspicions that
need a runtime measurement first.

## 0. Ground rules for the executing agent

- Work on a branch from `main`; one logical change per commit.
- Keep each fix minimal and local. Do not widen scope, do not refactor
  unrelated code, do not change user-visible defaults without an issue.
- Prove before pushing. Run the checks in section 5 for every package you
  touch. Swift changes must compile in Xcode 26.6 on macOS 15 or
  newer; there is no Swift toolchain on Linux CI, so a Linux-only agent must
  hand the Swift build step to a macOS runner or a human (see section 6).
- Never skip, disable, or quarantine a test to get green.
- Add a regression test for every correctness fix. Performance fixes get a
  measurement in the PR description (before and after, same input).

## 1. Integrated source baseline (not proof of installation)

Crashes and hangs:
- SIGPIPE ignored at launch; `SO_NOSIGPIPE` on local MCP sockets.
- `EditorDocument.canConcurrentlyReadDocuments` returns `false` (main-actor
  overrides trapped on AppKit's document-opening queue).
- Local MCP accept loop and connections run on dedicated threads; agent CLI
  output is drained on dedicated I/O threads. Blocking reads no longer pin
  cooperative-pool threads.
- Archive listing drains stdout and stderr concurrently, with bounded output and a timeout.

Data loss:
- Vault CBOR encoder uses a growable buffer (was `push(...bytes)`, stack
  overflow near 128 KB).
- Web app: one editor and undo history per note; programmatic `setText` is
  excluded from history and from `onChange`.
- `PendingFileSave.queue` flushes a pending edit for another file.

Performance:
- Workspace sidebar session binding is idempotent; full index rebuilds are
  coalesced and incremental; one SQLite connection per `WorkspaceIndex`;
  link regexes compiled once; search lines folded once; tag lookups batched.
- Activity history kept in memory with a debounced write and a flush on quit.
- Clipboard helper: key and entitlement resolved once; one JSON decoder per
  journal load; palette previews bounded; plain-text pasteboard preferred.
- CoreEditor: selection-aware visual-editing rebuild, single-transaction
  `formatContent`, one scan for the search counter, per-line outline word
  cache, viewport-clamped line decorations, cached inline table cells,
  document sent to completion only when changed.
- Web app: search computed only when the search sidebar is open; one
  IndexedDB connection; sync skips unchanged notes and deletes orphans.

## 2. Remaining work, ordered by user impact

Each item: where, what, fix, how to verify. Do them in this order.

### P1. Rendered preview re-renders the whole document per keystroke
- Where: `CoreEditor/src/@preview/index.ts` (`scheduleRender`),
  `CoreEditor/src/@preview/renderer.ts` (`renderMarkdown`).
- What: `applyChanges` re-parses incrementally (fine) but every render does
  `content.innerHTML = renderMarkdown(source, tree)` for the full document.
  Measured 77 ms per render for a 350 KB document, 130 ms with a 2,000-row
  table. It runs in the preview WKWebView process, so it does not block
  typing, but it burns a core and lags the preview.
- Fix: render per top-level block and cache HTML keyed by
  `(node.name, source.slice(node.from, node.to))`; re-render only blocks
  intersecting the applied `changes` (the renderer already emits
  `data-source-from/to` anchors). Replace children in place instead of
  replacing `innerHTML`.
- Verify: extend `CoreEditor/test/previewRenderer.test.ts` with a
  block-cache test (same output as a full render after an edit in the
  middle). Measure with a 350 KB fixture before and after.

### P2. Edits typed during a sync are overwritten — implemented for 2.5.6
- Where: `WebApp/src/App.tsx` around the sync handler (`setFiles(synchronized)`
  after `flushPendingEdit()` and the network round trip).
- What: the selected note's content captured at click time replaces whatever
  the user typed while the sync ran; the editor is then reset with `setText`.
- Fix: either pass `readOnly={syncing}` to `CoreEditor` (simplest, visible to
  the user), or after sync compare the current editor text with the
  pre-sync snapshot and three-way merge with `mergeMarkdown` from
  `WebApp/src/security/VaultMerge.ts`.
- Verify: unit test around the sync completion path with a changed draft;
  manual check in the PWA with a slow network throttle.

### P3. `files` state churns on every keystroke
- Where: `WebApp/src/App.tsx` (`changeContent`, `graph` memo, `FilesPanel`).
- What: `changeContent` replaces the `files` array per keystroke, so
  `buildGraph` (5 to 70 ms) and the full file list re-render on every key.
- Fix: keep the live editor text out of `files`. Hold it in a `draftContent`
  ref or state, write it into `files` from `PendingFileSave.onSaved`, and
  memoize `fold(path + content)` per `(id, modifiedAt)` inside
  `WebApp/src/search/search.ts`.
- Verify: React profiler before and after on a 500-note workspace; existing
  tests in `WebApp/src` must stay green.

### P4. Conversation import simhash is BigInt per bit
- Where: `WebApp/src/conversation/normalize.ts` (3-gram simhash, `hash128`).
- What: 122 ms per 20 KB conversation, 545 ms per 100 KB, on the main thread,
  once per conversation during `plan()`. A ZIP export with hundreds of
  conversations freezes the tab for minutes.
- Fix: this hash is persisted for dedupe, so changing the function changes
  fingerprints. Safest path: move `parseConversationSource` and `plan()` into
  a Web Worker (keep the algorithm), then optionally introduce a v2 hash with
  `Math.imul` FNV and keep accepting v1 for existing records.
- Verify: import a fixture ZIP with 200 conversations; the UI must stay
  responsive; `WebApp/src/conversation/*.test.ts` stay green.

### P5. File tree loses expansion state and re-stats everything on autosave
- Where: `MarkEditMac/Sources/Editor/Views/WorkspaceSidebarView.swift`
  (`reloadTree`), `MarkEditMac/Sources/Editor/Models/WorkspaceSession.swift`
  (`WorkspaceFilePresenter`, `scheduleRefresh`).
- What: every idle autosave fires `presentedSubitemDidChange`, which rebuilds
  the root `WorkspaceTreeNode` (identity-based, so NSOutlineView forgets
  expansion) and re-enumerates every expanded folder. Moves and renames
  pass the parent directory to `refresh(url:)`, which triggers a full
  rebuild.
- Fix: keep the existing root, `invalidate(recursive:)` only the node for the
  changed URL's parent, then `outlineView.reloadItem(node, reloadChildren:
  true)`; make `WorkspaceTreeNode` equatable by URL. In `scheduleRefresh`,
  for a directory URL refresh its direct children instead of rebuilding.
- Verify: Xcode, expand three folders, type and wait for autosave; the tree
  must keep its expansion. Add a `ModulesTests` case for the index refresh
  path if feasible.

### P6. Knowledge export rereads every permanent clipboard record per copy
- Where: `ConversationCaptureHelper/ClipboardHistory.swift`
  (`ClipboardKnowledgeArchive.reconcile`, `trimmedRecentItems`).
- What: `reconcile` reads every existing `Clip--<id>.md` from disk to compare
  before writing, once per qualifying copy; permanent items are never
  trimmed, so this grows without bound.
- Fix: track changed item IDs since the last reconcile and write only those,
  or compare against a stored `(id, capturedAt, tagIDs, isPinned)`
  fingerprint. Do not add automatic deletion or retention caps for permanent clipboard records.
- Verify: `Scripts/ClipboardHistoryStoreTestMain.swift` (extend it); time
  `reconcile` with 2,000 permanent items.

### P7. Clipboard `record()` copies the whole items array per copy
- Where: `ConversationCaptureHelper/ClipboardHistory.swift` (`record`,
  `rebuildItemIndex`).
- What: `var candidate = items` copies up to 10,000 structs, then
  `rebuildItemIndex` and a `filter(...).count` walk them all, on every copy.
- Fix: first measure; preserve the existing write-failure rollback/data protection,
  then update only the affected item index if justified.
- Verify: same test harness as P6; measure `record` with 10,000 items.

### P8. Search hot path still re-folds candidates per query
- Where: `MarkEditMac/Modules/Sources/SharedUI/WorkspaceIndex.swift`
  (`searchGroup`, `resultLines`).
- What: up to 500 candidate bodies are loaded and folded line by line per
  keystroke (120 ms debounce). The `folded` column already exists.
- Fix: use FTS5 `highlight()` or `instr()` on the stored folded text to find
  matching line offsets, and only load bodies for the files that will be
  shown.
- Verify: `MarkEditMac/Modules/Tests/WorkspaceIndexTests.swift`; measure a
  three-term query on 2,000 notes.

### P9. Line-number gutter forces a reflow per visible heading (unverified)
- Where: `CoreEditor/src/modules/lines/index.ts` (`adjustGutterPositions`).
- What: interleaves `getComputedStyle`/`getBoundingClientRect` reads with
  `style.paddingTop` writes per heading on every geometry update.
- Fix if confirmed: batch all reads, then all writes.
- Verify: Safari Web Inspector timeline while scrolling a document with
  many headings and line numbers on.

### P10. Semantic search worker runs overlapping index jobs (unverified)
- Where: `WebApp/src/search/SemanticSearchWorker.ts`.
- What: two `index` messages interleave; the last to finish wins and ONNX
  work is doubled.
- Fix if confirmed: queue index requests and drop superseded ones.

## 3. Items examined and deliberately left alone

- `editorCoreCompositionEnded` calling `renderCurrent()`: fires once per IME
  composition, not per caret move, and the preview skips rendering while
  composing, so this call is required.
- `AppDocumentController` `DispatchQueue.main.sync` hops: safe as long as no
  caller waits synchronously on the document-opening queue from main; none
  does today. Do not add one.
- The 0.75 s / 2 s pasteboard polling timers: macOS has no change
  notification; the cost per change was reduced instead.
- `LocalMCPServer` creating a second `WorkspaceIndex` on the same database
  for the Agent panel: now cheap because rebuilds are incremental. If
  contention shows up (`SQLITE_BUSY` in logs), pass the session's index in.

## 4. Stability release 2.5.6 (19)

Development and release repository: `ksamint/kmd01`. The integration branch
`codex/stabilize-2.5.6` includes PR #14, the four installed-only fixes
(4ecbf6c, 05a1f10, 0d388e1, 40bac91), and the previously uncommitted bookmark
entitlements / manifest cleanup patches. Original worktrees remain intact.

The actual installed baseline is still **2.5.5 (18), 40bac9139f371e808cc861480a7afe65d109f6d7**.
“Implemented”, “tested”, and “installed” are separate states. No candidate is
accepted until the signed runtime matrix and 24-hour observation are complete.

CI uses `ubuntu-24.04`; relevant Mac/shared/config/script/workflow changes
select macOS 26 / Xcode 26.6 and macOS 15 / Xcode 26.3 automatically.
Pushes to main and manual dispatch run all checks. `Release readiness` always
runs and fails for missing, cancelled, failed, or unexpectedly skipped jobs.
The same macOS 26 Universal build is exercised on macOS 15 ARM64 and Intel.
Unsigned/ad hoc CI runtime is isolated and does not prove grant persistence.
PR jobs have no signing credentials. Signing requires protected main, an exact
commit, and successful full main CI for that commit.

The local macOS host has Command Line Tools only. Standalone Swift compilation
is useful evidence but does not replace the full app/Swift-package Xcode tests.

Current source changes include serialized sync writes, a visible read-only
sync interval, retained failed pending edits, network cancellation/deadline,
manifest-before-orphan cleanup, document lifecycle isolation, concurrent archive
pipe draining, bounded MCP shutdown, and Agent cancellation/process cleanup.
Persistent authorization additionally requires Apple-issued App Group profiles
and correct cross-process transfer; copying app-scoped bookmarks is insufficient.

See [the acceptance ledger](STABILITY_2.5.6.md) for actual evidence and blockers.

## 5. Verification commands

Node 24.19 (`.node-version`), Rust 1.97.1 for the cloud workspace.

```sh
# CoreEditor (editor engine)
cd CoreEditor && corepack enable && yarn install --immutable && yarn build && yarn test

# Web PWA, shared vault protocol, Mac web bundle
cd WebApp && npm ci && npm run lint && npm test && npm run build && npm run build:mac && npm run validate:mac-bundle

# Agent SDK and resource modules
cd AgentSDK && npm ci && npm run lint && npm test && npm run build
cd ResourceModules && npm ci && npm run verify

# Localization and identity
node Scripts/validate-localizations.mjs && node Scripts/validate-product-identity.mjs

# Cloud (Rust)
cd Cloud && cargo fmt --all -- --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace

# Mac app (macOS with Xcode 26.6; compatibility with Xcode 26.3)
xcodebuild build -project MarkEdit.xcodeproj -scheme MarkEditMac -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
swift test --package-path MarkEditKit
xcodebuild test -project MarkEdit.xcodeproj -scheme ModulesTests -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
Scripts/test-document-open-smoke.sh
```

Smoke checks on a built app, in this order:
1. Open a workspace with 1,000+ notes; toggle the sidebar modes repeatedly;
   the index must rebuild once, not per toggle (watch the status text).
2. Type with the outline sidebar and the rendered preview open; no stutter.
3. Open the Agent panel, start a tool call, press Cancel; the app must stay
   alive and the panel must report the cancellation.
4. Quit with "reopen windows" on and an unsaved draft; relaunch; no crash.
5. Finder quick action "Convert to Markdown" on a ZIP with 5,000 entries.
6. Copy a long selection from Safari with clipboard capture on; the palette
   must not stall.
7. Web PWA: edit note A, open note B, press Undo; B must be unchanged.
8. Web PWA: sync a note over 200 KB; it must upload.

## 6. Signed candidate and release

1. Merge the integration PR only after all required checks pass. Keep all
   production identifiers, Team ID, App Group and keychain group unchanged.
2. Use the `release` environment on protected main. Generate a Developer ID
   profile for each component; four profiles must explicitly authorize the
   existing `group.art.apuch.ksamint-markedit` group. Validate final signed
   entitlements, profile expiry, bundle identities, nested SHA, version and
   architecture with `Scripts/verify-release-app.sh`.
3. Formal builds use Xcode 26.6 and Universal architecture. Preserve the 6 MiB
   DMG size gate; do not silently weaken it if the first Universal build fails.
4. Sign, notarize, staple, and verify the candidate. Keep a draft until runtime
   acceptance is complete. `finalize-release.yml` no longer publishes solely
   because notarization is accepted.
5. Test in an isolated account/workspace first. Back up the installed App and
   necessary data with restricted permissions; request normal quit, and defer
   installation if any unsaved document keeps the App running. This Mac runs
   only the production signed `/Applications/kmd.app`.
6. Record exact artifact SHA256s, commit, evidence, 30 lifecycle cycles, 10
   quit/relaunch cycles, logout/login, two full user-arranged reboots, same-
   identity upgrade and at least 24 hours of use on macOS 15 and 26 in
   `docs/release-acceptance/v2.5.6.json`. Use schema 1 with `approved`, `reviewer`,
   `commit`, `artifacts` (all four final asset basename/hash pairs), and `systems`
   entries required by `Scripts/ci-release-gates.py`. Do not fabricate a record
   or automatically reboot the user's Mac.
7. Merge the evidence/acceptance record through the protected PR process.
   Finalize publishes the accepted exact bytes and updates the cask only after
   the record passes. No rebuild may substitute a different artifact.
8. On regression, stop promotion and restore the previous App, preserving new
   user data and diagnostic evidence. Never overwrite new databases with an old
   backup as an application rollback.

No public API, file-format or encryption-format changes, and no data migration.
Performance P1 and P3–P10 remain future work; P9/P10 require reproduction first.

## 7. Definition of done

- Full exact-commit CI, including both Xcode versions, passes.
- The production signed candidate passes every runtime/authorization/data
  scenario in the acceptance ledger; no new main/helper crash reports occur.
- SHA256, nested signing identities/profiles, architecture, Gatekeeper,
  notarization and staple evidence is saved and matches the published bytes.
- “Repeated authorization solved” is not recorded before the reboot matrix.
