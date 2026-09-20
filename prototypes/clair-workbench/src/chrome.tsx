// The application chrome.
//
// The Main artboard's titlebar, sidebar and status bar are the app's chrome,
// not one screen's decoration. They are built once here and stay put; only the
// sidebar panel and the main area change as you navigate. The other artboards
// each drew their own header because an artboard is a single still frame —
// those are treated as internal parts of this shell, not as separate chrome.

import { Fragment, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';

import { targetRing, useContextMenu } from './contextMenu';
import { files, projectTabs, type FileKind } from './data';
import { fileMenu, projectMenu, sessionTabMenu, standInTabMenu } from './menus';
import { color, fs, groupColor, line, mono, radius, space, wash, withAlpha, type GroupColorKey } from './tokens';
import {
  IconBranch,
  IconBug,
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
    <div style={{ display: 'flex', alignItems: 'center', gap: space[2] }}>
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
}: {
  children: ReactNode;
  onClick?: () => void;
  active?: boolean;
  width?: number;
  height?: number;
  title?: string;
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
        // Same white-wash "selected" as the tabs now use, not surfaceActive.
        background: active ? wash.selected : undefined,
        color: active ? color.chromeInk : undefined,
      }}
    >
      {children}
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
    gap: space[1],
    height: 18,
    padding: '0 4px',
    borderRadius: radius.control,
    fontSize: fs.caption,
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
        gap: space[2],
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
 * Tabs are a fixed width, left to right, and never stretch. Width is what
 * makes a tab strip calm, so 200px is generous — the titlebar's own controls
 * were cut back to pay for it — but it is the same 200px however many tabs
 * are open and however wide the window is. A tab that moved or resized every
 * time a sibling opened would cost more than the tidy right edge is worth.
 *
 * A name that does not fit ends in an ellipsis; the full name is the tab's title.
 */
const TAB_WIDTH = 200;

/** A faint seam between adjacent tabs — just a short rule, never a box around either. */
function TabDivider() {
  return <div style={{ width: 1, height: 18, background: line.chromeSoft, flexShrink: 0 }} />;
}

function Tab({
  icon,
  label,
  active,
  dot,
  onClick,
  onContextMenu,
  targeted,
}: {
  icon: ReactNode;
  label: string;
  active: boolean;
  /** The unsaved / running marker the Main artboard draws after the label. */
  dot?: boolean;
  onClick: () => void;
  onContextMenu?: (event: React.MouseEvent) => void;
  /** Its context menu is open. */
  targeted?: boolean;
}) {
  const tint = active ? color.chromeInk : color.textTertiary;
  return (
    <button
      className={active ? undefined : 'tab-btn'}
      onClick={onClick}
      onContextMenu={onContextMenu}
      title={label}
      style={{
        boxShadow: targeted ? targetRing : undefined,
        position: 'relative',
        display: 'flex',
        alignItems: 'center',
        gap: space[1],
        padding: '0 8px',
        width: TAB_WIDTH,
        flexShrink: 0,
        borderRadius: radius.card,
        // Selected is a white wash over chrome — the same idiom Activity's
        // and Overlays' own "selected" rows already use — so it reads
        // brighter than plain surfaceActive. Unselected must omit
        // `background` entirely (not 'transparent'): an inline value of any
        // kind outranks the .hoverable:hover rule and silently kills hover.
        background: active ? wash.selected : undefined,
        height: 38,
        alignSelf: 'center',
        overflow: 'hidden',
      }}
    >
      {icon}
      <span
        style={{
          fontSize: fs.caption,
          fontWeight: active ? 600 : 400,
          color: tint,
          whiteSpace: 'nowrap',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          minWidth: 0,
          flex: 1,
          textAlign: 'left',
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
        <span
          role="button"
          aria-label={`${label} を閉じる`}
          title="閉じる"
          onClick={(e) => e.stopPropagation()}
          style={{ display: 'flex', alignItems: 'center', color: color.textTertiary, flexShrink: 0 }}
        >
          <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={1.4} strokeLinecap="round">
            <path d="M4 4l8 8M12 4l-8 8" />
          </svg>
        </span>
      ) : null}
    </button>
  );
}

