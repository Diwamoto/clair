'use client';

import { useState } from 'react';

import { canvasScreens } from './canvas-screens';

export default function Home() {
  const [activeId, setActiveId] = useState(canvasScreens[0].id);
  const active = canvasScreens.find((screen) => screen.id === activeId) ?? canvasScreens[0];

  return (
    <div className="screen-shell">
      <nav className="screen-rail" aria-label="画面">
        <div className="screen-rail-heading">Clair UI</div>
        {canvasScreens.map((screen) => (
          <button
            type="button"
            key={screen.id}
            className={screen.id === activeId ? 'is-active' : ''}
            onClick={() => setActiveId(screen.id)}
          >
            {screen.label}
          </button>
        ))}
      </nav>
      <div className="screen-stage">
        <div className="screen-frame-note">
          {active.label} · {active.width}×{active.height}
        </div>
        <div
          className="screen-frame"
          style={{ width: active.width, height: active.height }}
        >
          <style dangerouslySetInnerHTML={{ __html: active.css }} />
          <div dangerouslySetInnerHTML={{ __html: active.html }} />
        </div>
      </div>
    </div>
  );
}
