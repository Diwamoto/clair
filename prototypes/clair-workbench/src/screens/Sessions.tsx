import { branchColor, commits, type Session } from '../data';
import {
  IconBellFilled,
  IconBranch,
  IconBrackets,
  IconClose,
  IconCodex,
  IconSession,
  IconSparkle,
  IconTerminalPrompt,
} from '../icons';
import { useWorkbench } from '../store';
import { Chip, MainHeader, SourceControlModeTabs } from '../chrome';
import { color, fs, groupColor, line, radius, space, wash } from '../tokens';

const GRID = '26px 146px 84px 196px 66px 1fr 104px 88px';

function AgentIcon({ icon }: { icon: Session['icon'] }) {
  if (icon === 'codex') return <IconCodex size={12} color={color.textTertiary} />;
  if (icon === 'claude') return <IconSparkle size={12} color={color.textTertiary} />;
  if (icon === 'opencode') return <IconBrackets size={12} color={color.textTertiary} />;
  return <IconTerminalPrompt size={12} color={color.textQuaternary} />;
}

export function SessionsMain() {
  const wb = useWorkbench();
  const attention = wb.sessions.find((s) => s.attention);

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, background: color.canvas }}>
      <MainHeader>
        <IconSession size={15} color={color.textTertiary} />
        <span style={{ fontSize: fs.body, fontWeight: 600, color: color.chromeInk }}>Agents</span>
        <span style={{ fontSize: fs.caption, color: color.textQuaternary }}>全Project · PTYとprocessから得られる事実のみ</span>
        <div style={{ flex: 1 }} />
        <Chip
          onClick={() => (attention ? wb.setScreen('workspace') : undefined)}
          style={{
            background: 'rgba(241,242,246,0.07)',
            border: '1px solid rgba(241,242,246,0.22)',
            color: color.textSecondary,
          }}
        >
          <IconBellFilled size={10} />
          次の注意へ
          <span style={{ color: color.textQuaternary, fontWeight: 400 }}>⌥⇥</span>
        </Chip>
        <Chip
          onClick={() => wb.setOverlay('addAgent')}
          style={{ background: color.panel, border: `1px solid ${line.hairline}`, color: color.textTertiary }}
        >
          Agentを起動 <span style={{ color: color.textQuaternary, fontWeight: 400 }}>⌃⌘N</span>
        </Chip>
      </MainHeader>

      <div
        style={{
          display: 'grid',
          gridTemplateColumns: GRID,
          alignItems: 'center',
          gap: space[3],
          height: 26,
          padding: '0 12px',
          borderBottom: `1px solid ${line.hairline}`,
          color: color.textTertiary,
          fontSize: fs.caption,
          fontWeight: 600,
        }}
      >
        <div />
        <div>AGENT</div>
        <div>PROJECT</div>
        <div>実行CONTEXT</div>
        <div style={{ textAlign: 'right' }}>経過</div>
        <div>最後のSIGNAL</div>
        <div>利用枠</div>
        <div />
      </div>

      <div className="scroll" style={{ flex: 1 }}>
        {wb.sessions.map((s) => (
          <div
            key={s.id}
            style={{
              display: 'grid',
              gridTemplateColumns: GRID,
              alignItems: 'center',
              gap: space[3],
              height: 34,
              padding: s.attention ? '0 14px 0 12px' : '0 14px',
              borderBottom: `1px solid ${line.hairlineFaint}`,
              background: s.attention ? 'rgba(241,242,246,0.05)' : undefined,
              borderLeft: s.attention ? `2px solid ${color.textSecondary}` : undefined,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'center' }}>
              {s.state === 'exit 1' ? (
                <IconClose size={12} color={color.danger} />
              ) : (
                <span
                  style={{
                    width: 7,
                    height: 7,
                    borderRadius: '50%',
                    boxSizing: 'border-box',
                    background: s.attention ? color.attention : s.state === '待機' ? 'transparent' : color.textPrimary,
                    border: s.state === '待機' ? `1px solid ${color.textQuaternary}` : undefined,
                  }}
                />
              )}
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: space[1], minWidth: 0 }}>
              <AgentIcon icon={s.icon} />
              <span style={{ fontWeight: 600, color: s.icon === 'zsh' || s.icon === 'opencode' ? color.textSecondary : color.textPrimary }}>
                {s.agent}
              </span>
              <span style={{ fontSize: fs.caption, color: color.textTertiary }}>{s.state}</span>
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: space[1] }}>
              <span style={{ width: 6, height: 6, borderRadius: radius.control, background: color.textTertiary }} />
              <span style={{ color: color.textSecondary }}>{s.project}</span>
            </div>

            <div>
              {s.worktree ? (
                <Chip
                  style={{
                    background: wash.medium,
                    border: `1px solid ${line.strong}`,
                    color: color.textTertiary,
                  }}
                >
                  <IconBranch size={9} />
                  worktree · {s.worktree}
                </Chip>
              ) : (
                <Chip
                  style={{
                    background: 'rgba(155,161,155,0.12)',
                    border: '1px solid rgba(155,161,155,0.36)',
                    color: color.textTertiary,
                  }}
                >
                  {s.context}
                </Chip>
              )}
            </div>

            <div className="tnum" style={{ textAlign: 'right', color: color.textTertiary }}>
              {s.elapsed}
            </div>

            <div style={{ color: s.signal === '—' ? color.textQuaternary : color.textTertiary, minWidth: 0, overflow: 'hidden', whiteSpace: 'nowrap' }}>
              {s.signal}
              {s.signalTime ? <span style={{ color: color.textQuaternary }}> · {s.signalTime}</span> : null}
            </div>

            <div>
              {s.quotaPercent ? (
                <div style={{ display: 'flex', alignItems: 'center', gap: space[1] }}>
                  <div style={{ flex: 1, height: 4, borderRadius: radius.control, background: color.surfaceActive, overflow: 'hidden' }}>
                    <div
                      style={{
                        width: `${s.quotaPercent}%`,
                        height: '100%',
                        background: s.quotaTight ? color.textSecondary : color.textTertiary,
                      }}
                    />
                  </div>
                  <span className="tnum" style={{ fontSize: fs.caption, color: s.quotaTight ? color.textSecondary : color.textTertiary }}>
                    {s.quotaLabel}
                  </span>
                </div>
              ) : (
                <span className="tnum" style={{ fontSize: fs.caption, color: color.lineNumber }}>
                  —
                </span>
              )}
            </div>

            <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
              <Chip
                onClick={() => (s.action === '再起動' ? wb.restartSession(s.id) : wb.setScreen('workspace'))}
                style={{
                  background: s.action === '移動 ↵' ? color.surfaceActive : 'transparent',
                  color: s.action === '移動 ↵' ? color.textSecondary : color.textQuaternary,
                }}
              >
                {s.action}
              </Chip>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

