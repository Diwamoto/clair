// Icons copied verbatim from the Clair UI design canvas artboards. Paths are
// transcribed as-is; only the wrapper is React. Nothing here is redrawn.

type S = { size?: number; color?: string; style?: React.CSSProperties };

const stroke = (d: React.ReactNode, w = 1.4, extra: Record<string, string> = {}) =>
  function Icon({ size = 16, color = 'currentColor', style }: S) {
    return (
      <svg
        width={size}
        height={size}
        viewBox="0 0 16 16"
        fill="none"
        stroke={color}
        strokeWidth={w}
        style={{ flexShrink: 0, ...style }}
        {...extra}
      >
        {d}
      </svg>
    );
  };

const filled = (d: React.ReactNode) =>
  function Icon({ size = 16, color = 'currentColor', style }: S) {
    return (
      <svg width={size} height={size} viewBox="0 0 16 16" fill={color} style={{ flexShrink: 0, ...style }}>
        {d}
      </svg>
    );
  };

export const IconClaude = filled(
  <path d="M13.4 8.9c.4-1.7-.1-3.6-1.5-5-1.9-1.9-4.8-2.2-7.1-.9.3 0 .7 0 1 .1 1.5.2 2.8 1 3.6 2.1-1.1-.4-2.3-.5-3.5-.1 1.4.2 2.6 1 3.4 2.2-1.6.4-3.3-.1-4.4-1.3.1 2.2 1.6 4.1 3.7 4.8-2 .4-4-.3-5.3-1.8.6 3.1 3.5 5.2 6.6 4.7 3.7-.5 5.9-2.6 7.1-4.9-.6.1-1.1.1-1.5.1z" />,
);

export const IconSparkle = filled(
  <path d="M8 1.4l1.15 4.45L13.6 7 9.15 8.15 8 12.6l-1.15-4.45L2.4 7l4.45-1.15z" />,
);

export const IconCodex = stroke(<path d="M8 1.6l5.5 3.2v6.4L8 14.4l-5.5-3.2V4.8z" />, 1.3, {
  strokeLinejoin: 'round',
});

export const IconSearch = stroke(
  <>
    <circle cx="7" cy="7" r="4.1" />
    <path d="M10.1 10.1 13.6 13.6" />
  </>,
  1.5,
  { strokeLinecap: 'round' },
);

export const IconCommand = stroke(
  <>
    <rect x="5.6" y="5.6" width="4.8" height="4.8" />
    <circle cx="4.1" cy="4.1" r="1.5" />
    <circle cx="11.9" cy="4.1" r="1.5" />
    <circle cx="4.1" cy="11.9" r="1.5" />
    <circle cx="11.9" cy="11.9" r="1.5" />
  </>,
  1.4,
);

export const IconGear = stroke(
  <>
    <circle cx="8" cy="8" r="2.2" />
    <path d="M8 2.2v1.5M8 12.3v1.5M13.8 8h-1.5M3.7 8H2.2M12.1 3.9l-1.05 1.05M4.95 11.05 3.9 12.1M12.1 12.1l-1.05-1.05M4.95 4.95 3.9 3.9" />
  </>,
  1.3,
);

export const IconFolder = stroke(
  <path d="M2.2 4.6A1.4 1.4 0 0 1 3.6 3.2h2.7l1.4 1.9h4.7a1.4 1.4 0 0 1 1.4 1.4v5a1.4 1.4 0 0 1-1.4 1.4H3.6a1.4 1.4 0 0 1-1.4-1.4z" />,
  1.4,
  { strokeLinejoin: 'round' },
);

export const IconBranch = stroke(
  <>
    <circle cx="4.6" cy="3.7" r="1.7" />
    <circle cx="4.6" cy="12.3" r="1.7" />
    <circle cx="11.4" cy="6.4" r="1.7" />
    <path d="M4.6 5.4v5.2M11.4 8.1c0 2.2-2.1 2.5-3.6 2.9" />
  </>,
  1.4,
);

