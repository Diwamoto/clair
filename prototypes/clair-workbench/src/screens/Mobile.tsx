import { useState } from 'react';

import {
  IconBell,
  IconBellOff,
  IconBrackets,
  IconClose,
  IconCodex,
  IconEmptySession,
  IconGear,
  IconGrid,
  IconSession,
  IconSparkle,
} from '../icons';
import { useWorkbench } from '../store';
import { color, line, wash } from '../tokens';

type Tab = '概要' | 'セッション' | 'アクティビティ' | '設定';

function Card({ children, style }: { children: React.ReactNode; style?: React.CSSProperties }) {
  return (
    <div
      style={{
        background: color.panel,
        border: `1px solid ${line.hairline}`,
        borderRadius: 10,
        ...style,
      }}
    >
      {children}
    </div>
  );
}

// The EMPTY STATE component the Tokens artboard defines, reused verbatim.
function EmptyState({ title, note }: { title: string; note: string }) {
  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 7,
        padding: '16px 12px',
        borderRadius: 4,
        background: color.canvas,
      }}
    >
      <IconEmptySession size={24} color="#3d454e" />
      <span style={{ fontSize: 12, fontWeight: 600, color: color.textSecondary }}>{title}</span>
      <span style={{ fontSize: 10, color: color.textQuaternary, textAlign: 'center', maxWidth: 260, lineHeight: '15px' }}>
        {note}
      </span>
    </div>
  );
}

function SessionCard({
  icon,
  name,
  project,
  worktree,
  elapsed,
  dim,
  exited,
}: {
  icon: 'claude' | 'opencode' | 'zsh';
  name: string;
  project: string;
  worktree?: string;
  elapsed: string;
  dim?: boolean;
  exited?: boolean;
}) {
  return (
    <Card style={{ padding: '12px 13px', marginBottom: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        {icon === 'claude' ? (
          <IconSparkle size={14} color={color.textTertiary} />
        ) : icon === 'opencode' ? (
          <IconBrackets size={14} color={color.textTertiary} />
        ) : (
          <span style={{ width: 8, height: 8, borderRadius: '50%', background: color.textQuaternary, flexShrink: 0 }} />
        )}
        <span style={{ fontSize: 14, fontWeight: 600, flex: 1, color: dim ? color.textSecondary : color.textPrimary }}>
          {name}
        </span>
        {exited ? (
          <>
            <IconClose size={13} color={color.textTertiary} />
            <span style={{ fontSize: 11, fontWeight: 600, color: color.textPrimary }}>exit 1</span>
          </>
        ) : icon === 'zsh' ? (
          <span className="cl" style={{ fontSize: 12, color: color.textQuaternary }}>
            {elapsed}
          </span>
        ) : (
          <>
            <span style={{ width: 8, height: 8, borderRadius: '50%', background: color.textSecondary, flexShrink: 0 }} />
            <span className="cl" style={{ fontSize: 12, color: color.textQuaternary }}>
              {elapsed}
            </span>
          </>
        )}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginTop: 7, flexWrap: 'wrap' }}>
        <span style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 12, color: color.textTertiary }}>
          <span style={{ width: 7, height: 7, borderRadius: 2, background: color.textTertiary }} />
          {project}
        </span>
        {worktree ? (
          <span
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 4,
              height: 20,
              padding: '0 7px',
              borderRadius: 4,
              background: wash.medium,
              border: `1px solid ${line.strong}`,
              color: color.textTertiary,
              fontSize: 10,
              fontWeight: 600,
            }}
          >
            {worktree}
          </span>
        ) : exited ? (
          <span style={{ fontSize: 12, color: color.textQuaternary }}>11:58:14</span>
        ) : (
          <span style={{ fontSize: 12, color: color.textQuaternary }}>Project root</span>
        )}
      </div>
    </Card>
  );
}