/**
 * The Agents screen's sidebar panel: the scope the list is read through.
 * The rail itself is the list of sessions, so the panel narrows it rather
 * than repeating it — Project first, because "which project is this agent
 * working in" is the question the rail is answered against.
 */
export function AgentsPanel() {
  const wb = useWorkbench();
  const byProject = new Map<string, number>();
  for (const s of wb.sessions) byProject.set(s.project, (byProject.get(s.project) ?? 0) + 1);
  const byState = new Map<string, number>();
  for (const s of wb.sessions) byState.set(s.state, (byState.get(s.state) ?? 0) + 1);

  const row = (label: string, count: number, tint: string | undefined, selected: boolean) => (
    <div
      key={label}
      className="hoverable"
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: space[2],
        height: 26,
        margin: '0 8px',
        padding: '0 8px',
        borderRadius: radius.card,
        background: selected ? 'rgba(241,242,246,0.08)' : undefined,
        color: selected ? color.chromeInk : color.textTertiary,
        fontSize: fs.caption,
      }}
    >
      <span
        style={{
          width: 6,
          height: 6,
          borderRadius: '50%',
          background: tint ?? 'transparent',
          flexShrink: 0,
        }}
      />
      <span style={{ flex: 1 }}>{label}</span>
      <span style={{ fontSize: fs.caption, color: color.textTertiary }}>{count}</span>
    </div>
  );

  const heading = (text: string) => (
    <div style={{ padding: '8px 16px 4px', fontSize: fs.caption, color: color.textTertiary }}>{text}</div>
  );

  return (
    <div className="scroll" style={{ position: 'absolute', inset: 0, paddingBottom: 8 }}>
      {heading('Project')}
      {row('すべて', wb.sessions.length, undefined, true)}
      {[...byProject].map(([p, n]) => row(p, n, groupColor[wb.groupColors[p] ?? 'gray'], false))}
      {heading('状態')}
      {[...byState].map(([st, n]) => row(st, n, undefined, false))}
    </div>
  );
}

export function SessionsStatus() {
  const wb = useWorkbench();
  const attention = wb.sessions.find((s) => s.attention);
  if (!attention) return null;
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: space[1],
        height: 18,
        padding: '0 8px',
        borderRadius: radius.card,
        background: 'rgba(241,242,246,0.07)',
        border: '1px solid rgba(241,242,246,0.22)',
        color: color.textSecondary,
      }}
    >
      <span style={{ fontWeight: 600 }}>{attention.agent} が入力待ち</span>
      <span style={{ fontSize: fs.caption, color: color.textQuaternary }}>⌥⇥</span>
    </div>
  );
}

/* ── merge graph ──────────────────────────────────────────────────────── */

const GRAPH_GRID = '44px minmax(0,1fr) 96px 90px 84px 74px';

