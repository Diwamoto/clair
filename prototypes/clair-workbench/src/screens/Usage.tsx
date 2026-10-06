import { useState } from 'react';

import { IconBrackets, IconCodex, IconSparkle } from '../icons';
import { color, fs, line, radius, space, withAlpha } from '../tokens';

// 設定 › 使用状況. Every chart is grayscale: the Tokens artboard gives colour only to diff,
// debug and tab groups, so magnitude is lightness and agent identity is the agent's icon.
// Sample data, seeded so the mock renders the same every time.

type Agent = 'claude' | 'codex' | 'opencode';
const AGENTS: { id: Agent; title: string }[] = [
  { id: 'claude', title: 'Claude Code' },
  { id: 'codex', title: 'Codex' },
  { id: 'opencode', title: 'OpenCode' },
];

function AgentIcon({ agent }: { agent: Agent }) {
  if (agent === 'codex') return <IconCodex size={12} color={color.textTertiary} />;
  if (agent === 'claude') return <IconSparkle size={12} color={color.textTertiary} />;
  return <IconBrackets size={12} color={color.textTertiary} />;
}

let seed = 20261006;
const rnd = () => {
  seed = (seed * 1664525 + 1013904223) % 4294967296;
  return seed / 4294967296;
};
const TODAY = new Date(2026, 9, 6);
const DAYS = Array.from({ length: 365 }, (_, i) => {
  const d = new Date(TODAY);
  d.setDate(d.getDate() - (364 - i));
  const weekday = [0.35, 1, 1.1, 1, 1.05, 0.9, 0.45][d.getDay()];
  const trend = 0.45 + 0.75 * (i / 364);
  const by = Object.fromEntries(
    AGENTS.map((a, j) => [a.id, rnd() < 0.12 ? 0 : Math.round([7, 4, 1.2][j] * weekday * trend * (0.3 + rnd() * 1.4))]),
  ) as Record<Agent, number>;
  return { d, by, total: by.claude + by.codex + by.opencode };
});
const fmtDay = (d: Date) => `${d.getMonth() + 1}月${d.getDate()}日(${'日月火水木金土'[d.getDay()]})`;

/** Five lightness steps of one ink: 0 / 1–3 / 4–7 / 8–12 / 13+. */
const level = (n: number) => (n === 0 ? 0 : n < 4 ? 1 : n < 8 ? 2 : n < 13 ? 3 : 4);
const levelFill = (l: number) => (l === 0 ? color.surfaceActive : withAlpha(color.textSecondary, [0, 0.25, 0.45, 0.7, 0.95][l]));

function Section({ title, aside, children }: { title: string; aside?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div style={{ padding: '20px 22px', background: color.chrome, borderRadius: radius.card, marginBottom: 12 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: space[3], marginBottom: space[4] }}>
        <h2 style={{ margin: 0, fontSize: fs.body, fontWeight: 600 }}>{title}</h2>
        {aside}
      </div>
      {children}
    </div>
  );
}

function Note({ children }: { children: React.ReactNode }) {
  return <span style={{ color: color.textTertiary, fontSize: fs.caption }}>{children}</span>;
}

function Segmented<T extends string>({ value, options, onChange }: { value: T; options: readonly T[]; onChange: (v: T) => void }) {
  return (
    <div style={{ display: 'flex', borderRadius: radius.control, border: `1px solid ${line.hairline}`, overflow: 'hidden', flexShrink: 0 }}>
      {options.map((o) => (
        <button
          key={o}
          onClick={() => onChange(o)}
          style={{
            height: 24,
            padding: '0 8px',
            fontSize: fs.caption,
            fontWeight: o === value ? 600 : 400,
            background: o === value ? color.surfaceActive : undefined,
            color: o === value ? color.textPrimary : color.textSecondary,
          }}
        >
          {o}
        </button>
      ))}
    </div>
  );
}

function Tile({ title, value, unit, sub, children }: { title: string; value: string; unit?: string; sub?: string; children?: React.ReactNode }) {
  return (
    <div style={{ flex: '1 1 140px', minWidth: 0, padding: '12px 14px', background: color.canvas, borderRadius: radius.card, display: 'flex', flexDirection: 'column', gap: space[1] }}>
      <span style={{ color: color.textTertiary, fontSize: fs.caption }}>{title}</span>
      <span style={{ fontSize: fs.display.screenTitle, fontWeight: 600, fontVariantNumeric: 'tabular-nums', color: color.textPrimary }}>
        {value}
        {unit ? <span style={{ fontSize: fs.secondary, fontWeight: 400, color: color.textTertiary, marginLeft: 3 }}>{unit}</span> : null}
      </span>
      {sub ? <span style={{ color: color.textTertiary, fontSize: fs.caption, fontVariantNumeric: 'tabular-nums' }}>{sub}</span> : null}
      {children}
    </div>
  );
}

