import { useEffect, useMemo, useRef, useState } from 'react';

import { projects, type Session } from '../data';
import {
  IconArrowRight,
  IconBell,
  IconBellOff,
  IconBrackets,
  IconChevron,
  IconChevronLeft,
  IconClose,
  IconCodex,
  IconEllipsis,
  IconEmptySession,
  IconGear,
  IconGrid,
  IconHost,
  IconInfo,
  IconQR,
  IconSession,
  IconSparkle,
} from '../icons';
import { artboards, type ArtboardKey } from '../mobile-artboards';
import { useWorkbench } from '../store';
import { color, line, wash } from '../tokens';

type Tab = '概要' | 'セッション' | 'アクティビティ' | '設定';
type Push = { kind: 'terminal'; sessionId: string } | { kind: 'pairing' } | null;

// `?review=1` reveals a Live/Design toggle so each mobile screen can be checked
// against its own artboard on the design canvas. It has no effect on the
// product route. The snapshots come from src/mobile-artboards.ts, which is
// generated from the canvas — never transcribed.
const reviewMode = typeof window !== 'undefined' && window.location.search.includes('review=1');

// The host record the canvas draws on MobileHome / MobileSettings / MobilePairing.
// The endpoint is allowed to change; the fingerprint is the pinned identity.
const HOST = {
  name: 'daiki-mbp16',
  route: 'Tailscale Serve',
  endpoint: 'daiki-mbp16.ts.net:8443',
  fingerprint: '7f3a 91c4 2e8b d05a',
  fingerprintFull: ['7f3a 91c4 2e8b d05a', '4c71 e6f9 38ad b2c0'],
  protocol: '1.2',
};

// Scopes default to deny; what is withheld has to be as visible as what is
// granted, and none of it can be raised from the phone.
const SCOPES = [
  { id: 'view', granted: true },
  { id: 'write_terminal', granted: true },
  { id: 'signal', granted: true },
  { id: 'terminate', granted: false },
  { id: 'spawn_session', granted: false },
  { id: 'manage_devices', granted: false },
] as const;

/* ---------------------------------------------------------------- primitives
   Values come from the MOBILE section of the Tokens artboard: 44px touch
   targets, card radius 10, button/field radius 8, 16px gutter. */

const TOUCH = 44;
const R_CARD = 10;
const R_BUTTON = 8;

function Eyebrow({ children, style }: { children: React.ReactNode; style?: React.CSSProperties }) {
  return (
    <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: '0.06em', color: color.textQuaternary, ...style }}>
      {children}
    </div>
  );
}

function Section({ children }: { children: React.ReactNode }) {
  return <Eyebrow style={{ margin: '0 2px 8px 2px' }}>{children}</Eyebrow>;
}

function Card({
  children,
  style,
  prominent,
  onClick,
}: {
  children: React.ReactNode;
  style?: React.CSSProperties;
  prominent?: boolean;
  onClick?: () => void;
}) {
  return (
    <div
      onClick={onClick}
      style={{
        background: prominent ? wash.soft : color.panel,
        border: `1px solid ${prominent ? 'rgba(241,242,246,0.24)' : line.hairline}`,
        borderRadius: R_CARD,
        textAlign: 'left',
        ...style,
      }}
    >
      {children}
    </div>
  );
}

function PrimaryButton({
  children,
  onClick,
  style,
}: {
  children: React.ReactNode;
  onClick?: () => void;
  style?: React.CSSProperties;
}) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 8,
        height: TOUCH,
        borderRadius: R_BUTTON,
        background: wash.strong,
        border: `1px solid ${line.stronger}`,
        color: color.textPrimary,
        fontSize: 14,
        fontWeight: 600,
        ...style,
      }}
    >
      {children}
    </button>
  );
}

// The destructive control from the Tokens artboard: weight, not colour.
function DestructiveButton({ children, onClick }: { children: React.ReactNode; onClick?: () => void }) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'flex',
        alignItems: 'center',
        height: 28,
        padding: '0 11px',
        borderRadius: 4,
        background: wash.soft,
        border: '1px solid rgba(241,242,246,0.24)',
        color: color.textPrimary,
        fontSize: 11,
        fontWeight: 700,
        flexShrink: 0,
      }}
    >
      {children}
    </button>
  );
}

function StatusPill({ label }: { label: string }) {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 5,
        height: 26,
        padding: '0 9px',
        borderRadius: 13,
        background: 'rgba(241,242,246,0.08)',
        border: '1px solid rgba(241,242,246,0.24)',
      }}
    >
      <span style={{ width: 6, height: 6, borderRadius: '50%', background: color.textSecondary }} />
      <span style={{ fontSize: 11, fontWeight: 600, color: color.textPrimary }}>{label}</span>
    </div>
  );
}

function StateBadge({ label }: { label: string }) {
  return (
    <span
      style={{
        fontSize: 11,
        fontWeight: 600,
        color: color.textPrimary,
        background: wash.strongest,
        borderRadius: 4,
        padding: '3px 7px',
      }}
    >
      {label}
    </span>
  );
}

