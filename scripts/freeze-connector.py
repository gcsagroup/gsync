"""仅在构建机运行：生成独立连接器，并随包保留运行时的授权文本。"""
from pathlib import Path
from importlib import metadata
import shutil, subprocess, sys, sysconfig
root = Path(__file__).resolve().parents[1]
out = root/'build/mac-connector'
out.mkdir(exist_ok=True)
notices = out/'ConnectorNotices'
if notices.exists():
    shutil.rmtree(notices)
notices.mkdir()
for lock in ('requirements-lock.txt', 'requirements-build.txt'):
    for line in (root/'tools/connectors'/lock).read_text().splitlines():
        if line.startswith('-r '):
            continue
        name, version = line.split('==')
        dist = metadata.distribution(name)
        if dist.version != version:
            sys.exit('请先安装锁定的连接器构建依赖：'+name)
        for item in dist.files or []:
            if '.dist-info/' in str(item) and any(s in str(item).lower() for s in ('license','notice','copying')):
                dest = notices/name/str(item).split('.dist-info/',1)[1]
                dest.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(dist.locate_file(item),dest)
shutil.copyfile(Path(sysconfig.get_path('stdlib'))/'LICENSE.txt',notices/'Python-LICENSE.txt')
subprocess.run([sys.executable,'-m','PyInstaller','--noconfirm','--onefile','--name','pbsync-connector',
                '--distpath',out,'--specpath',out,'--workpath',out/'work',
                '--collect-all','pykeepass','--copy-metadata','pykeepass',
                '--hidden-import','_cffi_backend',root/'tools/connectors/connector.py'],check=True)
