// Clair's own context menu.
//
// The CONTROLS card on the Tokens artboard says "nativeを混ぜない", and the
// right-click menu was the one native control still showing through — the
// browser's here, AppKit's in the app. The ContextMenu artboard defines the
// replacement; the values below are copied from it:
//
// - material: the overlay's (chromeRaised over line.strong, radius 10, the
//   palette's shadow) but no scrim — a menu does not dim the window.
// - rows: 26px, radius 6 inside the 4px padding, so the corners stay
//   concentric with the 10px panel. Hover and keyboard selection are one
//   state and wear surfaceActive; nothing in a menu carries colour.
// - header: when the menu acts on one object (a file, a project) its name and
//   path sit on top, so you can see what you right-clicked. A place — a
//   selection, a pane — gets no header.
// - an action that exists but cannot run right now stays, disabled, so its
//   position is learnable; an action that means nothing for this target is
//   left out.
// - destructive actions come last, in weight 700, never in red.
// - opens in 90ms from the corner nearest the pointer; closes at once.

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
} from 'react';

import { IconChevron } from './icons';
import { useWorkbench, type Workbench } from './store';
import { GROUP_COLOR_KEYS, color, groupColor, line, type GroupColorKey } from './tokens';

export type MenuItem = {
  type: 'item';
  label: string;
  icon?: ReactNode;
  shortcut?: string;
  /** Quiet trailing text that describes the target rather than naming a key. */
  detail?: string;
  run?: () => void;
  disabled?: boolean;
  destructive?: boolean;
  submenu?: MenuEntry[];
};

export type MenuEntry =
  | MenuItem
  | { type: 'separator' }
  | { type: 'swatches'; value: GroupColorKey; onPick: (key: GroupColorKey) => void };

export type MenuSpec = {
  header?: { icon?: ReactNode; title: string; sub?: string };
  entries: MenuEntry[];
};

/** Rebuilt on every render of the open menu, so it always reads live state. */
export type MenuBuilder = (wb: Workbench) => MenuSpec;

export const separator: MenuEntry = { type: 'separator' };

export const item = (label: string, rest: Omit<MenuItem, 'type' | 'label'> = {}): MenuItem => ({
  type: 'item',
  label,
  ...rest,
});

const GROUP_LABEL: Record<GroupColorKey, string> = {
  blue: '青',
  green: '緑',
  amber: '黄',
  red: '赤',
  purple: '紫',
  gray: 'なし',
};

/**
 * Open a menu at the pointer. The surface passes a builder, not a menu, and
 * optionally the id of the thing it was opened on (see `contextMenu.target`).
 */
export function useContextMenu() {
  const { openContextMenu } = useWorkbench();
  return useCallback(
    (event: ReactMouseEvent, build: MenuBuilder, target?: string) => {
      event.preventDefault();
      openContextMenu(event.clientX, event.clientY, build, target);
    },
    [openContextMenu],
  );
}

/** The ring a right-clicked row or tab wears while its menu is open. */
export const targetRing = `inset 0 0 0 1px ${line.ring}`;

const MARGIN = 8;
const PAD = 4;
const ICON_COLUMN = 14;

type Pos = { left: number; top: number; origin: string };

const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(value, max));

const selectable = (entry: MenuEntry | undefined) =>
  !!entry && (entry.type === 'swatches' || (entry.type === 'item' && !entry.disabled));

const firstSelectable = (entries: MenuEntry[]) => entries.findIndex(selectable);

export function ContextMenuLayer() {
  const wb = useWorkbench();
  if (!wb.contextMenu) return null;
  return <OpenMenu key={wb.contextMenu.id} />;
}

