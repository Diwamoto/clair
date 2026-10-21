// An agent's file-operation proposal (`finder.propose`), as a tab: the
// operations in order, each with a checkbox, and 適用 / 却下. Nothing on disk
// changes until the user applies; the agent's call waits for that answer the
// way an `openDiff` proposal does. Destructive rows (ゴミ箱) start unchecked.
//
// Values are the review list's: 28px rows, surfaceActive selection, the
// primary / secondary buttons, success/attention/danger only for the verb.

import { useState } from 'react';

import { tildify, type ProposalOp } from '../finder';
import { IconSparkle } from '../icons';
import { useWorkbench } from '../store';
import { color, fs, line, radius, space } from '../tokens';

// A function, not a table: the tints are read per render so the light scheme applies.
const verbOf = (kind: ProposalOp['kind']) =>
  ({
    mkdir: { label: 'フォルダを作成', tint: color.success },
    move: { label: '移動', tint: color.attention },
    rename: { label: '名前を変更', tint: color.attention },
    trash: { label: 'ゴミ箱に入れる', tint: color.danger },
  })[kind];

export function ProposalPane({ id, paneId }: { id: string; paneId: string }) {
  const wb = useWorkbench();
  const proposal = wb.proposals[id];
  const [checked, setChecked] = useState<Set<number>>(
    () => new Set(proposal?.ops.flatMap((op, i) => (op.kind === 'trash' ? [] : [i])) ?? []),
  );
  if (!proposal) return null;
  const rel = (path: string) => (path.startsWith(proposal.folder + '/') ? path.slice(proposal.folder.length + 1) : tildify(path));
  const pending = proposal.state === 'pending';
  const toggle = (i: number) =>
    setChecked((current) => {
      const next = new Set(current);
      if (next.has(i)) next.delete(i);
      else next.add(i);
      return next;
    });

  return (
    <div
      onMouseDown={() => wb.setFocusedPane(paneId)}
      style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, background: color.canvas }}
    >
      <div style={{ padding: '16px 20px 12px', display: 'flex', flexDirection: 'column', gap: space[1], borderBottom: `1px solid ${line.hairlineFaint}` }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: space[2] }}>
          <IconSparkle size={14} color={color.textTertiary} />
          <span style={{ fontSize: fs.title, fontWeight: 600, color: color.textPrimary }}>整理の提案</span>
          <span className="cl" style={{ fontSize: fs.caption, color: color.textTertiary }}>{tildify(proposal.folder)}</span>
        </div>
        <span style={{ fontSize: fs.secondary, color: color.textTertiary }}>
          {proposal.agent} から · {proposal.ops.length} 件の操作。適用するまでディスクは変わりません。
        </span>
      </div>

      <div className="scroll" style={{ flex: 1, minHeight: 0, padding: '6px 0' }}>
        {proposal.ops.map((op, i) => {
          const verb = verbOf(op.kind);
          const on = checked.has(i);
          return (
            <label
              key={i}
              className={pending ? 'hoverable' : undefined}
              style={{ display: 'flex', alignItems: 'center', gap: space[3], minHeight: 28, margin: '0 8px', padding: '4px 12px', borderRadius: radius.control, cursor: pending ? 'pointer' : 'default', opacity: !pending && !on ? 0.5 : 1 }}
            >
              <input type="checkbox" checked={on} disabled={!pending} onChange={() => toggle(i)} />
              <span style={{ width: 96, flexShrink: 0, fontSize: fs.secondary, fontWeight: 600, color: verb.tint }}>{verb.label}</span>
              <span className="cl" style={{ flex: 1, minWidth: 0, fontSize: fs.secondary, color: color.textSecondary, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {op.kind === 'mkdir' ? rel(op.to) : op.kind === 'trash' ? rel(op.from) : `${rel(op.from)}  →  ${rel(op.to)}`}
              </span>
              {op.why ? <span style={{ flexShrink: 0, fontSize: fs.caption, color: color.textQuaternary }}>{op.why}</span> : null}
            </label>
          );
        })}
      </div>

      <div style={{ height: 52, flexShrink: 0, display: 'flex', alignItems: 'center', gap: space[2], padding: '0 20px', borderTop: `1px solid ${line.hairlineFaint}` }}>
        {pending ? (
          <>
            <button
              className="btn-primary"
              disabled={!checked.size}
              onClick={() => wb.applyProposal(id, [...checked].sort((a, b) => a - b))}
              style={{ height: 28, padding: '0 12px', borderRadius: radius.control, fontSize: fs.secondary }}
            >
              選択した {checked.size} 件を適用
            </button>
            <button className="btn-secondary" onClick={() => wb.rejectProposal(id)} style={{ height: 28, padding: '0 12px', borderRadius: radius.control, fontSize: fs.secondary }}>
              却下
            </button>
            <span style={{ fontSize: fs.caption, color: color.textQuaternary }}>結果は {proposal.agent} に返ります</span>
          </>
        ) : (
          <>
            <span style={{ fontSize: fs.secondary, color: color.textSecondary }}>
              {proposal.state === 'applied' ? `${proposal.applied} 件を適用しました` : '却下しました'}
            </span>
            <button className="btn-secondary" onClick={() => wb.goToPlace(proposal.folder)} style={{ height: 28, padding: '0 12px', borderRadius: radius.control, fontSize: fs.secondary }}>
              ファイルブラウザで表示
            </button>
          </>
        )}
      </div>
    </div>
  );
}
