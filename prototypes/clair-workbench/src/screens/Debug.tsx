import { useState } from 'react';

import {
  IconDot,
  IconGrip,
  IconPlay,
  IconRefresh,
  IconStar,
  IconStepInto,
  IconStepOut,
  IconStepOver,
  IconStop,
} from '../icons';
import { useWorkbench } from '../store';

import { color, fs, line, radius, space, wash } from '../tokens';

const SWIFT_LINES: Array<[number, string]> = [
  [7, '  func makeNSView(context: Context) -> SourceEditorView {'],
  [8, '    let view = SourceEditorView(document: document)'],
  [9, '    view.restoreSelection()'],
  [10, '    return view'],
  [11, '  }'],
];

const GO_LINES: Array<[number, string]> = [
  [34, 'func (s *Server) handleGetUser(w http.ResponseWriter, r *http.Request) {'],
  [35, '  id := r.URL.Query().Get("id")'],
  [36, '  user := s.store.Find(id)'],
  [37, '  '],
  [38, '  w.Header().Set("Content-Type", "application/json")'],
  [39, '  json.NewEncoder(w).Encode(map[string]string{'],
  [40, '    "name": user.Name,'],
  [41, '  })'],
  [42, '}'],
];

function DebugToolbar() {
  const wb = useWorkbench();
  const button = (key: Parameters<typeof wb.debugStep>[0], node: React.ReactNode, tint?: string, bg?: string) => (
    <button
      key={key}
      onClick={() => wb.debugStep(key)}
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: 28,
        height: 28,
        borderRadius: radius.control,
        background: bg,
        color: tint ?? color.textTertiary,
      }}
    >
      {node}
    </button>
  );

  return (
    <div
      style={{
        position: 'absolute',
        top: 12,
        left: '50%',
        transform: 'translateX(-50%)',
        zIndex: 5,
        display: 'flex',
        alignItems: 'center',
        gap: space[0],
        height: 34,
        padding: '0 4px',
        borderRadius: radius.card,
        background: color.chromeRaised,
        border: '1px solid rgba(241,242,246,0.14)',
        boxShadow: '0 8px 20px rgba(0,0,0,0.4)',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', width: 14, height: 20, color: color.textQuaternary }}>
        <IconGrip />
      </div>
      <div style={{ width: 1, height: 18, background: 'rgba(241,242,246,0.14)', margin: '0 4px' }} />
      {button('continue', <IconPlay size={13} />, color.debugBlueText, 'rgba(91,136,247,0.16)')}
      {button('over', <IconStepOver size={13} />)}
      {button('into', <IconStepInto size={13} />)}
      {button('out', <IconStepOut size={13} />)}
      <div style={{ width: 1, height: 18, background: 'rgba(241,242,246,0.14)', margin: '0 4px' }} />
      {button('restart', <IconRefresh size={13} />)}
      {button('stop', <IconStop size={12} />, color.danger)}
    </div>
  );
}

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <div style={{ padding: '12px 12px 4px', fontSize: fs.caption, fontWeight: 600, color: color.textTertiary }}>
      {children}
    </div>
  );
}

function CodeGutterRow({
  lineNo,
  text,
  current,
  breakpoint,
  onToggle,
}: {
  lineNo: number;
  text: string;
  current: boolean;
  breakpoint: boolean;
  onToggle: () => void;
}) {
  return (
    <>
      <button
        onClick={onToggle}
        title="ブレークポイントを切り替え"
        style={{
          position: 'relative',
          textAlign: 'right',
          paddingRight: 12,
          color: current ? color.debugBlue : color.lineNumber,
          background: current ? 'rgba(91,136,247,0.14)' : undefined,
          boxShadow: current ? `inset 2px 0 ${color.debugBlue}` : undefined,
          width: '100%',
          display: 'block',
        }}
      >
        {breakpoint ? (
          <span
            style={{
              position: 'absolute',
              left: 6,
              top: '50%',
              transform: 'translateY(-50%)',
              width: 8,
              height: 8,
              borderRadius: '50%',
              background: color.danger,
            }}
          />
        ) : null}
        {lineNo}
      </button>
      <div style={{ paddingLeft: 16, background: current ? 'rgba(91,136,247,0.14)' : undefined, whiteSpace: 'pre' }}>
        {text}
      </div>
    </>
  );
}

/** The debugger's stop badge, shown in the shared titlebar. */
export function DebugBadge() {
  const wb = useWorkbench();
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: space[1],
        height: 28,
        padding: '0 8px',
        marginRight: 4,
        borderRadius: radius.control,
        background: 'rgba(226,123,131,0.14)',
        border: '1px solid rgba(226,123,131,0.4)',
        color: color.danger,
        fontSize: fs.caption,
        fontWeight: 600,
      }}
    >
      <IconDot size={11} />
      {wb.debugRunning ? `ClairApp.swift:${wb.debugLine} で停止` : 'ブレークポイントで停止'}
    </div>
  );
}