function OpenMenu() {
  const wb = useWorkbench();
  const menu = wb.contextMenu!;
  const spec = (menu.build as MenuBuilder)(wb);
  const close = wb.closeContextMenu;
  const layerRef = useRef<HTMLDivElement>(null);

  // The active row at each open level; a level exists for every submenu the
  // active path runs through. -1 means the level is open with nothing lit.
  const [levels, setLevels] = useState<number[]>([-1]);
  const [swatch, setSwatch] = useState(() => {
    const row = spec.entries.find((e) => e.type === 'swatches');
    return row?.type === 'swatches' ? GROUP_COLOR_KEYS.indexOf(row.value) : 0;
  });

  const panels: MenuEntry[][] = [spec.entries];
  for (let depth = 0; depth < levels.length - 1; depth++) {
    const entry = panels[depth][levels[depth]];
    if (entry?.type !== 'item' || !entry.submenu || entry.disabled) break;
    panels.push(entry.submenu);
  }

  // Keyboard focus moves into the menu, and goes back where it came from on
  // close — unless whatever the chosen item opened has taken it already.
  useLayoutEffect(() => {
    const layer = layerRef.current;
    const previous = document.activeElement as HTMLElement | null;
    layer?.querySelector<HTMLElement>('[data-level="0"]')?.focus({ preventScroll: true });
    return () => {
      const now = document.activeElement;
      if (!now || now === document.body || layer?.contains(now)) previous?.focus?.({ preventScroll: true });
    };
  }, []);

  useEffect(() => {
    window.addEventListener('blur', close);
    window.addEventListener('resize', close);
    return () => {
      window.removeEventListener('blur', close);
      window.removeEventListener('resize', close);
    };
  }, [close]);

  const choose = (depth: number, index: number) => {
    const entry = panels[depth]?.[index];
    if (!entry || entry.type === 'separator') return;
    if (entry.type === 'swatches') {
      entry.onPick(GROUP_COLOR_KEYS[swatch]);
      return;
    }
    if (entry.disabled) return;
    if (entry.submenu) {
      setLevels([...levels.slice(0, depth), index, firstSelectable(entry.submenu)]);
      return;
    }
    close();
    entry.run?.();
  };

  const hover = (depth: number, index: number) => {
    const entry = panels[depth][index];
    const next = [...levels.slice(0, depth), selectable(entry) ? index : -1];
    if (entry?.type === 'item' && entry.submenu && !entry.disabled) next.push(-1);
    if (next.join() !== levels.join()) setLevels(next);
  };

  // Leaving a panel clears its highlight, unless the pointer is on its way
  // into the submenu that row opened.
  const leave = (depth: number) => {
    if (levels.length > depth + 1) return;
    if (levels[depth] !== -1) setLevels([...levels.slice(0, depth), -1]);
  };

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (['Shift', 'Meta', 'Control', 'Alt', 'CapsLock'].includes(event.key)) return;
      const depth = panels.length - 1;
      const entries = panels[depth];
      const index = levels[depth] ?? -1;
      const entry = entries[index];
      const stop = () => {
        event.preventDefault();
        event.stopPropagation();
      };

      switch (event.key) {
        case 'ArrowDown':
        case 'ArrowUp': {
          stop();
          const dir = event.key === 'ArrowDown' ? 1 : -1;
          const n = entries.length;
          let i = index < 0 ? (dir > 0 ? -1 : n) : index;
          for (let step = 0; step < n; step++) {
            i = (i + dir + n) % n;
            if (selectable(entries[i])) break;
          }
          if (selectable(entries[i])) setLevels([...levels.slice(0, depth), i]);
          return;
        }
        case 'ArrowRight':
          stop();
          if (entry?.type === 'swatches') setSwatch((s) => Math.min(GROUP_COLOR_KEYS.length - 1, s + 1));
          else if (entry?.type === 'item' && entry.submenu && !entry.disabled) {
            setLevels([...levels.slice(0, depth + 1), firstSelectable(entry.submenu)]);
          }
          return;
        case 'ArrowLeft':
          stop();
          if (entry?.type === 'swatches') setSwatch((s) => Math.max(0, s - 1));
          else if (depth > 0) setLevels(levels.slice(0, depth));
          return;
        case 'Enter':
        case ' ':
          stop();
          choose(depth, index);
          return;
        case 'Escape':
          stop();
          if (depth > 0) setLevels(levels.slice(0, depth));
          else close();
          return;
        case 'Tab':
          stop();
          return;
        default:
          close();
      }
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  });

  /**
   * The layer's own box, in the unscaled 1440×900 design space. The layer is
   * read off the panel rather than `layerRef`: a panel is placed in its own
   * layout effect, which runs before the parent's ref is attached.
   */
  const frame = (layer: HTMLElement) => {
    const box = layer.getBoundingClientRect();
    const scale = layer.offsetWidth ? box.width / layer.offsetWidth : 1;
    return {
      width: layer.offsetWidth,
      height: layer.offsetHeight,
      x: (clientX: number) => (clientX - box.left) / scale,
      y: (clientY: number) => (clientY - box.top) / scale,
    };
  };

  const placeRoot = (el: HTMLElement): Pos => {
    const f = frame(el.parentElement!);
    const x = f.x(menu.x);
    const y = f.y(menu.y);
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    const flipX = x + w > f.width - MARGIN;
    const flipY = y + h > f.height - MARGIN;
    return {
      left: clamp(flipX ? x - w : x, MARGIN, f.width - w - MARGIN),
      top: clamp(flipY ? y - h : y, MARGIN, f.height - h - MARGIN),
      origin: `${flipX ? 'right' : 'left'} ${flipY ? 'bottom' : 'top'}`,
    };
  };

  // A submenu's first row lines up with the row that opened it, and the two
  // panels share an edge; it flips to the left when the right has no room.
  const placeSub = (depth: number) => (el: HTMLElement): Pos => {
    const layer = el.parentElement!;
    const f = frame(layer);
    const parent = layer.querySelector(`[data-level="${depth - 1}"]`)!.getBoundingClientRect();
    const row = layer
      .querySelector(`[data-level="${depth - 1}"] [data-index="${levels[depth - 1]}"]`)!
      .getBoundingClientRect();
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    let left = f.x(parent.right) - 1;
    const flipX = left + w > f.width - MARGIN;
    if (flipX) left = f.x(parent.left) - w + 1;
    return {
      left,
      top: clamp(f.y(row.top) - PAD - 1, MARGIN, f.height - h - MARGIN),
      origin: `${flipX ? 'right' : 'left'} top`,
    };
  };

  return (
    <div
      ref={layerRef}
      // The layer catches the click that dismisses the menu, so it never
      // lands on whatever sits underneath. A right-click is handed on, so a
      // second menu opens where the pointer is now.
      onMouseDown={(event) => {
        if (event.target !== event.currentTarget || event.button !== 0 || event.ctrlKey) return;
        close();
      }}
      onWheel={(event) => {
        if (event.target === event.currentTarget) close();
      }}
      onContextMenu={(event) => {
        event.preventDefault();
        if (event.target !== event.currentTarget) return;
        const layer = event.currentTarget;
        const { clientX, clientY } = event;
        layer.style.pointerEvents = 'none';
        const below = document.elementFromPoint(clientX, clientY);
        layer.style.pointerEvents = '';
        close();
        below?.dispatchEvent(
          new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX, clientY, button: 2 }),
        );
      }}
      style={{ position: 'absolute', inset: 0, zIndex: 60 }}
    >
      {panels.map((entries, depth) => (
        <Panel
          key={depth === 0 ? 'root' : `${depth}:${levels[depth - 1]}`}
          depth={depth}
          entries={entries}
          header={depth === 0 ? spec.header : undefined}
          active={levels[depth] ?? -1}
          swatch={swatch}
          place={depth === 0 ? placeRoot : placeSub(depth)}
          onHover={hover}
          onLeave={leave}
          onChoose={choose}
          onSwatch={setSwatch}
        />
      ))}
    </div>
  );
}

