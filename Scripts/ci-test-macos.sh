#!/bin/bash
set -euo pipefail
os=${1:?usage: ci-test-macos.sh 15\|26}
case "$os" in 15|26) ;; *) exit 2 ;; esac
commit=$(git rev-parse HEAD)
evidence="$RUNNER_TEMP/macos-$os-evidence"
mkdir -p "$evidence"
xcodebuild -version | tee "$evidence/xcode.txt"
sw_vers > "$evidence/macos.txt"
printf '%s\n' "$commit" > "$evidence/commit.txt"
node Scripts/validate-localizations.mjs
node Scripts/validate-product-identity.mjs
Scripts/ci-test-clipboard.sh 2>&1 | tee "$evidence/clipboard.log"
Scripts/test-workspace-bookmarks.sh 2>&1 | tee "$evidence/workspace-bookmarks.log"
Scripts/test-swift-stability.sh 2>&1 | tee "$evidence/stability.log"
xcodebuild build -project MarkEdit.xcodeproj -scheme MarkEditMac \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$RUNNER_TEMP/DerivedData-$os" \
  -resultBundlePath "$evidence/Build.xcresult" \
  MACOSX_DEPLOYMENT_TARGET=15.0 ARCHS="arm64 x86_64" VALID_ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  KSAMINT_BUILD_COMMIT="$commit" CODE_SIGN_IDENTITY='' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 2>&1 | tee "$evidence/build.log"
swift test --package-path MarkEditKit 2>&1 | tee "$evidence/MarkEditKit.log"
for scheme in MarkEditCoreTests ModulesTests; do
  xcodebuild test -project MarkEdit.xcodeproj -scheme "$scheme" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$evidence/$scheme.xcresult" \
    KSAMINT_BUILD_COMMIT="$commit" CODE_SIGN_IDENTITY='' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 2>&1 | tee "$evidence/$scheme.log"
done
app="$RUNNER_TEMP/DerivedData-$os/Build/Products/Release/kmd.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :KSAMINTBuildCommit' "$app/Contents/Info.plist")" = "$commit"
Scripts/verify-universal.sh "$app"
# Ad hoc signing permits CI runtime tests without access to distribution credentials.
codesign --force --deep --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$evidence/kmd-release.zip"
(cd "$evidence" && shasum -a 256 kmd-release.zip > kmd-release.zip.sha256)
CI_ISOLATED_RUNNER=github-hosted Scripts/ci-runtime-smoke.sh "$evidence"
