# kmd

[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-0F4B42)](https://github.com/ksamint/kmd01/releases/latest)
[![Build and test](https://github.com/ksamint/kmd01/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/ksamint/kmd01/actions/workflows/build-and-test.yml)

kmd is a fast, native Markdown editor for macOS with first-class
Simplified Chinese, Traditional Chinese, Japanese, and French interfaces.
It is an independent localization-focused fork of
[MarkEdit](https://github.com/MarkEdit-app/MarkEdit).

The editor remains small and responsive because localization is compiled into
Apple string catalogs and macOS supplies language selection, spellchecking,
tokenization, and input methods. The CodeMirror editing engine and extension
API stay compatible with upstream MarkEdit.

## Features

- Native AppKit and SwiftUI interface
- Automatic macOS and per-app language selection
- Chinese and Japanese IME-aware editing
- UTF-8, GB 18030, Big 5, EUC-JP, Shift JIS, and other native encodings
- GFM-compatible Markdown powered by CodeMirror 6
- Local workspace tree, global Unicode search, tags, categories, backlinks, and graph
- Optional Mac on-device Deep Search with a separately downloaded multilingual model
- Offline Web PWA workspace using OPFS with an IndexedDB fallback
- Opt-in local MCP tools constrained to one authorized workspace
- Lazy local Codex and Claude Code Agent panel with read-only defaults and diff-gated writes
- Signed, on-demand Folder, safe HTML, OKF, MinerU, ZIP, TAR, and TGZ resource previews
- Optional Passkey account and zero-knowledge encrypted backup protocol
- Tencent COS encrypted object and manifest synchronization
- Independent ARM64 `ksamint-vault` recovery CLI
- Shared TypeScript vault protocol and expiring read-only Agent SDK
- Finder and Quick Look extensions
- Shortcuts, AppleScript, and JavaScript extension support
- Apple Silicon ARM64 build (Intel is not included in v2.5)

## Installation

The signed and notarized ARM64 release supports Apple Silicon Macs running
macOS 15 or later:

```sh
brew install --cask fengurt/ksamint/kmd
open -a "kmd"
```

Alternatively, download `ksamint-MarkEdit-<version>.dmg` from the
[latest GitHub release](https://github.com/ksamint/kmd01/releases/latest).

Pull requests also produce an ARM64, ad-hoc-signed development artifact.
Download `ksamint-MarkEdit-development` from the successful GitHub Actions run,
unzip it, and copy `kmd.app` into `~/Applications`.

## Local MCP

The Mac app can serve its current local-first knowledge tools over stdio without
starting the GUI. MCP is disabled unless the executable is explicitly launched
with `--mcp-stdio`, and writes require the separate `--allow-write` opt-in.

```json
{
  "mcpServers": {
    "ksamint-markedit": {
      "command": "/Applications/kmd.app/Contents/MacOS/kmd",
      "args": ["--mcp-stdio", "--workspace", "/absolute/path/to/notes"]
    }
  }
}
```

`set_tags`, `set_category`, and `move_to_trash` additionally require
`confirmed: true` on each call. Paths and symlinks cannot escape the selected
workspace, and writes append to `.ksamint/audit.log`.

## Local CLI Agent Bridge

Open the optional right Agent panel with `Command-Option-A`. The app detects an
existing `codex` or `claude` executable only after the panel is opened and reuses
that CLI's own login, MCP, plugin, and connector configuration. It never stores
or forwards API keys.

Codex is started through `codex app-server`; Claude Code uses its streaming JSON
input and output mode. Both run with read-only or planning defaults. Network and
external tool requests remain subject to the CLI approval protocol, while file
insertion, creation, patching, tags, and categories always require a visible
diff and an additional confirmation in MarkEdit.

While the panel is open, the app exposes its 14 workspace tools plus five
read-only resource tools through a permission-`0600` Unix socket protected by a
random 256-bit capability. It does not listen on TCP. Resource reads are limited
to 10 MiB per call and their contents are marked as untrusted data. Cancel first
sends the provider's protocol interruption and then terminates the process group
if the CLI does not stop within the grace period.

Agent output remains temporary until you explicitly insert it, save it as
Markdown, or save an OKF-compatible `Reference` snapshot. Confirmed actions are
recorded in `.ksamint/agent-drafts.jsonl`.

## Private cloud and recovery

Cloud features are optional and default to off. The Mac app remains fully
functional without an account. When enabled, Markdown, paths, attachments,
vector shards, and manifests are encrypted on the device before upload; the
service receives only ciphertext and synchronization metadata.

The versioned Rust protocol, Passkey/Axum API, Tencent STS integration,
GitHub App token broker, deployment files, and independent recovery CLI live in
[`Cloud`](Cloud/README.md). Permanent provider credentials are never embedded
in the app or Web PWA.

The v2.5 code line authorizes a new browser with a five-minute, signed device
grant from an existing Vault device, or with the 24-word package generated from
the active Vault Master Key. Both devices independently derive the displayed
eight-digit verification code from the enrollment keys. Device sessions are
short lived and revocation immediately removes manifest, object, and STS
access. First sync is blocked until the recovery package has been downloaded
and four random words have been verified.

Encrypted GitHub snapshots are queued after every accepted manifest and batched
for five minutes. GitHub installation tokens remain on the service; the backup
branch contains only encrypted Markdown objects, a signed manifest, and an
opaque recovery catalog. The Web history view decrypts a selected snapshot on
the device and offers current, historical-as-new-version, keep-both, and merge
choices without rewriting Git history. Message-level Claude and ChatGPT
attachments are content-addressed, shown in the import preview, and can be
selected independently from the original export package.

Web Deep Search is opt-in and lazy. It downloads a checksum-pinned,
first-party-hosted multilingual E5 model only after confirmation, uses WebGPU
with a WASM SIMD fallback, stores Float16 shards in OPFS, reuses unchanged
embeddings, and uses an HNSW graph for larger workspaces. The initial PWA shell
does not contain the model or ONNX runtime worker.

The Mac v2.5 targets include an independent sandboxed clipboard Login Item, a
workspace-scoped Finder Sync menu, and a Finder Quick Action for selections
outside the workspace. These components share only signed App Group requests;
scanning, Agent access, conversion, and writes happen in the main app. Local
text, HTML, structured data, directory, and ZIP/TAR manifest conversion is
implemented. PDF/image conversion remains disabled unless a Tencent-hosted
MinerU Precision VLM provider using the audited Data Merge wrapper is configured;
there is no tokenless or lower-quality fallback.

Clipboard capture is opt-in under **Settings › General**. When enabled, its
sandboxed Login Item shows a menu-bar control, saves high-confidence
conversations immediately under `Conversations`, and keeps other captures in a
device-local encrypted review queue for 30 days. The Hub opens activity history
by default for a blank window and links directly to capture history and its
workspace-wide search. The cloud interval affects only encrypted sync; local
capture is immediate.

Finder integration includes **New Markdown File**, local **Convert to
Markdown**, and **Convert Markdown to DOCX**. DOCX export requires explicit
upload confirmation and a Datamerge `standard` key stored in the user's macOS
Keychain. The production admin key is used only to provision that restricted
credential through the Datamerge Admin API and is never embedded in the app,
preferences, logs, or repository.

The Web PWA encrypts files and paths before direct upload. It can import
Markdown, UTF-8 text, and safe HTML from files, complete browser-selected
folders, drag and drop, or credential-free HTTPS URLs. Imports are stored in
OPFS with the encrypted IndexedDB fallback and never overwrite an existing
path.

On a remote head change the PWA verifies and decrypts the new snapshot locally,
performs a three-way Markdown merge, and creates timestamped conflict copies
for overlapping edits or delete/edit races instead of silently overwriting
either side. An encrypted local conflict ledger retains the common ancestor,
this-device version, remote version, and resolution. The compare UI can retain
either side, combine both, or save a manually edited result; resolving never
deletes the preserved source versions. The shared
`@ksamint/vault-protocol` package keeps deterministic CBOR and cryptographic
test vectors aligned with Rust. `@ksamint/agent-sdk` verifies signed manifests
and decrypts an explicit, expiring read-only capability inside the Agent
process; the server never receives plaintext searches or keys.

## Language review

Every translatable catalog entry is validated for completeness and placeholder
safety in CI. Japanese and French translations are published only after an
explicit native-language review. Translation corrections are welcome through
the [issue tracker](https://github.com/ksamint/kmd01/issues).

## Compatibility

- Deep links use `ksamint-markedit://` so the fork can coexist with MarkEdit.
- Bundle IDs, exported UTIs, containers, and preferences use the
  `art.apuch.ksamint.markedit` namespace.
- The `MarkEdit` JavaScript API, extension registry, AppleScript commands, and
  supported Markdown formats remain compatible with the upstream ecosystem.

Upstream customization and usage documentation remains applicable:
[manual](https://github.com/MarkEdit-app/MarkEdit/wiki/Manual),
[customization](https://github.com/MarkEdit-app/MarkEdit/wiki/Customization),
and [extensions](https://markedit-app.github.io/extensions/).

## Development

The project contains:

- `CoreEditor`: TypeScript, CodeMirror 6, Lezer, Vite, and Jest
- `MarkEditCore` and `MarkEditKit`: shared Swift packages
- `MarkEditMac`: the native macOS app and feature modules
- `MarkEditMac/Modules/ResourceCore` and `ResourceUI`: signed, isolated,
  read-only resource module protocol, filesystem broker, and lazy WKWebView host
- `ResourceModules`: separately signed Folder, safe HTML, Google OKF, MinerU,
  and ZIP/TAR/TGZ preview modules. The signed OKF, safe HTML, and archive
  modules are bundled as offline fallbacks; Folder, MinerU, and newer module
  versions remain separately downloadable.
- `WebApp`: the shared React/Vite offline knowledge workspace
- `VaultProtocolTS`: shared TypeScript deterministic-CBOR and vault crypto
- `AgentSDK`: remote read-only, client-side-decrypting Agent SDK
- `FinderExtension` and `PreviewExtension`: native system integrations

Use Node.js 24.19 and Xcode 26.6:

```sh
cd CoreEditor
corepack enable
yarn install --immutable
yarn build
yarn test
cd ..
node Scripts/validate-localizations.mjs
cd WebApp
npm ci
npm run build
npm run build:mac
npm run validate:mac-bundle
cd ..
xcodebuild build -project MarkEdit.xcodeproj -scheme MarkEditMac -destination 'platform=macOS'
```

Verify the separately distributed resource modules and their archive security
tests with:

```sh
cd ResourceModules
npm run verify
```

The app creates no module WebView or worker until the user opens a matching
resource. Bundled OKF, safe HTML, and archive modules work offline on first
use. A newer or separately distributed module is downloaded only after the
user approves its displayed name, version, and size. Every manifest has a
P-256 signature and every static asset has a SHA-256 hash. Modules run in a
non-persistent, network-disabled WebKit process and receive only paginated
directory metadata or bounded byte ranges from the selected resource.
Resource containers can be opened from File > Open Resource, the Recent
Resources submenu, or by dropping a folder, archive, HTML, or OKF resource onto
an editor window. Ordinary image and PDF drops retain their Markdown behavior.

## Branding and license

The ksamint / 查明 identity and mint/deep-green theme follow the current
[APUCH brand directory](https://apuch.art/brand?brand=ksamint). The black-and-white
paw holding bamboo app icon remains the current shipping artwork while a more
abstract `kmd` paw mark is reviewed separately.

kmd is distributed under the MIT License. The fork is based on
MarkEdit by Ying Zhong and its contributors; upstream copyright and license
notices are preserved. Built with
[CodeMirror 6](https://codemirror.net/) and
[ts-gyb](https://github.com/microsoft/ts-gyb).
