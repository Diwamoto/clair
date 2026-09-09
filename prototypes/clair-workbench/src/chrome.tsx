// The application chrome.
//
// The Main artboard's titlebar, sidebar and status bar are the app's chrome,
// not one screen's decoration. They are built once here and stay put; only the
// sidebar panel and the main area change as you navigate. The other artboards
// each drew their own header because an artboard is a single still frame —
// those are treated as internal parts of this shell, not as separate chrome.

import { Fragment, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';

import { files, projectTabs, projects, type FileKind } from './data';
import { color, line, mono } from './tokens';
import {
  IconBell,
  IconBranch,
  IconBug,
  IconChevron,
  IconClaude,
  IconCodex,
  IconCommand,
  IconDoc,
  IconEllipsis,
  IconFolder,
  IconGear,
  IconMarkdown,
  IconSearch,
  IconSession,
  IconShieldCheck,
  IconSparkle,
} from './icons';
import { useWorkbench, type Screen } from './store';

const byPath = new Map(files.map((f) => [f.path, f]));

export function FileIcon({ kind, tint }: { kind: FileKind; tint: string }) {
  if (kind === 'md') return <IconMarkdown size={12} color={tint} />;
  if (kind === 'swift') return <IconClaude size={12} color={tint} />;
  return <IconDoc size={12} color={tint} />;
}

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

/**
 * The 44px header a screen puts at the top of the main area — branch review,
 * the session rail and the merge graph all draw one. It is not chrome: it
 * belongs to the screen, under the shared titlebar.
 */
export function MainHeader({ children, height = 44 }: { children: ReactNode; height?: number }) {
  return (
    <div
      style={{
        height,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        padding: '0 16px',
        backgroundColor: color.chrome,
        borderBottom: `1px solid ${line.chrome}`,
      }}
    >
      {children}
    </div>
  );
}

/* ── titlebar ─────────────────────────────────────────────────────────── */

/**
 * Tabs are a fixed width so the row stays a steady rhythm however long a file
 * name is. A name that does not fit is faded out at its right edge rather than
 * ellipsised: the fade says "there is more" without spending characters on
 * punctuation, and it keeps the label's ink even at the cut.
 *
 * 168px sits inside the 124–210px band the Main artboard specifies.
 */
const TAB_WIDTH = 168;
const TAB_FADE = 18;

const fadeRight: CSSProperties = {
  WebkitMaskImage: `linear-gradient(to right, #000 calc(100% - ${TAB_FADE}px), transparent 100%)`,
  maskImage: `linear-gradient(to right, #000 calc(100% - ${TAB_FADE}px), transparent 100%)`,
};

/** A faint seam between adjacent tabs — just a short rule, never a box around either. */
function TabDivider() {
  return <div style={{ width: 1, height: 18, background: line.chromeSoft, flexShrink: 0 }} />;
}

/** True while the label is wider than the room the tab gives it. */
function useClipped(label: string) {
  const ref = useRef<HTMLSpanElement>(null);
  const [clipped, setClipped] = useState(false);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setClipped(el.scrollWidth > el.clientWidth);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [label]);

  return [ref, clipped] as const;
}

