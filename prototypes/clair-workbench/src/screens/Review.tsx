import { changedFiles, diffs, type ChangedFile, type DiffLine } from '../data';
import { HighlightedLine } from '../highlight';
import { IconClaude, IconRefresh, IconShieldCheck } from '../icons';
import { useWorkbench } from '../store';
import { MainHeader, SourceControlModeTabs } from '../chrome';
import { color, line } from '../tokens';

/** The "+"/"−" stage toggle VSCode puts at the end of a changed-file row —
 * one glyph, not an icon, matching how this app already uses plain "▾"/"▸"
 * characters for the explorer's disclosure triangles rather than SVG. */
function StageButton({ staged, onClick, title }: { staged: boolean; onClick: () => void; title: string }) {
  return (
    <button
      className="act"
      title={title}
      onClick={(e) => {
        e.stopPropagation();
        onClick();
      }}
      style={{ width: 18, height: 18, fontSize: 12, fontWeight: 700, color: color.textTertiary, flexShrink: 0 }}
    >
      {staged ? '−' : '+'}
    </button>
  );
}

function FileRow({
  file,
  staged,
  selected,
  onSelect,
  onToggleStage,
}: {
  file: ChangedFile;
  staged: boolean;
  selected: boolean;
  onSelect: () => void;
  onToggleStage: () => void;
}) {
  const untracked = file.untracked;
  return (
    <div
      role="button"
      tabIndex={0}
      className={selected ? undefined : 'hoverable'}
      onClick={onSelect}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') onSelect();
      }}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 7,
        width: '100%',
        height: 24,
        padding: selected ? '0 8px 0 20px' : '0 8px 0 22px',
        fontSize: 11,
        color: selected ? color.textPrimary : color.textTertiary,
        background: selected ? color.surfaceActive : undefined,
        borderLeft: selected ? `2px solid ${color.textSecondary}` : undefined,
        cursor: 'pointer',
      }}
    >
      <IconClaude size={12} color={untracked ? color.success : color.textTertiary} />
      <span style={{ flex: 1, textAlign: 'left', color: untracked ? color.success : undefined }}>{file.name}</span>
      {untracked ? (
        <span className="cl" style={{ fontSize: 10, color: color.textMuted }}>
          未追跡
        </span>
      ) : (
        <>
          {file.added ? (
            <span className="cl" style={{ fontSize: 10, color: color.success }}>
              +{file.added}
            </span>
          ) : null}
          {file.removed ? (
            <span className="cl" style={{ fontSize: 10, color: color.danger }}>
              −{file.removed}
            </span>
          ) : null}
        </>
      )}
      <StageButton staged={staged} onClick={onToggleStage} title={staged ? 'ステージを取り消す' : 'ステージに追加'} />
    </div>
  );
}

function SectionHeading({
  label,
  count,
  bulkTitle,
  bulkGlyph,
  onBulk,
}: {
  label: string;
  count: number;
  bulkTitle: string;
  bulkGlyph: string;
  onBulk: () => void;
}) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 6, height: 26, padding: '0 12px 0 20px' }}>
      <span style={{ fontSize: 10, fontWeight: 700, color: color.textTertiary, letterSpacing: '0.03em', flex: 1 }}>
        {label} <span style={{ color: color.textMuted, fontWeight: 400 }}>{count}</span>
      </span>
      {count ? (
        <button
          className="act"
          title={bulkTitle}
          onClick={onBulk}
          style={{ width: 18, height: 18, fontSize: 12, fontWeight: 700, color: color.textQuaternary, flexShrink: 0 }}
        >
          {bulkGlyph}
        </button>
      ) : null}
    </div>
  );
}

/** From the Tokens artboard's EMPTY STATE component. */
function NoChanges() {
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
        margin: 12,
      }}
    >
      <IconShieldCheck size={24} color={color.divider} />
      <span style={{ fontSize: 12, fontWeight: 600, color: color.textSecondary }}>変更はありません</span>
      <span style={{ fontSize: 10, color: color.textQuaternary, textAlign: 'center', maxWidth: 220, lineHeight: '15px' }}>
        working tree はきれいです。
      </span>
    </div>
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
  const visible = changedFiles.filter((f) => wb.workingPaths.has(f.path));
  const staged = visible.filter((f) => wb.stagedPaths.has(f.path));
  const unstaged = visible.filter((f) => !wb.stagedPaths.has(f.path));
  const current = visible.find((f) => f.path === wb.reviewFile) ?? visible[0];
  return { wb, staged, unstaged, visible, current };
}

