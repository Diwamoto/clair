// Follow-through motion, ported from arc-library (MIT,
// github.com/kuratlielia/arc-library): registry/motion-tokens.ts plus the
// behaviour of its command palette. Canvas policy: *responses* to input stay
// inside the LATENCY BUDGET on the Tokens artboard (overlays open in 90ms).
// The springs here only drive motion that follows an already-visible answer —
// a highlight catching up, rows closing their gaps, a frame settling to its
// new height — so they never add latency to an action.

import { useEffect, useState } from 'react';

export type Spring = { stiffness: number; damping: number };

// arc states its springs as visualDuration/bounce; the physical mapping is
// arc's own `physical()` (registry/components/confirm-morph), so a retarget
// mid-flight keeps the velocity it already has:
//   root = 2π / (visualDuration · 1.2)   stiffness = root²   damping = 2(1−bounce)·root
const physical = (visualDuration: number, bounce: number): Spring => {
  const root = (2 * Math.PI) / (visualDuration * 1.2);
  return { stiffness: root * root, damping: 2 * (1 - bounce) * root };
};

/** Presses, pointers, small indicators. Settles fast with a hint of life. */
export const SNAPPY: Spring = physical(0.26, 0.12);
/** Panels, height changes, layout shifts. Critically damped, never overshoots. */
export const SMOOTH: Spring = physical(0.4, 0);
/** Shape morphs and shared layout highlights. */
export const MORPH: Spring = physical(0.42, 0.16);

/** arc's enter ease, for the short tweens that answer the keyboard. */
export const ENTER = [0.16, 1, 0.3, 1] as const;

type Tween = { tween: true; duration: number; ease: readonly [number, number, number, number] };
export type Motion = Spring | Tween;

/** A short ease in seconds, e.g. the keyboard's 70ms highlight slide. */
export const tween = (duration: number, ease: readonly [number, number, number, number] = ENTER): Tween => ({
  tween: true,
  duration,
  ease,
});

const isTween = (m: Motion): m is Tween => 'tween' in m;

// Standard CSS cubic-bezier evaluation (x from t via Newton–Raphson with a
// bisection fallback), so a tween here matches a CSS transition exactly.
function cubicBezier([x1, y1, x2, y2]: readonly [number, number, number, number]) {
  const cx = 3 * x1;
  const bx = 3 * (x2 - x1) - cx;
  const ax = 1 - cx - bx;
  const cy = 3 * y1;
  const by = 3 * (y2 - y1) - cy;
  const ay = 1 - cy - by;
  const sampleX = (t: number) => ((ax * t + bx) * t + cx) * t;
  const sampleY = (t: number) => ((ay * t + by) * t + cy) * t;
  const sampleDX = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (x: number) => {
    let t = x;
    for (let i = 0; i < 8; i++) {
      const err = sampleX(t) - x;
      if (Math.abs(err) < 1e-6) return sampleY(t);
      const d = sampleDX(t);
      if (Math.abs(d) < 1e-6) break;
      t -= err / d;
    }
    let lo = 0;
    let hi = 1;
    t = x;
    while (hi - lo > 1e-6) {
      if (sampleX(t) < x) lo = t;
      else hi = t;
      t = (lo + hi) / 2;
    }
    return sampleY(t);
  };
}

/**
 * Animate one scalar, calling `onUpdate` with each frame's value. Returns a
 * cancel function. Springs integrate with fixed 1ms substeps so the feel does
 * not depend on frame rate.
 */
export function animate(from: number, to: number, motion: Motion, onUpdate: (v: number) => void, onDone?: () => void): () => void {
  if (from === to) {
    onUpdate(to);
    onDone?.();
    return () => {};
  }
  let raf = 0;
  let dead = false;
  if (isTween(motion)) {
    const ease = cubicBezier(motion.ease);
    const t0 = performance.now();
    const step = (now: number) => {
      if (dead) return;
      const t = Math.min(1, (now - t0) / (motion.duration * 1000));
      onUpdate(from + (to - from) * ease(t));
      if (t < 1) raf = requestAnimationFrame(step);
      else {
        dead = true;
        onDone?.();
      }
    };
    raf = requestAnimationFrame(step);
  } else {
    let value = from;
    let velocity = 0;
    let last = performance.now();
    const step = (now: number) => {
      if (dead) return;
      let dt = Math.min(64, now - last) / 1000;
      last = now;
      while (dt > 0) {
        const h = Math.min(dt, 0.001);
        const force = -motion.stiffness * (value - to) - motion.damping * velocity;
        velocity += force * h;
        value += velocity * h;
        dt -= h;
      }
      onUpdate(value);
      if (Math.abs(value - to) < 0.05 && Math.abs(velocity) < 1) {
        dead = true;
        onUpdate(to);
        onDone?.();
        return;
      }
      raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
  }
  return () => {
    dead = true;
    cancelAnimationFrame(raf);
  };
}

/** arc's GLIDE_ROWS: when every remaining row moves within about a viewport,
 * the list closes its gaps with a glide; a long jump (the first letters typed
 * into a long list) snaps like a search-result list instead of streaking rows
 * through the frame. A row only in the new list just appears and never blocks
 * the glide — but with no shared rows there is nothing to glide, so snap. */
export const GLIDE_ROWS = 6;

export function shouldGlide(previous: readonly string[], current: readonly string[]): boolean {
  const before = new Map(previous.map((key, i) => [key, i]));
  let shared = 0;
  for (let i = 0; i < current.length; i++) {
    const from = before.get(current[i]!);
    if (from === undefined) continue;
    shared++;
    if (Math.abs(from - i) > GLIDE_ROWS) return false;
  }
  return shared > 0;
}

/** `prefers-reduced-motion: reduce`, live. Everything here stops, not slows. */
export function useReducedMotion(): boolean {
  const [reduced, setReduced] = useState(() => matchMedia('(prefers-reduced-motion: reduce)').matches);
  useEffect(() => {
    const mq = matchMedia('(prefers-reduced-motion: reduce)');
    const on = () => setReduced(mq.matches);
    mq.addEventListener('change', on);
    return () => mq.removeEventListener('change', on);
  }, []);
  return reduced;
}
