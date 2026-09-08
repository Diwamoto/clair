#!/usr/bin/env python3
"""Freeze a read-only copy of the user's current EditorWeb build for comparison."""
from pathlib import Path
import shutil, hashlib, json, datetime
root = Path(__file__).resolve().parent
source = Path('/Users/daiki/Projects/clair/apple/ClairApp/EditorWeb')
target = root / '.build/baseline-web'
if target.exists(): raise SystemExit('Baseline already frozen; retain it for reproducibility.')
shutil.copytree(source, target)
manifest = {'source':str(source),'captured_at':datetime.datetime.now().astimezone().isoformat(), 'files': {str(p.relative_to(target)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(target.rglob('*')) if p.is_file()}}
(root/'evidence/web-baseline.json').write_text(json.dumps(manifest, indent=2))
