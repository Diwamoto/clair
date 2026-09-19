import { Fragment, useCallback, useEffect, useRef, useState } from 'react';

import { targetRing, useContextMenu } from '../contextMenu';
import { files, tree } from '../data';
import { HighlightedLine } from '../highlight';
import { IconBranchSmall } from '../icons';
import { copyText, editorMenu, fileMenu, folderMenu, readClipboard, streamMenu } from '../menus';
import { useWorkbench, type PaneNode } from '../store';
import { FileIcon } from '../chrome';
import { color, fs, line, mono, radius, space } from '../tokens';

const byPath = new Map(files.map((f) => [f.path, f]));

const INDENT: Record<number, number> = { 0: 10, 1: 22, 2: 36, 3: 55 };

/* ── sidebar ──────────────────────────────────────────────────────────── */

export function ExplorerPanel() {
  const wb = useWorkbench();
  const menu = useContextMenu();

  // A row whose menu is open wears a ring, inset from the sidebar edge the
  // way the selected row already is.
  const ringed = (id: string, indent: number, base: string) =>
    wb.contextMenu?.target === id
      ? {
          width: 'calc(100% - 16px)',
          margin: '0 8px',
          padding: `0 10px 0 ${indent - 8}px`,
          borderRadius: radius.card,
          boxShadow: targetRing,
        }
      : { width: '100%', padding: base };

  const hidden = (parent: string | undefined) => {
    let cursor = parent;
    while (cursor) {
      if (wb.collapsed.has(cursor)) return true;
      cursor = cursor.includes('/') ? cursor.slice(0, cursor.lastIndexOf('/')) : undefined;
    }
    return false;
  };

  return (
    <div className="scroll" style={{ position: 'absolute', inset: 0, padding: '4px 0' }}>
        {tree.map((node) => {
          if (node.type !== 'project' && hidden(node.parent)) return null;

          if (node.type === 'project') {
            const open = !wb.collapsed.has(node.id);
            return (
              <button
                key={node.id}
                onClick={() => wb.toggleFolder(node.id)}
                onContextMenu={(event) => menu(event, (w) => folderMenu(w, node.id, node.name, true), node.id)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: space[1],
                  height: 24,
                  ...ringed(node.id, 10, '0 10px'),
                  color: color.attention,
                }}
              >
                {open ? '▾' : '▸'}
                <IconBranchSmall size={10} />
                <span style={{ fontSize: fs.caption, fontWeight: 700, marginLeft: 2 }}>{node.name}</span>
              </button>
            );
          }

          if (node.type === 'folder') {
            const open = !wb.collapsed.has(node.id);
            return (
              <button
                key={node.id}
                onClick={() => wb.toggleFolder(node.id)}
                onContextMenu={(event) => menu(event, (w) => folderMenu(w, node.id, node.name, false), node.id)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: space[1],
                  height: 24,
                  ...ringed(node.id, INDENT[node.depth] ?? 22, `0 10px 0 ${INDENT[node.depth] ?? 22}px`),
                  color: color.textSecondary,
                }}
              >
                {open ? '▾' : '▸'}
                <span style={{ fontSize: fs.caption, marginLeft: 2 }}>{node.name}</span>
              </button>
            );
          }

          const file = byPath.get(node.path);
          const selected = wb.activePath === node.path;
          const dirty = wb.tabs.find((t) => t.path === node.path)?.dirty;
          const status = dirty ? 'M' : file?.status;
          const targeted = wb.contextMenu?.target === node.id;
          const framed = selected || targeted;
          return (
            <button
              key={node.id}
              className={selected ? undefined : 'hoverable'}
              onClick={() => wb.openFile(node.path)}
              onContextMenu={(event) => menu(event, (w) => fileMenu(w, node.path, 'tree'), node.id)}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: space[1],
                width: framed ? 'calc(100% - 16px)' : '100%',
                height: selected ? 28 : 26,
                padding: `0 10px 0 ${(INDENT[node.depth] ?? 36) - (framed ? 8 : 0)}px`,
                margin: framed ? '0 8px' : undefined,
                borderRadius: framed ? 7 : undefined,
                background: selected ? 'rgba(255,255,255,0.08)' : undefined,
                boxShadow: targeted ? targetRing : undefined,
                color: selected ? color.textPrimary : color.textTertiary,
              }}
            >
              <FileIcon kind={file?.kind ?? 'swift'} tint={selected ? '#cfd3ce' : color.textTertiary} />
              <span style={{ fontSize: fs.caption, flex: 1, fontWeight: selected ? 500 : 400 }}>{node.name}</span>
              {status ? (
                <span
                  style={{
                    fontSize: fs.caption,
                    fontWeight: 600,
                    color: status === 'A' ? color.success : color.attention,
                  }}
                >
                  {status}
                </span>
              ) : null}
            </button>
          );
      })}
    </div>
  );
}