export function ReviewPanel() {
  const { wb, staged, unstaged, current } = useReview();
  const canCommit = staged.length > 0 && wb.commitMessage.trim().length > 0;

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

      <div style={{ flexShrink: 0, padding: 10, display: 'flex', flexDirection: 'column', gap: 6 }}>
        <textarea
          value={wb.commitMessage}
          onChange={(e) => wb.setCommitMessage(e.target.value)}
          placeholder="コミットメッセージ"
          rows={2}
          style={{
            resize: 'none',
            border: `1px solid ${line.hairline}`,
            borderRadius: 4,
            background: color.panel,
            color: color.textPrimary,
            fontSize: 11,
            padding: '6px 8px',
            outline: 'none',
          }}
        />
        <button
          disabled={!canCommit}
          onClick={() => wb.commitStaged()}
          style={{
            height: 26,
            borderRadius: 4,
            background: canCommit ? color.surfaceActive : color.panel,
            border: `1px solid ${canCommit ? line.stronger : line.hairline}`,
            color: canCommit ? color.textPrimary : color.textQuaternary,
            fontSize: 11,
            fontWeight: 600,
            cursor: canCommit ? 'pointer' : 'default',
          }}
        >
          コミット{staged.length ? `（${staged.length}）` : ''}
        </button>
      </div>

      {staged.length === 0 && unstaged.length === 0 ? (
        <NoChanges />
      ) : (
        <div className="scroll" style={{ flex: 1, padding: '2px 0' }}>
          <SectionHeading
            label="ステージ済みの変更"
            count={staged.length}
            bulkTitle="すべてステージを取り消す"
            bulkGlyph="−"
            onBulk={() => wb.unstageAll()}
          />
          {staged.map((f) => (
            <FileRow
              key={f.path}
              file={f}
              staged
              selected={f.path === current?.path}
              onSelect={() => wb.setReviewFile(f.path)}
              onToggleStage={() => wb.toggleStaged(f.path)}
            />
          ))}

          <SectionHeading label="変更" count={unstaged.length} bulkTitle="すべてステージ" bulkGlyph="+" onBulk={() => wb.stageAll()} />
          {unstaged.map((f) => (
            <FileRow
              key={f.path}
              file={f}
              staged={false}
              selected={f.path === current?.path}
              onSelect={() => wb.setReviewFile(f.path)}
              onToggleStage={() => wb.toggleStaged(f.path)}
            />
          ))}
        </div>
      )}
    </div>
  );
}

export function ReviewMain() {
  const { wb, staged, current } = useReview();

  if (!current) {
    return (
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, background: color.canvas }}>
        <MainHeader>
          <SourceControlModeTabs />
        </MainHeader>
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <NoChanges />
        </div>
      </div>
    );
  }

  const rows = diffs[current.path] ?? [];
  const isStaged = wb.stagedPaths.has(current.path);

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, background: color.canvas }}>
      <MainHeader>
        <SourceControlModeTabs />
        <span className="cl" style={{ fontSize: 10, color: color.textMuted }}>
          {staged.length} / {changedFiles.length} files staged
        </span>
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
            background: current.untracked ? 'rgba(229,192,123,0.14)' : isStaged ? 'rgba(138,203,148,0.14)' : 'rgba(242,244,238,0.07)',
            color: current.untracked ? color.attention : isStaged ? color.success : color.textTertiary,
            fontSize: 9,
            fontWeight: 600,
          }}
        >
          {current.untracked ? '未追跡' : isStaged ? 'ステージ済み' : '変更あり'}
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
  if (!current) return null;
  return (
    <span className="cl" style={{ color: color.textMuted }}>
      {current.path}
    </span>
  );
}
