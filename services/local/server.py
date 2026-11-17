#!/usr/bin/env python3
"""仅监听本机的 WebDAV／密文云验证服务；日志不记录路径或请求体。"""
from __future__ import annotations
import sqlite3, time, secrets as random_secrets, uuid
from contextlib import closing
import argparse, base64, hashlib, hmac, json, os, re, shutil, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit
from xml.sax.saxutils import escape

MAX_OBJECT = 128 * 1024 * 1024
OBJECT = re.compile(r'(?:space\.pbsync|[0-9a-f-]{36}\.(?:pbop|pbatt))\Z')
LOCK = threading.RLock()

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()

def password_hash(password, salt):
    return hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1).hex()

class AccountError(Exception):
    def __init__(self, status): self.status = status

class StorageServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32
    def __init__(self, address, root, dav_user, dav_password, cloud_token):
        super().__init__(address, Handler)
        self.root = Path(root).resolve()
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.dav_auth = 'Basic ' + base64.b64encode((dav_user + ':' + dav_password).encode()).decode()
        self.cloud_auth = 'Bearer ' + cloud_token

        self.accounts = self.root / '.accounts.sqlite'
        with closing(sqlite3.connect(self.accounts)) as db:
            os.chmod(self.accounts, 0o600)
            db.executescript("""
                CREATE TABLE IF NOT EXISTS accounts (name TEXT PRIMARY KEY, salt BLOB, credential TEXT, recovery TEXT);
                CREATE TABLE IF NOT EXISTS sessions (digest TEXT PRIMARY KEY, owner TEXT, device TEXT, scope TEXT, expiry INTEGER);
            """)

    def identity(self, db, auth):
        if not auth.startswith('Bearer '): raise AccountError(401)
        row = db.execute('SELECT owner,device,scope FROM sessions WHERE digest=? AND expiry>?',(digest(auth[7:]),time.time())).fetchone()
        if not row: raise AccountError(401)
        return row

    def account(self, action, body, auth):
        def field(key, pattern=None):
            v = body.get(key)
            if not isinstance(v,str) or not 1 <= len(v) <= 256 or (pattern and not re.fullmatch(pattern,v)): raise AccountError(400)
            return v
        with LOCK, closing(sqlite3.connect(self.accounts)) as db, db:
            db.execute('DELETE FROM sessions WHERE expiry<=?', (time.time(),))
            def issue(owner, scope, days):
                token, device = random_secrets.token_urlsafe(32), str(uuid.uuid4())
                db.execute('INSERT INTO sessions VALUES(?,?,?,?,?)',(digest(token),owner,device,scope,time.time()+86400*days))
                return {'token':token,'device':device}
            if action in ('register','login','reset'):
                name, password = field('name','[a-zA-Z0-9_-]{1,64}'), field('password')
                if len(password)<12: raise AccountError(400)
                row=db.execute('SELECT salt,credential,recovery FROM accounts WHERE name=?',(name,)).fetchone()
                if action=='login':
                    if not row or not hmac.compare_digest(row[1],password_hash(password,row[0])): raise AccountError(401)
                    return issue(name,'*',1)
                if action=='register' and row: raise AccountError(409)
                if action=='reset' and (not row or not hmac.compare_digest(row[2],digest(field('recovery')))): raise AccountError(401)
                recovery, salt = random_secrets.token_urlsafe(32),os.urandom(16)
                db.execute('INSERT OR REPLACE INTO accounts VALUES(?,?,?,?)',(name,salt,password_hash(password,salt),digest(recovery)))
                db.execute('DELETE FROM sessions WHERE owner=?',(name,))
                return {**issue(name,'*',1),'recovery':recovery}
            owner, device, scope = self.identity(db,auth)
            if action=='logout':
                db.execute('DELETE FROM sessions WHERE device=?',(device,)); return {}
            if scope!='*': raise AccountError(403)
            if action=='approve': return issue(owner,field('space','[a-zA-Z0-9_-]{1,64}'),30)
            if action=='devices':
                return {'devices':[{'device':d,'space':s} for d,s in db.execute('SELECT device,scope FROM sessions WHERE owner=? AND scope!=?',(owner,'*'))]}
            if action=='revoke':
                cur=db.execute('DELETE FROM sessions WHERE owner=? AND device=? AND scope!=?',(owner,field('device'),'*'))
                if not cur.rowcount: raise AccountError(404)
                return {}
            raise AccountError(404)

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'PBsyncLocal/1'
    def log_message(self, *_): pass
    def send(self, status, data=b'', content_type='application/octet-stream', etag=None):
        if status >= 400: self.close_connection = True
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-store')
        if etag: self.send_header('ETag', etag)
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(data)
    def target(self):
        parts = urlsplit(self.path)
        path = unquote(parts.path)
        segments = path.strip('/').split('/')
        if parts.query or parts.fragment or any(p in ('.', '..') or '\\' in p or '\x00' in p for p in segments): self.send(400); return None
        if len(segments) not in (2, 3) or segments[0] not in ('dav', 'cloud', 'account') or not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}', segments[1]): self.send(404); return None
        owner = None
        if segments[0] == 'account':
            try:
                with closing(sqlite3.connect(self.server.accounts)) as db:
                    owner, _, scope = self.server.identity(db,self.headers.get('Authorization',''))
                if scope not in ('*',segments[1]): raise AccountError(403)
            except AccountError as err: self.send(err.status); return None
        expected = self.server.dav_auth if segments[0] == 'dav' else self.server.cloud_auth
        if owner is None and not hmac.compare_digest(self.headers.get('Authorization', ''), expected): self.send(401); return None
        if len(segments) == 3 and not OBJECT.fullmatch(segments[2]): self.send(400); return None
        target = self.server.root.joinpath('account',owner,*segments[1:]) if owner else self.server.root.joinpath(*segments)
        if target.is_symlink() or any(p.is_symlink() for p in target.parents if p != self.server.root.parent): self.send(403); return None
        return target, segments
    def body(self):
        if self.headers.get('Transfer-Encoding'): self.send(400); return None
        try: count = int(self.headers.get('Content-Length', '0'))
        except ValueError: self.send(400); return None
        if not 0 <= count <= MAX_OBJECT: self.send(413); return None
        data = self.rfile.read(count)
        if len(data) != count: self.send(400); return None
        return data
    @staticmethod
    def etag(data): return '"' + hashlib.sha256(data).hexdigest() + '"'
    def do_GET(self):
        resolved = self.target()
        if not resolved: return
        path, segments = resolved
        if len(segments) != 3 or not path.is_file(): self.send(404); return
        with LOCK:
            if segments[0]=='account' and not self.target(): return
            data = path.read_bytes()
        self.send(200, data, etag=self.etag(data))
    def do_POST(self):
        match = re.fullmatch(r'/auth/(register|reset|login|logout|approve|devices|revoke)',self.path)
        if not match: self.send(404); return
        if self.headers.get_content_type() != 'application/json': self.send(415); return
        try:
            if not 0 < int(self.headers.get('Content-Length','0')) <= 4096: raise AccountError(413)
            raw=self.body()
            if raw is None: return
            body=json.loads(raw)
            if not isinstance(body,dict): raise AccountError(400)
            result=self.server.account(match[1],body,self.headers.get('Authorization',''))
        except (ValueError,UnicodeError): self.send(400); return
        except AccountError as err: self.send(err.status); return
        self.send(200,json.dumps(result).encode(),'application/json')
    def do_HEAD(self): self.do_GET()
    def do_PROPFIND(self):
        resolved = self.target()
        if not resolved: return
        if self.body() is None: return
        path, segments = resolved
        if len(segments) != 2 or self.headers.get('Depth') != '1': self.send(400); return
        # 测试命名空间可按需创建；生产 WebDAV 目录必须由用户预先建立。
        with LOCK:
            if segments[0]=='account' and not self.target(): return
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
            rows = []
            for child in sorted(path.iterdir()):
                if child.is_file() and not child.is_symlink() and OBJECT.fullmatch(child.name):
                    data = child.read_bytes()
                    rows.append(f'<d:response><d:href>/{escape("/".join(segments))}/{child.name}</d:href><d:propstat><d:prop><d:getetag>{escape(self.etag(data))}</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')
        self.send(207, ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">' + ''.join(rows) + '</d:multistatus>').encode(), 'application/xml')
    def do_PUT(self):
        resolved = self.target()
        if not resolved: return
        path, segments = resolved
        if len(segments) != 3: self.send(400); return
        data = self.body()
        if data is None: return
        with LOCK:
            if segments[0]=='account' and not self.target(): return
            exists = path.exists()
            if self.headers.get('If-None-Match') == '*':
                if exists: self.send(412); return
            elif self.headers.get('If-Match'):
                if not exists or not hmac.compare_digest(self.etag(path.read_bytes()), self.headers['If-Match']): self.send(412); return
            else: self.send(428); return
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix='.pending-', dir=path.parent)
            try:
                with os.fdopen(fd, 'wb') as output:
                    output.write(data); output.flush(); os.fsync(output.fileno())
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary): os.unlink(temporary)
        self.send(204 if exists else 201, etag=self.etag(data))
    def do_DELETE(self): self.send(405)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True); parser.add_argument('--port', type=int, default=47852)
    parser.add_argument('--secrets-file', required=True)
    args = parser.parse_args()
    secrets = json.loads(Path(args.secrets_file).read_text())
    if not all(isinstance(secrets.get(k), str) and len(secrets[k]) >= (1 if k == 'dav_user' else 16) for k in ('dav_user', 'dav_password', 'cloud_token')): raise SystemExit('测试凭据格式错误')
    server = StorageServer(('127.0.0.1', args.port), args.root, **secrets)
    print(f'PBsync 本地验证服务已监听 127.0.0.1:{server.server_port}', flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()
