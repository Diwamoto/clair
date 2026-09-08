#!/usr/bin/env python3
from pathlib import Path
import hashlib, json
root = Path(__file__).parent / 'fixtures'
root.mkdir(exist_ok=True)
samples = {
 'normal.swift': '// 日本語 👨‍👩‍👧‍👦 e\u0301\n/* multi\n line */\nlet text = """\n日本語 🙂\n"""\nlet count = 42\n',
 'sample.rs': '/* nested /* comment */ comment */\nfn main() { let s = r#"日本語\n🙂"#; println!("{}", s); }\n',
 'sample.ts': '/* comment\ncontinued */\nconst name: string = `日本語 ${1 + 2}`;\n',
 'sample.tsx': '/* 日本語 */\nexport const View = () => <div title="🙂">{`hello ${42}`}</div>;\n',
 'sample.json': '{"日本語": "🙂", "escaped": "line\\nnext", "value": 42, "ok": true}\n',
 'sample.md': '# 日本語 🙂\n\n```swift\nlet x = "hi"\n```\n\n**bold** and `inline`\n',
}
for name, text in samples.items(): (root/name).write_text(text)
line = 'let value = "日本語 🙂" // sample\n'
for n in [1, 10]:
    target = n * 1024 * 1024
    (root/f'{n}mb.swift').write_text(line * (target // len(line.encode())))
(root/'long-line.ts').write_text('const x = "' + 'a' * (1024 * 1024) + '";')
(root/'large-old.txt').write_text('\n'.join(f'line {i}' for i in range(10000)))
(root/'large-new.txt').write_text('\n'.join(f'changed {i}' if i % 5 == 0 else f'line {i}' for i in range(10000)))
manifest = {p.name: {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(root.iterdir())}
(Path(__file__).parent/'evidence/fixtures.json').write_text(json.dumps(manifest, indent=2))