const axis = { fill: color.textTertiary, fontSize: 10 } as const;

function Overview() {
  const sum = (from: number, to: number) => DAYS.slice(DAYS.length - to, DAYS.length - from).reduce((s, x) => s + x.total, 0);
  const week = sum(0, 7);
  const prev = sum(7, 14);
  const pct = Math.round(((week - prev) / Math.max(prev, 1)) * 100);
  let streak = 0;
  for (let i = DAYS.length - 1; i >= 0 && DAYS[i].total > 0; i--) streak++;
  let best = 0;
  let run = 0;
  for (const x of DAYS) {
    run = x.total ? run + 1 : 0;
    best = Math.max(best, run);
  }
  const spark = DAYS.slice(-14).map((x) => x.total);
  const max = Math.max(...spark, 1);
  const pts = spark.map((v, i) => `${(i / 13) * 110},${22 - (v / max) * 20}`).join(' ');
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: space[2] }}>
      <Tile title="今日" value={String(DAYS.at(-1)!.total)} unit="件" sub={`昨日 ${DAYS.at(-2)!.total} 件`} />
      <Tile title="直近7日" value={String(week)} unit="件" sub={`前週比 ${pct >= 0 ? '+' : ''}${pct}%`}>
        <svg width={112} height={24} aria-hidden>
          <polyline points={pts} fill="none" stroke={color.textSecondary} strokeWidth={1.5} strokeLinejoin="round" />
        </svg>
      </Tile>
      <Tile title="連続日数" value={String(streak)} unit="日" sub={`最長 ${best} 日`} />
      <Tile title="よく使う時間帯" value="21" unit="時台" sub="次いで 10 時台" />
    </div>
  );
}

function Calendar() {
  const [filter, setFilter] = useState<'すべて' | 'Claude Code' | 'Codex' | 'OpenCode'>('すべて');
  const pick = (x: (typeof DAYS)[number]) => (filter === 'すべて' ? x.total : x.by[AGENTS.find((a) => a.title === filter)!.id]);
  const pad = DAYS[0].d.getDay();
  const cells = [...Array(pad).fill(null), ...DAYS];
  const weeks = Array.from({ length: Math.ceil(cells.length / 7) }, (_, i) => cells.slice(i * 7, i * 7 + 7));
  return (
    <Section title="日別アクティビティ" aside={<Segmented value={filter} options={['すべて', 'Claude Code', 'Codex', 'OpenCode'] as const} onChange={setFilter} />}>
      <div className="scroll" style={{ overflowX: 'auto' }}>
        <div style={{ display: 'flex', gap: 2, width: 'max-content' }}>
          {weeks.map((w, i) => {
            const first = w.find((x) => x && x.d.getDate() <= 7 && x.d.getDay() === 0) ?? (i === 0 ? w.find(Boolean) : undefined);
            return (
              <div key={i} style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                <span style={{ height: 14, fontSize: 10, color: color.textTertiary, whiteSpace: 'nowrap', width: 10 }}>
                  {first ? `${first.d.getMonth() + 1}月` : ''}
                </span>
                {w.map((x, j) =>
                  x ? (
                    <div
                      key={j}
                      title={`${fmtDay(x.d)}\n依頼・追記 ${x.total} 件` + AGENTS.map((a) => (x.by[a.id] ? `\n${a.title}: ${x.by[a.id]} 件` : '')).join('')}
                      style={{ width: 10, height: 10, borderRadius: 2, background: levelFill(level(pick(x))) }}
                    />
                  ) : (
                    <div key={j} style={{ width: 10, height: 10 }} />
                  ),
                )}
              </div>
            );
          })}
        </div>
      </div>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: space[2], flexWrap: 'wrap', gap: space[2] }}>
        <Note>直近 1 年 · 右端が今日</Note>
        <div style={{ display: 'flex', alignItems: 'center', gap: 3 }}>
          <Note>少</Note>
          {[0, 1, 2, 3, 4].map((l) => (
            <div key={l} style={{ width: 10, height: 10, borderRadius: 2, background: levelFill(l) }} />
          ))}
          <Note>多</Note>
        </div>
      </div>
    </Section>
  );
}

