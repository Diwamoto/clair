// The file browser pane: Finder's column view inside a Clair pane.
//
// - Columns flow left to right. Opening a folder adds its column on the
//   right; picking something further left drops every column after it.
// - A folder is listed only when its column appears (`listDir`, one level),
//   never the whole tree up front; the first look shows a loading row.
// - A text file opens in Clair; anything else goes to its default app or
//   one picked from "このアプリケーションで開く ›".
// - Rows drag out as paths: dropped on a terminal they arrive shell-escaped
//   on its input line (TerminalPane), the same as a drop from the macOS Finder.
//
// Values are the tree's (24px rows, radius.control, surfaceActive for the
// selection) and the pane header's; nothing here is a new token.

import { Fragment, useEffect, useMemo, useRef, useState } from 'react';

import { targetRing, useContextMenu } from '../contextMenu';
import { FileIcon } from '../chrome';
import { HOME, isHidden, listDir, places, previewText, shellEscape, tildify, type FsEntry } from '../finder';
import { IconChevron, IconChevronLeft, IconDoc, IconFolder } from '../icons';
import { finderBackgroundMenu, finderEntryMenu } from '../menus';
import { useWorkbench } from '../store';
import { color, fs, line, radius, space } from '../tokens';

const COLUMN = 200;
const PLACES = 140;
const PREVIEW = 240;
// The mock's disk answers at once; this stands in for a real folder read so
// the lazy listing is visible.
const LOAD_MS = 220;

/** The drag payload every path source shares (file browser rows, explorer rows). */
export const PATHS_TYPE = 'application/x-clair-paths';

export function setPathDrag(event: React.DragEvent, paths: string[]) {
  event.dataTransfer.setData(PATHS_TYPE, JSON.stringify(paths));
  event.dataTransfer.setData('text/plain', paths.map(shellEscape).join(' '));
  event.dataTransfer.effectAllowed = 'copy';
}

export function readPathDrag(event: React.DragEvent): string[] | null {
  const raw = event.dataTransfer.getData(PATHS_TYPE);
  if (!raw) return null;
  try {
    const paths = JSON.parse(raw);
    return Array.isArray(paths) ? paths.filter((p): p is string => typeof p === 'string') : null;
  } catch {
    return null;
  }
}

type View = { columns: string[]; selection: string[] };

// Where each tab was left, so switching tabs and back restores its columns.
// ponytail: module-level, the mock's lifetime; native keeps it in the tab's own state.
const kept = new Map<string, View>();

