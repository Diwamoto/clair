#!/usr/bin/env python3
from pathlib import Path
import json, statistics, math
root = Path(__file__).resolve().parent

def stats(values):
    return f'{statistics.median(values):.2f} / {sorted(values)[math.ceil(len(values)*.95)-1]:.2f}'
lines=['# 測定値（生JSONから生成）','', '単位ms。反復操作は中央値 / p95（20回、nearest-rank）。API完了境界は実装ごとに異なる。速度比にしない。','']
for filename in ['benchmark','benchmark-async']:
    data=json.loads((root/f'evidence/{filename}.json').read_text())
    lines += [f'## Native: {filename}', '', '|fixture|同期初期配置|初回可視色付け検出|入力|スクロール|2タブ往復|累積max RSS MiB|CPU秒|','|---|---:|---:|---:|---:|---:|---:|---:|']
    for x in data:
        if 'construct_layout_ms' in x:
            lines.append(f"|{x['fixture']}|{x['construct_layout_ms']:.2f}|{x['first_visible_highlight_ms']:.2f}|{stats(x['input_sync_ms'])}|{stats(x['scroll_sync_ms'])}|{stats(x['two_tab_switch_sync_ms'])}|{x['process_maxrss_bytes']/1048576:.1f}|{x['process_cpu_seconds']:.2f}|")
        elif 'construct_ms' in x: lines += ['',f"50追加タブの生成・表示: {x['construct_ms']:.2f}ms。"]
        elif 'alignment_ms' in x: lines += ['',f"10,000行/2,000置換diff: 配置計算 {x['alignment_ms']:.2f}ms、配置＋表示 {x['alignment_and_display_ms']:.2f}ms、スクロール {stats(x['scroll_sync_ms'])}ms。"]
    lines += ['']
data=json.loads((root/'evidence/web.json').read_text())
lines += ['## Current Clair Web assets in WKWebView', '', '|fixture|setDocument往復|選択往復|スクロール往復|20選択で届いた本文MiB|','|---|---:|---:|---:|---:|']
for x in data:
    if 'fixture' not in x: continue
    lines.append(f"|{x['fixture']}|{x['set_document_roundtrip_ms']:.2f}|{stats(x['selection_roundtrip_ms'])}|{stats(x['scroll_roundtrip_ms'])}|{x['selection_bridge_content_bytes']/1048576:.2f}|")
data=json.loads((root/'evidence/vscode.json').read_text())
lines += ['',f"## VS Code {data['version']} / isolated extension host", '', '|fixture|open＋show API|入力API|reveal API|2タブ往復API|','|---|---:|---:|---:|---:|']
for x in data['results']:
    if 'input_api_ms' in x:
        lines.append(f"|{x['fixture']}|{x['open_show_api_ms']:.2f}|{stats(x['input_api_ms'])}|{stats(x['scroll_api_ms'])}|{stats(x['two_tab_switch_api_ms'])}|")
    else: lines += ['',str(x)]
(root/'MEASUREMENTS.md').write_text('\n'.join(lines)+'\n')