/* ── panes ────────────────────────────────────────────────────────────── */

/**
 * The open file's path, one segment per directory plus the filename, at the
 * top of the pane it belongs to. A deliberate exception to the "no header
 * row per pane" rule on the Tokens artboard — see that artboard's own note
 * for the trade-off this accepts (the 74px chrome budget no longer holds
 * once an editor is split; each editor pane now carries its own 24px row).
 */
function PathBreadcrumb({ path }: { path: string }) {
  const parts = path.split('/');
  return (
    <div
      className="cl"
      style={{
        height: 24,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'center',
        gap: space[1],
        padding: '0 12px',
        overflow: 'hidden',
        background: color.canvas,
      }}
    >
      {parts.map((part, i) => {
        const last = i === parts.length - 1;
        return (
          <Fragment key={i}>
            {i > 0 ? (
              <span style={{ fontSize: fs.caption, color: color.textQuaternary, flexShrink: 0 }}>›</span>
            ) : null}
            <span
              style={{
                fontSize: fs.caption,
                fontWeight: last ? 600 : 400,
                color: last ? color.textSecondary : color.textQuaternary,
                whiteSpace: 'nowrap',
                flexShrink: last ? 0 : 1,
                overflow: 'hidden',
                textOverflow: 'ellipsis',
              }}
            >
              {part}
            </span>
          </Fragment>
        );
      })}
    </div>
  );
}

function EditorPane({ node }: { node: Extract<PaneNode, { kind: 'leaf' }> }) {
  const wb = useWorkbench();
  const path = node.filePath ?? wb.activePath;
  const file = byPath.get(path);
  const text = wb.contents[path] ?? '';
  const lines = text.split('\n');
  const areaRef = useRef<HTMLTextAreaElement>(null);
  const preRef = useRef<HTMLPreElement>(null);
  const gutterRef = useRef<HTMLDivElement>(null);
  const [caretLine, setCaretLine] = useState(1);
  const menu = useContextMenu();

  // The selection is read when the menu opens, not when an item runs: by
  // then focus has moved into the menu and back.
  const openMenu = (event: React.MouseEvent) => {
    const area = areaRef.current;
    if (!area) return;
    const start = area.selectionStart;
    const end = area.selectionEnd;
    const selection = area.value.slice(start, end);
    const first = area.value.slice(0, start).split('\n').length;
    const refocus = (caret?: number) =>
      requestAnimationFrame(() => {
        area.focus();
        if (caret !== undefined) area.setSelectionRange(caret, caret);
      });

    menu(event, (w) =>
      editorMenu(w, {
        paneId: node.id,
        path,
        selection,
        lines: [first, first + selection.split('\n').length - 1],
        copy: () => {
          copyText(selection);
          refocus();
        },
        cut: () => {
          copyText(selection);
          w.editFile(path, area.value.slice(0, start) + area.value.slice(end));
          refocus(start);
        },
        paste: () => {
          void readClipboard().then((text) => {
            if (text === null) return refocus();
            w.editFile(path, area.value.slice(0, start) + text + area.value.slice(end));
            refocus(start + text.length);
          });
        },
      }),
    );
  };

  // The highlighted layer and the gutter follow the textarea's own scroll.
  const syncScroll = useCallback(() => {
    const area = areaRef.current;
    if (!area) return;
    if (preRef.current) {
      preRef.current.scrollTop = area.scrollTop;
      preRef.current.scrollLeft = area.scrollLeft;
    }
    if (gutterRef.current) gutterRef.current.scrollTop = area.scrollTop;
  }, []);

  const syncCaret = useCallback(() => {
    const area = areaRef.current;
    if (!area) return;
    const before = area.value.slice(0, area.selectionStart);
    const rows = before.split('\n');
    setCaretLine(rows.length);
    wb.setCursor({ line: rows.length, column: rows[rows.length - 1].length + 1 });
  }, [wb]);

  return (
    <div
      onMouseDown={() => wb.setFocusedPane(node.id)}
      style={{
        flex: 1,
        display: 'flex',
        flexDirection: 'column',
        minWidth: 0,
        minHeight: 0,
        background: color.canvas,
        overflow: 'hidden',
      }}
    >
      <PathBreadcrumb path={path} />
      <div style={{ flex: 1, display: 'flex', minWidth: 0, minHeight: 0, overflow: 'hidden' }}>
        <div
          ref={gutterRef}
          className="cl"
          style={{
            width: 46,
            flexShrink: 0,
            padding: '8px 0',
            textAlign: 'right',
            fontSize: fs.secondary,
            lineHeight: '19px',
            color: color.lineNumber,
            overflow: 'hidden',
          }}
        >
          {lines.map((_, i) => (
            <div key={i} style={{ paddingRight: 12, color: i + 1 === caretLine ? color.textTertiary : undefined }}>
              {i + 1}
            </div>
          ))}
        </div>
        <div style={{ flex: 1, position: 'relative', minWidth: 0, overflow: 'hidden' }}>
          <pre
            ref={preRef}
            className="cl"
            aria-hidden
            style={{
              margin: 0,
              padding: '8px 12px 8px 0',
              fontSize: fs.secondary,
              lineHeight: '19px',
              color: color.code,
              whiteSpace: 'pre',
              overflow: 'hidden',
              height: '100%',
            }}
          >
            {lines.map((l, i) => (
              <HighlightedLine key={i} line={l} kind={file?.kind ?? 'swift'} />
            ))}
          </pre>
          <textarea
            ref={areaRef}
            className="cl scroll"
            spellCheck={false}
            value={text}
            onChange={(e) => {
              wb.editFile(path, e.target.value);
              syncCaret();
            }}
            onKeyUp={syncCaret}
            onClick={syncCaret}
            onContextMenu={openMenu}
            onScroll={syncScroll}
            onKeyDown={(e) => {
              if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') {
                e.preventDefault();
                wb.saveFile(path);
              }
            }}
            style={{
              position: 'absolute',
              inset: 0,
              width: '100%',
              height: '100%',
              padding: '8px 12px 8px 0',
              border: 0,
              outline: 'none',
              resize: 'none',
              background: 'transparent',
              color: 'transparent',
              caretColor: color.textPrimary,
              fontSize: fs.secondary,
              lineHeight: '19px',
              whiteSpace: 'pre',
              overflow: 'auto',
            }}
          />
        </div>
      </div>
    </div>
  );
}

