import { branchColor, commits, type Session } from '../data';
import {
  IconBellFilled,
  IconBranch,
  IconBrackets,
  IconClose,
  IconCodex,
  IconInfo,
  IconSession,
  IconSparkle,
  IconTerminalPrompt,
} from '../icons';
import { useWorkbench } from '../store';
import { Chip, MainHeader } from '../chrome';
import { color, line, wash } from '../tokens';

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
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0 }}>
      <MainHeader>
        <IconSession size={15} color={color.textTertiary} />
        <span style={{ fontSize: 13, fontWeight: 600 }}>セッション</span>
        <span style={{ fontSize: 10, color: color.textQuaternary }}>全Project · PTYとprocessから得られる事実のみ</span>
        <div style={{ flex: 1 }} />
        <Chip
          onClick={() => (attention ? wb.setScreen('workspace') : undefined)}
          style={{
            background: 'rgba(242,244,238,0.07)',
            border: '1px solid rgba(242,244,238,0.22)',
            color: color.textSecondary,
          }}
        >
          <IconBellFilled size={10} />
          次の注意へ
          <span style={{ color: color.textQuaternary, fontWeight: 500 }}>⌥⇥</span>
        </Chip>
        <Chip
          onClick={() => wb.setOverlay('addAgent')}
          style={{ background: color.panel, border: `1px solid ${line.hairline}`, color: color.textTertiary }}
        >
          Agentを起動 <span style={{ color: color.textMuted, fontWeight: 500 }}>⌃⌘N</span>
        </Chip>
      </MainHeader>

      <div
        style={{
          display: 'grid',
          gridTemplateColumns: GRID,
          alignItems: 'center',
          gap: 12,
          height: 26,
          padding: '0 14px',
          background: color.panelDeep,
          borderBottom: `1px solid ${line.hairline}`,
          color: color.textMuted,
          fontSize: 9,
          fontWeight: 700,
          letterSpacing: '0.04em',
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
              gap: 12,
              height: 34,
              padding: s.attention ? '0 14px 0 12px' : '0 14px',
              borderBottom: `1px solid ${line.hairlineFaint}`,
              background: s.attention ? 'rgba(242,244,238,0.05)' : undefined,
              borderLeft: s.attention ? `2px solid ${color.textSecondary}` : undefined,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'center' }}>
              {s.attention ? (
                <IconBellFilled size={13} color={color.textPrimary} />
              ) : s.state === 'exit 1' ? (
                <IconClose size={12} color={color.textTertiary} />
              ) : (
                <span
                  style={{
                    width: 7,
                    height: 7,
                    borderRadius: '50%',
                    background: s.state === '待機' ? color.textQuaternary : color.textSecondary,
                  }}
                />
              )}
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: 7, minWidth: 0 }}>
              <AgentIcon icon={s.icon} />
              <span style={{ fontWeight: 600, color: s.icon === 'zsh' || s.icon === 'opencode' ? color.textSecondary : color.textPrimary }}>
                {s.agent}
              </span>
              <Chip
                style={{
                  background:
                    s.state === '入力待ち'
                      ? wash.strongest
                      : s.state === '待機'
                        ? 'rgba(155,161,155,0.12)'
                        : wash.selected,
                  color: s.state === '待機' ? color.textTertiary : s.state === 'exit 1' ? color.textPrimary : color.textSecondary,
                }}
              >
                {s.state}
              </Chip>
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
              <span style={{ width: 6, height: 6, borderRadius: 2, background: color.textTertiary }} />
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

            <div className="cl" style={{ textAlign: 'right', color: color.textTertiary }}>
              {s.elapsed}
            </div>

            <div style={{ color: s.signal === '—' ? color.textMuted : color.textTertiary, minWidth: 0, overflow: 'hidden', whiteSpace: 'nowrap' }}>
              {s.signal}
              {s.signalTime ? <span style={{ color: color.textMuted }}> · {s.signalTime}</span> : null}
            </div>

            <div>
              {s.quotaPercent ? (
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <div style={{ flex: 1, height: 4, borderRadius: 2, background: color.surfaceActive, overflow: 'hidden' }}>
                    <div
                      style={{
                        width: `${s.quotaPercent}%`,
                        height: '100%',
                        background: s.quotaTight ? color.textSecondary : color.textTertiary,
                      }}
                    />
                  </div>
                  <span className="cl" style={{ fontSize: 10, color: s.quotaTight ? color.textSecondary : color.textTertiary }}>
                    {s.quotaLabel}
                  </span>
                </div>
              ) : (
                <span className="cl" style={{ fontSize: 10, color: color.lineNumber }}>
                  —
                </span>
              )}
            </div>

            <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
              <Chip
                onClick={() => (s.action === '再起動' ? wb.restartSession(s.id) : wb.setScreen('workspace'))}
                style={{
                  background: s.action === '移動 ↵' ? color.surfaceActive : 'transparent',
                  color: s.action === '移動 ↵' ? color.textSecondary : color.textMuted,
                }}
              >
                {s.action}
              </Chip>
            </div>
          </div>
        ))}
        <div style={{ background: color.canvas, height: 12 }} />
      </div>

      <div style={{ flexShrink: 0, padding: '12px 16px', background: color.panelDeep, borderTop: `1px solid ${line.hairline}` }}>
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 9, color: color.textQuaternary, fontSize: 10, lineHeight: '15px' }}>
          <IconInfo size={13} color={color.textTertiary} style={{ marginTop: 1 }} />
          <span>
            ここに出す値は全て <b style={{ color: color.textTertiary }}>PTYとprocessから直接得られる事実</b> である。state
            は{' '}
            <span className="cl" style={{ color: color.textTertiary }}>
              TerminalSession.State
            </span>
            、signalはbell / exit code / 公式hook、実行contextは起動時に選ばれたcwd。TUIの内容は解釈しない。
          </span>
        </div>
      </div>
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
        gap: 6,
        height: 18,
        padding: '0 8px',
        borderRadius: 9,
        background: 'rgba(242,244,238,0.07)',
        border: '1px solid rgba(242,244,238,0.22)',
        color: color.textSecondary,
      }}
    >
      <span style={{ fontWeight: 600 }}>{attention.agent} が入力待ち</span>
      <span style={{ fontSize: 9, color: color.textQuaternary }}>⌥⇥</span>
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
        <span style={{ fontSize: 13, fontWeight: 600 }}>マージグラフ</span>
        <div style={{ flex: 1 }} />
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, fontSize: 10, color: color.textTertiary }}>
          {(Object.keys(branchColor) as Array<keyof typeof branchColor>).map((b) => (
            <span key={b} style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
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
          color: color.textMuted,
          fontSize: 9,
          fontWeight: 700,
          letterSpacing: '0.04em',
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
              borderBottom: '1px solid rgba(242,244,238,0.06)',
            }}
          >
            <GraphCell kind={c.graph} />
            <span
              style={{
                fontSize: 11.5,
                fontWeight: c.graph === 'merge' ? 700 : 400,
                color: c.graph === 'merge' ? color.textPrimary : color.codeBright,
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
                paddingRight: 10,
                textAlign: 'left',
              }}
            >
              {c.subject}
            </span>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 9.5, color: color.textTertiary }}>
              <span style={{ width: 6, height: 6, borderRadius: '50%', background: branchColor[c.branch], flexShrink: 0 }} />
              {c.branch}
            </span>
            <span style={{ fontSize: 10.5, color: color.textTertiary }}>{c.author}</span>
            <span style={{ fontSize: 10, color: color.textMuted }}>{c.when}</span>
            <span className="cl" style={{ fontSize: 10, color: color.textMuted }}>
              {c.hash}
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}