function ScopeChip({ id, granted }: { id: string; granted: boolean }) {
  return (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        height: 22,
        padding: '0 8px',
        borderRadius: 4,
        fontSize: 11,
        fontWeight: 600,
        background: granted ? wash.strongest : 'transparent',
        border: granted ? `1px solid ${line.stronger}` : `1px dashed ${line.strong}`,
        color: granted ? color.textPrimary : color.textQuaternary,
      }}
    >
      {id}
    </span>
  );
}

// The switch from the Settings artboard, unchanged: grayscale, no accent.
function Switch({ on, onChange }: { on: boolean; onChange: () => void }) {
  return (
    <button
      onClick={onChange}
      style={{
        position: 'relative',
        width: 34,
        height: 20,
        borderRadius: 10,
        background: on ? '#6b7280' : color.divider,
        flexShrink: 0,
      }}
    >
      <span
        style={{
          position: 'absolute',
          top: 3,
          left: on ? 17 : 3,
          width: 14,
          height: 14,
          borderRadius: '50%',
          background: on ? color.textPrimary : color.textSecondary,
          transition: 'left 120ms ease',
        }}
      />
    </button>
  );
}

// The inline banner from the Tokens artboard CONTROLS block.
function Banner({ children, style }: { children: React.ReactNode; style?: React.CSSProperties }) {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'flex-start',
        gap: 8,
        padding: '10px 11px',
        borderRadius: R_BUTTON,
        background: wash.soft,
        border: '1px solid rgba(241,242,246,0.22)',
        color: color.textSecondary,
        fontSize: 11,
        lineHeight: '16px',
        ...style,
      }}
    >
      <IconInfo size={14} style={{ marginTop: 1 }} />
      <span>{children}</span>
    </div>
  );
}

function ProjectDot() {
  return <span style={{ width: 7, height: 7, borderRadius: 2, background: color.textTertiary, flexShrink: 0 }} />;
}

function Dim({ children }: { children: React.ReactNode }) {
  return <span style={{ color: color.divider }}>{children}</span>;
}

// A row inside a card: the hairline belongs to every row but the first.
function Row({
  children,
  first,
  onClick,
  style,
}: {
  children: React.ReactNode;
  first?: boolean;
  onClick?: () => void;
  style?: React.CSSProperties;
}) {
  return (
    <div
      onClick={onClick}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        minHeight: 48,
        padding: '8px 0',
        borderTop: first ? undefined : `1px solid ${line.hairlineFaint}`,
        ...style,
      }}
    >
      {children}
    </div>
  );
}

function KV({ label, value, extra, first }: { label: string; value: string; extra?: React.ReactNode; first?: boolean }) {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'baseline',
        gap: 8,
        padding: first ? '0 0 7px 0' : '7px 0',
        borderTop: first ? undefined : `1px solid ${line.hairlineFaint}`,
      }}
    >
      <span style={{ fontSize: 11, color: color.textQuaternary, width: 92, flexShrink: 0 }}>{label}</span>
      <span className="cl" style={{ fontSize: 11, color: color.textSecondary }}>
        {value}
      </span>
      {extra ? (
        <>
          <div style={{ flex: 1 }} />
          {extra}
        </>
      ) : null}
    </div>
  );
}

function Tag({ children }: { children: React.ReactNode }) {
  return (
    <span
      style={{
        fontSize: 10,
        fontWeight: 600,
        color: color.textTertiary,
        background: wash.medium,
        border: `1px solid ${line.strong}`,
        borderRadius: 4,
        padding: '2px 6px',
        flexShrink: 0,
      }}
    >
      {children}
    </span>
  );
}

// The EMPTY STATE component the Tokens artboard defines, reused verbatim.
function EmptyState({ title, note }: { title: string; note: string }) {
  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 7,
        padding: '16px 12px',
        borderRadius: 4,
        background: color.canvas,
      }}
    >
      <IconEmptySession size={24} color={color.divider} />
      <span style={{ fontSize: 12, fontWeight: 600, color: color.textSecondary }}>{title}</span>
      <span
        style={{ fontSize: 10, color: color.textQuaternary, textAlign: 'center', maxWidth: 260, lineHeight: '15px' }}
      >
        {note}
      </span>
    </div>
  );
}

function AgentGlyph({ icon, size = 14, tone }: { icon: Session['icon']; size?: number; tone?: string }) {
  const c = tone ?? color.textTertiary;
  if (icon === 'codex') return <IconCodex size={size} color={c} />;
  if (icon === 'claude') return <IconSparkle size={size} color={c} />;
  if (icon === 'opencode') return <IconBrackets size={size} color={c} />;
  return <span style={{ width: 8, height: 8, borderRadius: '50%', background: color.textQuaternary, flexShrink: 0 }} />;
}

/* ------------------------------------------------------------------- shell */

function StatusSpacer() {
  // no fake status bar : this space belongs to the real one
  return <div style={{ height: 54, flexShrink: 0 }} />;
}