/** The text selected inside this pane — not a selection left in another one. */
function selectionWithin(pane: HTMLElement) {
  const selection = window.getSelection();
  if (!selection?.anchorNode || !pane.contains(selection.anchorNode)) return '';
  return selection.toString();
}

function LogLine({ text, tone }: { text: string; tone?: string }) {
  const tint =
    tone === 'add' ? color.success : tone === 'del' ? color.danger : tone === 'dim' ? color.codeComment : undefined;
  return <div style={{ color: tint }}>{text || ' '}</div>;
}

function AgentPane({ node }: { node: Extract<PaneNode, { kind: 'leaf' }> }) {
  const wb = useWorkbench();
  const menu = useContextMenu();
  return (
    <div
      onMouseDown={() => wb.setFocusedPane(node.id)}
      onContextMenu={(event) => {
        const selection = selectionWithin(event.currentTarget);
        menu(event, (w) => streamMenu(w, { paneId: node.id, kind: 'agent', selection }));
      }}
      className="cl scroll"
      style={{
        flex: 1,
        minHeight: 0,
        background: color.canvas,
        padding: '20px 12px 8px 12px',
        fontSize: fs.caption,
        lineHeight: '17px',
        color: color.code,
        whiteSpace: 'pre',
      }}
    >
      {wb.agentLog.map((l, i) => (
        <LogLine key={i} text={l.text} tone={l.tone === 'accent' ? undefined : l.tone} />
      ))}
    </div>
  );
}

function TerminalPane({ node }: { node: Extract<PaneNode, { kind: 'leaf' }> }) {
  const wb = useWorkbench();
  const [input, setInput] = useState('');
  const scrollRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const menu = useContextMenu();

  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [wb.terminal.length]);

  const prompt = wb.awaitingApproval ? 'Apply this change? [y/N] ' : '$ ';

  return (
    <div
      ref={scrollRef}
      onMouseDown={(event) => {
        wb.setFocusedPane(node.id);
        // A right-click must not move focus into the prompt: that would drop
        // the text selection the menu is about to copy.
        if (event.button !== 2 && !event.ctrlKey) inputRef.current?.focus();
      }}
      onContextMenu={(event) => {
        const selection = selectionWithin(event.currentTarget);
        menu(event, (w) =>
          streamMenu(w, {
            paneId: node.id,
            kind: 'terminal',
            selection,
            paste: () => {
              void readClipboard().then((text) => {
                if (text) setInput((current) => current + text.replace(/\n/g, ' '));
                requestAnimationFrame(() => inputRef.current?.focus());
              });
            },
          }),
        );
      }}
      className="cl scroll"
      style={{
        flex: 1,
        minHeight: 0,
        background: color.canvas,
        padding: '20px 12px 8px 12px',
        fontSize: fs.caption,
        lineHeight: '17px',
        color: color.code,
        whiteSpace: 'pre',
        cursor: 'text',
      }}
    >
      {wb.terminal.map((l, i) => (
        <LogLine key={i} text={l.text} tone={l.tone} />
      ))}
      <div style={{ display: 'flex', alignItems: 'center' }}>
        <span style={{ color: wb.awaitingApproval ? color.code : color.codeComment }}>{prompt}</span>
        <span style={{ position: 'relative', flex: 1, display: 'flex', alignItems: 'center' }}>
          <span>{input}</span>
          <span
            className="caret"
            style={{ display: 'inline-block', width: 7, height: 14, background: color.code, marginLeft: 2 }}
          />
          <input
            ref={inputRef}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                wb.runTerminal(input);
                setInput('');
              }
            }}
            style={{
              position: 'absolute',
              inset: 0,
              width: '100%',
              border: 0,
              outline: 'none',
              background: 'transparent',
              color: 'transparent',
              caretColor: 'transparent',
              fontFamily: mono,
              fontSize: fs.caption,
            }}
          />
        </span>
      </div>
    </div>
  );
}

