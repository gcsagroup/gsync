import base64,concurrent.futures,importlib.util,json,tempfile,threading,unittest,urllib.request,urllib.error
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('server',ROOT/'services/local/server.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class ServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='pbsync-server-')
        self.server=m.StorageServer(('127.0.0.1',0),self.tmp.name,'test-user','synthetic-dav-secret-2026','synthetic-cloud-token-2026')
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.base=f'http://127.0.0.1:{self.server.server_port}'
        self.auth='Basic '+base64.b64encode(b'test-user:synthetic-dav-secret-2026').decode()
    def tearDown(self):self.server.shutdown();self.server.server_close();self.thread.join();self.tmp.cleanup()
    def request(self,method,path='/dav/test/space.pbsync',data=None,headers=None,auth=None):
        request=urllib.request.Request(self.base+path,data=data,method=method,headers={'Authorization':self.auth if auth is None else auth,**(headers or {})})
        try:
            with urllib.request.urlopen(request,timeout=5) as response:return response.status,response.read(),dict(response.headers)
        except urllib.error.HTTPError as error:return error.code,error.read(),dict(error.headers)
    def test_authorization_and_cloud_separation(self):
        self.assertEqual(self.request('GET',auth='invalid')[0],401)
        self.assertEqual(self.request('PUT','/cloud/test/space.pbsync',b'cipher',{'If-None-Match':'*'})[0],401)
        result=self.request('PUT','/cloud/test/space.pbsync',b'cipher',{'If-None-Match':'*'},'Bearer synthetic-cloud-token-2026')
        self.assertEqual(result[0],201)
    def test_conditional_create_update_and_readback(self):
        self.assertEqual(self.request('PUT',data=b'first')[0],428)
        created=self.request('PUT',data=b'cipher-1',headers={'If-None-Match':'*'});self.assertEqual(created[0],201)
        self.assertEqual(self.request('PUT',data=b'overwritten',headers={'If-None-Match':'*'})[0],412)
        self.assertEqual(self.request('PUT',data=b'overwritten',headers={'If-Match':'"wrong"'})[0],412)
        self.assertEqual(self.request('PUT',data=b'cipher-2',headers={'If-Match':created[2]['ETag']})[0],204)
        self.assertEqual(self.request('GET')[1],b'cipher-2')
        self.assertEqual(self.request('DELETE')[0],405)
    def test_simultaneous_conditional_creation_has_one_winner(self):
        def attempt(i):return self.request('PUT',data=f'cipher-{i}'.encode(),headers={'If-None-Match':'*'})[0]
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:statuses=list(pool.map(attempt,range(6)))
        self.assertEqual(statuses.count(201),1);self.assertEqual(statuses.count(412),5)
    def test_propfind_traversal_and_unknown_objects(self):
        result=self.request('PROPFIND','/dav/test/',b'<propfind/>',{'Depth':'1'});self.assertEqual(result[0],207)
        self.assertEqual(self.request('PUT','/dav/test/%2e%2e',b'bad',{'If-None-Match':'*'})[0],400)
        self.assertEqual(self.request('PUT','/dav/test/plaintext.txt',b'bad',{'If-None-Match':'*'})[0],400)
        self.assertEqual(self.request('PROPFIND','/dav/test/',b'',{'Depth':'infinity'})[0],400)
    def test_restart_preserves_ciphertext(self):
        self.request('PUT',data=b'opaque-ciphertext',headers={'If-None-Match':'*'})
        self.server.shutdown();self.thread.join();self.server.server_close()
        self.server=m.StorageServer(('127.0.0.1',0),self.tmp.name,'test-user','synthetic-dav-secret-2026','synthetic-cloud-token-2026')
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start();self.base=f'http://127.0.0.1:{self.server.server_port}'
        self.assertEqual(self.request('GET')[1],b'opaque-ciphertext')

    def test_account_device_scope_revoke_reset_and_logout(self):
        def post(route, fields, token=''):
            status,data,_=self.request('POST','/auth/'+route,json.dumps(fields).encode(),{'Content-Type':'application/json'},'Bearer '+token)
            return status,json.loads(data) if data else {}
        credentials={'name':'synthetic','password':'test-account-password'}
        rc,owner=post('register',credentials); self.assertEqual(rc,200)
        rc,login=post('login',credentials);self.assertEqual(rc,200)
        self.assertEqual(post('register',credentials)[0],409)
        device=post('approve',{'space':'space_a'},owner['token'])[1]
        path='/account/space_a/space.pbsync'
        def access(method,path,token,data=None):
            return self.request(method,path,data,{'If-None-Match':'*'},'Bearer '+token)[:2]
        self.assertEqual(access('PUT',path,device['token'],b'first-copy')[0],201)
        old=access('GET',path,device['token'])[1]
        self.assertEqual(access('GET',path.replace('space_a','other'),device['token'])[0],403)
        self.assertEqual(access('GET',path,'synthetic-cloud-token-2026')[0],401)
        self.assertEqual(post('approve',{'space':'other'},device['token'])[0],403)
        other=post('register',dict(credentials,name='second'))[1]
        self.assertEqual(access('GET',path,other['token'])[0],404)
        self.assertEqual(post('revoke',{'device':device['device']},other['token'])[0],404)
        self.assertEqual(post('devices',{},owner['token'])[1]['devices'][0]['device'],device['device'])
        self.assertEqual(post('revoke',{'device':device['device']},owner['token'])[0],200)
        self.assertEqual(access('GET',path,device['token'])[0],401)
        self.assertEqual(access('PUT',path,device['token'],b'future')[0],401)
        self.assertEqual(old,b'first-copy')
        self.assertEqual(post('reset',dict(credentials,recovery='wrong'))[0],401)
        reset=post('reset',dict(credentials,password='new-account-password',recovery=owner['recovery']))[1]
        self.assertEqual(access('GET',path,owner['token'])[0],401)
        self.assertEqual(access('GET',path,reset['token']),(200,b'first-copy'))
        self.assertEqual(post('login',credentials)[0],401)
        expiring=post('approve',{'space':'other'},reset['token'])[1]
        import sqlite3
        with sqlite3.connect(self.server.accounts) as db:
            db.execute('UPDATE sessions SET expiry=0 WHERE device=?',(expiring['device'],))
        self.assertEqual(access('GET',path.replace('space_a','other'),expiring['token'])[0],401)
        self.assertEqual(post('logout',{},reset['token'])[0],200)
        self.assertEqual(access('GET',path,reset['token'])[0],401)

if __name__=='__main__':unittest.main()
