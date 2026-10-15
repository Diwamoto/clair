import { useEffect, useRef, useState } from 'react';

import { IconArrowRight, IconChevron, IconClaude, IconCodex, IconMarkdown } from '../icons';
import { color, fs, line, radius, space, wash } from '../tokens';

// ADR-0020: the concierge is a raw PTY agent; this panel draws its official
// transcript as chat. Children are links to their own terminal panes — their
// output is never relayed here, which is what keeps the manager cheap.
// One concierge for all of Clair, not per Project, so switching or closing a
// Project never kills it; it starts the first time the user opens this view.

type Provider = 'claude' | 'codex';
const PROVIDER_ICON = { claude: IconClaude, codex: IconCodex };

type Child = { id: string; name: string; project: string; provider: Provider; pane: number; state: '実行中' | '入力待ち' | '終了 0' | '終了 1' };
type Msg =
  | { id: string; from: 'user' | 'agent'; text: string }
  | { id: string; from: 'tool'; name: string; detail: string }
  | { id: string; from: 'children'; ids: string[] };

const CHILDREN: Child[] = [
  { id: 'c1', name: 'fix-login', project: 'clair', provider: 'claude', pane: 3, state: '実行中' },
  { id: 'c2', name: 'review-api', project: 'clair', provider: 'codex', pane: 4, state: '入力待ち' },
  { id: 'c3', name: 'docs-typo', project: 'clair-docs', provider: 'claude', pane: 5, state: '終了 0' },
];

const SEED: Msg[] = [
  { id: 'm1', from: 'user', text: 'ログインのバグ修正と API のレビュー、ついでに README の typo も片付けて。' },
  { id: 'm2', from: 'tool', name: 'clair agent.launch ×3', detail: 'profile=claude branch=fix-login\nprofile=codex branch=review-api\nprofile=claude branch=docs-typo' },
  { id: 'm3', from: 'agent', text: '3 つに分けて起動しました。進み具合は下のリンクから各ターミナルで確認できます。終わったら結果だけまとめます。' },
  { id: 'm4', from: 'children', ids: ['c1', 'c2', 'c3'] },
];

const STATE_COLOR: Record<Child['state'], string> = {
  実行中: color.success,
  入力待ち: color.attention,
  '終了 0': color.textQuaternary,
  '終了 1': color.danger,
};

function ChildChip({ child, focused, onFocus }: { child: Child; focused: boolean; onFocus: () => void }) {
  return (
    <button
      className="hoverable"
      onClick={onFocus}
      title={`ペイン ${child.pane} へ移動`}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: space[2],
        width: '100%',
        height: 32,
        padding: '0 8px',
        borderRadius: radius.control,
        border: `1px solid ${focused ? line.stronger : line.hairline}`,
        background: focused ? color.surfaceActive : wash.faint,
        color: color.textSecondary,
        fontSize: fs.body,
      }}
    >
      <AgentMark provider={child.provider} size={20} busy={child.state === '実行中'} tint={STATE_COLOR[child.state]} />
      <span style={{ flex: 1, minWidth: 0, textAlign: 'left', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
        {child.name}
        <span style={{ marginLeft: 6, color: color.textQuaternary }}>{child.project}</span>
      </span>
      <span className="tnum" style={{ color: color.textQuaternary }}>{child.state}</span>
      <IconArrowRight size={11} color={color.textQuaternary} />
    </button>
  );
}

/** The agent's logo in a circle; while busy a dot orbits it (the native side: a rotating arc). */
function AgentMark({ provider, size, busy, tint = color.textSecondary }: { provider: Provider; size: number; busy?: boolean; tint?: string }) {
  const Icon = PROVIDER_ICON[provider];
  return (
    <span style={{ position: 'relative', width: size, height: size, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: radius.pill, border: `1px solid ${line.hairline}` }}>
      <Icon size={Math.round(size * 0.5)} color={tint} />
      {busy ? (
        <svg className="orbit" width={size} height={size} viewBox="0 0 20 20" style={{ position: 'absolute', inset: -1 }}>
          <circle cx="10" cy="10" r="9.5" fill="none" stroke={tint} strokeWidth="1.2" strokeLinecap="round" strokeDasharray="12 48" />
        </svg>
      ) : null}
    </span>
  );
}

// ponytail: module-level state shared by panel and main; a store slice if the mock grows more concierge state.
let shared = { phase: 'off' as 'off' | 'booting' | 'ready', focused: null as string | null };
const listeners = new Set<() => void>();
function useShared() {
  const [, bump] = useState(0);
  useEffect(() => {
    const l = () => bump((n) => n + 1);
    listeners.add(l);
    return () => void listeners.delete(l);
  }, []);
  const set = (patch: Partial<typeof shared>) => {
    shared = { ...shared, ...patch };
    listeners.forEach((l) => l());
  };
  return [shared, set] as const;
}