function TabHeader({ title, sub, right }: { title: string; sub: React.ReactNode; right?: React.ReactNode }) {
  return (
    <div style={{ flexShrink: 0, padding: '0 16px 12px 16px' }}>
      <Eyebrow style={{ marginBottom: 4 }}>PRIVATE NETWORK</Eyebrow>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 24, fontWeight: 700, letterSpacing: '-0.02em' }}>{title}</span>
        <div style={{ flex: 1 }} />
        {right ?? <StatusPill label="接続中" />}
      </div>
      <div style={{ marginTop: 3, fontSize: 12, color: color.textQuaternary }}>{sub}</div>
    </div>
  );
}

function Footnote({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        flexShrink: 0,
        padding: '10px 16px 8px 16px',
        color: color.textQuaternary,
        fontSize: 11,
        lineHeight: '16px',
      }}
    >
      {children}
    </div>
  );
}

const TAB_ICONS: Record<Tab, React.ReactNode> = {
  概要: <IconGrid size={22} />,
  セッション: <IconSession size={22} />,
  アクティビティ: <IconBell size={22} />,
  設定: <IconGear size={22} />,
};

function TabBar({ tab, onSelect }: { tab: Tab; onSelect: (t: Tab) => void }) {
  return (
    <div
      style={{
        minHeight: 78,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'flex-start',
        paddingTop: 8,
        paddingBottom: 'env(safe-area-inset-bottom)',
        backgroundColor: color.chrome,
        borderTop: `1px solid ${line.chrome}`,
      }}
    >
      {(Object.keys(TAB_ICONS) as Tab[]).map((name) => {
        const on = tab === name;
        return (
          <button
            key={name}
            onClick={() => onSelect(name)}
            style={{
              flex: 1,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 3,
              color: on ? color.textPrimary : color.textQuaternary,
            }}
          >
            {TAB_ICONS[name]}
            <span style={{ fontSize: 10, fontWeight: on ? 600 : 400 }}>{name}</span>
          </button>
        );
      })}
    </div>
  );
}

/* -------------------------------------------------------------- 概要 screen */

function SessionSummaryCard({ session, onOpen }: { session: Session; onOpen: () => void }) {
  return (
    <Card prominent style={{ padding: 13, marginBottom: 12 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <AgentGlyph icon={session.icon} size={15} tone={color.textPrimary} />
        <span style={{ fontSize: 15, fontWeight: 600, flex: 1 }}>{session.agent}</span>
        <StateBadge label={session.state} />
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 7, fontSize: 12, color: color.textTertiary }}>
        <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
          <ProjectDot />
          {session.project}
        </span>
        <Dim>·</Dim>
        <span>{session.worktree ?? session.context}</span>
        <Dim>·</Dim>
        <span className="cl">{session.signalTime || session.elapsed}</span>
      </div>
      <PrimaryButton onClick={onOpen} style={{ width: '100%', marginTop: 10 }}>
        ターミナルを開く
      </PrimaryButton>
    </Card>
  );
}

function HomeScreen({ onOpenTerminal }: { onOpenTerminal: (id: string) => void }) {
  const wb = useWorkbench();
  const attention = wb.sessions.filter((s) => s.attention);

  return (
    <>
      <Card style={{ padding: 13, marginBottom: 12 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10 }}>
          <IconHost size={15} color={color.textSecondary} />
          <span style={{ fontSize: 15, fontWeight: 600 }}>{HOST.name}</span>
          <div style={{ flex: 1 }} />
          <span style={{ fontSize: 11, fontWeight: 600, color: color.textTertiary }}>{HOST.route}</span>
        </div>
        <KV label="endpoint" value={HOST.endpoint} />
        <KV label="fingerprint" value={HOST.fingerprint} extra={<Tag>固定済み</Tag>} />
        <KV
          label="protocol"
          value={HOST.protocol}
          extra={<span style={{ fontSize: 11, color: color.textQuaternary }}>この端末は view · 入力</span>}
        />
      </Card>

      <Section>要対応</Section>
      {attention.length ? (
        attention.map((s) => <SessionSummaryCard key={s.id} session={s} onOpen={() => onOpenTerminal(s.id)} />)
      ) : (
        <div style={{ marginBottom: 12 }}>
          <EmptyState
            title="返すものはありません"
            note="どのsessionも入力を待っていません。呼ばれたらアクティビティに出ます。"
          />
        </div>
      )}

      <Section>PROJECT</Section>
      <Card style={{ padding: '4px 13px' }}>
        {projects.map((p, i) => {
          const list = wb.sessions.filter((s) => s.project === p);
          const waiting = list.filter((s) => s.attention).length;
          const exited = list.filter((s) => s.state === 'exit 1').length;
          return (
            <div
              key={p}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 8,
                height: 42,
                borderTop: i === 0 ? undefined : `1px solid ${line.hairlineFaint}`,
              }}
            >
              <ProjectDot />
              <span style={{ fontSize: 14, fontWeight: 600, flex: 1, color: exited ? color.textSecondary : undefined }}>
                {p}
              </span>
              {waiting ? <StateBadge label={String(waiting)} /> : null}
              <span style={{ fontSize: 12, color: color.textQuaternary }}>
                {list.length} セッション{exited ? ' · exit 1' : ''}
              </span>
            </div>
          );
        })}
      </Card>
    </>
  );
}

/* --------------------------------------------------------- セッション screen */