export const IconBranchSmall = stroke(
  <>
    <circle cx="4.6" cy="3.7" r="1.4" />
    <circle cx="4.6" cy="12.3" r="1.4" />
    <circle cx="11.4" cy="6.4" r="1.4" />
    <path d="M4.6 5.1v5.8M11.4 7.8c0 2.2-2.1 2.5-3.6 2.9" />
  </>,
  1.7,
);

export const IconShieldCheck = stroke(
  <>
    <path d="M8 2.3 3.3 4.2v3.9c0 2.7 2 4.7 4.7 5.5 2.7-.8 4.7-2.8 4.7-5.5V4.2z" />
    <path d="M6.1 7.9 7.5 9.3l2.5-2.6" />
  </>,
  1.4,
  { strokeLinejoin: 'round' },
);

export const IconBell = stroke(
  <>
    <path d="M8 2.6a3.5 3.5 0 0 1 3.5 3.5c0 2.9 1.2 3.8 1.2 3.8H3.3s1.2-.9 1.2-3.8A3.5 3.5 0 0 1 8 2.6z" />
    <path d="M6.7 12.3a1.4 1.4 0 0 0 2.6 0" />
  </>,
  1.4,
);

export const IconBellOff = stroke(
  <>
    <path d="M8 2.6a3.5 3.5 0 0 1 3.5 3.5c0 2.9 1.2 3.8 1.2 3.8H3.3s1.2-.9 1.2-3.8A3.5 3.5 0 0 1 8 2.6z" />
    <path d="M6.7 12.3a1.4 1.4 0 0 0 2.6 0" />
    <path d="M3 3l10 10" />
  </>,
  1.4,
);

export const IconBellFilled = filled(
  <>
    <path d="M8 2.2a3.6 3.6 0 0 1 3.6 3.6c0 2.9 1.2 3.9 1.2 3.9H3.2s1.2-1 1.2-3.9A3.6 3.6 0 0 1 8 2.2z" />
    <path d="M6.6 11.6a1.5 1.5 0 0 0 2.8 0z" />
  </>,
);

export const IconSession = stroke(
  <>
    <rect x="2.2" y="3.2" width="11.6" height="9.6" rx="1.5" />
    <path d="M4.9 6.4 6.9 8.3 4.9 10.2" />
    <path d="M8.5 10.4h2.6" />
  </>,
  1.4,
  { strokeLinecap: 'round', strokeLinejoin: 'round' },
);

export const IconEmptySession = stroke(
  <>
    <rect x="2.2" y="3.2" width="11.6" height="9.6" rx="1.5" />
    <path d="M4.9 6.4 6.9 8.3 4.9 10.2" />
  </>,
  1.2,
  { strokeLinecap: 'round', strokeLinejoin: 'round' },
);

export const IconEllipsis = filled(
  <>
    <circle cx="4" cy="8" r="1.15" />
    <circle cx="8" cy="8" r="1.15" />
    <circle cx="12" cy="8" r="1.15" />
  </>,
);

export const IconDoc = stroke(<path d="M4.2 2.3h5.1L12 5v8.7a1 1 0 0 1-1 1H4.2a1 1 0 0 1-1-1V3.3a1 1 0 0 1 1-1z" />, 1.3, {
  strokeLinejoin: 'round',
});

export const IconMarkdown = stroke(
  <>
    <rect x="1.2" y="3.4" width="13.6" height="9.2" rx="1.3" />
    <path d="M3.4 10.1V5.9l2.1 2.5 2.1-2.5v4.2M10 6.1v3M8.6 8.1l1.4 1.7 1.4-1.7" />
  </>,
  1.2,
  { strokeLinecap: 'round', strokeLinejoin: 'round' },
);

export const IconChevron = stroke(<path d="M5.5 3.5 10 8l-4.5 4.5" />, 1.7, {
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
});

export const IconRefresh = stroke(<path d="M13 8a5 5 0 1 1-1.5-3.6M13 3.2v2.6h-2.6" />, 1.5, {
  strokeLinecap: 'round',
});

export const IconArrowRight = stroke(<path d="M3 8h9M9 5l3 3-3 3" />, 1.5, {
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
});

export const IconClose = stroke(<path d="M5 5l6 6M11 5l-6 6" />, 1.9, { strokeLinecap: 'round' });