export function FinderPane({ paneId, tab, root }: { paneId: string; tab: string; root: string }) {
  const wb = useWorkbench();
  const menu = useContextMenu();
  const [view, setView] = useState<View>(() => kept.get(tab) ?? { columns: [root], selection: [] });
  useEffect(() => void kept.set(tab, view), [tab, view]);
  const [back, setBack] = useState<View[]>([]);
  const [forward, setForward] = useState<View[]>([]);
  const [listings, setListings] = useState<Record<string, FsEntry[] | 'loading' | null>>({});
  const [showHidden, setShowHidden] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const focused = wb.focusedPane === paneId;

  // Lazy listing: a folder is read the first time its column shows.
  useEffect(() => {
    for (const folder of view.columns) {
      if (folder in listings) continue;
      setListings((current) => ({ ...current, [folder]: 'loading' }));
      setTimeout(() => setListings((current) => ({ ...current, [folder]: listDir(folder) })), LOAD_MS);
    }
  }, [view.columns, listings]);

  // The newest column is the one you are reading: keep it in view.
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTo({ left: el.scrollWidth, behavior: 'smooth' });
  }, [view.columns.length, view.selection]);

  useEffect(() => {
    if (!notice) return;
    const timer = setTimeout(() => setNotice(null), 2400);
    return () => clearTimeout(timer);
  }, [notice]);

  const entries = (folder: string): FsEntry[] | 'loading' | null => {
    const listed = listings[folder];
    if (listed === undefined || listed === 'loading' || listed === null) return listed ?? 'loading';
    return [...listed, ...(wb.fsCopies[folder] ?? [])]
      .filter((e) => !wb.fsTrashed.has(e.path) && (showHidden || !isHidden(e.name)))
      .sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name, 'ja') : a.dir ? -1 : 1));
  };

  const go = (next: View) => {
    setBack((b) => [...b, view]);
    setForward([]);
    setView(next);
  };

  const all = useMemo(() => new Map(view.columns.flatMap((c) => {
    const list = entries(c);
    return Array.isArray(list) ? list.map((e) => [e.path, e] as const) : [];
  })), [view.columns, listings, wb.fsCopies, wb.fsTrashed, showHidden]); // eslint-disable-line react-hooks/exhaustive-deps

  const picked = view.selection.length === 1 ? all.get(view.selection[0]) : undefined;
  const columnOf = (path: string) => view.columns.indexOf(path.slice(0, path.lastIndexOf('/')));

  const select = (entry: FsEntry, index: number, toggle: boolean) => {
    wb.setFocusedPane(paneId);
    const columns = view.columns.slice(0, index + 1);
    if (toggle && view.selection.length && columnOf(view.selection[0]) === index) {
      const has = view.selection.includes(entry.path);
      const selection = has ? view.selection.filter((p) => p !== entry.path) : [...view.selection, entry.path];
      return setView({ columns, selection });
    }
    setView({ columns: entry.dir ? [...columns, entry.path] : columns, selection: [entry.path] });
  };

  const open = (entry: FsEntry, app?: string) => {
    if (entry.dir && !app) return go({ columns: [...view.columns.slice(0, columnOf(entry.path) + 1), entry.path], selection: [] });
    if (!app && entry.text && entry.projectPath) return wb.openFile(entry.projectPath);
    // The mock has no other apps (and no editor for files outside its Project); say what native would do.
    setNotice(app ? `${app} で開きました — ${entry.name}` : entry.text ? `Clair で開きました(Project 外のファイル) — ${entry.name}` : `既定のアプリで開きました — ${entry.name}`);
  };

  const actions = {
    open,
    notice: setNotice,
    reveal: (path: string) => go({ columns: [path], selection: [] }),
    paste: (folder: string) => {
      const list = entries(folder);
      const n = wb.pasteFiles(folder, Array.isArray(list) ? list.map((e) => e.name) : []);
      if (n) setNotice(`${n} 項目をペーストしました`);
    },
    trash: (paths: string[]) => {
      wb.trashFiles(paths);
      setView((v) => ({ ...v, selection: [], columns: v.columns.filter((c) => !paths.some((p) => c === p || c.startsWith(p + '/'))) }));
    },
    showHidden,
    toggleHidden: () => setShowHidden((h) => !h),
  };

  const onKeyDown = (event: React.KeyboardEvent) => {
    const meta = event.metaKey || event.ctrlKey;
    const current = view.selection[view.selection.length - 1];
    const index = current ? columnOf(current) : 0;
    const list = entries(view.columns[Math.max(0, index)]);
    if (meta && event.shiftKey && event.key === '.') {
      event.preventDefault();
      return actions.toggleHidden();
    }
    if (meta && event.altKey && event.key.toLowerCase() === 'c' && view.selection.length) {
      event.preventDefault();
      void navigator.clipboard?.writeText(view.selection.join('\n')).catch(() => undefined);
      return setNotice('パスをコピーしました');
    }
    if (meta && event.key.toLowerCase() === 'c' && view.selection.length) {
      event.preventDefault();
      wb.setFileClipboard(view.selection);
      return setNotice(`${view.selection.length} 項目をコピーしました`);
    }
    if (meta && event.key.toLowerCase() === 'v') {
      event.preventDefault();
      return actions.paste(picked?.dir ? picked.path : view.columns[Math.max(0, index)]);
    }
    if (meta && event.key === 'Backspace' && view.selection.length) {
      event.preventDefault();
      return actions.trash(view.selection);
    }
    if (!Array.isArray(list)) return;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const at = list.findIndex((e) => e.path === current);
      const next = list[Math.max(0, Math.min(list.length - 1, at + (event.key === 'ArrowDown' ? 1 : -1)))];
      if (next) select(next, Math.max(0, index), false);
    } else if (event.key === 'ArrowRight' && picked?.dir) {
      event.preventDefault();
      const inner = entries(picked.path);
      if (Array.isArray(inner) && inner[0]) select(inner[0], view.columns.indexOf(picked.path), false);
    } else if (event.key === 'ArrowLeft' && index > 0) {
      event.preventDefault();
      setView({ columns: view.columns.slice(0, index + 1), selection: [view.columns[index]] });
    } else if (event.key === 'Enter' && picked) {
      event.preventDefault();
      open(picked);
    }
  };

  // Path bar: `~` for home, then one segment per folder down to what is selected.
  const crumbs = (() => {
    const deepest = picked?.path ?? view.columns[view.columns.length - 1];
    const base = deepest === HOME || deepest.startsWith(HOME + '/') ? HOME : '';
    const rest = deepest.slice(base.length).split('/').filter(Boolean);
    return [
      ...(base ? [{ label: '~', path: HOME }] : []),
      ...rest.map((part, i) => ({ label: part, path: `${base}/${rest.slice(0, i + 1).join('/')}` })),
    ];
  })();

  const count = (() => {
    const last = view.columns[view.columns.length - 1];
    const list = entries(last);
    return Array.isArray(list) ? list.length : 0;
  })();

  return (
    <div onMouseDown={() => wb.setFocusedPane(paneId)} style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, background: color.canvas }}>
      {/* Toolbar: back / forward and the path of what is selected (click a segment to start the columns there). */}
      <div style={{ height: 28, flexShrink: 0, display: 'flex', alignItems: 'center', gap: space[1], padding: '0 8px', borderBottom: `1px solid ${line.hairlineFaint}` }}>
        <NavButton label="戻る" disabled={!back.length} onClick={() => { setForward((f) => [view, ...f]); setView(back[back.length - 1]); setBack((b) => b.slice(0, -1)); }}>
          <IconChevronLeft size={11} />
        </NavButton>
        <NavButton label="進む" disabled={!forward.length} onClick={() => { setBack((b) => [...b, view]); setView(forward[0]); setForward((f) => f.slice(1)); }}>
          <IconChevron size={11} />
        </NavButton>
        <div className="cl" style={{ flex: 1, minWidth: 0, display: 'flex', alignItems: 'center', gap: space[1], overflow: 'hidden', marginLeft: space[1] }}>
          {crumbs.map((c, i) => {
            const last = i === crumbs.length - 1;
            return (
              <Fragment key={c.path + i}>
                {i > 0 ? <span style={{ fontSize: fs.caption, color: color.textQuaternary, flexShrink: 0 }}>›</span> : null}
                <button
                  className="hoverable"
                  onClick={() => (all.get(c.path)?.dir === false ? undefined : go({ columns: [c.path], selection: [] }))}
                  style={{ fontSize: fs.caption, padding: '1px 4px', borderRadius: radius.control, whiteSpace: 'nowrap', fontWeight: last ? 600 : 400, color: last ? color.textSecondary : color.textQuaternary, flexShrink: last ? 0 : 1, overflow: 'hidden', textOverflow: 'ellipsis' }}
                >
                  {c.label}
                </button>
              </Fragment>
            );
          })}
        </div>
      </div>

      <div
        tabIndex={0}
        onKeyDown={onKeyDown}
        onMouseDown={() => wb.setFocusedPane(paneId)}
        style={{ flex: 1, minHeight: 0, display: 'flex', outline: 'none' }}
      >
        {/* Places: Finder's sidebar, as the first, fixed column. */}
        <div className="scroll" style={{ width: PLACES, flexShrink: 0, padding: '6px 0', background: color.panel, borderRight: `1px solid ${line.hairlineFaint}` }}>
          <div style={{ fontSize: fs.caption, color: color.textQuaternary, padding: '4px 16px 6px' }}>場所</div>
          {places.map((p) => {
            const on = view.columns[0] === p.path;
            return (
              <button
                key={p.path}
                className={on ? undefined : 'hoverable'}
                onClick={() => go({ columns: [p.path], selection: [] })}
                style={{ ...rowStyle(on, false), paddingLeft: 8 }}
              >
                <IconFolder size={12} color={color.textTertiary} />
                <span style={{ fontSize: fs.secondary, color: on ? color.textPrimary : color.textSecondary, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.label}</span>
              </button>
            );
          })}
        </div>

        <div ref={scrollRef} className="scroll" style={{ flex: 1, minWidth: 0, display: 'flex', overflowX: 'auto', overflowY: 'hidden' }}>
          {view.columns.map((folder, index) => {
            const list = entries(folder);
            return (
              <div
                key={folder}
                className="scroll"
                onContextMenu={(event) => {
                  if (event.target !== event.currentTarget) return;
                  menu(event, (w) => finderBackgroundMenu(w, folder, actions));
                }}
                style={{ width: COLUMN, flexShrink: 0, padding: '4px 0', borderRight: `1px solid ${line.hairlineFaint}`, overflowY: 'auto' }}
              >
                {list === 'loading' ? (
                  <div style={{ fontSize: fs.secondary, color: color.textTertiary, padding: '4px 16px' }}>読み込み中…</div>
                ) : list === null ? (
                  <div style={{ fontSize: fs.secondary, color: color.textTertiary, padding: '4px 16px' }}>開けません</div>
                ) : list.length === 0 ? (
                  <div style={{ fontSize: fs.secondary, color: color.textQuaternary, padding: '4px 16px' }}>空のフォルダ</div>
                ) : (
                  list.map((entry) => {
                    const selected = view.selection.includes(entry.path) || view.columns[index + 1] === entry.path;
                    // The trail (a folder whose column is open to the right) keeps a quieter wash once focus moved on.
                    const trail = !view.selection.includes(entry.path) && selected;
                    const targeted = wb.contextMenu?.target === `${paneId}:${entry.path}`;
                    return (
                      <button
                        key={entry.path}
                        draggable
                        onDragStart={(event) => setPathDrag(event, view.selection.includes(entry.path) ? view.selection : [entry.path])}
                        className={selected ? 'finder-row' : 'finder-row hoverable'}
                        onClick={(event) => select(entry, index, event.metaKey || event.ctrlKey)}
                        onDoubleClick={() => open(entry)}
                        onContextMenu={(event) => {
                          if (!view.selection.includes(entry.path)) select(entry, index, false);
                          const paths = view.selection.includes(entry.path) ? view.selection : [entry.path];
                          menu(event, (w) => finderEntryMenu(w, entry, paths, actions), `${paneId}:${entry.path}`);
                        }}
                        title={tildify(entry.path)}
                        style={{ ...rowStyle(selected && !trail, trail), boxShadow: targeted ? targetRing : undefined }}
                      >
                        {entry.dir ? (
                          <IconFolder size={12} color={color.textTertiary} />
                        ) : entry.kind ? (
                          <FileIcon kind={entry.kind} tint={color.textTertiary} />
                        ) : (
                          <IconDoc size={12} color={color.textTertiary} />
                        )}
                        <span style={{ flex: 1, minWidth: 0, fontSize: fs.secondary, color: isHidden(entry.name) ? color.textQuaternary : selected ? color.textPrimary : color.textSecondary, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                          {entry.name}
                        </span>
                        {entry.dir ? <IconChevron size={9} color={color.textQuaternary} /> : null}
                      </button>
                    );
                  })
                )}
                {/* The empty space below the rows is the column's own: right-click it for paste / hidden files. */}
                <div
                  style={{ minHeight: 40, height: '100%' }}
                  onContextMenu={(event) => menu(event, (w) => finderBackgroundMenu(w, folder, actions))}
                  onClick={() => setView({ columns: view.columns.slice(0, index + 1), selection: [] })}
                />
              </div>
            );
          })}
          {picked && !picked.dir ? <Preview entry={picked} open={open} /> : null}
          {view.selection.length > 1 ? (
            <div style={{ width: PREVIEW, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: fs.secondary, color: color.textTertiary }}>
              {view.selection.length} 項目を選択
            </div>
          ) : null}
        </div>
      </div>

      {/* Footer: Finder's item count, or what the last action did. */}
      <div style={{ height: 22, flexShrink: 0, display: 'flex', alignItems: 'center', padding: '0 12px', fontSize: fs.caption, color: notice ? color.textSecondary : color.textQuaternary, borderTop: `1px solid ${line.hairlineFaint}`, opacity: focused || notice ? 1 : 0.8 }}>
        {notice ?? `${count} 項目${view.selection.length ? ` · ${view.selection.length} 項目を選択` : ''}${showHidden ? ' · 隠しファイルを表示中' : ''}`}
      </div>
    </div>
  );
}

function rowStyle(selected: boolean, trail: boolean): React.CSSProperties {
  return {
    display: 'flex',
    alignItems: 'center',
    gap: 8,
    height: 24,
    width: 'calc(100% - 12px)',
    margin: '0 6px',
    padding: '0 8px',
    borderRadius: radius.control,
    background: selected ? color.surfaceActive : trail ? color.surfaceHover : undefined,
  };
}

function NavButton({ label, disabled, onClick, children }: { label: string; disabled: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      title={label}
      aria-label={label}
      disabled={disabled}
      onClick={onClick}
      className={disabled ? undefined : 'hoverable'}
      style={{ width: 22, height: 22, display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: radius.control, color: disabled ? color.textQuaternary : color.textTertiary, opacity: disabled ? 0.5 : 1, cursor: disabled ? 'default' : 'pointer' }}
    >
      {children}
    </button>
  );
}

/** The last column for a single file: what it is, a first look, and how to open it. */
function Preview({ entry, open }: { entry: FsEntry; open: (entry: FsEntry, app?: string) => void }) {
  const text = previewText(entry);
  return (
    <div className="scroll" style={{ width: PREVIEW, flexShrink: 0, padding: '16px 16px 12px', display: 'flex', flexDirection: 'column', gap: space[2], overflowY: 'auto' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: space[2] }}>
        {entry.kind ? <FileIcon kind={entry.kind} tint={color.textTertiary} /> : <IconDoc size={16} color={color.textTertiary} />}
        <span style={{ fontSize: fs.body, fontWeight: 600, color: color.textPrimary, wordBreak: 'break-all' }}>{entry.name}</span>
      </div>
      <div className="tnum" style={{ fontSize: fs.caption, color: color.textTertiary, lineHeight: '16px' }}>
        {entry.size} · 変更 {entry.modified}
        <br />
        {tildify(entry.path)}
      </div>
      {text !== null ? (
        <pre className="cl" style={{ margin: 0, padding: '8px 10px', fontSize: fs.caption, lineHeight: '16px', color: color.code, background: color.panel, borderRadius: radius.card, whiteSpace: 'pre', overflow: 'hidden', maxHeight: 16 * 14 + 16 }}>
          {text.split('\n').slice(0, 14).join('\n')}
        </pre>
      ) : (
        <div style={{ height: 120, display: 'flex', alignItems: 'center', justifyContent: 'center', background: color.panel, borderRadius: radius.card, fontSize: fs.caption, color: color.textQuaternary }}>
          Clair ではプレビューできません
        </div>
      )}
      <div style={{ display: 'flex', gap: space[1], flexWrap: 'wrap' }}>
        {entry.text ? (
          <button className="btn-primary" onClick={() => open(entry)} style={buttonStyle}>Clair で開く</button>
        ) : null}
        <button className={entry.text ? 'btn-secondary' : 'btn-primary'} onClick={() => open(entry, entry.text ? 'TextEdit' : undefined)} style={buttonStyle}>
          {entry.text ? '他のアプリで開く' : '既定のアプリで開く'}
        </button>
      </div>
    </div>
  );
}

const buttonStyle: React.CSSProperties = { height: 26, padding: '0 10px', borderRadius: radius.control, fontSize: fs.secondary };
