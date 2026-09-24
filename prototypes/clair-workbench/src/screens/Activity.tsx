import { useEffect, useRef, useState, type CSSProperties } from 'react';

import { activityItems } from '../data';
import { IconArrowRight, IconSearch } from '../icons';
import { useWorkbench } from '../store';

import { color, fs, line, radius, space, wash } from '../tokens';

export function ActivityPanel() {
  const wb = useWorkbench();
  const [filter, setFilter] = useState('');
  const [scope, setScope] = useState<'すべて' | 'clair' | 'ccedit'>('すべて');

  const items = activityItems.filter((i) => !filter || i.title.includes(filter) || i.meta.includes(filter));

  return (
    <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column' }}>
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: space[2],
              height: 40,
              padding: '0 12px',
              margin: '8px 12px',
              borderRadius: radius.card,
              background: color.chrome,
              border: `1px solid ${line.hairline}`,
            }}
          >
            <IconSearch size={13} color={color.textQuaternary} />
            <input
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder="Agents を絞り込む"
              style={{
                flex: 1,
                minWidth: 0,
                border: 0,
                outline: 'none',
                background: 'transparent',
                fontSize: fs.caption,
                color: color.textSecondary,
              }}
            />
          </div>
          <div style={{ display: 'flex', gap: space[1], padding: '0 12px 8px' }}>
            {(['すべて', 'clair', 'ccedit'] as const).map((s) => {
              const on = scope === s;
              return (
                <button
                  key={s}
                  onClick={() => setScope(s)}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    height: 22,
                    padding: '0 8px',
                    borderRadius: radius.control,
                    background: on ? wash.raised : 'transparent',
                    border: on ? `1px solid ${line.hairline}` : '1px solid transparent',
                    color: on ? color.textSecondary : color.textQuaternary,
                    fontSize: fs.caption,
                  }}
                >
                  {s}
                </button>
              );
            })}
          </div>
          <div className="scroll" style={{ flex: 1 }}>
            {items.map((item) => {
              const selected = wb.activeActivity === item.id;
              return (
                <button
                  key={item.id}
                  className={selected ? undefined : 'hoverable'}
                  onClick={() => wb.setActiveActivity(item.id)}
                  style={{
                    display: 'flex',
                    alignItems: 'flex-start',
                    gap: space[2],
                    width: 'calc(100% - 16px)',
                    margin: '0 8px',
                    padding: '8px',
                    borderRadius: radius.control,
                    background: selected ? color.surfaceActive : undefined,
                  }}
                >
                  <span
                    style={{
                      width: 18,
                      height: 18,
                      flex: '0 0 18px',
                      borderRadius: '50%',
                      background:
                        item.state === 'done' ? 'rgba(241,242,246,0.05)' : selected || item.state === 'attention' ? wash.strongest : wash.selected,
                      color: item.state === 'done' ? color.textQuaternary : selected || item.state === 'attention' ? color.textPrimary : color.textSecondary,
                      display: 'grid',
                      placeItems: 'center',
                      fontSize: fs.caption,
                      marginTop: 2,
                    }}
                  >
                    {item.glyph}
                  </span>
                  <span style={{ minWidth: 0 }}>
                    <strong
                      style={{
                        display: 'block',
                        color: selected ? color.textPrimary : color.textSecondary,
                        fontSize: fs.caption,
                        fontWeight: 400,
                        textAlign: 'left',
                      }}
                    >
                      {item.title}
                    </strong>
                    <small style={{ display: 'block', marginTop: 4, color: color.textQuaternary, fontSize: fs.caption }}>
                      {item.meta}
                    </small>
                  </span>
                </button>
              );
            })}
          </div>
    </div>
  );
}

// One 720px column for messages, approval card and composer alike.
const COLUMN: CSSProperties = { width: '100%', maxWidth: 720, margin: '0 auto', padding: '0 16px' };

