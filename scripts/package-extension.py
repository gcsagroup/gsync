#!/usr/bin/env python3
"""从共用书签引擎生成完整扩展与仅书签扩展。"""
import json
import shutil
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = ROOT/'extensions/browser'
base = ROOT/'build/extensions'
receipts = []
for browser in ('chromium','firefox'):
    for bookmarks_only in (False, True):
        name = browser + ('-bookmarks' if bookmarks_only else '')
        target = base/name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(ROOT/'extensions/bookmarks-only' if bookmarks_only else source, target)
        shutil.copy2(ROOT/'LICENSE', target/'LICENSE.txt')
        if bookmarks_only:
            for shared in ('bookmarks.mjs','native-writes.mjs','crypto.mjs','policy.mjs','style.css'):
                shutil.copy2(source/shared, target/shared)
        path = target/'manifest.json'
        manifest = json.loads(path.read_text())
        if browser=='firefox':
            manifest['background']={'scripts':['background.mjs'],'type':'module'}
            extension_id = 'pbsync-bookmarks@gcsa.local' if bookmarks_only else 'pbsync@gcsa.local'
            manifest['browser_specific_settings']={'gecko':{'id':extension_id,'strict_min_version':'142.0','data_collection_permissions':{'required':['none']}}}
        path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
        archive = Path(shutil.make_archive(str(base/('pbsync-'+name)),'zip',target))
        receipts.append({'package':name, 'version':manifest['version'], 'archive':archive.name,
                         'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),
                         'signed':False, 'permissions':manifest['permissions']})
        print(target)
(base/'package-receipts.json').write_text(json.dumps(receipts,ensure_ascii=False,indent=2)+'\n')