function GraphCell({ kind }: { kind: (typeof commits)[number]['graph'] }) {
  const main = branchColor.main;
  const feature = branchColor['pane-split'];
  const docs = branchColor['docs-update'];
  return (
    <svg width="34" height="32" viewBox="0 0 34 32">
      {kind === 'merge' ? (
        <>
          <path d="M7 0V16" stroke={main} strokeWidth="1.6" fill="none" />
          <path d="M7 16V32" stroke={main} strokeWidth="1.6" fill="none" />
          <circle cx="7" cy="16" r="3.4" fill={color.panel} stroke={main} strokeWidth="1.8" />
          <path d="M17 0C17 8 7 8 7 16" stroke={feature} strokeWidth="1.6" fill="none" />
          <path d="M27 0V32" stroke={docs} strokeWidth="1.6" fill="none" />
        </>
      ) : kind === 'onBranch' ? (
        <>
          <path d="M7 0V32" stroke={main} strokeWidth="1.6" fill="none" />
          <path d="M17 0V32" stroke={feature} strokeWidth="1.6" fill="none" />
          <circle cx="17" cy="16" r="3" fill={feature} />
          <path d="M27 0V32" stroke={docs} strokeWidth="1.6" fill="none" />
        </>
      ) : kind === 'branchOff' ? (
        <>
          <path d="M7 0V32" stroke={main} strokeWidth="1.6" fill="none" />
          <circle cx="7" cy="16" r="3" fill={main} />
          <path d="M7 16C7 8 17 8 17 0" stroke={feature} strokeWidth="1.6" fill="none" />
          <path d="M27 0V32" stroke={docs} strokeWidth="1.6" fill="none" />
        </>
      ) : kind === 'onDocs' ? (
        <>
          <path d="M7 0V32" stroke={main} strokeWidth="1.6" fill="none" />
          <path d="M27 0V32" stroke={docs} strokeWidth="1.6" fill="none" />
          <circle cx="27" cy="16" r="3" fill={docs} />
        </>
      ) : kind === 'branchOffDocs' ? (
        <>
          <path d="M7 0V32" stroke={main} strokeWidth="1.6" fill="none" />
          <circle cx="7" cy="16" r="3" fill={main} />
          <path d="M7 16C7 8 27 8 27 0" stroke={docs} strokeWidth="1.6" fill="none" />
        </>
      ) : (
        <>
          <path d="M7 0V32" stroke={main} strokeWidth="1.6" fill="none" />
          <circle cx="7" cy="16" r="3.4" fill={main} />
        </>
      )}
    </svg>
  );
}

export function MergeGraphMain() {
  const wb = useWorkbench();
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0 }}>
      <MainHeader>
        <SourceControlModeTabs />
        <div style={{ flex: 1 }} />
        <div style={{ display: 'flex', alignItems: 'center', gap: space[3], fontSize: fs.caption, color: color.textTertiary }}>
          {(Object.keys(branchColor) as Array<keyof typeof branchColor>).map((b) => (
            <span key={b} style={{ display: 'inline-flex', alignItems: 'center', gap: space[1] }}>
              <span style={{ width: 7, height: 7, borderRadius: '50%', background: branchColor[b] }} />
              {b}
            </span>
          ))}
        </div>
      </MainHeader>

      <div
        style={{
          height: 30,
          flexShrink: 0,
          display: 'grid',
          gridTemplateColumns: GRAPH_GRID,
          alignItems: 'center',
          padding: '0 16px',
          color: color.textTertiary,
          fontSize: fs.caption,
          fontWeight: 600,
          borderBottom: `1px solid ${line.hairline}`,
        }}
      >
        <span>グラフ</span>
        <span>コミット</span>
        <span>ブランチ</span>
        <span>作者</span>
        <span>日時</span>
        <span>ハッシュ</span>
      </div>

      <div className="scroll" style={{ flex: 1 }}>
        {commits.map((c) => (
          <button
            key={c.hash}
            className="hoverable"
            onClick={() => wb.setScreen('review')}
            style={{
              display: 'grid',
              gridTemplateColumns: GRAPH_GRID,
              alignItems: 'center',
              width: '100%',
              height: 32,
              padding: '0 16px',
              borderBottom: '1px solid rgba(241,242,246,0.06)',
            }}
          >
            <GraphCell kind={c.graph} />
            <span
              style={{
                fontSize: fs.secondary,
                fontWeight: c.graph === 'merge' ? 700 : 400,
                color: c.graph === 'merge' ? color.textPrimary : color.codeBright,
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
                paddingRight: 8,
                textAlign: 'left',
              }}
            >
              {c.subject}
            </span>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: space[1], fontSize: fs.caption, color: color.textTertiary }}>
              <span style={{ width: 6, height: 6, borderRadius: '50%', background: branchColor[c.branch], flexShrink: 0 }} />
              {c.branch}
            </span>
            <span style={{ fontSize: fs.caption, color: color.textTertiary }}>{c.author}</span>
            <span style={{ fontSize: fs.caption, color: color.textQuaternary }}>{c.when}</span>
            <span className="cl" style={{ fontSize: fs.caption, color: color.textQuaternary }}>
              {c.hash}
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}
