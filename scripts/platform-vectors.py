#!/usr/bin/env python3
"""在本机 .NET 和 JVM 中交叉验证同一 Apple 备份，不写入平台 SDK 或个人目录。"""
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
samples = root/'fixtures/format-v1'
expected = json.loads((samples/'expected.json').read_text())
archive = json.loads((samples/expected['file']).read_text())
head = archive['header']
fields = dict(head, **expected, sealedState=archive['sealedState'],
              prefix=f'PBsync|{head["format"]}|{head["spaceID"].lower()}|{head["keyEpoch"]}|')
properties = '\n'.join(f'{k}={v}' for k,v in fields.items() if k!='title')
subprocess.run(['java',root/'tools/format-check/java/FormatCheck.java'],input=properties,text=True,check=True)
with tempfile.TemporaryDirectory() as d:
    directory = Path(d)
    project = directory/'dotnet'
    shutil.copytree(root/'tools/format-check/dotnet',project)
    # 只有本机内置框架。还原时使用空源列表，避免联网补齐缺失工具链。
    config = directory/'NuGet.Config'
    config.write_text('<configuration><packageSources><clear/></packageSources></configuration>')
    env = dict(os.environ,DOTNET_CLI_HOME=d,DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_NOLOGO='1')
    subprocess.run(['dotnet','restore','--configfile',config],cwd=project,env=env,check=True)
    subprocess.run(['dotnet','run','--no-restore','--',samples],cwd=project,env=env,check=True)
