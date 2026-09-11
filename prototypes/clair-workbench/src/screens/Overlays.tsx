import { useEffect, useMemo, useRef, useState } from 'react';

import { commands, files } from '../data';
import { IconClaude, IconCommand, IconMarkdown, IconQuickOpen, IconSearch } from '../icons';
import { useWorkbench } from '../store';
import { color, line, mono, wash } from '../tokens';

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
        borderRadius: 10,
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
        gap: 9,
        padding: '0 14px',
        borderBottom: `1px solid ${line.hairline}`,
      }}
    >
      <span style={{ color: color.textTertiary, display: 'flex' }}>{icon}</span>
      <span style={{ fontSize: 13, fontWeight: 600, color: color.textPrimary }}>{title}</span>
      <span style={{ fontSize: 10, color: color.textMuted }}>{hint}</span>
      <div style={{ flex: 1 }} />
      <button
        className="cl"
        onClick={onClose}
        style={{
          fontSize: 9,
          fontWeight: 600,
          color: color.textQuaternary,
          background: color.panel,
          border: `1px solid ${line.hairline}`,
          borderRadius: 3,
          padding: '2px 6px',
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
}: {
  value: string;
  onChange: (v: string) => void;
  count: string;
  inputRef: React.RefObject<HTMLInputElement | null>;
  onKeyDown: (e: React.KeyboardEvent) => void;
}) {
  return (
    <div style={{ padding: '10px 12px 8px 12px' }}>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          height: 40,
          padding: '0 11px',
          borderRadius: 5,
          background: color.canvas,
          border: `1px solid ${line.ring}`,
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
            fontSize: 13,
            color: color.textPrimary,
            caretColor: color.textSecondary,
          }}
        />
        <span style={{ fontSize: 10, color: color.textMuted }}>{count}</span>
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
        gap: 5,
        height: 20,
        padding: '0 7px',
        borderRadius: 3,
        background: color.canvas,
        border: `1px solid ${line.hairline}`,
      }}
    >
      <span className="cl" style={{ fontSize: 10, color: color.textSecondary }}>
        {children}
      </span>
    </button>
  );
}

/* ── command palette / quick open ─────────────────────────────────────── */

