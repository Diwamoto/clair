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

// `?review=1` reveals a Live/Design toggle so the mobile screens can be
// checked against the canvas's MobileOverview artboard side by side. It has
// no effect on the product route. Only セッション has a matching artboard —
// the other three tabs stay gaps for the canvas to fill, same as Live.
const reviewMode = typeof window !== 'undefined' && window.location.search.includes('review=1');

// Copied verbatim from MobileOverview.dc.html on the design canvas (the
// セッション tab's own frame, including its own status-bar spacer and tab
// bar) so the comparison has no transcription drift from the artboard.
const SESSION_ARTBOARD_STYLE = `
  .dc-cl { font-family: "SF Mono", ui-monospace, Menlo, monospace; }
  .dc-card { background: #181b1f; border: 1px solid rgba(242,244,238,0.11); border-radius: 10px; }
  .dc-mica-thin { background: #31363f; }
`;

const SESSION_ARTBOARD_HTML = `
<div style="width: 390px; height: 844px; display: flex; flex-direction: column; overflow: hidden; background: #282c34; color: #f1f3ef; font-family: -apple-system, BlinkMacSystemFont, 'Hiragino Sans', 'Hiragino Kaku Gothic ProN', 'SF Pro Text', system-ui, sans-serif; -webkit-font-smoothing: antialiased;">
  <div style="height: 54px; flex-shrink: 0;"></div>
  <div style="flex-shrink: 0; padding: 0 16px 12px 16px;">
    <div style="font-size: 10px; font-weight: 700; letter-spacing: 0.06em; color: #55605a; margin-bottom: 4px;">PRIVATE NETWORK</div>
    <div style="display: flex; align-items: center; gap: 8px;">
      <span style="font-size: 24px; font-weight: 700; letter-spacing: -0.02em;">セッション</span>
      <div style="flex: 1;"></div>
      <div style="display: flex; align-items: center; gap: 5px; height: 26px; padding: 0 9px; border-radius: 13px; background: rgba(242,244,238,0.08); border: 1px solid rgba(242,244,238,0.24);">
        <span style="width: 6px; height: 6px; border-radius: 50%; background: #c9cec8;"></span>
        <span style="font-size: 11px; font-weight: 600; color: #f1f3ef;">接続中</span>
      </div>
    </div>
    <div style="margin-top: 3px; font-size: 12px; color: #707871;">daiki-mbp16 · 5 セッション</div>
  </div>
  <div style="flex: 1; overflow: hidden; padding: 0 16px;">
    <div class="dc-card" style="padding: 13px; margin-bottom: 12px; background: rgba(242,244,238,0.04); border-color: rgba(242,244,238,0.24);">
      <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 8px;">
        <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="#f1f3ef" stroke-width="1.3" stroke-linejoin="round"><path d="M8 1.6l5.5 3.2v6.4L8 14.4l-5.5-3.2V4.8z"/></svg>
        <span style="font-size: 15px; font-weight: 600; color: #f1f3ef;">codex</span>
        <span style="font-size: 11px; font-weight: 600; color: #f1f3ef; background: rgba(242,244,238,0.12); border-radius: 4px; padding: 3px 7px;">入力待ち</span>
      </div>
      <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 10px; font-size: 12px; color: #9ba19b;">
        <span style="display: flex; align-items: center; gap: 5px;"><span style="width: 7px; height: 7px; border-radius: 2px; background: #9ba19b;"></span>clair</span>
        <span style="color: #3d454e;">·</span>
        <span>Project root</span>
        <span style="color: #3d454e;">·</span>
        <span class="dc-cl">4m 12s</span>
      </div>
      <div class="dc-cl" style="padding: 10px; border-radius: 7px; background: #282c34; font-size: 11px; line-height: 17px; color: #abb2bf; white-space: pre; overflow: hidden;"><div><span style="color: #e5c07b;">crates/clair-ptyhost/src/pty.rs</span></div><div>  <span style="color: #8acb94;">+18</span> <span style="color: #e27b83;">-4</span></div><div>Apply this change? <span style="color: #e5c07b;">[y/N]</span> <span style="background: #abb2bf; color: #121416;"> </span></div></div>
      <div style="display: flex; gap: 8px; margin-top: 10px;">
        <div style="flex: 1; display: flex; align-items: center; justify-content: center; height: 44px; border-radius: 8px; background: rgba(242,244,238,0.09); border: 1px solid rgba(242,244,238,0.28); color: #f1f3ef; font-size: 14px; font-weight: 600;">ターミナルを開く</div>
        <div style="display: flex; align-items: center; justify-content: center; width: 52px; height: 44px; border-radius: 8px; background: #181b1f; border: 1px solid rgba(242,244,238,0.11); color: #9ba19b;">
          <svg width="18" height="18" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M8 2.6a3.5 3.5 0 0 1 3.5 3.5c0 2.9 1.2 3.8 1.2 3.8H3.3s1.2-.9 1.2-3.8A3.5 3.5 0 0 1 8 2.6z"/><path d="M6.7 12.3a1.4 1.4 0 0 0 2.6 0"/><path d="M3 3l10 10"/></svg>
        </div>
      </div>
    </div>
    <div style="font-size: 10px; font-weight: 700; letter-spacing: 0.06em; color: #55605a; margin: 0 2px 8px 2px;">その他のセッション</div>
    <div class="dc-card" style="padding: 12px 13px; margin-bottom: 8px;">
      <div style="display: flex; align-items: center; gap: 8px;">
        <svg width="14" height="14" viewBox="0 0 16 16" fill="#9ba19b" style="flex-shrink: 0;"><path d="M8 1.4l1.15 4.45L13.6 7 9.15 8.15 8 12.6l-1.15-4.45L2.4 7l4.45-1.15z"/></svg>
        <span style="font-size: 14px; font-weight: 600; flex: 1;">Claude Code</span>
        <span style="width: 8px; height: 8px; border-radius: 50%; background: #c9cec8; flex-shrink: 0;"></span>
        <span class="dc-cl" style="font-size: 12px; color: #707871;">18m</span>
      </div>
      <div style="display: flex; align-items: center; gap: 7px; margin-top: 7px;">
        <span style="display: flex; align-items: center; gap: 5px; font-size: 12px; color: #9ba19b;"><span style="width: 7px; height: 7px; border-radius: 2px; background: #9ba19b;"></span>clair</span>
        <span style="display: inline-flex; align-items: center; gap: 4px; height: 20px; padding: 0 7px; border-radius: 4px; background: rgba(242,244,238,0.06); border: 1px solid rgba(242,244,238,0.19); color: #9ba19b; font-size: 10px; font-weight: 600;">
          <svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="4.6" cy="3.7" r="1.7"/><circle cx="4.6" cy="12.3" r="1.7"/><circle cx="11.4" cy="6.4" r="1.7"/><path d="M4.6 5.4v5.2M11.4 8.1c0 2.2-2.1 2.5-3.6 2.9"/></svg>
          pane-split
        </span>
      </div>
    </div>
    <div class="dc-card" style="padding: 12px 13px; margin-bottom: 8px;">
      <div style="display: flex; align-items: center; gap: 8px;">
        <svg width="14" height="14" viewBox="0 0 16 16" fill="#9ba19b" style="flex-shrink: 0;"><path d="M8 1.4l1.15 4.45L13.6 7 9.15 8.15 8 12.6l-1.15-4.45L2.4 7l4.45-1.15z"/></svg>
        <span style="font-size: 14px; font-weight: 600; flex: 1;">Claude Code</span>
        <span style="width: 8px; height: 8px; border-radius: 50%; background: #c9cec8; flex-shrink: 0;"></span>
        <span class="dc-cl" style="font-size: 12px; color: #707871;">1h 42m</span>
      </div>
      <div style="display: flex; align-items: center; gap: 7px; margin-top: 7px;">
        <span style="display: flex; align-items: center; gap: 5px; font-size: 12px; color: #9ba19b;"><span style="width: 7px; height: 7px; border-radius: 2px; background: #9ba19b;"></span>ccedit</span>
        <span style="display: inline-flex; align-items: center; gap: 4px; height: 20px; padding: 0 7px; border-radius: 4px; background: rgba(242,244,238,0.06); border: 1px solid rgba(242,244,238,0.19); color: #9ba19b; font-size: 10px; font-weight: 600;">
          <svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="4.6" cy="3.7" r="1.7"/><circle cx="4.6" cy="12.3" r="1.7"/><circle cx="11.4" cy="6.4" r="1.7"/><path d="M4.6 5.4v5.2M11.4 8.1c0 2.2-2.1 2.5-3.6 2.9"/></svg>
          retire-rust-core
        </span>
      </div>
    </div>
    <div class="dc-card" style="padding: 12px 13px; margin-bottom: 8px;">
      <div style="display: flex; align-items: center; gap: 8px;">
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="#9ba19b" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" style="flex-shrink: 0;"><path d="M6 4.5 2.8 8 6 11.5M10 4.5 13.2 8 10 11.5"/></svg>
        <span style="font-size: 14px; font-weight: 600; flex: 1; color: #c9cec8;">OpenCode</span>
        <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="#9ba19b" stroke-width="1.9" stroke-linecap="round" style="flex-shrink: 0;"><path d="M5 5l6 6M11 5l-6 6"/></svg>
        <span style="font-size: 11px; font-weight: 600; color: #f1f3ef;">exit 1</span>
      </div>
      <div style="display: flex; align-items: center; gap: 7px; margin-top: 7px;">
        <span style="display: flex; align-items: center; gap: 5px; font-size: 12px; color: #9ba19b;"><span style="width: 7px; height: 7px; border-radius: 2px; background: #9ba19b;"></span>clair-releases</span>
        <span style="font-size: 12px; color: #707871;">11:58:14</span>
      </div>
    </div>
    <div class="dc-card" style="padding: 12px 13px;">
      <div style="display: flex; align-items: center; gap: 8px;">
        <span style="width: 8px; height: 8px; border-radius: 50%; background: #707871; flex-shrink: 0;"></span>
        <span style="font-size: 14px; font-weight: 600; flex: 1; color: #c9cec8;">zsh</span>
        <span class="dc-cl" style="font-size: 12px; color: #707871;">3h 06m</span>
      </div>
      <div style="display: flex; align-items: center; gap: 7px; margin-top: 7px;">
        <span style="display: flex; align-items: center; gap: 5px; font-size: 12px; color: #9ba19b;"><span style="width: 7px; height: 7px; border-radius: 2px; background: #9ba19b;"></span>clair</span>
        <span style="font-size: 12px; color: #707871;">Project root</span>
      </div>
    </div>
  </div>
  <div style="flex-shrink: 0; padding: 10px 16px 8px 16px; color: #55605a; font-size: 11px; line-height: 16px;">
    terminal outputはこの端末に保存されない。
  </div>
  <div class="dc-mica-thin" style="height: 78px; flex-shrink: 0; display: flex; align-items: flex-start; padding-top: 8px; background-color: #31363f; border-top: 1px solid rgba(242,244,238,0.1);">
    <div style="flex: 1; display: flex; flex-direction: column; align-items: center; gap: 3px; color: #707871;">
      <svg width="22" height="22" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="2.2" y="2.6" width="4.6" height="4.6" rx="1"/><rect x="9.2" y="2.6" width="4.6" height="4.6" rx="1"/><rect x="2.2" y="8.8" width="4.6" height="4.6" rx="1"/><rect x="9.2" y="8.8" width="4.6" height="4.6" rx="1"/></svg>
      <span style="font-size: 10px;">概要</span>
    </div>
    <div style="flex: 1; display: flex; flex-direction: column; align-items: center; gap: 3px; color: #f1f3ef;">
      <svg width="22" height="22" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><rect x="2.2" y="3.2" width="11.6" height="9.6" rx="1.5"/><path d="M4.9 6.4 6.9 8.3 4.9 10.2"/><path d="M8.5 10.4h2.6"/></svg>
      <span style="font-size: 10px; font-weight: 600;">セッション</span>
    </div>
    <div style="flex: 1; display: flex; flex-direction: column; align-items: center; gap: 3px; color: #707871;">
      <svg width="22" height="22" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M8 2.6a3.5 3.5 0 0 1 3.5 3.5c0 2.9 1.2 3.8 1.2 3.8H3.3s1.2-.9 1.2-3.8A3.5 3.5 0 0 1 8 2.6z"/><path d="M6.7 12.3a1.4 1.4 0 0 0 2.6 0"/></svg>
      <span style="font-size: 10px;">アクティビティ</span>
    </div>
    <div style="flex: 1; display: flex; flex-direction: column; align-items: center; gap: 3px; color: #707871;">
      <svg width="22" height="22" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="2.2"/><path d="M8 2.2v1.5M8 12.3v1.5M13.8 8h-1.5M3.7 8H2.2M12.1 3.9l-1.05 1.05M4.95 11.05 3.9 12.1M12.1 12.1l-1.05-1.05M4.95 4.95 3.9 3.9"/></svg>
      <span style="font-size: 10px;">設定</span>
    </div>
  </div>
</div>
`;

