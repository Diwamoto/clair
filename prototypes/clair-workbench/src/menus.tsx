// What each surface's right-click menu holds. The menu component itself
// (contextMenu.tsx) knows nothing about files, panes or projects; the menus
// the ContextMenu artboard draws are spelled out here.

import { files, type FileKind } from './data';
import { item, separator, type MenuEntry, type MenuSpec } from './contextMenu';
import {
  IconBranch,
  IconBranchSmall,
  IconClaude,
  IconCloseThin,
  IconCodex,
  IconDoc,
  IconFolder,
  IconMarkdown,
  IconSession,
  IconSparkle,
  IconSplitDown,
  IconSplitRight,
  IconTerminalPrompt,
} from './icons';
import type { Screen, Workbench } from './store';

const ROOT = '~/Projects';
const byPath = new Map(files.map((f) => [f.path, f]));

const dirOf = (path: string) => (path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : '');

export function copyText(text: string) {
  try {
    void navigator.clipboard?.writeText(text).catch(() => undefined);
  } catch {
    /* the hosting frame refused clipboard access */
  }
}

export async function readClipboard(): Promise<string | null> {
  try {
    return (await navigator.clipboard?.readText()) ?? null;
  } catch {
    return null;
  }
}

function fileGlyph(kind: FileKind | undefined) {
  if (kind === 'md') return <IconMarkdown size={12} />;
  if (kind === 'swift') return <IconClaude size={12} />;
  return <IconDoc size={12} />;
}

/**
 * The agents a file or a selection can be handed to. An exited session stays
 * in the list, disabled, rather than vanishing — it is still where you left it.
 */
function agentsSubmenu(wb: Workbench, message: string): MenuEntry[] {
  return wb.sessions
    .filter((s) => s.icon !== 'zsh')
    .map((s) =>
      item(s.agent, {
        icon:
          s.icon === 'codex' ? (
            <IconCodex size={12} />
          ) : s.icon === 'claude' ? (
            <IconSparkle size={12} />
          ) : (
            <IconTerminalPrompt size={12} />
          ),
        detail: s.state === 'exit 1' ? 'exit 1' : [s.project, s.worktree].filter(Boolean).join(' · '),
        disabled: s.state === 'exit 1',
        run: () => {
          // Only clair's Claude Code has a conversation behind it in this
          // mock; every other agent opens the session rail it lives in.
          if (s.id === 's2') {
            wb.setScreen('activity');
            wb.sendMessage(message);
          } else {
            wb.setScreen('sessions');
          }
        },
      }),
    );
}

function paneEntries(wb: Workbench, paneId: string): MenuEntry[] {
  const maximized = wb.maximized === paneId;
  return [
    item('右に分割', {
      icon: <IconSplitRight size={12} />,
      shortcut: '⌃⌘D',
      run: () => wb.splitPane('horizontal', paneId),
    }),
    item('下に分割', {
      icon: <IconSplitDown size={12} />,
      shortcut: '⌃⌘⇧D',
      run: () => wb.splitPane('vertical', paneId),
    }),
    item(maximized ? '最大化を解除' : 'ペインを最大化', {
      shortcut: '⌃⌘M',
      run: () => wb.setMaximized(maximized ? null : paneId),
    }),
  ];
}

function closePaneEntry(wb: Workbench, paneId: string): MenuEntry {
  return item('ペインを閉じる', {
    shortcut: '⌃⌘W',
    destructive: true,
    disabled: wb.layout.kind === 'leaf',
    run: () => wb.closePane(paneId),
  });
}

/* ── titlebar ─────────────────────────────────────────────────────────── */

