function exactDocument(documents, fixture, normalize) {
  const matches = documents.filter(document => {
    const file = document.file();
    return file && normalize(String(file)) === fixture;
  });
  if (matches.length !== 1) throw new Error('Expected exactly one dedicated fixture document');
  return matches[0];
}

function verifyRestoredDocument(documents, fixture, normalize, expectedSource) {
  const document = exactDocument(documents, fixture, normalize);
  if (typeof expectedSource !== 'string' || document.source() !== expectedSource) {
    throw new Error('Restored fixture source differs from the saved file');
  }
}

function saveExactDocument(app, fixture, normalize, source, trace) {
  trace('documents:query');
  const documents = app.documents();
  trace('fixture:select');
  const document = exactDocument(documents, fixture, normalize);
  trace('source:set');
  document.source = source;
  trace('document:save');
  app.save(document);
  trace('document:saved');
}

function requireAutomationPermission(pid, trace) {
  // The native signature takes const AEAddressDesc*. Binding it as an opaque
  // pointer avoids JXA's incompatible AEDesc/AEAddressDesc typedef metadata.
  ObjC.bindFunction('AEDeterminePermissionToAutomateTarget',
    ['int', ['void *', 'unsigned int', 'unsigned int', 'bool']]);
  const target = $.NSAppleEventDescriptor.descriptorWithProcessIdentifier(pid);
  const typeWildCard = 0x2a2a2a2a;
  trace('automation:preflight');
  const status = $.AEDeterminePermissionToAutomateTarget(
    target.aeDesc, typeWildCard, typeWildCard, false,
  );
  trace(`automation:status=${status}`);
  if (status !== 0) {
    const error = new Error(`Automation unavailable (OSStatus ${status}); no consent was requested`);
    error.automationStatus = status;
    throw error;
  }
}

function axValue(element, name) {
  try { return element.attributes.byName(name).value(); } catch (_) { return undefined; }
}

function exactAXWindow(windows, fixture, normalize) {
  const matches = windows.filter(window => {
    const document = axValue(window, 'AXDocument');
    return typeof document === 'string' && normalize(document) === fixture;
  });
  if (matches.length !== 1) throw new Error(`Expected one exact AXDocument window; found ${matches.length}`);
  return matches[0];
}

function exactAXEditor(window, expectedSource, trace) {
  const elements = window.entireContents();
  if (!Array.isArray(elements) || elements.length > 256) throw new Error('AX document subtree exceeds diagnostic bound');
  const roles = {};
  const matches = [];
  for (const element of elements) {
    const role = element.role();
    roles[role] = (roles[role] || 0) + 1;
    if (role !== 'AXTextArea') continue;
    const value = axValue(element, 'AXValue');
    let settable = false;
    try { settable = element.attributes.byName('AXValue').settable(); } catch (_) {}
    trace(`ax:text-area length=${typeof value === 'string' ? value.length : 'unavailable'} settable=${settable}`);
    if (typeof value === 'string' && value === expectedSource && settable === true) matches.push(element);
  }
  trace(`ax:roles=${JSON.stringify(roles)}`);
  // The native WebView wrapper and inner CodeMirror editor may both expose a
  // text-area role. Never select by role/order alone or accept partial text.
  if (matches.length !== 1) throw new Error(`Expected one writable full-text AX editor; found ${matches.length}`);
  return matches[0];
}

function operateAXDocument(events, process, pid, fixture, normalize, expectedSource, newSource, trace) {
  if (process.unixId() !== pid) throw new Error('AX process identity changed');
  const window = exactAXWindow(process.windows(), fixture, normalize);
  const editor = exactAXEditor(window, expectedSource, trace);
  if (newSource === undefined) {
    trace('ax:restoration-verified');
    return; // No open, focus, selection, clipboard, or other mutation on restore.
  }
  if (window.sheets().length !== 0) throw new Error('Exact fixture window has a modal sheet');
  process.frontmost = true;
  window.actions.byName('AXRaise').perform();
  editor.focused = true;
  const assertFocus = () => {
    const focusedWindow = axValue(process, 'AXFocusedWindow');
    if (process.unixId() !== pid || !process.frontmost() || !editor.focused()
        || !focusedWindow || normalize(String(axValue(focusedWindow, 'AXDocument'))) !== fixture
        || normalize(String(axValue(window, 'AXDocument'))) !== fixture) {
      throw new Error('Exact fixture editor lost focus; refusing UI input');
    }
  };
  assertFocus();
  trace('ax:source-set');
  editor.attributes.byName('AXValue').value = newSource;
  if (axValue(editor, 'AXValue') !== newSource) throw new Error('AX editor did not accept the complete fixture payload');
  assertFocus();
  trace('ax:save-command');
  events.keystroke('s', { using: 'command down' });
  // The shell verifies actual saved bytes before quit and exact restored text.
}