function Tab({
  icon,
  label,
  active,
  dot,
  onClick,
}: {
  icon: ReactNode;
  label: string;
  active: boolean;
  /** The unsaved / running marker the Main artboard draws after the label. */
  dot?: boolean;
  onClick: () => void;
}) {
  const tint = active ? color.textPrimary : color.textTertiary;
  const [labelRef, clipped] = useClipped(label);
  return (
    <button
      onClick={onClick}
      title={label}
      style={{
        position: 'relative',
        display: 'flex',
        alignItems: 'center',
        gap: 7,
        padding: '0 11px',
        width: TAB_WIDTH,
        flexShrink: 0,
        borderRadius: 7,
        background: 'transparent',
        height: '100%',
        alignSelf: 'stretch',
        overflow: 'hidden',
      }}
    >
      {icon}
      <span
        ref={labelRef}
        style={{
          fontSize: 11,
          fontWeight: active ? 600 : 400,
          color: tint,
          whiteSpace: 'nowrap',
          overflow: 'hidden',
          flex: 1,
          textAlign: 'left',
          // Only a name that actually runs past the tab is faded; one that
          // fits keeps its last letters at full ink.
          ...(clipped ? fadeRight : null),
        }}
      >
        {label}
      </span>
      {dot ? (
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

function FileTab({ path, active }: { path: string; active: boolean }) {
  const wb = useWorkbench();
  const tab = wb.tabs.find((t) => t.path === path);
  const file = byPath.get(path);
  const tint = active ? color.textPrimary : color.textTertiary;
  return (
    <Tab
      icon={file ? <FileIcon kind={file.kind} tint={tint} /> : <IconSparkle size={12} color={tint} />}
      label={file?.name ?? path}
      active={active}
      dot={tab?.dirty}
      onClick={() => {
        wb.setActivePath(path);
        wb.openFile(path);
      }}
    />
  );
}

/**
 * A titlebar tab group's own label, Chrome's tab-group pill: the whole chip
 * toggles that project's tabs open or shut, independent of which project is
 * active. Collapsing does not touch `activeProject` — folding away the group
 * you're working in just hides its tab strip, the way collapsing the active
 * group in Chrome leaves the page alone.
 */
function ProjectChip({
  project,
  active,
  collapsed,
  onToggle,
}: {
  project: string;
  active: boolean;
  collapsed: boolean;
  onToggle: () => void;
}) {
  return (
    <button
      onClick={onToggle}
      title={`${project} タブグループを${collapsed ? '展開' : '折りたたむ'}`}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 4,
        height: 26,
        padding: '0 7px 0 10px',
        borderRadius: 8,
        background: active ? 'rgba(255,255,255,0.08)' : 'transparent',
        border: `1px solid ${active ? 'rgba(255,255,255,0.12)' : 'transparent'}`,
        alignSelf: 'center',
        flexShrink: 0,
      }}
    >
      <span
        style={{
          fontSize: 12,
          fontWeight: 600,
          color: active ? color.textPrimary : color.textQuaternary,
          whiteSpace: 'nowrap',
        }}
      >
        {project}
      </span>
      <span
        className="tab-group-chevron"
        style={{ display: 'inline-flex', transform: collapsed ? 'rotate(0deg)' : 'rotate(90deg)' }}
      >
        <IconChevron size={10} color={active ? color.textSecondary : color.textQuaternary} />
      </span>
    </button>
  );
}

/**
 * One project's row of tabs, collapsing toward its own chip rather than
 * disappearing outright: the `1fr → 0fr` grid track keeps the chip as the
 * fixed left edge, so the tabs shrink into it instead of the row jumping.
 * Only `clair` has real editor state behind its tabs (`wb.tabs`); the other
 * groups render `projectTabs`, a couple of stand-in labels drawn from what
 * the mock already says about those projects elsewhere, so every group has
 * something to show when expanded per the "make every project's tabs
 * visible" request — not real openable files.
 */
function ProjectGroup({ project }: { project: string }) {
  const wb = useWorkbench();
  const active = project === wb.activeProject;
  const collapsed = wb.collapsedProjects.has(project);

  // The real editor tabs (wb.tabs) and the Claude Code / codex tabs are
  // `clair`'s specifically — the workspace behind them never changes with
  // `activeProject` — so they stay put in `clair`'s row regardless of which
  // chip is currently highlighted; every other project renders its
  // `projectTabs` stand-ins instead.
  const items: ReactNode[] =
    !(project in projectTabs)
      ? [
          ...wb.tabs.map((t) => (
            <FileTab key={t.path} path={t.path} active={t.path === wb.activePath && wb.screen === 'workspace'} />
          )),
          <Tab
            key="activity"
            icon={<IconSparkle size={12} color={wb.screen === 'activity' ? color.textPrimary : color.textTertiary} />}
            label="Claude Code"
            active={wb.screen === 'activity'}
            dot
            onClick={() => wb.setScreen('activity')}
          />,
          <Tab
            key="sessions"
            icon={<IconCodex size={12} color={wb.screen === 'sessions' ? color.textPrimary : color.textTertiary} />}
            label="codex"
            active={wb.screen === 'sessions'}
            onClick={() => wb.setScreen('sessions')}
          />,
        ]
      : (projectTabs[project] ?? []).map((f) => (
          <Tab
            key={f.path}
            icon={<FileIcon kind={f.kind} tint={color.textTertiary} />}
            label={f.name}
            active={false}
            onClick={() => wb.setActiveProject(project)}
          />
        ));

  return (
    <div style={{ display: 'flex', alignItems: 'center', alignSelf: 'stretch', flexShrink: 0, minWidth: 0 }}>
      <ProjectChip project={project} active={active} collapsed={collapsed} onToggle={() => wb.toggleProjectCollapsed(project)} />
      <div
        className="tab-group-track"
        style={{
          display: 'grid',
          gridTemplateColumns: collapsed ? '0fr' : '1fr',
          alignSelf: 'stretch',
          minWidth: 0,
        }}
      >
        <div style={{ overflow: 'hidden', minWidth: 0, display: 'flex', alignItems: 'center', height: '100%', gap: 3, paddingLeft: 4 }}>
          {items.map((tab, i) => (
            <Fragment key={i}>
              {i > 0 ? <TabDivider /> : null}
              {tab}
            </Fragment>
          ))}
        </div>
      </div>
    </div>
  );
}

/**
 * The one titlebar, from the Main artboard: traffic lights, every project's
 * tab group — Chrome-style, each collapsible toward its own chip — then
 * file/symbol search and the two window actions. `extra` is where a screen
 * adds its own status badge (the debugger's stop badge, for instance)
 * without growing a second row.
 */
export function AppTitlebar({ extra }: { extra?: ReactNode }) {
  const wb = useWorkbench();
  return (
    <div
      style={{
        height: 48,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'flex-end',
        backgroundColor: color.chrome,
        borderBottom: `1px solid ${line.hairline}`,
      }}
    >
      <div style={{ width: 76, flexShrink: 0, display: 'flex', alignItems: 'center', gap: 8, padding: '0 0 18px 20px' }}>
        <TrafficLights />
      </div>

      <div
        className="no-scrollbar"
        style={{ flex: 1, height: 48, display: 'flex', alignItems: 'center', gap: 5, minWidth: 0, overflow: 'hidden' }}
      >
        {projects.map((p, i) => (
          <Fragment key={p}>
            {i > 0 ? <div style={{ width: 1, height: 22, background: 'rgba(242,244,238,0.09)', margin: '0 5px', flexShrink: 0 }} /> : null}
            <ProjectGroup project={p} />
          </Fragment>
        ))}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '0 12px 9px 12px', flexShrink: 0 }}>
        {extra}
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
        <button
          className="act"
          title="設定"
          onClick={() => wb.setScreen(wb.screen === 'settings' ? 'workspace' : 'settings')}
          style={wb.screen === 'settings' ? { background: color.surfaceActive, color: color.textPrimary } : undefined}
        >
          <IconGear size={15} />
        </button>
      </div>
    </div>
  );
}

