#!/usr/bin/env python3
"""从固定路径的已验证 Mac 候选生成只含 App 的本地只读安装镜像。"""
import os, plistlib, subprocess, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[1]
app = root/'build/GCSA-PBsync.app'
out = root/'build/distribution'
out.mkdir(exist_ok=True)
subprocess.run(['codesign','--verify','--deep','--strict',app],check=True)
if not os.access(app/'Contents/Resources/pbsync-connector',os.X_OK):
    raise SystemExit('缺少可执行的包内连接器')
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
name = f"PBsync-Mac-{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}"
with tempfile.TemporaryDirectory(dir=out) as tmp:
    stage = Path(tmp)/'image'
    stage.mkdir()
    subprocess.run(['ditto',app,stage/app.name],check=True)
    pending = Path(tmp)/'candidate.dmg'
    subprocess.run(['hdiutil','create','-volname',name,'-srcfolder',stage,'-format','UDZO',pending],check=True)
    subprocess.run(['hdiutil','verify',pending],check=True)
    pending.replace(out/(name+'.dmg'))
print(out/(name+'.dmg'))