export function CommandPalette() {
  const wb = useWorkbench();
  const isCommand = wb.overlay === 'command';
  const [query, setQuery] = useState('');
  const [index, setIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

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

  useEffect(() => setIndex(0), [query, isCommand]);

  const commit = (i: number) => {
    const row = rows[i];
    if (!row) return;
    if (isCommand) wb.runCommand(row.key);
    else wb.openFile(row.key);
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setIndex((i) => Math.min(rows.length - 1, i + 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setIndex((i) => Math.max(0, i - 1));
    } else if (e.key === 'Enter') {
      e.preventDefault();
      commit(index);
    }
  };

  return (
    <Scrim onClose={() => wb.setOverlay(null)}>
      <Panel width={560}>
        <ShellHeader
          icon={isCommand ? <IconCommand size={14} /> : <IconQuickOpen size={14} />}
          title={isCommand ? 'コマンド' : 'ファイルへ移動'}
          hint={isCommand ? 'Command Registryの全操作' : 'Project内のファイル'}
          onClose={() => wb.setOverlay(null)}
        />
        <QueryInput
          value={query}
          onChange={setQuery}
          count={`${rows.length} 件`}
          inputRef={inputRef}
          onKeyDown={onKeyDown}
        />
        <div className="scroll" style={{ padding: '0 8px 8px 8px', minHeight: 322, maxHeight: '46vh' }}>
          {rows.map((row, i) => {
            const on = i === index;
            return (
              <button
                key={row.key}
                onMouseEnter={() => setIndex(i)}
                onClick={() => commit(i)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 10,
                  width: '100%',
                  height: 40,
                  padding: '0 10px',
                  marginBottom: 2,
                  borderRadius: 5,
                  background: on ? color.surfaceActive : row.danger ? wash.soft : 'transparent',
                  boxShadow: on
                    ? `inset 0 0 0 1px ${line.ring}`
                    : row.danger
                      ? 'inset 0 0 0 1px rgba(242,244,238,0.16)'
                      : 'none',
                }}
              >
                <span style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0, flex: 1 }}>
                  <span
                    style={{
                      fontSize: 12,
                      fontWeight: 500,
                      color: on ? color.textPrimary : color.textSecondary,
                      whiteSpace: 'nowrap',
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                    }}
                  >
                    {row.title}
                  </span>
                  <span
                    className="cl"
                    style={{
                      fontSize: 9,
                      color: color.textMuted,
                      whiteSpace: 'nowrap',
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                    }}
                  >
                    {row.sub}
                  </span>
                </span>
                <span
                  className="cl"
                  style={{
                    fontSize: 10,
                    fontWeight: 600,
                    color: on ? color.textSecondary : color.textMuted,
                    whiteSpace: 'nowrap',
                    minWidth: 52,
                    textAlign: 'right',
                  }}
                >
                  {row.shortcut}
                </span>
              </button>
            );
          })}
        </div>
        <div
          style={{
            height: 34,
            flexShrink: 0,
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            padding: '0 14px',
            background: color.panel,
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
                  gap: 5,
                  height: 20,
                  padding: '0 8px',
                  borderRadius: 3,
                  background: on ? color.surfaceActive : 'transparent',
                  color: on ? color.textPrimary : color.textTertiary,
                  fontSize: 10,
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
          <span style={{ fontSize: 10, color: color.textQuaternary }}>
            <span className="cl" style={{ color: color.textSecondary }}>
              ↵
            </span>{' '}
            選択中を実行
          </span>
          <div style={{ flex: 1 }} />
          <span style={{ fontSize: 10, color: color.textMuted }}>{isCommand ? '⌘K' : '⌘P'}</span>
        </div>
      </Panel>
    </Scrim>
  );
}

/* ── search ───────────────────────────────────────────────────────────── */

type Hit = { path: string; name: string; kind: string; lineNo: number; text: string; at: number };

export function SearchOverlay() {
  const wb = useWorkbench();
  const [query, setQuery] = useState('Workspace');
  const [index, setIndex] = useState(0);
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
    return out.slice(0, 40);
  }, [query, wb.contents]);

  const fileCount = new Set(hits.map((h) => h.path)).size;

  useEffect(() => setIndex(0), [query]);

  const grouped = useMemo(() => {
    const map = new Map<string, Hit[]>();
    hits.forEach((h) => {
      const list = map.get(h.path) ?? [];
      list.push(h);
      map.set(h.path, list);
    });
    return [...map.entries()];
  }, [hits]);

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setIndex((i) => Math.min(hits.length - 1, i + 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setIndex((i) => Math.max(0, i - 1));
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const hit = hits[index];
      if (hit) wb.openFile(hit.path);
    }
  };

  let flat = -1;

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
        />
        <div className="scroll" style={{ padding: '0 8px 8px 8px', maxHeight: 400, minHeight: 120 }}>
          {grouped.map(([path, list], gi) => {
            const file = files.find((f) => f.path === path)!;
            const dir = path.slice(0, path.lastIndexOf('/'));
            return (
              <div key={path}>
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 8,
                    height: 26,
                    padding: '0 10px',
                    marginTop: gi ? 6 : 0,
                    color: color.textTertiary,
                    fontWeight: 600,
                    fontSize: 11,
                  }}
                >
                  {file.kind === 'md' ? (
                    <IconMarkdown size={12} color={color.textTertiary} />
                  ) : (
                    <IconClaude size={12} color={color.textTertiary} />
                  )}
                  {file.name}
                  <span className="cl" style={{ marginLeft: 'auto', color: color.textMuted, fontWeight: 400 }}>
                    {dir}
                  </span>
                </div>
                {list.map((hit) => {
                  flat += 1;
                  const on = flat === index;
                  const mine = flat;
                  return (
                    <button
                      key={`${hit.path}:${hit.lineNo}`}
                      onMouseEnter={() => setIndex(mine)}
                      onClick={() => wb.openFile(hit.path)}
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        width: '100%',
                        height: 32,
                        padding: '0 10px 0 30px',
                        marginBottom: 1,
                        borderRadius: 5,
                        background: on ? color.surfaceActive : 'transparent',
                        boxShadow: on ? `inset 0 0 0 1px ${line.ring}` : 'none',
                      }}
                    >
                      <span
                        className="cl"
                        style={{
                          fontSize: 11.5,
                          color: on ? color.textPrimary : color.textTertiary,
                          whiteSpace: 'nowrap',
                          overflow: 'hidden',
                        }}
                      >
                        {hit.lineNo}
                        {'  '}
                        {hit.text.slice(0, hit.at).trimStart()}
                        <b
                          style={{
                            color: on ? color.textPrimary : color.textSecondary,
                            background: on ? 'rgba(242,244,238,0.22)' : 'rgba(242,244,238,0.14)',
                            borderRadius: 2,
                          }}
                        >
                          {hit.text.slice(hit.at, hit.at + query.length)}
                        </b>
                        {hit.text.slice(hit.at + query.length)}
                      </span>
                    </button>
                  );
                })}
              </div>
            );
          })}
          {!hits.length ? (
            <div style={{ padding: '18px 10px', color: color.textMuted, fontSize: 11 }}>一致するものはありません。</div>
          ) : null}
        </div>
        <div
          style={{
            height: 34,
            flexShrink: 0,
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            padding: '0 14px',
            background: color.panel,
            borderTop: `1px solid ${line.hairline}`,
          }}
        >
          <KeyChip onClick={() => setIndex((i) => Math.max(0, i - 1))}>↑</KeyChip>
          <KeyChip onClick={() => setIndex((i) => Math.min(hits.length - 1, i + 1))}>↓</KeyChip>
          <span style={{ fontSize: 10, color: color.textQuaternary }}>
            <span className="cl" style={{ color: color.textSecondary }}>
              ↵
            </span>{' '}
            ファイルを開く
          </span>
          <div style={{ flex: 1 }} />
          <span style={{ fontSize: 10, color: color.textMuted }}>⇧⌘F</span>
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

  const label = { fontSize: 11, fontWeight: 600, color: color.textSecondary } as const;
  const hint = { color: color.textMuted, fontSize: 10 } as const;

  return (
    <Scrim onClose={() => wb.setOverlay(null)}>
      <div
        className="overlay-panel"
        style={{
          width: 'min(100%, 620px)',
          margin: '26px 12px 44px',
          overflow: 'hidden',
          borderRadius: 10,
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
            gap: 18,
            padding: '18px 20px',
            borderBottom: `1px solid ${line.hairline}`,
          }}
        >
          <div>
            <div
              style={{
                fontSize: 9,
                fontWeight: 700,
                letterSpacing: '0.06em',
                textTransform: 'uppercase',
                color: color.textMuted,
              }}
            >
              新しいセッション
            </div>
            <h2 style={{ margin: '4px 0 3px', fontSize: 18, fontWeight: 600 }}>Agentを追加</h2>
            <p className="cl" style={{ margin: 0, color: color.textMuted, fontSize: 11, lineHeight: 1.5 }}>
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
              fontSize: 17,
            }}
          >
            ×
          </button>
        </div>

        <div className="scroll" style={{ padding: '18px 20px 20px', display: 'grid', gap: 16, maxHeight: '58vh' }}>
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '34px minmax(0,1fr) auto',
              alignItems: 'center',
              gap: 11,
              padding: 12,
              border: `1px solid ${line.strong}`,
              borderRadius: 6,
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
                fontSize: 13,
                fontWeight: 700,
              }}
            >
              OC
            </span>
            <div>
              <div
                style={{
                  fontSize: 9,
                  fontWeight: 700,
                  letterSpacing: '0.06em',
                  textTransform: 'uppercase',
                  color: color.textMuted,
                }}
              >
                おすすめ · 残り使用量が多いAgent
              </div>
              <strong style={{ fontSize: 12.5, fontWeight: 600 }}>OpenCode</strong>
              <div className="cl" style={{ color: color.textMuted, fontSize: 10 }}>
                5時間 残り84% · 7日間 残り78%
              </div>
            </div>
            <button
              onClick={() => setAgent('OpenCode')}
              style={{
                minHeight: 26,
                padding: '0 9px',
                border: `1px solid ${line.strong}`,
                borderRadius: 4,
                background: wash.selected,
                color: color.textSecondary,
                fontSize: 10.5,
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
              <span className="cl" style={hint}>
                このセッションで使う接続済みのAgentを選択します。
              </span>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,minmax(0,1fr))', gap: 8 }}>
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
                      gap: 8,
                      padding: 10,
                      border: `1px solid ${on ? line.strong : line.hairline}`,
                      borderRadius: 5,
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
                        border: `1px solid ${on ? 'rgba(242,244,238,0.4)' : line.strong}`,
                        display: 'grid',
                        placeItems: 'center',
                        fontSize: 9,
                        fontWeight: 700,
                      }}
                    >
                      {a.code}
                    </span>
                    <span>
                      <strong style={{ display: 'block', fontSize: 10.5, fontWeight: 600, color: on ? undefined : color.textSecondary }}>
                        {a.name}
                      </strong>
                      <small className="cl" style={{ display: 'block', marginTop: 2, color: color.textMuted, fontSize: 9 }}>
                        {a.quota}
                      </small>
                    </span>
                    <span className="cl" style={{ textAlign: 'right', color: color.textPrimary, fontSize: 12 }}>
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
              <span className="cl" style={hint}>
                新しいセッションを、続けて作業しやすい場所で開きます。
              </span>
            </div>
            <div
              style={{
                display: 'grid',
                gridTemplateColumns: '1fr 1fr',
                gap: 1,
                padding: 1,
                background: line.hairline,
                borderRadius: 6,
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
                      gap: 8,
                      padding: '7px 10px',
                      borderRadius: 5,
                      background: on ? color.surfaceActive : color.panel,
                      boxShadow: on ? `inset 0 0 0 1px ${line.strong}` : undefined,
                    }}
                  >
                    <span style={{ fontSize: 15, textAlign: 'center', color: on ? color.textSecondary : color.textQuaternary }}>
                      {glyph}
                    </span>
                    <span>
                      <strong style={{ display: 'block', fontSize: 10.5, fontWeight: 600, color: on ? undefined : color.textTertiary }}>
                        {name}
                      </strong>
                      <small className="cl" style={{ display: 'block', marginTop: 2, color: color.textMuted, fontSize: 9 }}>
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
              <span className="cl" style={hint}>
                変更を分離するか、現在のProjectに紐づけます。
              </span>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
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
                      gap: 8,
                      padding: 10,
                      border: `1px solid ${on ? line.strong : line.hairline}`,
                      borderRadius: 5,
                      background: on ? color.surfaceHover : 'transparent',
                      color: on ? color.textPrimary : color.textTertiary,
                    }}
                  >
                    <span
                      style={{
                        width: 13,
                        height: 13,
                        borderRadius: '50%',
                        border: on ? `4px solid ${color.textPrimary}` : '1px solid rgba(242,244,238,0.36)',
                        marginTop: 1,
                      }}
                    />
                    <span>
                      <strong style={{ display: 'block', fontSize: 10.5, fontWeight: 600, color: on ? undefined : color.textSecondary }}>
                        {name}
                      </strong>
                      <small className="cl" style={{ display: 'block', marginTop: 2, color: color.textMuted, fontSize: 9 }}>
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
                padding: '0 10px',
                border: `1px solid ${line.strong}`,
                borderRadius: 5,
                background: color.canvas,
                color: color.textSecondary,
                fontSize: 11,
                outline: 'none',
              }}
            />
            <div className="cl" style={{ marginTop: 6, color: color.textMuted, fontSize: 9.5 }}>
              ~/Projects/clair/.worktrees/{branch}
            </div>
          </div>

          <div>
            <div style={{ marginBottom: 8 }}>
              <strong style={label}>最初のプロンプト</strong>{' '}
              <span className="cl" style={hint}>
                任意 · 空のまま起動すると待機状態で開きます。
              </span>
            </div>
            <textarea
              className="cl"
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              placeholder="例: EditorPane の行間を少し広げて、既存の配色は変えずに調整して。"
              style={{
                width: '100%',
                minHeight: 56,
                padding: '9px 10px',
                border: `1px solid ${line.strong}`,
                borderRadius: 5,
                background: color.canvas,
                color: color.textSecondary,
                fontSize: 11,
                lineHeight: 1.5,
                outline: 'none',
                resize: 'vertical',
              }}
            />
          </div>

          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
            <div>
              <span className="cl" style={{ display: 'block', marginBottom: 6, color: color.textMuted, fontSize: 9.5 }}>
                セッションモード
              </span>
              <div
                style={{
                  minHeight: 30,
                  padding: '0 9px',
                  border: `1px solid ${line.strong}`,
                  borderRadius: 4,
                  background: color.canvas,
                  color: color.textSecondary,
                  fontSize: 11,
                  display: 'flex',
                  alignItems: 'center',
                }}
              >
                実装
              </div>
            </div>
            <button
              onClick={() => setConfirm((c) => !c)}
              style={{ display: 'flex', alignItems: 'center', gap: 8, color: color.textTertiary, fontSize: 10.5 }}
            >
              <span
                style={{
                  width: 13,
                  height: 13,
                  borderRadius: 3,
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
            gap: 12,
            padding: '16px 20px',
            borderTop: `1px solid ${line.hairline}`,
            background: color.panel,
            flexWrap: 'wrap',
          }}
        >
          <span className="cl" style={{ color: color.textMuted, fontSize: 10 }}>
            {agent} · デフォルトモデル · {place} · {worktree}
          </span>
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              onClick={() => wb.setOverlay(null)}
              style={{
                minHeight: 32,
                padding: '0 12px',
                border: `1px solid ${line.strong}`,
                borderRadius: 5,
                color: color.textTertiary,
                fontSize: 11,
                display: 'flex',
                alignItems: 'center',
              }}
            >
              キャンセル
            </button>
            <button
              onClick={() => {
                wb.setOverlay(null);
                wb.setScreen(place === 'ターミナル' ? 'sessions' : 'activity');
              }}
              style={{
                minHeight: 32,
                padding: '0 12px',
                borderRadius: 5,
                background: color.textPrimary,
                color: '#121416',
                fontSize: 11,
                fontWeight: 600,
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