function FileTab({ path, active }: { path: string; active: boolean }) {
  const wb = useWorkbench();
  const menu = useContextMenu();
  const tab = wb.tabs.find((t) => t.path === path);
  const file = byPath.get(path);
  const tint = active ? color.chromeInk : color.textTertiary;
  const target = `tab:${path}`;
  return (
    <Tab
      icon={file ? <FileIcon kind={file.kind} tint={tint} /> : <IconSparkle size={12} color={tint} />}
      label={file?.name ?? path}
      active={active}
      dot={tab?.dirty}
      targeted={wb.contextMenu?.target === target}
      onClick={() => {
        wb.setActivePath(path);
        wb.openFile(path);
      }}
      onContextMenu={(event) => menu(event, (w) => fileMenu(w, path, 'tab'), target)}
    />
  );
}

/**
 * A titlebar tab group's own label, Chrome's tab-group pill: click toggles
 * that project's tabs open or shut, independent of which project is active.
 * Collapsing does not touch `activeProject` — folding away the group you're
 * working in just hides its tab strip, the way collapsing the active group in
 * Chrome leaves the page alone.
 *
 * The group's colour is a 6px dot before the name — no pill, no underline.
 * Right-click opens the chip's context menu, whose
 * first row is the colour swatches — how Chrome puts a tab group's colour
 * picker behind a right-click on the group's own chip rather than a second
 * control next to it.
 */
function ProjectChip({
  project,
  label,
  collapsed,
  colorKey,
  renaming,
  targeted,
  onToggle,
  onMenu,
  onRename,
  onCancelRename,
}: {
  project: string;
  label: string;
  collapsed: boolean;
  colorKey: GroupColorKey;
  renaming: boolean;
  targeted: boolean;
  onToggle: () => void;
  onMenu: (event: React.MouseEvent) => void;
  onRename: (name: string) => void;
  onCancelRename: () => void;
}) {
  const swatch = groupColor[colorKey];

  // Name-field frame only — the chip itself is a dot and a name, no pill.
  const frame: CSSProperties = {
    display: 'flex',
    alignItems: 'center',
    height: 26,
    padding: '0 8px',
    borderRadius: radius.card,
    background: color.chrome,
    border: `1px solid ${line.ring}`,
    alignSelf: 'center',
    flexShrink: 0,
  };
  const text: CSSProperties = {
    fontSize: fs.secondary,
    fontWeight: 600,
    color: color.textSecondary,
    whiteSpace: 'nowrap',
  };

  if (renaming) {
    return <ChipNameField label={label} frame={frame} text={text} onCommit={onRename} onCancel={onCancelRename} />;
  }

  return (
    <button
      onClick={onToggle}
      onContextMenu={onMenu}
      title={`${project} タブグループを${collapsed ? '展開' : '折りたたむ'}（右クリックでメニュー）`}
      style={{
        display: 'flex',
        alignItems: 'center',
        height: 26,
        padding: '0 10px',
        alignSelf: 'center',
        flexShrink: 0,
        borderRadius: radius.card,
        // The chip carries the group's colour as its own fill now, not a
        // dot beside the name — `withAlpha` is the same helper the tab
        // group's own doc describes for this (14-22% fill / 28-55% border;
        // `gray` already carries its own alpha, so it passes through as-is).
        background: withAlpha(swatch, 0.16),
        border: `1px solid ${withAlpha(swatch, 0.4)}`,
        boxShadow: targeted ? `0 0 0 2px ${color.chrome}, 0 0 0 3px ${line.ring}` : undefined,
      }}
    >
      <span style={text}>{label}</span>
    </button>
  );
}

/**
 * Renaming happens in place: the chip becomes its own name field, painted
 * as a focused field (the palette input's ring) in the chip's shape.
 * ↵ or clicking away keeps the name, esc puts the old one back.
 */
