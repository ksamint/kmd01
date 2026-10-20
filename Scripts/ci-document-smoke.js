function exactDocument(documents, fixture, normalize) {
  const matches = documents.filter(document => {
    const file = document.file();
    return file && normalize(String(file)) === fixture;
  });
  if (matches.length !== 1) throw new Error('Expected exactly one dedicated fixture document');
  return matches[0];
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
  const [mode, appPath, expectedPID, fixture] = argv;
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
  const app = Application(Number(expectedPID));
  if (mode === 'open') {
    app.open(Path(fixture));
  } else if (mode === 'save') {
    const document = exactDocument(app.documents(), normalize(fixture), normalize);
    document.source = '# Save smoke test';
    app.save(document);
  } else {
    throw new Error('Unknown smoke operation');
  }
}

if (typeof module !== 'undefined') module.exports = { exactDocument, isProductionBundle, run };
