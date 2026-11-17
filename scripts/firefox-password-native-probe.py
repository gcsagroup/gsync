#!/usr/bin/env python3
"""仅操作本轮 Firefox 独立资料，通过浏览器附带 NSS 加解密合成账号。"""
import argparse
import base64
import ctypes
import json
import os
import sqlite3
import subprocess
import time
import uuid
from pathlib import Path
from contextlib import closing

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'build/password-native-20261111'
PROFILE = EVIDENCE / 'firefox-profile'
DATABASE = PROFILE / 'logins.json'
USERNAME = 'pbsync-native-qa-20261111'
PASSWORDS = ('Synthetic-Native-First-20261111', 'Synthetic-Native-Updated-20261111')


class ProbeError(Exception):
    pass


class Item(ctypes.Structure):
    _fields_ = [('type', ctypes.c_uint), ('data', ctypes.POINTER(ctypes.c_ubyte)),
                ('length', ctypes.c_uint)]


class NSS:
    def __enter__(self):
        base = '/Applications/Firefox.app/Contents/MacOS/'
        self.glue = ctypes.CDLL(base + 'libmozglue.dylib', mode=ctypes.RTLD_GLOBAL)
        self.library = ctypes.CDLL(base + 'libnss3.dylib')
        n = self.library
        if not all(hasattr(n, symbol) for symbol in ('PK11SDR_EncryptWithMechanism',
                   'PK11SDR_Decrypt', 'NSS_Init', 'NSS_Shutdown')):
            raise ProbeError('当前 NSS 版本不支持已验收的接口。')
        n.NSS_Init.argtypes = [ctypes.c_char_p]
        n.NSS_Init.restype = ctypes.c_int
        n.PK11_GetInternalKeySlot.restype = ctypes.c_void_p
        n.PK11_FreeSlot.argtypes = [ctypes.c_void_p]
        n.PK11SDR_EncryptWithMechanism.argtypes = [ctypes.c_void_p, ctypes.POINTER(Item),
            ctypes.c_ulong, ctypes.POINTER(Item), ctypes.POINTER(Item), ctypes.c_void_p]
        n.PK11SDR_Decrypt.argtypes = [ctypes.POINTER(Item), ctypes.POINTER(Item), ctypes.c_void_p]
        n.SECITEM_FreeItem.argtypes = [ctypes.POINTER(Item), ctypes.c_int]
        if n.NSS_Init(('sql:' + str(PROFILE)).encode()) != 0:
            raise ProbeError('无法打开本轮 NSS 测试资料。')
        return self

    def __exit__(self, *args):
        self.library.NSS_Shutdown()

    def crypt(self, value, decrypt=False):
        source = base64.b64decode(value, validate=True) if decrypt else value.encode()
        buffer = (ctypes.c_ubyte * len(source)).from_buffer_copy(source)
        incoming, outgoing, key_id = Item(0, buffer, len(source)), Item(), Item()
        if decrypt:
            status = self.library.PK11SDR_Decrypt(ctypes.byref(incoming), ctypes.byref(outgoing), None)
        else:
            slot = self.library.PK11_GetInternalKeySlot()
            if not slot:
                raise ProbeError('无法取得测试资料的 NSS 槽位。')
            try:
                # CKM_AES_CBC；使用 NSS 自己的默认 SDR 钥匙和随机 IV。
                status = self.library.PK11SDR_EncryptWithMechanism(slot, ctypes.byref(key_id),
                    0x1082, ctypes.byref(incoming), ctypes.byref(outgoing), None)
            finally:
                self.library.PK11_FreeSlot(slot)
        if status:
            raise ProbeError('NSS 拒绝加解密；不尝试绕过主密码或替换钥匙。')
        try:
            data = ctypes.string_at(outgoing.data, outgoing.length)
            return data.decode() if decrypt else base64.b64encode(data).decode()
        finally:
            self.library.SECITEM_FreeItem(ctypes.byref(outgoing), 0)