function ChipNameField({
  label,
  frame,
  text,
  onCommit,
  onCancel,
}: {
  label: string;
  frame: CSSProperties;
  text: CSSProperties;
  onCommit: (name: string) => void;
  onCancel: () => void;
}) {
  const [value, setValue] = useState(label);
  const cancelled = useRef(false);
  return (
    <input
      autoFocus
      aria-label="Project名"
      value={value}
      onFocus={(event) => event.currentTarget.select()}
      onChange={(event) => setValue(event.target.value)}
      onKeyDown={(event) => {
        // The field owns every key while it is open — esc must not also
        // send the window back to the workspace.
        event.stopPropagation();
        if (event.key === 'Enter') onCommit(value);
        if (event.key === 'Escape') {
          cancelled.current = true;
          onCancel();
        }
      }}
      onBlur={() => {
        if (!cancelled.current) onCommit(value);
      }}
      style={{
        ...frame,
        ...text,
        width: `calc(${Math.max(4, value.length)}ch + 22px)`,
        background: color.chrome,
        border: `1px solid ${line.ring}`,
        color: color.textPrimary,
        outline: 'none',
      }}
    />
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
 *
 * The group is told apart by its colour dot alone; only the active tab
 * carries an underline.
 */
function ProjectGroup({ project }: { project: string }) {
  const wb = useWorkbench();
  const menu = useContextMenu();
  const targeted = (id: string) => wb.contextMenu?.target === id;
  const collapsed = wb.collapsedProjects.has(project);
  const colorKey = wb.groupColors[project] ?? 'gray';

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
            icon={<IconSparkle size={12} color={wb.screen === 'activity' ? color.chromeInk : color.textTertiary} />}
            label="Claude Code"
            active={wb.screen === 'activity'}
            dot
            targeted={targeted('tab:activity')}
            onClick={() => wb.setScreen('activity')}
            onContextMenu={(event) => menu(event, (w) => sessionTabMenu(w, 'Claude Code', 'activity'), 'tab:activity')}
          />,
          <Tab
            key="sessions"
            icon={<IconCodex size={12} color={wb.screen === 'sessions' ? color.chromeInk : color.textTertiary} />}
            label="codex"
            active={wb.screen === 'sessions'}
            targeted={targeted('tab:sessions')}
            onClick={() => wb.setScreen('sessions')}
            onContextMenu={(event) => menu(event, (w) => sessionTabMenu(w, 'codex', 'sessions'), 'tab:sessions')}
          />,
        ]
      : (projectTabs[project] ?? []).map((f) => (
          <Tab
            key={f.path}
            icon={<FileIcon kind={f.kind} tint={color.textTertiary} />}
            label={f.name}
            active={false}
            targeted={targeted(`tab:${project}:${f.path}`)}
            onClick={() => wb.setActiveProject(project)}
            onContextMenu={(event) =>
              menu(event, (w) => standInTabMenu(w, project, f), `tab:${project}:${f.path}`)
            }
          />
        ));

  return (
    <div
      style={{
        position: 'relative',
        display: 'flex',
        alignItems: 'center',
        alignSelf: 'stretch',
        flexShrink: 0,
        minWidth: 0,
      }}
    >
      <ProjectChip
        project={project}
        label={wb.projectLabels[project] ?? project}
        collapsed={collapsed}
        colorKey={colorKey}
        renaming={wb.renamingProject === project}
        targeted={targeted(`chip:${project}`)}
        onToggle={() => wb.toggleProjectCollapsed(project)}
        onMenu={(event) => menu(event, (w) => projectMenu(w, project), `chip:${project}`)}
        onRename={(name) => wb.renameProject(project, name)}
        onCancelRename={() => wb.setRenamingProject(null)}
      />
      <div
        className="tab-group-track"
        style={{
          display: 'grid',
          gridTemplateColumns: collapsed ? '0fr' : '1fr',
          alignSelf: 'stretch',
          minWidth: 0,
        }}
      >
        <div style={{ overflow: 'hidden', minWidth: 0, display: 'flex', alignItems: 'center', height: '100%', gap: space[0], paddingLeft: 4 }}>
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
        // Tabs are centred in the bar now that the selected one is a filled
        // shape rather than an underline hanging off the bottom edge.
        alignItems: 'center',
        backgroundColor: color.chrome,
        borderBottom: `1px solid ${line.hairline}`,
      }}
    >
      <div style={{ width: 76, flexShrink: 0, display: 'flex', alignItems: 'center', gap: space[2], padding: '0 0 0 20px' }}>
        <TrafficLights />
      </div>

      <div
        className="no-scrollbar"
        // Fixed-width tabs overflow rather than shrink, so the strip has to
        // scroll — otherwise a narrow window puts the last tabs out of reach.
        // The scrollbar itself stays hidden; this is chrome, not content.
        style={{ flex: 1, height: 48, display: 'flex', alignItems: 'center', gap: space[1], minWidth: 0, overflowX: 'auto', overflowY: 'hidden' }}
      >
        {wb.projectOrder.map((p, i) => (
          <Fragment key={p}>
            {i > 0 ? <div style={{ width: 1, height: 22, background: 'rgba(241,242,246,0.09)', margin: '0 4px', flexShrink: 0 }} /> : null}
            <ProjectGroup project={p} />
          </Fragment>
        ))}
        {/* New tab sits at the end of the strip, where every tabbed app puts
            it — not among the window actions on the right. */}
        <Act title="新しいタブ" width={30} height={30}>
          <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={1.4} strokeLinecap="round">
            <path d="M8 3.5v9M3.5 8h9" />
          </svg>
        </Act>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: space[1], padding: '0 12px', flexShrink: 0 }}>
        {extra}
        {/* The field itself, back in the tab bar. A magnifier on its own said
            "there is a search somewhere"; the field says what it searches and
            gives the shortcut, and the fixed-width tabs mean the 200px it
            takes costs nothing else on the row. It is the chrome's own colour
            over a hairline, like every other field: one surface, one outline. */}
        <button
          onClick={() => wb.setOverlay('search')}
          title="検索"
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: space[1],
            width: 200,
            height: 28,
            padding: '0 8px',
            borderRadius: radius.card,
            background: color.chrome,
            border: `1px solid ${line.hairline}`,
          }}
        >
          <IconSearch size={12} color={color.textQuaternary} />
          <span style={{ fontSize: fs.caption, color: color.textTertiary, flex: 1, textAlign: 'left' }}>
            ファイル、シンボル
          </span>
          <span className="tnum" style={{ fontSize: fs.caption, color: color.textQuaternary }}>
            ⌘⇧F
          </span>
        </button>
        <button className="act" title="コマンドパレット" onClick={() => wb.setOverlay('command')}>
          <IconCommand size={15} />
        </button>
        <button
          className="act"
          title="設定"
          onClick={() => wb.setScreen(wb.screen === 'settings' ? 'workspace' : 'settings')}
          style={wb.screen === 'settings' ? { background: color.surfaceActive, color: color.chromeInk } : undefined}
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
// `graph` has no nav entry of its own: the merge graph is one view inside
// the source-control tool (see SourceControlModeTabs below), not a separate
// destination — a git GUI doesn't give its commit graph its own top-level
// tab distinct from the rest of the tool. The shield icon opens the tool at
// its `review` (changes) default; `⌃⌘G` does the same.
const NAV: Array<{ id: string; screen: Screen; label: string; icon: (p: { size?: number }) => ReactNode }> = [
  { id: 'files', screen: 'workspace', label: 'File Tree', icon: IconFolder },
  { id: 'review', screen: 'review', label: 'Source Control', icon: IconBranch },
  { id: 'agents', screen: 'sessions', label: 'Agents', icon: IconSession },
  { id: 'debug', screen: 'debug', label: 'Debug', icon: IconBug },
];

