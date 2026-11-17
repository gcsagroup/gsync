#!/usr/bin/env python3
"""仅验证本轮 Chrome／Edge 合成账号；不提供日常密码导入或后台同步功能。"""
import argparse
import ctypes
import hashlib
import json
import os
import sqlite3
import sys
import time
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'build/password-native-20261111'
PROFILE = Path.home() / 'Library/Application Support/Google/Chrome/Profile 2'
DATABASE = PROFILE / 'Login Data'
USERNAME = 'pbsync-native-qa-20261111'
PASSWORDS = ('Synthetic-Native-First-20261111', 'Synthetic-Native-Updated-20261111')
KEY_SERVICE, KEY_ACCOUNT = b'Chrome Safe Storage', b'Chrome'
BROWSER = 'chrome'


def select_browser(browser):
    """只允许固定的两份测试资料，不能从命令行传入日常资料路径。"""
    global PROFILE, DATABASE, KEY_SERVICE, KEY_ACCOUNT, BROWSER
    if browser == 'chrome':
        PROFILE = Path.home() / 'Library/Application Support/Google/Chrome/Profile 2'
        KEY_SERVICE, KEY_ACCOUNT = b'Chrome Safe Storage', b'Chrome'
    elif browser == 'edge':
        PROFILE = EVIDENCE / 'edge-profile/Default'
        KEY_SERVICE, KEY_ACCOUNT = b'Microsoft Edge Safe Storage', b'Microsoft Edge'
    else:
        raise ProbeError('未知测试浏览器。')
    DATABASE, BROWSER = PROFILE / 'Login Data', browser


class ProbeError(Exception):
    pass


