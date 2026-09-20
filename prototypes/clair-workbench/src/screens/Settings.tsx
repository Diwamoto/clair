import { useState } from 'react';

import { RouteLink } from '../App';
import { IconCloseThin } from '../icons';
import { useWorkbench } from '../store';

import { color, fs, line, radius, space } from '../tokens';

const SECTIONS = ['一般', 'AIプロバイダー', 'エディタ', 'ターミナル', 'モバイル', 'アップデート'];

/** A short, closed set of values — segmented rather than a Switch because
 * there are more than two states. Same lightness-only emphasis rule: the
 * selected segment gets surfaceActive, nothing gets a new hue. */
function Segmented<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T;
  options: readonly T[];
  onChange: (next: T) => void;
}) {
  return (
    <div style={{ display: 'flex', borderRadius: radius.control, border: `1px solid ${line.hairline}`, overflow: 'hidden' }}>
      {options.map((opt) => {
        const on = opt === value;
        return (
          <button
            key={opt}
            onClick={() => onChange(opt)}
            style={{
              height: 26,
              padding: '0 10px',
              fontSize: fs.caption,
              fontWeight: on ? 600 : 400,
              background: on ? color.surfaceActive : undefined,
              color: on ? color.textPrimary : color.textSecondary,
            }}
          >
            {opt}
          </button>
        );
      })}
    </div>
  );
}

/** The `~/Projects` row's look, reused for any other path/command value. */
function FieldValue({ children }: { children: React.ReactNode }) {
  return (
    <div
      className="cl"
      style={{
        minHeight: 26,
        padding: '0 8px',
        display: 'flex',
        alignItems: 'center',
        border: `1px solid ${line.hairline}`,
        borderRadius: radius.control,
        background: color.chrome,
        color: color.textSecondary,
        fontSize: fs.caption,
      }}
    >
      {children}
    </div>
  );
}

function Switch({ on, onClick }: { on: boolean; onClick: () => void }) {
  return (
    <button
      role="switch"
      aria-checked={on}
      onClick={onClick}
      style={{
        position: 'relative',
        width: 34,
        height: 20,
        borderRadius: radius.pill,
        background: on ? color.textSecondary : color.surfaceActive,
        flexShrink: 0,
      }}
    >
      <i
        style={{
          position: 'absolute',
          top: 3,
          left: on ? 17 : 3,
          width: 14,
          height: 14,
          borderRadius: '50%',
          background: on ? color.canvas : color.textTertiary,
          transition: 'left 120ms ease',
        }}
      />
    </button>
  );
}

function Row({
  title,
  note,
  control,
  first,
  last,
}: {
  title: string;
  note?: string;
  control: React.ReactNode;
  first?: boolean;
  last?: boolean;
}) {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: space[3],
        minHeight: 52,
        padding: '12px 0',
        borderTop: first ? `1px solid ${line.hairlineSoft}` : undefined,
        borderBottom: last ? 0 : `1px solid ${line.hairlineSoft}`,
      }}
    >
      <div>
        <strong style={{ display: 'block', fontSize: fs.secondary, fontWeight: 600, color: color.textPrimary }}>{title}</strong>
        {note ? (
          <small className="prose" style={{ display: 'block', marginTop: 2, color: color.textTertiary, fontSize: fs.caption }}>
            {note}
          </small>
        ) : null}
      </div>
      {control}
    </div>
  );
}

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div
      style={{
        padding: '20px 22px',
        background: color.chrome,
        borderRadius: radius.card,
        marginBottom: 12,
      }}
    >
      <div style={{ marginBottom: 16 }}>
        <h2 style={{ margin: 0, fontSize: fs.body, fontWeight: 600 }}>{title}</h2>
      </div>
      {children}
    </div>
  );
}

/** The settings sections live in the shared sidebar, not in a column of their own. */
export function SettingsPanel() {
  const wb = useWorkbench();
  const [query, setQuery] = useState('');
  const section = wb.settingsSection;
  const sections = SECTIONS.filter((s) => !query || s.includes(query));

  return (
        <div
          className="scroll"
          style={{
            position: 'absolute',
            inset: 0,
            display: 'flex',
            flexDirection: 'column',
            gap: space[3],
            padding: '16px 8px',
          }}
        >
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="設定を検索"
            style={{
              display: 'flex',
              alignItems: 'center',
              height: 32,
              padding: '0 8px',
              borderRadius: radius.control,
              background: color.chrome,
              border: `1px solid ${line.hairline}`,
              color: color.textSecondary,
              fontSize: fs.caption,
              outline: 'none',
            }}
          />
          <nav>
            <div style={{ margin: '4px 8px', color: color.textTertiary, fontSize: fs.caption, fontWeight: 600 }}>
              ワークスペース
            </div>
            {sections.map((s) => {
              const on = section === s;
              return (
                <button
                  key={s}
                  className={on ? undefined : 'hoverable'}
                  onClick={() => wb.setSettingsSection(s)}
                  style={{
                    minHeight: 30,
                    width: '100%',
                    display: 'flex',
                    alignItems: 'center',
                    gap: space[2],
                    padding: '0 8px',
                    borderRadius: radius.control,
                    background: on ? color.surfaceActive : undefined,
                    color: on ? color.textPrimary : color.textSecondary,
                    fontSize: fs.caption,
                    fontWeight: on ? 600 : 400,
                  }}
                >
                  {s}
                </button>
              );
            })}
          </nav>
        </div>
  );
}