function SessionRow({ session, onOpen }: { session: Session; onOpen: () => void }) {
  const exited = session.state === 'exit 1';
  const idle = session.icon === 'zsh';
  return (
    <Card onClick={onOpen} style={{ padding: '12px 13px', marginBottom: 8, cursor: 'pointer' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <AgentGlyph icon={session.icon} />
        <span
          style={{
            fontSize: 14,
            fontWeight: 600,
            flex: 1,
            color: exited || idle ? color.textSecondary : color.textPrimary,
          }}
        >
          {session.agent}
        </span>
        {exited ? (
          <>
            <IconClose size={13} color={color.textTertiary} />
            <span style={{ fontSize: 11, fontWeight: 600, color: color.textPrimary }}>exit 1</span>
          </>
        ) : (
          <>
            {idle ? null : (
              <span
                style={{ width: 8, height: 8, borderRadius: '50%', background: color.textSecondary, flexShrink: 0 }}
              />
            )}
            <span className="cl" style={{ fontSize: 12, color: color.textQuaternary }}>
              {session.elapsed}
            </span>
          </>
        )}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginTop: 7, flexWrap: 'wrap' }}>
        <span style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 12, color: color.textTertiary }}>
          <ProjectDot />
          {session.project}
        </span>
        {session.worktree ? (
          <Tag>{session.worktree}</Tag>
        ) : (
          <span style={{ fontSize: 12, color: color.textQuaternary }}>
            {exited ? session.signalTime : session.context}
          </span>
        )}
      </div>
    </Card>
  );
}

function SessionsScreen({
  onOpenTerminal,
  muted,
  onToggleMute,
}: {
  onOpenTerminal: (id: string) => void;
  muted: boolean;
  onToggleMute: () => void;
}) {
  const wb = useWorkbench();
  const lead = wb.sessions[0];
  // The order the artboard draws: live agents, then whatever exited, then the
  // plain shell. A shell that has been idle for hours should not sit above an
  // agent that is still working.
  const rank = (s: Session) => (s.icon === 'zsh' ? 2 : s.state === 'exit 1' ? 1 : 0);
  const rest = wb.sessions.slice(1).slice().sort((a, b) => rank(a) - rank(b));

  return (
    <>
      <Card prominent style={{ padding: 13, marginBottom: 12 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
          <IconCodex size={15} color={color.textPrimary} />
          <span style={{ fontSize: 15, fontWeight: 600, color: color.textPrimary }}>{lead.agent}</span>
          <StateBadge label={wb.awaitingApproval ? '入力待ち' : '実行中'} />
        </div>
        <div
          style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10, fontSize: 12, color: color.textTertiary }}
        >
          <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
            <ProjectDot />
            {lead.project}
          </span>
          <Dim>·</Dim>
          <span>{lead.context}</span>
          <Dim>·</Dim>
          <span className="cl">{lead.elapsed}</span>
        </div>
        <div
          className="cl"
          style={{
            padding: 10,
            borderRadius: 7,
            background: color.canvas,
            fontSize: 11,
            lineHeight: '17px',
            color: color.code,
            whiteSpace: 'pre',
            overflowX: 'auto',
          }}
        >
          <div>
            <span style={{ color: color.attention }}>crates/clair-ptyhost/src/pty.rs</span>
          </div>
          <div>
            {'  '}
            <span style={{ color: color.success }}>+18</span> <span style={{ color: color.danger }}>-4</span>
          </div>
          {wb.awaitingApproval ? (
            <div>
              Apply this change? <span style={{ color: color.attention }}>[y/N]</span>{' '}
              <span className="caret" style={{ background: color.code, color: '#121416' }}>
                {' '}
              </span>
            </div>
          ) : (
            <div>
              <span style={{ color: color.success }}>applied</span> · pty.rs
            </div>
          )}
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
          <PrimaryButton onClick={() => onOpenTerminal(lead.id)} style={{ flex: 1 }}>
            ターミナルを開く
          </PrimaryButton>
          <button
            onClick={onToggleMute}
            aria-label={muted ? '通知を戻す' : '通知を止める'}
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: 52,
              height: TOUCH,
              borderRadius: R_BUTTON,
              background: color.panel,
              border: `1px solid ${line.hairline}`,
              color: color.textTertiary,
            }}
          >
            {muted ? <IconBellOff size={18} /> : <IconBell size={18} />}
          </button>
        </div>
      </Card>

      <Section>その他のセッション</Section>
      {rest.map((s) => (
        <SessionRow key={s.id} session={s} onOpen={() => onOpenTerminal(s.id)} />
      ))}
    </>
  );
}

/* ------------------------------------------------- アクティビティ screen */