function Punchcard() {
  const prof = [0.1, 0.05, 0.02, 0, 0, 0, 0.02, 0.1, 0.3, 0.6, 1, 0.85, 0.4, 0.6, 0.85, 0.8, 0.75, 0.6, 0.35, 0.45, 0.7, 1.1, 0.9, 0.4];
  const weekday = [0.35, 1, 1.1, 1, 1.05, 0.9, 0.45];
  const L = 28;
  const cw = 26;
  const ch = 20;
  return (
    <Section title="曜日 × 時間帯" aside={<Note>直近 90 日 · 円の大きさ = 依頼数</Note>}>
      <svg width="100%" viewBox={`0 0 ${L + 24 * cw} ${7 * ch + 22}`} role="img" aria-label="曜日と時間帯ごとの依頼数">
        {'日月火水木金土'.split('').map((n, r) => (
          <g key={n}>
            <text x={L - 10} y={r * ch + ch / 2 + 4} textAnchor="end" style={axis}>
              {n}
            </text>
            {prof.map((p, h) => {
              const v = Math.round(p * weekday[r] * 26);
              const rad = v ? Math.max(2, Math.sqrt(v / 30) * 8.5) : 1.5;
              return (
                <circle key={h} cx={L + h * cw + cw / 2} cy={r * ch + ch / 2} r={rad} fill={v ? color.textSecondary : color.divider} fillOpacity={v ? 0.85 : 1}>
                  <title>{`${n}曜 ${h}時台: ${v} 件`}</title>
                </circle>
              );
            })}
          </g>
        ))}
        {[0, 6, 12, 18, 23].map((h) => (
          <text key={h} x={L + h * cw + cw / 2} y={7 * ch + 16} textAnchor="middle" style={axis}>
            {h}時
          </text>
        ))}
      </svg>
    </Section>
  );
}

function MonthCompare() {
  const [mode, setMode] = useState<'依頼・追記' | '推定費用'>('依頼・追記');
  const k = mode === '推定費用' ? 0.82 : 1;
  const sep = DAYS.filter((x) => x.d.getMonth() === 8);
  const oct = DAYS.filter((x) => x.d.getMonth() === 9 && x.d.getFullYear() === 2026);
  const cum = (a: typeof DAYS) => a.reduce<number[]>((acc, x) => [...acc, (acc.at(-1) ?? 0) + x.total * k], []);
  const cs = cum(sep);
  const co = cum(oct);
  const max = Math.ceil(cs.at(-1)! / 50) * 50;
  const L = 40;
  const W = 600;
  const H = 130;
  const x = (d: number) => L + ((d - 1) / 30) * W;
  const y = (v: number) => 8 + H - (v / max) * H;
  const unit = mode === '推定費用' ? '$' : '';
  const diff = Math.round(co.at(-1)! - cs[co.length - 1]);
  return (
    <Section title="今月と先月" aside={<Segmented value={mode} options={['依頼・追記', '推定費用'] as const} onChange={setMode} />}>
      <svg width="100%" viewBox={`0 0 ${L + W + 140} ${H + 30}`} role="img" aria-label="今月と先月の累積">
        {[0, max / 2, max].map((v) => (
          <g key={v}>
            <line x1={L} x2={L + W} y1={y(v)} y2={y(v)} stroke={line.hairlineSoft} />
            <text x={L - 6} y={y(v) + 4} textAnchor="end" style={axis}>
              {unit}
              {v}
            </text>
          </g>
        ))}
        <polyline points={cs.map((v, i) => `${x(i + 1)},${y(v)}`).join(' ')} fill="none" stroke={color.textTertiary} strokeWidth={1.5} strokeDasharray="4 3" />
        <polyline points={co.map((v, i) => `${x(i + 1)},${y(v)}`).join(' ')} fill="none" stroke={color.textPrimary} strokeWidth={2} />
        <circle cx={x(co.length)} cy={y(co.at(-1)!)} r={3.5} fill={color.textPrimary} />
        <text x={x(co.length) + 8} y={y(co.at(-1)!) - 6} style={{ ...axis, fill: color.textPrimary }}>
          10月 {unit}
          {Math.round(co.at(-1)!)}(先月同日 {diff >= 0 ? '+' : ''}
          {diff})
        </text>
        <text x={x(31) + 6} y={y(cs.at(-1)!) + 4} style={axis}>
          9月 {unit}
          {Math.round(cs.at(-1)!)}
        </text>
        {[1, 10, 20, 31].map((d) => (
          <text key={d} x={x(d)} y={H + 26} textAnchor="middle" style={axis}>
            {d}日
          </text>
        ))}
      </svg>
      {mode === '推定費用' ? <Note>API 標準料金で換算した推定です。費用を算出できないセッション 6 件は含めていません。</Note> : null}
    </Section>
  );
}

