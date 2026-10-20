const assert = require('node:assert/strict');
const { exactDocument, verifyRestoredDocument, isProductionBundle, run } = require('./ci-document-smoke.js');
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

const savedSource = '# Save smoke test\n';
const restored = { file: () => '/private/tmp/fixture.md', source: () => savedSource };
verifyRestoredDocument([unrelated, untitled, restored], '/tmp/fixture.md', normalize, savedSource);
assert.throws(() => verifyRestoredDocument([unrelated], '/tmp/fixture.md', normalize, savedSource));
assert.throws(() => verifyRestoredDocument([restored, restored], '/tmp/fixture.md', normalize, savedSource));
assert.throws(() => verifyRestoredDocument([restored], '/tmp/fixture.md', normalize, savedSource.trimEnd()));
assert.throws(() => verifyRestoredDocument([restored], '/tmp/fixture.md', normalize, null));

// Exercise the actual restored dispatch, including stale PID/path rejection.
// No open/save method exists on the mock: verification must never mutate state.
const appPath = '/isolated/kmd.app';
processes.splice(0, processes.length, {
  bundleIdentifier: 'art.apuch.ksamint.markedit',
  bundleURL: { path: appPath },
  processIdentifier: 103,
});
$.NSWorkspace.sharedWorkspace.runningApplications.count = 1;
global.$ = Object.assign(value => ({ stringByResolvingSymlinksInPath: normalize(value) }), $);
$.NSUTF8StringEncoding = 4;
$.NSString = {
  stringWithContentsOfFileEncodingError(path, encoding) {
    assert.equal(path, '/tmp/fixture.md');
    assert.equal(encoding, 4);
    return savedSource;
  },
};
let documents = [unrelated, untitled, restored];
global.Application = pid => {
  assert.equal(pid, 103);
  return { documents: () => documents };
};
run(['restored', appPath, '103', '/tmp/fixture.md']);
assert.throws(() => run(['restored', appPath, '102', '/tmp/fixture.md']));
assert.throws(() => run(['restored', '/Applications/kmd.app', '103', '/tmp/fixture.md']));
documents = [unrelated];
assert.throws(() => run(['restored', appPath, '103', '/tmp/fixture.md']));
documents = [{ ...restored, source: () => '# wrong document contents\n' }];
assert.throws(() => run(['restored', appPath, '103', '/tmp/fixture.md']));
console.log('Restoration verifies the exact fixture and saved content without opening it.');

const editableFixture = { file: () => '/tmp/fixture.md', source: '' };
const savedPayloads = [];
documents = [unrelated, untitled, editableFixture];
global.Application = pid => {
  assert.equal(pid, 103);
  return {
    documents: () => documents,
    save(document) {
      assert.equal(document, editableFixture);
      savedPayloads.push(document.source);
    },
  };
};
for (let cycle = 1; cycle <= 30; cycle++) {
  const payload = `# Save smoke test: lifecycle ${cycle}/30`;
  run(['save', appPath, '103', '/tmp/fixture.md', payload]);
  assert.equal(editableFixture.source, payload);
}
assert.equal(new Set(savedPayloads).size, 30);
assert.equal(Object.hasOwn(unrelated, 'source'), false);
run(['save', appPath, '103', '/tmp/fixture.md']);
assert.equal(editableFixture.source, '# Save smoke test');
assert.throws(() => run(['save', appPath, '102', '/tmp/fixture.md', 'must not write']));
assert.equal(editableFixture.source, '# Save smoke test');
console.log('All 30 cycle payloads save only the exact fixture; default payload remains supported.');
