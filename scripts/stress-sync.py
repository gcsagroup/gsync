#!/usr/bin/env python3
"""用固定 CLI 和两个全新合成配置实测规模。仅保留计数、时间及进程峰值。"""
import json,os,re,subprocess,tempfile,time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
rows=[]
with tempfile.TemporaryDirectory(prefix='pbsync-scale-') as tmp:
    base=Path(tmp)
    def run(label,*args):
        start=time.monotonic()
        p=subprocess.run(['/usr/bin/time','-l',str(root/'build/pbsync'),*map(str,args)],capture_output=True,text=True,
                         env={**os.environ,'PBSYNC_PASSWORD':'SYNTHETIC-SCALE-LOCAL-ONLY'},check=True)
        result=json.loads(p.stdout)
        rows.append(dict(stage=label,seconds=round(time.monotonic()-start,3),peakMiB=round(int(re.search(r'(\d+)\s+maximum resident set size',p.stderr)[1])/1048576,1),result=result))
        return result
    for kind,n in [('bookmarks',10000),('vault',5000)]:
        a=base/kind/'a'/'local.pbsync'; b=base/kind/'b'/'local.pbsync';remote=base/kind/'remote';src=base/kind/'input'
        run(kind+' 创建','create','--file',a,'--kind',kind,'--recovery-out',a.with_suffix('.recovery'))
        def generate(n,changed=False):
            if kind=='bookmarks':
                src.write_text('<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n'+''.join(f'<DT><A HREF="https://example.invalid/{i}">收藏 {i}</A>\n' for i in range(n))+'</DL><p>')
            else:
                src.write_text('name,url,username,password\n'+''.join(f'条目{i},https://example.invalid/{i},user{i},SYNTHETIC-{int(changed)}\n' for i in range(n)))
        def ingest():return run(kind+' 导入','import','--file',a,'--input',src,'--format','html' if kind=='bookmarks' else 'csv')
        generate(n);assert ingest()['changed']==n
        assert run(kind+' 首次同步','sync','--file',a,'--folder',remote)['pending']==0
        assert run(kind+' 第二设备首读','connect','--file',b,'--folder',remote)['items']==n
        if kind=='vault':
            generate(1000,True); assert ingest()['changed']==1000
            assert run('补传 1000 个离线版本','sync','--file',a,'--folder',remote)['uploaded']==1000
            assert run('第二设备合并','sync','--file',b,'--folder',remote)['downloaded']==1000
            assert run('无变化时重读历史','sync','--file',b,'--folder',remote)['pending']==0
            assert run('第二设备最终回读','inspect','--file',b)==dict(items=5000,revisions=6000,deleted=0)
            result=base/'restored.csv'
            run('第二设备导出比对','export','--file',b,'--output',result,'--format','csv','--allow-plaintext')
            import csv
            with result.open() as f:
                actual={r['username']:r['password'] for r in csv.DictReader(f)}
            assert actual=={f'user{i}':f'SYNTHETIC-{int(i<1000)}' for i in range(n)}
out=root/'build/f10-f12';out.mkdir(exist_ok=True)
(out/'scale.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(rows,ensure_ascii=False))