function Bars({ values, max, label, ink }: { values: number[]; max: number; label: string; ink: string }) {
  const W = 600;
  const H = 60;
  const bw = W / values.length;
  return (
    <g>
      <text x={0} y={10} style={{ ...axis, fill: color.textSecondary, fontWeight: 600 }}>
        {label}
      </text>
      {values.map((v, i) =>
        v ? (
          <rect key={i} x={40 + i * bw + 2} y={24 + H - (v / max) * H} width={bw - 4} height={(v / max) * H} rx={2} fill={ink}>
            <title>{`${label}: ${v} 件`}</title>
          </rect>
        ) : null,
      )}
      <line x1={40} x2={40 + W} y1={24 + H} y2={24 + H} stroke={line.strong} />
      <text x={34} y={28} textAnchor="end" style={axis}>
        {max}
      </text>
    </g>
  );
}

function PromptsAndCommits() {
  const [project, setProject] = useState<'clair' | 'clair-docs' | 'scratch'>('clair');
  const last = DAYS.slice(-30);
  const prompts = last.map((x) => x.total);
  const commits = last.map((x, i) => (x.total === 0 ? 0 : Math.max(0, Math.round(x.total * 0.35 * (0.4 + ((i * 7) % 10) / 8)))));
  return (
    <Section title="依頼とコミット" aside={<Segmented value={project} options={['clair', 'clair-docs', 'scratch'] as const} onChange={setProject} />}>
      {project === 'scratch' ? (
        <div style={{ padding: '18px', border: `1px dashed ${line.strong}`, borderRadius: radius.card, textAlign: 'center', color: color.textTertiary, fontSize: fs.secondary }}>
          この Project は Git リポジトリではないため、コミット数を表示できません。
        </div>
      ) : (
        <svg width="100%" viewBox="0 0 640 210" role="img" aria-label="直近30日の依頼数とコミット数">
          <Bars values={prompts} max={Math.ceil(Math.max(...prompts) / 5) * 5} label="依頼・追記" ink={color.textSecondary} />
          <g transform="translate(0,100)">
            <Bars values={commits} max={Math.max(5, Math.ceil(Math.max(...commits) / 5) * 5)} label="コミット" ink={color.textTertiary} />
          </g>
          {[0, 7, 14, 21, 29].map((i) => (
            <text key={i} x={40 + (i + 0.5) * 20} y={204} textAnchor="middle" style={axis}>
              {`${last[i].d.getMonth() + 1}/${last[i].d.getDate()}`}
            </text>
          ))}
        </svg>
      )}
      <Note>直近 30 日 · あなたのコミット(merge を除く)</Note>
    </Section>
  );
}

function WaitTime() {
  const bins: [string, number][] = [
    ['〜10秒', 38], ['10〜30秒', 71], ['30秒〜1分', 64], ['1〜2分', 52], ['2〜5分', 41], ['5〜10分', 19], ['10〜30分', 8], ['30分+', 3],
  ];
  const W = 600;
  const H = 100;
  const bw = W / bins.length;
  return (
    <Section title="AI を待っている時間" aside={<Note>直近 7 日 · 依頼 296 件</Note>}>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: space[2], marginBottom: space[3] }}>
        <Tile title="待った時間の合計" value="4時間12分" />
        <Tile title="中央値" value="48" unit="秒" sub="Claude Code 62秒 · Codex 35秒" />
      </div>
      <svg width="100%" viewBox={`0 0 ${W + 40} ${H + 26}`} role="img" aria-label="応答時間の分布">
        {bins.map(([n, v], i) => (
          <g key={n}>
            <rect x={40 + i * bw + 3} y={4 + H - (v / 80) * H} width={bw - 6} height={(v / 80) * H} rx={2} fill={color.textSecondary}>
              <title>{`${n}: ${v} 件`}</title>
            </rect>
            <text x={40 + i * bw + bw / 2} y={H + 20} textAnchor="middle" style={axis}>
              {n}
            </text>
          </g>
        ))}
        <line x1={40} x2={40 + W} y1={4 + H} y2={4 + H} stroke={line.strong} />
        <line x1={40 + 2.6 * bw} x2={40 + 2.6 * bw} y1={4} y2={4 + H} stroke={color.textPrimary} strokeDasharray="3 3" />
        <text x={40 + 2.6 * bw + 5} y={14} style={{ ...axis, fill: color.textPrimary }}>
          中央値 48秒
        </text>
      </svg>
    </Section>
  );
}

