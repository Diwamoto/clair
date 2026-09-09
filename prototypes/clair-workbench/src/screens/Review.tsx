import { changedFiles, diffs, type DiffLine } from '../data';
import { HighlightedLine } from '../highlight';
import { IconArrowRight, IconChevron, IconClaude, IconRefresh } from '../icons';
import { useWorkbench } from '../store';
import { MainHeader, SourceControlModeTabs } from '../chrome';
import { color, line, wash } from '../tokens';

function FileRow({
  name,
  added,
  removed,
  untracked,
  selected,
  onClick,
}: {
  name: string;
  added: number;
  removed: number;
  untracked?: boolean;
  selected: boolean;
  onClick: () => void;
}) {
  return (
    <button
      className={selected ? undefined : 'hoverable'}
      onClick={onClick}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 7,
        width: '100%',
        height: 24,
        padding: selected ? '0 12px 0 20px' : '0 12px 0 22px',
        fontSize: 11,
        color: selected ? color.textPrimary : color.textTertiary,
        background: selected ? color.surfaceActive : undefined,
        borderLeft: selected ? `2px solid ${color.textSecondary}` : undefined,
      }}
    >
      <IconClaude size={12} color={untracked ? color.success : color.textTertiary} />
      <span style={{ flex: 1, textAlign: 'left', color: untracked ? color.success : undefined }}>{name}</span>
      {untracked ? (
        <span className="cl" style={{ fontSize: 10, color: color.textMuted }}>
          未追跡
        </span>
      ) : (
        <>
          {added ? (
            <span className="cl" style={{ fontSize: 10, color: color.success }}>
              +{added}
            </span>
          ) : null}
          {removed ? (
            <span className="cl" style={{ fontSize: 10, color: color.danger }}>
              −{removed}
            </span>
          ) : null}
        </>
      )}
    </button>
  );
}

function DiffRow({ row }: { row: DiffLine }) {
  const tint = row.sign === '+' ? 'rgba(138,203,148,0.10)' : row.sign === '-' ? 'rgba(226,123,131,0.10)' : undefined;
  const signColor = row.sign === '+' ? color.success : row.sign === '-' ? color.danger : undefined;
  return (
    <>
      <div className="dn" style={{ textAlign: 'right', paddingRight: 10, color: color.lineNumber, background: row.sign === '-' ? tint : undefined }}>
        {row.old ?? ''}
      </div>
      <div className="dn" style={{ textAlign: 'right', paddingRight: 10, color: color.lineNumber, background: row.sign === '+' ? tint : undefined }}>
        {row.New ?? ''}
      </div>
      <div style={{ paddingLeft: 12, background: tint, whiteSpace: 'pre' }}>
        {signColor ? <span style={{ color: signColor }}>{row.sign}</span> : ' '}
        <HighlightedLine line={row.text} kind="swift" />
      </div>
    </>
  );
}

function useReview() {
  const wb = useWorkbench();
  const visible = changedFiles.filter((f) =>
    wb.reviewFilter === '全差分' ? true : wb.reviewFilter === 'commit済み' ? f.group === 'committed' : f.group === 'uncommitted',
  );
  return {
    wb,
    committed: visible.filter((f) => f.group === 'committed'),
    uncommitted: visible.filter((f) => f.group === 'uncommitted'),
    current: changedFiles.find((f) => f.path === wb.reviewFile) ?? changedFiles[0],
  };
}

export function ReviewPanel() {
  const { wb, committed, uncommitted, current } = useReview();

  return (
    <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column' }}>
          <div
            style={{
              height: 32,
              flexShrink: 0,
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              padding: '0 12px',
              borderBottom: `1px solid ${line.hairline}`,
            }}
          >
            <span style={{ fontSize: 13, fontWeight: 600 }}>変更を確認</span>
            <div style={{ flex: 1 }} />
            <button className="act" style={{ width: 20, height: 20 }} title="更新">
              <IconRefresh size={13} color={color.textQuaternary} />
            </button>
          </div>
          <div className="scroll" style={{ flex: 1, padding: '6px 0' }}>
            {committed.length ? (
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, height: 26, padding: '0 12px' }}>
                <IconChevron size={11} color={color.success} style={{ transform: 'rotate(90deg)' }} />
                <span style={{ fontSize: 10, fontWeight: 700, color: color.success, letterSpacing: '0.03em' }}>
                  COMMIT済み
                </span>
                <span style={{ fontSize: 9, color: color.textMuted }}>3 commits · {committed.length} files</span>
              </div>
            ) : null}
            {committed.map((f) => (
              <FileRow
                key={f.path}
                name={f.name}
                added={f.added}
                removed={f.removed}
                selected={f.path === current.path}
                onClick={() => wb.setReviewFile(f.path)}
              />
            ))}

            {uncommitted.length ? (
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, height: 26, padding: '0 12px', marginTop: 6 }}>
                <IconChevron size={11} color={color.attention} style={{ transform: 'rotate(90deg)' }} />
                <span style={{ fontSize: 10, fontWeight: 700, color: color.attention, letterSpacing: '0.03em' }}>
                  未COMMIT
                </span>
                <span style={{ fontSize: 9, color: color.textMuted }}>{uncommitted.length} file</span>
              </div>
            ) : null}
            {uncommitted.map((f) => (
              <FileRow
                key={f.path}
                name={f.name}
                added={f.added}
                removed={f.removed}
                untracked={f.untracked}
                selected={f.path === current.path}
                onClick={() => wb.setReviewFile(f.path)}
              />
            ))}
          </div>
    </div>
  );
}

