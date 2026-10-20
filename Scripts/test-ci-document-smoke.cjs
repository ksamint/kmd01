const assert = require('node:assert/strict');
const { exactDocument, isProductionBundle, run } = require('./ci-document-smoke.js');
const fixture = { file: () => '/isolated/fixture.md' };
const unrelated = { file: () => '/real-user/notes.md' };
const untitled = { file: () => null };
const normalize = value => value.replace('/private/tmp/', '/tmp/');
assert.equal(exactDocument([unrelated, untitled, fixture], '/isolated/fixture.md', normalize), fixture);
assert.throws(() => exactDocument([unrelated, untitled], '/isolated/fixture.md', normalize));
assert.throws(() => exactDocument([fixture, fixture], '/isolated/fixture.md', normalize));
const symlinked = { file: () => '/private/tmp/fixture.md' };
assert.equal(exactDocument([symlinked], '/tmp/fixture.md', normalize), symlinked);
console.log('Dedicated smoke document selection tests passed.');

assert.equal(isProductionBundle('art.apuch.ksamint.markedit'), true);
assert.equal(isProductionBundle('art.apuch.ksamint.markedit.conversation-capture-helper'), true);
assert.equal(isProductionBundle('art.apuch.ksamint.markedit.dev'), false);
assert.equal(isProductionBundle('art.apuch.ksamint.markedit.conversation-capture-helper.dev'), false);
assert.equal(isProductionBundle('com.unrelated.ConversationCaptureHelper'), false);
console.log('Exact production bundle selection tests passed.');

// Mock AppKit to exercise PID selection without touching real applications.
const stopped = [];
const extensionPath = '/Applications/kmd.app/Contents/PlugIns/PreviewExtension.appex';
const process = pid => ({
  bundleIdentifier: 'art.apuch.ksamint.markedit.preview-extension',
  bundleURL: { path: extensionPath },
  processIdentifier: pid,
  get terminate() { stopped.push(pid); return true; },
});
const processes = [process(101), process(102)];
global.ObjC = { import() {}, unwrap: value => value };
global.$ = value => ({ stringByResolvingSymlinksInPath: value });
$.NSWorkspace = { sharedWorkspace: { runningApplications: {
  count: processes.length, objectAtIndex: index => processes[index],
} } };
$.NSRunningApplication = { runningApplicationWithProcessIdentifier: pid => processes.find(item => item.processIdentifier === pid) };
run(['quit', extensionPath, '102']);
assert.deepEqual(stopped, [102]);
assert.throws(() => run(['quit', extensionPath, '999']));
assert.throws(() => run(['quit', '/Applications/unrelated.app', '101']));
assert.deepEqual(stopped, [102]);
console.log('Graceful shutdown selects only the exact bundle and PID.');
