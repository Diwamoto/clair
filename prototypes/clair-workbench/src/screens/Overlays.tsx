import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';

import { commands, files } from '../data';
import { IconChevron, IconClaude, IconFolder, IconMarkdown, IconSearch, IconTreeView } from '../icons';
import { animate, shouldGlide, SMOOTH, SNAPPY, tween, useReducedMotion } from '../spring';
import { useWorkbench } from '../store';
import { color, fs, line, mono, radius, space, wash } from '../tokens';

/* The scrim the AddAgent artboard defines for an overlay over the workspace. */
function Scrim({ children, onClose }: { children: React.ReactNode; onClose: () => void }) {
  return (
    <div
      className="overlay-scrim"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
      style={{
        position: 'absolute',
        inset: 0,
        zIndex: 40,
        background: 'rgba(8,10,12,0.68)',
        display: 'flex',
        alignItems: 'flex-start',
        justifyContent: 'center',
        paddingTop: 44,
        overflow: 'auto',
      }}
    >
      {children}
    </div>
  );
}

function Panel({ width, children }: { width: number; children: React.ReactNode }) {
  return (
    <div
      className="overlay-panel"
      style={{
        width: 'min(100%, ' + width + 'px)',
        display: 'flex',
        flexDirection: 'column',
        borderRadius: radius.overlay,
        border: `1px solid ${line.strong}`,
        boxShadow: '0 18px 48px rgba(0,0,0,0.62)',
        overflow: 'hidden',
        background: color.chromeRaised,
        margin: '0 12px 44px',
      }}
    >
      {children}
    </div>
  );
}

function ShellHeader({
  icon,
  title,
  hint,
  onClose,
}: {
  icon: React.ReactNode;
  title: string;
  hint: string;
  onClose: () => void;
}) {
  return (
    <div
      style={{
        height: 44,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'center',
        gap: space[2],
        padding: '0 12px',
        borderBottom: `1px solid ${line.hairline}`,
      }}
    >
      <span style={{ color: color.textTertiary, display: 'flex' }}>{icon}</span>
      <span style={{ fontSize: fs.body, fontWeight: 600, color: color.textPrimary }}>{title}</span>
      <span style={{ fontSize: fs.caption, color: color.textQuaternary }}>{hint}</span>
      <div style={{ flex: 1 }} />
      <button
        className="tnum"
        onClick={onClose}
        style={{
          fontSize: fs.caption,
          fontWeight: 600,
          color: color.textQuaternary,
          background: color.panel,
          border: `1px solid ${line.hairline}`,
          borderRadius: radius.control,
          padding: '2px 4px',
        }}
      >
        esc
      </button>
    </div>
  );
}

function QueryInput({
  value,
  onChange,
  count,
  inputRef,
  onKeyDown,
  trailing,
}: {
  value: string;
  onChange: (v: string) => void;
  count: string;
  inputRef: React.RefObject<HTMLInputElement | null>;
  onKeyDown: (e: React.KeyboardEvent) => void;
  trailing?: React.ReactNode;
}) {
  return (
    <div style={{ padding: '8px 12px 8px 12px' }}>
      <div
        className="field"
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: space[2],
          height: 40,
          padding: '0 8px',
          borderRadius: radius.control,
          background: color.chromeRaised,
          border: `1px solid ${line.hairline}`,
        }}
      >
        <IconSearch size={14} color={color.textQuaternary} />
        <input
          ref={inputRef}
          autoFocus
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={onKeyDown}
          style={{
            flex: 1,
            minWidth: 0,
            border: 0,
            outline: 'none',
            background: 'transparent',
            fontSize: fs.body,
            color: color.textPrimary,
            caretColor: color.textSecondary,
          }}
        />
        <span style={{ fontSize: fs.caption, color: color.textQuaternary }}>{count}</span>
        {trailing}
      </div>
    </div>
  );
}

function KeyChip({ children, onClick }: { children: React.ReactNode; onClick?: () => void }) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: space[1],
        height: 20,
        padding: '0 4px',
        borderRadius: radius.control,
        border: `1px solid ${line.hairline}`,
      }}
    >
      <span className="tnum" style={{ fontSize: fs.caption, color: color.textSecondary }}>
        {children}
      </span>
    </button>
  );
}

/** A shortcut as one keycap per key: ⌃⌘G → [⌃][⌘][G]. */
function Keycaps({ shortcut, on }: { shortcut: string; on: boolean }) {
  return (
    <span style={{ display: 'flex', gap: space[0], flexShrink: 0 }}>
      {[...shortcut].map((k, i) => (
        <kbd
          key={i}
          className="tnum"
          style={{
            font: 'inherit',
            minWidth: 20,
            height: 20,
            padding: '0 4px',
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            borderRadius: radius.control,
            border: `1px solid ${line.hairline}`,
            fontSize: fs.caption,
            color: on ? color.textSecondary : color.textTertiary,
          }}
        >
          {k}
        </kbd>
      ))}
    </span>
  );
}

