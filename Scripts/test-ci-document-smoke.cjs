const assert = require('node:assert/strict');
const {
  exactDocument, verifyRestoredDocument, saveExactDocument, requireAutomationPermission,
  exactAXWindow, exactAXEditor, operateAXDocument, copyFocusedSource, isProductionBundle, run,
  diagnosticWindowIDs,
} = require('./ci-document-smoke.js');
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
global.ObjC = { import() {}, unwrap: value => value, bindFunction() {} };
global.$ = value => ({ stringByResolvingSymlinksInPath: value });
$.NSWorkspace = { sharedWorkspace: { runningApplications: {
  count: processes.length, objectAtIndex: index => processes[index],
} } };
$.NSRunningApplication = { runningApplicationWithProcessIdentifier: pid => processes.find(item => item.processIdentifier === pid) };
$.NSAppleEventDescriptor = { descriptorWithProcessIdentifier: pid => ({ aeDesc: { pid } }) };
let automationStatus = 0;
$.AEDeterminePermissionToAutomateTarget = (target, eventClass, eventID, askUser) => {
  assert.equal(target.pid, 103);
  assert.equal(eventClass, 0x2a2a2a2a);
  assert.equal(eventID, 0x2a2a2a2a);
  assert.equal(askUser, false);
  return automationStatus;
};
assert.equal(run(['running-production']), [
  `101\t${extensionPath}\tart.apuch.ksamint.markedit.preview-extension`,
  `102\t${extensionPath}\tart.apuch.ksamint.markedit.preview-extension`,
].join('\n'));
console.log('Production inventory retains both executing instances of an embedded extension.');
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

for (const denied of [-1743, -1744, -600]) {
  automationStatus = denied;
  const traces = [];
  assert.throws(() => requireAutomationPermission(103, stage => traces.push(stage)), new RegExp(String(denied)));
  assert.deepEqual(traces, ['automation:preflight', `automation:status=${denied}`]);
  global.Application = () => { throw new Error('must not connect without automation permission'); };
  assert.throws(() => run(['save', appPath, '103', '/tmp/fixture.md', 'must not write']), new RegExp(String(denied)));
  assert.equal(editableFixture.source, '# Save smoke test');
}
automationStatus = 0;
const stages = [];
saveExactDocument({
  documents: () => [editableFixture],
  save(document) { assert.equal(document, editableFixture); },
}, '/tmp/fixture.md', normalize, 'diagnostic fixture', stage => stages.push(stage));
assert.deepEqual(stages, ['documents:query', 'fixture:select', 'source:set', 'document:save', 'document:saved']);
console.log('Nonprompting automation preflight fails closed and save diagnostics identify each event stage.');

function attribute(value, writable = false) {
  let stored = value;
  const result = { settable: () => writable };
  Object.defineProperty(result, 'value', {
    get: () => () => stored,
    set: next => { assert.equal(writable, true); stored = next; },
  });
  return result;
}
function axNode(role, values) {
  return {
    role: () => role,
    attributes: { byName: name => {
      if (!values[name]) throw new Error('unsupported attribute');
      return values[name];
    } },
  };
}
const axText = attribute(savedSource, true);
const axEditor = axNode('AXTextArea', { AXValue: axText });
let focused = false;
Object.defineProperty(axEditor, 'focused', { get: () => () => focused, set: value => { focused = value; } });
const wrapper = axNode('AXTextArea', {}); // Native WKWebView can have the same AX role.
let raised = 0;
const axDocument = attribute('/private/tmp/fixture.md');
const axWindow = Object.assign(axNode('AXWindow', { AXDocument: axDocument }), {
  entireContents: () => [wrapper, axEditor],
  sheets: () => [],
  actions: { byName(name) { assert.equal(name, 'AXRaise'); return { perform() { raised++; } }; } },
});
const unrelatedWindow = axNode('AXWindow', { AXDocument: attribute('/private/tmp/unrelated.md') });
assert.equal(exactAXWindow([unrelatedWindow, axWindow], '/tmp/fixture.md', normalize), axWindow);
assert.throws(() => exactAXWindow([unrelatedWindow], '/tmp/fixture.md', normalize));
assert.throws(() => exactAXWindow([axWindow, axWindow], '/tmp/fixture.md', normalize));
assert.equal(exactAXEditor(axWindow, () => {}), axEditor);
assert.throws(() => exactAXEditor({ entireContents: () => [axEditor, axEditor] }, () => {}));
assert.throws(() => exactAXEditor({ entireContents: () => Array(257).fill(wrapper) }, () => {}));

