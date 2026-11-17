#!/usr/bin/env python3
"""在现有工作区生成静态链接的 Windows x64 调试验收包。"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import urllib.request

from build import ROOT, BUILD, bump, run

TARGET = BUILD / 'windows'
SOURCE = ROOT / 'apps' / 'Windows'
JSON_URL = 'https://raw.githubusercontent.com/nlohmann/json/v3.12.0/single_include/nlohmann/json.hpp'
JSON_SHA256 = 'aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63'


def get_json() -> Path:
    header = TARGET / 'deps' / 'json.hpp'
    header.parent.mkdir(parents=True, exist_ok=True)
    if not header.is_file():
        with urllib.request.urlopen(JSON_URL, timeout=30) as response:
            contents = response.read(2_000_000)
        if hashlib.sha256(contents).hexdigest() != JSON_SHA256:
            raise ValueError('JSON 编译头文件校验失败')
        header.write_bytes(contents)
    elif hashlib.sha256(header.read_bytes()).hexdigest() != JSON_SHA256:
        raise ValueError('本地 JSON 编译头文件校验失败')
    return header


def rc_path(path: Path) -> str:
    return '"' + path.as_posix().replace('"', '\\"') + '"'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tests', action='store_true', help='另外构建远程机验收工具')
    options = parser.parse_args()

    prefix = 'x86_64-w64-mingw32-'
    for name in ('g++', 'windres', 'objdump'):
        if not shutil.which(prefix + name):
            raise SystemExit(f'缺少 Windows x64 工具链程序 {prefix + name}')
    header = get_json()
    version, number = bump('windows-x64')
    parts = version.split('.')
    if len(parts) != 2 or any(not part.isdigit() for part in parts) or not 1 <= number <= 65535:
        raise ValueError('Windows 文件版本必须为两段数字和有效的构建号')
    major, minor = map(int, parts)
    resource = TARGET / 'PBsync.rc'
    resource.write_text(f'''
1 RT_MANIFEST {rc_path(SOURCE / 'app.manifest')}
201 RCDATA {rc_path(SOURCE / 'JSON-LICENSE.txt')}
1 VERSIONINFO
 FILEVERSION {major},{minor},{number},0
 PRODUCTVERSION {major},{minor},{number},0
 FILEFLAGSMASK 0x3fL
 FILEOS 0x40004L
 FILETYPE 1
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904B0"
  BEGIN
   VALUE "CompanyName", "GCSA"
   VALUE "FileDescription", "PBsync Windows"
   VALUE "FileVersion", "{version}.{number}"
   VALUE "ProductName", "PBsync"
   VALUE "ProductVersion", "{version}.{number}"
   VALUE "OriginalFilename", "PBsync.exe"
  END
 END
 BLOCK "VarFileInfo"
 BEGIN
  VALUE "Translation", 0x0409, 1200
 END
END
'''.replace('RT_MANIFEST', '24'), encoding='utf-8')

    logs = TARGET / 'logs'
    logs.mkdir(exist_ok=True)
    run([prefix + 'windres', '--input', str(resource), '--output', str(TARGET / 'resource.o')], logs / f'resource-{number}.log')
    flags = ['-std=c++20', '-municode', '-DUNICODE', '-D_UNICODE', '-DNOMINMAX', '-D_WIN32_WINNT=0x0A00',
             '-O2', '-Wall', '-Wextra', '-Werror', '-finput-charset=UTF-8',
             '-I' + str(header.parent), '-I' + str(SOURCE / 'src')]
    libraries = ['-static', '-static-libgcc', '-static-libstdc++', '-s', '-lbcrypt', '-lcrypt32',
                 '-lole32', '-lruntimeobject', '-lwinhttp', '-lshlwapi', '-lxmllite', '-lcomctl32', '-lcomdlg32', '-lgdi32', '-lshell32', '-lwtsapi32']
    objects = []
    for name in ('vault', 'dav', 'browser_bridge', 'windows_hello', 'main'):
        output = TARGET / (name + '.o')
        run([prefix + 'g++', *flags, '-c', str(SOURCE / 'src' / (name + '.cpp')), '-o', str(output)],
            logs / f'{name}-{number}.log')
        objects.append(str(output))
    staged = TARGET / f'PBsync-{number}.tmp.exe'
    run([prefix + 'g++', '-municode', '-mwindows', *objects, str(TARGET / 'resource.o'),
         *libraries, '-o', str(staged)], logs / f'link-{number}.log')

    listing = subprocess.check_output([prefix + 'objdump', '-p', str(staged)], text=True)
    allowed = {'advapi32.dll', 'bcrypt.dll', 'combase.dll', 'comctl32.dll', 'comdlg32.dll', 'crypt32.dll',
               'gdi32.dll', 'kernel32.dll', 'msvcrt.dll', 'ole32.dll', 'shell32.dll',
               'shlwapi.dll', 'user32.dll', 'winhttp.dll', 'wtsapi32.dll', 'xmllite.dll'}
    imports = {name.lower() for name in re.findall(r'DLL Name:\s+(\S+)', listing)}
    # Windows 10/11 自带 Universal CRT 的 API 集。工具链的 C++ 库和线程库始终静态链接。
    external = {name for name in imports - allowed
                if not re.fullmatch(r'api-ms-win-(?:crt-[a-z]+-l1-1-0|core-winrt-(?:l1-1-0|string-l1-1-0))\.dll', name)}
    if not imports or external:
        raise ValueError(f'发现非系统依赖: {sorted(external)}')
    if options.tests:
        run([prefix + 'g++', *flags, str(SOURCE / 'tests' / 'vault_check.cpp'), *objects[:2],
             str(TARGET / 'windows_hello.o'),
             *libraries, '-o', str(TARGET / 'VaultCheck.exe')], logs / f'tests-{number}.log')
        capture = TARGET / 'capture-main.o'
        run([prefix + 'g++', *flags, '-DPBSYNC_UI_CAPTURE', '-c', str(SOURCE / 'src' / 'main.cpp'),
             '-o', str(capture)], logs / f'capture-{number}.log')
        run([prefix + 'g++', '-municode', '-mwindows', *objects[:-1], str(capture), str(TARGET / 'resource.o'),
             *libraries, '-o', str(TARGET / 'WindowCheck.exe')], logs / f'capture-link-{number}.log')
    destination = TARGET / 'PBsync.exe'
    staged.replace(destination)
    (TARGET / 'imports.txt').write_text('\n'.join(sorted(imports)) + '\n', encoding='utf-8')
    print(f'Windows Ver {version} ({number}) {destination}')


if __name__ == '__main__':
    main()