@contextmanager
def connect(*args, **kwargs):
    connection = sqlite3.connect(*args, **kwargs)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def chrome_key(interactive=False):
    """仅请求指定钥匙；拒绝时退出，不创建、替换或导出钥匙。"""
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    security.SecKeychainSetUserInteractionAllowed.argtypes = [ctypes.c_bool]
    security.SecKeychainFindGenericPassword.argtypes = [
        ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint32,
        ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
    security.SecKeychainItemFreeContent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    security.SecKeychainSetUserInteractionAllowed(interactive)
    length, pointer = ctypes.c_uint32(), ctypes.c_void_p()
    service, account = KEY_SERVICE, KEY_ACCOUNT
    status = security.SecKeychainFindGenericPassword(
        None, len(service), service, len(account), account,
        ctypes.byref(length), ctypes.byref(pointer), None)
    if status:
        raise ProbeError(f'钥匙串未授权或不可用（OSStatus {status}）；未写入密码库。')
    try:
        return hashlib.pbkdf2_hmac('sha1', ctypes.string_at(pointer, length.value),
                                   b'saltysalt', 1003, dklen=16)
    finally:
        security.SecKeychainItemFreeContent(None, pointer)


def crypt(data, key, decrypt=False):
    """与已核对的 Chromium macOS v10 格式对应；不接受未知版本。"""
    if len(key) != 16:
        raise ProbeError('不支持的密钥长度。')
    if decrypt:
        if not data.startswith(b'v10') or (len(data) - 3) % 16 or len(data) < 19:
            raise ProbeError('不支持或损坏的密文格式。')
        data = data[3:]
    library = ctypes.CDLL('/usr/lib/system/libcommonCrypto.dylib')
    library.CCCrypt.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
        ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p,
        ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    output = ctypes.create_string_buffer(len(data) + 16)
    written = ctypes.c_size_t()
    status = library.CCCrypt(int(decrypt), 0, 1, key, len(key), b' ' * 16,
                            data, len(data), output, len(output), ctypes.byref(written))
    if status:
        raise ProbeError(f'加解密失败（{status}）。')
    result = output.raw[:written.value]
    return result if decrypt else b'v10' + result


def validate_rows(connection, origin):
    """任何非本轮账号或未知格式出现，整库拒绝写入。"""
    version = connection.execute("select value from meta where key='version'").fetchone()
    if not version or int(version[0]) != 43:
        raise ProbeError('密码库版本不在本轮已核对范围。')
    rows = connection.execute('select origin_url, username_value, signon_realm from logins').fetchall()
    if len(rows) > 1 or any(row != (origin + '/', USERNAME, origin + '/') for row in rows):
        raise ProbeError('发现非本轮测试记录，停止操作。')
    if BROWSER == 'edge':
        meta = dict(connection.execute('select key,value from meta'))
        if str(meta.get('logins_edge_extended_table_version')) != '4' or str(meta.get('edge_breached_table_version')) != '6':
            raise ProbeError('Edge 附加表版本不在已核对范围。')
        for table in ('sync_entities_metadata', 'sync_model_metadata'):
            if connection.execute('select count(*) from ' + table).fetchone()[0]:
                raise ProbeError('测试库包含云同步状态，停止直接操作。')
        if connection.execute('select count(*) from logins_edge_extended where id not in (select id from logins)').fetchone()[0]:
            raise ProbeError('Edge 附加表存在未知记录。')
        if any(row != (origin + '/', USERNAME) for row in connection.execute('select url,username from breached')):
            raise ProbeError('Edge 检查表存在其他账号。')


def target_origin():
    if DATABASE.is_symlink() or PROFILE.is_symlink() or DATABASE.resolve() != DATABASE:
        raise ProbeError('不允许重定向测试资料路径。')
    if not DATABASE.is_file():
        raise ProbeError('本轮独立资料不存在。')
    site = json.loads((EVIDENCE / 'site.json').read_text())
    from urllib.parse import urlsplit
    parsed = urlsplit(site['origin'])
    if parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or not parsed.port or parsed.path:
        raise ProbeError('只允许本机验收站点。')
    origin = site['origin']
    # 先只读核对范围，取得授权后再开启写事务。
    with connect(DATABASE.as_uri() + '?mode=ro', uri=True) as source:
        validate_rows(source, origin)
    return origin


def run(action, revision=1, interactive=False, key=None):
    origin = target_origin()
    if key is None:
        key = chrome_key(interactive)
    if action == 'authorize':
        return {'action': action, 'key_available': True, 'database_written': False}
    if action == 'read':
        with connect(DATABASE.as_uri() + '?mode=ro', uri=True) as source:
            validate_rows(source, origin)
            rows = source.execute('select password_value from logins').fetchall()
        versions = []
        for (ciphertext,) in rows:
            plain = crypt(ciphertext, key, True).decode()
            versions.append(PASSWORDS.index(plain) + 1 if plain in PASSWORDS else 'unknown')
        return {'action': action, 'count': len(rows), 'revisions': versions}
    backup = EVIDENCE / f'{BROWSER}-before-{time.time_ns()}.sqlite'
    with connect(DATABASE.as_uri() + '?mode=ro', uri=True) as source:
        with connect(backup) as target:
            source.backup(target)
    os.chmod(backup, 0o600)
    timestamp = int((time.time() + 11644473600) * 1_000_000)
    with connect(DATABASE.as_uri() + '?mode=rw', uri=True, timeout=2) as target:
        target.execute('pragma foreign_keys=on')
        target.execute('begin immediate')
        validate_rows(target, origin)
        if action == 'delete':
            if BROWSER == 'edge':
                target.execute('delete from logins_edge_extended where id in '
                    '(select id from logins where origin_url=? and username_value=?)', (origin + '/', USERNAME))
                target.execute('delete from breached where url=? and username=?', (origin + '/', USERNAME))
            target.execute('delete from logins where origin_url=? and username_value=?',
                           (origin + '/', USERNAME))
        elif action == 'upsert':
            cipher = crypt(PASSWORDS[revision - 1].encode(), key)
            count = target.execute('select count(*) from logins').fetchone()[0]
            if count:
                target.execute('update logins set password_value=?,date_password_modified=? '
                               'where origin_url=? and username_value=?',
                               (cipher, timestamp, origin + '/', USERNAME))
            else:
                cursor = target.execute('insert into logins '
                    '(origin_url,action_url,username_element,username_value,password_element,'
                    'password_value,submit_element,signon_realm,date_created,blacklisted_by_user,'
                    'scheme,password_type,times_used,skip_zero_click,date_password_modified) '
                    'values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                    (origin + '/', origin + '/login', 'username', USERNAME, 'password', cipher,
                     '', origin + '/', timestamp, 0, 0, 0, 0, 1, timestamp))
                if BROWSER == 'edge':
                    target.execute('insert into logins_edge_extended(id) values (?)', (cursor.lastrowid,))
        else:
            raise ProbeError('未知操作。')
        validate_rows(target, origin)
    return {'action': action, 'database_written': True, 'backup': str(backup),
            'browser_acceptance': 'pending'}


def session(interactive=False):
    """一次授权后的钥匙仅留在本进程，完成各阶段后退出即释放。"""
    target_origin()
    key = chrome_key(interactive)
    print(json.dumps({'ready': True, 'database_written': False}), flush=True)
    for line in sys.stdin:
        try:
            command = json.loads(line)
            action = command.get('action')
            if action == 'quit':
                break
            if action not in ('read', 'upsert', 'delete'):
                raise ProbeError('会话不接受此操作。')
            revision = command.get('revision', 1)
            if revision not in (1, 2):
                raise ProbeError('未知测试版本。')
            result = run(action, revision=revision, key=key)
        except (ProbeError, OSError, sqlite3.Error, ValueError) as error:
            result = {'error': str(error), 'completed': False}
        print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['authorize', 'read', 'upsert', 'delete', 'session'])
    parser.add_argument('--browser', choices=['chrome', 'edge'], default='chrome')
    parser.add_argument('--revision', type=int, choices=[1, 2], default=1)
    parser.add_argument('--interactive', action='store_true',
                        help='仅在用户明确同意后请求系统钥匙串提示')
    args = parser.parse_args()
    try:
        select_browser(args.browser)
        if args.action == 'session':
            session(args.interactive)
        else:
            print(json.dumps(run(args.action, args.revision, args.interactive), ensure_ascii=False))
    except (ProbeError, OSError, sqlite3.Error, ValueError) as error:
        print(json.dumps({'error': str(error), 'completed': False}, ensure_ascii=False))
        raise SystemExit(1)