export function DebugPanel() {
  const wb = useWorkbench();

  return (
    <div className="scroll" style={{ position: 'absolute', inset: 0 }}>
          <div style={{ padding: '12px 12px 4px', fontSize: fs.caption, fontWeight: 600, color: color.textTertiary }}>
            ブレークポイント
          </div>
          {wb.breakpoints.length ? (
            wb.breakpoints
              .slice()
              .sort((a, b) => a - b)
              .map((bp) => (
                <button
                  key={bp}
                  onClick={() => wb.toggleBreakpoint(bp)}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: space[2],
                    width: '100%',
                    height: 28,
                    padding: '0 12px',
                    background: color.canvas,
                    borderLeft: `2px solid ${color.danger}`,
                    color: color.textPrimary,
                  }}
                >
                  <span style={{ width: 8, height: 8, borderRadius: '50%', background: color.danger, flexShrink: 0 }} />
                  <span className="cl" style={{ fontSize: fs.caption }}>
                    ClairApp.swift:{bp}
                  </span>
                </button>
              ))
          ) : (
            <div style={{ padding: '0 12px', color: color.textQuaternary, fontSize: fs.caption }}>設定されていません</div>
          )}

          <SectionLabel>コールスタック</SectionLabel>
          <div style={{ display: 'flex', flexDirection: 'column' }}>
            {(
              [
                ['セッションを開始', `ClairApp.swift:${wb.debugLine}`, true],
                ['ブレークポイントで停止', 'ClairApp.swift:4', false],
                ['選択範囲を復元', 'ClairApp.swift:10', false],
              ] as const
            ).map(([name, where, top]) => (
              <div
                key={name}
                style={{
                  height: 32,
                  display: 'flex',
                  flexDirection: 'column',
                  justifyContent: 'center',
                  padding: '0 12px',
                  borderLeft: top ? `2px solid ${color.debugBlue}` : undefined,
                  background: top ? 'rgba(91,136,247,0.08)' : undefined,
                }}
              >
                <span style={{ fontSize: fs.caption, color: top ? color.textPrimary : color.textTertiary }}>{name}</span>
                <small className="cl" style={{ color: color.textQuaternary, fontSize: fs.caption }}>
                  {where}
                </small>
              </div>
            ))}
          </div>

          <SectionLabel>変数</SectionLabel>
          {(
            [
              ['document', 'SourceDocument(id: "workspace-view")'],
              ['document.isDirty', 'Bool · false'],
              ['workspace.project', 'Project.ID · clair'],
            ] as const
          ).map(([name, value]) => (
            <div key={name} style={{ padding: '4px 12px' }}>
              <div className="cl" style={{ color: color.codeFunc, fontSize: fs.caption }}>
                {name}
              </div>
              <small className="cl" style={{ color: color.textQuaternary, fontSize: fs.caption }}>
                {value}
              </small>
            </div>
          ))}
    </div>
  );
}

export function DebugMain() {
  const wb = useWorkbench();
  return (
        <div style={{ position: 'relative', flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, background: color.canvas }}>
          <DebugToolbar />
          <div className="scroll" style={{ minHeight: 0, flex: 1, padding: '16px 0' }}>
            <div
              className="cl"
              style={{
                display: 'grid',
                gridTemplateColumns: '44px minmax(0,1fr)',
                fontSize: fs.secondary,
                lineHeight: '24px',
                color: color.codeBright,
              }}
            >
              {SWIFT_LINES.map(([no, text]) => (
                <CodeGutterRow
                  key={no}
                  lineNo={no}
                  text={text}
                  current={no === wb.debugLine}
                  breakpoint={wb.breakpoints.includes(no)}
                  onToggle={() => wb.toggleBreakpoint(no)}
                />
              ))}
            </div>
          </div>
          <div style={{ height: 1, flexShrink: 0, background: line.paneDivider }} />
          <div style={{ height: 160, flexShrink: 0, display: 'flex', flexDirection: 'column' }}>
            <div
              style={{
                height: 26,
                flexShrink: 0,
                display: 'flex',
                alignItems: 'center',
                padding: '0 12px',
                color: color.textQuaternary,
                fontSize: fs.caption,
                borderBottom: `1px solid ${line.hairline}`,
              }}
            >
              デバッグコンソール
            </div>
            <div className="cl scroll" style={{ flex: 1, padding: '8px 12px', color: color.textTertiary, fontSize: fs.caption, lineHeight: 1.6 }}>
              {wb.debugConsole.map((l, i) => (
                <div key={i}>{l}</div>
              ))}
            </div>
          </div>
        </div>
  );
}

