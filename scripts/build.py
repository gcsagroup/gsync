#!/usr/bin/env python3
"""固定构建路径与递增版本；不安装真机、不上传商店、不改系统签名设置。"""
import argparse, datetime, fcntl, json, os, plistlib, shutil, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/'build'

def bump(reason):
    BUILD.mkdir(exist_ok=True)
    with (BUILD/'.version.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        number=int((ROOT/'BUILD_NUMBER').read_text().strip())+1
        (ROOT/'BUILD_NUMBER').write_text(str(number)+'\n')
        version=(ROOT/'VERSION').read_text().strip()
        record={'time':datetime.datetime.now().astimezone().isoformat(),'version':version,'build':number,'action':reason}
        with (BUILD/'build-history.jsonl').open('a') as output:output.write(json.dumps(record,ensure_ascii=False)+'\n')
    return version,number

def run(args,log):
    with log.open('w') as output:
        result=subprocess.run(args,cwd=ROOT,stdout=output,stderr=subprocess.STDOUT)
    if result.returncode:
        print(f'构建未通过，日志：{log}')
        lines=log.read_text(errors='replace').splitlines()
        issues=[line for line in lines if 'error:' in line or 'warning:' in line]
        print('\n'.join(issues[-35:] or lines[-15:]))
        raise SystemExit(result.returncode)

def verify_product(target, platform, version, number):
    """读取实际安装包，而不是用构建参数推断结果。任何主包／扩展不一致都失败。"""
    app_id = 'com.gcsa.pbsync' + ('.ios' if platform == 'ios' else '')
    expected_ids = {app_id, app_id + '.credentials'}
    relative_info = 'Contents/Info.plist' if platform == 'mac' else 'Info.plist'
    plugins = target / ('Contents/PlugIns' if platform == 'mac' else 'PlugIns')
    bundles = [target, *sorted(plugins.glob('*.appex'))]
    records = []
    for bundle in bundles:
        info = plistlib.loads((bundle / relative_info).read_bytes())
        actual = (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion'))
        if actual != (version, str(number)):
            raise ValueError(f'产物版本不一致：{bundle.name}，期望 {version} ({number})，回读 {actual}')
        records.append({'path':str(bundle.relative_to(BUILD)), 'bundleID':info.get('CFBundleIdentifier'),
                        'version':actual[0], 'build':actual[1]})
    if len(records) != 2 or {record['bundleID'] for record in records} != expected_ids:
        raise ValueError('主 App／凭据扩展身份或数量不一致，构建不予通过。')
    return records

def build(platform, team=None):
    signed = platform in ('mac-signed', 'device')
    if signed and not (team and len(team) == 10 and team.isalnum()):
        raise SystemExit('开发签名需要 --team 指定团队。')
    action = platform
    version,number=bump(action)
    if signed: platform = 'mac' if action == 'mac-signed' else 'ios'
    if platform in ('mac', 'mac-signed'):
        if not (BUILD/'f14-pack-env/bin/python').is_file():
            raise SystemExit('缺少 Mac 打包环境，请先按 distribution/BUILD.md 安装构建依赖。')
        run([str(BUILD/'f14-pack-env/bin/python'), 'scripts/freeze-connector.py'],BUILD/f'connector-{number}.log')
    run(['xcodegen','generate','--spec',str(ROOT/'apps/Apple/project.yml')],BUILD/f'generate-{number}.log')
    if platform=='test-bundles':
        run(['swift','build','--build-tests','--scratch-path',str(BUILD/'swift')],BUILD/f'test-bundles-{number}.log')
        return
    if platform=='core-tests':
        run(['swift','test','--scratch-path',str(BUILD/'swift'),'--parallel'],BUILD/f'core-tests-{number}.log')
        print(f'核心测试通过：{BUILD/f"core-tests-{number}.log"}');return
    if platform=='cli':
        run(['swift','build','--scratch-path',str(BUILD/'swift'),'--product','pbsync'],BUILD/f'cli-{number}.log')
        # macOS 可能仍缓存旧 inode 的代码签名；在同目录完成签名与校验后原子替换。
        staged = BUILD/f'.pbsync-{number}'
        try:
            shutil.copy2(BUILD/'swift/debug/pbsync', staged)
            run(['codesign','--force','--sign','-','--identifier','com.gcsa.pbsync.nativehost',str(staged)], BUILD/f'sign-cli-{number}.log')
            run(['codesign','--verify','--strict',str(staged)], BUILD/f'verify-cli-{number}.log')
            os.replace(staged, BUILD/'pbsync')
        finally:
            staged.unlink(missing_ok=True)
        print(f'CLI 构建 {number}：{BUILD/"pbsync"}');return
    scheme='PBsyncMac' if platform=='mac' else 'PBsyncIOS'
    destination='platform=macOS' if platform=='mac' else 'generic/platform=iOS Simulator'
    signing = ['CODE_SIGNING_ALLOWED=NO']
    if platform == 'ios' and not signed:
        signing = ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-']
    if signed:
        signing = ['-allowProvisioningUpdates',f'DEVELOPMENT_TEAM={team}','CODE_SIGN_IDENTITY=Apple Development']
        if platform == 'ios': destination = 'generic/platform=iOS'
    run(['xcodebuild' ,'-project',str(ROOT/'apps/Apple/PBsync.xcodeproj'),'-scheme',scheme,'-configuration','Debug','-destination',destination,'-derivedDataPath',str(BUILD/'apple'),*signing,f'MARKETING_VERSION={version}',f'CURRENT_PROJECT_VERSION={number}','build'],BUILD/f'{platform}-{number}.log')
    if platform=='mac':
        source=BUILD/'apple/Build/Products/Debug/GCSA-PBsync.app';target=BUILD/'GCSA-PBsync.app'
        # 只更新本项目固定 App 目录；运行中版本由调用方先退出。
        if target.exists():shutil.rmtree(target)
        shutil.copytree(source,target)
        helper=target/'Contents/Resources/pbsync-connector'
        if not os.access(helper, os.X_OK) or not (helper.parent/'ConnectorNotices/Python-LICENSE.txt').is_file():
            raise ValueError('安装包缺少连接器或许可文本')
        if not signed:
            info=target/'Contents/Info.plist'
            data=plistlib.loads(info.read_bytes());data['PBsyncSharedContainer']=False
            info.write_bytes(plistlib.dumps(data))
            for extension in (target/'Contents/PlugIns').glob('*.appex'):
                run(['codesign','--force','--sign','-',str(extension)],BUILD/f'sign-extension-{number}.log')
            run(['codesign','--force','--sign','-',str(target)],BUILD/f'sign-app-{number}.log')
        run(['codesign','--verify','--deep','--strict',str(target)],BUILD/f'verify-signature-{number}.log')
    else:
        target=BUILD/'apple/Build/Products'/('Debug-iphoneos' if signed else 'Debug-iphonesimulator')/'PBsync.app'
    records=verify_product(target, platform, version, number)
    if signed:
        for product in records:
            bundle = BUILD/product['path']
            run(['codesign','--verify','--strict',str(bundle)],BUILD/f'verify-{bundle.stem}-{number}.log')
            ent = plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements','-',str(bundle)],stderr=subprocess.DEVNULL))
            if ent.get('com.apple.developer.team-identifier') != team or 'group.com.gcsa.pbsync' not in ent.get('com.apple.security.application-groups',[]) or ent.get('com.apple.developer.authentication-services.autofill-credential-provider') is not True:
                raise ValueError(f'团队、共享容器或凭据权限回读失败：{bundle.name}')
    receipt={'time' :datetime.datetime.now().astimezone().isoformat(),'platform':platform,
             'signature':'development-verified' if signed else 'ad-hoc-verified' if platform=='mac' else 'simulator-no-distribution-signing',
             'products':records}
    (BUILD/f'product-{action}-{number}.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
    print(f'Ver {version} ({number})：{target}；主 App 与凭据扩展版本回读一致。')
    if platform=='mac' and not signed:print('本机临时签名验证通过；系统提供器及正式分发仍待受信任签名验收。')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('target',choices=['mac','ios','cli','core-tests','test-bundles','mac-signed','device']);parser.add_argument('--team');args=parser.parse_args();build(args.target,args.team)
