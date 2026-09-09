import { useCallback, useEffect, useRef, useState } from 'react';

import { files, projects, tree, type FileKind } from '../data';
import { HighlightedLine } from '../highlight';
import {
  IconBranchSmall,
  IconClaude,
  IconCodex,
  IconCommand,
  IconDoc,
  IconGear,
  IconMarkdown,
  IconSearch,
  IconSparkle,
} from '../icons';
import { useWorkbench, type PaneNode } from '../store';
import { QuotaMeter, ScreenShell, Sidebar, StatusBar, Titlebar } from '../chrome';
import { color, line, mono, wash } from '../tokens';

const byPath = new Map(files.map((f) => [f.path, f]));

const INDENT: Record<number, number> = { 0: 10, 1: 22, 2: 36, 3: 55 };

function FileIcon({ kind, tint }: { kind: FileKind; tint: string }) {
  if (kind === 'md') return <IconMarkdown size={12} color={tint} />;
  if (kind === 'swift') return <IconClaude size={12} color={tint} />;
  return <IconDoc size={12} color={tint} />;
}

/* ── titlebar ─────────────────────────────────────────────────────────── */

function Tab({ path, active }: { path: string; active: boolean }) {
  const wb = useWorkbench();
  const tab = wb.tabs.find((t) => t.path === path);
  const file = byPath.get(path);
  const tint = active ? color.textPrimary : color.textTertiary;
  return (
    <button
      className="tab"
      onClick={() => {
        wb.setActivePath(path);
        wb.openFile(path);
      }}
      style={{
        position: 'relative',
        display: 'flex',
        alignItems: 'center',
        gap: 7,
        padding: '0 11px',
        minWidth: 124,
        maxWidth: 210,
        borderRadius: 7,
        background: 'transparent',
        height: '100%',
        alignSelf: 'stretch',
      }}
    >
      {file ? <FileIcon kind={file.kind} tint={tint} /> : <IconSparkle size={12} color={tint} />}
      <span
        style={{
          fontSize: 11,
          fontWeight: active ? 600 : 400,
          color: tint,
          whiteSpace: 'nowrap',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          flex: 1,
        }}
      >
        {file?.name ?? path}
      </span>
      {tab?.dirty ? (
        <span
          style={{
            width: 6,
            height: 6,
            borderRadius: '50%',
            background: active ? color.textTertiary : color.textQuaternary,
            flexShrink: 0,
          }}
        />
      ) : null}
      {active ? (
        <div
          style={{
            position: 'absolute',
            left: 11,
            right: 11,
            bottom: 0,
            height: 2,
            background: color.textPrimary,
            borderRadius: '1px 1px 0 0',
          }}
        />
      ) : null}
    </button>
  );
}