export function ReviewMain() {
  const { wb, uncommitted, current } = useReview();
  const rows = diffs[current.path] ?? [];
  const totals = changedFiles.reduce((acc, f) => ({ a: acc.a + f.added, r: acc.r + f.removed }), { a: 0, r: 0 });

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, background: color.canvas }}>
          <MainHeader>
            <SourceControlModeTabs />
            <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
              <span
                style={{
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 4,
                  height: 20,
                  padding: '0 7px',
                  borderRadius: 3,
                  background: 'rgba(242,244,238,0.07)',
                  border: '1px solid rgba(242,244,238,0.22)',
                  color: color.textSecondary,
                  fontSize: 10,
                  fontWeight: 600,
                }}
              >
                pane-split
              </span>
              <IconArrowRight size={13} color={color.textQuaternary} />
              <span
                style={{
                  display: 'inline-flex',
                  alignItems: 'center',
                  height: 20,
                  padding: '0 7px',
                  borderRadius: 3,
                  background: 'rgba(242,244,238,0.05)',
                  border: '1px solid rgba(242,244,238,0.16)',
                  color: color.textTertiary,
                  fontSize: 10,
                  fontWeight: 600,
                }}
              >
                main
              </span>
            </div>
            <span className="cl" style={{ fontSize: 10, color: color.textMuted }}>
              {changedFiles.length} files · <span style={{ color: color.success }}>+{totals.a}</span>{' '}
              <span style={{ color: color.danger }}>−{totals.r}</span>
            </span>
            <div style={{ flex: 1 }} />
            <div
              style={{
                display: 'flex',
                alignItems: 'stretch',
                height: 24,
                borderRadius: 4,
                background: color.panel,
                border: `1px solid ${line.hairline}`,
                overflow: 'hidden',
              }}
            >
              {(['全差分', 'commit済み', '未commit'] as const).map((f) => {
                const on = wb.reviewFilter === f;
                return (
                  <button
                    key={f}
                    onClick={() => wb.setReviewFilter(f)}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      padding: '0 10px',
                      background: on ? color.surfaceActive : undefined,
                      color: on ? color.textPrimary : color.textQuaternary,
                      fontSize: 10,
                      fontWeight: on ? 600 : 400,
                    }}
                  >
                    {f}
                  </button>
                );
              })}
            </div>
            <button
              disabled={uncommitted.length > 0}
              style={{
                display: 'flex',
                alignItems: 'center',
                height: 24,
                padding: '0 11px',
                borderRadius: 4,
                background: wash.strong,
                border: `1px solid ${line.stronger}`,
                color: color.textPrimary,
                fontSize: 11,
                fontWeight: 600,
                opacity: uncommitted.length > 0 ? 0.45 : 1,
                cursor: uncommitted.length > 0 ? 'default' : 'pointer',
              }}
            >
              merge commitで採用
            </button>
          </MainHeader>

          <div
            style={{
              height: 30,
              flexShrink: 0,
              display: 'flex',
              alignItems: 'center',
              gap: 9,
              padding: '0 16px',
              background: '#171a1e',
              borderBottom: `1px solid ${line.hairline}`,
            }}
          >
            <IconClaude size={12} color={color.textTertiary} />
            <span className="cl" style={{ fontSize: 11, color: color.textSecondary }}>
              {current.path}
            </span>
            {current.added ? (
              <span className="cl" style={{ fontSize: 10, color: color.success }}>
                +{current.added}
              </span>
            ) : null}
            {current.removed ? (
              <span className="cl" style={{ fontSize: 10, color: color.danger }}>
                −{current.removed}
              </span>
            ) : null}
            <div style={{ flex: 1 }} />
            <span
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: 4,
                height: 18,
                padding: '0 6px',
                borderRadius: 3,
                background: current.untracked ? 'rgba(229,192,123,0.14)' : 'rgba(138,203,148,0.14)',
                color: current.untracked ? color.attention : color.success,
                fontSize: 9,
                fontWeight: 600,
              }}
            >
              {current.untracked ? '未commit · 未追跡' : `commit済み · ${current.commit}`}
            </span>
          </div>

          <div className="scroll" style={{ flex: 1, background: color.canvas }}>
            <div
              className="cl"
              style={{
                display: 'grid',
                gridTemplateColumns: '44px 44px 1fr',
                fontSize: 12,
                lineHeight: '19px',
                color: color.code,
              }}
            >
              {rows.map((row, i) => (
                <DiffRow key={i} row={row} />
              ))}
            </div>
          </div>
    </div>
  );
}

export function ReviewStatus() {
  const { current } = useReview();
  return (
    <span className="cl" style={{ color: color.textMuted }}>
      {current.path}
    </span>
  );
}
