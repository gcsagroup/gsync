import importlib.util,json,os,tempfile,unittest,uuid,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('connector',ROOT/'tools/connectors/connector.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)

class ConnectorTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='pbsync-connector-');self.root=Path(self.tmp.name)
        self.old=os.environ.get('PBSYNC_SOURCE_PASSWORD');os.environ['PBSYNC_SOURCE_PASSWORD']='SYNTHETIC-ONLY-2026'
    def tearDown(self):
        self.tmp.cleanup()
        if self.old is None:os.environ.pop('PBSYNC_SOURCE_PASSWORD',None)
        else:os.environ['PBSYNC_SOURCE_PASSWORD']=self.old
    def test_kdbx_recycle_bin_and_nested_entries_are_not_imported(self):
        from pykeepass import create_database
        path=self.root/'recycle.kdbx';db=create_database(path,password='SYNTHETIC-ONLY-2026')
        live=db.add_entry(db.root_group,'保留账号','live','live-secret')
        trashed=db.add_entry(db.root_group,'回收站账号','trashed','trashed-secret')
        db.trash_entry(trashed)
        nested=db.add_group(db.recyclebin_group,'回收站子目录')
        db.add_entry(nested,'子目录旧账号','nested','nested-secret');db.save()
        result=c.read_kdbx(path)
        self.assertEqual([item['sourceID'] for item in result['items']],[str(live.uuid)])
    def test_1pux_selection_preserves_unknown(self):
        result=c.onepux(ROOT/'fixtures/synthetic.1pux','vault-test-001')
        self.assertEqual(len(result['items']),1)
        self.assertEqual(result['items'][0]['fields']['custom.未知字段'],'保留')
        self.assertTrue(result['items'][0]['raw'])
        self.assertEqual(c.onepux(ROOT/'fixtures/synthetic.1pux','unselected-vault')['items'],[])
        with self.assertRaises(c.ConnectorError):c.onepux(ROOT/'fixtures/synthetic.1pux','missing')
    def test_keepassxc_31_header_hash_after_seed_rotation(self):
        import base64,hashlib,shutil
        from pykeepass import PyKeePass
        os.environ['PBSYNC_SOURCE_PASSWORD']='Synthetic-KeePass-Only-2026'
        source=self.root/'keepassxc.kdbx'
        shutil.copyfile(ROOT/'fixtures/keepassxc-3.1.kdbx',source)
        patch=self.root/'patch.json'
        patch.write_text('[]')
        result=c.write_kdbx(source,patch,c.digest(source))
        candidate=PyKeePass(result['candidate'],password=os.environ['PBSYNC_SOURCE_PASSWORD'])
        expected=base64.b64encode(hashlib.sha256(candidate.kdbx.header.data).digest()).decode()
        self.assertEqual(candidate.tree.findtext('Meta/HeaderHash'),expected)

    def test_zip_traversal_duplicate_and_bomb_rejected(self):
        for name,entries in [('traversal',[('../escape','bad')]),('duplicate',[('export.data','{}'),('export.data','{}')]),('bomb',[('export.data','0'*1_000_000)])]:
            path=self.root/(name+'.zip')
            with zipfile.ZipFile(path,'w',compression=zipfile.ZIP_DEFLATED) as archive:
                for filename,data in entries:archive.writestr(filename,data)
            with self.assertRaises(c.ConnectorError):c.safe_zip(path)
        self.assertFalse((self.root.parent/'escape').exists())
    def test_kdbx_real_library_roundtrip_preserves_unknown_attachment_and_history(self):
        from pykeepass import create_database,PyKeePass
        path=self.root/'synthetic.kdbx'
        db=create_database(path,password='SYNTHETIC-ONLY-2026')
        group=db.add_group(db.root_group,'中文目录')
        entry=db.add_entry(group,'合成账号','tester','original-secret',url='https://example.com',notes='保留备注')
        entry.set_custom_property('unknown-plugin-field','keep-this',protect=True)
        entry.add_attachment(db.add_binary(b'synthetic-attachment'),'附件.txt')
        db.save()
        before=path.read_bytes();baseline=c.digest(path)
        imported=c.read_kdbx(path)
        self.assertEqual(imported['items'][0]['fields']['custom.unknown-plugin-field'],'keep-this')
        self.assertEqual(len(imported['items'][0]['attachments']),1)
        patch=self.root/'patch.json';patch.write_text(json.dumps([{'sourceID':str(entry.uuid),'password':'updated-secret'}]))
        result=c.write_kdbx(path,patch,baseline,apply=False)
        self.assertEqual(path.read_bytes(),before)
        self.assertTrue(Path(result['candidate']).exists())
        self.assertFalse(result['canApply']);self.assertFalse(result['sourceChanged'])
        restored=PyKeePass(result['candidate'],password='SYNTHETIC-ONLY-2026').find_entries(uuid=entry.uuid,first=True)
        self.assertEqual(restored.password,'updated-secret');self.assertEqual(restored.custom_properties['unknown-plugin-field'],'keep-this')
        self.assertEqual(restored.attachments[0].data,b'synthetic-attachment');self.assertGreaterEqual(len(restored.history),1)
        self.assertEqual(path.read_bytes(),before)
        with self.assertRaises(c.ConnectorError):c.write_kdbx(path,patch,baseline,apply=True)
        self.assertEqual(path.read_bytes(),before)
    def test_kdbx_apply_rejected_before_source_access(self):
        from unittest.mock import patch
        with patch.object(c,'keepass',side_effect=AssertionError('不得打开来源')), patch.object(c.os,'replace',side_effect=AssertionError('不得替换来源')):
            with self.assertRaisesRegex(c.ConnectorError,'原地写回已禁用'):
                c.write_kdbx(self.root/'missing.kdbx',self.root/'missing.json','unknown',apply=True)
    def test_kdbx_concurrent_source_save_is_preserved(self):
        from pykeepass import create_database,PyKeePass
        from unittest.mock import patch
        path=self.root/'concurrent.kdbx';db=create_database(path,password='SYNTHETIC-ONLY-2026')
        entry=db.add_entry(db.root_group,'original','test','original');db.save();baseline=c.digest(path)
        patches=self.root/'patch.json';patches.write_text(json.dumps([{'sourceID':str(entry.uuid),'password':'candidate-update'}]))
        original_loader=c.keepass;concurrent_bytes=[]
        def load_then_concurrent_save(source,keyfile=None):
            loaded=original_loader(source,keyfile)
            other=PyKeePass(source,password='SYNTHETIC-ONLY-2026')
            other.find_entries(uuid=entry.uuid,first=True).title='concurrent-change';other.save()
            concurrent_bytes.append(path.read_bytes());return loaded
        with patch.object(c,'keepass',side_effect=load_then_concurrent_save):
            result=c.write_kdbx(path,patches,baseline)
        self.assertTrue(result['sourceChanged']);self.assertFalse(result['applied'])
        self.assertEqual(path.read_bytes(),concurrent_bytes[0])
        candidate=PyKeePass(result['candidate'],password='SYNTHETIC-ONLY-2026').find_entries(uuid=entry.uuid,first=True)
        self.assertEqual(candidate.password,'candidate-update')
        with self.assertRaises(c.ConnectorError):c.write_kdbx(path,patches,baseline,apply=True)
        self.assertEqual(path.read_bytes(),concurrent_bytes[0])
    def test_kdbx_unknown_write_fields_rejected(self):
        from pykeepass import create_database
        path=self.root/'test.kdbx';db=create_database(path,password='SYNTHETIC-ONLY-2026');entry=db.add_entry(db.root_group,'a','u','p');db.save()
        patch=self.root/'patch.json';patch.write_text(json.dumps([{'sourceID':str(entry.uuid),'delete':True}]))
        before=path.read_bytes()
        with self.assertRaises(c.ConnectorError):c.write_kdbx(path,patch,c.digest(path),apply=False)
        self.assertEqual(path.read_bytes(),before)
    def test_onepassword_blocks_unconditional_write(self):
        source={'id':'item','vault':{'id':'vault'},'version':3,'title':'test','fields':[{'purpose':'PASSWORD','value':'old'}]}
        original=c.op_run;c.op_run=lambda *args,**kwargs:source
        try:
            patch=self.root/'patch.json';patch.write_text(json.dumps({'password':'new'}))
            self.assertFalse(c.op_write('vault','item',patch,'3')['canApply'])
            with self.assertRaises(c.ConnectorError):c.op_write('vault','item',patch,'3',apply=True)
            with self.assertRaises(c.ConnectorError):c.op_write('other','item',patch,'3')
            self.assertEqual(source['fields'][0]['value'],'old')
        finally:c.op_run=original

if __name__=='__main__':unittest.main()