function Panel({
  depth,
  entries,
  header,
  active,
  swatch,
  place,
  onHover,
  onLeave,
  onChoose,
  onSwatch,
}: {
  depth: number;
  entries: MenuEntry[];
  header?: MenuSpec['header'];
  active: number;
  swatch: number;
  place: (el: HTMLElement) => Pos;
  onHover: (depth: number, index: number) => void;
  onLeave: (depth: number) => void;
  onChoose: (depth: number, index: number) => void;
  onSwatch: (index: number) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<Pos | null>(null);

  // Measured before the first paint, so the panel never shows at 0,0.
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const next = place(el);
    setPos((cur) =>
      cur && cur.left === next.left && cur.top === next.top && cur.origin === next.origin ? cur : next,
    );
    // Placement depends on the row count, not on the entries' identity, which
    // changes on every render because the builder reruns.
  }, [entries.length, header?.title]);

  // Only a panel that has an icon somewhere keeps the icon column.
  const icons = entries.some((e) => e.type === 'item' && e.icon) || !!header?.icon;
  const labelInset = icons ? 8 + ICON_COLUMN + 8 : 8;

  return (
    <div
      ref={ref}
      role="menu"
      tabIndex={-1}
      data-level={depth}
      className="ctx-menu"
      onMouseLeave={() => onLeave(depth)}
      onContextMenu={(event) => event.preventDefault()}
      style={{
        position: 'absolute',
        // Unplaced, the panel sits at 0,0 for one commit that is never
        // painted. It is not hidden for it: a hidden panel cannot take focus.
        left: pos?.left ?? 0,
        top: pos?.top ?? 0,
        transformOrigin: pos?.origin,
        minWidth: 220,
        maxWidth: 320,
        padding: PAD,
        background: color.chromeRaised,
        border: `1px solid ${line.strong}`,
        borderRadius: 10,
        boxShadow: '0 18px 48px rgba(0,0,0,0.62)',
        outline: 'none',
        userSelect: 'none',
      }}
    >
      {header ? (
        <>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '5px 8px 4px' }}>
            {header.icon ? (
              <span style={{ width: ICON_COLUMN, flexShrink: 0, display: 'flex', justifyContent: 'center', color: color.textTertiary }}>
                {header.icon}
              </span>
            ) : null}
            <span style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0 }}>
              <span
                style={{
                  fontSize: 11,
                  fontWeight: 600,
                  color: color.textPrimary,
                  whiteSpace: 'nowrap',
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                }}
              >
                {header.title}
              </span>
              {header.sub ? (
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
                  {header.sub}
                </span>
              ) : null}
            </span>
          </div>
          <Rule />
        </>
      ) : null}

      {entries.map((entry, index) => {
        if (entry.type === 'separator') return <Rule key={index} />;

        if (entry.type === 'swatches') {
          const lit = active === index;
          return (
            <div
              key={index}
              role="group"
              aria-label="グループカラー"
              data-index={index}
              onMouseEnter={() => onHover(depth, index)}
              style={{ display: 'flex', alignItems: 'center', gap: 6, height: 32, padding: `0 8px 0 ${labelInset}px` }}
            >
              {GROUP_COLOR_KEYS.map((key, i) => {
                const picked = entry.value === key;
                const focused = lit && swatch === i;
                return (
                  <button
                    key={key}
                    role="menuitemradio"
                    aria-checked={picked}
                    aria-label={GROUP_LABEL[key]}
                    title={GROUP_LABEL[key]}
                    onMouseEnter={() => onSwatch(i)}
                    onClick={() => {
                      onSwatch(i);
                      entry.onPick(key);
                    }}
                    style={{
                      width: 26,
                      height: 18,
                      flexShrink: 0,
                      borderRadius: 4,
                      background: groupColor[key],
                      boxShadow: picked
                        ? `0 0 0 2px ${color.chromeRaised}, 0 0 0 3.5px ${color.textSecondary}`
                        : focused
                          ? `0 0 0 2px ${color.chromeRaised}, 0 0 0 3.5px ${line.ring}`
                          : 'none',
                    }}
                  />
                );
              })}
            </div>
          );
        }

        const on = active === index;
        const label = entry.disabled
          ? color.textMuted
          : on || entry.destructive
            ? color.textPrimary
            : color.textSecondary;
        const quiet = entry.disabled ? color.textMuted : on ? color.textSecondary : color.textQuaternary;
        return (
          <div
            key={index}
            role="menuitem"
            data-index={index}
            aria-disabled={entry.disabled || undefined}
            aria-haspopup={entry.submenu ? 'menu' : undefined}
            aria-expanded={entry.submenu ? on : undefined}
            onMouseEnter={() => onHover(depth, index)}
            onClick={() => onChoose(depth, index)}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              height: 26,
              padding: '0 8px',
              borderRadius: 6,
              background: on ? color.surfaceActive : undefined,
              cursor: entry.disabled ? 'default' : 'pointer',
            }}
          >
            {icons ? (
              <span
                style={{
                  width: ICON_COLUMN,
                  flexShrink: 0,
                  display: 'flex',
                  justifyContent: 'center',
                  color: entry.disabled ? color.textMuted : on ? color.textSecondary : color.textTertiary,
                }}
              >
                {entry.icon}
              </span>
            ) : null}
            <span
              style={{
                flex: 1,
                minWidth: 0,
                fontSize: 12,
                fontWeight: entry.destructive ? 700 : 400,
                color: label,
                whiteSpace: 'nowrap',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
              }}
            >
              {entry.label}
            </span>
            {entry.detail ? (
              <span className="cl" style={{ marginLeft: 12, fontSize: 10, color: quiet, whiteSpace: 'nowrap' }}>
                {entry.detail}
              </span>
            ) : null}
            {entry.shortcut ? (
              <span className="cl" style={{ marginLeft: 20, fontSize: 10, color: quiet, whiteSpace: 'nowrap' }}>
                {entry.shortcut}
              </span>
            ) : null}
            {entry.submenu ? <IconChevron size={10} color={quiet} style={{ marginLeft: 12 }} /> : null}
          </div>
        );
      })}
    </div>
  );
}

function Rule() {
  return <div role="separator" style={{ height: 1, margin: '4px 8px', background: line.hairline }} />;
}