function Concurrency() {
  const [mode, setMode] = useState<'今日' | '直近7日の平均'>('今日');
  const steps: [number, number][] = mode === '今日'
    ? [[0, 0], [8.8, 1], [9.3, 2], [10.4, 3], [10.9, 2], [11.5, 4], [12.1, 2], [12.6, 0], [13.2, 1], [13.9, 3], [14.5, 3]]
    : [[0, 0], [8, 0.4], [9, 1.1], [10, 1.8], [11, 2.2], [12, 1.2], [13, 1.4], [14, 2], [15, 1.9], [17, 1.3], [19, 0.6], [21, 1.1], [23, 0.4], [24, 0.4]];
  const W = 600;
  const H = 90;
  const x = (h: number) => 40 + (h / 24) * W;
  const y = (v: number) => 4 + H - (v / 4) * H;
  let d = `M${x(0)},${y(0)}`;
  steps.forEach(([h, v], i) => {
    if (i) d += `H${x(h)}`;
    d += `V${y(v)}`;
  });
  d += `H${x(steps.at(-1)![0])}`;
  return (
    <Section title="同時に動いたエージェント数" aside={<Segmented value={mode} options={['今日', '直近7日の平均'] as const} onChange={setMode} />}>
      <svg width="100%" viewBox={`0 0 ${W + 50} ${H + 26}`} role="img" aria-label="同時に動いたエージェント数">
        {[0, 1, 2, 3, 4].map((v) => (
          <g key={v}>
            <line x1={40} x2={40 + W} y1={y(v)} y2={y(v)} stroke={line.hairlineSoft} />
            <text x={34} y={y(v) + 4} textAnchor="end" style={axis}>
              {v}
            </text>
          </g>
        ))}
        <path d={`${d}V${y(0)}Z`} fill={withAlpha(color.textSecondary, 0.16)} />
        <path d={d} fill="none" stroke={color.textSecondary} strokeWidth={1.5} />
        {[0, 6, 12, 18, 24].map((h) => (
          <text key={h} x={x(h)} y={H + 20} textAnchor="middle" style={axis}>
            {h}時
          </text>
        ))}
      </svg>
      <Note>{mode === '今日' ? '最大 4 本(11:30) · 2 本以上で並列していた時間 2時間40分' : '時間帯ごとの平均 · 最大 2.2 本(11 時台)'}</Note>
    </Section>
  );
}

const cell = { padding: '7px 6px', borderTop: `1px solid ${line.hairlineSoft}`, fontVariantNumeric: 'tabular-nums' } as const;
const num = { ...cell, textAlign: 'right' } as const;
const head = { padding: '0 6px 6px', color: color.textTertiary, fontWeight: 400, textAlign: 'left' } as const;

function Agents() {
  const rows: [Agent, number, string, string?][] = [
    ['claude', 1498, '$1,428.29'],
    ['codex', 899, '$527.15'],
    ['opencode', 262, '$34.88', '費用不明 6 セッション'],
  ];
  return (
    <Section title="エージェント別" aside={<Note>全期間 · 推定費用は API 換算で、請求額ではありません</Note>}>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: space[2] }}>
        {rows.map(([a, n, usd, note]) => (
          <div key={a} style={{ flex: '1 1 150px', padding: '10px 12px', background: color.canvas, borderRadius: radius.card, display: 'flex', flexDirection: 'column', gap: 2, fontSize: fs.secondary }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: space[1], color: color.textSecondary }}>
              <AgentIcon agent={a} />
              {AGENTS.find((x) => x.id === a)!.title}
            </span>
            <span style={{ fontSize: fs.title, fontWeight: 600, fontVariantNumeric: 'tabular-nums' }}>{n} 件</span>
            <span style={{ color: color.textTertiary, fontSize: fs.caption }}>
              推定 {usd}
              {note ? ` · ${note}` : ''}
            </span>
          </div>
        ))}
      </div>
    </Section>
  );
}

