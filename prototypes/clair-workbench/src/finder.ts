// The file browser's disk. The mock has none, so this is a small fixed tree
// rooted at the user's home; Project files under ~/Projects/clair point at the
// same contents the editor already shows (data.ts), so "Clair で開く" lands on
// a real tab. Everything else is listing-only.

import { files, type FileKind } from './data';

export const HOME = '/Users/daiki';
export const PROJECT_ROOT = `${HOME}/Projects/clair`;

export type FsEntry = {
  name: string;
  path: string;
  dir: boolean;
  size?: string;
  modified: string;
  /** Text Clair's editor can open. Anything else goes to another app. */
  text?: boolean;
  kind?: FileKind;
  /** The Project-relative path when the file is one the editor knows. */
  projectPath?: string;
};

/** A file browser tab's path in `wb.tabs`: the folder it starts from, behind a scheme no file path has. */
export const finderTab = (folder: string) => `finder:${folder}`;
export const finderRoot = (tabPath: string) => (tabPath.startsWith('finder:') ? tabPath.slice('finder:'.length) : null);

type Node = { name: string; dir?: Node[]; size?: string; modified?: string; text?: boolean };

const f = (name: string, size: string, modified: string, text = false): Node => ({ name, size, modified, text });
const d = (name: string, children: Node[], modified = '10/12'): Node => ({ name, dir: children, modified });

const projectFiles = (prefix: string) =>
  files
    .filter((file) => file.path.startsWith(prefix + '/') && !file.path.slice(prefix.length + 1).includes('/'))
    .map((file) => f(file.name, `${(file.content.length / 1024).toFixed(1)} KB`, '今日 14:02', true));

const disk: Node = d('daiki', [
  d('Desktop', [f('スクリーンショット 2026-10-18 21.04.12.png', '1.2 MB', '昨日 21:04'), f('memo.txt', '2 KB', '10/15', true)]),
  d('Documents', [
    d('請求書', [f('2026-09.pdf', '84 KB', '10/01'), f('2026-10.pdf', '86 KB', '今日 09:12')]),
    f('職務経歴書.docx', '48 KB', '9/03'),
  ]),
  d('Downloads', [
    f('ghostty-1.3.0.dmg', '18.4 MB', '10/11'),
    f('design-review.pdf', '2.1 MB', '昨日 18:40'),
    f('api-response.json', '12 KB', '今日 11:30', true),
    f('logo.svg', '4 KB', '10/02', true),
    f('archive.zip', '7.7 MB', '9/28'),
  ]),
  d('Projects', [
    d('clair', [
      d('apple', [d('ClairApp', projectFiles('apple/ClairApp'), '今日 14:02')], '今日 14:02'),
      d('crates', [d('clair-ptyhost', [d('src', [f('pty.rs', '6.4 KB', '今日 13:51', true)]), f('Cargo.toml', '1 KB', '10/09', true)])]),
      d('docs', [d('architecture', projectFiles('docs/architecture'))]),
      d('dist', [f('Clair.app.zip', '41 MB', '10/17')]),
      f('.gitignore', '1 KB', '9/21', true),
      f('AGENTS.md', '3 KB', '10/16', true),
      f('Package.swift', '9 KB', '10/16', true),
      f('README.md', '6 KB', '10/16', true),
    ]),
    d('ccedit', [f('README.md', '4 KB', '9/21', true)]),
    d('clair-docs', [d('site', projectFiles('clair-docs/site'))]),
  ]),
  f('.zshrc', '3 KB', '9/30', true),
]);

const kindOf = (name: string): FileKind | undefined =>
  name.endsWith('.swift') ? 'swift' : name.endsWith('.md') ? 'md' : name.endsWith('.rs') ? 'rust' : name.endsWith('.go') ? 'go' : undefined;

function find(path: string): Node | undefined {
  if (path === HOME) return disk;
  if (!path.startsWith(HOME + '/')) return undefined;
  let node: Node | undefined = disk;
  for (const part of path.slice(HOME.length + 1).split('/')) node = node?.dir?.find((c) => c.name === part);
  return node;
}

