import { syntaxTree } from '@codemirror/language';
import {
  EditorSelection,
  EditorState,
  Range,
  StateEffect,
  StateField,
} from '@codemirror/state';
import {
  Decoration,
  DecorationSet,
  EditorView,
  WidgetType,
} from '@codemirror/view';
import { SyntaxNode, SyntaxNodeRef } from '@lezer/common';
import { editingState } from '../../common/store';
import { tryGetEditor } from '../../common/utils';

type SourceRange = {
  from: number;
  to: number;
};

const refreshEffect = StateEffect.define();
let pendingMode: boolean | undefined;
let lastActiveRanges: SourceRange[] = [];

function sameRanges(lhs: SourceRange[], rhs: SourceRange[]) {
  return lhs.length === rhs.length
    && lhs.every((range, index) => range.from === rhs[index].from && range.to === rhs[index].to);
}

export const visualEditingExtension = [
  StateField.define<DecorationSet>({
    create(state) {
      return buildDecorations(state);
    },
    update(decorations, transaction) {
      if (!editingState.compositionEnded) {
        return transaction.docChanged
          ? decorations.map(transaction.changes)
          : decorations;
      }

      if (transaction.docChanged || transaction.effects.length > 0) {
        return buildDecorations(transaction.state);
      }

      // A selection change only matters when it moves the caret into or out
      // of a block; rebuilding from the whole syntax tree on every arrow key
      // cost tens of milliseconds in large documents.
      if (transaction.selection !== undefined) {
        const activeRanges = getActiveRanges(transaction.state);
        if (sameRanges(activeRanges, lastActiveRanges)) {
          return decorations;
        }
        return buildDecorations(transaction.state, activeRanges);
      }
      return decorations;
    },
    provide: field => EditorView.decorations.from(field),
  }),
  EditorView.baseTheme({
    '.cm-visual-list-marker': {
      display: 'inline-block',
      minWidth: '1.15em',
      color: 'currentColor',
      textAlign: 'center',
      userSelect: 'none',
    },
    '.cm-visual-quote-marker': {
      display: 'inline-block',
      width: '0.32em',
      height: '1.15em',
      marginRight: '0.45em',
      borderRadius: '2px',
      backgroundColor: 'currentColor',
      opacity: '0.35',
      verticalAlign: '-0.18em',
    },
    '.cm-visual-task': {
      margin: '0 0.4em 0 0',
      accentColor: 'Highlight',
      verticalAlign: '-0.12em',
    },
    '.cm-visual-image': {
      display: 'inline-flex',
      maxWidth: 'min(100%, 720px)',
      margin: '0.4em 0',
      padding: '0',
      border: '0',
      borderRadius: '6px',
      background: 'transparent',
      cursor: 'text',
      verticalAlign: 'middle',
    },
    '.cm-visual-image img': {
      display: 'block',
      maxWidth: '100%',
      maxHeight: '460px',
      borderRadius: '6px',
      objectFit: 'contain',
    },
    '.cm-visual-image-fallback': {
      padding: '0.25em 0.5em',
      border: '1px solid color-mix(in srgb, currentColor 25%, transparent)',
      borderRadius: '5px',
      opacity: '0.7',
    },
    '.cm-visual-table': {
      display: 'block',
      maxWidth: '100%',
      margin: '0.45em 0 0.8em',
      overflowX: 'auto',
      cursor: 'text',
    },
    '.cm-visual-table table': {
      width: '100%',
      borderSpacing: '0',
      borderCollapse: 'collapse',
      fontFamily: 'inherit',
    },
    '.cm-visual-table th, .cm-visual-table td': {
      padding: '0.35em 0.6em',
      border: '1px solid color-mix(in srgb, currentColor 22%, transparent)',
      textAlign: 'left',
    },
    '.cm-visual-table th': {
      fontWeight: '600',
      backgroundColor: 'color-mix(in srgb, currentColor 7%, transparent)',
    },
  }),
];

export function setVisualEditing(enabled: boolean) {
  window.config.visualEditingMode = enabled;
  if (!editingState.compositionEnded) {
    pendingMode = enabled;
    return;
  }

  applyMode(enabled);
}

