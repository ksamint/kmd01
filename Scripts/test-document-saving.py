#!/usr/bin/env python3
"""Compile production save paths with both real AppKit signatures and headless doubles."""
from pathlib import Path
import subprocess
import json
import re
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def method(source, signature):
    start = source.index('  ' + signature)
    end = source.index('\n  }', start) + len('\n  }')
    return source[start:end]


def main():
    document = (ROOT / 'MarkEditMac/Sources/Editor/Models/EditorDocument.swift').read_text()
    extras = (ROOT / 'MarkEditMac/Sources/Extras/NSDocumentController+Extras.swift').read_text()
    template = (ROOT / 'Scripts/DocumentSavingTestMain.swift').read_text()
    signatures = [
        'func waitUntilSaveCompleted(', 'func saveContent(', 'func updateContent(',
        'func enqueueSave(', 'func performSave(', 'func refreshContent(', 'func finishSaving(',
        'func editorScript(', 'func notifyDocumentDelegate(', 'func cancelTermination(', 'func saveScriptCommand(',
        'override func save(_', 'override func save(withDelegate', 'override func saveAs(',
        'override func canClose(', 'override func autosave(', 'override func data(',
    ]
    template = template.replace('  // DOCUMENT_METHODS', '\n\n'.join(method(document, signature) for signature in signatures))
    template = template.replace('// RESULT_HELPERS', document[document.index('private struct DocumentEditorSnapshot:'):])
    template = template.replace('  // CONTROLLER_SAVE', method(extras, 'func saveOutdatedDocuments('))
    app_delegate = (ROOT / 'MarkEditMac/Sources/Main/Application/AppDelegate.swift').read_text()
    template = template.replace('  // TERMINATION_METHOD', method(app_delegate, 'func applicationShouldTerminate('))
    scripts = re.findall(r'editorScript\("""\n(.*?)\n\s*"""', document, re.DOTALL)
    clean = next(script for script in scripts if 'markContentClean' in script)
    snapshot = next(script for script in scripts if 'JSON.stringify' in script)
    javascript = '''
      const assert = require('node:assert/strict');
      const clean = new Function('webModules', 'savedText', CLEAN);
      const snapshot = new Function('webModules', 'needsTitle', SNAPSHOT);
      let text = 'saved \\"literal\\" 中文\\n', marks = 0, headings = 0;
      const modules = {
        core: { getEditorText: () => text },
        history: { markContentClean: () => { marks++; } },
        toc: { getTableOfContents: () => { headings++; return [{title: 'Title'}]; } },
      };
      const saved = text;
      assert.equal(clean(modules, saved), 'clean');
      assert.equal(marks, 1);
      text += 'queued edit';
      assert.equal(clean(modules, saved), 'changed');
      assert.equal(marks, 1);
      assert.deepEqual(JSON.parse(snapshot(modules, false)), {text});
      assert.equal(headings, 0);
      assert.deepEqual(JSON.parse(snapshot(modules, true)), {text, title: 'Title'});
      assert.equal(headings, 1);
      console.log('Actual editor snapshot and atomic clean JavaScript checks passed.');
    '''.replace('CLEAN', json.dumps(clean)).replace('SNAPSHOT', json.dumps(snapshot))
    subprocess.run(['node', '-e', javascript], check=True, timeout=10)
    with tempfile.TemporaryDirectory(prefix='kmd-document-saving-') as directory:
        source = Path(directory) / 'Saving.swift'
        source.write_text(template)
        base = ['swiftc', '-swift-version', '6', '-parse-as-library', str(source)]
        subprocess.run(base + ['-D', 'SDK_CHECK', '-typecheck'], check=True, timeout=60)
        binary = Path(directory) / 'saving'
        subprocess.run(base + ['-o', str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == '__main__':
    main()