def run(action, revision=1):
    for path in (PROFILE, DATABASE, PROFILE / 'key4.db'):
        if path.is_symlink() or path.resolve() != path or not path.exists():
            raise ProbeError('测试资料路径缺失或发生重定向。')
    origin = json.loads((EVIDENCE / 'site.json').read_text())['origin']
    from urllib.parse import urlsplit
    url = urlsplit(origin)
    if url.scheme != 'http' or url.hostname != '127.0.0.1' or not url.port or url.path:
        raise ProbeError('只允许本机验收站点。')
    original = DATABASE.read_bytes()
    data = json.loads(original)
    if data.get('version') != 3 or len(data.get('logins', [])) > 1:
        raise ProbeError('未知格式或超出本轮唯一账号范围。')
    for row in data['logins']:
        if row.get('hostname') != origin or row.get('encType') != 1:
            raise ProbeError('存在非本轮记录，停止操作。')
    rust_database = PROFILE / 'logins.db'
    if rust_database.exists():
        if rust_database.is_symlink():
            raise ProbeError('不允许重定向存储文件。')
        with closing(sqlite3.connect(rust_database.as_uri() + '?mode=ro', uri=True)) as connection:
            if any(connection.execute('select count(*) from ' + table).fetchone()[0]
                   for table in ('loginsL', 'loginsM')):
                raise ProbeError('Rust 密码库已有记录，不能按 JSON 存储写回。')
    # 实验已确认运行时会被旧缓存覆盖，因此禁止在测试进程运行中写回。
    if action != 'read':
        processes = subprocess.run(['ps', '-axo', 'command='], capture_output=True, text=True, check=True).stdout
        if any('Firefox.app/Contents/MacOS/firefox' in line and str(PROFILE) in line
               for line in processes.splitlines()):
            raise ProbeError('测试 Firefox 尚在运行，延后写回。')
    with NSS() as nss:
        revisions = []
        for row in data['logins']:
            if nss.crypt(row['encryptedUsername'], True) != USERNAME:
                raise ProbeError('存在其他账号，停止操作。')
            plain = nss.crypt(row['encryptedPassword'], True)
            revisions.append(PASSWORDS.index(plain) + 1 if plain in PASSWORDS else 'unknown')
        if action == 'read':
            return {'action': action, 'count': len(revisions), 'revisions': revisions}
        timestamp = int(time.time() * 1000)
        if action == 'delete':
            data['logins'] = []
        elif action == 'upsert':
            if not data['logins']:
                data['logins'] = [{'id': data['nextId'], 'hostname': origin, 'httpRealm': None,
                    'formSubmitURL': origin, 'usernameField': 'username', 'passwordField': 'password',
                    'encryptedUsername': nss.crypt(USERNAME), 'guid': '{' + str(uuid.uuid4()) + '}',
                    'encType': 1, 'timeCreated': timestamp, 'timeLastUsed': 0,
                    'timesUsed': 0, 'syncCounter': 0, 'everSynced': False}]
                data['nextId'] += 1
            row = data['logins'][0]
            row['encryptedPassword'] = nss.crypt(PASSWORDS[revision - 1])
            row['timePasswordChanged'] = timestamp
            row['syncCounter'] = row.get('syncCounter', 0) + 1
        else:
            raise ProbeError('未知操作。')
    if DATABASE.read_bytes() != original:
        raise ProbeError('浏览器同时修改了文件，放弃本次写回。')
    backup = EVIDENCE / f'firefox-before-{time.time_ns()}.json'
    backup.write_bytes(original)
    os.chmod(backup, 0o600)
    temporary = PROFILE / f'.pbsync-test-{uuid.uuid4().hex}.json'
    try:
        with temporary.open('x') as output:
            os.chmod(temporary, 0o600)
            json.dump(data, output, ensure_ascii=False, separators=(',', ':'))
            output.flush()
            os.fsync(output.fileno())
        if DATABASE.read_bytes() != original:
            raise ProbeError('写回前资料发生变化，已放弃。')
        os.replace(temporary, DATABASE)
    finally:
        temporary.unlink(missing_ok=True)
    return {'action': action, 'database_written': True, 'backup': str(backup),
            'browser_acceptance': 'pending'}


if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['read', 'upsert', 'delete'])
    parser.add_argument('--revision', type=int, choices=[1, 2], default=1)
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.action, args.revision), ensure_ascii=False))
    except (ProbeError, OSError, ValueError, KeyError, sqlite3.Error) as error:
        print(json.dumps({'error': str(error), 'completed': False}, ensure_ascii=False))
        raise SystemExit(1)