export function finishVisualComposition() {
  if (pendingMode !== undefined) {
    const enabled = pendingMode;
    pendingMode = undefined;
    applyMode(enabled);
  } else if (window.config.visualEditingMode === true) {
    tryGetEditor()?.dispatch({ effects: refreshEffect.of(null) });
  }
}

function applyMode(enabled: boolean) {
  const compartment = window.dynamics.visualEditing;
  tryGetEditor()?.dispatch({
    effects: compartment?.reconfigure(enabled ? visualEditingExtension : []),
  });
}

function buildDecorations(
  state: EditorState,
  activeRanges: SourceRange[] = getActiveRanges(state),
): DecorationSet {
  lastActiveRanges = activeRanges;
  const ranges: Range<Decoration>[] = [];
  const visited = new Set<string>();

  const append = (node: SyntaxNodeRef, range: Range<Decoration>) => {
    const key = `${node.name}:${node.from}:${node.to}`;
    if (!visited.has(key)) {
      visited.add(key);
      ranges.push(range);
    }
  };

  syntaxTree(state).iterate({
    enter: node => {
      if (node.from >= node.to || isActive(node, activeRanges)) {
        return;
      }

      switch (node.name) {
        case 'Image':
          append(node, imageDecoration(state, node));
          return false;
        case 'Table':
          append(node, tableDecoration(state, node));
          return false;
        case 'TaskMarker':
          append(node, taskDecoration(state, node));
          return false;
        case 'ListMark':
          append(node, listMarkerDecoration(state, node));
          return false;
        case 'QuoteMark':
          append(node, Decoration.replace({
            widget: new QuoteMarkerWidget(),
          }).range(node.from, node.to));
          return false;
        case 'URL':
          if (isLabeledLink(node.node, (from, to) => state.sliceDoc(from, to))) {
            append(node, hiddenRange(node));
          }
          return false;
        case 'LinkLabel':
          if (node.node.parent?.name === 'Link') {
            append(node, hiddenRange(node));
          }
          return false;
        default:
          if (hiddenMarkerNames.has(node.name)) {
            append(node, hiddenRange(node));
            return false;
          }
          return;
      }
    },
  });

  return Decoration.set(ranges, true);
}

function getActiveRanges(state: EditorState): SourceRange[] {
  const tree = syntaxTree(state);
  const ranges = state.selection.ranges.flatMap(selection => {
    if (!selection.empty) {
      return [
        blockRangeAt(tree.resolveInner(selection.from, 1), state),
        { from: selection.from, to: selection.to },
        blockRangeAt(tree.resolveInner(selection.to, -1), state),
      ];
    }
    return [blockRangeAt(tree.resolveInner(selection.head, 1), state)];
  });

  return mergeRanges(ranges);
}

function blockRangeAt(node: SyntaxNode, state: EditorState): SourceRange {
  let block: SyntaxNode | undefined;
  for (let current: SyntaxNode | null = node; current !== null; current = current.parent) {
    if (editableBlockNames.has(current.name) || headingPattern.test(current.name)) {
      block = current;
    }
  }

  if (block !== undefined) {
    return { from: block.from, to: block.to };
  }

  const line = state.doc.lineAt(node.from);
  return { from: line.from, to: line.to };
}

function mergeRanges(ranges: SourceRange[]): SourceRange[] {
  const sorted = ranges.toSorted((lhs, rhs) => lhs.from - rhs.from);
  const merged: SourceRange[] = [];

  for (const range of sorted) {
    const last = merged.at(-1);
    if (last === undefined || range.from > last.to) {
      merged.push({ ...range });
    } else {
      last.to = Math.max(last.to, range.to);
    }
  }
  return merged;
}

function isActive(node: SyntaxNodeRef, activeRanges: SourceRange[]): boolean {
  return activeRanges.some(range => node.from < range.to && node.to > range.from);
}

function hiddenRange(node: SyntaxNodeRef): Range<Decoration> {
  return Decoration.replace({}).range(node.from, node.to);
}