function DesignSnapshot({ tab }: { tab: Tab }) {
  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'flex-start',
        gap: 10,
        padding: '16px 0',
        overflow: 'auto',
        background: '#0c0e10',
      }}
    >
      <div style={{ fontSize: 11, fontWeight: 600, color: color.textQuaternary }}>
        design canvas · MobileOverview artboard
      </div>
      {tab === 'セッション' ? (
        <>
          <style>{SESSION_ARTBOARD_STYLE}</style>
          <div
            style={{ width: 390, height: 844, borderRadius: 12, overflow: 'hidden', flexShrink: 0 }}
            dangerouslySetInnerHTML={{ __html: SESSION_ARTBOARD_HTML }}
          />
        </>
      ) : (
        <div style={{ width: 390, padding: '0 16px', flexShrink: 0 }}>
          <EmptyState
            title={`${tab} はまだキャンバスにありません`}
            note="デザインキャンバスが定義しているモバイル画面はセッションの1枚だけです。ここを埋めるのはキャンバス側の作業です。"
          />
        </div>
      )}
    </div>
  );
}

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
  const [designMode, setDesignMode] = useState(false);

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
        position: 'relative',
      }}
    >
      {reviewMode ? (
        <button
          onClick={() => setDesignMode((d) => !d)}
          style={{
            position: 'absolute',
            top: 10,
            right: 10,
            zIndex: 10,
            display: 'flex',
            alignItems: 'center',
            gap: 6,
            height: 28,
            padding: '0 10px',
            borderRadius: 14,
            background: 'rgba(0,0,0,0.55)',
            border: '1px dashed rgba(242,244,238,0.5)',
            color: color.textPrimary,
            fontSize: 11,
            fontWeight: 600,
          }}
        >
          {designMode ? 'Design' : 'Live'} 表示中 · 切替
        </button>
      ) : null}

      {designMode ? (
        <div style={{ flex: 1, overflow: 'hidden' }}>
          <DesignSnapshot tab={tab} />
        </div>
      ) : (
        <>
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
        </>
      )}

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
