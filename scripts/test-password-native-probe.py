#!/usr/bin/env python3
"""使用合成钥匙和临时 SQLite 核对实验工具；不访问用户钥匙串。"""
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('probe', Path(__file__).with_name('password-native-probe.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
firefox_spec = importlib.util.spec_from_file_location('firefox_probe',
    Path(__file__).with_name('firefox-password-native-probe.py'))
firefox = importlib.util.module_from_spec(firefox_spec)
firefox_spec.loader.exec_module(firefox)
KEY = bytes(range(16))


class ProbeTests(unittest.TestCase):
    def test_crypto_matches_independent_openssl(self):
        for plain in [b'', b'one', '独立测试账号🔑'.encode(), b'a' * 32]:
            expected = subprocess.run(['openssl', 'enc', '-aes-128-cbc', '-K', KEY.hex(),
                '-iv', (b' ' * 16).hex()], input=plain, capture_output=True, check=True).stdout
            self.assertEqual(probe.crypt(plain, KEY), b'v10' + expected)
            self.assertEqual(probe.crypt(b'v10' + expected, KEY, True), plain)

    def test_rejects_unknown_or_damaged_ciphertext(self):
        for ciphertext in [b'v11' + b'a' * 16, b'v10', b'v10' + b'a' * 15]:
            with self.assertRaises(probe.ProbeError):
                probe.crypt(ciphertext, KEY, True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.profile = self.root / 'Profile 2'
        self.profile.mkdir()
        self.database = self.profile / 'Login Data'
        self.origin = 'http://127.0.0.1:60696'
        (self.root / 'site.json').write_text(json.dumps({'origin': self.origin}))
        with probe.connect(self.database) as connection:
            connection.executescript('''
                create table meta (key text, value text);
                insert into meta values ('version','43');
                create table logins (origin_url text, action_url text, username_element text,
                    username_value text, password_element text, password_value blob,
                    submit_element text, signon_realm text, date_created integer,
                    blacklisted_by_user integer, scheme integer, password_type integer,
                    times_used integer, skip_zero_click integer, date_password_modified integer);
            ''')
        self.patch = patch.multiple(probe, PROFILE=self.profile, DATABASE=self.database,
                                    EVIDENCE=self.root)
        self.patch.start()
        self.key = patch.object(probe, 'chrome_key', return_value=KEY)
        self.key_mock = self.key.start()

    def tearDown(self):
        self.key.stop()
        self.patch.stop()
        self.temp.cleanup()

    def test_add_update_delete_and_backup(self):
        first = probe.run('upsert')
        self.assertEqual(probe.run('read')['revisions'], [1])
        probe.run('upsert', revision=2)
        self.assertEqual(probe.run('read')['revisions'], [2])
        deletion = probe.run('delete')
        self.assertEqual(probe.run('read')['count'], 0)
        with probe.connect(first['backup']) as connection:
            self.assertEqual(connection.execute('select count(*) from logins').fetchone()[0], 0)
        with probe.connect(deletion['backup']) as connection:
            cipher = connection.execute('select password_value from logins').fetchone()[0]
            self.assertEqual(probe.crypt(cipher, KEY, True).decode(), probe.PASSWORDS[1])

    def test_foreign_account_stops_before_keychain_access(self):
        with probe.connect(self.database) as connection:
            connection.execute('insert into logins (origin_url,username_value,signon_realm) '
                               'values (?,?,?)', ('https://example.test/', 'foreign', 'https://example.test/'))
        with self.assertRaises(probe.ProbeError):
            probe.run('delete')
        self.key_mock.assert_not_called()

    def test_unknown_schema_stops_before_keychain_access(self):
        with probe.connect(self.database) as connection:
            connection.execute("update meta set value='44'")
        with self.assertRaises(probe.ProbeError):
            probe.run('upsert')
        self.key_mock.assert_not_called()

    def test_denied_keychain_does_not_write(self):
        self.key_mock.side_effect = probe.ProbeError('合成拒绝')
        with self.assertRaises(probe.ProbeError):
            probe.run('upsert')
        with probe.connect(self.database) as connection:
            self.assertEqual(connection.execute('select count(*) from logins').fetchone()[0], 0)
        self.assertEqual(list(self.root.glob('chrome-before-*')), [])

    def test_symlink_profile_is_rejected(self):
        link = self.root / 'link'
        link.symlink_to(self.profile, target_is_directory=True)
        with patch.multiple(probe, PROFILE=link, DATABASE=link / 'Login Data'):
            with self.assertRaises(probe.ProbeError):
                probe.run('upsert')
        self.key_mock.assert_not_called()

    def test_session_keeps_one_in_memory_authorization(self):
        commands = '\n'.join(json.dumps(c) for c in [
            {'action': 'upsert', 'revision': 1}, {'action': 'read'},
            {'action': 'delete'}, {'action': 'quit'}]) + '\n'
        output = io.StringIO()
        with patch.object(probe.sys, 'stdin', io.StringIO(commands)), patch.object(probe.sys, 'stdout', output):
            probe.session()
        self.key_mock.assert_called_once_with(False)
        results = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertTrue(results[0]['ready'])
        self.assertEqual(results[2]['revisions'], [1])

    def test_edge_removes_associated_test_records(self):
        with probe.connect(self.database) as c:
            c.executescript('''
                alter table logins add column id integer;
                create trigger login_id after insert on logins begin
                    update logins set id=new.rowid where rowid=new.rowid; end;
                insert into meta values ('logins_edge_extended_table_version','4');
                insert into meta values ('edge_breached_table_version','6');
                create table logins_edge_extended(id integer primary key);
                create table breached(url text,username text);
                create table sync_entities_metadata(id integer);
                create table sync_model_metadata(id integer);
            ''')
        with patch.object(probe, 'BROWSER', 'edge'):
            probe.run('upsert')
            with probe.connect(self.database) as c:
                self.assertEqual(c.execute('select count(*) from logins_edge_extended').fetchone()[0], 1)
                c.execute('insert into breached values (?,?)', (self.origin + '/', probe.USERNAME))
            probe.run('delete')
            with probe.connect(self.database) as c:
                self.assertEqual(c.execute('select count(*) from logins_edge_extended').fetchone()[0], 0)
                self.assertEqual(c.execute('select count(*) from breached').fetchone()[0], 0)
                c.execute('insert into sync_model_metadata values (1)')
            with self.assertRaises(probe.ProbeError):
                probe.run('upsert')


class FirefoxGuards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.profile = self.root / 'firefox-profile'
        self.profile.mkdir()
        self.database = self.profile / 'logins.json'
        self.original = json.dumps({'version': 3, 'nextId': 1, 'logins': []})
        self.database.write_text(self.original)
        (self.profile / 'key4.db').touch()
        (self.root / 'site.json').write_text(json.dumps({'origin': 'http://127.0.0.1:60696'}))
        self.patch = patch.multiple(firefox, PROFILE=self.profile, DATABASE=self.database, EVIDENCE=self.root)
        self.patch.start()
        self.native = patch.object(firefox, 'NSS')
        self.nss = self.native.start()

    def tearDown(self):
        self.native.stop()
        self.patch.stop()
        self.temp.cleanup()

    def test_live_process_is_rejected_before_crypto_or_write(self):
        result = subprocess.CompletedProcess([], 0, stdout=f'/Applications/Firefox.app/Contents/MacOS/firefox -profile {self.profile}')
        with patch.object(firefox.subprocess, 'run', return_value=result):
            with self.assertRaises(firefox.ProbeError):
                firefox.run('upsert')
        self.assertEqual(self.database.read_text(), self.original)
        self.nss.assert_not_called()

    def test_unknown_format_is_rejected(self):
        self.database.write_text(json.dumps({'version': 4, 'logins': []}))
        with self.assertRaises(firefox.ProbeError):
            firefox.run('read')
        self.nss.assert_not_called()

    def test_foreign_origin_is_rejected(self):
        self.database.write_text(json.dumps({'version': 3, 'logins': [
            {'hostname': 'https://example.test', 'encType': 1}]}))
        with self.assertRaises(firefox.ProbeError):
            firefox.run('read')
        self.nss.assert_not_called()

    def test_active_rust_store_is_rejected(self):
        with probe.connect(self.profile / 'logins.db') as c:
            c.executescript('create table loginsL(id integer); create table loginsM(id integer); insert into loginsL values(1);')
        with self.assertRaises(firefox.ProbeError):
            firefox.run('read')
        self.nss.assert_not_called()


class BrowserSelectionTests(unittest.TestCase):
    def test_edge_uses_only_fixed_test_profile_and_own_key(self):
        with patch.multiple(probe, PROFILE=probe.PROFILE, DATABASE=probe.DATABASE,
                            KEY_SERVICE=probe.KEY_SERVICE, KEY_ACCOUNT=probe.KEY_ACCOUNT,
                            BROWSER=probe.BROWSER):
            probe.select_browser('edge')
            self.assertEqual(probe.DATABASE, probe.EVIDENCE / 'edge-profile/Default/Login Data')
            self.assertEqual(probe.KEY_SERVICE, b'Microsoft Edge Safe Storage')
            self.assertEqual(probe.KEY_ACCOUNT, b'Microsoft Edge')
            self.assertEqual(probe.BROWSER, 'edge')
            with self.assertRaises(probe.ProbeError):
                probe.select_browser('daily-profile')


if __name__ == '__main__':
    unittest.main(verbosity=2)
