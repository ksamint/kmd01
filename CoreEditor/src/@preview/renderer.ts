import { markdownLanguage } from '@codemirror/lang-markdown';
import { SyntaxNode, Tree } from '@lezer/common';

type RenderContext = {
  source: string;
  references: Map<string, string>;
};

export function renderMarkdown(source: string, parsedTree?: Tree): string {
  const tree = parsedTree ?? markdownLanguage.parser.parse(source);
  const references = new Map<string, string>();

  for (const match of source.matchAll(/^\[([^\]]+)\]:\s+(\S+)/gm)) {
    references.set(match[1].toLocaleLowerCase(), match[2]);
  }

  return renderNode(tree.topNode, { source, references });
}

export function safeURL(rawValue: string, image: boolean): string | undefined {
  const value = rawValue.trim().replace(/^<|>$/g, '');
  if (value.length === 0 || /^(?:javascript|vbscript|data):/i.test(value)) {
    return undefined;
  }

  if (value.startsWith('#')) {
    return image ? undefined : value;
  }

  const scheme = value.match(/^([a-z][a-z0-9+.-]*):/i)?.[1]?.toLocaleLowerCase();
  if (scheme !== undefined) {
    const allowedSchemes = image ? ['http', 'https'] : ['http', 'https', 'mailto'];
    return allowedSchemes.includes(scheme) ? value : undefined;
  }

  if (value.startsWith('/') || value.startsWith('~') || value.includes('\\')) {
    return undefined;
  }

  return image
    ? `image-loader://${encodeURI(value)}`
    : encodeURI(value);
}

function renderNode(node: SyntaxNode, context: RenderContext): string {
  const source = context.source.slice(node.from, node.to);
  const position = ` data-source-from="${node.from}" data-source-to="${node.to}"`;
  const heading = node.name.match(/^(?:ATX|Setext)Heading([1-6])$/);

  if (heading !== null) {
    const level = heading[1];
    return `<h${level}${position}>${renderChildren(node, context, markerNodes).trim()}</h${level}>`;
  }

  switch (node.name) {
    case 'Document':
      return renderChildren(node, context, new Set());
    case 'Paragraph':
      return `<p${position}>${renderChildren(node, context, new Set()).trim()}</p>`;
    case 'StrongEmphasis':
      return `<strong${position}>${renderChildren(node, context, markerNodes)}</strong>`;
    case 'Emphasis':
      return `<em${position}>${renderChildren(node, context, markerNodes)}</em>`;
    case 'Strikethrough':
      return `<del${position}>${renderChildren(node, context, markerNodes)}</del>`;
    case 'Subscript':
      return `<sub${position}>${renderChildren(node, context, markerNodes)}</sub>`;
    case 'Superscript':
      return `<sup${position}>${renderChildren(node, context, markerNodes)}</sup>`;
    case 'InlineCode':
      return `<code${position}>${escapeHTML(stripInlineMarks(source))}</code>`;
    case 'FencedCode':
      return renderFencedCode(source, position);
    case 'CodeBlock':
      return `<pre${position}><code>${escapeHTML(
        source.split(/\r?\n/).map(line => line.replace(/^(?: {4}|\t)/, '')).join('\n'),
      )}</code></pre>`;
    case 'BulletList':
      return `<ul${position}>${renderChildren(node, context, markerNodes)}</ul>`;
    case 'OrderedList': {
      const start = parseInt(source.match(/^\s*(\d+)[.)]/)?.[1] ?? '1');
      const startAttribute = start === 1 ? '' : ` start="${start}"`;
      return `<ol${startAttribute}${position}>${renderChildren(node, context, markerNodes)}</ol>`;
    }
    case 'ListItem':
      return `<li${position}>${renderChildren(node, context, markerNodes).trim()}</li>`;
    case 'Task':
      return renderChildren(node, context, markerNodes);
    case 'TaskMarker':
      return `<input class="task" type="checkbox" disabled${/\[[xX]\]/.test(source) ? ' checked' : ''}>`;
    case 'Blockquote':
      return `<blockquote${position}>${renderChildren(node, context, markerNodes).trim()}</blockquote>`;
    case 'HorizontalRule':
      return `<hr${position}>`;
    case 'Link':
      return renderLink(source, position, context);
    case 'Image':
      return renderImage(source, position);
    case 'LinkReference':
      return renderLinkReference(source, position, context);
    case 'Table':
      return renderTable(source, position, context);
    case 'HTMLBlock':
    case 'HTMLTag':
    case 'CommentBlock':
    case 'ProcessingInstructionBlock':
      return `<pre class="raw-html"${position}><code>${escapeHTML(source)}</code></pre>`;
    case 'Frontmatter':
      return `<pre class="front-matter"${position}><code>${escapeHTML(source)}</code></pre>`;
    case 'HardBreak':
      return `<br${position}>`;
    case 'Escape':
      return escapeHTML(source.replace(/^\\/, ''));
    case 'Entity':
      return escapeHTML(decodeEntity(source));
    case 'InlineMath':
    case 'BlockMath':
      return `<code class="math-source"${position}>${escapeHTML(source)}</code>`;
    default:
      if (markerNodes.has(node.name)) {
        return '';
      }
      return node.firstChild === null
        ? escapeHTML(source)
        : renderChildren(node, context, new Set());
  }
}

