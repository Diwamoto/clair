// Screen transitions.
//
// The model is one z axis. The workspace sits nearest the viewer; every other
// screen lives behind it. Navigating away pushes the current screen back into
// depth and the next one emerges from that same depth — and coming back does
// the same in reverse. Three screens have a genuinely different relationship
// to the workspace and move differently, so the motion says something about
// where you went rather than being decoration:
//
//   depth   default. Recede / emerge along z.
//   slide   merge graph ↔ branch review — siblings in the sidebar strip, so
//           they move sideways in the direction of travel.
//   lift    the session rail — one table across every project, so it rises
//           from below like a drawer rather than coming from behind the page.
//   sheet   settings — a sheet that comes over the top, not from behind.
//
// Durations come from the LATENCY BUDGET on the Tokens artboard: Project切替
// is 80 / 200ms, so a screen change animates in 200ms and an overlay — budgeted
// with palette表示 at 33 / 80ms — in 90ms.

import { useLayoutEffect, useRef, useState, type ReactNode } from 'react';

import type { Screen } from './store';

export const SCREEN_MS = 200;
export const OVERLAY_MS = 90;

type Kind = 'depth' | 'slide' | 'lift' | 'sheet';

const KIND: Record<Screen, Kind> = {
  workspace: 'depth',
  review: 'slide',
  graph: 'slide',
  activity: 'depth',
  debug: 'depth',
  debugAgent: 'depth',
  sessions: 'lift',
  settings: 'sheet',
};

// Left-to-right order in the sidebar strip, so a slide knows its direction.
const ORDER: Screen[] = ['workspace', 'graph', 'review', 'debug', 'debugAgent', 'activity', 'sessions', 'settings'];

function transitionFor(from: Screen, to: Screen) {
  // The screen being *entered* chooses the motion, except when returning to
  // the workspace, where the screen being left is the one with character.
  const kind = to === 'workspace' ? KIND[from] : KIND[to];
  if (kind === 'slide') {
    const forward = ORDER.indexOf(to) >= ORDER.indexOf(from);
    return forward ? 'slide-fwd' : 'slide-back';
  }
  return kind;
}

/**
 * Cross-fades between screens. The outgoing screen stays mounted for one
 * transition so both halves of the movement are visible at once.
 */
export function ScreenStage({ screen, children }: { screen: Screen; children: ReactNode }) {
  const nodeRef = useRef<ReactNode>(children);
  const screenRef = useRef<Screen>(screen);
  const [leaving, setLeaving] = useState<{ key: number; node: ReactNode; name: string } | null>(null);
  const [entering, setEntering] = useState<{ key: number; name: string } | null>(null);
  const seq = useRef(0);
  const timer = useRef(0);

  useLayoutEffect(() => {
    if (screenRef.current !== screen) {
      const name = transitionFor(screenRef.current, screen);
      seq.current += 1;
      const key = seq.current;
      setLeaving({ key, node: nodeRef.current, name });
      setEntering({ key, name });
      screenRef.current = screen;

      // The timer is held in a ref rather than returned as an effect cleanup:
      // this effect has no dependency list, so a cleanup would be run by the
      // very next render — the one these setStates cause — and the outgoing
      // layer would never be torn down.
      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => {
        setLeaving((current) => (current?.key === key ? null : current));
        setEntering((current) => (current?.key === key ? null : current));
      }, SCREEN_MS);
    }
    nodeRef.current = children;
  });

  useLayoutEffect(() => () => window.clearTimeout(timer.current), []);

  return (
    <div style={{ position: 'relative', width: '100%', height: '100%', overflow: 'hidden' }}>
      {leaving ? (
        <div key={`leave-${leaving.key}`} className={`screen-layer leave-${leaving.name}`} aria-hidden>
          {leaving.node}
        </div>
      ) : null}
      <div key={entering ? `enter-${entering.key}` : 'stable'} className={entering ? `screen-layer enter-${entering.name}` : 'screen-layer'}>
        {children}
      </div>
    </div>
  );
}
