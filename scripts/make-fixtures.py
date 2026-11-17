#!/usr/bin/env python3
"""创建合成数据，不读取用户浏览器或真实密码。"""
import csv,io,json,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
fixtures=ROOT/'fixtures';fixtures.mkdir(exist_ok=True)
html=['<!DOCTYPE NETSCAPE-Bookmark-file-1>','<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">','<DL><p>']
for folder in range(5):
    html.append(f'<DT><H3>中文目录 {folder+1}</H3><DL><p>')
    for i in range(6):html.append(f'<DT><A HREF="https://example.com/{i}">合成收藏 {folder+1}-{i+1}</A>')
    if folder==0:html.extend(['<DT><H3>二级目录</H3><DL><p>','<DT><H3>三级目录</H3><DL><p>','</DL><p>','</DL><p>'])
    html.append('</DL><p>')
html.append('</DL><p>');(fixtures/'bookmarks.html').write_text('\n'.join(html)+'\n')
with (fixtures/'logins.csv').open('w',newline='') as output:
    writer=csv.writer(output);writer.writerow(['name','url','username','password','note','未知字段'])
    for i in range(12):writer.writerow([f'合成账号 {i+1}','https://example.com',f'user{i}@example.invalid',f'ONLY-SYNTHETIC-{i}-NOT-A-REAL-SECRET','中文备注，含逗号\n第二行','保留扩展内容'])
source={'uuid':'entry-test-001','categoryUuid':'001','overview':{'title':'1PUX 合成账号','urls':[{'url':'https://example.com'}]},'details':{'loginFields':[{'designation':'username','value':'test@example.invalid'},{'designation':'password','value':'SYNTHETIC-ONLY'}],'notesPlain':'合成来源，不是真实导出','sections':[{'fields':[{'id':'f1','title':'未知字段','value':{'string':'保留'}}]}]}}
with zipfile.ZipFile(fixtures/'synthetic.1pux','w',compression=zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('export.attributes',json.dumps({'version':3}))
    archive.writestr('export.data',json.dumps({'accounts':[{'vaults':[{'attrs':{'uuid':'vault-test-001','name':'合成测试库'},'items':[source]},{'attrs':{'uuid':'unselected-vault','name':'未选择库'},'items':[]}]}]}))
(fixtures/'README.md').write_text('# 合成测试数据\n\n这些文件由 scripts/make-fixtures.py 生成，全部是虚构账号与 example.com 网址，不含个人数据。30 个收藏、7 个目录（三层嵌套）、12 条 CSV 登录项。synthetic.1pux 用于格式与范围测试，不是 1Password 实际客户端导出证据。\n')
print('合成样本已生成')
