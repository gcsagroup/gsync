#!/usr/bin/env python3
"""按构建输入白名单生成内部源码候选，并校验锁定版本、依赖声明及归档正文。"""
import hashlib
import json
import os
import subprocess
import tempfile
import zipfile
from importlib import metadata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build/distribution'
OUT.mkdir(parents=True,exist_ok=True)
inputs = {}
inventory = []


def include(name, data):
    if name in inputs:
        raise ValueError('归档路径重复：'+name)
    inputs[name] = data


def include_file(file):
    if file.is_symlink() or not file.is_file():
        raise ValueError('无法归档输入：'+str(file))
    include(str(file.relative_to(ROOT)),file.read_bytes())


for name in ('VERSION','BUILD_NUMBER','Package.swift','Package.resolved','apps/Apple/project.yml'):
    include_file(ROOT/name)
patterns = {
    'Sources':['*/*.swift'], 'Tests':['*.py','*.mjs','*Tests/*.swift'],
    'apps/Apple':['CredentialProvider/*.swift','Resources/*.plist','Resources/*.entitlements'],
    'scripts':['*.py'], 'services/local':['*.py'],
    'extensions/browser':['*.mjs','*.js','*.html','*.css','manifest.json'],
    'tools/format-check':['dotnet/FormatCheck.csproj','dotnet/Program.cs','java/FormatCheck.java'],
    'tools/connectors':['connector.py','requirements*.txt'],
    'fixtures':['README.md','bookmarks.html','logins.csv','synthetic.1pux','keepassxc-3.1.kdbx',
                'safari-zh-simulator.zip','format-v1/expected.json','format-v1/synthetic-v1.pbsync'],
    'distribution':['BUILD.md','open-gates.json','licenses/ZIPFoundation-MIT.txt']}
for directory, globs in patterns.items():
    for pattern in globs:
        for file in sorted((ROOT/directory).glob(pattern)):
            include_file(file)

pin, = json.loads((ROOT/'Package.resolved').read_text())['pins']
checkout = ROOT/'build/swift/checkouts/ZIPFoundation'
if subprocess.check_output(['git','-C',checkout,'rev-parse','HEAD'],text=True).strip()!=pin['state']['revision']:
    raise ValueError('Swift 依赖检出与锁文件不一致')
notice = 'distribution/licenses/ZIPFoundation-MIT.txt'
if inputs[notice] != (checkout/'LICENSE').read_bytes():
    raise ValueError('ZIPFoundation 授权文本与锁定依赖不一致')
inventory.append({'package':'ZIPFoundation',**pin['state'],'license':'MIT','files':[notice],'scope':'主包及扩展'})
runtime = (ROOT/'tools/connectors/requirements-lock.txt').read_text().splitlines()
packaging = [line for line in (ROOT/'tools/connectors/requirements-build.txt').read_text().splitlines() if not line.startswith('-r ')]
for line in runtime + packaging:
    name,version = line.split('==')
    dependency = metadata.distribution(name)
    if dependency.version != version:
        raise ValueError('依赖版本与锁文件不符：'+name)
    notices = []
    for path in dependency.files or ():
        if '.dist-info/' not in str(path) or not any(word in str(path).lower() for word in ('license','copying','notice')):
            continue
        target = 'distribution/python-notices/'+name+'/'+str(path)
        include(target,dependency.locate_file(path).read_bytes())
        notices.append(target)
    if not notices:
        raise ValueError('依赖缺少许可文本：'+name)
    inventory.append({'package':name,'version':version,'license':dependency.metadata.get('License-Expression') or dependency.metadata.get('License'),
                      'files':notices,'scope':'连接器及测试依赖' if line in runtime else '打包工具'})
include('distribution/dependencies.json',(json.dumps(inventory,ensure_ascii=False,indent=2)+'\n').encode())
include('README.md',inputs['distribution/BUILD.md'])
manifest = {name:hashlib.sha256(data).hexdigest() for name,data in sorted(inputs.items())}
include('distribution/manifest.json',json.dumps(manifest,indent=2).encode())
dest = OUT/'PBsync-source-candidate.zip'
with tempfile.TemporaryDirectory(dir=OUT) as temp:
    pending = Path(temp)/'candidate.zip'
    with zipfile.ZipFile(pending,'w',zipfile.ZIP_DEFLATED) as archive:
        for name,data in sorted(inputs.items()):
            archive.writestr(name,data)
    with zipfile.ZipFile(pending) as archive:
        if archive.testzip() or set(inputs)!=set(archive.namelist()) or any(archive.read(n)!=d for n,d in inputs.items()):
            raise ValueError('源码包回读不一致')
    os.replace(pending,dest)
(OUT/'dependencies.json').write_bytes(inputs['distribution/dependencies.json'])
print(f'已回读 {len(inputs)} 个文件、{len(inventory)} 个锁定依赖。{dest}')
