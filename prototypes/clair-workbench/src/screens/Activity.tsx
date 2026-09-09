import { useEffect, useRef, useState } from 'react';

import { activityItems } from '../data';
import { IconSearch } from '../icons';
import { useWorkbench } from '../store';

import { color, line, wash } from '../tokens';

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
              gap: 8,
              height: 40,
              padding: '0 12px',
              margin: '8px 12px',
              borderRadius: 6,
              background: color.canvas,
              border: `1px solid ${line.strong}`,
            }}
          >
            <IconSearch size={13} color={color.textQuaternary} />
            <input
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder="アクティビティを絞り込む"
              style={{
                flex: 1,
                minWidth: 0,
                border: 0,
                outline: 'none',
                background: 'transparent',
                fontSize: 11,
                color: color.textSecondary,
              }}
            />
          </div>
          <div style={{ display: 'flex', gap: 5, padding: '0 12px 8px' }}>
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
                    borderRadius: 4,
                    background: on ? wash.raised : 'transparent',
                    border: on ? `1px solid ${line.hairline}` : '1px solid transparent',
                    color: on ? color.textSecondary : color.textQuaternary,
                    fontSize: 10,
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
                  onClick={() => wb.setActiveActivity(item.id)}
                  style={{
                    display: 'flex',
                    alignItems: 'flex-start',
                    gap: 10,
                    width: '100%',
                    padding: '9px 14px',
                    background: selected ? 'rgba(242,244,238,0.055)' : undefined,
                    borderLeft: `2px solid ${selected ? color.textSecondary : 'transparent'}`,
                  }}
                >
                  <span
                    style={{
                      width: 18,
                      height: 18,
                      flex: '0 0 18px',
                      borderRadius: '50%',
                      background:
                        item.state === 'done' ? 'rgba(242,244,238,0.05)' : selected || item.state === 'attention' ? wash.strongest : wash.selected,
                      color: item.state === 'done' ? color.textQuaternary : selected || item.state === 'attention' ? color.textPrimary : color.textSecondary,
                      display: 'grid',
                      placeItems: 'center',
                      fontSize: 10,
                      marginTop: 1,
                    }}
                  >
                    {item.glyph}
                  </span>
                  <span style={{ minWidth: 0 }}>
                    <strong
                      style={{
                        display: 'block',
                        color: selected ? color.textPrimary : color.textSecondary,
                        fontSize: 11,
                        fontWeight: 500,
                        textAlign: 'left',
                      }}
                    >
                      {item.title}
                    </strong>
                    <small style={{ display: 'block', marginTop: 4, color: color.textMuted, fontSize: 10 }}>
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

export function ActivityMain() {
  const wb = useWorkbench();
  const [draft, setDraft] = useState('');
  const feedRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = feedRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [wb.messages.length]);

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, background: color.canvas }}>
          <div ref={feedRef} className="scroll" style={{ minHeight: 0, flex: 1, padding: '26px 0 16px' }}>
            {wb.messages.map((m) => (
              <div key={m.id} style={{ maxWidth: 640, margin: '0 auto 16px', padding: '0 30px' }}>
                <div
                  style={{
                    padding: '12px 16px',
                    borderRadius: 10,
                    background: m.from === 'user' ? wash.strong : 'rgba(242,244,238,0.045)',
                    color: m.from === 'user' ? color.textPrimary : color.textSecondary,
                    fontSize: 13,
                    lineHeight: 1.55,
                    maxWidth: '85%',
                    marginLeft: m.from === 'user' ? 'auto' : undefined,
                  }}
                >
                  {m.text}
                </div>
                <div
                  className="cl"
                  style={{ marginTop: 6, color: color.textMuted, fontSize: 10, textAlign: m.from === 'user' ? 'right' : 'left' }}
                >
                  {m.time}
                </div>
              </div>
            ))}

            <div style={{ maxWidth: 640, margin: '0 auto 16px', padding: '0 30px' }}>
              <div
                style={{
                  border: `1px solid ${line.stronger}`,
                  borderRadius: 8,
                  background: wash.faint,
                  overflow: 'hidden',
                }}
              >
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    gap: 12,
                    padding: '12px 16px',
                    borderBottom: `1px solid rgba(242,244,238,0.14)`,
                    color: color.textPrimary,
                    fontSize: 12.5,
                    fontWeight: 600,
                  }}
                >
                  変更を適用してテストを実行しますか？
                  <span className="cl" style={{ color: color.textMuted, fontWeight: 400, fontSize: 10 }}>
                    PermissionRequest
                  </span>
                </div>
                <div style={{ padding: '14px 16px', display: 'grid', gap: 10 }}>
                  <div
                    className="cl scroll"
                    style={{
                      padding: '9px 11px',
                      border: `1px solid ${line.hairline}`,
                      borderRadius: 6,
                      background: color.canvas,
                      color: color.textSecondary,
                      fontSize: 12.5,
                      whiteSpace: 'pre',
                    }}
                  >
                    git diff --check &amp;&amp; swift test --package-path packages/ClairMobileKit
                  </div>
                  <div className="cl" style={{ display: 'flex', gap: 18, color: color.textMuted, fontSize: 10, flexWrap: 'wrap' }}>
                    <span>作業ディレクトリ ~/Projects/ccedit</span>
                    <span>リスク ローカルのテストコマンドを実行</span>
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 8, padding: '0 16px 14px' }}>
                  {(
                    [
                      ['拒否', line.hairline, 'transparent', color.textTertiary, 400],
                      ['セッション中は許可', line.strong, wash.medium, color.textSecondary, 400],
                      ['今回だけ許可', line.stronger, wash.strong, color.textPrimary, 600],
                    ] as const
                  ).map(([label, border, bg, fg, weight]) => {
                    const chosen = wb.approvalDecision === label;
                    return (
                      <button
                        key={label}
                        onClick={() => wb.setApprovalDecision(label)}
                        style={{
                          flex: 1,
                          textAlign: 'center',
                          minHeight: 30,
                          lineHeight: '30px',
                          border: `1px solid ${chosen ? line.ring : border}`,
                          borderRadius: 4,
                          background: chosen ? color.surfaceActive : bg,
                          color: chosen ? color.textPrimary : fg,
                          fontSize: 11,
                          fontWeight: weight,
                        }}
                      >
                        {label}
                      </button>
                    );
                  })}
                </div>
              </div>
              {wb.approvalDecision ? (
                <div className="cl" style={{ marginTop: 8, color: color.textMuted, fontSize: 10 }}>
                  {wb.approvalDecision} を選択しました。
                </div>
              ) : null}
            </div>
          </div>

          <div
            style={{
              flexShrink: 0,
              margin: '0 20px 16px',
              display: 'flex',
              alignItems: 'center',
              gap: 10,
              padding: '0 14px',
              height: 46,
              borderRadius: 8,
              background: color.panel,
              border: `1px solid ${line.strong}`,
            }}
          >
            <input
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && draft.trim()) {
                  wb.sendMessage(draft.trim());
                  setDraft('');
                }
              }}
              placeholder="Agentにメッセージ…"
              style={{
                flex: 1,
                border: 0,
                outline: 'none',
                background: 'transparent',
                color: color.textPrimary,
                fontSize: 12.5,
              }}
            />
          </div>
    </div>
  );
}

export function ActivityStatus() {
  return (
    <span className="cl" style={{ color: color.textMuted }}>
      Claude Code · 実行中
    </span>
  );
}
