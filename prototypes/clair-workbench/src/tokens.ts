// Design tokens transcribed from the Tokens artboard of the Clair UI design
// canvas. The canvas is the source of truth: every value here is copied, not
// chosen. Do not add a token that the canvas does not define.

export const color = {
  // SURFACE — two tiers. The pane (canvas/surface) is the darkest thing in
  // the window because it is what you read for hours; chrome sits one step
  // above it so the frame reads as frame and never as content. These are the
  // dark scheme; `applyScheme('light')` swaps in `light` below (spec §5.11).
  chrome: '#31363f',
  canvas: '#282c34',
  surface: '#282c34',
  chromeRaised: '#1e2227',
  surfaceHover: '#2e333c',
  surfaceActive: '#383d47',

  // CHROME INK — chrome's own ladder. Its strongest step stays under the
  // code's own contrast against the pane (6.6:1) so the frame never speaks
  // louder than the thing being read; textPrimary is content ink only.
  chromeInk: '#b7bac1',

  // TEXT
  textPrimary: '#f1f2f6',
  textSecondary: '#caccd2',
  textTertiary: '#9b9fa6',
  textQuaternary: '#81858d',

  // Rules and gutters. There is no text ink below textQuaternary.
  lineNumber: '#5f636d',
  divider: '#494d56',

  // MEANING — only diff and debug are allowed to carry colour.
  success: '#8acb94',
  attention: '#e5c07b',
  danger: '#e27b83',

  // Debug-only accents (current line / call stack), from the Debug artboard.
  debugBlue: '#5b88f7',
  debugBlueText: '#8fb0fa',

  // Panel grounds used by cards, footers and overlays.
  panel: '#181b1f',
  panelDeep: '#101214',
  overlayGround: '#0c0e10',

  // Editor content colours (One Dark), from the code blocks on the artboards.
  code: '#abb2bf',
  codeBright: '#d0d4cf',
  codeComment: '#5c6370',
  codeKeyword: '#c678dd',
  codeType: '#e5c07b',
  codeFunc: '#61afef',
  codeString: '#98c379',
  codeNumber: '#d19a66',

  // Traffic lights.
  close: '#ff5f57',
  minimize: '#febc2e',
  zoom: '#28c840',
};

// Hairlines and washes. Structural rules are black (One Dark grooves);
// strong/stronger/ring stay light so focus and emphasis remain visible.
export const line = {
  hairline: 'rgba(0,0,0,0.4)',
  hairlineSoft: 'rgba(0,0,0,0.32)',
  hairlineFaint: 'rgba(0,0,0,0.24)',
  chrome: 'rgba(0,0,0,0.36)',
  chromeSoft: 'rgba(0,0,0,0.32)',
  strong: 'rgba(241,242,246,0.19)',
  stronger: 'rgba(241,242,246,0.28)',
  ring: 'rgba(241,242,246,0.32)',
  paneDivider: 'rgba(0,0,0,0.5)',
};

// TAB GROUP COLOURS — the one other place colour is allowed, alongside diff
// and debug: identifying a project's tab group in the titlebar. Reuses the
// existing accents (not new hues) so a coloured group still reads as part of
// the same muted palette. `gray` (== line.stronger) is the uncoloured default.
export const groupColor = {
  blue: '#5b88f7',
  green: '#8acb94',
  amber: '#e5c07b',
  red: '#e27b83',
  purple: '#c678dd',
  gray: line.stronger,
} as const;

export type GroupColorKey = keyof typeof groupColor;
export const GROUP_COLOR_KEYS = Object.keys(groupColor) as GroupColorKey[];

/** A `groupColor` entry at a given opacity — `gray` already carries its own
 * alpha (it's `line.stronger`), so it passes through unchanged. */
