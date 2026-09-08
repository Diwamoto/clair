#!/usr/bin/env python3
from pathlib import Path
import json, hashlib
root = Path(__file__).resolve().parent
pins = json.loads((root/'Package.resolved').read_text())['pins']
items=[]
for pin in pins:
    matches=[p for p in (root/'.build/checkouts').iterdir() if p.name.lower()==pin['identity']]
    notices=[]
    if matches:
        for p in matches[0].iterdir():
            if p.is_file() and p.name.lower().startswith(('license','copying')):
                notices.append({'file':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'first_lines':p.read_text(errors='replace')[:180]})
    items.append({**pin,'root_license_files':notices})
(root/'evidence/dependencies.json').write_text(json.dumps(items,indent=2))
grammars=root/'.build/checkouts/CodeEditLanguages/CodeLanguages-Container/CodeLanguages-Container.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
(root/'evidence/grammar-source-pins.json').write_bytes(grammars.read_bytes())