function ActivityScreen({ onOpenTerminal }: { onOpenTerminal: (id: string) => void }) {
  const wb = useWorkbench();
  const attention = wb.sessions.filter((s) => s.attention);
  // Everything that has signalled, newest first — identity and time only.
  const history = wb.sessions
    .filter((s) => !s.attention && s.signalTime)
    .sort((a, b) => b.signalTime.localeCompare(a.signalTime));

  return (
    <>
      <Section>要対応 — {attention.length}件</Section>
      {attention.length ? (
        attention.map((s) => <SessionSummaryCard key={s.id} session={s} onOpen={() => onOpenTerminal(s.id)} />)
      ) : (
        <div style={{ marginBottom: 12 }}>
          <EmptyState title="返すものはありません" note="呼ばれたセッションがあればここに出ます。" />
        </div>
      )}

      <Section>これまで</Section>
      <Card style={{ padding: '2px 13px' }}>
        {history.map((s, i) => (
          <div
            key={s.id}
            onClick={() => onOpenTerminal(s.id)}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 9,
              height: 52,
              borderTop: i === 0 ? undefined : `1px solid ${line.hairlineFaint}`,
            }}
          >
            <AgentGlyph icon={s.icon} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: s.state === 'exit 1' ? color.textSecondary : undefined }}>
                {s.agent}
              </div>
              <div
                style={{
                  fontSize: 11,
                  color: color.textTertiary,
                  marginTop: 2,
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
              >
                {s.signal} · {s.project}
                {s.worktree ? ` / ${s.worktree}` : ''}
              </div>
            </div>
            <span className="cl" style={{ fontSize: 11, color: color.textQuaternary, flexShrink: 0 }}>
              {s.signalTime}
            </span>
          </div>
        ))}
      </Card>

      <Banner style={{ marginTop: 12 }}>
        通知はどのsessionが呼んでいるかだけを運ぶ。terminalの内容・prompt・cwdは含めない。
      </Banner>
    </>
  );
}

/* ------------------------------------------------------------- 設定 screen */

type Device = { id: string; name: string; scopes: string; since: string; current?: boolean };

function SettingsScreen({
  devices,
  onRevoke,
  onPair,
  refreshOnResume,
  onToggleResume,
}: {
  devices: Device[];
  onRevoke: (id: string) => void;
  onPair: () => void;
  refreshOnResume: boolean;
  onToggleResume: () => void;
}) {
  return (
    <>
      <Section>この端末の権限</Section>
      <Card style={{ padding: '12px 13px', marginBottom: 12 }}>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
          {SCOPES.map((s) => (
            <ScopeChip key={s.id} id={s.id} granted={s.granted} />
          ))}
        </div>
        <div style={{ marginTop: 10, fontSize: 11, lineHeight: '16px', color: color.textQuaternary }}>
          破線は未付与。付与はMac側の操作でしか増やせない。
        </div>
      </Card>

      <Section>接続</Section>
      <Card style={{ padding: '2px 13px', marginBottom: 12 }}>
        <Row first>
          <span style={{ fontSize: 13, flex: 1 }}>経路</span>
          <span style={{ fontSize: 12, color: color.textTertiary }}>{HOST.route}</span>
          <IconChevron size={13} color={color.textQuaternary} />
        </Row>
        <Row>
          <span style={{ fontSize: 13, flex: 1 }}>host fingerprint</span>
          <span className="cl" style={{ fontSize: 11, color: color.textTertiary }}>
            7f3a…d05a
          </span>
          <Tag>固定済み</Tag>
        </Row>
        <Row>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13 }}>前面復帰で再取得</div>
            <div style={{ fontSize: 11, color: color.textQuaternary, marginTop: 2 }}>
              アプリに戻ったとき要対応を取り直す
            </div>
          </div>
          <Switch on={refreshOnResume} onChange={onToggleResume} />
        </Row>
      </Card>

      <Section>ペアリング済みの端末</Section>
      <Card style={{ padding: '2px 13px', marginBottom: 12 }}>
        {devices.map((d, i) => (
          <Row key={d.id} first={i === 0}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: d.current ? color.textPrimary : color.textSecondary }}>
                {d.name}
                {d.current ? <span style={{ fontWeight: 400, color: color.textQuaternary }}> · この端末</span> : null}
              </div>
              <div style={{ fontSize: 11, color: color.textQuaternary, marginTop: 2 }}>
                {d.scopes} — {d.since}
              </div>
            </div>
            {d.current ? null : <DestructiveButton onClick={() => onRevoke(d.id)}>取り消す</DestructiveButton>}
          </Row>
        ))}
      </Card>

      <PrimaryButton onClick={onPair} style={{ width: '100%' }}>
        <IconQR size={16} />
        端末を追加
      </PrimaryButton>
    </>
  );
}

/* ------------------------------------------------------- ターミナル (push) */

const TONE: Record<string, string> = {
  add: color.success,
  del: color.danger,
  dim: color.codeComment,
  accent: color.attention,
};