function renderChildren(
  node: SyntaxNode,
  context: RenderContext,
  skippedNodeNames: Set<string>,
): string {
  let result = '';
  let cursor = node.from;

  for (let child = node.firstChild; child !== null; child = child.nextSibling) {
    if (child.from > cursor) {
      result += escapeHTML(context.source.slice(cursor, child.from));
    }
    if (!skippedNodeNames.has(child.name)) {
      result += renderNode(child, context);
    }
    cursor = child.to;
  }

  if (cursor < node.to) {
    result += escapeHTML(context.source.slice(cursor, node.to));
  }
  return result;
}

function renderLink(source: string, position: string, context: RenderContext): string {
  const footnote = source.match(/^\[\^([^\]]+)\]$/);
  if (footnote !== null) {
    const label = escapeAttribute(footnote[1]);
    return `<sup class="footnote-ref"${position}><a href="#fn-${label}">${escapeHTML(footnote[1])}</a></sup>`;
  }

  const standard = source.match(/^\[([\s\S]*?)\]\((\S+?)(?:\s+["'][\s\S]*?["'])?\)$/);
  const reference = source.match(/^\[([\s\S]*?)\]\[([^\]]+)\]$/);
  const label = standard?.[1] ?? reference?.[1];
  const rawURL = standard?.[2] ?? context.references.get((reference?.[2] ?? '').toLocaleLowerCase());
  const url = rawURL === undefined ? undefined : safeURL(rawURL, false);

  if (label === undefined || url === undefined) {
    return `<span class="unsafe-link"${position}>${escapeHTML(label ?? source)}</span>`;
  }

  return `<a href="${escapeAttribute(url)}"${position}>${escapeHTML(label)}</a>`;
}

function renderImage(source: string, position: string): string {
  const match = source.match(/^!\[([\s\S]*?)\]\((\S+?)(?:\s+["']([\s\S]*?)["'])?\)$/);
  const alt = match?.[1] ?? '';
  const url = match === null ? undefined : safeURL(match[2], true);

  if (url === undefined) {
    return `<span class="image-fallback"${position}>${escapeHTML(alt || source)}</span>`;
  }

  const title = match?.[3] === undefined ? '' : ` title="${escapeAttribute(match[3])}"`;
  return `<figure${position}><img src="${escapeAttribute(url)}" alt="${escapeAttribute(alt)}"${title} loading="lazy"><figcaption>${escapeHTML(alt)}</figcaption></figure>`;
}

function renderLinkReference(source: string, position: string, context: RenderContext): string {
  const match = source.match(/^\[([^\]]+)\]:\s+(\S+)(?:\s+["']([\s\S]*?)["'])?/);
  if (match === null) {
    return `<p class="reference-definition"${position}>${escapeHTML(source)}</p>`;
  }

  if (match[1].startsWith('^')) {
    const label = match[1].slice(1);
    const body = source.slice(match[0].length).trim() || match[2];
    return `<section class="footnote"${position} id="fn-${escapeAttribute(label)}"><sup>${escapeHTML(label)}</sup> ${renderInline(body, context)}</section>`;
  }

  return '';
}

function renderTable(source: string, position: string, context: RenderContext): string {
  const rows = source.trim().split(/\r?\n/).map(splitTableRow);
  if (rows.length < 2) {
    return `<pre${position}><code>${escapeHTML(source)}</code></pre>`;
  }

  const alignments = rows[1].map(cell => {
    const value = cell.trim();
    if (value.startsWith(':') && value.endsWith(':')) {
      return 'center';
    }
    return value.endsWith(':') ? 'right' : 'left';
  });
  const header = rows[0].map((cell, index) => (
    `<th style="text-align:${alignments[index] ?? 'left'}">${renderInline(cell.trim(), context)}</th>`
  )).join('');
  const body = rows.slice(2).map(row => `<tr>${row.map((cell, index) => (
    `<td style="text-align:${alignments[index] ?? 'left'}">${renderInline(cell.trim(), context)}</td>`
  )).join('')}</tr>`).join('');

  return `<div class="table-scroll"${position}><table><thead><tr>${header}</tr></thead><tbody>${body}</tbody></table></div>`;
}

function splitTableRow(line: string): string[] {
  const trimmed = line.trim().replace(/^\||\|$/g, '');
  const cells: string[] = [];
  let current = '';
  let escaped = false;

  for (const character of trimmed) {
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

// Table cells are re-rendered with the whole document; most of them are
// unchanged between renders, so their HTML is cached by source text. The
// cache is scoped to the current reference definitions, which are the only
// other input the inline renderer depends on.
const inlineCache = {
  referencesKey: '',
  entries: new Map<string, string>(),
};
const inlineCacheLimit = 20_000;

function renderInline(source: string, context: RenderContext): string {
  const referencesKey = [...context.references].map(([label, url]) => `${label}\u{0}${url}`).join('\n');
  if (inlineCache.referencesKey !== referencesKey) {
    inlineCache.referencesKey = referencesKey;
    inlineCache.entries.clear();
  }

  const cached = inlineCache.entries.get(source);
  if (cached !== undefined) {
    return cached;
  }

  const tree = markdownLanguage.parser.parse(source);
  const paragraph = tree.topNode.firstChild;
  const rendered = paragraph === null
    ? escapeHTML(source)
    : renderChildren(paragraph, { ...context, source }, new Set()).trim();

  if (inlineCache.entries.size >= inlineCacheLimit) {
    inlineCache.entries.clear();
  }
  inlineCache.entries.set(source, rendered);
  return rendered;
}

function renderFencedCode(source: string, position: string): string {
  const lines = source.split(/\r?\n/);
  const firstLine = lines.shift() ?? '';
  if (/^\s*(```|~~~)/.test(lines.at(-1) ?? '')) {
    lines.pop();
  }
  const language = firstLine.replace(/^\s*(?:```|~~~)\s*/, '').trim().split(/\s+/)[0];
  const languageClass = language.length === 0 ? '' : ` class="language-${escapeAttribute(language)}"`;
  return `<pre${position}><code${languageClass}>${escapeHTML(lines.join('\n'))}</code></pre>`;
}

function stripInlineMarks(source: string): string {
  const marker = source.match(/^(`+)([\s\S]*)(\1)$/);
  return marker?.[2] ?? source;
}

function decodeEntity(source: string): string {
  const textarea = document.createElement('textarea');
  textarea.innerHTML = source;
  return textarea.value;
}

function escapeHTML(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function escapeAttribute(value: string): string {
  return escapeHTML(value).replaceAll('`', '&#96;');
}

const markerNodes = new Set([
  'CodeInfo',
  'CodeMark',
  'EmphasisMark',
  'HeaderMark',
  'LinkMark',
  'ListMark',
  'QuoteMark',
  'StrikethroughMark',
]);