export const IconCloseThin = stroke(<path d="M3.5 3.5l9 9M12.5 3.5l-9 9" />, 1.6, { strokeLinecap: 'round' });

export const IconTerminalPrompt = stroke(<><path d="M3 4l4 4-4 4" /><path d="M9 12h4" /></>, 1.6, {
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
});

export const IconBrackets = stroke(<path d="M6 4.5 2.8 8 6 11.5M10 4.5 13.2 8 10 11.5" />, 1.8, {
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
});

export const IconInfo = stroke(<><circle cx="8" cy="8" r="5.8" /><path d="M8 7.2v3.6M8 5.3v.9" /></>, 1.4);

export const IconGrid = stroke(
  <>
    <rect x="2.2" y="2.6" width="4.6" height="4.6" rx="1" />
    <rect x="9.2" y="2.6" width="4.6" height="4.6" rx="1" />
    <rect x="2.2" y="8.8" width="4.6" height="4.6" rx="1" />
    <rect x="9.2" y="8.8" width="4.6" height="4.6" rx="1" />
  </>,
  1.3,
);

export const IconDot = filled(<circle cx="8" cy="8" r="6" />);

export const IconPlay = filled(<path d="M5 3.5v9l8-4.5z" />);

export const IconStepOver = stroke(
  <>
    <path d="M2.5 8h8" />
    <path d="M7.5 4.5 11 8l-3.5 3.5" />
    <circle cx="13.2" cy="8" r="1.3" fill="currentColor" stroke="none" />
  </>,
  1.5,
  { strokeLinecap: 'round', strokeLinejoin: 'round' },
);

export const IconStepInto = stroke(
  <>
    <path d="M8 2.5v6.5" />
    <path d="M4.8 6 8 9l3.2-3" />
    <path d="M2.5 13h11" />
  </>,
  1.5,
  { strokeLinecap: 'round', strokeLinejoin: 'round' },
);

export const IconStepOut = stroke(
  <>
    <path d="M8 9.5v-6.5" />
    <path d="M4.8 6l3.2-3 3.2 3" />
    <path d="M2.5 13h11" />
  </>,
  1.5,
  { strokeLinecap: 'round', strokeLinejoin: 'round' },
);

export const IconStop = filled(<rect x="3" y="3" width="10" height="10" rx="1.5" />);

export const IconStar = filled(
  <path d="M8 1.6l1.35 3.9 4.1.15-3.25 2.55 1.2 3.95L8 9.7l-3.4 2.45 1.2-3.95L2.55 5.65l4.1-.15z" />,
);

export const IconGopher = stroke(
  <>
    <path d="M4 6.2C3 4.8 3.4 3 4.8 2.3M12 6.2c1-1.4.6-3.2-.8-3.9" />
    <path d="M8 6.6c-2.6 0-4.6 1.7-4.6 3.9 0 2.2 2 3.6 4.6 3.6s4.6-1.4 4.6-3.6c0-2.2-2-3.9-4.6-3.9z" />
    <circle cx="6.1" cy="9.6" r="1" fill="#282c34" stroke="none" />
    <circle cx="9.9" cy="9.6" r="1" fill="#282c34" stroke="none" />
    <path d="M6.9 12.1c.3.3.9.3 1.2 0" />
  </>,
  1.2,
  { strokeLinecap: 'round', strokeLinejoin: 'round' },
);

export const IconQuickOpen = stroke(
  <>
    <path d="M4.2 2.6h4.6L12 5.8v7.6H4.2z" />
    <path d="M8.6 2.6v3.3H12" />
  </>,
  1.5,
  { strokeLinejoin: 'round' },
);

export const IconGrip = ({ color = 'currentColor' }: { color?: string }) => (
  <svg width="8" height="14" viewBox="0 0 8 14" fill={color}>
    <circle cx="2" cy="2" r="1.2" />
    <circle cx="6" cy="2" r="1.2" />
    <circle cx="2" cy="7" r="1.2" />
    <circle cx="6" cy="7" r="1.2" />
    <circle cx="2" cy="12" r="1.2" />
    <circle cx="6" cy="12" r="1.2" />
  </svg>
);