function TerminalScreen({ session, onBack }: { session: Session; onBack: () => void }) {
  const wb = useWorkbench();
  const [value, setValue] = useState('');
  const [history, setHistory] = useState<string[]>([]);
  const [at, setAt] = useState(-1);
  const bodyRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = bodyRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [wb.terminal]);

  const send = (text: string) => {
    wb.runTerminal(text);
    if (text.trim()) setHistory((h) => [text, ...h]);
    setValue('');
    setAt(-1);
  };

  const recall = (delta: number) => {
    const next = Math.min(history.length - 1, Math.max(-1, at + delta));
    setAt(next);
    setValue(next < 0 ? '' : history[next]);
  };

  const key = (label: string, onPress: () => void, style?: React.CSSProperties) => (
    <button
      key={label}
      onClick={onPress}
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        height: 32,
        padding: '0 11px',
        borderRadius: 6,
        background: color.panel,
        border: `1px solid ${line.hairline}`,
        color: color.textSecondary,
        fontSize: 12,
        fontWeight: 600,
        flexShrink: 0,
        ...style,
      }}
    >
      {label}
    </button>
  );

  return (
    <>
      <StatusSpacer />

      {/* push screen : a back bar replaces the tab bar, this is not a 5th tab */}
      <div
        style={{
          height: TOUCH,
          flexShrink: 0,
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          padding: '0 12px 0 8px',
          backgroundColor: color.chrome,
          borderBottom: `1px solid ${line.chrome}`,
        }}
      >
        <button onClick={onBack} style={{ display: 'flex', alignItems: 'center', gap: 2, color: color.textSecondary }}>
          <IconChevronLeft size={20} />
          <span style={{ fontSize: 14 }}>セッション</span>
        </button>
        <div style={{ flex: 1 }} />
        <AgentGlyph icon={session.icon} size={15} tone={color.textPrimary} />
        <span style={{ fontSize: 14, fontWeight: 600 }}>{session.agent}</span>
        <div style={{ flex: 1 }} />
        <IconEllipsis size={18} color={color.textTertiary} />
      </div>

      <div
        style={{
          flexShrink: 0,
          display: 'flex',
          alignItems: 'center',
          gap: 7,
          padding: '8px 16px',
          fontSize: 11,
          color: color.textTertiary,
          borderBottom: `1px solid ${line.hairlineFaint}`,
        }}
      >
        <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
          <ProjectDot />
          {session.project}
        </span>
        <Dim>·</Dim>
        <span>{session.worktree ?? session.context}</span>
        <span style={{ flex: 1 }} />
        <span className="cl" style={{ color: color.textQuaternary }}>
          epoch 7 · +1.84 MB
        </span>
      </div>

      {/* raw PTY bytes : no screen scraping, no semantic parsing */}
      <div
        ref={bodyRef}
        className="cl scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '10px 14px',
          fontSize: 11.5,
          lineHeight: '18px',
          color: color.code,
          whiteSpace: 'pre-wrap',
          wordBreak: 'break-word',
          background: color.canvas,
        }}
      >
        {/* out-of-range cursor is an explicit gap, never a silent continuation */}
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            margin: '6px 0',
            color: color.textQuaternary,
            fontSize: 10.5,
          }}
        >
          <span style={{ flex: 1, height: 1, background: line.hairline }} />
          <span>欠落 2.3 KB · 保持範囲外</span>
          <span style={{ flex: 1, height: 1, background: line.hairline }} />
        </div>
        {wb.terminal.map((l, i) => (
          <div key={i} style={{ color: l.tone ? TONE[l.tone] : undefined }}>
            {l.text || ' '}
          </div>
        ))}
        {wb.awaitingApproval ? (
          <div>
            Apply this change? <span style={{ color: color.attention }}>[y/N]</span>{' '}
            <span className="caret" style={{ background: color.code, color: '#121416' }}>
              {' '}
            </span>
          </div>
        ) : null}
      </div>

      {/* viewport is client-local : reading on the phone never resizes the PTY */}
      <div
        style={{
          flexShrink: 0,
          padding: '7px 16px',
          fontSize: 10.5,
          color: color.textQuaternary,
          borderTop: `1px solid ${line.hairlineFaint}`,
        }}
      >
        表示幅はこの端末だけのもの。PTYのcolumnsは変えない。
      </div>

      <div
        style={{
          flexShrink: 0,
          backgroundColor: color.chrome,
          borderTop: `1px solid ${line.chrome}`,
          padding: '9px 12px 10px 12px',
          paddingBottom: 'calc(10px + env(safe-area-inset-bottom))',
        }}
      >
        <div style={{ display: 'flex', gap: 7, marginBottom: 9 }}>
          {key('esc', () => setValue(''))}
          {key('tab', () => setValue((v) => `${v}  `))}
          {key('^C', () => send('N'))}
          <div style={{ flex: 1 }} />
          {key('↑', () => recall(1), { width: 40, padding: 0 })}
          {key('↓', () => recall(-1), { width: 40, padding: 0 })}
        </div>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            send(value);
          }}
          style={{ display: 'flex', alignItems: 'center', gap: 8 }}
        >
          <input
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder={wb.awaitingApproval ? 'y / N' : 'コマンドを送る'}
            autoComplete="off"
            autoCapitalize="off"
            spellCheck={false}
            className="cl"
            style={{
              flex: 1,
              height: TOUCH,
              padding: '0 12px',
              borderRadius: R_BUTTON,
              background: color.panel,
              border: `1px solid ${line.strong}`,
              color: color.textPrimary,
              fontSize: 13,
              outline: 'none',
            }}
          />
          <button
            type="submit"
            aria-label="送信"
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: 52,
              height: TOUCH,
              borderRadius: R_BUTTON,
              background: wash.strong,
              border: `1px solid ${line.stronger}`,
              color: color.textPrimary,
            }}
          >
            <IconArrowRight size={18} />
          </button>
        </form>
      </div>
    </>
  );
}

