import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';

import { AddAgentOverlay, CommandPalette, SearchOverlay } from './screens/Overlays';
import { ActivityScreen } from './screens/Activity';
import { DebugAgentScreen, DebugScreen } from './screens/Debug';
import { MergeGraphScreen, SessionsScreen } from './screens/Sessions';
import { MobileApp } from './screens/Mobile';
import { ReviewScreen } from './screens/Review';
import { SettingsScreen } from './screens/Settings';
import { WorkspaceScreen } from './screens/Workspace';
import { WorkbenchProvider, useWorkbench } from './store';
import { color, line } from './tokens';

/* ── routing ──────────────────────────────────────────────────────────── */

type Route = 'ide' | 'mobile';

function useRoute(): [Route, (r: Route) => void] {
  const read = (): Route => (window.location.hash.replace(/^#\/?/, '') === 'mobile' ? 'mobile' : 'ide');
  const [route, setRoute] = useState<Route>(read);
  useEffect(() => {
    const onHash = () => setRoute(read());
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);
  return [route, (r: Route) => (window.location.hash = `#/${r}`)];
}

function useViewport() {
  const [size, setSize] = useState(() => ({ width: window.innerWidth, height: window.innerHeight }));
  useEffect(() => {
    const onResize = () => setSize({ width: window.innerWidth, height: window.innerHeight });
    window.addEventListener('resize', onResize);
    window.addEventListener('orientationchange', onResize);
    return () => {
      window.removeEventListener('resize', onResize);
      window.removeEventListener('orientationchange', onResize);
    };
  }, []);
  return size;
}

/* ── the IDE itself ───────────────────────────────────────────────────── */

function Ide() {
  const wb = useWorkbench();

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const cmd = event.metaKey || event.ctrlKey;
      const key = event.key.toLowerCase();

      if (event.key === 'Escape') {
        if (wb.overlay) {
          event.preventDefault();
          wb.setOverlay(null);
        } else if (wb.screen !== 'workspace') {
          event.preventDefault();
          wb.setScreen('workspace');
        }
        return;
      }
      if (!cmd) return;

      // ⌃⌘ family — pane commands, exactly the shortcuts the palette lists.
      if (event.ctrlKey && event.metaKey) {
        if (key === 'd') {
          event.preventDefault();
          return wb.runCommand(event.shiftKey ? 'clair.pane.split.vertical' : 'clair.pane.split.horizontal');
        }
        if (key === 'w') {
          event.preventDefault();
          return wb.runCommand('clair.pane.close');
        }
        if (key === 'm') {
          event.preventDefault();
          return wb.runCommand('clair.pane.maximize');
        }
        if (key === '=') {
          event.preventDefault();
          return wb.runCommand('clair.pane.equalize');
        }
        if (event.key === 'ArrowRight') {
          event.preventDefault();
          return wb.runCommand('clair.pane.focus.right');
        }
        if (key === 'l') {
          event.preventDefault();
          return wb.setScreen('sessions');
        }
        if (key === 'n') {
          event.preventDefault();
          return wb.setOverlay('addAgent');
        }
        if (key === 'g') {
          event.preventDefault();
          return wb.setScreen('review');
        }
      }

      if (key === 'k') {
        event.preventDefault();
        return wb.setOverlay('command');
      }
      if (key === 'p') {
        event.preventDefault();
        return wb.setOverlay('quickOpen');
      }
      if (key === 'f' && event.shiftKey) {
        event.preventDefault();
        return wb.setOverlay('search');
      }
      if (key === 'd' && event.shiftKey) {
        event.preventDefault();
        return wb.setScreen('debug');
      }
      if (event.key === ',') {
        event.preventDefault();
        return wb.setScreen('settings');
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [wb]);

  return (
    <div style={{ position: 'relative', width: '100%', height: '100%', overflow: 'hidden' }}>
      {wb.screen === 'workspace' ? <WorkspaceScreen /> : null}
      {wb.screen === 'review' ? <ReviewScreen /> : null}
      {wb.screen === 'graph' ? <MergeGraphScreen /> : null}
      {wb.screen === 'activity' ? <ActivityScreen /> : null}
      {wb.screen === 'debug' ? <DebugScreen /> : null}
      {wb.screen === 'debugAgent' ? <DebugAgentScreen /> : null}
      {wb.screen === 'settings' ? <SettingsScreen /> : null}
      {wb.screen === 'sessions' ? <SessionsScreen /> : null}

      {wb.overlay === 'command' || wb.overlay === 'quickOpen' ? <CommandPalette /> : null}
      {wb.overlay === 'search' ? <SearchOverlay /> : null}
      {wb.overlay === 'addAgent' ? <AddAgentOverlay /> : null}
    </div>
  );
}

/* ── viewer harness ───────────────────────────────────────────────────────
   Everything below is the harness that lets a 1440×900 desktop design be
   inspected on a phone. It is deliberately outside the product surface: the
   IDE itself is never re-laid-out for a narrow screen, only scaled. */

const DESIGN = { width: 1440, height: 900 };

function ScaledIde({ viewport }: { viewport: { width: number; height: number } }) {
  // Fit to width: the whole layout is visible at once and the viewer zooms in
  // from there. The design itself is never re-laid-out for the narrow screen.
  const fit = Math.min(1, viewport.width / DESIGN.width);
  const [scale, setScale] = useState(fit);
  const [autoFit, setAutoFit] = useState(true);
  const stageRef = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    if (autoFit) setScale(fit);
  }, [autoFit, fit]);

  const bump = useCallback((delta: number) => {
    setAutoFit(false);
    setScale((s) => Math.min(2, Math.max(0.2, Number((s + delta).toFixed(2)))));
  }, []);

  return (
    <div style={{ position: 'fixed', inset: 0, background: color.overlayGround }}>
      <div
        ref={stageRef}
        className="scroll"
        style={{
          position: 'absolute',
          inset: 0,
          overflow: 'auto',
          WebkitOverflowScrolling: 'touch',
          display: 'grid',
          placeContent: 'center start',
        }}
      >
        <div style={{ width: DESIGN.width * scale, height: DESIGN.height * scale }}>
          <div
            style={{
              width: DESIGN.width,
              height: DESIGN.height,
              transform: `scale(${scale})`,
              transformOrigin: 'top left',
            }}
          >
            <Ide />
          </div>
        </div>
      </div>

      <ViewerBar
        scale={scale}
        onZoomOut={() => bump(-0.1)}
        onZoomIn={() => bump(0.1)}
        onFit={() => setAutoFit(true)}
        autoFit={autoFit}
      />
    </div>
  );
}

function ViewerBar({
  scale,
  onZoomOut,
  onZoomIn,
  onFit,
  autoFit,
}: {
  scale: number;
  onZoomOut: () => void;
  onZoomIn: () => void;
  onFit: () => void;
  autoFit: boolean;
}) {
  const button: React.CSSProperties = {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    minWidth: 30,
    height: 26,
    padding: '0 8px',
    borderRadius: 4,
    color: color.textSecondary,
    fontSize: 12,
  };
  return (
    <div
      style={{
        position: 'fixed',
        left: '50%',
        bottom: 'calc(12px + env(safe-area-inset-bottom))',
        transform: 'translateX(-50%)',
        zIndex: 90,
        display: 'flex',
        alignItems: 'center',
        gap: 2,
        height: 34,
        padding: '0 6px',
        borderRadius: 8,
        background: color.chromeRaised,
        border: '1px solid rgba(242,244,238,0.14)',
        boxShadow: '0 8px 20px rgba(0,0,0,0.4)',
      }}
    >
      <button style={button} onClick={onZoomOut} aria-label="縮小">
        −
      </button>
      <button
        style={{ ...button, color: autoFit ? color.textPrimary : color.textSecondary, fontSize: 10, fontWeight: 600 }}
        onClick={onFit}
      >
        {Math.round(scale * 100)}%
      </button>
      <button style={button} onClick={onZoomIn} aria-label="拡大">
        +
      </button>
      <div style={{ width: 1, height: 18, background: 'rgba(242,244,238,0.14)', margin: '0 4px' }} />
      <a
        href="#/mobile"
        style={{ ...button, textDecoration: 'none', fontSize: 10, fontWeight: 600, color: color.textTertiary }}
      >
        モバイル
      </a>
    </div>
  );
}

const PHONE = { width: 390, height: 844 };

function MobileStage({ viewport }: { viewport: { width: number; height: number } }) {
  // On a real phone the app runs full-bleed; on a desktop it sits in a frame.
  const fullBleed = viewport.width <= 460;

  if (fullBleed) {
    return (
      <div style={{ position: 'fixed', inset: 0, background: color.chrome }}>
        <MobileApp />
        <a
          href="#/ide"
          style={{
            position: 'fixed',
            right: 'calc(10px + env(safe-area-inset-right))',
            top: 'calc(10px + env(safe-area-inset-top))',
            zIndex: 90,
            display: 'flex',
            alignItems: 'center',
            height: 24,
            padding: '0 9px',
            borderRadius: 12,
            background: 'rgba(242,244,238,0.07)',
            border: '1px solid rgba(242,244,238,0.22)',
            color: color.textSecondary,
            fontSize: 10,
            fontWeight: 600,
            textDecoration: 'none',
          }}
        >
          IDEへ
        </a>
      </div>
    );
  }

  const scale = Math.min(1, (viewport.height - 96) / PHONE.height);

  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        background: color.overlayGround,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 16,
      }}
    >
      <div style={{ width: PHONE.width * scale, height: PHONE.height * scale }}>
        <div
          style={{
            width: PHONE.width,
            height: PHONE.height,
            transform: `scale(${scale})`,
            transformOrigin: 'top left',
            borderRadius: 44,
            overflow: 'hidden',
            border: `1px solid ${line.strong}`,
            boxShadow: '0 24px 70px rgba(0,0,0,0.5)',
          }}
        >
          <MobileApp />
        </div>
      </div>
      <a
        href="#/ide"
        style={{
          display: 'flex',
          alignItems: 'center',
          height: 24,
          padding: '0 11px',
          borderRadius: 12,
          background: 'rgba(242,244,238,0.07)',
          border: '1px solid rgba(242,244,238,0.22)',
          color: color.textSecondary,
          fontSize: 10,
          fontWeight: 600,
          textDecoration: 'none',
        }}
      >
        デスクトップのIDEへ戻る
      </a>
    </div>
  );
}

export default function App() {
  const [route] = useRoute();
  const viewport = useViewport();
  const narrow = viewport.width < 1000;

  return (
    <WorkbenchProvider>
      {route === 'mobile' ? (
        <MobileStage viewport={viewport} />
      ) : narrow ? (
        <ScaledIde viewport={viewport} />
      ) : (
        <Ide />
      )}
    </WorkbenchProvider>
  );
}