export function ActivityMain() {
  const wb = useWorkbench();
  const [draft, setDraft] = useState('');
  const feedRef = useRef<HTMLDivElement>(null);
  const send = () => {
    if (!draft.trim()) return;
    wb.sendMessage(draft.trim());
    setDraft('');
  };

  useEffect(() => {
    const el = feedRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [wb.messages.length]);

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, background: color.canvas }}>
          <div ref={feedRef} className="scroll" style={{ minHeight: 0, flex: 1, padding: '26px 0 16px' }}>
            {wb.messages.map((m) => (
              <div key={m.id} className="msg" style={{ ...COLUMN, marginBottom: space[4] }}>
                <div
                  className="prose"
                  style={{
                    padding: m.from === 'user' ? '12px 16px' : 0,
                    borderRadius: radius.overlay,
                    background: m.from === 'user' ? wash.strong : undefined,
                    color: m.from === 'user' ? color.textPrimary : color.textSecondary,
                    fontSize: fs.body,
                    lineHeight: 1.55,
                    maxWidth: m.from === 'user' ? '85%' : undefined,
                    marginLeft: m.from === 'user' ? 'auto' : undefined,
                    width: m.from === 'user' ? 'fit-content' : undefined,
                  }}
                >
                  {m.text}
                </div>
                <div
                  className="tnum msg-time"
                  style={{ marginTop: space[1], color: color.textQuaternary, fontSize: fs.caption, textAlign: m.from === 'user' ? 'right' : 'left' }}
                >
                  {m.time}
                </div>
              </div>
            ))}

            <div style={{ ...COLUMN, marginBottom: space[4] }}>
              <div
                style={{
                  border: `1px solid ${line.stronger}`,
                  borderRadius: radius.card,
                  background: wash.faint,
                  overflow: 'hidden',
                }}
              >
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    gap: space[3],
                    padding: '12px 16px',
                    borderBottom: `1px solid rgba(241,242,246,0.14)`,
                    color: color.textPrimary,
                    fontSize: fs.body,
                    fontWeight: 600,
                  }}
                >
                  変更を適用してテストを実行しますか？
                  <span className="tnum" style={{ color: color.textQuaternary, fontWeight: 400, fontSize: fs.caption }}>
                    PermissionRequest
                  </span>
                </div>
                <div style={{ padding: '12px 16px', display: 'grid', gap: space[2] }}>
                  <div
                    className="cl scroll"
                    style={{
                      padding: '8px 8px',
                      border: `1px solid ${line.hairline}`,
                      borderRadius: radius.card,
                      background: color.canvas,
                      color: color.textSecondary,
                      fontSize: fs.body,
                      whiteSpace: 'pre',
                    }}
                  >
                    git diff --check &amp;&amp; swift test --package-path packages/ClairMobileKit
                  </div>
                  <div className="tnum" style={{ display: 'flex', gap: space[4], color: color.textQuaternary, fontSize: fs.caption, flexWrap: 'wrap' }}>
                    <span>作業ディレクトリ ~/Projects/ccedit</span>
                    <span>リスク ローカルのテストコマンドを実行</span>
                  </div>
                </div>
                <div style={{ display: 'flex', justifyContent: 'flex-end', gap: space[2], padding: '0 16px 12px' }}>
                  {(
                    [
                      ['拒否', 'btn-secondary'],
                      ['セッション中は許可', 'btn-secondary'],
                      ['今回だけ許可', 'btn-primary'],
                    ] as const
                  ).map(([label, cls]) => (
                    <button
                      key={label}
                      className={cls}
                      onClick={() => wb.setApprovalDecision(label)}
                      style={{
                        textAlign: 'center',
                        minHeight: 30,
                        padding: '0 12px',
                        borderRadius: radius.control,
                        fontSize: fs.caption,
                      }}
                    >
                      {label}
                    </button>
                  ))}
                </div>
              </div>
              {wb.approvalDecision ? (
                <div className="tnum" style={{ marginTop: 8, color: color.textQuaternary, fontSize: fs.caption }}>
                  {wb.approvalDecision} を選択しました。
                </div>
              ) : null}
            </div>
          </div>

          <div style={{ ...COLUMN, flexShrink: 0, marginBottom: space[4] }}>
            <div
              className="field"
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: space[2],
                padding: '0 8px 0 12px',
                height: 46,
                borderRadius: radius.card,
                background: color.canvas,
                border: `1px solid ${line.hairline}`,
              }}
            >
              <input
                className="prose"
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') send();
                }}
                placeholder="Agentにメッセージ…"
                style={{
                  flex: 1,
                  border: 0,
                  outline: 'none',
                  background: 'transparent',
                  color: color.textPrimary,
                  fontSize: fs.body,
                }}
              />
              <button
                className="btn-primary"
                aria-label="送信"
                title="送信"
                disabled={!draft.trim()}
                onClick={send}
                style={{ width: 28, height: 28, display: 'grid', placeItems: 'center', borderRadius: radius.control, flexShrink: 0 }}
              >
                <IconArrowRight size={14} style={{ transform: 'rotate(-90deg)' }} />
              </button>
            </div>
          </div>
    </div>
  );
}

export function ActivityStatus() {
  return (
    <span className="tnum" style={{ color: color.textQuaternary }}>
      Claude Code · 実行中
    </span>
  );
}
