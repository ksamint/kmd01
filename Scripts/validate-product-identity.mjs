#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = relativePath => fs.readFileSync(path.join(root, relativePath), 'utf8');
const requireText = (relativePath, expected) => {
  if (!read(relativePath).includes(expected)) {
    throw new Error(`${relativePath} is missing ${JSON.stringify(expected)}`);
  }
};

const buildConfig = read('Build.xcconfig');
const version = buildConfig.match(/^MARKETING_VERSION = (.+)$/m)?.[1];
const build = buildConfig.match(/^CURRENT_PROJECT_VERSION = (.+)$/m)?.[1];
if (!version || !build) throw new Error('Build.xcconfig version is incomplete');

for (const packagePath of [
  'CoreEditor/package.json',
  'WebApp/package.json',
  'AgentSDK/package.json',
  'ResourceModules/package.json',
  'VaultProtocolTS/package.json',
]) {
  const packageVersion = JSON.parse(read(packagePath)).version;
  if (packageVersion !== version) {
    throw new Error(`${packagePath} version ${packageVersion} does not match ${version}`);
  }
}

requireText('Cloud/Cargo.toml', `version = "${version}"`);
requireText('MarkEdit.xcodeproj/project.pbxproj', 'productName = "kmd";');
requireText('MarkEdit.xcodeproj/project.pbxproj', 'PRODUCT_NAME = "kmd";');
requireText('MarkEdit.xcodeproj/project.pbxproj', 'path = "kmd.app";');
requireText('MarkEditMac/Info.plist', '<string>ksamint-markedit</string>');
requireText('Build.xcconfig', 'PRODUCT_BUNDLE_IDENTIFIER = art.apuch.ksamint.markedit$(BUNDLE_ID_SUFFIX)');
requireText('MarkEditMac/Info.entitlements', '<string>group.art.apuch.ksamint-markedit</string>');
for (const target of ['MarkEditMac', 'ConversationCaptureHelper', 'FinderExtension', 'QuickActionExtension']) {
  const entitlements = `${target}/Info.entitlements`;
  if (!/<key>com\.apple\.security\.files\.bookmarks\.app-scope<\/key>\s*<true\s*\/>/.test(read(entitlements))) {
    throw new Error(`${entitlements} must enable persistent security-scoped bookmarks`);
  }
}
requireText('MarkEditMac/Resources/art.apuch.ksamint-markedit.conversation-capture.plist', '<string>Contents/MacOS/kmd</string>');
requireText('.github/workflows/release.yml', 'art.apuch.ksamint.markedit|ksamint MarkEdit Developer ID');

for (const scheme of fs.readdirSync(path.join(root, 'MarkEdit.xcodeproj/xcshareddata/xcschemes'))) {
  if (!scheme.startsWith('MarkEditMac') || !scheme.endsWith('.xcscheme')) continue;
  requireText(`MarkEdit.xcodeproj/xcshareddata/xcschemes/${scheme}`, 'BuildableName = "kmd.app"');
}

const renderedCask = read('Scripts/render-cask.rb');
if (!renderedCask.includes('cask "kmd"') || !renderedCask.includes('app "kmd.app"')) {
  throw new Error('Homebrew cask does not install the renamed app');
}

console.log(`Product identity validation passed for kmd ${version} (${build}).`);