export function DebugStatus() {
  const wb = useWorkbench();
  return (
    <span className="cl" style={{ color: color.textQuaternary }}>
      EditorPane.swift:{wb.debugLine}
    </span>
  );
}

/* ── Debug + AI (検討中) ──────────────────────────────────────────────── */

/** The badges this exploratory screen adds to the shared titlebar. */
export function DebugAgentBadge() {
  return (
    <>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: space[1],
          height: 28,
          padding: '0 8px',
          borderRadius: radius.control,
          background: 'rgba(91,136,247,0.14)',
          border: '1px solid rgba(91,136,247,0.4)',
          color: color.debugBlueText,
          fontSize: fs.caption,
          fontWeight: 600,
        }}
      >
        <IconStar size={11} />
        Agent が操作中 · dap-go
      </div>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: space[1],
          height: 28,
          padding: '0 8px',
          marginRight: 4,
          borderRadius: radius.control,
          background: 'rgba(226,123,131,0.14)',
          border: '1px solid rgba(226,123,131,0.4)',
          color: color.danger,
          fontSize: fs.caption,
          fontWeight: 600,
        }}
      >
        <IconDot size={11} />
        main.go:40 で停止
      </div>
    </>
  );
}

export function DebugAgentPanel() {
  return (
    <div className="scroll" style={{ position: 'absolute', inset: 0 }}>
      <div style={{ padding: '12px 12px 4px', fontSize: fs.caption, fontWeight: 600, color: color.textTertiary }}>
        ブレークポイント
      </div>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: space[2],
          height: 28,
          padding: '0 12px',
          background: color.canvas,
          borderLeft: `2px solid ${color.danger}`,
          color: color.textPrimary,
        }}
      >
        <span style={{ width: 8, height: 8, borderRadius: '50%', background: color.danger, flexShrink: 0 }} />
        <span className="cl" style={{ fontSize: fs.caption }}>
          main.go:40
        </span>
        <span style={{ marginLeft: 'auto', fontSize: fs.caption, color: color.textQuaternary }}>agent</span>
      </div>

      <SectionLabel>コールスタック</SectionLabel>
      {(
        [
          ['handleGetUser', 'main.go:40', true],
          ['ServeHTTP', 'mux.go:114', false],
          ['main', 'main.go:18', false],
        ] as const
      ).map(([name, where, top]) => (
        <div
          key={name}
          style={{
            height: 32,
            display: 'flex',
            flexDirection: 'column',
            justifyContent: 'center',
            padding: '0 12px',
            borderLeft: top ? `2px solid ${color.debugBlue}` : undefined,
            background: top ? 'rgba(91,136,247,0.08)' : undefined,
          }}
        >
          <span style={{ fontSize: fs.caption, color: top ? color.textPrimary : color.textTertiary }}>{name}</span>
          <small className="cl" style={{ color: color.textQuaternary, fontSize: fs.caption }}>
            {where}
          </small>
        </div>
      ))}

      <SectionLabel>変数</SectionLabel>
      <div style={{ padding: '4px 12px', background: 'rgba(226,123,131,0.09)' }}>
        <div className="cl" style={{ color: color.danger, fontSize: fs.caption }}>
          user
        </div>
        <small className="cl" style={{ color: color.danger, fontSize: fs.caption }}>
          *User · nil
        </small>
      </div>
      {(
        [
          ['id', 'string · "u_9921"'],
          ['r.Method', 'string · "GET"'],
        ] as const
      ).map(([name, value]) => (
        <div key={name} style={{ padding: '4px 12px' }}>
          <div className="cl" style={{ color: color.codeFunc, fontSize: fs.caption }}>
            {name}
          </div>
          <small className="cl" style={{ color: color.textQuaternary, fontSize: fs.caption }}>
            {value}
          </small>
        </div>
      ))}
    </div>
  );
}