/* ── sidebar ──────────────────────────────────────────────────────────── */

/**
 * The activity strip inside the sidebar rather than in a column of its own —
 * the chrome budget on the Tokens artboard is what pays for that.
 *
 * Search is deliberately absent: file and symbol search is the titlebar field,
 * so having it here too would give one job two entry points.
 */
const NAV: Array<{ id: string; screen: Screen; label: string; icon: (p: { size?: number }) => ReactNode }> = [
  { id: 'files', screen: 'workspace', label: 'エクスプローラー', icon: IconFolder },
  { id: 'graph', screen: 'graph', label: 'マージグラフ', icon: IconBranch },
  { id: 'review', screen: 'review', label: '変更を確認', icon: IconShieldCheck },
  { id: 'debug', screen: 'debug', label: '実行とデバッグ', icon: IconBug },
  { id: 'activity', screen: 'activity', label: 'アクティビティ', icon: IconBell },
];

/** Which strip entry the current screen lights up, and which panel it shows. */
export function navIdFor(screen: Screen): string {
  if (screen === 'debug' || screen === 'debugAgent') return 'debug';
  if (screen === 'graph') return 'graph';
  if (screen === 'review') return 'review';
  if (screen === 'activity') return 'activity';
  if (screen === 'settings') return 'settings';
  return 'files';
}

