import { Fragment } from 'react';

import { color } from './tokens';
import type { FileKind } from './data';

// One Dark token colours, taken from the code blocks the artboards draw.
const KEYWORDS: Record<string, string[]> = {
  swift: [
    'import', 'struct', 'class', 'enum', 'protocol', 'extension', 'func', 'var', 'let', 'private',
    'public', 'internal', 'static', 'return', 'if', 'else', 'guard', 'switch', 'case', 'for', 'in',
    'while', 'some', 'self', 'init', 'nil', 'true', 'false', 'throws', 'try', 'await', 'async',
  ],
  go: [
    'package', 'import', 'func', 'var', 'const', 'type', 'struct', 'interface', 'return', 'if',
    'else', 'for', 'range', 'switch', 'case', 'defer', 'go', 'map', 'nil', 'true', 'false',
  ],
  rust: ['use', 'fn', 'let', 'mut', 'pub', 'struct', 'enum', 'impl', 'match', 'return', 'if', 'else', 'for', 'in'],
  md: [],
};

const TYPE_RE = /^[A-Z][A-Za-z0-9_]*$/;

type Token = { text: string; color?: string };

function tokenizeLine(line: string, kind: FileKind): Token[] {
  if (kind === 'md') {
    if (line.startsWith('#')) return [{ text: line, color: color.codeType }];
    return [{ text: line }];
  }

  const commentAt = line.indexOf('//');
  let body = line;
  let comment = '';
  if (commentAt >= 0) {
    body = line.slice(0, commentAt);
    comment = line.slice(commentAt);
  }

  const keywords = KEYWORDS[kind] ?? [];
  const tokens: Token[] = [];
  // Split on word boundaries, strings and numbers while keeping separators.
  const parts = body.split(/("[^"]*"|\b[A-Za-z_][A-Za-z0-9_]*\b|\b\d+\.?\d*\b)/g);

  for (let i = 0; i < parts.length; i += 1) {
    const part = parts[i];
    if (!part) continue;
    if (part.startsWith('"') && part.endsWith('"') && part.length > 1) {
      tokens.push({ text: part, color: color.codeString });
    } else if (/^\d/.test(part) && /^[\d.]+$/.test(part)) {
      tokens.push({ text: part, color: color.codeNumber });
    } else if (keywords.includes(part)) {
      tokens.push({ text: part, color: color.codeKeyword });
    } else if (TYPE_RE.test(part)) {
      tokens.push({ text: part, color: color.codeType });
    } else if (/^[A-Za-z_]/.test(part) && parts[i + 1]?.startsWith('(')) {
      tokens.push({ text: part, color: color.codeFunc });
    } else {
      tokens.push({ text: part });
    }
  }

  if (comment) tokens.push({ text: comment, color: color.codeComment });
  return tokens;
}

export function HighlightedLine({ line, kind }: { line: string; kind: FileKind }) {
  const tokens = tokenizeLine(line, kind);
  return (
    <>
      {tokens.map((token, i) => (
        <Fragment key={i}>
          {token.color ? <span style={{ color: token.color }}>{token.text}</span> : token.text}
        </Fragment>
      ))}
      {'\n'}
    </>
  );
}