export function DebugAgentMain() {
  const [applied, setApplied] = useState<null | '却下' | '適用してテスト'>(null);

  return (
    <div style={{ flex: 1, display: 'flex', minWidth: 0, minHeight: 0 }}>
      <div style={{ position: 'relative', flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, background: color.canvas }}>
        <DebugToolbar />
        <div className="scroll" style={{ minHeight: 0, flex: 1, padding: '16px 0' }}>
          <div
            className="cl"
            style={{ display: 'grid', gridTemplateColumns: '44px minmax(0,1fr)', fontSize: fs.secondary, lineHeight: '24px', color: color.code }}
          >
            {GO_LINES.map(([no, text]) => (
              <CodeGutterRow key={no} lineNo={no} text={text} current={no === 40} breakpoint={no === 40} onToggle={() => undefined} />
            ))}
          </div>
        </div>
      </div>

      <div
        style={{
          width: 380,
          flexShrink: 0,
          display: 'flex',
          flexDirection: 'column',
          borderLeft: `1px solid ${line.chrome}`,
        }}
      >
        <div
          style={{
            height: 30,
            flexShrink: 0,
            display: 'flex',
            alignItems: 'center',
            padding: '0 12px',
            color: color.textQuaternary,
            fontSize: fs.caption,
            borderBottom: `1px solid ${line.hairline}`,
          }}
        >
          AIエージェント · go debug session
        </div>
        <div className="scroll" style={{ flex: 1, padding: '12px 12px', display: 'flex', flexDirection: 'column', gap: space[2] }}>
          <div className="cl" style={{ color: color.textQuaternary, fontSize: fs.caption }}>
            $ clair debug run ./cmd/api --agent
          </div>
          {(
            [
              ['dap.set_breakpoint(main.go:40)', 'breakpoint id=1 を設定'],
              ['dap.continue()', 'stopped: breakpoint main.go:40'],
              ['dap.get_state()', 'frame handleGetUser · user = nil · id = "u_9921"'],
              ['dap.evaluate("s.store.Find(id)")', '→ (nil, false)'],
            ] as const
          ).map(([call, result]) => (
            <div key={call}>
              <div className="cl" style={{ color: color.debugBlueText, fontSize: fs.caption }}>
                ● {call}
              </div>
              <div className="cl" style={{ color: color.textQuaternary, fontSize: fs.caption, paddingLeft: 12 }}>
                {result}
              </div>
            </div>
          ))}

          <div style={{ color: color.textSecondary, fontSize: fs.secondary, lineHeight: 1.6, padding: '2px 0 0' }}>
            user が nil のまま Name にアクセスしています。Find() は未検出時に nil
            を返す実装なので、呼び出し側に nil チェックが必要です。修正案を作成しました。
          </div>

          <div
            style={{
              border: `1px solid ${line.stronger}`,
              borderRadius: radius.card,
              background: wash.faint,
              overflow: 'hidden',
              marginTop: 2,
            }}
          >
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                padding: '8px 12px',
                borderBottom: '1px solid rgba(241,242,246,0.14)',
                color: color.textPrimary,
                fontSize: fs.secondary,
                fontWeight: 600,
              }}
            >
              修正を適用しますか？
              <span className="cl" style={{ color: color.textQuaternary, fontWeight: 400, fontSize: fs.caption }}>
                main.go
              </span>
            </div>
            <div className="cl" style={{ padding: '8px 12px', fontSize: fs.caption, lineHeight: 1.7, whiteSpace: 'pre' }}>
              <span style={{ color: color.danger }}>{'-       "name": user.Name,'}</span>
              {'\n'}
              <span style={{ color: color.success }}>{'+       if user == nil {'}</span>
              {'\n'}
              <span style={{ color: color.success }}>{'+           http.Error(w, "not found", http.StatusNotFound)'}</span>
              {'\n'}
              <span style={{ color: color.success }}>{'+           return'}</span>
              {'\n'}
              <span style={{ color: color.success }}>{'+       }'}</span>
              {'\n'}
              <span style={{ color: color.success }}>{'+       "name": user.Name,'}</span>
            </div>
            <div style={{ display: 'flex', gap: space[2], padding: '0 12px 12px' }}>
              {(
                [
                  ['却下', line.hairline, 'transparent', color.textTertiary, 400],
                  ['適用してテスト', line.stronger, wash.strong, color.textPrimary, 600],
                ] as const
              ).map(([label, border, bg, fg, weight]) => (
                <button
                  key={label}
                  onClick={() => setApplied(label)}
                  style={{
                    flex: 1,
                    textAlign: 'center',
                    minHeight: 28,
                    lineHeight: '28px',
                    border: `1px solid ${applied === label ? line.ring : border}`,
                    borderRadius: radius.control,
                    background: applied === label ? color.surfaceActive : bg,
                    color: applied === label ? color.textPrimary : fg,
                    fontSize: fs.caption,
                    fontWeight: weight,
                  }}
                >
                  {label}
                </button>
              ))}
            </div>
          </div>
          {applied ? (
            <div className="tnum" style={{ color: color.textQuaternary, fontSize: fs.caption }}>
              {applied} を選択しました。
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}

export function DebugAgentStatus() {
  return (
    <span className="cl" style={{ color: color.textQuaternary }}>
      cmd/api/main.go:40 · Go 1.22
    </span>
  );
}
