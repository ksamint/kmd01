import { ChangeSpec } from '@codemirror/state';

/**
 * Format the content, usually gets called when saving files.
 *
 * @param insertFinalNewline Whether to insert newline at end of file
 * @param trimTrailingWhitespace Whether to remove trailing whitespaces
 * @param userInitiated Whether the action is explicitly triggered by the user
 */
export default function formatContent(
  insertFinalNewline: boolean,
  trimTrailingWhitespace: boolean,
  userInitiated: boolean,
) {
  const editor = window.editor;
  const state = editor.state;

  // All edits are expressed against the current document and dispatched as a
  // single transaction. Dispatching once per line used to trigger a full view
  // update (decorations, native notifications, preview) per trailing-space
  // line, which froze saving for documents with thousands of them.
  const changes: ChangeSpec[] = [];

  // Whether formatting operations are all taken
  let isCompleted = true;

  if (trimTrailingWhitespace) {
    const ranges = state.selection.ranges;
    for (let index = 1; index <= state.doc.lines; ++index) {
      const line = state.doc.line(index);
      const match = /\s+$/g.exec(line.text);
      if (match === null) {
        continue;
      }

      // For implicit formatting, avoid trimming spaces before the caret
      if (!userInitiated && ranges.some(({ from, to }) => from === to && line.to === to)) {
        isCompleted = false;
        continue;
      }

      changes.push({
        insert: '',
        from: match.index + line.from,
        to: line.to,
      });
    }
  }

  if (insertFinalNewline) {
    // We don't need to ensure final newline when it's empty.
    // The document ends with a line break exactly when its last line is empty.
    const doc = state.doc;
    if (doc.length > 0 && doc.line(doc.lines).length > 0) {
      changes.push({
        insert: state.lineBreak,
        from: doc.length,
      });
    }
  }

  if (changes.length > 0) {
    editor.dispatch({
      changes,
      userEvent: '@none', // Ignore automatic scrolling
    });
  }

  return isCompleted;
}