/** Opening the view is what starts the concierge; it then lives until Clair quits. */
function useLazyStart() {
  const [state, set] = useShared();
  useEffect(() => {
    if (shared.phase !== 'off') return;
    set({ phase: 'booting' });
    setTimeout(() => set({ phase: 'ready' }), 1400);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  return [state, set] as const;
}

/** Sidebar: the concierge itself, its tasks, and its instructions. */
export function ConciergePanel() {
  const [{ phase, focused }, set] = useLazyStart();
  const running = phase === 'ready';
  const [tasksOpen, setTasksOpen] = useState(true);
  const setFocused = (v: string) => set({ focused: v });
  const active = CHILDREN.filter((c) => !c.state.startsWith('終了')).length;

  return (
    <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column' }}>
      {/* header: the concierge itself — provider, state, and its raw terminal */}
      <div style={{ display: 'flex', alignItems: 'center', gap: space[2], height: 40, padding: '0 12px', borderBottom: `1px solid ${line.hairline}`, whiteSpace: 'nowrap' }}>
        <IconClaude size={14} color={color.textSecondary} />
        <span style={{ color: color.textPrimary, fontWeight: 600 }}>コンシェルジュ</span>
        <span style={{ display: 'flex', alignItems: 'center', gap: 4, color: color.textQuaternary, fontSize: fs.body }}>
          <span style={{ width: 6, height: 6, borderRadius: radius.pill, background: running ? color.success : color.textQuaternary }} />
          {running ? 'Clair 全体' : '起動中…'}
        </span>
        <span style={{ flex: 1 }} />
        <button className="btn-secondary" disabled={!running} title="コンシェルジュのターミナルを開く" style={{ height: 24, padding: '0 8px', borderRadius: radius.control, fontSize: fs.body }}>
          ターミナル
        </button>
      </div>

      {/* tasks: children launched by the concierge, collapsible */}
      <div style={{ padding: '8px 12px', borderBottom: `1px solid ${line.hairline}` }}>
        <button onClick={() => setTasksOpen((v) => !v)} style={{ display: 'flex', alignItems: 'center', gap: 4, width: '100%', color: color.textTertiary, fontSize: fs.body }}>
          <IconChevron size={10} style={{ transform: tasksOpen ? 'rotate(90deg)' : undefined }} />
          担当中のタスク
          <span className="tnum" style={{ marginLeft: 'auto', color: color.textQuaternary }}>{active} 件実行中</span>
        </button>
        {tasksOpen ? (
          <div style={{ display: 'grid', gap: space[1], marginTop: space[2] }}>
            {CHILDREN.map((c) => (
              <ChildChip key={c.id} child={c} focused={focused === c.id} onFocus={() => setFocused(c.id)} />
            ))}
          </div>
        ) : null}
      </div>

      <div style={{ flex: 1 }} />

      {/* footer: per-Project instructions */}
      <button
        className="hoverable"
        style={{ display: 'flex', alignItems: 'center', gap: space[2], height: 30, padding: '0 12px', borderTop: `1px solid ${line.hairline}`, color: color.textTertiary, fontSize: fs.body }}
      >
        <IconMarkdown size={12} />
        ~/.clair/concierge.md を編集
      </button>
    </div>
  );
}

/** Main area: the concierge's transcript as a full-size chat panel. */
export function ConciergeMain() {
  const [{ phase, focused }, set] = useLazyStart();
  const [messages, setMessages] = useState<Msg[]>(SEED);
  const [thinking, setThinking] = useState(false);
  const [draft, setDraft] = useState('');
  const [openTool, setOpenTool] = useState<string | null>(null);
  const setFocused = (v: string) => set({ focused: v });
  const feedRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = feedRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages.length, thinking]);

  // Sending while the concierge is down starts it with this as its first request.
  const send = () => {
    const text = draft.trim();
    if (!text) return;
    setMessages((m) => [...m, { id: `u${m.length}`, from: 'user', text }]);
    setDraft('');
    // ponytail: canned reply; the native side shows this until the transcript gets the next turn.
    setThinking(true);
    setTimeout(() => {
      setThinking(false);
      setMessages((m) => [...m, { id: `a${m.length}`, from: 'agent', text: '了解です。必要なら Project ごとに分けて agent を起動します。' }]);
    }, 1800);
  };

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, background: color.canvas }}>
      <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', width: '100%', maxWidth: 760, margin: '0 auto' }}>
      {/* chat: the concierge's transcript */}
      <div ref={feedRef} className="scroll" style={{ flex: 1, minHeight: 0, padding: '26px 16px 8px' }}>
        {phase !== 'ready' ? (
          <Waiting label="コンシェルジュを起動しています…" />
        ) : (
          messages.map((m) => (
            <div key={m.id} className="msg" style={{ marginBottom: space[3] }}>
              {m.from === 'tool' ? (
                <div style={{ border: `1px solid ${line.hairline}`, borderRadius: radius.card, background: wash.faint }}>
                  <button
                    onClick={() => setOpenTool(openTool === m.id ? null : m.id)}
                    style={{ display: 'flex', alignItems: 'center', gap: 4, width: '100%', height: 26, padding: '0 8px', color: color.textTertiary, fontSize: fs.caption }}
                  >
                    <IconChevron size={10} style={{ transform: openTool === m.id ? 'rotate(90deg)' : undefined }} />
                    <span className="tnum">{m.name}</span>
                  </button>
                  {openTool === m.id ? (
                    <div className="cl" style={{ padding: '0 8px 8px 22px', color: color.textQuaternary, fontSize: fs.caption, whiteSpace: 'pre-wrap' }}>{m.detail}</div>
                  ) : null}
                </div>
              ) : m.from === 'children' ? (
                <div style={{ display: 'grid', gap: space[1] }}>
                  {m.ids.map((id) => {
                    const c = CHILDREN.find((x) => x.id === id)!;
                    return <ChildChip key={id} child={c} focused={focused === id} onFocus={() => setFocused(id)} />;
                  })}
                </div>
              ) : m.from === 'agent' ? (
                <div style={{ display: 'flex', gap: space[2], alignItems: 'flex-start' }}>
                  <AgentMark provider="claude" size={22} />
                  <div className="prose" style={{ color: color.textSecondary, fontSize: fs.title, lineHeight: 1.55, paddingTop: 1 }}>{m.text}</div>
                </div>
              ) : (
                <div
                  className="prose"
                  style={{
                    padding: m.from === 'user' ? '8px 12px' : 0,
                    borderRadius: radius.overlay,
                    background: m.from === 'user' ? wash.strong : undefined,
                    color: m.from === 'user' ? color.textPrimary : color.textSecondary,
                    fontSize: fs.title,
                    lineHeight: 1.55,
                    maxWidth: m.from === 'user' ? '85%' : undefined,
                    marginLeft: m.from === 'user' ? 'auto' : undefined,
                    width: m.from === 'user' ? 'fit-content' : undefined,
                  }}
                >
                  {m.text}
                </div>
              )}
            </div>
          ))
        )}
        {thinking ? (
          <div style={{ display: 'flex', alignItems: 'center', gap: space[2], color: color.textTertiary, fontSize: fs.body }}>
            <AgentMark provider="claude" size={22} busy />
            <span className="shimmer">考えています…</span>
          </div>
        ) : null}
      </div>

      {/* composer: text goes to the concierge's PTY */}
      <div style={{ padding: '8px 12px' }}>
        <div style={{ display: 'flex', alignItems: 'flex-end', gap: space[2], padding: '6px 6px 6px 12px', borderRadius: radius.overlay, border: `1px solid ${line.stronger}`, background: color.canvas }}>
          <textarea
            value={draft}
            disabled={phase !== 'ready'}
                        onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
                e.preventDefault();
                send();
              }
            }}
            rows={2}
            placeholder="コンシェルジュに頼む…"
            style={{ flex: 1, minWidth: 0, resize: 'none', border: 0, outline: 'none', background: 'transparent', color: color.textPrimary, fontSize: fs.title }}
          />
          <button
            onClick={send}
            disabled={!draft.trim()}
            title="送信"
            aria-label="送信"
            style={{ width: 26, height: 26, flexShrink: 0, borderRadius: radius.pill, display: 'flex', alignItems: 'center', justifyContent: 'center', background: draft.trim() ? color.textPrimary : color.textQuaternary, color: color.canvas }}
          >
            <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"><path d="M8 13V3M3.5 7.5 8 3l4.5 4.5" /></svg>
          </button>
        </div>
      </div>

      </div>
    </div>
  );
}

/** Booting: the agent's logo in the middle with a dot orbiting it. */
function Waiting({ label }: { label: string }) {
  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: space[3], color: color.textTertiary, fontSize: fs.body }}>
      <AgentMark provider="claude" size={56} busy />
      <span className="shimmer">{label}</span>
    </div>
  );
}
