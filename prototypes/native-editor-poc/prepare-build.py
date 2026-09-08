#!/usr/bin/env python3
"""Swift CLI does not synthesize Bundle.module for implicit xcassets (Xcode does).
Copy catalog as a resource so API builds. Custom symbol images may be unavailable;
PoC does not rely on those images. Never patches the original Clair checkout.
"""
from pathlib import Path
p = Path(__file__).parent / '.build/checkouts/CodeEditSymbols/Package.swift'
s = p.read_text()
old = 'name: "CodeEditSymbols",\n            dependencies: []'
new = old + ',\n            resources: [.copy("Symbols.xcassets")]'
if new not in s:
    assert old in s
    p.chmod(0o644)
    p.write_text(s.replace(old, new))