/** Hidden like Finder: dotfiles stay out unless ⇧⌘. turns them on. */
export const isHidden = (name: string) => name.startsWith('.');

const toEntry = (parent: string, node: Node): FsEntry => {
  const path = `${parent}/${node.name}`;
  const projectPath = path.startsWith(PROJECT_ROOT + '/') ? path.slice(PROJECT_ROOT.length + 1) : undefined;
  const known = projectPath ? files.some((file) => file.path === projectPath) : false;
  // clair-docs is an added folder of the clair Project (ADR-0017); its files keep their prefix.
  const docsPath = path.startsWith(`${HOME}/Projects/clair-docs/`) ? path.slice(`${HOME}/Projects/`.length) : undefined;
  return {
    name: node.name,
    path,
    dir: !!node.dir,
    size: node.size,
    modified: node.modified ?? '',
    text: node.text,
    kind: kindOf(node.name),
    projectPath: known ? projectPath : docsPath && files.some((file) => file.path === docsPath) ? docsPath : undefined,
  };
};

/**
 * One folder's listing — the only read the browser makes. Nothing below it is
 * touched until that folder is opened, which is the native contract too
 * (a column lists its own folder, off the main thread, when it appears).
 */
export function listDir(path: string): FsEntry[] | null {
  const node = find(path);
  if (!node?.dir) return null;
  return node.dir
    .map((child) => toEntry(path, child))
    .sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name, 'ja') : a.dir ? -1 : 1));
}

export function entryAt(path: string): FsEntry | null {
  const node = find(path);
  if (!node) return null;
  return toEntry(path.slice(0, path.lastIndexOf('/')) || '/', node);
}

/** A first look at a text file: the editor's contents when it knows the file, a stand-in otherwise. */
export function previewText(entry: FsEntry): string | null {
  if (!entry.text) return null;
  const known = entry.projectPath ? files.find((file) => file.path === entry.projectPath) : undefined;
  if (known) return known.content;
  if (entry.name.endsWith('.json')) return '{\n  "id": "req_01",\n  "status": "ok",\n  "items": [ … ]\n}';
  if (entry.name.endsWith('.toml')) return '[package]\nname = "clair-ptyhost"\nedition = "2021"';
  return `# ${entry.name}\n…`;
}

/** Where a path reads from, Finder-style: `~` for home, the rest as is. */
export const tildify = (path: string) => (path === HOME ? '~' : path.startsWith(HOME + '/') ? '~' + path.slice(HOME.length) : path);

/**
 * The text a dropped path becomes on a command line. Same rule as Ghostty's
 * own drop: backslash before every character a shell would read as syntax,
 * so `foo bar.png` arrives as one argument.
 */
export function shellEscape(path: string) {
  return path.replace(/[\s\\'"`$!&*()[\]{}<>|;#?~^]/g, (c) => `\\${c}`);
}

/** The places column: where Finder's sidebar would take you. */
export const places: { label: string; path: string }[] = [
  { label: 'clair', path: PROJECT_ROOT },
  { label: 'ホーム', path: HOME },
  { label: 'デスクトップ', path: `${HOME}/Desktop` },
  { label: '書類', path: `${HOME}/Documents` },
  { label: 'ダウンロード', path: `${HOME}/Downloads` },
];

/** Other apps for "このアプリケーションで開く ›", by extension. The native list comes from Launch Services. */
export function appsFor(entry: FsEntry): string[] {
  const ext = entry.name.includes('.') ? entry.name.slice(entry.name.lastIndexOf('.') + 1) : '';
  if (['png', 'svg'].includes(ext)) return ['プレビュー', 'Safari', 'Figma'];
  if (ext === 'pdf') return ['プレビュー', 'Safari'];
  if (ext === 'docx') return ['Pages', 'Microsoft Word'];
  if (['zip', 'dmg'].includes(ext)) return ['アーカイブユーティリティ', 'DiskImageMounter'];
  if (entry.dir) return ['Finder', 'ターミナル'];
  return ['TextEdit', 'Xcode', 'Visual Studio Code'];
}
