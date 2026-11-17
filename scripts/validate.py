#!/usr/bin/env python3
"""运行本地测试，可附上当前候选的 UI 实操回执并检查发布条件。"""
import argparse
import datetime
import importlib.util
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

from candidate_checks import checked_counts, products, release_status

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-check', action='store_true')
    parser.add_argument('--ui-receipt', type=Path)
    parser.add_argument('--store-apps', nargs=2, type=Path, metavar=('MAC_APP','IPHONE_APP'), help='build 目录下实际导出的商店 .app')
    parser.add_argument('--team', help='商店包应使用的团队 ID')
    args = parser.parse_args()
    run_dir = ROOT/'build'/('validation-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    run_dir.mkdir(parents=True)
    spec = importlib.util.spec_from_file_location('dav', ROOT/'services/local/server.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    server = module.StorageServer(('127.0.0.1',0),run_dir/'remote-ciphertext','test-user','synthetic-dav-secret-2026','synthetic-cloud-token-2026')
    thread = threading.Thread(target=server.serve_forever,daemon=True)
    thread.start()
    env = dict(os.environ, PBSYNC_TEST_DAV_URL=f'http://127.0.0.1:{server.server_port}/dav/{uuid.uuid4().hex}/')
    results = []

    def run(name, argv, *, counted=False):
        log = run_dir/(name+'.log')
        start = time.monotonic()
        record = {'name':name,'log':str(log)}
        try:
            with log.open('w') as output:
                process = subprocess.run(argv,cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=600)
            record['exitCode'] = process.returncode
            if process.returncode == 0 and counted:
                record['passed'] = checked_counts(name,log.read_text(errors='replace'))
        except (OSError, ValueError, TypeError, subprocess.TimeoutExpired) as exc:
            record.update(exitCode=1,reason=str(exc))
        record['seconds'] = round(time.monotonic()-start,3)
        results.append(record)
        print(name, '通过' if record['exitCode']==0 else '失败', record.get('passed',''), flush=True)
        return record['exitCode'] == 0

    py = ROOT/'.venv/bin/python'
    try:
        if run('test-build',['python3','scripts/build.py','test-bundles']):
            for suite in ('PBsyncCoreTests','PBsyncAppTests'):
                # 单独读取 XCTest 框架实际计数，构建时的并行调度摘要不计入。
                run(suite,['xcrun','xctest',ROOT/f'build/swift/out/Products/Debug/{suite}.xctest'],counted=True)
        run('python',[py,'-m','unittest','discover','-s','Tests','-p','test_*.py','-v'],counted=True)
        run('extension',['node','--test','--test-reporter=tap','Tests/extension.test.mjs','Tests/native-writes.test.mjs'],counted=True)
        run('independent-crypto',[py,'scripts/independent-crypto-check.py'])
        run('format-v1',[py,'scripts/check-format-vector.py'])
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    current = {}
    summary = {'time':datetime.datetime.now().astimezone().isoformat(),'results':results}
    receipt = None
    try:
        if args.ui_receipt:
            receipt = json.loads(args.ui_receipt.read_text())
        current = products(args.store_apps,args.team)
    except (OSError, ValueError, TypeError, KeyError, subprocess.CalledProcessError) as exc:
        summary['candidateError'] = str(exc)
    summary.update(release_status(results,current,receipt,checked_store=bool(args.store_apps)))
    summary['passedTests'] = sum(r.get('passed',0) for r in results)
    (run_dir/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    (ROOT/'build/latest-validation.txt').write_text(str(run_dir)+'\n')
    print(f'{summary["passedTests"]} 项通过；UI {summary["manualUI"]}；发布条件{"满足" if summary["releaseReady"] else "尚未满足"}。记录：{run_dir}')
    if summary['automated'] != '通过': return 1
    if args.release_check and not summary['releaseReady']: return 2
    return 0


if __name__=='__main__':
    sys.exit(main())
