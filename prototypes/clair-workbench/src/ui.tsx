import type { CSSProperties, ReactNode } from 'react';

import { color, line, mono, wash } from './tokens';
import {
  IconBell,
  IconBranch,
  IconEllipsis,
  IconFolder,
  IconSearch,
  IconSession,
  IconShieldCheck,
} from './icons';
import { useWorkbench, type Screen } from './store';

export function TrafficLights() {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      {[color.close, color.minimize, color.zoom].map((c) => (
        <div key={c} style={{ width: 12, height: 12, borderRadius: '50%', background: c }} />
      ))}
    </div>
  );
}

export function VDivider({ height = 22, margin = 4 }: { height?: number; margin?: number }) {
  return <div style={{ width: 1, height, background: line.hairline, margin: `0 ${margin}px` }} />;
}

export function Act({
  children,
  onClick,
  active,
  width = 30,
  height = 28,
  title,
  underline,
}: {
  children: ReactNode;
  onClick?: () => void;
  active?: boolean;
  width?: number;
  height?: number;
  title?: string;
  underline?: boolean;
}) {
  return (
    <button
      className="act"
      title={title}
      aria-label={title}
      onClick={onClick}
      style={{
        position: 'relative',
        width,
        height,
        background: active ? color.surfaceActive : undefined,
        color: active ? color.textPrimary : undefined,
      }}
    >
      {children}
      {active && underline ? (
        <div
          style={{
            position: 'absolute',
            left: '50%',
            bottom: -1,
            transform: 'translateX(-50%)',
            width: 18,
            height: 2,
            background: color.textSecondary,
          }}
        />
      ) : null}
    </button>
  );
}

export function Chip({
  children,
  style,
  onClick,
}: {
  children: ReactNode;
  style?: CSSProperties;
  onClick?: () => void;
}) {
  const base: CSSProperties = {
    display: 'inline-flex',
    alignItems: 'center',
    gap: 4,
    height: 18,
    padding: '0 6px',
    borderRadius: 3,
    fontSize: 9,
    fontWeight: 600,
    whiteSpace: 'nowrap',
    ...style,
  };
  if (onClick) {
    return (
      <button onClick={onClick} style={{ ...base, cursor: 'pointer' }}>
        {children}
      </button>
    );
  }
  return <span style={base}>{children}</span>;
}

// The 34px activity strip that lives inside the sidebar, per the chrome budget.
const STRIP: Array<{ id: string; screen: Screen; label: string; icon: (p: { size?: number }) => ReactNode }> = [
  { id: 'files', screen: 'workspace', label: 'エクスプローラー', icon: IconFolder },
  { id: 'search', screen: 'workspace', label: '検索', icon: IconSearch },
  { id: 'graph', screen: 'graph', label: 'マージグラフ', icon: IconBranch },
  { id: 'review', screen: 'review', label: '変更を確認', icon: IconShieldCheck },
  { id: 'activity', screen: 'activity', label: 'アクティビティ', icon: IconBell },
];

export function SidebarStrip({
  active,
  compact,
  showSessions,
}: {
  active: string;
  compact?: boolean;
  showSessions?: boolean;
}) {
  const wb = useWorkbench();
  const w = compact ? 36 : 38;
  const h = compact ? 30 : 32;
  return (
    <div
      style={{
        height: 34,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'center',
        gap: compact ? 2 : 3,
        padding: '0 8px',
        borderBottom: `1px solid ${line.chromeSoft}`,
      }}
    >
      <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        {STRIP.map((item) => {
          const Icon = item.icon;
          const isActive = active === item.id;
          return (
            <Act
              key={item.id}
              width={w}
              height={h}
              title={item.label}
              active={isActive}
              underline={item.id !== 'files'}
              onClick={() => {
                if (item.id === 'search') {
                  wb.setScreen('workspace');
                  wb.setOverlay('search');
                } else {
                  wb.setOverlay(null);
                  wb.setScreen(item.screen);
                }
              }}
            >
              <Icon size={16} />
            </Act>
          );
        })}
        {showSessions ? (
          <Act width={w} height={h} title="セッション" onClick={() => wb.setScreen('sessions')}>
            <IconSession size={16} />
          </Act>
        ) : null}
      </div>
      <Act title="その他">
        <IconEllipsis size={13} />
      </Act>
    </div>
  );
}

export function QuotaMeter({ percent = 84, label = '残り16%', tint }: { percent?: number; label?: string; tint?: string }) {
  const fill = tint ?? color.textSecondary;
  return (
    <>
      <span style={{ color: color.textMuted, fontSize: 10 }}>Claude 5時間</span>
      <div style={{ width: 34, height: 4, borderRadius: 2, background: line.strong, overflow: 'hidden' }}>
        <div style={{ width: `${percent}%`, height: '100%', background: fill }} />
      </div>
      <span className="cl" style={{ fontSize: 10, color: fill, fontWeight: 600 }}>
        {label}
      </span>
    </>
  );
}

export function StatusBar({ children }: { children: ReactNode }) {
  return (
    <div
      style={{
        height: 26,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        padding: '0 12px',
        backgroundColor: color.chrome,
        borderTop: `1px solid ${line.chrome}`,
        color: color.textTertiary,
        fontSize: 11,
      }}
    >
      {children}
    </div>
  );
}

export function ScreenShell({ children }: { children: ReactNode }) {
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
        fontSize: 11,
      }}
    >
      {children}
    </div>
  );
}

// The 48px titlebar shared by every screen that is not the workspace: traffic
// lights, the active project pill, then the screen's own content.
export function SimpleTitlebar({ project, children }: { project: string; children?: ReactNode }) {
  return (
    <div
      style={{
        height: 48,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'center',
        gap: 12,
        padding: '0 16px',
        backgroundColor: color.chrome,
        borderBottom: `1px solid ${line.chrome}`,
      }}
    >
      <TrafficLights />
      <VDivider />
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 6,
          height: 26,
          padding: '0 9px',
          borderRadius: 6,
          background: wash.strong,
          border: `1px solid ${line.ring}`,
        }}
      >
        <span style={{ fontSize: 12, fontWeight: 600 }}>{project}</span>
      </div>
      {children}
    </div>
  );
}

export const monoStyle: CSSProperties = { fontFamily: mono };
