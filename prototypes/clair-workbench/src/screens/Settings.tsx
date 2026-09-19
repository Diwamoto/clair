import { useState } from 'react';

import { RouteLink } from '../App';
import { useWorkbench } from '../store';

import { color, fs, line, radius, space } from '../tokens';

const SECTIONS = ['一般', 'AIプロバイダー', 'エディタ', 'ターミナル', 'モバイル', 'アップデート'];

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
        borderRadius: radius.overlay,
        background: on ? '#6b7280' : '#494d56',
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
          background: on ? color.textPrimary : color.textSecondary,
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
  note: string;
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
        <small className="prose" style={{ display: 'block', marginTop: 2, color: color.textTertiary, fontSize: fs.caption }}>{note}</small>
      </div>
      {control}
    </div>
  );
}

function Card({ title, note, children }: { title: string; note: string; children: React.ReactNode }) {
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
        <p className="prose" style={{ margin: '4px 0 0', color: color.textTertiary, fontSize: fs.caption, lineHeight: 1.5 }}>{note}</p>
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
                  onClick={() => wb.setSettingsSection(s)}
                  style={{
                    minHeight: 30,
                    width: '100%',
                    display: 'flex',
                    alignItems: 'center',
                    gap: space[2],
                    padding: '0 8px',
                    borderRadius: radius.control,
                    background: on ? 'rgba(241,242,246,0.075)' : undefined,
                    color: on ? color.textPrimary : color.textTertiary,
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
                <Card title="ワークスペース" note="Projectを開くときに使う基本設定です。">
                  <Row
                    first
                    title="ワークスペースのディレクトリ"
                    note="Projectをまとめて管理するフォルダです。"
                    control={
                      <div
                        className="cl"
                        style={{
                          minHeight: 30,
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

                <Card title="インターフェース" note="ワークスペースを静かで集中しやすい表示にします。">
                  <Row
                    first
                    last
                    title="ステータスバーの利用枠を表示"
                    note="最も逼迫したAgentの利用枠を、すべての画面のstatus barに表示します。"
                    control={<Switch on={wb.toggles.showQuota} onClick={() => wb.setToggle('showQuota')} />}
                  />
                </Card>
              </>
            ) : section === 'モバイル' ? (
              <Card title="モバイル" note="同じネットワーク上の端末からセッションを確認します。">
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
                        background: 'rgba(241,242,246,0.09)',
                        border: `1px solid ${line.stronger}`,
                        color: color.textPrimary,
                        fontSize: fs.caption,
                        fontWeight: 600,
                        textDecoration: 'none',
                      }}
                    >
                      モバイルを開く ↗
                    </RouteLink>
                  }
                />
              </Card>
            ) : (
              <Card title={section} note="この画面はデザインキャンバスにまだ存在しません。">
                <div style={{ color: color.textQuaternary, fontSize: fs.caption, lineHeight: 1.7 }}>
                  キャンバスが定義しているのは「一般」の内容だけです。ここに項目を足すのはキャンバス側の作業です。
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