/** Which strip entry the current screen lights up, and which panel it shows. */
export function navIdFor(screen: Screen): string {
  if (screen === 'debug' || screen === 'debugAgent') return 'debug';
  if (screen === 'graph' || screen === 'review') return 'review';
  // The agent conversation opens from its own titlebar tab; while it is up,
  // Agents is the entry that owns it.
  if (screen === 'sessions' || screen === 'activity') return 'agents';
  if (screen === 'settings') return 'settings';
  return 'files';
}

/**
 * The changes/graph switch inside the source-control tool's own header —
 * treats the merge graph as a second mode of one tool (git GUI clients do
 * the same) rather than a separate screen with its own nav entry.
 */
export function SourceControlModeTabs() {
  const wb = useWorkbench();
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'stretch',
        height: 24,
        flexShrink: 0,
        borderRadius: radius.control,
        border: `1px solid ${line.hairline}`,
        overflow: 'hidden',
      }}
    >
      {([
        { id: 'review', label: '変更' },
        { id: 'graph', label: 'グラフ' },
      ] as const).map((m) => {
        const on = wb.screen === m.id;
        return (
          <button
            key={m.id}
            onClick={() => wb.setScreen(m.id)}
            style={{
              display: 'flex',
              alignItems: 'center',
              padding: '0 12px',
              background: on ? color.surfaceActive : undefined,
              color: on ? color.textPrimary : color.textSecondary,
              fontSize: fs.caption,
              fontWeight: on ? 600 : 400,
            }}
          >
            {m.label}
          </button>
        );
      })}
    </div>
  );
}