function hostedUIFallback(mode, pid, fixture, normalize, newSource, trace) {
  const environment = $.NSProcessInfo.processInfo.environment;
  if (ObjC.unwrap(environment.objectForKey('GITHUB_ACTIONS')) !== 'true'
      || ObjC.unwrap(environment.objectForKey('CI_ISOLATED_RUNNER')) !== 'github-hosted') {
    throw new Error('UI fallback requires an isolated hosted runner');
  }
  const workspace = $.NSWorkspace.sharedWorkspace;
  const eventsURL = workspace.URLForApplicationWithBundleIdentifier('com.apple.systemevents');
  if (!eventsURL) throw new Error('System Events is unavailable');
  const running = workspace.launchApplicationAtURLOptionsConfigurationError(
    eventsURL, $.NSWorkspaceLaunchWithoutActivation, $.NSDictionary.dictionary, null,
  );
  if (!running || ObjC.unwrap(running.bundleIdentifier) !== 'com.apple.systemevents') {
    throw new Error('Could not identify System Events');
  }
  // Check the separate System Events grant without requesting or modifying it.
  requireAutomationPermission(Number(running.processIdentifier), trace);
  const events = Application(Number(running.processIdentifier));
  if (events.uiElementsEnabled() !== true) throw new Error('Existing Accessibility permission is unavailable');
  const processes = events.processes.whose({ unixId: pid })();
  if (processes.length !== 1) throw new Error('Expected one System Events process with the exact app PID');
  const source = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
    fixture, $.NSUTF8StringEncoding, null,
  ));
  if (typeof source !== 'string') throw new Error('Could not read dedicated fixture');
  operateAXDocument(events, processes[0], pid, normalize(fixture), normalize, source,
    mode === 'save' ? (newSource === undefined ? '# Save smoke test' : newSource) : undefined, trace);
}

function isProductionBundle(identifier) {
  return [
    'art.apuch.ksamint.markedit',
    'art.apuch.ksamint.markedit.conversation-capture-helper',
    'art.apuch.ksamint.markedit.finder-extension',
    'art.apuch.ksamint.markedit.preview-extension',
    'art.apuch.ksamint.markedit.quick-actions',
  ].includes(identifier);
}

function run(argv) {
  ObjC.import('AppKit');
  const normalize = value => {
    const path = value.startsWith('file:') ? $.NSURL.URLWithString(value).path : $(value);
    return ObjC.unwrap(path.stringByResolvingSymlinksInPath);
  };
  const [mode, appPath, expectedPID, fixture, saveSource] = argv;
  const applications = $.NSWorkspace.sharedWorkspace.runningApplications;
  const matches = [];
  const production = [];
  for (let index = 0; index < applications.count; index++) {
    const candidate = applications.objectAtIndex(index);
    const identifier = ObjC.unwrap(candidate.bundleIdentifier);
    if (mode === 'running-production' && !isProductionBundle(identifier)) continue;
    const candidatePath = ObjC.unwrap(candidate.bundleURL.path);
    if (mode === 'running-production') {
      if (typeof candidatePath !== 'string' || /[\n\t]/.test(candidatePath)) throw new Error('Invalid production process path');
      production.push([candidate.processIdentifier, normalize(candidatePath), identifier].join('\t'));
      continue;
    }
    if (typeof candidatePath === 'string' && normalize(candidatePath) === normalize(appPath)) {
      matches.push(candidate.processIdentifier);
    }
  }
  if (mode === 'running-production') return production.join('\n');
  if (mode === 'quit') {
    if (!matches.some(pid => String(pid) === expectedPID)) throw new Error('Production process identity changed');
    const running = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(expectedPID));
    if (!isProductionBundle(ObjC.unwrap(running.bundleIdentifier)) || normalize(ObjC.unwrap(running.bundleURL.path)) !== normalize(appPath)) {
      throw new Error('Production bundle identity changed');
    }
    if (!running.terminate) throw new Error('Application declined graceful termination');
    return;
  }
  if (matches.length > 1) throw new Error('Multiple processes use the exact test bundle');
  if (mode === 'pid') return matches.length ? String(matches[0]) : '';
  if (matches.length !== 1 || String(matches[0]) !== expectedPID) {
    throw new Error('Test process identity changed');
  }
  const trace = typeof module === 'undefined' ? value => console.log(`[smoke] ${value}`) : () => {};
  if (mode === 'save' || mode === 'restored') {
    try {
      requireAutomationPermission(Number(expectedPID), trace);
    } catch (error) {
      if ((error.automationStatus !== -1743 && error.automationStatus !== -1744)
          || !$.NSProcessInfo) throw error;
      trace('automation:using-existing-UI-permissions');
      hostedUIFallback(mode, Number(expectedPID), fixture, normalize, saveSource, trace);
      return;
    }
  }
  trace('application:connect');
  const app = Application(Number(expectedPID));
  trace('application:ready');
  if (mode === 'open') {
    trace('document:open');
    app.open(Path(fixture));
    trace('document:opened');
  } else if (mode === 'save') {
    saveExactDocument(app, normalize(fixture), normalize,
      saveSource === undefined ? '# Save smoke test' : saveSource, trace);
  } else if (mode === 'restored') {
    // Read-only: opening here would conceal a failed AppKit restoration.
    const source = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
      fixture, $.NSUTF8StringEncoding, null,
    ));
    trace('restoration:query');
    verifyRestoredDocument(app.documents(), normalize(fixture), normalize, source);
    trace('restoration:verified');
  } else {
    throw new Error('Unknown smoke operation');
  }
}

if (typeof module !== 'undefined') module.exports = {
  exactDocument, verifyRestoredDocument, saveExactDocument, requireAutomationPermission, isProductionBundle, run,
  exactAXWindow, exactAXEditor, operateAXDocument,
};