/* -------------------------------------------------------- ペアリング (push) */

function PairingScreen({ onCancel, onPair }: { onCancel: () => void; onPair: (name: string) => void }) {
  const [left, setLeft] = useState(292);

  useEffect(() => {
    const t = window.setInterval(() => setLeft((n) => Math.max(0, n - 1)), 1000);
    return () => window.clearInterval(t);
  }, []);

  const clock = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
  const expired = left === 0;

  return (
    <>
      <StatusSpacer />
      <div style={{ height: TOUCH, flexShrink: 0, display: 'flex', alignItems: 'center', padding: '0 16px' }}>
        <button onClick={onCancel} style={{ fontSize: 14, color: color.textTertiary }}>
          キャンセル
        </button>
        <div style={{ flex: 1 }} />
        <span style={{ fontSize: 14, fontWeight: 600 }}>ペアリング</span>
        <div style={{ flex: 1 }} />
        {/* balances the title against the キャンセル on the left */}
        <span aria-hidden style={{ fontSize: 14, visibility: 'hidden' }}>
          キャンセル
        </span>
      </div>

      <div className="scroll" style={{ flex: 1, overflowY: 'auto', padding: '12px 16px 0 16px' }}>
        <div style={{ fontSize: 20, fontWeight: 700, letterSpacing: '-0.01em', lineHeight: '28px', marginBottom: 6 }}>
          このMacとペアリングしますか？
        </div>
        <div style={{ fontSize: 12, lineHeight: '18px', color: color.textTertiary, marginBottom: 16 }}>
          Macの画面に出ている指紋と、下の指紋が一致することを確かめてください。
        </div>

        <Card prominent style={{ padding: 13, marginBottom: 12 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 11 }}>
            <IconHost size={15} color={color.textPrimary} />
            <span style={{ fontSize: 15, fontWeight: 600 }}>{HOST.name}</span>
          </div>
          <Eyebrow style={{ marginBottom: 5 }}>HOST FINGERPRINT</Eyebrow>
          <div className="cl" style={{ fontSize: 17, letterSpacing: '0.08em', color: color.textPrimary, lineHeight: '26px' }}>
            {HOST.fingerprintFull.map((row) => (
              <div key={row}>{row}</div>
            ))}
          </div>
          <div style={{ marginTop: 11, paddingTop: 9, borderTop: `1px solid ${line.hairline}` }}>
            <KV label="endpoint" value={HOST.endpoint} first />
            <div style={{ height: 6 }} />
            <KV label="protocol" value={HOST.protocol} first />
          </div>
        </Card>

        <Section>最初に付与される権限</Section>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 8 }}>
          {SCOPES.map((s) => (
            <ScopeChip key={s.id} id={s.id} granted={s.id === 'view'} />
          ))}
        </div>
        <div style={{ fontSize: 11, lineHeight: '16px', color: color.textQuaternary, margin: '0 2px 14px 2px' }}>
          最初は閲覧だけ。入力・割り込みはあとからMacで足す。
        </div>

        <Banner>
          このリンクは一度だけ使える。指紋が変わったときは別のhostとして扱い、接続せずに再ペアリングを求める。
        </Banner>
      </div>

      <div
        style={{
          flexShrink: 0,
          padding: '12px 16px 8px 16px',
          paddingBottom: 'calc(8px + env(safe-area-inset-bottom))',
        }}
      >
        <PrimaryButton
          onClick={expired ? undefined : () => onPair('daiki-ipad')}
          style={{ width: '100%', opacity: expired ? 0.45 : 1 }}
        >
          ペアリングする
        </PrimaryButton>
        <div style={{ textAlign: 'center', marginTop: 9, fontSize: 11, color: color.textQuaternary }}>
          {expired ? (
            'このリンクは期限切れ。Macで作り直してください。'
          ) : (
            <>
              このリンクは <span className="cl">{clock}</span> で期限切れ
            </>
          )}
        </div>
      </div>
    </>
  );
}

/* ----------------------------------------------------------- design compare */

function DesignSnapshot({ k }: { k: ArtboardKey }) {
  const board = artboards[k];
  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 10,
        padding: '16px 0',
        overflow: 'auto',
        background: color.overlayGround,
      }}
    >
      <div style={{ fontSize: 11, fontWeight: 600, color: color.textQuaternary }}>design canvas · {board.file}</div>
      <style>{board.css}</style>
      <div
        className="dc-board"
        style={{ width: 390, height: 844, borderRadius: 12, overflow: 'hidden', flexShrink: 0 }}
        dangerouslySetInnerHTML={{ __html: board.html }}
      />
    </div>
  );
}

/* ------------------------------------------------------------------ the app */

const INITIAL_DEVICES: Device[] = [
  { id: 'd1', name: 'daiki-iphone15', scopes: 'view · 入力 · signal', since: '2026-09-02 から', current: true },
];