function SidebarStrip() {
  const wb = useWorkbench();
  const active = navIdFor(wb.screen);

  return (
    <div
      style={{
        height: 34,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'center',
        gap: 3,
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
              width={38}
              height={32}
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
        <Act
          width={38}
          height={32}
          title="セッション"
          active={wb.screen === 'sessions'}
          underline
          onClick={() => wb.setScreen('sessions')}
        >
          <IconSession size={16} />
        </Act>
      </div>
      <Act title="その他">
        <IconEllipsis size={13} />
      </Act>
    </div>
  );
}

/* ── status bar ───────────────────────────────────────────────────────── */

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

/**
 * The one status bar. Branch and working-tree state on the left, then the
 * screen's own context, then the tightest agent's quota — which the Settings
 * artboard makes a preference — and the session count.
 */
function AppStatusBar({ context, trailing }: { context?: ReactNode; trailing?: ReactNode }) {
  const wb = useWorkbench();
  const onBranch = wb.screen === 'review';

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
      <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
        <IconBranch size={12} />
        <span>{onBranch ? 'pane-split' : 'main'}</span>
      </div>
      <span className="cl" style={{ color: color.textMuted }}>
        {onBranch ? 'worktree' : '↓0 ↑2'}
      </span>
      <span>{6 + wb.dirtyCount} 変更</span>
      {context ? <span style={{ color: color.divider }}>·</span> : null}
      {context}
      <div style={{ flex: 1 }} />
      {wb.toggles.showQuota ? <QuotaMeter /> : null}
      <span style={{ color: color.divider }}>·</span>
      <span>{wb.sessions.length} セッション</span>
      {trailing ? <span style={{ color: color.divider }}>·</span> : null}
      {trailing}
    </div>
  );
}

/* ── shell ────────────────────────────────────────────────────────────── */

/**
 * Header, sidebar and footer are mounted once and never unmount; only the
 * sidebar panel and the main area swap as you navigate.
 */
export function AppShell({
  panel,
  main,
  titlebarExtra,
  statusContext,
  statusTrailing,
  sidebarWidth = 286,
}: {
  panel: ReactNode;
  main: ReactNode;
  titlebarExtra?: ReactNode;
  statusContext?: ReactNode;
  statusTrailing?: ReactNode;
  sidebarWidth?: number;
}) {
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
      <AppTitlebar extra={titlebarExtra} />
      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        <div
          style={{
            width: sidebarWidth,
            flexShrink: 0,
            display: 'flex',
            flexDirection: 'column',
            backgroundColor: color.chrome,
            borderRight: `1px solid ${line.chrome}`,
            minHeight: 0,
          }}
        >
          <SidebarStrip />
          <div style={{ flex: 1, minHeight: 0, position: 'relative' }}>{panel}</div>
        </div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, position: 'relative' }}>
          {main}
        </div>
      </div>
      <AppStatusBar context={statusContext} trailing={statusTrailing} />
    </div>
  );
}

export const monoStyle: CSSProperties = { fontFamily: mono };
