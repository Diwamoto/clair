// Design tokens transcribed from the Tokens artboard of the Clair UI design
// canvas. The canvas is the source of truth: every value here is copied, not
// chosen. Do not add a token that the canvas does not define.

export const color = {
  // SURFACE — two tiers. The pane (canvas/surface) is the darkest thing in
  // the window because it is what you read for hours; chrome sits one step
  // above it so the frame reads as frame and never as content. Dark only —
  // there is no light theme.
  chrome: '#31363f',
  canvas: '#282c34',
  surface: '#282c34',
  chromeRaised: '#1e2227',
  surfaceHover: '#2e333c',
  surfaceActive: '#383d47',

  // CHROME INK — chrome's own ladder. Its strongest step stays under the
  // code's own contrast against the pane (6.6:1) so the frame never speaks
  // louder than the thing being read; textPrimary is content ink only.
  chromeInk: '#b6bcb6',
  chromeInkMuted: '#8a908b',

  // TEXT
  textPrimary: '#f1f3ef',
  textSecondary: '#c9cec8',
  textTertiary: '#9ba19b',
  textQuaternary: '#707871',

  // Further inks the artboards use for the quietest labels and rules.
  textMuted: '#55605a',
  lineNumber: '#4b5561',
  divider: '#3d454e',

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
} as const;

// Hairlines and washes, exactly as they appear on the artboards.
export const line = {
  hairline: 'rgba(242,244,238,0.11)',
  hairlineSoft: 'rgba(242,244,238,0.08)',
  hairlineFaint: 'rgba(242,244,238,0.055)',
  chrome: 'rgba(242,244,238,0.1)',
  chromeSoft: 'rgba(242,244,238,0.09)',
  strong: 'rgba(242,244,238,0.19)',
  stronger: 'rgba(242,244,238,0.28)',
  ring: 'rgba(242,244,238,0.32)',
  paneDivider: 'rgba(242,244,238,0.15)',
} as const;

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
  faint: 'rgba(242,244,238,0.03)',
  soft: 'rgba(242,244,238,0.04)',
  medium: 'rgba(242,244,238,0.06)',
  raised: 'rgba(242,244,238,0.075)',
  selected: 'rgba(255,255,255,0.08)',
  strong: 'rgba(242,244,238,0.09)',
  strongest: 'rgba(242,244,238,0.12)',
} as const;

// TYPE SCALE — 4 steps.
export const type = {
  title: { fontSize: 13, fontWeight: 600 },
  chromeStrong: { fontSize: 11, fontWeight: 600 },
  chrome: { fontSize: 11, fontWeight: 400 },
  micro: { fontSize: 9, fontWeight: 500 },
} as const;

// RADIUS — 3 steps.
export const radius = { control: 4, card: 6, overlay: 10 } as const;

// SPACING — 7 steps.
export const space = [2, 4, 6, 8, 12, 16, 24] as const;

// CHROME BUDGET — the vertical px before code. titlebar 48 + status bar 26.
export const chrome = { titlebar: 48, sidebarStrip: 34, statusBar: 26 } as const;

export const sans =
  "-apple-system, BlinkMacSystemFont, 'Hiragino Sans', 'Hiragino Kaku Gothic ProN', 'SF Pro Text', system-ui, sans-serif";
export const mono = '"SF Mono", ui-monospace, "JetBrains Mono", Menlo, monospace';
