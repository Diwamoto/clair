// Shared chrome. Every screen composes the same header, sidebar and footer
// from here instead of redrawing them, so the 48 / 34 / 26px chrome budget is
// held in one place. The values are still the canvas's own — this file is
// where they live, not a reinterpretation of them.

import type { CSSProperties, ReactNode } from 'react';

import { color, line, mono, wash } from './tokens';
import {
  IconBell,
  IconBranch,
  IconBug,
  IconEllipsis,
  IconFolder,
  IconSession,
  IconShieldCheck,
} from './icons';
import { useWorkbench, type Screen } from './store';

/* ── atoms ────────────────────────────────────────────────────────────── */

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

/** The project pill the titlebar carries on every non-workspace screen. */
export function ProjectPill({ name, onClick }: { name: string; onClick?: () => void }) {
  const style: CSSProperties = {
    display: 'flex',
    alignItems: 'center',
    gap: 6,
    height: 26,
    padding: '0 9px',
    borderRadius: 6,
    background: wash.strong,
    border: `1px solid ${line.ring}`,
  };
  const label = <span style={{ fontSize: 12, fontWeight: 600 }}>{name}</span>;
  return onClick ? (
    <button onClick={onClick} style={style}>
      {label}
    </button>
  ) : (
    <div style={style}>{label}</div>
  );
}

/* ── header ───────────────────────────────────────────────────────────── */

/**
 * The 48px titlebar. `variant="workspace"` is the parallel-tab row the Main
 * artboard draws; the default is the centred row every other screen uses.
 * A screen passes its own right-hand content as children.
 */
export function Titlebar({
  variant = 'plain',
  project,
  onProjectClick,
  title,
  children,
  align = 'center',
}: {
  variant?: 'plain' | 'workspace';
  project?: string;
  onProjectClick?: () => void;
  title?: string;
  children?: ReactNode;
  align?: 'center' | 'end';
}) {
  return (
    <div
      style={{
        height: 48,
        flexShrink: 0,
        display: 'flex',
        alignItems: align === 'end' ? 'flex-end' : 'center',
        gap: variant === 'workspace' ? 0 : 12,
        padding: variant === 'workspace' ? 0 : '0 16px',
        backgroundColor: color.chrome,
        borderBottom: `1px solid ${variant === 'workspace' ? line.hairline : line.chrome}`,
      }}
    >
      {variant === 'workspace' ? (
        <div
          style={{
            width: 76,
            flexShrink: 0,
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            padding: '0 0 18px 20px',
          }}
        >
          <TrafficLights />
        </div>
      ) : (
        <>
          <TrafficLights />
          <VDivider />
          {project ? <ProjectPill name={project} onClick={onProjectClick} /> : null}
          {title ? <span style={{ fontSize: 13, fontWeight: 600 }}>{title}</span> : null}
        </>
      )}
      {children}
    </div>
  );
}

/* ── sidebar ──────────────────────────────────────────────────────────── */

/**
 * The activity strip that lives inside the sidebar rather than in a column of
 * its own — the chrome budget on the Tokens artboard is what pays for this.
 *
 * Search is deliberately absent: file and symbol search is the titlebar
 * field, so having it here too would give one job two entry points.
 */
const NAV: Array<{ id: string; screen: Screen; label: string; icon: (p: { size?: number }) => ReactNode }> = [
  { id: 'files', screen: 'workspace', label: 'エクスプローラー', icon: IconFolder },
  { id: 'graph', screen: 'graph', label: 'マージグラフ', icon: IconBranch },
  { id: 'review', screen: 'review', label: '変更を確認', icon: IconShieldCheck },
  { id: 'debug', screen: 'debug', label: '実行とデバッグ', icon: IconBug },
  { id: 'activity', screen: 'activity', label: 'アクティビティ', icon: IconBell },
];

/** Which strip entry the current screen lights up. */
export function navIdFor(screen: Screen): string {
  if (screen === 'debug' || screen === 'debugAgent') return 'debug';
  if (screen === 'graph') return 'graph';
  if (screen === 'review') return 'review';
  if (screen === 'activity') return 'activity';
  return 'files';
}

export function SidebarStrip({ compact, showSessions }: { compact?: boolean; showSessions?: boolean }) {
  const wb = useWorkbench();
  const active = navIdFor(wb.screen);
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
        {NAV.map((item) => {
          const Icon = item.icon;
          return (
            <Act
              key={item.id}
              width={w}
              height={h}
              title={item.label}
              active={active === item.id}
              underline={item.id !== 'files'}
              onClick={() => {
                wb.setOverlay(null);
                wb.setScreen(item.screen);
              }}
            >
              <Icon size={16} />
            </Act>
          );
        })}
        {showSessions ? (
          <Act
            width={w}
            height={h}
            title="セッション"
            active={wb.screen === 'sessions'}
            underline
            onClick={() => wb.setScreen('sessions')}
          >
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

/** The 286px (or wider) sidebar column: the strip plus whatever the screen puts under it. */
export function Sidebar({
  width = 286,
  compact,
  showSessions,
  children,
}: {
  width?: number;
  compact?: boolean;
  showSessions?: boolean;
  children: ReactNode;
}) {
  return (
    <div
      style={{
        width,
        flexShrink: 0,
        display: 'flex',
        flexDirection: 'column',
        backgroundColor: color.chrome,
        borderRight: `1px solid ${line.chrome}`,
      }}
    >
      <SidebarStrip compact={compact} showSessions={showSessions} />
      {children}
    </div>
  );
}

/* ── footer ───────────────────────────────────────────────────────────── */

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

/* ── shell ────────────────────────────────────────────────────────────── */

/** Every screen is a column: header, body, footer. */
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

/** The area between header and footer. */
export function ScreenBody({ children }: { children: ReactNode }) {
  return <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>{children}</div>;
}

export const monoStyle: CSSProperties = { fontFamily: mono };
