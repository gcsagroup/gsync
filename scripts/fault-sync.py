#!/usr/bin/env python3
"""以真实 TCP 和 CLI 子进程验证故障；仅操作本次创建的临时目录。"""
import importlib.util,json,os,socket,subprocess,tempfile,threading
from pathlib import Path
root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('dav',root/'services/local/server.py')
dav=importlib.util.module_from_spec(spec);spec.loader.exec_module(dav)
env={**os.environ,'PBSYNC_PASSWORD':'SYNTHETIC-vault-secret','PBSYNC_STORAGE_SECRET':'SYNTHETIC-webdav-secret','PBSYNC_NEW_PASSWORD':'SYNTHETIC-rotated-secret'}
mode='normal';gate=threading.Event();release=threading.Event()
class Handler(dav.Handler):
    def do_GET(self):
        if mode=='partial' and self.path.endswith('.pbop'):
            self.send_response(200);self.send_header('Content-Length','500');self.end_headers()
            self.wfile.write(b'truncated');self.wfile.flush();self.connection.shutdown(socket.SHUT_RDWR);self.close_connection=True;return
        super().do_GET()
    def do_PUT(self):
        if mode=='quota':
            self.body();self.send(507);return
        if mode=='interrupt' and self.path.endswith('.pbop'):
            self.body();gate.set();release.wait(12);self.close_connection=True;return
        if mode=='migration' and self.headers.get('If-Match'):
            # 新位置已校验，旧位置尚未冻结；此时终止客户端。
            self.body();gate.set();release.wait(12);self.close_connection=True;return
        super().do_PUT()
def start(path,port=0):
    server=dav.StorageServer(('127.0.0.1',port),path,'qa',env['PBSYNC_STORAGE_SECRET'],'synthetic-cloud-token')
    server.RequestHandlerClass=Handler
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    return server
def stop(server):server.shutdown();server.server_close()
def run(*args,want=True,password=None):
    p=subprocess.run([root/'build/pbsync',*args],capture_output=True,text=True,env=env if password is None else dict(env,PBSYNC_PASSWORD=password),timeout=45)
    assert (p.returncode==0)==want,(args[0],p.stderr)
    for key in ('PBSYNC_PASSWORD','PBSYNC_STORAGE_SECRET','PBSYNC_NEW_PASSWORD'):
        assert env[key] not in p.stderr+p.stdout
    return json.loads(p.stdout) if want else p.stderr.strip()
def interrupt(*args):
    gate.clear();release.clear()
    p=subprocess.Popen([root/'build/pbsync',*args],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=env)
    try:assert gate.wait(12)
    finally:p.kill();p.wait();release.set()
result={}
with tempfile.TemporaryDirectory(prefix='pbsync-faults-') as tmp:
    base=Path(tmp); a=base/'a/local.pbsync';b=base/'b/local.pbsync';src=base/'input.csv'
    server=start(base/'remote');port=server.server_port
    args=['--url',f'http://127.0.0.1:{port}/dav/qa/','--username','qa']
    try:
        run('create','--file',a,'--kind','vault','--recovery-out',base/'key')
        run('sync','--file',a,*args)
        src.write_text('name,username,password\n故障,fixture,SYNTHETIC-entry-only\n')
        run('import','--file',a,'--input',src,'--format','csv')
        stop(server);server=None
        result['listenerStopped']=run('sync','--file',a,*args,want=False)
        server=start(base/'remote',port)
        mode='quota';result['quota507']=run('sync','--file',a,*args,want=False)
        mode='interrupt';interrupt('sync','--file',a,*args)
        mode='normal';result['afterKill']=run('sync','--file',a,*args);assert result['afterKill']['uploaded']==1
        mode='partial';result['truncatedGET']=run('connect','--file',b,*args,want=False);assert not b.exists()
        mode='normal';result['reconnect']=run('connect','--file',b,*args);assert result['reconnect']['items']==1
        mode='migration';dest=base/'candidate'
        interrupt('migrate','--file',a,*args,'--destination-folder',dest,'--recovery-out',base/'new-key')
        mode='normal'
        result['oldAfterInterruptedMigration']=run('sync','--file',a,*args)
        result['candidateAfterInterruptedMigration']=run('connect','--file',base/'c/local.pbsync','--folder',dest,password=env['PBSYNC_NEW_PASSWORD'])
        assert result['candidateAfterInterruptedMigration']==dict(items=1,revisions=1)
        run('migrate','--file',a,*args,'--destination-folder',base/'finished','--recovery-out',base/'new-key')
        result['retiredSource']=run('sync','--file',b,*args,want=False)
        result['completedMigration']=run('inspect','--file',a,password=env['PBSYNC_NEW_PASSWORD']);assert result['completedMigration']['items']==1
        assert not any(b'SYNTHETIC-entry-only' in f.read_bytes() for d in (base/'remote',dest,base/'finished',a.parent,b.parent) for f in d.rglob('*') if f.is_file())
    finally:
        if server:stop(server)
out=root/'build/f10-f12';out.mkdir(exist_ok=True)
(out/'faults.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print('断连、507、部分响应、杀进程、迁移中断与重连通过')