// A separate vertical rail, not a strip folded into the sidebar's top edge —
// VSCode/JetBrains/Zed/Cursor all keep navigation identity off to the side
// in its own column, so it never competes with the panel's own content for
// width the way the old 34px horizontal strip did. Icons grew 16->18px now
// that there's headroom for them; 44px matches the touch/device sizing the
// Mobile artboards already use elsewhere in Tokens.
const ACTIVITY_BAR_WIDTH = 44;
const NAV_ITEM_HEIGHT = 40;
const NAV_GAP = space[1];

function ActivityBar() {
  const wb = useWorkbench();
  const active = navIdFor(wb.screen);
  const containerRef = useRef<HTMLDivElement>(null);
  const [visibleCount, setVisibleCount] = useState(NAV.length);
  const [overflowOpen, setOverflowOpen] = useState(false);

  // "…" only exists to hold what doesn't fit. A vertical rail has far more
  // room than the old horizontal strip did, so in practice this rarely
  // renders — but the rail can still fill up as more tools are added later.
  useLayoutEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const fullHeight = (n: number) => n * NAV_ITEM_HEIGHT + Math.max(0, n - 1) * NAV_GAP;
    const compute = () => {
      const available = el.clientHeight;
      if (fullHeight(NAV.length) <= available) {
        setVisibleCount(NAV.length);
        return;
      }
      let count = NAV.length - 1;
      while (count > 0 && fullHeight(count) + NAV_GAP + NAV_ITEM_HEIGHT > available) count -= 1;
      setVisibleCount(count);
    };
    compute();
    const observer = new ResizeObserver(compute);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  const visible = NAV.slice(0, visibleCount);
  const overflow = NAV.slice(visibleCount);
  if (overflow.length === 0 && overflowOpen) setOverflowOpen(false);

  useEffect(() => {
    if (!overflowOpen) return;
    const close = () => setOverflowOpen(false);
    window.addEventListener('mousedown', close);
    return () => window.removeEventListener('mousedown', close);
  }, [overflowOpen]);

  return (
    <div
      style={{
        width: ACTIVITY_BAR_WIDTH,
        flexShrink: 0,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: space[1],
        padding: '8px 0',
        backgroundColor: color.chrome,
        borderRight: `1px solid ${line.chrome}`,
      }}
    >
      <div ref={containerRef} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: space[1], minHeight: 0, overflow: 'hidden' }}>
        {visible.map((item) => {
          const Icon = item.icon;
          return (
            <Act
              key={item.id}
              width={32}
              height={NAV_ITEM_HEIGHT}
              title={item.label}
              active={active === item.id}
              onClick={() => {
                wb.setOverlay(null);
                wb.setScreen(item.screen);
              }}
            >
              <Icon size={18} />
            </Act>
          );
        })}
      </div>
      {overflow.length > 0 ? (
        <div style={{ position: 'relative', flexShrink: 0 }}>
          <Act title="その他のナビゲーション" active={overflowOpen || overflow.some((i) => active === i.id)} onClick={() => setOverflowOpen((v) => !v)}>
            <IconEllipsis size={13} />
          </Act>
          {overflowOpen ? (
            <div
              className="ctx-menu"
              style={{
                position: 'absolute',
                bottom: 0,
                left: 36,
                minWidth: 160,
                padding: 4,
                borderRadius: radius.overlay,
                background: color.chromeRaised,
                border: `1px solid ${line.strong}`,
                boxShadow: '0 8px 24px rgba(0,0,0,0.35)',
                zIndex: 10,
              }}
            >
              {overflow.map((item) => {
                const Icon = item.icon;
                const on = active === item.id;
                return (
                  <button
                    key={item.id}
                    className={on ? undefined : 'hoverable'}
                    onClick={() => {
                      wb.setOverlay(null);
                      wb.setScreen(item.screen);
                      setOverflowOpen(false);
                    }}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: space[2],
                      width: '100%',
                      height: 30,
                      padding: '0 8px',
                      borderRadius: radius.control,
                      background: on ? wash.selected : undefined,
                      color: on ? color.textPrimary : color.textSecondary,
                      fontSize: fs.caption,
                    }}
                  >
                    <Icon size={14} />
                    {item.label}
                  </button>
                );
              })}
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

/* ── status bar ───────────────────────────────────────────────────────── */

export function QuotaMeter({ percent = 84, label = '残り16%', tint }: { percent?: number; label?: string; tint?: string }) {
  const fill = tint ?? color.textSecondary;
  return (
    <>
      <span style={{ color: color.textQuaternary, fontSize: fs.caption }}>Claude 5時間</span>
      <div style={{ width: 34, height: 4, borderRadius: radius.control, background: line.strong, overflow: 'hidden' }}>
        <div style={{ width: `${percent}%`, height: '100%', background: fill }} />
      </div>
      <span className="tnum" style={{ fontSize: fs.caption, color: fill, fontWeight: 600 }}>
        {label}
      </span>
    </>
  );
}

/**
 * The branch name in the status bar, clickable to switch — a lightweight
 * stand-in for `git checkout` without leaving the status bar. Opens upward
 * (it sits on the bottom edge), same overlay surface and ring as every other
 * popover.
 */
function BranchSwitcher() {
  const wb = useWorkbench();
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) return;
    const close = () => setOpen(false);
    window.addEventListener('mousedown', close);
    return () => window.removeEventListener('mousedown', close);
  }, [open]);

  return (
    <div style={{ position: 'relative' }} onMouseDown={(e) => e.stopPropagation()}>
      <button
        className="hoverable"
        onClick={() => setOpen((v) => !v)}
        title="ブランチを切り替え"
        style={{ display: 'flex', alignItems: 'center', gap: space[1], height: 20, padding: '0 4px', borderRadius: radius.control }}
      >
        <IconBranch size={12} />
        <span>{wb.currentBranch}</span>
      </button>
      {open ? (
        <div
          className="ctx-menu"
          style={{
            position: 'absolute',
            bottom: 24,
            left: 0,
            minWidth: 180,
            padding: 4,
            borderRadius: radius.overlay,
            background: color.chromeRaised,
            border: `1px solid ${line.strong}`,
            boxShadow: '0 -8px 24px rgba(0,0,0,0.35)',
            zIndex: 10,
          }}
        >
          <div style={{ padding: '4px 8px', color: color.textQuaternary, fontSize: fs.caption, fontWeight: 600 }}>ブランチを切り替え</div>
          {wb.branches.map((b) => {
            const on = b === wb.currentBranch;
            return (
              <button
                key={b}
                className={on ? undefined : 'hoverable'}
                onClick={() => {
                  wb.setCurrentBranch(b);
                  setOpen(false);
                }}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: space[2],
                  width: '100%',
                  height: 28,
                  padding: '0 8px',
                  borderRadius: radius.control,
                  background: on ? color.surfaceActive : undefined,
                  color: on ? color.textPrimary : color.textSecondary,
                  fontSize: fs.caption,
                  fontWeight: on ? 600 : 400,
                }}
              >
                <IconBranch size={12} />
                {b}
              </button>
            );
          })}
        </div>
      ) : null}
    </div>
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
      className="tnum"
      style={{
        height: 26,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'center',
        gap: space[3],
        padding: '0 12px',
        backgroundColor: color.chrome,
        borderTop: `1px solid ${line.chrome}`,
        color: color.textTertiary,
        fontSize: fs.caption,
      }}
    >
      <BranchSwitcher />
      <span className="tnum" style={{ color: color.textQuaternary }}>
        {onBranch ? 'worktree' : '↓0 ↑2'}
      </span>
      <span>{6 + wb.dirtyCount} 変更</span>
      {context}
      <div style={{ flex: 1 }} />
      {wb.toggles.showQuota ? <QuotaMeter /> : null}
      <span>{wb.sessions.length} セッション</span>
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
        color: color.chromeInk,
        fontSize: fs.caption,
      }}
    >
      <AppTitlebar extra={titlebarExtra} />
      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        <ActivityBar />
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
