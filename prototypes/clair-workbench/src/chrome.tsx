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
  IconCodex,
  IconCommand,
  IconEllipsis,
  IconFolder,
  IconGear,
  IconSearch,
  IconSession,
  IconSparkle,
} from './icons';
import { useWorkbench, type Screen } from './store';

const byPath = new Map(files.map((f) => [f.path, f]));

/** Monochrome Simple Icons logos (CC0), mirroring native `FileIcon` (ClairDesignSystem). */
const kindLogo: Record<FileKind, string> = {
  swift: 'M7.51 0C7.22 0 6.94 0 6.65 0C6.41 0 6.17 0.01 5.92 0.01C5.79 0.01 5.66 0.02 5.53 0.03C5.13 0.04 4.74 0.08 4.35 0.15C3.83 0.24 3.32 0.41 2.85 0.65C1.9 1.13 1.13 1.9 0.64 2.85C0.4 3.33 0.24 3.82 0.15 4.35C0.06 4.87 0.03 5.4 0.01 5.92C0.01 6.17 0 6.41 0 6.65C0 6.93 0 7.22 0 7.51L0 16.49C0 16.78 0 17.07 0 17.35C0 17.59 0.01 17.84 0.01 18.08C0.03 18.6 0.06 19.13 0.15 19.65C0.25 20.18 0.4 20.67 0.65 21.15C1.13 22.1 1.9 22.87 2.85 23.36C3.33 23.6 3.82 23.75 4.35 23.85C4.87 23.94 5.4 23.97 5.92 23.99C6.16 24 6.41 24 6.65 24C6.93 24 7.22 24 7.51 24L16.49 24C16.78 24 17.07 24 17.35 24C17.59 24 17.84 24 18.08 23.99C18.6 23.98 19.13 23.94 19.65 23.85C20.18 23.76 20.68 23.59 21.15 23.35C22.1 22.87 22.87 22.1 23.36 21.15C23.6 20.67 23.75 20.18 23.85 19.65C23.94 19.13 23.97 18.6 23.99 18.08C24 17.84 24 17.59 24 17.35C24 17.07 24 16.78 24 16.49L24 7.51C24 7.22 24 6.94 24 6.65C24 6.41 23.99 6.17 23.99 5.92C23.98 5.4 23.94 4.87 23.85 4.35C23.76 3.83 23.59 3.32 23.35 2.85C22.87 1.9 22.1 1.13 21.15 0.64C20.68 0.41 20.18 0.24 19.65 0.15C19.13 0.06 18.6 0.02 18.08 0.01C17.84 0.01 17.59 0 17.35 0C17.07 0 16.78 0 16.49 0L7.51 0ZM13.54 3.41C17.66 5.88 20.09 10.57 19.09 14.54C19.07 14.63 19.04 14.72 19.02 14.81L19.02 14.81C21.08 17.35 20.52 20.07 20.25 19.56C19.18 17.47 17.19 17.99 16.17 18.52C16.07 18.57 15.98 18.62 15.88 18.67L15.86 18.69L15.86 18.69C13.75 19.81 10.91 19.89 8.05 18.67C5.73 17.66 3.76 15.97 2.41 13.83C3.06 14.31 3.76 14.73 4.51 15.08C7.53 16.49 10.56 16.39 12.7 15.08C9.65 12.73 7.1 9.67 5.15 7.19C4.77 6.76 4.44 6.29 4.14 5.81C6.48 7.95 10.18 10.64 11.51 11.38C8.69 8.41 6.21 4.74 6.32 4.86C10.76 9.33 14.85 11.86 14.85 11.86C15.01 11.94 15.12 12.01 15.21 12.07C15.3 11.85 15.37 11.63 15.44 11.4C16.14 8.81 15.35 5.85 13.54 3.41Z',
  go: 'M1.81 10.23C1.76 10.23 1.75 10.21 1.78 10.17L2.02 9.86C2.05 9.82 2.1 9.8 2.15 9.8L6.32 9.8C6.37 9.8 6.38 9.83 6.36 9.87L6.16 10.17C6.14 10.21 6.08 10.24 6.04 10.24ZM0.05 11.31C0 11.31 -0.01 11.28 0.01 11.25L0.26 10.93C0.28 10.9 0.34 10.87 0.39 10.87L5.71 10.87C5.76 10.87 5.78 10.91 5.77 10.94L5.68 11.22C5.67 11.27 5.62 11.29 5.57 11.29ZM2.88 12.38C2.83 12.38 2.82 12.35 2.84 12.31L3 12.02C3.03 11.98 3.07 11.95 3.12 11.95L5.46 11.95C5.5 11.95 5.53 11.98 5.53 12.03L5.5 12.31C5.5 12.36 5.46 12.39 5.42 12.39ZM15 10.02C14.27 10.21 13.76 10.35 13.04 10.53C12.87 10.58 12.85 10.59 12.7 10.42C12.53 10.22 12.4 10.09 12.15 9.97C11.42 9.61 10.7 9.72 10.04 10.15C9.24 10.66 8.83 11.42 8.85 12.37C8.86 13.3 9.5 14.07 10.42 14.2C11.22 14.31 11.88 14.03 12.41 13.43C12.52 13.3 12.61 13.16 12.72 13L10.47 13C10.23 13 10.17 12.85 10.25 12.65C10.4 12.29 10.68 11.68 10.84 11.38C10.9 11.26 11.01 11.19 11.14 11.19L15.39 11.19C15.37 11.5 15.37 11.82 15.32 12.14C15.2 12.97 14.87 13.76 14.36 14.43C13.52 15.54 12.42 16.23 11.03 16.41C9.89 16.56 8.82 16.34 7.89 15.64C7.02 14.99 6.53 14.12 6.4 13.05C6.25 11.77 6.63 10.63 7.4 9.62C8.23 8.54 9.33 7.85 10.67 7.6C11.77 7.4 12.82 7.53 13.77 8.17C14.38 8.58 14.83 9.14 15.12 9.82C15.19 9.93 15.14 9.99 15 10.02M18.87 16.48C17.81 16.46 16.84 16.15 16.02 15.45C15.34 14.88 14.89 14.08 14.76 13.2C14.55 11.88 14.91 10.71 15.7 9.67C16.56 8.55 17.59 7.96 18.98 7.72C20.17 7.51 21.29 7.62 22.31 8.31C23.23 8.94 23.8 9.8 23.95 10.92C24.15 12.5 23.7 13.78 22.61 14.88C21.84 15.66 20.89 16.15 19.81 16.38C19.49 16.44 19.18 16.45 18.87 16.48ZM21.65 11.76C21.64 11.61 21.64 11.49 21.62 11.38C21.41 10.22 20.34 9.57 19.23 9.82C18.15 10.07 17.45 10.76 17.19 11.85C16.98 12.77 17.42 13.69 18.26 14.06C18.91 14.34 19.55 14.31 20.17 13.99C21.09 13.51 21.59 12.77 21.65 11.76Z',
  md: 'M22.27 19.39L1.73 19.39C1.27 19.39 0.83 19.2 0.51 18.88C0.18 18.55 0 18.11 0 17.66L0 6.34C0 5.39 0.77 4.62 1.73 4.62L22.27 4.62C23.23 4.62 24 5.39 24 6.35L24 17.65C24 18.11 23.82 18.55 23.49 18.88C23.17 19.2 22.73 19.38 22.27 19.38ZM5.77 15.92L5.77 11.42L8.08 14.31L10.38 11.42L10.38 15.92L12.69 15.92L12.69 8.08L10.38 8.08L8.08 10.96L5.77 8.08L3.46 8.08L3.46 15.93ZM21.23 12L18.92 12L18.92 8.08L16.62 8.08L16.62 12L14.31 12L17.77 16.04Z',
  rust: 'M23.83 11.7L22.83 11.08C22.82 10.98 22.81 10.88 22.8 10.79L23.66 9.98C23.75 9.9 23.79 9.78 23.77 9.66C23.74 9.54 23.66 9.44 23.55 9.4L22.44 8.99C22.42 8.89 22.39 8.8 22.36 8.7L23.05 7.74C23.12 7.65 23.13 7.52 23.09 7.41C23.04 7.3 22.94 7.22 22.82 7.2L21.65 7.01C21.61 6.92 21.56 6.83 21.51 6.75L22 5.67C22.05 5.56 22.04 5.43 21.98 5.33C21.91 5.23 21.8 5.18 21.68 5.18L20.49 5.22C20.43 5.15 20.37 5.07 20.3 5L20.58 3.84C20.6 3.73 20.57 3.6 20.48 3.52C20.4 3.43 20.28 3.4 20.16 3.43L19.01 3.7C18.93 3.63 18.85 3.57 18.78 3.51L18.82 2.33C18.83 2.21 18.77 2.09 18.67 2.02C18.57 1.96 18.44 1.95 18.33 2L17.25 2.49C17.17 2.44 17.08 2.39 16.99 2.35L16.8 1.18C16.78 1.06 16.7 0.96 16.59 0.92C16.48 0.87 16.35 0.89 16.26 0.96L15.3 1.65C15.2 1.62 15.11 1.59 15.01 1.56L14.6 0.45C14.55 0.34 14.46 0.26 14.34 0.24C14.22 0.21 14.1 0.25 14.02 0.34L13.21 1.2C13.11 1.19 13.02 1.18 12.92 1.18L12.29 0.17C12.23 0.07 12.12 0 12 0C11.88 0 11.77 0.07 11.71 0.17L11.08 1.18C10.98 1.18 10.89 1.19 10.79 1.2L9.98 0.34C9.9 0.25 9.78 0.21 9.66 0.23C9.54 0.26 9.44 0.34 9.4 0.45L8.99 1.56C8.89 1.59 8.8 1.62 8.7 1.65L7.74 0.95C7.65 0.89 7.52 0.87 7.41 0.92C7.3 0.96 7.22 1.06 7.2 1.18L7.01 2.35C6.92 2.39 6.83 2.44 6.75 2.49L5.67 2C5.56 1.95 5.43 1.96 5.33 2.02C5.23 2.09 5.18 2.21 5.18 2.33L5.22 3.51C5.15 3.57 5.07 3.63 4.99 3.7L3.84 3.42C3.72 3.4 3.6 3.43 3.52 3.52C3.43 3.6 3.4 3.73 3.42 3.84L3.7 5C3.63 5.07 3.57 5.15 3.51 5.22L2.32 5.18C2.2 5.18 2.09 5.23 2.02 5.33C1.96 5.43 1.95 5.56 2 5.67L2.49 6.75C2.44 6.83 2.39 6.92 2.35 7.01L1.18 7.2C1.06 7.22 0.96 7.3 0.92 7.41C0.87 7.52 0.89 7.65 0.96 7.74L1.65 8.7C1.62 8.8 1.59 8.89 1.56 8.99L0.45 9.4C0.34 9.44 0.26 9.54 0.23 9.66C0.21 9.78 0.25 9.9 0.34 9.98L1.2 10.79C1.19 10.88 1.18 10.98 1.17 11.08L0.17 11.7C0.06 11.77 0 11.88 0 12C0 12.12 0.06 12.23 0.17 12.29L1.17 12.92C1.18 13.01 1.19 13.11 1.2 13.21L0.34 14.02C0.25 14.1 0.21 14.22 0.23 14.34C0.26 14.46 0.34 14.55 0.45 14.6L1.56 15.01C1.59 15.11 1.62 15.2 1.65 15.3L0.95 16.25C0.88 16.35 0.87 16.48 0.92 16.59C0.96 16.7 1.06 16.78 1.18 16.8L2.35 16.99C2.39 17.08 2.44 17.16 2.49 17.25L2 18.33C1.95 18.44 1.96 18.56 2.02 18.66C2.09 18.76 2.21 18.82 2.33 18.82L3.51 18.77C3.57 18.85 3.63 18.93 3.7 19L3.43 20.16C3.4 20.27 3.43 20.4 3.52 20.48C3.6 20.57 3.73 20.6 3.84 20.57L5 20.3C5.07 20.37 5.15 20.43 5.22 20.49L5.18 21.67C5.18 21.79 5.23 21.91 5.33 21.97C5.43 22.04 5.56 22.05 5.67 22L6.75 21.51C6.83 21.56 6.92 21.6 7.01 21.65L7.2 22.82C7.22 22.93 7.3 23.03 7.41 23.08C7.52 23.13 7.65 23.11 7.75 23.04L8.7 22.35C8.8 22.38 8.89 22.41 8.99 22.44L9.4 23.55C9.44 23.66 9.54 23.74 9.66 23.77C9.78 23.79 9.9 23.75 9.98 23.66L10.79 22.8C10.89 22.81 10.98 22.82 11.08 22.83L11.71 23.83C11.77 23.93 11.88 24 12 24C12.12 24 12.23 23.93 12.3 23.83L12.92 22.83C13.02 22.82 13.12 22.81 13.21 22.8L14.02 23.66C14.1 23.75 14.22 23.79 14.34 23.76C14.46 23.74 14.55 23.66 14.6 23.55L15.01 22.44C15.11 22.41 15.2 22.38 15.3 22.35L16.26 23.04C16.35 23.11 16.48 23.13 16.59 23.08C16.7 23.04 16.78 22.94 16.8 22.82L16.99 21.65C17.08 21.6 17.17 21.56 17.25 21.51L18.33 22C18.44 22.05 18.57 22.04 18.67 21.97C18.76 21.91 18.82 21.79 18.82 21.67L18.78 20.49C18.85 20.43 18.93 20.37 19 20.3L20.16 20.57C20.27 20.6 20.4 20.56 20.48 20.48C20.57 20.4 20.6 20.27 20.57 20.16L20.3 19C20.37 18.93 20.43 18.85 20.49 18.77L21.67 18.82C21.79 18.82 21.91 18.76 21.98 18.66C22.04 18.56 22.05 18.44 22 18.33L21.51 17.25C21.56 17.16 21.61 17.08 21.65 16.99L22.82 16.8C22.94 16.78 23.04 16.7 23.08 16.59C23.13 16.48 23.11 16.35 23.04 16.25L22.35 15.3L22.44 15.01L23.55 14.6C23.66 14.55 23.74 14.46 23.77 14.34C23.79 14.22 23.75 14.1 23.66 14.02L22.8 13.21C22.81 13.11 22.82 13.01 22.83 12.92L23.83 12.29C23.94 12.23 24 12.12 24 12C24 11.88 23.94 11.77 23.83 11.7ZM17.09 20.06C16.71 19.97 16.47 19.6 16.55 19.21C16.63 18.83 17.01 18.58 17.39 18.66C17.64 18.71 17.85 18.89 17.93 19.14C18.01 19.38 17.95 19.65 17.78 19.84C17.61 20.03 17.34 20.12 17.09 20.06ZM16.75 17.74C16.58 17.71 16.41 17.74 16.26 17.83C16.12 17.93 16.02 18.08 15.98 18.24L15.62 19.91C14.52 20.41 13.29 20.69 12 20.69C10.73 20.69 9.47 20.42 8.31 19.88L7.95 18.21C7.91 18.04 7.81 17.89 7.67 17.8C7.52 17.71 7.35 17.67 7.18 17.71L5.71 18.03C5.43 17.74 5.18 17.44 4.94 17.13L12.11 17.13C12.19 17.13 12.25 17.11 12.25 17.04L12.25 14.5C12.25 14.43 12.19 14.42 12.11 14.42L10.02 14.42L10.02 12.81L12.28 12.81C12.49 12.81 13.39 12.87 13.68 14.02C13.77 14.37 13.96 15.52 14.1 15.89C14.24 16.3 14.78 17.13 15.37 17.13L18.94 17.13C18.98 17.13 19.03 17.12 19.07 17.12C18.82 17.45 18.55 17.77 18.26 18.07ZM6.84 20.02C6.59 20.08 6.32 20 6.15 19.81C5.97 19.62 5.92 19.35 6 19.11C6.08 18.86 6.28 18.68 6.54 18.63C6.92 18.55 7.29 18.8 7.37 19.18C7.46 19.56 7.22 19.94 6.84 20.02ZM4.12 9C4.23 9.23 4.21 9.51 4.06 9.72C3.9 9.93 3.65 10.04 3.39 10.01C3.13 9.98 2.91 9.82 2.81 9.58C2.67 9.22 2.83 8.81 3.18 8.65C3.54 8.5 3.95 8.65 4.12 9ZM3.28 10.98L4.82 10.3C4.97 10.23 5.1 10.1 5.16 9.94C5.22 9.77 5.22 9.6 5.15 9.44L4.83 8.72L6.07 8.72L6.07 14.33L3.57 14.33C3.26 13.24 3.16 12.1 3.28 10.98ZM10.02 10.43L10.02 8.78L12.98 8.78C13.13 8.78 14.06 8.96 14.06 9.65C14.06 10.23 13.35 10.43 12.76 10.43ZM20.77 11.92C20.77 12.14 20.77 12.36 20.75 12.57L19.85 12.57C19.76 12.57 19.72 12.63 19.72 12.72L19.72 13.13C19.72 14.11 19.17 14.32 18.69 14.37C18.24 14.42 17.73 14.18 17.67 13.9C17.4 12.38 16.95 12.06 16.24 11.5C17.12 10.94 18.03 10.11 18.03 9C18.03 7.81 17.22 7.06 16.66 6.69C15.88 6.17 15.01 6.07 14.77 6.07L5.47 6.07C6.75 4.63 8.48 3.66 10.38 3.3L11.47 4.45C11.59 4.58 11.75 4.65 11.93 4.65C12.1 4.66 12.27 4.59 12.39 4.47L13.62 3.3C16.15 3.77 18.35 5.34 19.62 7.57L18.78 9.47C18.64 9.8 18.78 10.18 19.11 10.33L20.73 11.05C20.76 11.34 20.77 11.63 20.77 11.92ZM11.47 2.32C11.66 2.15 11.92 2.08 12.17 2.15C12.41 2.23 12.6 2.42 12.66 2.67C12.72 2.92 12.64 3.18 12.46 3.35C12.17 3.6 11.74 3.58 11.47 3.31C11.21 3.03 11.21 2.6 11.47 2.32ZM19.81 9.03C19.89 8.86 20.03 8.72 20.21 8.66C20.38 8.59 20.58 8.59 20.75 8.67C21.02 8.79 21.18 9.05 21.18 9.34C21.17 9.63 20.99 9.88 20.72 9.99C20.45 10.09 20.15 10.02 19.95 9.81C19.75 9.61 19.69 9.3 19.81 9.03Z',
};

export function FileIcon({ kind, tint }: { kind: FileKind; tint?: string }) {
  return (
    <svg width={14} height={14} viewBox="0 0 24 24" fill={tint ?? 'currentColor'} aria-hidden>
      <path d={kindLogo[kind]} />
    </svg>
  );
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
              fontSize: fs.secondary,
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
            fontSize: fs.secondary,
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