/** The chip's menu — the native app's project menu, with the colour picked in place. */
export function projectMenu(wb: Workbench, project: string): MenuSpec {
  const order = wb.projectOrder;
  const index = order.indexOf(project);
  const active = wb.activeProject === project;
  const collapsed = wb.collapsedProjects.has(project);
  return {
    header: { title: wb.projectLabels[project] ?? project, sub: `${ROOT}/${project}` },
    entries: [
      { type: 'swatches', value: wb.groupColors[project] ?? 'gray', onPick: (key) => wb.setGroupColor(project, key) },
      separator,
      item('このProjectに切り替え', { disabled: active, run: () => wb.setActiveProject(project) }),
      item(collapsed ? 'グループを展開' : 'グループを折りたたむ', { run: () => wb.toggleProjectCollapsed(project) }),
      item('Project名を変更…', { run: () => wb.setRenamingProject(project) }),
      separator,
      item('左へ移動', { disabled: index <= 0, run: () => wb.moveProject(project, -1) }),
      item('右へ移動', { disabled: index >= order.length - 1, run: () => wb.moveProject(project, 1) }),
      separator,
      item('Projectを閉じる', { destructive: true, disabled: order.length < 2, run: () => wb.closeProject(project) }),
    ],
  };
}

/** A file, from its tab or from the tree. The tab adds the close group on top. */
export function fileMenu(wb: Workbench, path: string, from: 'tab' | 'tree'): MenuSpec {
  const file = byPath.get(path);
  const tabIndex = wb.tabs.findIndex((t) => t.path === path);
  const changed = wb.workingPaths.has(path) || !!file?.status;

  const opening: MenuEntry[] =
    from === 'tab'
      ? [
          item('タブを閉じる', { icon: <IconCloseThin size={11} />, shortcut: '⌘W', run: () => wb.closeTab(path) }),
          item('他のタブを閉じる', { disabled: wb.tabs.length < 2, run: () => wb.closeOtherTabs(path) }),
          item('右側のタブを閉じる', {
            disabled: tabIndex < 0 || tabIndex === wb.tabs.length - 1,
            run: () => wb.closeTabsToRight(path),
          }),
          separator,
        ]
      : [item('開く', { shortcut: '↵', run: () => wb.openFile(path) })];

  return {
    header: { icon: fileGlyph(file?.kind), title: file?.name ?? path, sub: dirOf(path) || 'clair' },
    entries: [
      ...opening,
      item('右に分割して開く', { icon: <IconSplitRight size={12} />, run: () => wb.openInSplit(path, 'horizontal') }),
      item('下に分割して開く', { icon: <IconSplitDown size={12} />, run: () => wb.openInSplit(path, 'vertical') }),
      separator,
      item('Agentに送る', { icon: <IconSparkle size={12} />, submenu: agentsSubmenu(wb, `@${path} を見てください。`) }),
      item('変更を確認', {
        icon: <IconBranch size={12} />,
        disabled: !changed,
        run: () => {
          wb.setReviewFile(path);
          wb.setScreen('review');
        },
      }),
      separator,
      item('パスをコピー', { shortcut: '⌥⌘C', run: () => copyText(`${ROOT}/clair/${path}`) }),
      item('相対パスをコピー', { shortcut: '⌥⇧⌘C', run: () => copyText(path) }),
      item('Finderで表示', { icon: <IconFolder size={12} />, shortcut: '⌥⌘R' }),
    ],
  };
}

/** A tab that stands in for another project's file — the mock has nothing to open behind it. */
export function standInTabMenu(wb: Workbench, project: string, file: { path: string; name: string; kind: FileKind }): MenuSpec {
  return {
    header: { icon: fileGlyph(file.kind), title: file.name, sub: [project, dirOf(file.path)].filter(Boolean).join('/') },
    entries: [
      item('このProjectに切り替え', {
        disabled: wb.activeProject === project,
        run: () => wb.setActiveProject(project),
      }),
      separator,
      item('パスをコピー', { shortcut: '⌥⌘C', run: () => copyText(`${ROOT}/${project}/${file.path}`) }),
      item('相対パスをコピー', { shortcut: '⌥⇧⌘C', run: () => copyText(file.path) }),
    ],
  };
}

