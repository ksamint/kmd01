import { describe, expect, test } from '@jest/globals';
import { undo } from '@codemirror/commands';
import { createStandaloneMarkdownEditor } from '../src/standalone';

describe('Standalone editor', () => {
  test('setText is not reported as a user edit', () => {
    const changes: string[] = [];
    const editor = createStandaloneMarkdownEditor({
      parent: document.body,
      doc: 'note A',
      onChange: text => changes.push(text),
    });

    editor.setText('note B');
    expect(editor.getText()).toBe('note B');
    expect(changes).toEqual([]);

    editor.view.dispatch({ changes: { from: 0, insert: 'typed ' } });
    expect(changes).toEqual(['typed note B']);
    editor.destroy();
  });

  test('undo never restores a previously loaded document', () => {
    const changes: string[] = [];
    const editor = createStandaloneMarkdownEditor({
      parent: document.body,
      doc: 'note A',
      onChange: text => changes.push(text),
    });

    editor.view.dispatch({ changes: { from: 0, insert: 'edited ' }, userEvent: 'input.type' });
    editor.setText('note B');
    undo(editor.view);

    expect(editor.getText()).toBe('note B');
    expect(changes).toEqual(['edited note A']);
    editor.destroy();
  });
});
