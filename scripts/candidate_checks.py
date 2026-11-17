"""本地候选读回与发布检查。缺少、跳过或过期的证据均单独列出。"""
import datetime
import json
import plistlib
import re
import subprocess
from pathlib import Path

from build import BUILD, ROOT, verify_product

BUNDLES = {'mac': BUILD / 'GCSA-PBsync.app',
           'ios': BUILD / 'apple/Build/Products/Debug-iphonesimulator/PBsync.app'}
UI_CASES = {'mac': {'restore', 'locked', 'wrong-password', 'unlock'},
            'ios': {'fresh-install', 'restore', 'open-items'}}


def checked_counts(name, output):
    """读取运行器的最终摘要，禁止以退出码零代替实际测试数。"""
    if name == 'python':
        match = re.search(r'^Ran (\d+) tests? in ', output, re.M)
        if not match or not re.search(r'^OK\s*$', output, re.M):
            raise ValueError('Python 测试缺失、失败或跳过')
        count = int(match[1])
    elif name == 'extension':
        def field(key):
            match = re.search(r'^# ' + key + r' (\d+)$', output, re.M)
            if not match:
                raise ValueError('缺少扩展测试计数：'+key)
            return int(match[1])
        count = field('pass')
        if count != field('tests') or any(field(k) for k in ('fail', 'skipped', 'todo', 'cancelled')):
            raise ValueError('扩展测试未全部执行通过')
    else:
        # 只采信整个 XCTest 包的最后摘要。
        match = re.search(r"Test Suite 'All tests' passed[^\n]*\n\s*Executed (\d+) tests?, with 0 failures", output)
        if not match or re.search(r"Test Case .* skipped", output):
            raise ValueError('XCTest 包为空、跳过或失败')
        count = int(match[1])
    if count <= 0:
        raise ValueError('测试计数为零')
    return count


def verify_store_signature(bundle, platform, identifier, team, details):
    """对待送审的实际包核对 Apple 信任链、团队、系统平台和扩展权限。"""
    if not re.fullmatch(r'[A-Z0-9]{10}', team or ''):
        raise ValueError('请指定要核对的十位团队 ID')
    subprocess.run(['codesign','--verify','--strict','-R','anchor apple generic',bundle],
                   check=True,capture_output=True)
    if f'TeamIdentifier={team}' not in details.splitlines() or not re.search(r'^Authority=(Apple Distribution|3rd Party Mac Developer Application|iPhone Distribution):', details, re.M):
        raise ValueError('主包或扩展的分发签名、团队不符合要求')
    contents = bundle/'Contents' if platform=='mac' else bundle
    info = plistlib.loads((contents/'Info.plist').read_bytes())
    target = 'MacOSX' if platform=='mac' else 'iPhoneOS'
    if target not in info.get('CFBundleSupportedPlatforms',[]):
        raise ValueError('实际包的系统平台不匹配')
    ent = plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements','-',bundle],stderr=subprocess.DEVNULL))
    profile_path = contents/('embedded.provisionprofile' if platform=='mac' else 'embedded.mobileprovision')
    profile = plistlib.loads(subprocess.check_output(['security','cms','-D','-i',profile_path],stderr=subprocess.DEVNULL))
    if team not in profile['TeamIdentifier'] or profile['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise ValueError('描述文件的团队或有效期不符合要求')
    if profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices'):
        raise ValueError('需要商店分发描述文件')
    app_key = 'com.apple.application-identifier' if platform=='mac' else 'application-identifier'
    for rights in (ent,profile['Entitlements']):
        if (rights.get(app_key) != team+'.'+identifier or rights.get('get-task-allow') or
                rights.get('com.apple.security.get-task-allow') or
                rights.get('com.apple.developer.authentication-services.autofill-credential-provider') is not True or
                'group.com.gcsa.pbsync' not in rights.get('com.apple.security.application-groups',[])):
            raise ValueError('主包或扩展的应用身份、权限或调试开关不符合送审条件')


def products(store_apps=None, team=None):
    result = {}
    version = (ROOT / 'VERSION').read_text().strip()
    selected = BUNDLES if store_apps is None else dict(zip(('mac','ios'),store_apps,strict=True))
    for platform, target in selected.items():
        app = target.resolve()
        info = 'Contents/Info.plist' if platform == 'mac' else 'Info.plist'
        number = plistlib.loads((app / info).read_bytes())['CFBundleVersion']
        rows = verify_product(app, platform, version, int(number))
        if store_apps is None:
            receipt = json.loads((BUILD / f'product-{platform}-{number}.json').read_text())
            if rows != receipt['products']:
                raise ValueError('构建回执与实际产物不一致')
        components = []
        for row in rows:
            bundle = BUILD / row['path']
            subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True,capture_output=True)
            details = subprocess.check_output(['codesign','-dvvv',str(bundle)],stderr=subprocess.STDOUT,text=True)
            if store_apps is not None:
                verify_store_signature(bundle,platform,row['bundleID'],team,details)
            cdhash = re.search(r'^CDHash=([0-9a-f]+)$', details, re.M)[1]
            resources = bundle / 'Contents/Resources' if platform == 'mac' else bundle
            notice = resources / 'ZIPFoundation-MIT.txt'
            if notice.read_bytes() != (ROOT / 'distribution/licenses' / notice.name).read_bytes():
                raise ValueError('包内第三方声明版本不一致')
            components.append(dict(row, cdhash=cdhash, adhoc='Signature=adhoc' in details or 'adhoc' in details.split('flags=')[-1].splitlines()[0]))
        result[platform] = components
    return result


def ui_result(receipt, current):
    if receipt is None:
        return '待实操'
    if not isinstance(receipt, dict):
        return '回执格式无效'
    for platform, cases in UI_CASES.items():
        entry = receipt.get(platform, {})
        if not isinstance(entry,dict): return '回执格式无效'
        if entry.get('cdhashes') != [p['cdhash'] for p in current[platform]]:
            return '产物已变化，需重新实操'
        observations = entry.get('observations', {})
        if not isinstance(observations,dict): return '回执格式无效'
        if any(not isinstance(observations.get(case),dict) or observations[case].get('status') != '通过' or
               not observations[case].get('observed') for case in cases):
            return '实操未全部通过'
    return '通过'


def release_status(runs, current, receipt, *, checked_store=False):
    ui = ui_result(receipt, current) if current else '产物校验失败'
    # 这些项目按产品计划需单独验收并更新。分发渠道的发布动作在验收之后。
    open_items = json.loads((ROOT / 'distribution/open-gates.json').read_text())
    return {'automated': '通过' if all(r['exitCode'] == 0 for r in runs) else '失败',
            'products': current, 'manualUI': ui, 'openRequirements': open_items,
            'signingStatus': '商店签名及描述文件通过' if checked_store and current else '尚缺已核验的商店包',
            'distributionStatus': {name:'未提供发布回执' for name in ['TestFlight','App Store','GitHub','公开云']},
            'releaseReady': checked_store and bool(current) and ui == '通过' and not open_items and all(r['exitCode'] == 0 for r in runs)
                            and all(not p['adhoc'] for rows in current.values() for p in rows)}
