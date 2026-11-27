import Foundation

// The HTML tools that ship with Clair (`HTMLTools.builtin`). Each is one self-contained page.
extension HTMLTools {
  /// Paste a `terraform plan` / `terragrunt plan` output, pick resources, copy the `-target` apply command.
  static let terraformPlan = ##"""
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Terraform Plan Picker</title>
<style>
  :root {
    --bg: #fbfbfa; --surface: #ffffff; --line: #e4e4e0; --text: #1d1d1b; --muted: #6b6b66;
    --add: #1a7f37; --add-bg: #e7f5ea; --del: #c4321f; --del-bg: #fbe9e6; --chg: #9a6700; --chg-bg: #fbf3dc;
    --rep: #8250df; --rep-bg: #f1ebfc; --dim: #8c8c86; --focus: #2f6feb; --sel: #eef3fe;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #1b1b1a; --surface: #232322; --line: #353533; --text: #ebebe7; --muted: #9b9b95;
      --add: #57c26b; --add-bg: #1f3324; --del: #f0735f; --del-bg: #3a2420; --chg: #d9a93a; --chg-bg: #362e1a;
      --rep: #b493f5; --rep-bg: #2e2540; --dim: #74746f; --focus: #6d9bff; --sel: #24304a;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif; }
  code, pre, textarea, .addr { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px; }
  header { padding: 12px 16px; border-bottom: 1px solid var(--line); display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  header h1 { font-size: 14px; margin: 0 8px 0 0; }
  textarea { width: 100%; height: 160px; padding: 8px; border: 1px solid var(--line); border-radius: 6px; background: var(--surface); color: var(--text); resize: vertical; }
  #input { padding: 12px 16px; }
  #input.folded { display: none; }
  button, select, input[type=search] { font: inherit; color: var(--text); background: var(--surface); border: 1px solid var(--line); border-radius: 6px; padding: 3px 10px; }
  button { cursor: pointer; } button:hover { border-color: var(--muted); }
  button.primary { background: var(--focus); border-color: var(--focus); color: #fff; }
  .chip { border-radius: 999px; padding: 1px 10px; }
  .chip[aria-pressed="false"] { opacity: .45; }
  input[type=search] { flex: 1; min-width: 160px; }
  #summary { color: var(--muted); }
  #list { padding: 8px 16px 120px; }
  .row { background: var(--surface); border: 1px solid var(--line); border-radius: 6px; margin-bottom: 6px; }
  .row.focused { outline: 2px solid var(--focus); outline-offset: -1px; }
  .row.selected { background: var(--sel); }
  .row.applied { opacity: .45; }
  .head { display: flex; align-items: center; gap: 8px; padding: 6px 10px; cursor: pointer; }
  .head input { margin: 0; }
  .addr { flex: 1; overflow-wrap: anywhere; }
  .badge { font-size: 11px; padding: 0 8px; border-radius: 999px; white-space: nowrap; }
  .create { color: var(--add); background: var(--add-bg); } .update { color: var(--chg); background: var(--chg-bg); }
  .delete { color: var(--del); background: var(--del-bg); } .replace { color: var(--rep); background: var(--rep-bg); }
  .other { color: var(--muted); background: var(--line); }
  pre { margin: 0; padding: 8px 12px; border-top: 1px solid var(--line); overflow-x: auto; }
  pre .a { color: var(--add); } pre .d { color: var(--del); } pre .c { color: var(--chg); } pre .r { color: var(--rep); } pre .n { color: var(--dim); }
  footer { position: fixed; left: 0; right: 0; bottom: 0; background: var(--surface); border-top: 1px solid var(--line); padding: 8px 16px; display: flex; flex-direction: column; gap: 6px; }
  footer .bar { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  #cmd { max-height: 64px; overflow: auto; padding: 4px 8px; background: var(--bg); border: 1px solid var(--line); border-radius: 6px; white-space: pre-wrap; overflow-wrap: anywhere; }
  .hint { color: var(--muted); font-size: 11px; }
  .empty { color: var(--muted); padding: 32px 0; text-align: center; }
</style>
</head>
<body>
<header>
  <h1>Terraform Plan Picker</h1>
  <span id="summary"></span>
  <span style="flex:1"></span>
  <button id="toggleInput">plan を貼り直す</button>
</header>
<section id="input">
  <textarea id="plan" placeholder="terraform plan / terragrunt plan の出力をここに貼り付け（ANSI 色・terragrunt の行頭プレフィックスはそのままで可）"></textarea>
</section>
<header id="filters" hidden>
  <span id="chips"></span>
  <input type="search" id="q" placeholder="アドレスで絞り込み (/)">
  <button id="selAll">表示中を全選択</button>
  <button id="selNone">選択解除</button>
  <label><input type="checkbox" id="hideApplied"> 適用済みを隠す</label>
</header>
<main id="list"></main>
<footer>
  <div class="bar">
    <select id="mode">
      <option value="terraform apply">terraform apply</option>
      <option value="terragrunt apply">terragrunt apply</option>
      <option value="terraform plan">terraform plan</option>
      <option value="terragrunt plan">terragrunt plan</option>
      <option value="">-target だけ</option>
    </select>
    <span id="count">0 件選択</span>
    <span style="flex:1"></span>
    <button id="markApplied">選択を適用済みにする</button>
    <button id="copy" class="primary">コマンドをコピー</button>
  </div>
  <code id="cmd"></code>
  <span class="hint">j/k 移動 · x/Space 選択 · o/Enter 開閉 · / 検索 · c コピー · -target は依存先も一緒に apply します（apply 前の plan 表示で確認）</span>
</footer>
<script>
const ACTIONS = [
  ["is tainted, so must be replaced", "replace"], ["must be replaced", "replace"], ["will be replaced", "replace"],
  ["will be created", "create"], ["will be updated in-place", "update"], ["will be destroyed", "delete"],
  ["will be read during apply", "read"], ["has moved to", "move"], ["will be imported", "import"],
  ["will no longer be managed by Terraform", "forget"], ["will be forgotten", "forget"],
];
const LABEL = { create: "作成", update: "変更", replace: "置換", delete: "削除", read: "読み取り", move: "移動", import: "import", forget: "管理外へ" };
const HEADER = new RegExp("^\\s*# ([^(\\s].*?) (" + ACTIONS.map(a => a[0].replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|") + ")");
const ANSI = /\x1b\[[0-9;]*[A-Za-z]/g;
// terragrunt ≥0.67: "15:04:05.000 STDOUT [unit] tofu: <line>"
// ponytail: the [unit] is dropped; run-all plans spanning units need a per-unit `cd`, add when that comes up.
const TG = /^\S+\s+(STDOUT|STDERR)\s+(\[[^\]]*\]\s+)?\S+:\s?/;

let items = [], shown = [], focus = 0, filter = new Set(Object.keys(LABEL));
const $ = id => document.getElementById(id);

function parse(text) {
  const lines = text.replace(ANSI, "").split(/\r?\n/).map(l => l.replace(TG, ""));
  let start = lines.findLastIndex(l => /will perform the following actions:/.test(l));
  const out = []; let cur = null; let plan = "";
  for (let i = start + 1; i < lines.length; i++) {
    const l = lines[i];
    if (/^\s*(Plan|Changes to Outputs):/.test(l) || /^─{5,}/.test(l.trim())) { if (/^\s*Plan:/.test(l)) plan = l.trim(); cur = null; continue; }
    const m = l.match(HEADER);
    if (m) { cur = { addr: m[1], action: ACTIONS.find(a => a[0] === m[2])[1], body: [l.trim()], selected: false, applied: false, open: false }; out.push(cur); continue; }
    if (cur) cur.body.push(l);
  }
  for (const it of out) { while (it.body.length && !it.body.at(-1).trim()) it.body.pop(); it.body = dedent(it.body); }
  return { items: out, plan };
}
function dedent(body) {
  const ind = Math.min(...body.slice(1).filter(l => l.trim()).map(l => l.match(/^ */)[0].length));
  return [body[0], ...body.slice(1).map(l => l.slice(isFinite(ind) ? ind : 0))];
}
function lineClass(l) {
  const t = l.trimStart();
  return /^(-\/\+|\+\/-)/.test(t) ? "r" : t[0] === "+" ? "a" : t[0] === "-" ? "d" : t[0] === "~" ? "c" : /^(#|<=)/.test(t) ? "n" : "";
}
function badgeClass(a) { return ["create", "update", "delete", "replace"].includes(a) ? a : "other"; }

function load() {
  const r = parse($("plan").value);
  items = r.items; focus = 0;
  $("summary").textContent = items.length ? (r.plan || items.length + " 件") : "";
  $("input").classList.toggle("folded", items.length > 0);
  $("filters").hidden = !items.length;
  if (items.length) $("plan").blur();  // the folded textarea would otherwise swallow j/k
  renderChips(); render();
}
function renderChips() {
  const chips = $("chips"); chips.textContent = "";
  for (const a of Object.keys(LABEL)) {
    const n = items.filter(i => i.action === a).length;
    if (!n) continue;
    const b = document.createElement("button");
    b.className = "chip badge " + badgeClass(a); b.textContent = `${LABEL[a]} ${n}`;
    b.setAttribute("aria-pressed", filter.has(a));
    b.onclick = () => { filter.has(a) ? filter.delete(a) : filter.add(a); renderChips(); render(); };
    chips.append(b, " ");
  }
}
function render() {
  const q = $("q").value.trim().toLowerCase();
  shown = items.filter(i => filter.has(i.action) && (!q || i.addr.toLowerCase().includes(q)) && !(i.applied && $("hideApplied").checked));
  focus = Math.max(0, Math.min(focus, shown.length - 1));
  const list = $("list"); list.textContent = "";
  if (!items.length) { list.innerHTML = '<p class="empty">plan の出力を貼り付けると、リソースごとに並びます。</p>'; }
  shown.forEach((it, idx) => {
    const row = document.createElement("div");
    row.className = "row" + (it.selected ? " selected" : "") + (it.applied ? " applied" : "") + (idx === focus ? " focused" : "");
    const head = document.createElement("div"); head.className = "head";
    const cb = document.createElement("input"); cb.type = "checkbox"; cb.checked = it.selected; cb.disabled = it.applied;
    cb.onclick = e => { e.stopPropagation(); it.selected = cb.checked; focus = idx; render(); };
    const badge = document.createElement("span"); badge.className = "badge " + badgeClass(it.action); badge.textContent = LABEL[it.action];
    const addr = document.createElement("span"); addr.className = "addr"; addr.textContent = it.addr;
    head.append(cb, badge, addr);
    if (it.applied) { const s = document.createElement("span"); s.className = "badge other"; s.textContent = "適用済み"; head.append(s); }
    head.onclick = () => { it.open = !it.open; focus = idx; render(); };
    row.append(head);
    if (it.open) {
      const pre = document.createElement("pre");
      for (const l of it.body) { const s = document.createElement("span"); s.className = lineClass(l); s.textContent = l + "\n"; pre.append(s); }
      row.append(pre);
    }
    list.append(row);
  });
  renderCmd();
  list.querySelector(".focused")?.scrollIntoView({ block: "nearest" });
}
const quote = s => "'" + s.replace(/'/g, "'\\''") + "'";
function command() {
  const sel = items.filter(i => i.selected && !i.applied);
  if (!sel.length) return "";
  const targets = sel.map(i => "-target=" + quote(i.addr));
  const mode = $("mode").value;
  return (mode ? [mode, ...targets] : targets).join(sel.length > 2 ? " \\\n  " : " ");
}
function renderCmd() {
  const n = items.filter(i => i.selected && !i.applied).length;
  $("count").textContent = n + " 件選択";
  $("cmd").textContent = command() || "リソースを選ぶと -target 付きのコマンドがここに出ます";
}
async function copy() {
  const c = command(); if (!c) return;
  try { await navigator.clipboard.writeText(c); }
  catch { const t = document.createElement("textarea"); t.value = c; document.body.append(t); t.select(); document.execCommand("copy"); t.remove(); }
  $("copy").textContent = "コピーしました"; setTimeout(() => $("copy").textContent = "コマンドをコピー", 1200);
}

$("plan").addEventListener("input", load);
$("toggleInput").onclick = () => { $("input").classList.remove("folded"); $("plan").focus(); $("plan").select(); };
$("q").addEventListener("input", render);
$("hideApplied").onchange = render;
$("mode").onchange = renderCmd;
$("selAll").onclick = () => { shown.forEach(i => { if (!i.applied) i.selected = true; }); render(); };
$("selNone").onclick = () => { items.forEach(i => i.selected = false); render(); };
$("markApplied").onclick = () => { items.forEach(i => { if (i.selected) { i.applied = true; i.selected = false; } }); render(); };
$("copy").onclick = copy;
document.addEventListener("keydown", e => {
  if (e.target.matches?.("textarea, input[type=search]") || e.metaKey || e.ctrlKey || e.altKey) {
    if (e.key === "Escape") e.target.blur();
    return;
  }
  const it = shown[focus];
  if (e.key === "j" || e.key === "ArrowDown") focus = Math.min(focus + 1, shown.length - 1);
  else if (e.key === "k" || e.key === "ArrowUp") focus = Math.max(focus - 1, 0);
  else if ((e.key === "x" || e.key === " ") && it && !it.applied) it.selected = !it.selected;
  else if ((e.key === "o" || e.key === "Enter") && it) it.open = !it.open;
  else if (e.key === "/") { e.preventDefault(); $("q").focus(); return; }
  else if (e.key === "c") { copy(); return; }
  else return;
  e.preventDefault(); render();
});
render();
</script>
</body>
</html>
"""##
}