export function MobileApp() {
  const wb = useWorkbench();
  const [tab, setTab] = useState<Tab>('セッション');
  const [muted, setMuted] = useState(false);

  const tabs: Array<[Tab, React.ReactNode]> = [
    ['概要', <IconGrid size={22} />],
    ['セッション', <IconSession size={22} />],
    ['アクティビティ', <IconBell size={22} />],
    ['設定', <IconGear size={22} />],
  ];

  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        background: color.chrome,
        color: color.textPrimary,
      }}
    >
      {/* no fake status bar : this space belongs to the real one */}
      <div style={{ height: 54, flexShrink: 0 }} />

      <div style={{ flexShrink: 0, padding: '0 16px 12px 16px' }}>
        <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: '0.06em', color: color.textMuted, marginBottom: 4 }}>
          PRIVATE NETWORK
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ fontSize: 24, fontWeight: 700, letterSpacing: '-0.02em' }}>{tab}</span>
          <div style={{ flex: 1 }} />
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 5,
              height: 26,
              padding: '0 9px',
              borderRadius: 13,
              background: wash.selected,
              border: '1px solid rgba(242,244,238,0.24)',
            }}
          >
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: color.textSecondary }} />
            <span style={{ fontSize: 11, fontWeight: 600, color: color.textPrimary }}>接続中</span>
          </div>
        </div>
        <div style={{ marginTop: 3, fontSize: 12, color: color.textQuaternary }}>
          daiki-mbp16 · {wb.sessions.length} セッション
        </div>
      </div>

      <div className="scroll" style={{ flex: 1, padding: '0 16px' }}>
        {tab === 'セッション' ? (
          <>
            <Card style={{ padding: 13, marginBottom: 12, background: wash.soft, borderColor: 'rgba(242,244,238,0.24)' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
                <IconCodex size={15} color={color.textPrimary} />
                <span style={{ fontSize: 15, fontWeight: 600, color: color.textPrimary }}>codex</span>
                <span
                  style={{
                    fontSize: 11,
                    fontWeight: 600,
                    color: color.textPrimary,
                    background: wash.strongest,
                    borderRadius: 4,
                    padding: '3px 7px',
                  }}
                >
                  {wb.awaitingApproval ? '入力待ち' : '実行中'}
                </span>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10, fontSize: 12, color: color.textTertiary }}>
                <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                  <span style={{ width: 7, height: 7, borderRadius: 2, background: color.textTertiary }} />
                  clair
                </span>
                <span style={{ color: color.divider }}>·</span>
                <span>Project root</span>
                <span style={{ color: color.divider }}>·</span>
                <span className="cl">4m 12s</span>
              </div>
              <div
                className="cl"
                style={{
                  padding: 10,
                  borderRadius: 7,
                  background: color.canvas,
                  fontSize: 11,
                  lineHeight: '17px',
                  color: color.code,
                  whiteSpace: 'pre',
                  overflowX: 'auto',
                }}
              >
                <div>
                  <span style={{ color: color.attention }}>crates/clair-ptyhost/src/pty.rs</span>
                </div>
                <div>
                  {'  '}
                  <span style={{ color: color.success }}>+18</span> <span style={{ color: color.danger }}>-4</span>
                </div>
                {wb.awaitingApproval ? (
                  <div>
                    Apply this change? <span style={{ color: color.attention }}>[y/N]</span>{' '}
                    <span className="caret" style={{ background: color.code, color: '#121416' }}>
                      {' '}
                    </span>
                  </div>
                ) : (
                  <div>
                    <span style={{ color: color.success }}>applied</span> · pty.rs
                  </div>
                )}
              </div>
              <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
                <button
                  onClick={() => wb.runTerminal('y')}
                  style={{
                    flex: 1,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    height: 44,
                    borderRadius: 8,
                    background: wash.strong,
                    border: `1px solid ${line.stronger}`,
                    color: color.textPrimary,
                    fontSize: 14,
                    fontWeight: 600,
                  }}
                >
                  ターミナルを開く
                </button>
                <button
                  onClick={() => setMuted((m) => !m)}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    width: 52,
                    height: 44,
                    borderRadius: 8,
                    background: color.panel,
                    border: `1px solid ${line.hairline}`,
                    color: color.textTertiary,
                  }}
                >
                  {muted ? <IconBellOff size={18} /> : <IconBell size={18} />}
                </button>
              </div>
            </Card>

            <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: '0.06em', color: color.textMuted, margin: '0 2px 8px 2px' }}>
              その他のセッション
            </div>

            <SessionCard icon="claude" name="Claude Code" project="clair" worktree="pane-split" elapsed="18m" />
            <SessionCard icon="claude" name="Claude Code" project="ccedit" worktree="retire-rust-core" elapsed="1h 42m" />
            <SessionCard icon="opencode" name="OpenCode" project="clair-releases" elapsed="—" dim exited />
            <SessionCard icon="zsh" name="zsh" project="clair" elapsed="3h 06m" dim />
          </>
        ) : (
          <EmptyState
            title={`${tab} はまだキャンバスにありません`}
            note="デザインキャンバスが定義しているモバイル画面はセッションの1枚だけです。ここを埋めるのはキャンバス側の作業です。"
          />
        )}
      </div>

      <div style={{ flexShrink: 0, padding: '10px 16px 8px 16px', color: color.textMuted, fontSize: 11, lineHeight: '16px' }}>
        terminal outputはこの端末に保存されない。
      </div>

      <div
        style={{
          minHeight: 78,
          flexShrink: 0,
          display: 'flex',
          alignItems: 'flex-start',
          paddingTop: 8,
          paddingBottom: 'env(safe-area-inset-bottom)',
          backgroundColor: color.chrome,
          borderTop: `1px solid ${line.chrome}`,
        }}
      >
        {tabs.map(([name, icon]) => {
          const on = tab === name;
          return (
            <button
              key={name}
              onClick={() => setTab(name)}
              style={{
                flex: 1,
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'center',
                gap: 3,
                color: on ? color.textPrimary : color.textQuaternary,
              }}
            >
              {icon}
              <span style={{ fontSize: 10, fontWeight: on ? 600 : 400 }}>{name}</span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