export function withAlpha(swatch: string, alpha: number): string {
  if (!swatch.startsWith('#')) return swatch;
  const n = parseInt(swatch.slice(1), 16);
  const r = (n >> 16) & 255;
  const g = (n >> 8) & 255;
  const b = n & 255;
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

export const wash = {
  faint: 'rgba(241,242,246,0.03)',
  soft: 'rgba(241,242,246,0.04)',
  medium: 'rgba(241,242,246,0.06)',
  raised: 'rgba(241,242,246,0.075)',
  selected: 'rgba(255,255,255,0.08)',
  strong: 'rgba(241,242,246,0.09)',
  strongest: 'rgba(241,242,246,0.12)',
};

// LIGHT SCHEME — One Light, the counterpart of the One Dark palette above.
// Same roles; washes and strong rules darken instead of lighten. Body ink
// (code, textSecondary) holds ≥ 4.5:1 on the canvas.
const light = {
  color: {
    chrome: '#eaeaeb', canvas: '#fafafa', surface: '#fafafa', chromeRaised: '#dcdcde',
    surfaceHover: '#f0f0f1', surfaceActive: '#e3e3e5',
    chromeInk: '#4f525a',
    textPrimary: '#1f2126', textSecondary: '#383a42', textTertiary: '#595c64', textQuaternary: '#6b6e76',
    lineNumber: '#9d9fa6', divider: '#d0d1d4',
    success: '#3d8a4a', attention: '#9a6700', danger: '#c8323f',
    debugBlue: '#4078f2', debugBlueText: '#2f5fd0',
    panel: '#f0f0f1', panelDeep: '#e6e6e7', overlayGround: '#d6d6d8',
    code: '#383a42', codeBright: '#202227', codeComment: '#8e9099', codeKeyword: '#a626a4',
    codeType: '#986801', codeFunc: '#3a6ee0', codeString: '#3d8a3c', codeNumber: '#986801',
    close: '#ff5f57', minimize: '#febc2e', zoom: '#28c840',
  },
  line: {
    hairline: 'rgba(0,0,0,0.14)', hairlineSoft: 'rgba(0,0,0,0.11)', hairlineFaint: 'rgba(0,0,0,0.08)',
    chrome: 'rgba(0,0,0,0.12)', chromeSoft: 'rgba(0,0,0,0.1)',
    strong: 'rgba(31,33,38,0.19)', stronger: 'rgba(31,33,38,0.28)', ring: 'rgba(31,33,38,0.32)',
    paneDivider: 'rgba(0,0,0,0.16)',
  },
  wash: {
    faint: 'rgba(31,33,38,0.03)', soft: 'rgba(31,33,38,0.04)', medium: 'rgba(31,33,38,0.06)',
    raised: 'rgba(31,33,38,0.075)', selected: 'rgba(0,0,0,0.06)', strong: 'rgba(31,33,38,0.09)',
    strongest: 'rgba(31,33,38,0.12)',
  },
} satisfies { color: typeof color; line: typeof line; wash: typeof wash };
const dark = { color: { ...color }, line: { ...line }, wash: { ...wash } };

// ponytail: swaps the shared token objects in place, so values captured at
// import time (styles.css, module-level consts) stay dark. CSS variables if
// the mock ever needs those to follow.
export function applyScheme(scheme: 'dark' | 'light') {
  const s = scheme === 'light' ? light : dark;
  Object.assign(color, s.color);
  Object.assign(line, s.line);
  Object.assign(wash, s.wash);
}

// TYPE SCALE — 4 steps, the macOS text styles. Strength comes from weight
// (400 / 600 only) and ink, never from size. Nothing under 11px.
export const fs = { caption: 11, secondary: 12, body: 13, title: 15, display: { pairingCode: 17, h1: 20, screenTitle: 24 } } as const;
export const lineHeight = { caption: '16px', secondary: '18px', body: '20px', title: '22px' } as const;

// RADIUS — 3 steps plus pill. `device` is the phone frame in the viewer only.
export const radius = { control: 4, card: 6, overlay: 10, pill: 999, device: 44 } as const;

// SPACING — 6 steps. 2 is only for an icon-to-label hairline gap.
export const space = [2, 4, 8, 12, 16, 24] as const;

// CHROME BUDGET — the vertical px before code. titlebar 48 + status bar 26.
// `cell` is the shared module of the two chrome strips: the titlebar's height
// and the activity bar's width are both one cell, and the selectable control
// inside either (a tab, a rail icon) is one `cellControl` square-ish box, so the
// two read as the same part with the same inset (5px).
const cell = 48;
export const chrome = { cell, cellControl: 38, titlebar: cell, activityBarWidth: cell, statusBar: 26 } as const;

export const sans = "-apple-system, BlinkMacSystemFont, 'Hiragino Sans', 'Hiragino Kaku Gothic ProN', sans-serif";
export const mono = "'SF Mono', ui-monospace, Menlo, 'Hiragino Sans', monospace";