/* ── command palette / quick open ─────────────────────────────────────── */

const PALETTE_ROW = 32;

export function CommandPalette() {
  const wb = useWorkbench();
  const isCommand = wb.overlay === 'command';
  const [query, setQuery] = useState('');
  const [index, setIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const reduced = useReducedMotion();
  const listRef = useRef<HTMLDivElement>(null);
  const highlightRef = useRef<HTMLDivElement>(null);
  // What moved the selection last: the keyboard slides (70ms), the pointer
  // springs, a fresh query snaps — arc's command palette does the same.
  const cause = useRef<'key' | 'pointer' | 'filter'>('filter');
  const hl = useRef({ y: 0, shown: false });
  const moveAnim = useRef<() => void>(() => {});
  const fadeAnim = useRef<() => void>(() => {});
  const heightAnim = useRef<() => void>(() => {});
  const prevKeys = useRef<string[]>([]);
  const lastPointer = useRef({ x: -1, y: -1 });

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (isCommand) {
      return commands
        .filter((c) => !q || c.title.toLowerCase().includes(q) || c.id.toLowerCase().includes(q))
        .map((c) => ({ key: c.id, title: c.title, sub: c.id, shortcut: c.shortcut, danger: c.risk === '破壊的' }));
    }
    return files
      .filter((f) => !q || f.name.toLowerCase().includes(q) || f.path.toLowerCase().includes(q))
      .map((f) => ({ key: f.path, title: f.name, sub: f.path, shortcut: '', danger: false }));
  }, [isCommand, query]);

  // Render-phase reset, the way arc's palette does it: a new query or mode
  // snaps the selection back to the top instead of animating there.
  const seen = useRef(query + '|' + isCommand);
  if (seen.current !== query + '|' + isCommand) {
    seen.current = query + '|' + isCommand;
    cause.current = 'filter';
    if (index !== 0) setIndex(0);
  }
  const sel = Math.min(index, Math.max(rows.length - 1, 0));

  // One highlight follows the selection: a spring behind the pointer, a 70ms
  // slide behind the arrow keys, a snap on a fresh query. It fades in when it
  // first appears and out when the list empties (arc's palette, same shape).
  useLayoutEffect(() => {
    const el = highlightRef.current;
    if (!el) return;
    const paint = (v: number) => {
      hl.current.y = v;
      el.style.transform = `translateY(${v}px)`;
    };
    const paintOpacity = (v: number) => {
      el.style.opacity = String(v);
    };
    moveAnim.current();
    fadeAnim.current();
    if (rows.length === 0) {
      hl.current.shown = false;
      if (reduced) paintOpacity(0);
      else fadeAnim.current = animate(1, 0, tween(0.1), paintOpacity);
      return;
    }
    const top = sel * PALETTE_ROW;
    const appear = !hl.current.shown;
    if (appear || reduced || cause.current === 'filter') paint(top);
    else moveAnim.current = animate(hl.current.y, top, cause.current === 'pointer' ? SNAPPY : tween(0.07), paint);
    if (appear) {
      hl.current.shown = true;
      if (reduced) paintOpacity(1);
      else fadeAnim.current = animate(0, 1, tween(0.08), paintOpacity);
    }
  }, [sel, rows.length, reduced]);

  // The results frame follows the list height, so filtering closes or opens
  // the gap instead of snapping (arc: spring smooth). Capped at 46vh, where
  // the list takes over as a scroller.
  useLayoutEffect(() => {
    const el = listRef.current;
    if (!el) return;
    const content = (rows.length === 0 ? PALETTE_ROW * 2 : rows.length * PALETTE_ROW) + 8;
    const target = Math.min(content, window.innerHeight * 0.46);
    const from = el.style.height ? parseFloat(el.style.height) : target;
    heightAnim.current();
    if (reduced) {
      el.style.height = `${target}px`;
      el.style.overflowY = '';
      return;
    }
    el.style.overflowY = 'clip';
    heightAnim.current = animate(from, target, SMOOTH, (v) => {
      el.style.height = `${v}px`;
    }, () => {
      el.style.overflowY = '';
    });
  }, [rows.length, reduced]);

  // Rows that survive a filter close their gaps with a glide (arc's smooth
  // spring; fixed-height rows, so the old place is just index arithmetic). A
  // long jump — the first letters into a long list — snaps instead.
  useLayoutEffect(() => {
    const prev = prevKeys.current;
    const keys = rows.map((r) => r.key);
    prevKeys.current = keys;
    const box = listRef.current;
    if (!box || reduced || !shouldGlide(prev, keys)) return;
    const before = new Map(prev.map((k, i) => [k, i]));
    box.querySelectorAll<HTMLElement>('[data-row]').forEach((el) => {
      const from = before.get(el.dataset.row!);
      const to = Number(el.dataset.index);
      if (from === undefined || from === to) return;
      const start = (from - to) * PALETTE_ROW;
      el.style.transform = `translateY(${start}px)`;
      animate(start, 0, SMOOTH, (v) => {
        el.style.transform = `translateY(${v}px)`;
      });
    });
  }, [rows, reduced]);

  // Keep the keyboard-selected row in view; a pointer selection already is.
  useEffect(() => {
    if (cause.current !== 'key') return;
    listRef.current?.querySelector(`[data-index="${sel}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [sel]);

  // A fresh query starts from the top.
  useEffect(() => {
    listRef.current?.scrollTo({ top: 0 });
  }, [query]);

  useEffect(
    () => () => {
      moveAnim.current();
      fadeAnim.current();
      heightAnim.current();
    },
    [],
  );

  const commit = (i: number) => {
    const row = rows[i];
    if (!row) return;
    if (isCommand) wb.runCommand(row.key);
    else wb.openFile(row.key);
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    cause.current = 'key';
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setIndex((i) => Math.min(rows.length - 1, i + 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setIndex((i) => Math.max(0, i - 1));
    } else if (e.key === 'Home') {
      e.preventDefault();
      setIndex(0);
    } else if (e.key === 'End') {
      e.preventDefault();
      setIndex(Math.max(rows.length - 1, 0));
    } else if (e.key === 'Enter') {
      e.preventDefault();
      commit(index);
    }
  };

  return (
    <Scrim onClose={() => wb.setOverlay(null)}>
      <Panel width={560}>
        <QueryInput
          value={query}
          onChange={setQuery}
          count={`${rows.length} 件`}
          inputRef={inputRef}
          onKeyDown={onKeyDown}
        />
        <div
          ref={listRef}
          className="scroll"
          style={{ position: 'relative', padding: '0 8px 8px 8px', maxHeight: '46vh' }}
        >
          <div
            ref={highlightRef}
            aria-hidden
            style={{
              position: 'absolute',
              top: 0,
              left: 8,
              right: 8,
              height: PALETTE_ROW,
              borderRadius: radius.control,
              background: color.surfaceActive,
              opacity: 0,
              pointerEvents: 'none',
            }}
          />
          {rows.length === 0 ? (
            <div
              style={{
                height: PALETTE_ROW * 2,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: fs.secondary,
                color: color.textQuaternary,
              }}
            >
              {isCommand ? '一致するコマンドがありません' : '一致するファイルがありません'}
            </div>
          ) : (
            rows.map((row, i) => {
              const on = i === sel;
              return (
                <button
                  key={row.key}
                  data-row={row.key}
                  data-index={i}
                  title={row.key}
                  // Pointer movement, not entry: keyboard navigation scrolls
                  // rows under a still pointer and must not hand the highlight
                  // back. Browsers also send synthetic moves while the list
                  // scrolls; same coordinates mean the pointer never moved.
                  onMouseMove={(e) => {
                    if (e.clientX === lastPointer.current.x && e.clientY === lastPointer.current.y) return;
                    lastPointer.current = { x: e.clientX, y: e.clientY };
                    cause.current = 'pointer';
                    if (index !== i) setIndex(i);
                  }}
                  onClick={() => commit(i)}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: space[2],
                    width: '100%',
                    height: PALETTE_ROW,
                    padding: '0 8px',
                    borderRadius: radius.control,
                    background: 'transparent',
                    position: 'relative',
                  }}
                >
                  <span
                    style={{
                      fontSize: fs.secondary,
                      color: row.danger ? color.danger : on ? color.textPrimary : color.textSecondary,
                      whiteSpace: 'nowrap',
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                      flex: 1,
                      textAlign: 'left',
                    }}
                  >
                    {row.title}
                  </span>
                  {isCommand ? (
                    <Keycaps shortcut={row.shortcut} on={on} />
                  ) : (
                    <span
                      className="cl"
                      style={{ fontSize: fs.caption, color: color.textQuaternary, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0 }}
                    >
                      {row.sub}
                    </span>
                  )}
                </button>
              );
            })
          )}
        </div>
        <div
          style={{
            height: 34,
            flexShrink: 0,
            display: 'flex',
            alignItems: 'center',
            gap: space[2],
            padding: '0 12px',
            borderTop: `1px solid ${line.hairline}`,
          }}
        >
          {(
            [
              ['コマンド', 'command'],
              ['ファイルへ移動', 'quickOpen'],
            ] as const
          ).map(([label, mode]) => {
            const on = wb.overlay === mode;
            return (
              <button
                key={mode}
                onClick={() => {
                  wb.setOverlay(mode);
                  inputRef.current?.focus();
                }}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: space[1],
                  height: 20,
                  padding: '0 8px',
                  borderRadius: radius.control,
                  background: on ? color.surfaceActive : 'transparent',
                  color: on ? color.textPrimary : color.textTertiary,
                  fontSize: fs.caption,
                  fontWeight: 600,
                }}
              >
                {label}
              </button>
            );
          })}
          <span style={{ width: 1, height: 14, background: line.hairline }} />
          <KeyChip onClick={() => setIndex((i) => Math.max(0, i - 1))}>↑</KeyChip>
          <KeyChip onClick={() => setIndex((i) => Math.min(rows.length - 1, i + 1))}>↓</KeyChip>
          <span style={{ fontSize: fs.caption, color: color.textQuaternary }}>
            <span className="tnum" style={{ color: color.textSecondary }}>
              ↵
            </span>{' '}
            選択中を実行
          </span>
          <div style={{ flex: 1 }} />
          <span style={{ fontSize: fs.caption, color: color.textQuaternary }}>{isCommand ? '⌘K' : '⌘P'}</span>
        </div>
      </Panel>
    </Scrim>
  );
}

/* ── search ───────────────────────────────────────────────────────────── */

type Hit = { path: string; name: string; kind: string; lineNo: number; text: string; at: number };

// Explorer order: in every directory, folders before files, each by name.
function treeOrder(a: string, b: string) {
  const x = a.split('/');
  const y = b.split('/');
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    if (x[i] === y[i]) continue;
    const xf = i === x.length - 1;
    const yf = i === y.length - 1;
    if (xf !== yf) return xf ? 1 : -1;
    return x[i].toLowerCase().localeCompare(y[i].toLowerCase());
  }
  return x.length - y.length;
}

type TreeRow =
  | { kind: 'folder' | 'file'; id: string; name: string; depth: number; count: number }
  | { kind: 'hit'; index: number; depth: number };

/* Folder → file → hit rows for hits already in tree order; rows under a folded id are left out. */
function treeRows(hits: Hit[], folded: Set<string>): TreeRow[] {
  const counts = new Map<string, number>();
  hits.forEach((h) => {
    const p = h.path.split('/');
    p.forEach((_, d) => {
      const id = p.slice(0, d + 1).join('/');
      counts.set(id, (counts.get(id) ?? 0) + 1);
    });
  });
  const out: TreeRow[] = [];
  const emitted = new Set<string>();
  let last = '';
  let hidden = false;
  hits.forEach((h, index) => {
    const p = h.path.split('/');
    if (h.path !== last) {
      last = h.path;
      hidden = false;
      p.forEach((name, d) => {
        const id = p.slice(0, d + 1).join('/');
        if (!hidden && !emitted.has(id)) {
          emitted.add(id);
          out.push({ kind: d === p.length - 1 ? 'file' : 'folder', id, name, depth: d, count: counts.get(id) ?? 0 });
        }
        hidden = hidden || folded.has(id);
      });
    }
    if (!hidden) out.push({ kind: 'hit', index, depth: p.length });
  });
  return out;
}

export function SearchOverlay() {
  const wb = useWorkbench();
  const [query, setQuery] = useState('Workspace');
  const [index, setIndex] = useState(0);
  const [tree, setTree] = useState(false);
  const [folded, setFolded] = useState<Set<string>>(new Set());
  const inputRef = useRef<HTMLInputElement>(null);

  const hits = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return [] as Hit[];
    const out: Hit[] = [];
    for (const file of files) {
      const source = wb.contents[file.path] ?? file.content;
      source.split('\n').forEach((text, i) => {
        const at = text.toLowerCase().indexOf(q);
        if (at >= 0) out.push({ path: file.path, name: file.name, kind: file.kind, lineNo: i + 1, text, at });
      });
    }
    const shown = out.slice(0, 40);
    // Tree mode orders hits as the tree draws them, so the flat index still follows the screen.
    return tree ? [...shown].sort((a, b) => (a.path === b.path ? 0 : treeOrder(a.path, b.path))) : shown;
  }, [query, wb.contents, tree]);

  const fileCount = new Set(hits.map((h) => h.path)).size;

  useEffect(() => setIndex(0), [query, tree]);

  const grouped = useMemo(() => {
    const map = new Map<string, Hit[]>();
    hits.forEach((h) => {
      const list = map.get(h.path) ?? [];
      list.push(h);
      map.set(h.path, list);
    });
    return [...map.entries()];
  }, [hits]);

  const rows = useMemo(() => (tree ? treeRows(hits, folded) : []), [tree, hits, folded]);
  // ↑↓ walk the hits on screen: all of them as a list, the unfolded ones as a tree.
  const order = tree ? rows.flatMap((r) => (r.kind === 'hit' ? [r.index] : [])) : hits.map((_, i) => i);

  const step = (d: number) =>
    setIndex((i) => {
      if (!order.length) return i;
      const at = order.indexOf(i);
      const from = at < 0 ? (d > 0 ? -1 : order.length) : at;
      return order[Math.min(order.length - 1, Math.max(0, from + d))];
    });

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      step(1);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      step(-1);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const hit = hits[index];
      if (hit) wb.openFile(hit.path);
    }
  };

  const toggleFold = (id: string) =>
    setFolded((s) => {
      const next = new Set(s);
      if (!next.delete(id)) next.add(id);
      return next;
    });

  const fileIcon = (kind: string) =>
    kind === 'md' ? <IconMarkdown size={12} color={color.textTertiary} /> : <IconClaude size={12} color={color.textTertiary} />;

  const hitRow = (hit: Hit, i: number, indent: number) => {
    const on = i === index;
    return (
      <button
        key={`${hit.path}:${hit.lineNo}`}
        onMouseEnter={() => setIndex(i)}
        onClick={() => wb.openFile(hit.path)}
        style={{
          display: 'flex',
          alignItems: 'center',
          width: '100%',
          height: 32,
          padding: `0 8px 0 ${indent}px`,
          marginBottom: 2,
          borderRadius: radius.control,
          background: on ? color.surfaceActive : 'transparent',
          boxShadow: on ? `inset 0 0 0 1px ${line.ring}` : 'none',
        }}
      >
        <span
          className="cl"
          style={{
            fontSize: fs.secondary,
            color: on ? color.textPrimary : color.textTertiary,
            whiteSpace: 'nowrap',
            overflow: 'hidden',
          }}
        >
          {hit.lineNo}
          {'  '}
          {hit.text.slice(0, hit.at).trimStart()}
          <b
            style={{
              color: on ? color.textPrimary : color.textSecondary,
              background: on ? 'rgba(241,242,246,0.22)' : 'rgba(241,242,246,0.14)',
              borderRadius: radius.control,
            }}
          >
            {hit.text.slice(hit.at, hit.at + query.length)}
          </b>
          {hit.text.slice(hit.at + query.length)}
        </span>
      </button>
    );
  };

  return (
    <Scrim onClose={() => wb.setOverlay(null)}>
      <Panel width={620}>
        <ShellHeader
          icon={<IconSearch size={14} />}
          title="検索"
          hint="Project内のファイルを横断"
          onClose={() => wb.setOverlay(null)}
        />
        <QueryInput
          value={query}
          onChange={setQuery}
          count={`${hits.length}件 · ${fileCount}ファイル`}
          inputRef={inputRef}
          onKeyDown={onKeyDown}
          trailing={
            <button
              className="hoverable"
              title="ツリー表示"
              aria-label="ツリー表示"
              aria-pressed={tree}
              onClick={() => {
                setTree((t) => !t);
                inputRef.current?.focus();
              }}
              style={{
                width: 30,
                height: 30,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                borderRadius: radius.control,
                background: tree ? color.surfaceActive : 'transparent',
                border: `1px solid ${tree ? line.ring : line.hairline}`,
              }}
            >
              <IconTreeView size={14} color={tree ? color.textPrimary : color.textQuaternary} />
            </button>
          }
        />
        <div className="scroll" style={{ padding: '0 8px 8px 8px', maxHeight: 400, minHeight: 120 }}>
          {tree
            ? rows.map((r) => {
                if (r.kind === 'hit') return hitRow(hits[r.index], r.index, 30 + r.depth * 12);
                const open = !folded.has(r.id);
                const hit = r.kind === 'file' ? hits.find((h) => h.path === r.id) : undefined;
                return (
                  <button
                    key={r.id}
                    className="hoverable"
                    onClick={() => toggleFold(r.id)}
                    aria-expanded={open}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: space[2],
                      width: '100%',
                      height: 26,
                      padding: `0 8px 0 ${8 + r.depth * 12}px`,
                      borderRadius: radius.control,
                      color: color.textTertiary,
                      fontWeight: 600,
                      fontSize: fs.caption,
                    }}
                  >
                    <IconChevron
                      size={10}
                      color={color.textTertiary}
                      style={{ transform: open ? 'rotate(90deg)' : undefined }}
                    />
                    {hit ? fileIcon(hit.kind) : <IconFolder size={12} color={color.textTertiary} />}
                    {r.name}
                    <span className="tnum" style={{ marginLeft: 'auto', color: color.textQuaternary, fontWeight: 400 }}>
                      {r.count}
                    </span>
                  </button>
                );
              })
            : grouped.map(([path, list], gi) => {
                const file = files.find((f) => f.path === path)!;
                const dir = path.slice(0, path.lastIndexOf('/'));
                return (
                  <div key={path}>
                    <div
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        gap: space[2],
                        height: 26,
                        padding: '0 8px',
                        marginTop: gi ? 6 : 0,
                        color: color.textTertiary,
                        fontWeight: 600,
                        fontSize: fs.caption,
                      }}
                    >
                      {fileIcon(file.kind)}
                      {file.name}
                      <span className="cl" style={{ marginLeft: 'auto', color: color.textQuaternary, fontWeight: 400 }}>
                        {dir}
                      </span>
                    </div>
                    {list.map((hit) => hitRow(hit, hits.indexOf(hit), 30))}
                  </div>
                );
              })}
          {!hits.length ? (
            <div style={{ padding: '16px 8px', color: color.textQuaternary, fontSize: fs.caption }}>一致するものはありません。</div>
          ) : null}
        </div>
        <div
          style={{
            height: 34,
            flexShrink: 0,
            display: 'flex',
            alignItems: 'center',
            gap: space[2],
            padding: '0 12px',
            borderTop: `1px solid ${line.hairline}`,
          }}
        >
          <KeyChip onClick={() => step(-1)}>↑</KeyChip>
          <KeyChip onClick={() => step(1)}>↓</KeyChip>
          <span style={{ fontSize: fs.caption, color: color.textQuaternary }}>
            <span className="tnum" style={{ color: color.textSecondary }}>
              ↵
            </span>{' '}
            ファイルを開く
          </span>
          <div style={{ flex: 1 }} />
          <span style={{ fontSize: fs.caption, color: color.textQuaternary }}>⇧⌘F</span>
        </div>
      </Panel>
    </Scrim>
  );
}

/* ── add agent ────────────────────────────────────────────────────────── */

const AGENTS = [
  { code: 'CX', name: 'Codex', quota: '5時間 残り68% · 2時間14分' },
  { code: 'CC', name: 'Claude Code', quota: '5時間 残り39% · 1時間08分' },
  { code: 'OC', name: 'OpenCode', quota: '5時間 残り84% · 4時間02分' },
];

export function AddAgentOverlay() {
  const wb = useWorkbench();
  const [agent, setAgent] = useState('OpenCode');
  const [place, setPlace] = useState<'ターミナル' | 'Agents'>('ターミナル');
  const [worktree, setWorktree] = useState<'現在のProject' | '新しいworktree'>('新しいworktree');
  const [branch, setBranch] = useState('agent-session');
  const [prompt, setPrompt] = useState('');
  const [confirm, setConfirm] = useState(true);

  const label = { fontSize: fs.caption, fontWeight: 600, color: color.textSecondary } as const;
  const hint = { color: color.textQuaternary, fontSize: fs.caption } as const;

  return (
    <Scrim onClose={() => wb.setOverlay(null)}>
      <div
        className="overlay-panel"
        style={{
          width: 'min(100%, 620px)',
          margin: '26px 12px 44px',
          overflow: 'hidden',
          borderRadius: radius.overlay,
          border: `1px solid ${line.strong}`,
          boxShadow: '0 24px 70px rgba(0,0,0,0.5)',
          background: color.chromeRaised,
        }}
      >
        <div
          style={{
            display: 'flex',
            alignItems: 'flex-start',
            justifyContent: 'space-between',
            gap: space[4],
            padding: '16px 20px',
            borderBottom: `1px solid ${line.hairline}`,
          }}
        >
          <div>
            <div
              style={{
                fontSize: fs.caption,
                fontWeight: 600,
                color: color.textTertiary,
              }}
            >
              新しいセッション
            </div>
            <h2 style={{ margin: '4px 0 2px', fontSize: fs.title, fontWeight: 600 }}>Agentを追加</h2>
            <p className="tnum" style={{ margin: 0, color: color.textQuaternary, fontSize: fs.caption, lineHeight: 1.5 }}>
              Agent、起動モデル、セッションの場所を選択します。
            </p>
          </div>
          <button
            onClick={() => wb.setOverlay(null)}
            style={{
              width: 28,
              height: 28,
              flexShrink: 0,
              border: `1px solid ${line.strong}`,
              borderRadius: '50%',
              display: 'grid',
              placeItems: 'center',
              color: color.textTertiary,
              fontSize: fs.title,
            }}
          >
            ×
          </button>
        </div>

        <div className="scroll" style={{ padding: '16px 20px 20px', display: 'grid', gap: space[4], maxHeight: '58vh' }}>
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '34px minmax(0,1fr) auto',
              alignItems: 'center',
              gap: space[2],
              padding: 12,
              border: `1px solid ${line.strong}`,
              borderRadius: radius.card,
              background: color.panel,
            }}
          >
            <span
              style={{
                width: 34,
                height: 34,
                borderRadius: '50%',
                background: color.surfaceHover,
                border: `1px solid ${line.strong}`,
                display: 'grid',
                placeItems: 'center',
                fontSize: fs.body,
                fontWeight: 600,
              }}
            >
              OC
            </span>
            <div>
              <div
                style={{
                  fontSize: fs.caption,
                  fontWeight: 600,
                  color: color.textTertiary,
                }}
              >
                おすすめ · 残り使用量が多いAgent
              </div>
              <strong style={{ fontSize: fs.body, fontWeight: 600 }}>OpenCode</strong>
              <div className="tnum" style={{ color: color.textQuaternary, fontSize: fs.caption }}>
                5時間 残り84% · 7日間 残り78%
              </div>
            </div>
            <button
              onClick={() => setAgent('OpenCode')}
              style={{
                minHeight: 26,
                padding: '0 8px',
                border: `1px solid ${line.strong}`,
                borderRadius: radius.control,
                background: wash.selected,
                color: color.textSecondary,
                fontSize: fs.caption,
                display: 'flex',
                alignItems: 'center',
              }}
            >
              このAgentを使う
            </button>
          </div>

          <div>
            <div style={{ marginBottom: 8 }}>
              <strong style={label}>Agent</strong>{' '}
              <span className="tnum" style={hint}>
                このセッションで使う接続済みのAgentを選択します。
              </span>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,minmax(0,1fr))', gap: space[2] }}>
              {AGENTS.map((a) => {
                const on = agent === a.name;
                return (
                  <button
                    key={a.code}
                    onClick={() => setAgent(a.name)}
                    style={{
                      minHeight: 64,
                      display: 'grid',
                      gridTemplateColumns: '22px minmax(0,1fr) 13px',
                      alignItems: 'center',
                      gap: space[2],
                      padding: 8,
                      border: `1px solid ${on ? line.strong : line.hairline}`,
                      borderRadius: radius.control,
                      background: on ? color.surfaceHover : 'transparent',
                      color: on ? color.textPrimary : color.textTertiary,
                    }}
                  >
                    <span
                      style={{
                        width: 22,
                        height: 22,
                        borderRadius: '50%',
                        background: on ? color.surfaceActive : color.surfaceHover,
                        border: `1px solid ${on ? 'rgba(241,242,246,0.4)' : line.strong}`,
                        display: 'grid',
                        placeItems: 'center',
                        fontSize: fs.caption,
                        fontWeight: 600,
                      }}
                    >
                      {a.code}
                    </span>
                    <span>
                      <strong style={{ display: 'block', fontSize: fs.caption, fontWeight: 600, color: on ? undefined : color.textSecondary }}>
                        {a.name}
                      </strong>
                      <small className="tnum" style={{ display: 'block', marginTop: 2, color: color.textQuaternary, fontSize: fs.caption }}>
                        {a.quota}
                      </small>
                    </span>
                    <span className="tnum" style={{ textAlign: 'right', color: color.textPrimary, fontSize: fs.secondary }}>
                      {on ? '✓' : ''}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>

          <div>
            <div style={{ marginBottom: 8 }}>
              <strong style={label}>起動場所</strong>{' '}
              <span className="tnum" style={hint}>
                新しいセッションを、続けて作業しやすい場所で開きます。
              </span>
            </div>
            <div
              style={{
                display: 'grid',
                gridTemplateColumns: '1fr 1fr',
                gap: space[0],
                padding: 2,
                background: line.hairline,
                borderRadius: radius.card,
                border: `1px solid ${line.hairline}`,
              }}
            >
              {(
                [
                  ['ターミナル', 'ワークスペースの隣で実行', '⌁'],
                  ['Agents', '会話画面を開く', '◌'],
                ] as const
              ).map(([name, sub, glyph]) => {
                const on = place === name;
                return (
                  <button
                    key={name}
                    onClick={() => setPlace(name)}
                    style={{
                      minHeight: 48,
                      display: 'grid',
                      gridTemplateColumns: '20px minmax(0,1fr)',
                      alignItems: 'center',
                      gap: space[2],
                      padding: '4px 8px',
                      borderRadius: radius.control,
                      background: on ? color.surfaceActive : color.panel,
                      boxShadow: on ? `inset 0 0 0 1px ${line.strong}` : undefined,
                    }}
                  >
                    <span style={{ fontSize: fs.title, textAlign: 'center', color: on ? color.textSecondary : color.textQuaternary }}>
                      {glyph}
                    </span>
                    <span>
                      <strong style={{ display: 'block', fontSize: fs.caption, fontWeight: 600, color: on ? undefined : color.textTertiary }}>
                        {name}
                      </strong>
                      <small className="tnum" style={{ display: 'block', marginTop: 2, color: color.textQuaternary, fontSize: fs.caption }}>
                        {sub}
                      </small>
                    </span>
                  </button>
                );
              })}
            </div>
          </div>

          <div>
            <div style={{ marginBottom: 8 }}>
              <strong style={label}>worktree</strong>{' '}
              <span className="tnum" style={hint}>
                変更を分離するか、現在のProjectに紐づけます。
              </span>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: space[2] }}>
              {(
                [
                  ['現在のProject', '~/Projects/clair'],
                  ['新しいworktree', '~/Projects/clair/.worktrees/'],
                ] as const
              ).map(([name, sub]) => {
                const on = worktree === name;
                return (
                  <button
                    key={name}
                    onClick={() => setWorktree(name)}
                    style={{
                      display: 'grid',
                      gridTemplateColumns: '14px minmax(0,1fr)',
                      alignItems: 'start',
                      gap: space[2],
                      padding: 8,
                      border: `1px solid ${on ? line.strong : line.hairline}`,
                      borderRadius: radius.control,
                      background: on ? color.surfaceHover : 'transparent',
                      color: on ? color.textPrimary : color.textTertiary,
                    }}
                  >
                    <span
                      style={{
                        width: 13,
                        height: 13,
                        borderRadius: '50%',
                        border: on ? `4px solid ${color.textPrimary}` : '1px solid rgba(241,242,246,0.36)',
                        marginTop: 2,
                      }}
                    />
                    <span>
                      <strong style={{ display: 'block', fontSize: fs.caption, fontWeight: 600, color: on ? undefined : color.textSecondary }}>
                        {name}
                      </strong>
                      <small className="tnum" style={{ display: 'block', marginTop: 2, color: color.textQuaternary, fontSize: fs.caption }}>
                        {sub}
                      </small>
                    </span>
                  </button>
                );
              })}
            </div>
            <input
              className="cl"
              value={branch}
              onChange={(e) => setBranch(e.target.value)}
              style={{
                marginTop: 8,
                width: '100%',
                height: 32,
                padding: '0 8px',
                border: `1px solid ${line.hairline}`,
                borderRadius: radius.control,
                background: color.chromeRaised,
                color: color.textSecondary,
                fontSize: fs.caption,
                outline: 'none',
              }}
            />
            <div className="cl" style={{ marginTop: 4, color: color.textQuaternary, fontSize: fs.caption }}>
              ~/Projects/clair/.worktrees/{branch}
            </div>
          </div>

          <div>
            <div style={{ marginBottom: 8 }}>
              <strong style={label}>最初のプロンプト</strong>{' '}
              <span className="tnum" style={hint}>
                任意 · 空のまま起動すると待機状態で開きます。
              </span>
            </div>
            <textarea
              className="prose"
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              placeholder="例: EditorPane の行間を少し広げて、既存の配色は変えずに調整して。"
              style={{
                width: '100%',
                minHeight: 56,
                padding: '8px 8px',
                border: `1px solid ${line.hairline}`,
                borderRadius: radius.control,
                background: color.chromeRaised,
                color: color.textSecondary,
                fontSize: fs.caption,
                lineHeight: 1.5,
                outline: 'none',
                resize: 'vertical',
              }}
            />
          </div>

          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: space[3], flexWrap: 'wrap' }}>
            <div>
              <span className="tnum" style={{ display: 'block', marginBottom: 4, color: color.textQuaternary, fontSize: fs.caption }}>
                セッションモード
              </span>
              <div
                style={{
                  minHeight: 30,
                  padding: '0 8px',
                  border: `1px solid ${line.strong}`,
                  borderRadius: radius.control,
                  background: color.canvas,
                  color: color.textSecondary,
                  fontSize: fs.caption,
                  display: 'flex',
                  alignItems: 'center',
                }}
              >
                実装
              </div>
            </div>
            <button
              onClick={() => setConfirm((c) => !c)}
              style={{ display: 'flex', alignItems: 'center', gap: space[2], color: color.textTertiary, fontSize: fs.caption }}
            >
              <span
                style={{
                  width: 13,
                  height: 13,
                  borderRadius: radius.control,
                  background: confirm ? color.textSecondary : 'transparent',
                  border: confirm ? undefined : `1px solid ${line.strong}`,
                  display: 'inline-block',
                }}
              />
              変更を適用する前に確認
            </button>
          </div>
        </div>

        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: space[3],
            padding: '16px 20px',
            borderTop: `1px solid ${line.hairline}`,
            flexWrap: 'wrap',
          }}
        >
          <span className="tnum" style={{ color: color.textQuaternary, fontSize: fs.caption }}>
            {agent} · デフォルトモデル · {place} · {worktree}
          </span>
          <div style={{ display: 'flex', gap: space[2] }}>
            <button
              className="btn-secondary"
              onClick={() => wb.setOverlay(null)}
              style={{
                minHeight: 32,
                padding: '0 12px',
                borderRadius: radius.control,
                fontSize: fs.caption,
                display: 'flex',
                alignItems: 'center',
              }}
            >
              キャンセル
            </button>
            <button
              className="btn-primary"
              onClick={() => {
                wb.setOverlay(null);
                wb.setScreen(place === 'ターミナル' ? 'sessions' : 'activity');
              }}
              style={{
                minHeight: 32,
                padding: '0 12px',
                borderRadius: radius.control,
                fontSize: fs.caption,
                display: 'flex',
                alignItems: 'center',
              }}
            >
              Agentを起動 ↗
            </button>
          </div>
        </div>
      </div>
    </Scrim>
  );
}

export const overlayMono = mono;