function Models() {
  const [range, setRange] = useState<'7日' | '30日' | '全期間'>('30日');
  const rows: [string, Agent, number, number | null][] = [
    ['claude-opus-5-5', 'claude', 48, 312.4],
    ['gpt-6-sol', 'codex', 37, 121.7],
    ['claude-sonnet-5', 'claude', 61, 88.1],
    ['gpt-6-luna', 'codex', 22, 6.3],
    ['OpenCode', 'opencode', 19, null],
  ];
  const total = rows.reduce((s, r) => s + (r[3] ?? 0), 0);
  return (
    <Section title="モデル別" aside={<Segmented value={range} options={['7日', '30日', '全期間'] as const} onChange={setRange} />}>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: fs.secondary }}>
        <thead>
          <tr>
            <th style={{ ...head, width: 24 }}>#</th>
            <th style={head}>モデル</th>
            <th style={{ ...head, textAlign: 'right' }}>セッション</th>
            <th style={{ ...head, textAlign: 'right' }}>推定費用</th>
            <th style={{ ...head, width: '26%' }}>割合</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(([m, a, n, usd], i) => (
            <tr key={m}>
              <td style={{ ...cell, color: color.textTertiary }}>{usd == null ? '—' : i + 1}</td>
              <td style={cell}>
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: space[1] }} className="cl">
                  <AgentIcon agent={a} />
                  {m}
                </span>
              </td>
              <td style={num}>{n}</td>
              <td style={{ ...num, color: usd == null ? color.textTertiary : undefined }}>{usd == null ? '算出不可' : `$${usd.toFixed(2)}`}</td>
              <td style={cell}>
                {usd == null ? null : (
                  <div title={`${((usd / total) * 100).toFixed(1)}%`} style={{ height: 6, borderRadius: 3, background: color.surfaceActive }}>
                    <div style={{ width: `${(usd / total) * 100}%`, height: '100%', borderRadius: 3, background: color.textSecondary }} />
                  </div>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </Section>
  );
}

function Sessions() {
  const rows: [string, string, Agent, number, number][] = [
    ['エディタの minimap を実装', 'clair', 'claude', 34, 41.2],
    ['Ghostty の resize で落ちる件', 'clair', 'codex', 21, 18.75],
    ['docs-site の検索を Pagefind に', 'clair-docs', 'claude', 17, 12.9],
    ['設定画面の検索', 'clair', 'claude', 11, 9.42],
    ['zsh の起動を速く', 'dotfiles', 'codex', 9, 4.1],
  ];
  return (
    <Section title="費用の大きいセッション" aside={<Note>直近 30 日 · 上位 5 件</Note>}>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: fs.secondary }}>
        <thead>
          <tr>
            <th style={{ ...head, width: 24 }}>#</th>
            <th style={head}>セッション</th>
            <th style={head}>Project</th>
            <th style={{ ...head, textAlign: 'right' }}>依頼</th>
            <th style={{ ...head, textAlign: 'right' }}>推定</th>
            <th style={head} />
          </tr>
        </thead>
        <tbody>
          {rows.map(([t, p, a, n, usd], i) => (
            <tr key={t} className="hoverable">
              <td style={{ ...cell, color: color.textTertiary }}>{i + 1}</td>
              <td style={cell}>
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: space[1] }}>
                  <AgentIcon agent={a} />
                  {t}
                </span>
              </td>
              <td style={{ ...cell, color: color.textTertiary }}>{p}</td>
              <td style={num}>{n}</td>
              <td style={num}>${usd.toFixed(2)}</td>
              <td style={{ ...cell, textAlign: 'right' }}>
                <button className="btn-secondary" style={{ minHeight: 22, padding: '0 8px', borderRadius: radius.control, fontSize: fs.caption }}>
                  再開
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </Section>
  );
}

function Group({ title }: { title: string }) {
  return (
    <div style={{ margin: '20px 0 8px', color: color.textTertiary, fontSize: fs.caption, fontWeight: 600, letterSpacing: '0.04em' }}>{title}</div>
  );
}

export function UsageSection() {
  return (
    <>
      <div style={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'center', gap: space[2], marginTop: -12, marginBottom: space[2] }}>
        <Note>14:32 に集計</Note>
        <button className="btn-secondary" style={{ minHeight: 24, padding: '0 8px', borderRadius: radius.control, fontSize: fs.caption }}>
          再集計
        </button>
      </div>
      <Group title="アクティビティ" />
      <Section title="概要">
        <Overview />
      </Section>
      <Calendar />
      <Punchcard />
      <MonthCompare />
      <PromptsAndCommits />
      <Group title="待ち時間と並列" />
      <WaitTime />
      <Concurrency />
      <Group title="ランキング" />
      <Agents />
      <Models />
      <Sessions />
    </>
  );
}