export function SettingsMain() {
  const wb = useWorkbench();
  const section = wb.settingsSection;

  return (
        <div className="scroll" style={{ flex: 1, minWidth: 0, minHeight: 0, padding: '40px 56px', background: color.canvas }}>
          <div style={{ maxWidth: 720, margin: '0 auto' }}>
            <h1 style={{ margin: 0, fontSize: fs.display.h1, fontWeight: 600, letterSpacing: '-0.01em' }}>{section}</h1>
            <p className="prose" style={{ margin: '8px 0 24px', color: color.textTertiary, fontSize: fs.secondary, lineHeight: 1.6 }}>
              {section === '一般'
                ? 'ワークスペースの基本動作とアプリ全体の表示を設定します。'
                : `${section} の設定です。`}
            </p>

            {section === '一般' ? (
              <>
                <Card title="ワークスペース">
                  <Row
                    first
                    title="ワークスペースのディレクトリ"
                    control={
                      <div style={{ display: 'flex', alignItems: 'center', gap: space[2] }}>
                        <div
                          className="cl"
                          style={{
                            minHeight: 26,
                            padding: '0 8px',
                            display: 'flex',
                            alignItems: 'center',
                            border: `1px solid ${line.hairline}`,
                            borderRadius: radius.control,
                            background: color.chrome,
                            color: color.textSecondary,
                            fontSize: fs.caption,
                          }}
                        >
                          ~/Projects
                        </div>
                        <button
                          className="btn-secondary"
                          style={{ minHeight: 26, padding: '0 8px', borderRadius: radius.control, fontSize: fs.caption }}
                        >
                          変更…
                        </button>
                      </div>
                    }
                  />
                  <Row
                    title="前回のレイアウトを復元"
                    note="Projectごとのファイル、ターミナル、分割位置を再開します。"
                    control={<Switch on={wb.toggles.restoreLayout} onClick={() => wb.setToggle('restoreLayout')} />}
                  />
                  <Row
                    last
                    title="閉じる前に確認"
                    note="実行中のターミナルや未保存のエディタを閉じる前に確認します。"
                    control={<Switch on={wb.toggles.confirmClose} onClick={() => wb.setToggle('confirmClose')} />}
                  />
                </Card>

                <Card title="インターフェース">
                  <Row
                    first
                    last
                    title="ステータスバーの利用枠を表示"
                    control={<Switch on={wb.toggles.showQuota} onClick={() => wb.setToggle('showQuota')} />}
                  />
                </Card>
              </>
            ) : section === 'モバイル' ? (
              <Card title="モバイル">
                <Row
                  first
                  last
                  title="モバイルの画面を確認"
                  note="iPhone向けのセッション一覧を別画面で開きます。"
                  control={
                    <RouteLink
                      to="mobile"
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        height: 24,
                        padding: '0 8px',
                        borderRadius: radius.control,
                        border: `1px solid ${line.strong}`,
                        color: color.textSecondary,
                        fontSize: fs.caption,
                        textDecoration: 'none',
                      }}
                    >
                      モバイルを開く ↗
                    </RouteLink>
                  }
                />
              </Card>
            ) : section === 'AIプロバイダー' ? (
              <>
                <Card title="Agent">
                  <Row
                    first
                    title="既定のAgent"
                    note="⌃⌘N で追加するときの初期選択。titlebarのタブは個別に選べます。"
                    control={<Segmented value={wb.defaultAgent} options={['claude', 'codex'] as const} onChange={wb.setDefaultAgent} />}
                  />
                  <Row
                    last
                    title="承認ポリシー"
                    note="ターミナル・Agent会話での変更提案を、どこまで自動で通すか。"
                    control={
                      <Segmented
                        value={wb.approvalPolicy}
                        options={['毎回確認', 'セッション中は許可', '自動承認'] as const}
                        onChange={wb.setApprovalPolicy}
                      />
                    }
                  />
                </Card>
                <Card title="インターフェース">
                  <Row
                    first
                    last
                    title="ステータスバーの利用枠を表示"
                    note="一般タブの同じ項目と共通です。"
                    control={<Switch on={wb.toggles.showQuota} onClick={() => wb.setToggle('showQuota')} />}
                  />
                </Card>
              </>
            ) : section === 'エディタ' ? (
              <Card title="編集">
                <Row
                  first
                  title="保存時に整形"
                  note="⌘S のタイミングでフォーマッタを実行します。"
                  control={<Switch on={wb.toggles.formatOnSave} onClick={() => wb.setToggle('formatOnSave')} />}
                />
                <Row
                  title="タブ幅"
                  control={<Segmented value={String(wb.tabWidth)} options={['2', '4', '8'] as const} onChange={(v) => wb.setTabWidth(Number(v))} />}
                />
                <Row
                  last
                  title="空白文字を表示"
                  note="タブ・行末の空白を薄く可視化します。"
                  control={<Switch on={wb.toggles.showWhitespace} onClick={() => wb.setToggle('showWhitespace')} />}
                />
              </Card>
            ) : section === 'ターミナル' ? (
              <Card title="シェルと承認">
                <Row
                  first
                  title="デフォルトシェル"
                  control={
                    <div style={{ display: 'flex', alignItems: 'center', gap: space[2] }}>
                      <FieldValue>{wb.defaultShell}</FieldValue>
                      <button
                        className="btn-secondary"
                        onClick={() => wb.setDefaultShell(wb.defaultShell === '/bin/zsh' ? '/bin/bash' : '/bin/zsh')}
                        style={{ minHeight: 26, padding: '0 8px', borderRadius: radius.control, fontSize: fs.caption }}
                      >
                        変更…
                      </button>
                    </div>
                  }
                />
                <Row
                  title="コマンド実行前に確認"
                  note="agentが実行するコマンドの承認プロンプト。ターミナルパネルの [y/N] と同じ挙動です。"
                  control={<Switch on={wb.toggles.terminalApprovals} onClick={() => wb.setToggle('terminalApprovals')} />}
                />
                <Row
                  last
                  title="スクロールバック"
                  control={
                    <Segmented
                      value={String(wb.scrollbackLines)}
                      options={['1000', '5000', '10000'] as const}
                      onChange={(v) => wb.setScrollbackLines(Number(v))}
                    />
                  }
                />
              </Card>
            ) : section === 'アップデート' ? (
              <>
                <Card title="更新チャンネル">
                  <Row
                    first
                    title="チャンネル"
                    note="Dev は先行ビルド。署名検証・backup/rollback はどちらも同じです。"
                    control={<Segmented value={wb.updateChannel} options={['Stable', 'Dev'] as const} onChange={wb.setUpdateChannel} />}
                  />
                  <Row
                    last
                    title="Agent実行中はスリープを抑止"
                    note="長時間タスクの途中でMacがスリープしないようにします。"
                    control={<Switch on={wb.toggles.preventSleepDuringAgent} onClick={() => wb.setToggle('preventSleepDuringAgent')} />}
                  />
                </Card>
                <Card title="バージョン">
                  <Row first last title="現在のバージョン" note={`Clair 2.0.0-${wb.updateChannel.toLowerCase()} · 最新`} control={<span />} />
                </Card>
              </>
            ) : (
              <Card title={section}>
                <div style={{ color: color.textQuaternary, fontSize: fs.caption, lineHeight: 1.7 }}>
                  この画面はデザインキャンバスにまだ存在しません。
                </div>
              </Card>
            )}
          </div>
        </div>
  );
}