/** The Claude Code / codex tabs: a session, not a file. */
export function sessionTabMenu(wb: Workbench, label: string, screen: Screen): MenuSpec {
  const claude = screen === 'activity';
  return {
    header: {
      icon: claude ? <IconSparkle size={12} /> : <IconCodex size={12} />,
      title: label,
      sub: claude ? 'clair · pane-split' : 'clair · Project root',
    },
    entries: [
      item(claude ? '会話を開く' : 'セッションを開く', { run: () => wb.setScreen(screen) }),
      item('Agentsの一覧で表示', { icon: <IconSession size={12} />, shortcut: '⌃⌘L', run: () => wb.setScreen('sessions') }),
      separator,
      item('Agentを追加…', { shortcut: '⌃⌘N', run: () => wb.setOverlay('addAgent') }),
    ],
  };
}

/* ── file tree ────────────────────────────────────────────────────────── */

export function folderMenu(wb: Workbench, id: string, name: string, isProject: boolean): MenuSpec {
  const open = !wb.collapsed.has(id);
  const relative = isProject ? '' : id.slice(id.indexOf('/') + 1);
  return {
    header: {
      icon: isProject ? <IconBranchSmall size={11} /> : <IconFolder size={12} />,
      title: name,
      sub: isProject ? `${ROOT}/${id}` : id,
    },
    entries: [
      item(open ? '折りたたむ' : '展開', { run: () => wb.toggleFolder(id) }),
      separator,
      item('パスをコピー', { shortcut: '⌥⌘C', run: () => copyText(`${ROOT}/${id}`) }),
      item('相対パスをコピー', { shortcut: '⌥⇧⌘C', disabled: isProject, run: () => copyText(relative) }),
      item('Finderで表示', { icon: <IconFolder size={12} />, shortcut: '⌥⌘R' }),
    ],
  };
}

/* ── panes ────────────────────────────────────────────────────────────── */

export type EditorMenuContext = {
  paneId: string;
  path: string;
  selection: string;
  lines: [number, number];
  cut: () => void;
  copy: () => void;
  paste: () => void;
};

/** The editor's menu has no header: its target is a place in the text, not an object. */
export function editorMenu(wb: Workbench, ctx: EditorMenuContext): MenuSpec {
  const has = ctx.selection.length > 0;
  const dirty = wb.tabs.find((t) => t.path === ctx.path)?.dirty ?? false;
  const range = ctx.lines[1] !== ctx.lines[0] ? `${ctx.lines[0]}-${ctx.lines[1]}` : `${ctx.lines[0]}`;
  const message = has ? `@${ctx.path}:${range}\n${ctx.selection}` : `@${ctx.path} を見てください。`;
  return {
    entries: [
      item('切り取り', { shortcut: '⌘X', disabled: !has, run: ctx.cut }),
      item('コピー', { shortcut: '⌘C', disabled: !has, run: ctx.copy }),
      item('ペースト', { shortcut: '⌘V', run: ctx.paste }),
      separator,
      item(has ? '選択範囲をAgentに送る' : 'Agentに送る', {
        icon: <IconSparkle size={12} />,
        submenu: agentsSubmenu(wb, message),
      }),
      item('保存', { shortcut: '⌘S', disabled: !dirty, run: () => wb.saveFile(ctx.path) }),
      separator,
      ...paneEntries(wb, ctx.paneId),
      separator,
      closePaneEntry(wb, ctx.paneId),
    ],
  };
}

export type StreamMenuContext = {
  paneId: string;
  kind: 'terminal' | 'agent';
  selection: string;
  paste?: () => void;
};

/** Terminal and agent output: copy out, paste in, and the pane itself. */
export function streamMenu(wb: Workbench, ctx: StreamMenuContext): MenuSpec {
  const has = ctx.selection.length > 0;
  const own: MenuEntry[] =
    ctx.kind === 'terminal'
      ? [
          item('ペースト', { shortcut: '⌘V', run: ctx.paste }),
          // No ⌘K: in Clair that key is the command palette, not clear.
          item('クリア', { run: () => wb.runTerminal('clear') }),
        ]
      : [item('会話を開く', { icon: <IconSparkle size={12} />, run: () => wb.setScreen('activity') })];
  return {
    entries: [
      item('コピー', { shortcut: '⌘C', disabled: !has, run: () => copyText(ctx.selection) }),
      ...own,
      separator,
      ...paneEntries(wb, ctx.paneId),
      separator,
      closePaneEntry(wb, ctx.paneId),
    ],
  };
}
