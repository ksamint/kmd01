import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import {
  bracketMatching,
  defaultHighlightStyle,
  syntaxHighlighting,
} from '@codemirror/language';
import { markdown } from '@codemirror/lang-markdown';
import { Annotation, Compartment, EditorState, Transaction } from '@codemirror/state';
import {
  drawSelection,
  EditorView,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
} from '@codemirror/view';

/** Marks document replacements made by the host rather than by the user. */
const programmaticChange = Annotation.define<boolean>();

export type StandaloneEditorOptions = {
  parent: HTMLElement;
  doc: string;
  readOnly?: boolean;
  onChange?: (text: string) => void;
};

export type StandaloneEditor = {
  view: EditorView;
  getText: () => string;
  setText: (text: string) => void;
  setReadOnly: (readOnly: boolean) => void;
  focus: () => void;
  destroy: () => void;
};

export function createStandaloneMarkdownEditor(
  options: StandaloneEditorOptions,
): StandaloneEditor {
  const readOnly = new Compartment();
  const view = new EditorView({
    parent: options.parent,
    state: EditorState.create({
      doc: options.doc,
      extensions: [
        lineNumbers(),
        highlightActiveLineGutter(),
        history(),
        drawSelection(),
        highlightActiveLine(),
        bracketMatching(),
        syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        markdown(),
        EditorView.lineWrapping,
        keymap.of([indentWithTab, ...defaultKeymap, ...historyKeymap]),
        readOnly.of(EditorState.readOnly.of(options.readOnly ?? false)),
        EditorView.updateListener.of(update => {
          if (!update.docChanged) {
            return;
          }
          // setText() replaces the document when the host switches notes or
          // applies a sync result; reporting that as an edit made every file
          // open look modified and queued a redundant save.
          const programmatic = update.transactions.some(
            transaction => transaction.annotation(programmaticChange) === true,
          );
          if (!programmatic) {
            options.onChange?.(update.state.doc.toString());
          }
        }),
      ],
    }),
  });

  return {
    view,
    getText: () => view.state.doc.toString(),
    setText: text => {
      const current = view.state.doc.toString();
      if (current === text) {
        return;
      }
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
        annotations: [
          programmaticChange.of(true),
          // Undo must never restore a different note's text into this one.
          Transaction.addToHistory.of(false),
        ],
      });
    },
    setReadOnly: value => {
      view.dispatch({
        effects: readOnly.reconfigure(EditorState.readOnly.of(value)),
      });
    },
    focus: () => view.focus(),
    destroy: () => view.destroy(),
  };
}