let frontmost = false;
let activeWindow = axWindow;
const axProcess = Object.assign(axNode('AXApplication', { AXFocusedWindow: {
  value: () => activeWindow,
} }), { unixId: () => 103, windows: () => [unrelatedWindow, axWindow] });
Object.defineProperty(axProcess, 'frontmost', { get: () => () => frontmost, set: value => { frontmost = value; } });
const keystrokes = [];
let editorSource = savedSource;
let clipboardText = '';
let clipboardGeneration = 0;
$.NSPasteboardTypeString = 'public.utf8-plain-text';
$.NSPasteboard = { generalPasteboard: {
  get clearContents() { clipboardText = ''; return ++clipboardGeneration; },
  get changeCount() { return clipboardGeneration; },
  setStringForType(text) { clipboardText = text; clipboardGeneration++; return true; },
  stringForType() { return clipboardText; },
} };
global.delay = () => {};
const systemEvents = { keystroke: (...args) => {
  keystrokes.push(args);
  if (args[0] === 'c') { clipboardText = editorSource; clipboardGeneration++; }
  if (args[0] === 'v') editorSource = clipboardText;
} };
axWindow.entireContents = () => {
  assert.ok(raised > 0, 'Raise the exact restored window before querying its WebKit subtree');
  return [wrapper, axEditor];
};
// AX layout text may add a newline; only the normal copy path is the source oracle.
axText.value = savedSource + '\n';
operateAXDocument(systemEvents, axProcess, 103, '/tmp/fixture.md', normalize, savedSource, undefined, () => {});
assert.equal(editorSource, savedSource);
assert.deepEqual(keystrokes.map(args => args[0]), ['a', 'c']);
keystrokes.length = 0;
assert.throws(() => operateAXDocument(systemEvents, axProcess, 999, '/tmp/fixture.md', normalize, savedSource, 'wrong', () => {}));
activeWindow = unrelatedWindow;
assert.throws(() => operateAXDocument(systemEvents, axProcess, 103, '/tmp/fixture.md', normalize, savedSource, 'wrong', () => {}));
assert.equal(editorSource, savedSource);
assert.equal(keystrokes.length, 0);
activeWindow = axWindow;
operateAXDocument(systemEvents, axProcess, 103, '/tmp/fixture.md', normalize, savedSource, '# new UI fixture', () => {});
assert.equal(editorSource, '# new UI fixture');
assert.deepEqual(keystrokes.map(args => args[0]), ['a', 'c', 'v', 'a', 'c', 's']);
assert.throws(() => operateAXDocument(systemEvents, axProcess, 103, '/tmp/fixture.md', normalize, savedSource, undefined, () => {}));
assert.throws(() => copyFocusedSource({ keystroke() {} }, () => {}), /did not copy/);
assert.throws(() => copyFocusedSource(systemEvents, () => { throw new Error('lost focus'); }), /lost focus/);
console.log('AX fallback verifies exact PID/document/focus and full copied text; restore never opens or edits.');

// Exercise fallback dispatch and its separate permission boundary, never a
// blanket retry through System Events after an arbitrary scripting error.
$.NSProcessInfo = { processInfo: { environment: {
  objectForKey: key => ({ GITHUB_ACTIONS: 'true', CI_ISOLATED_RUNNER: 'github-hosted' }[key]),
} } };
$.NSDictionary = { dictionary: {} };
$.NSWorkspaceLaunchWithoutActivation = 512;
$.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier = bundle => {
  assert.equal(bundle, 'com.apple.systemevents');
  return 'system-events-url';
};
$.NSWorkspace.sharedWorkspace.launchApplicationAtURLOptionsConfigurationError = (url, options) => {
  assert.equal(url, 'system-events-url');
  assert.equal(options, 512);
  return { bundleIdentifier: 'com.apple.systemevents', processIdentifier: 500 };
};
let eventsPermission = -1744;
$.AEDeterminePermissionToAutomateTarget = (target, _eventClass, _eventID, askUser) => {
  assert.equal(askUser, false);
  return target.pid === 103 ? -1744 : eventsPermission;
};
global.Application = () => { throw new Error('must not query System Events before its grant is checked'); };
assert.throws(() => run(['save', appPath, '103', '/tmp/fixture.md', 'blocked']), /-1744/);
eventsPermission = 0;
global.Application = pid => {
  assert.equal(pid, 500);
  return { uiElementsEnabled: () => false };
};
assert.throws(() => run(['save', appPath, '103', '/tmp/fixture.md', 'blocked']), /Accessibility permission/);
axText.value = savedSource;
editorSource = savedSource;
global.Application = pid => {
  assert.equal(pid, 500);
  return {
    ...systemEvents, uiElementsEnabled: () => true,
    processes: { whose(query) { assert.deepEqual(query, { unixId: 103 }); return () => [axProcess]; } },
  };
};
run(['save', appPath, '103', '/tmp/fixture.md', '# granted UI fixture']);
assert.equal(editorSource, '# granted UI fixture');
console.log('System Events fallback checks its own nonprompting grant and existing AX permission.');

const diagnosticWindow = { kCGWindowOwnerPID: 103, kCGWindowLayer: 0,
  kCGWindowIsOnscreen: true, kCGWindowNumber: 42 };
assert.equal(diagnosticWindowIDs([diagnosticWindow,
  { ...diagnosticWindow, kCGWindowOwnerPID: 999 },
  { ...diagnosticWindow, kCGWindowLayer: 1 },
  { ...diagnosticWindow, kCGWindowIsOnscreen: false }], 103), '42');
assert.throws(() => diagnosticWindowIDs([{ ...diagnosticWindow, kCGWindowNumber: '42' }], 103), /Invalid/);
assert.throws(() => diagnosticWindowIDs(Array(9).fill(diagnosticWindow), 103), /Too many/);
$.CGPreflightScreenCaptureAccess = () => false;
$.CGWindowListCopyWindowInfo = () => { throw new Error('Must not query windows without existing capture access'); };
assert.equal(run(['diagnostic-window-ids', appPath, '103']), '');
$.CGPreflightScreenCaptureAccess = () => true;
$.kCGWindowListOptionOnScreenOnly = '1';
ObjC.deepUnwrap = value => value;
$.CGWindowListCopyWindowInfo = (option, relativeWindow) => {
  assert.equal(option, '1');
  assert.equal(relativeWindow, 0);
  return [diagnosticWindow, { ...diagnosticWindow, kCGWindowOwnerPID: 999 }];
};
assert.equal(run(['diagnostic-window-ids', appPath, '103']), '42');
$.NSProcessInfo.processInfo.environment.objectForKey = () => undefined;
assert.throws(() => run(['diagnostic-window-ids', appPath, '103']), /isolated hosted runner/);
console.log('Window diagnostics are nonprompting, hosted-only and limited to exact-PID visible application windows.');