function imageDecoration(state: EditorState, node: SyntaxNodeRef): Range<Decoration> {
  const source = state.sliceDoc(node.from, node.to);
  const match = source.match(/^!\[([\s\S]*?)\]\((\S+?)(?:\s+["'][\s\S]*?["'])?\)$/);
  const alt = match?.[1] ?? '';
  const sourceURL = match === null ? undefined : safeImageURL(match[2]);
  return Decoration.replace({
    widget: new ImageWidget(node.from, sourceURL, alt),
  }).range(node.from, node.to);
}

function tableDecoration(state: EditorState, node: SyntaxNodeRef): Range<Decoration> {
  const source = state.sliceDoc(node.from, node.to);
  return Decoration.replace({
    block: true,
    widget: new TableWidget(node.from, source),
  }).range(node.from, node.to);
}

function taskDecoration(state: EditorState, node: SyntaxNodeRef): Range<Decoration> {
  const checked = /\[[xX]\]/.test(state.sliceDoc(node.from, node.to));
  return Decoration.replace({
    widget: new TaskWidget(node.from, node.to, checked),
  }).range(node.from, node.to);
}

function listMarkerDecoration(state: EditorState, node: SyntaxNodeRef): Range<Decoration> {
  const task = node.node.parent?.getChild('Task');
  if (task !== null && task !== undefined) {
    return hiddenRange(node);
  }

  const source = state.sliceDoc(node.from, node.to);
  const label = /^\d/.test(source) ? source : '•';
  return Decoration.replace({
    widget: new ListMarkerWidget(label),
  }).range(node.from, node.to);
}

function isLabeledLink(node: SyntaxNode, sliceDoc: (from: number, to?: number) => string): boolean {
  const parent = node.parent;
  if (parent?.name !== 'Link') {
    return false;
  }
  return sliceDoc(parent.from, parent.to).startsWith('[');
}

function safeImageURL(rawValue: string): string | undefined {
  const value = rawValue.trim().replace(/^<|>$/g, '');
  if (value.length === 0 || /^(?:javascript|vbscript|data):/i.test(value)) {
    return undefined;
  }

  const scheme = value.match(/^([a-z][a-z0-9+.-]*):/i)?.[1]?.toLocaleLowerCase();
  if (scheme !== undefined) {
    return ['http', 'https'].includes(scheme) ? value : undefined;
  }

  if (value.startsWith('/') || value.startsWith('~') || value.includes('\\')) {
    return undefined;
  }
  return `image-loader://${encodeURI(value)}`;
}

function revealSource(view: EditorView, position: number) {
  view.dispatch({
    selection: EditorSelection.cursor(position),
    scrollIntoView: true,
  });
  view.focus();
}

class ListMarkerWidget extends WidgetType {
  constructor(private readonly label: string) {
    super();
  }

  eq(other: ListMarkerWidget) {
    return other.label === this.label;
  }

  toDOM() {
    const element = document.createElement('span');
    element.className = 'cm-visual-list-marker';
    element.textContent = this.label;
    element.setAttribute('aria-hidden', 'true');
    return element;
  }
}

class QuoteMarkerWidget extends WidgetType {
  toDOM() {
    const element = document.createElement('span');
    element.className = 'cm-visual-quote-marker';
    element.setAttribute('aria-hidden', 'true');
    return element;
  }
}

class TaskWidget extends WidgetType {
  constructor(
    private readonly from: number,
    private readonly to: number,
    private readonly checked: boolean,
  ) {
    super();
  }

  eq(other: TaskWidget) {
    return other.from === this.from
      && other.to === this.to
      && other.checked === this.checked;
  }

  toDOM(view: EditorView) {
    const checkbox = document.createElement('input');
    checkbox.className = 'cm-visual-task';
    checkbox.type = 'checkbox';
    checkbox.checked = this.checked;
    checkbox.setAttribute('aria-label', window.config.localizable?.cmdClickToToggleTodo ?? 'Toggle task');
    checkbox.addEventListener('mousedown', event => {
      event.preventDefault();
      event.stopPropagation();
    });
    checkbox.addEventListener('click', event => {
      view.dispatch({
        changes: {
          from: this.from,
          to: this.to,
          insert: this.checked ? '[ ]' : '[x]',
        },
        userEvent: 'input',
      });
      event.preventDefault();
      event.stopPropagation();
    });
    return checkbox;
  }

  ignoreEvent() {
    return true;
  }
}

class ImageWidget extends WidgetType {
  constructor(
    private readonly position: number,
    private readonly sourceURL: string | undefined,
    private readonly alt: string,
  ) {
    super();
  }

  eq(other: ImageWidget) {
    return other.position === this.position
      && other.sourceURL === this.sourceURL
      && other.alt === this.alt;
  }

  toDOM(view: EditorView) {
    const button = document.createElement('button');
    button.className = 'cm-visual-image';
    button.type = 'button';
    button.title = this.alt;
    button.setAttribute('aria-label', this.alt || 'Reveal image source');

    if (this.sourceURL === undefined) {
      const fallback = document.createElement('span');
      fallback.className = 'cm-visual-image-fallback';
      fallback.textContent = this.alt || 'Image';
      button.appendChild(fallback);
    } else {
      const image = document.createElement('img');
      image.src = this.sourceURL;
      image.alt = this.alt;
      image.loading = 'lazy';
      button.appendChild(image);
    }

    button.addEventListener('click', event => {
      revealSource(view, this.position);
      event.preventDefault();
      event.stopPropagation();
    });
    return button;
  }

  ignoreEvent() {
    return true;
  }
}

class TableWidget extends WidgetType {
  constructor(
    private readonly position: number,
    private readonly source: string,
  ) {
    super();
  }

  eq(other: TableWidget) {
    return other.position === this.position && other.source === this.source;
  }

  toDOM(view: EditorView) {
    const wrapper = document.createElement('div');
    wrapper.className = 'cm-visual-table';
    wrapper.tabIndex = 0;
    wrapper.setAttribute('role', 'button');
    wrapper.setAttribute('aria-label', 'Reveal table source');

    const rows = this.source.trim().split(/\r?\n/).map(splitTableRow);
    const table = document.createElement('table');
    const header = document.createElement('thead');
    const headerRow = document.createElement('tr');
    for (const cell of rows[0] ?? []) {
      const element = document.createElement('th');
      element.textContent = cell.trim();
      headerRow.appendChild(element);
    }
    header.appendChild(headerRow);
    table.appendChild(header);

    const body = document.createElement('tbody');
    for (const row of rows.slice(2)) {
      const rowElement = document.createElement('tr');
      for (const cell of row) {
        const element = document.createElement('td');
        element.textContent = cell.trim();
        rowElement.appendChild(element);
      }
      body.appendChild(rowElement);
    }
    table.appendChild(body);
    wrapper.appendChild(table);

    const reveal = (event: Event) => {
      revealSource(view, this.position);
      event.preventDefault();
      event.stopPropagation();
    };
    wrapper.addEventListener('click', reveal);
    wrapper.addEventListener('keydown', event => {
      if (event.key === 'Enter' || event.key === ' ') {
        reveal(event);
      }
    });
    return wrapper;
  }

  ignoreEvent() {
    return true;
  }
}

function splitTableRow(line: string): string[] {
  const cells: string[] = [];
  let current = '';
  let escaped = false;
  for (const character of line.trim().replace(/^\||\|$/g, '')) {
    if (character === '|' && !escaped) {
      cells.push(current);
      current = '';
    } else {
      current += character;
    }
    escaped = character === '\\' && !escaped;
    if (character !== '\\') {
      escaped = false;
    }
  }
  cells.push(current);
  return cells;
}

const hiddenMarkerNames = new Set([
  'CodeInfo',
  'CodeMark',
  'EmphasisMark',
  'HeaderMark',
  'LinkMark',
  'StrikethroughMark',
]);

const editableBlockNames = new Set([
  'Blockquote',
  'CodeBlock',
  'FencedCode',
  'HTMLBlock',
  'LinkDefinition',
  'ListItem',
  'Paragraph',
  'Table',
]);

const headingPattern = /^(?:ATX|Setext)Heading[1-6]$/;