function WorkspaceTitlebar() {
  const wb = useWorkbench();
  return (
    <Titlebar variant="workspace" align="end">
      <div
        className="no-scrollbar"
        style={{
          flex: 1,
          height: 48,
          display: 'flex',
          alignItems: 'center',
          gap: 5,
          minWidth: 0,
          overflow: 'hidden',
        }}
      >
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 6,
            height: 26,
            padding: '0 10px',
            borderRadius: 8,
            background: 'rgba(255,255,255,0.08)',
            border: '1px solid rgba(255,255,255,0.12)',
            alignSelf: 'center',
            flexShrink: 0,
          }}
        >
          <span style={{ fontSize: 12, fontWeight: 600, color: color.textPrimary }}>{wb.activeProject}</span>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', alignSelf: 'stretch', gap: 3, marginLeft: 4, minWidth: 0 }}>
          {wb.tabs.map((t) => (
            <Tab key={t.path} path={t.path} active={t.path === wb.activePath} />
          ))}
          <button
            className="tab"
            onClick={() => wb.setScreen('activity')}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 7,
              padding: '0 11px',
              minWidth: 124,
              borderRadius: 7,
              height: '100%',
              alignSelf: 'stretch',
            }}
          >
            <IconSparkle size={12} color={color.textTertiary} />
            <span style={{ fontSize: 11, color: color.textTertiary, whiteSpace: 'nowrap', flex: 1 }}>Claude Code</span>
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: color.textQuaternary, flexShrink: 0 }} />
          </button>
          <button
            className="tab"
            onClick={() => wb.setScreen('sessions')}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 7,
              padding: '0 11px',
              minWidth: 124,
              borderRadius: 7,
              height: '100%',
              alignSelf: 'stretch',
            }}
          >
            <IconCodex size={12} color={color.textTertiary} />
            <span style={{ fontSize: 11, color: color.textTertiary, whiteSpace: 'nowrap', flex: 1 }}>codex</span>
          </button>
        </div>

        {projects
          .filter((p) => p !== wb.activeProject)
          .map((p) => (
            <div key={p} style={{ display: 'flex', alignItems: 'center', flexShrink: 0 }}>
              <div style={{ width: 1, height: 22, background: 'rgba(242,244,238,0.09)', margin: '0 5px' }} />
              <button
                onClick={() => wb.setActiveProject(p)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  height: 22,
                  padding: '0 9px',
                  borderRadius: 8,
                  color: color.textQuaternary,
                  alignSelf: 'center',
                }}
              >
                <span style={{ fontSize: 12, fontWeight: 600 }}>{p}</span>
              </button>
            </div>
          ))}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '0 12px 9px 12px', flexShrink: 0 }}>
        <button
          onClick={() => wb.setOverlay('search')}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 7,
            width: 200,
            height: 28,
            padding: '0 9px',
            borderRadius: 8,
            background: 'rgba(0,0,0,0.18)',
          }}
        >
          <IconSearch size={12} color={color.textQuaternary} />
          <span style={{ fontSize: 11, color: color.textMuted, flex: 1 }}>ファイル、シンボル</span>
        </button>
        <button className="act" title="コマンドパレット" onClick={() => wb.setOverlay('command')}>
          <IconCommand size={15} />
        </button>
        <button className="act" title="設定" onClick={() => wb.setScreen('settings')}>
          <IconGear size={15} />
        </button>
      </div>
    </Titlebar>
  );
}

/* ── sidebar ──────────────────────────────────────────────────────────── */

