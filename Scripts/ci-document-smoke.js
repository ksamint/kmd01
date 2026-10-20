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
    throw new Error(`Automation unavailable (OSStatus ${status}); no consent was requested`);
  }
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
    requireAutomationPermission(Number(expectedPID), trace);
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
};