export function SettingsStatus() {
  const wb = useWorkbench();
  return (
    <span className="tnum" style={{ color: color.textQuaternary }}>
      設定 · {wb.settingsSection}
    </span>
  );
}

/**
 * Settings as its own full-screen sheet, not a panel+main pair living inside
 * the shared shell. The titlebar's tabs and the sidebar's nav were both
 * still clickable through the old layout — a working "close" that competed
 * with three other ways to leave. Here there is exactly one: the ✕ at the
 * top-right, plus Esc (already wired in App.tsx for any non-workspace
 * screen). Nothing else on the screen can navigate away.
 */
export function SettingsScreen({ onClose }: { onClose: () => void }) {
  const wb = useWorkbench();
  return (
    <div
      className="enter-sheet"
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 50,
        display: 'flex',
        flexDirection: 'column',
        background: color.canvas,
      }}
    >
      <div
        style={{
          height: 48,
          flexShrink: 0,
          display: 'flex',
          alignItems: 'center',
          gap: space[2],
          padding: '0 12px 0 16px',
          background: color.chrome,
          borderBottom: `1px solid ${line.hairline}`,
        }}
      >
        <span style={{ fontSize: fs.body, fontWeight: 600, color: color.textPrimary }}>設定</span>
        <div style={{ flex: 1 }} />
        <button
          className="act"
          onClick={onClose}
          autoFocus
          title="設定を閉じる"
          aria-label="設定を閉じる"
        >
          <IconCloseThin size={14} />
        </button>
      </div>
      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        <div
          style={{
            width: 220,
            flexShrink: 0,
            position: 'relative',
            borderRight: `1px solid ${line.chrome}`,
            background: color.chrome,
          }}
        >
          <SettingsPanel />
        </div>
        <SettingsMain />
      </div>
      <div
        style={{
          height: 26,
          flexShrink: 0,
          display: 'flex',
          alignItems: 'center',
          padding: '0 12px',
          background: color.chrome,
          borderTop: `1px solid ${line.chrome}`,
          color: color.textQuaternary,
          fontSize: fs.caption,
        }}
      >
        設定 · {wb.settingsSection}
      </div>
    </div>
  );
}