function WorkspaceSidebar() {
  const wb = useWorkbench();

  const hidden = (parent: string | undefined) => {
    let cursor = parent;
    while (cursor) {
      if (wb.collapsed.has(cursor)) return true;
      cursor = cursor.includes('/') ? cursor.slice(0, cursor.lastIndexOf('/')) : undefined;
    }
    return false;
  };

  return (
    <Sidebar>
      <div className="scroll" style={{ flex: 1, padding: '6px 0' }}>
        {tree.map((node) => {
          if (node.type !== 'project' && hidden(node.parent)) return null;

          if (node.type === 'project') {
            const open = !wb.collapsed.has(node.id);
            return (
              <button
                key={node.id}
                onClick={() => wb.toggleFolder(node.id)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 5,
                  height: 24,
                  width: '100%',
                  padding: '0 10px',
                  color: color.attention,
                }}
              >
                {open ? '▾' : '▸'}
                <IconBranchSmall size={10} />
                <span style={{ fontSize: 11, fontWeight: 700, marginLeft: 1 }}>{node.name}</span>
              </button>
            );
          }

          if (node.type === 'folder') {
            const open = !wb.collapsed.has(node.id);
            return (
              <button
                key={node.id}
                onClick={() => wb.toggleFolder(node.id)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 5,
                  height: 24,
                  width: '100%',
                  padding: `0 10px 0 ${INDENT[node.depth] ?? 22}px`,
                  color: color.textSecondary,
                }}
              >
                {open ? '▾' : '▸'}
                <span style={{ fontSize: 11, marginLeft: 3 }}>{node.name}</span>
              </button>
            );
          }

          const file = byPath.get(node.path);
          const selected = wb.activePath === node.path;
          const dirty = wb.tabs.find((t) => t.path === node.path)?.dirty;
          const status = dirty ? 'M' : file?.status;
          return (
            <button
              key={node.id}
              className={selected ? undefined : 'hoverable'}
              onClick={() => wb.openFile(node.path)}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 6,
                width: selected ? 'calc(100% - 16px)' : '100%',
                height: selected ? 28 : 26,
                padding: `0 10px 0 ${(INDENT[node.depth] ?? 36) - (selected ? 8 : 0)}px`,
                margin: selected ? '0 8px' : undefined,
                borderRadius: selected ? 7 : undefined,
                background: selected ? 'rgba(255,255,255,0.08)' : undefined,
                color: selected ? color.textPrimary : color.textTertiary,
              }}
            >
              <FileIcon kind={file?.kind ?? 'swift'} tint={selected ? '#cfd3ce' : color.textTertiary} />
              <span style={{ fontSize: 11, flex: 1, fontWeight: selected ? 500 : 400 }}>{node.name}</span>
              {status ? (
                <span
                  style={{
                    fontSize: 10,
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
    </Sidebar>
  );
}

/* ── panes ────────────────────────────────────────────────────────────── */

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
      style={{ flex: 1, display: 'flex', minWidth: 0, minHeight: 0, background: color.canvas, overflow: 'hidden' }}
    >
      <div
        ref={gutterRef}
        className="cl"
        style={{
          width: 46,
          flexShrink: 0,
          padding: '20px 0 8px 0',
          textAlign: 'right',
          fontSize: 12,
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
            padding: '20px 12px 8px 0',
            fontSize: 12,
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
            padding: '20px 12px 8px 0',
            border: 0,
            outline: 'none',
            resize: 'none',
            background: 'transparent',
            color: 'transparent',
            caretColor: color.textPrimary,
            fontSize: 12,
            lineHeight: '19px',
            whiteSpace: 'pre',
            overflow: 'auto',
          }}
        />
      </div>
    </div>
  );
}

function LogLine({ text, tone }: { text: string; tone?: string }) {
  const tint =
    tone === 'add' ? color.success : tone === 'del' ? color.danger : tone === 'dim' ? color.codeComment : undefined;
  return <div style={{ color: tint }}>{text || ' '}</div>;
}

function AgentPane({ node }: { node: Extract<PaneNode, { kind: 'leaf' }> }) {
  const wb = useWorkbench();
  return (
    <div
      onMouseDown={() => wb.setFocusedPane(node.id)}
      className="cl scroll"
      style={{
        flex: 1,
        minHeight: 0,
        background: color.canvas,
        padding: '20px 12px 10px 12px',
        fontSize: 11,
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

  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [wb.terminal.length]);

  const prompt = wb.awaitingApproval ? 'Apply this change? [y/N] ' : '$ ';

  return (
    <div
      ref={scrollRef}
      onMouseDown={() => {
        wb.setFocusedPane(node.id);
        inputRef.current?.focus();
      }}
      className="cl scroll"
      style={{
        flex: 1,
        minHeight: 0,
        background: color.canvas,
        padding: '20px 12px 10px 12px',
        fontSize: 11,
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
            style={{ display: 'inline-block', width: 7, height: 14, background: color.code, marginLeft: 1 }}
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
              fontSize: 11,
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
        background: strong ? 'rgba(242,244,238,0.3)' : line.paneDivider,
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

/* ── screen ───────────────────────────────────────────────────────────── */

export function WorkspaceScreen() {
  const wb = useWorkbench();
  const maximizedNode = wb.maximized
    ? ((): PaneNode | null => {
        const find = (n: PaneNode): PaneNode | null =>
          n.id === wb.maximized ? n : n.kind === 'split' ? find(n.first) ?? find(n.second) : null;
        return find(wb.layout);
      })()
    : null;

  return (
    <ScreenShell>
      <WorkspaceTitlebar />
      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        <WorkspaceSidebar />
        <div style={{ flex: 1, display: 'flex', minWidth: 0 }}>
          <Pane node={maximizedNode ?? wb.layout} />
        </div>
      </div>
      <StatusBar>
        <span>main</span>
        <span className="cl" style={{ color: color.textMuted }}>
          ↓0 ↑2
        </span>
        <span>{6 + wb.dirtyCount} 変更</span>
        <div style={{ flex: 1 }} />
        <QuotaMeter />
        <span className="cl">
          Ln {wb.cursor.line}, Col {wb.cursor.column}
        </span>
      </StatusBar>
    </ScreenShell>
  );
}

export const workspaceWash = wash;
