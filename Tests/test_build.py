"""F03：验证最终产物身份和版本，不以命令参数代替回读。"""
import importlib.util,plistlib,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('build_script',ROOT/'scripts/build.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class BuildReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='pbsync-build-test-');self.root=Path(self.tmp.name)
        self.old=m.BUILD;m.BUILD=self.root
    def tearDown(self):m.BUILD=self.old;self.tmp.cleanup()
    def fixture(self,platform='mac',extension_build='7',extension_id=None):
        target=self.root/'PBsync.app';suffix='Contents/Info.plist' if platform=='mac' else 'Info.plist'
        plugin=target/('Contents/PlugIns' if platform=='mac' else 'PlugIns')/'Credentials.appex'
        app_id='com.gcsa.pbsync'+('.ios' if platform=='ios' else '')
        for bundle,identifier,number in [(target,app_id,'7'),(plugin,extension_id or app_id+'.credentials',extension_build)]:
            path=bundle/suffix;path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier,'CFBundleShortVersionString':'1.0','CFBundleVersion':number}))
        return target
    def test_mac_and_ios_receipts(self):
        for platform in ['mac','ios']:
            with self.subTest(platform=platform):self.assertEqual(len(m.verify_product(self.fixture(platform),platform,'1.0',7)),2)
    def test_rejects_stale_extension_version(self):
        with self.assertRaisesRegex(ValueError,'版本不一致'):m.verify_product(self.fixture(extension_build='1'),'mac','1.0',7)
    def test_rejects_wrong_bundle_identity(self):
        with self.assertRaisesRegex(ValueError,'身份或数量'):m.verify_product(self.fixture(extension_id='wrong.id'),'mac','1.0',7)
    def test_rejects_missing_extension(self):
        target=self.fixture();import shutil;shutil.rmtree(target/'Contents/PlugIns')
        with self.assertRaisesRegex(ValueError,'身份或数量'):m.verify_product(target,'mac','1.0',7)
    def test_generator_keeps_all_four_version_variables(self):
        text=(ROOT/'apps/Apple/project.yml').read_text()
        self.assertEqual(text.count('CFBundleVersion: $(CURRENT_PROJECT_VERSION)'),4)
        self.assertEqual(text.count('CFBundleShortVersionString: $(MARKETING_VERSION)'),4)
if __name__=='__main__':unittest.main()