function Divider({
  orientation,
  onDrag,
  strong,
}: {
  orientation: 'horizontal' | 'vertical';
  onDrag: (clientX: number, clientY: number, rect: DOMRect) => void;
  strong?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const horizontal = orientation === 'horizontal';

  const start = (event: React.PointerEvent) => {
    const parent = ref.current?.parentElement;
    if (!parent) return;
    const rect = parent.getBoundingClientRect();
    event.preventDefault();
    const move = (e: PointerEvent) => onDrag(e.clientX, e.clientY, rect);
    const stop = () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', stop);
      document.body.style.cursor = '';
    };
    document.body.style.cursor = horizontal ? 'col-resize' : 'row-resize';
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', stop);
  };

  return (
    <div
      ref={ref}
      onPointerDown={start}
      style={{
        position: 'relative',
        flexShrink: 0,
        width: horizontal ? 1 : undefined,
        height: horizontal ? undefined : 1,
        background: strong ? 'rgba(241,242,246,0.3)' : line.paneDivider,
        cursor: horizontal ? 'col-resize' : 'row-resize',
        touchAction: 'none',
      }}
    >
      {/* Hit area only — the visible rule stays exactly 1px. */}
      <div
        style={{
          position: 'absolute',
          left: horizontal ? -4 : 0,
          right: horizontal ? -4 : 0,
          top: horizontal ? 0 : -4,
          bottom: horizontal ? 0 : -4,
        }}
      />
    </div>
  );
}

function Pane({ node }: { node: PaneNode }) {
  const wb = useWorkbench();

  if (node.kind === 'leaf') {
    if (node.pane === 'editor') return <EditorPane node={node} />;
    if (node.pane === 'agent') return <AgentPane node={node} />;
    return <TerminalPane node={node} />;
  }

  const horizontal = node.orientation === 'horizontal';
  return (
    <div
      style={{
        flex: 1,
        display: 'flex',
        flexDirection: horizontal ? 'row' : 'column',
        minWidth: 0,
        minHeight: 0,
      }}
    >
      <div
        style={{
          flex: `0 0 ${node.ratio * 100}%`,
          display: 'flex',
          flexDirection: horizontal ? 'row' : 'column',
          minWidth: 0,
          minHeight: 0,
          overflow: 'hidden',
        }}
      >
        <Pane node={node.first} />
      </div>
      <Divider
        orientation={node.orientation}
        strong={!horizontal}
        onDrag={(x, y, rect) =>
          wb.setRatio(node.id, horizontal ? (x - rect.left) / rect.width : (y - rect.top) / rect.height)
        }
      />
      <div style={{ flex: 1, display: 'flex', flexDirection: horizontal ? 'row' : 'column', minWidth: 0, minHeight: 0 }}>
        <Pane node={node.second} />
      </div>
    </div>
  );
}

/* ── main area ────────────────────────────────────────────────────────── */

export function WorkspaceMain() {
  const wb = useWorkbench();
  const maximizedNode = wb.maximized
    ? ((): PaneNode | null => {
        const find = (n: PaneNode): PaneNode | null =>
          n.id === wb.maximized ? n : n.kind === 'split' ? find(n.first) ?? find(n.second) : null;
        return find(wb.layout);
      })()
    : null;

  return (
    <div style={{ flex: 1, display: 'flex', minWidth: 0, minHeight: 0 }}>
      <Pane node={maximizedNode ?? wb.layout} />
    </div>
  );
}

export function WorkspaceStatus() {
  const wb = useWorkbench();
  return (
    <span className="cl">
      Ln {wb.cursor.line}, Col {wb.cursor.column}
    </span>
  );
}