export function MobileApp() {
  const wb = useWorkbench();
  const [tab, setTab] = useState<Tab>('セッション');
  const [push, setPush] = useState<Push>(null);
  const [muted, setMuted] = useState(false);
  const [designMode, setDesignMode] = useState(false);
  const [devices, setDevices] = useState<Device[]>(INITIAL_DEVICES);
  const [refreshOnResume, setRefreshOnResume] = useState(true);
  const [fetchedAt, setFetchedAt] = useState('12:09:41');

  // The PWA re-reads attention when it comes back to the foreground; nothing
  // is cached on the device, so the timestamp is the whole story.
  useEffect(() => {
    if (!refreshOnResume) return;
    const onShow = () => {
      if (document.visibilityState !== 'visible') return;
      const d = new Date();
      setFetchedAt(
        [d.getHours(), d.getMinutes(), d.getSeconds()].map((n) => String(n).padStart(2, '0')).join(':'),
      );
    };
    document.addEventListener('visibilitychange', onShow);
    return () => document.removeEventListener('visibilitychange', onShow);
  }, [refreshOnResume]);

  const pushed = useMemo(() => {
    if (push?.kind !== 'terminal') return null;
    return wb.sessions.find((s) => s.id === push.sessionId) ?? wb.sessions[0];
  }, [push, wb.sessions]);

  const openTerminal = (id: string) => setPush({ kind: 'terminal', sessionId: id });

  const artboardKey: ArtboardKey =
    push?.kind === 'terminal' ? 'terminal' : push?.kind === 'pairing' ? 'pairing' : tab;

  const attentionCount = wb.sessions.filter((s) => s.attention).length;

  const sub: Record<Tab, React.ReactNode> = {
    概要: `${HOST.name} · ${wb.sessions.length} セッション`,
    セッション: `${HOST.name} · ${wb.sessions.length} セッション`,
    アクティビティ: `最後に取得 ${fetchedAt}${refreshOnResume ? ' · 前面復帰で再取得' : ''}`,
    設定: `${devices.find((d) => d.current)?.name} · protocol ${HOST.protocol}`,
  };

  const foot: Record<Tab, string> = {
    概要: 'Macを閉じてもhostとPTYは動き続ける。',
    セッション: 'terminal outputはこの端末に保存されない。',
    アクティビティ: 'この一覧は接続中のhostから取得している。端末には残さない。',
    設定: 'mobile接続の可否はMac側のスイッチが持つ。切ってもMacのPTYは止まらない。',
  };

  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        background: push?.kind === 'pairing' ? color.chromeRaised : color.chrome,
        color: color.textPrimary,
        position: 'relative',
      }}
    >
      {reviewMode ? (
        <button
          onClick={() => setDesignMode((d) => !d)}
          style={{
            position: 'absolute',
            top: 10,
            right: 10,
            zIndex: 10,
            display: 'flex',
            alignItems: 'center',
            gap: 6,
            height: 28,
            padding: '0 10px',
            borderRadius: 14,
            background: 'rgba(0,0,0,0.55)',
            border: '1px dashed rgba(241,242,246,0.5)',
            color: color.textPrimary,
            fontSize: 11,
            fontWeight: 600,
          }}
        >
          {designMode ? 'Design' : 'Live'} 表示中 · 切替
        </button>
      ) : null}

      {designMode ? (
        <div style={{ flex: 1, overflow: 'hidden' }}>
          <DesignSnapshot k={artboardKey} />
        </div>
      ) : push?.kind === 'terminal' && pushed ? (
        <TerminalScreen session={pushed} onBack={() => setPush(null)} />
      ) : push?.kind === 'pairing' ? (
        <PairingScreen
          onCancel={() => setPush(null)}
          onPair={(name) => {
            setDevices((list) =>
              list.some((d) => d.name === name)
                ? list
                : [...list, { id: `d${list.length + 1}`, name, scopes: 'view のみ', since: '今日' }],
            );
            setPush(null);
          }}
        />
      ) : (
        <>
          <StatusSpacer />
          <TabHeader
            title={tab}
            sub={sub[tab]}
            right={
              tab === 'アクティビティ' && attentionCount ? (
                <StatusPill label={`要対応 ${attentionCount}`} />
              ) : undefined
            }
          />
          <div className="scroll" style={{ flex: 1, padding: '0 16px' }}>
            {tab === '概要' ? (
              <HomeScreen onOpenTerminal={openTerminal} />
            ) : tab === 'セッション' ? (
              <SessionsScreen
                onOpenTerminal={openTerminal}
                muted={muted}
                onToggleMute={() => setMuted((m) => !m)}
              />
            ) : tab === 'アクティビティ' ? (
              <ActivityScreen onOpenTerminal={openTerminal} />
            ) : (
              <SettingsScreen
                devices={devices}
                onRevoke={(id) => setDevices((list) => list.filter((d) => d.id !== id))}
                onPair={() => setPush({ kind: 'pairing' })}
                refreshOnResume={refreshOnResume}
                onToggleResume={() => setRefreshOnResume((v) => !v)}
              />
            )}
          </div>
          <Footnote>{foot[tab]}</Footnote>
          <TabBar tab={tab} onSelect={setTab} />
        </>
      )}
    </div>
  );
}
