import { useState } from 'react';

import { RouteLink } from '../App';
import { AGENT_PROFILES } from '../data';
import { IconCloseThin } from '../icons';
import { useWorkbench } from '../store';
import { UsageSection } from './Usage';

import { color, fs, line, radius, space } from '../tokens';

const SECTIONS = ['一般', 'AIプロバイダー', '使用状況', 'エディタ', 'ターミナル', 'モバイル', 'アップデート'];

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

/** A closed set too long to read well as Segmented (e.g. the agent registry) —
 * same bordered-control look as FieldValue, native <select> for behaviour. */
function Dropdown<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T;
  options: readonly { id: T; title: string }[];
  onChange: (next: T) => void;
}) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value as T)}
      style={{
        height: 26,
        padding: '0 6px',
        border: `1px solid ${line.hairline}`,
        borderRadius: radius.control,
        background: color.chrome,
        color: color.textPrimary,
        fontSize: fs.caption,
      }}
    >
      {options.map((o) => (
        <option key={o.id} value={o.id}>
          {o.title}
        </option>
      ))}
    </select>
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
              fontSize: fs.secondary,
              outline: 'none',
            }}
          />
          <nav>
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
                    fontSize: fs.secondary,
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
  // The mock stays in Japanese; the row shows the setting the native app has (English is the default there).
  const [language, setLanguage] = useState<'English' | '日本語'>('English');

  return (
        <div className="scroll" style={{ flex: 1, minWidth: 0, minHeight: 0, padding: '40px 56px', background: color.canvas }}>
          <div style={{ maxWidth: 720, margin: '0 auto' }}>
            <h1 style={{ margin: 0, fontSize: fs.display.h1, fontWeight: 600, letterSpacing: '-0.01em' }}>{section}</h1>
            <p className="prose" style={{ margin: '8px 0 24px', color: color.textTertiary, fontSize: fs.secondary, lineHeight: 1.6 }}>
              {section === '一般'
                ? 'ワークスペースの基本動作とアプリ全体の表示を設定します。'
                : section === '使用状況'
                  ? '依頼・追記と推定費用の集計'
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
                    title="外観"
                    note="エディタ、ターミナル、サイドバーの配色をまとめて切り替えます。"
                    control={<Segmented value={wb.appearance} options={['ダーク', 'ライト', 'システム'] as const} onChange={wb.setAppearance} />}
                  />
                  <Row
                    title="言語"
                    control={<Segmented value={language} options={['English', '日本語'] as const} onChange={setLanguage} />}
                  />
                  <Row
                    last
                    title="ステータスバーの利用枠を隠す"
                    control={<Switch on={wb.toggles.hideQuota} onClick={() => wb.setToggle('hideQuota')} />}
                  />
                </Card>
              </>
            ) : section === '使用状況' ? (
              <UsageSection />
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
                    control={<Dropdown value={wb.defaultAgent} options={AGENT_PROFILES} onChange={wb.setDefaultAgent} />}
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
                    title="ステータスバーの利用枠を隠す"
                    note="一般タブの同じ項目と共通です。"
                    control={<Switch on={wb.toggles.hideQuota} onClick={() => wb.setToggle('hideQuota')} />}
                  />
                </Card>
              </>
            ) : section === 'エディタ' ? (
              <>
              <DisplayCard terminal={false} />
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
                  title="空白文字を表示"
                  note="タブ・行末の空白を薄く可視化します。"
                  control={<Switch on={wb.toggles.showWhitespace} onClick={() => wb.setToggle('showWhitespace')} />}
                />
                <Row
                  last
                  title="拡張子の言語"
                  note="組み込みの判定より優先されます。開き直したファイルから反映されます。"
                  control={null}
                />
                <AssociationList />
              </Card>
              </>
            ) : section === 'ターミナル' ? (
              <>
              <DisplayCard terminal />
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
              </>
            ) : section === 'アップデート' ? (
              <>
                <Card title="動作">
                  <Row
                    first
                    last
                    title="Agent実行中はスリープを抑止"
                    note="長時間タスクの途中でMacがスリープしないようにします。"
                    control={<Switch on={wb.toggles.preventSleepDuringAgent} onClick={() => wb.setToggle('preventSleepDuringAgent')} />}
                  />
                </Card>
                <Card title="バージョン">
                  <Row first title="現在のバージョン" note={`Clair 2.0.0 · 最新`} control={<span />} />
                  <Row
                    last
                    title="チェンジログ"
                    note="GitHub の CHANGELOG.md をブラウザで開きます。"
                    control={
                      <button
                        className="btn-secondary"
                        onClick={() => window.open('https://github.com/Diwamoto/clair/blob/main/CHANGELOG.md', '_blank')}
                        style={{ minHeight: 26, padding: '0 8px', borderRadius: radius.control, fontSize: fs.caption }}
                      >
                        ブラウザで開く
                      </button>
                    }
                  />
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

const FONTS = ['システム等幅', 'Menlo', 'Monaco', 'Courier New', 'JetBrains Mono'];
const FONT_SIZES = ['11', '12', '13', '14', '16', '18'] as const;

/** 設定 › エディタ / ターミナル「表示」. Mirrors the native card; the font list there is the installed monospaced families. */
function DisplayCard({ terminal }: { terminal: boolean }) {
  const [font, setFont] = useState(FONTS[0]);
  const [size, setSize] = useState<string>(terminal ? '13' : '12');
  const [lineNumbers, setLineNumbers] = useState(true);
  const [cursor, setCursor] = useState<'ブロック' | 'バー' | '下線'>('ブロック');
  const [blink, setBlink] = useState(true);
  return (
    <Card title="表示">
      <Row
        first
        title="フォント"
        note="インストール済みの等幅フォントから選びます。"
        control={
          <select aria-label="フォント" value={font} style={{ width: 220, height: 28 }} onChange={(e) => setFont(e.target.value)}>
            {FONTS.map((f) => <option key={f}>{f}</option>)}
          </select>
        }
      />
      <Row title="文字サイズ" control={<Segmented value={size} options={FONT_SIZES} onChange={setSize} />} />
      {terminal ? (
        <>
          <Row title="カーソルの形" control={<Segmented value={cursor} options={['ブロック', 'バー', '下線'] as const} onChange={setCursor} />} />
          <Row
            last
            title="カーソルを点滅"
            note="シェルやアプリが形・点滅を指定したときはそちらが優先されます。"
            control={<Switch on={blink} onClick={() => setBlink(!blink)} />}
          />
        </>
      ) : (
        <Row last title="行番号を表示" control={<Switch on={lineNumbers} onClick={() => setLineNumbers(!lineNumbers)} />} />
      )}
    </Card>
  );
}

const LANGUAGES = ['swift', 'go', 'typescript', 'javascript', 'python', 'json', 'markdown', 'rust', 'shell', 'ruby', 'java', 'php', 'terraform'];

/** Extension → language rows; + adds one. Mirrors the native 設定 › エディタ list. */
function AssociationList() {
  const [rows, setRows] = useState([{ id: 0, ext: 'tpl', lang: 'terraform' }]);
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 8, paddingBottom: 12 }}>
      {rows.map((r) => (
        <div key={r.id} style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
          <input aria-label="拡張子" placeholder="tpl" value={r.ext} style={{ width: 160, height: 28 }}
            onChange={(e) => setRows(rows.map((x) => (x.id === r.id ? { ...x, ext: e.target.value } : x)))} />
          <select aria-label="言語" value={r.lang} style={{ width: 180, height: 28 }}
            onChange={(e) => setRows(rows.map((x) => (x.id === r.id ? { ...x, lang: e.target.value } : x)))}>
            {LANGUAGES.map((l) => <option key={l}>{l}</option>)}
          </select>
          <button aria-label="削除" onClick={() => setRows(rows.filter((x) => x.id !== r.id))}>−</button>
        </div>
      ))}
      <button aria-label="追加" onClick={() => setRows([...rows, { id: Date.now(), ext: '', lang: 'terraform' }])}>＋</button>
    </div>
  );
}
