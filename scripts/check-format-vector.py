#!/usr/bin/env python3
"""第三方实现可用的 v1 备份样本验算。输入全是项目的公开合成常量。"""
import base64
import csv
import hashlib
import json
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

root = Path(__file__).resolve().parents[1]/'fixtures'
expected = json.loads((root/'format-v1/expected.json').read_text())
data = (root/'format-v1'/expected['file']).read_bytes()
assert hashlib.sha256(data).hexdigest() == expected['sha256']
archive = json.loads(data)
head = archive['header']
decode = base64.b64decode
prefix = f'PBsync|1|{head["spaceID"].lower()}|1|'
assert head['format'] == 1 and head['keyEpoch'] == 1 and head['iterations'] == 600000


def unseal(key, sealed, purpose):
    return AESGCM(key).decrypt(sealed[:12],sealed[12:],(prefix+purpose).encode())


def password_key(password):
    return hashlib.pbkdf2_hmac('sha256',password.encode(),decode(head['salt']),head['iterations'],32)


slot = decode(head['passwordSlot'])
key = unseal(password_key(expected['password']),slot,'password')
assert key == unseal(decode(expected['recovery']),decode(head['recoverySlot']),'recovery')
sealed = decode(archive['sealedState'])
clear = unseal(key,sealed,'state')
assert hashlib.sha256(clear).hexdigest() == expected['clearStateSHA256']
state = json.loads(clear)
assert state['name'] == expected['title'] and state['kind']=='vault'
with (root/'logins.csv').open() as f:
    logins = {r['username']:r['password'] for r in csv.DictReader(f)}
assert len(state['revisions']) == len(logins) == expected['items']
assert {r['item']['fields']['username']:r['item']['fields']['password'] for r in state['revisions']} == logins
for wrong_key, ciphertext, purpose in [(password_key('wrong'),slot,'password'),(key,sealed,'password'),
                                      (key,sealed[:-1]+bytes([sealed[-1]^1]),'state')]:
    try: unseal(wrong_key,ciphertext,purpose)
    except InvalidTag: continue
    raise ValueError('完整性校验错误接受了负例')
print('主密码和恢复密钥、12 个账号、错误口令、错误用途和篡改验证通过。')
