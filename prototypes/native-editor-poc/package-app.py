#!/usr/bin/env python3
from pathlib import Path
import shutil, plistlib
root = Path(__file__).resolve().parent
app = root / '.build/Clair Native PoC.app'
# Only recreates the generated PoC bundle; never touches Clair Stable/Dev.
if app.exists():
    for p in app.rglob('*'):
        if p.is_file(): p.chmod(0o644)
    shutil.rmtree(app)
(app/'Contents/MacOS').mkdir(parents=True)
shutil.copy2(root/'.build/release/NativeEditorPoC', app/'Contents/MacOS/NativeEditorPoC')
for source in (root/'.build/release').glob('*.bundle'):
    target = app/source.name
    shutil.copytree(source, target)
    # CLI's flat bundle + folder named Resources causes Bundle.resourceURL to
    # already end in Resources; upstream appends another Resources component.
    if source.name == 'CodeEditLanguages_CodeEditLanguages.bundle':
        shutil.copytree(source/'Resources', target/'Resources/Resources')
with (app/'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleExecutable':'NativeEditorPoC','CFBundleIdentifier':'com.diwamoto.clair.native-poc','CFBundleName':'Clair Native PoC','CFBundlePackageType':'APPL','NSHighResolutionCapable':True},f)
