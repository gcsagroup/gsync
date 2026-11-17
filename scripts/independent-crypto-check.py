#!/usr/bin/env python3
"""用独立运行时验证 Swift 产生的合成密码学向量。"""
import base64,hashlib,json
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
ROOT=Path(__file__).resolve().parents[1]
expected=hashlib.pbkdf2_hmac('sha256',b'password',b'salt-salt-salt-123',1,32)
assert (ROOT/'build/pbkdf-vector.bin').read_bytes()==expected
vector={key:base64.b64decode(value) for key,value in json.loads((ROOT/'build/passkey-vector.json').read_text()).items()}
public=ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(),vector['publicKey'])
public.verify(vector['signature'],vector['authenticatorData']+vector['clientDataHash'],ec.ECDSA(hashes.SHA256()))
assert vector['authenticatorData'][:32]==hashlib.sha256(b'example.com').digest()
assert vector['authenticatorData'][32]==0x1d
print('独立 Python 验证通过：PBKDF2-SHA256、P-256 签名、RP 摘要及标志。')
