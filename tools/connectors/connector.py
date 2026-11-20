#!/usr/bin/env python3
"""桌面来源连接器。输入／输出通过管道传递；秘密不进入命令参数与错误日志。"""
from __future__ import annotations
import argparse, base64, copy, datetime, hashlib, json, os, re, shutil, stat, subprocess, sys, tempfile, uuid, zipfile
from pathlib import Path, PurePosixPath

MAX_INPUT=128*1024*1024
MAX_ATTACHMENT=10*1024*1024

class ConnectorError(Exception): pass

def encode(data): return base64.b64encode(data).decode()
def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def secret(name):
    value=os.environ.get(name)
    if value is None: raise ConnectorError('缺少受控环境中的解锁材料。')
    return value

def base_item(identifier, title, kind='login', urls=None, fields=None, notes='', raw=None):
    return {'sourceID':str(identifier),'title':title or '未命名','kind':kind,'urls':urls or [],'fields':fields or {},'notes':notes or '', 'tags':[], 'attachments':[], 'raw':encode(json.dumps(raw or {},ensure_ascii=False,separators=(',',':')).encode())}

def safe_zip(path):
    if Path(path).stat().st_size>MAX_INPUT: raise ConnectorError('导入包超过 128 MB。')
    archive=zipfile.ZipFile(path)
    total=0; seen=set()
    for info in archive.infolist():
        name=info.filename; parts=PurePosixPath(name)
        if parts.is_absolute() or '..' in parts.parts or '\\' in name or '\x00' in name or re.match(r'^[A-Za-z]:',name) or name in seen: raise ConnectorError('导入包包含不安全或重复路径。')
        seen.add(name)
        if stat.S_ISLNK(info.external_attr>>16): raise ConnectorError('导入包不允许符号链接。')
        total+=info.file_size
        if total>MAX_INPUT or info.file_size>MAX_INPUT or info.file_size>max(1,info.compress_size)*200: raise ConnectorError('导入包展开大小或压缩比超限。')
    return archive

def onepux(path,vault_id=None,listing=False):
    with safe_zip(path) as archive:
        if 'export.data' not in archive.namelist(): raise ConnectorError('缺少 1PUX export.data。')
        data=json.loads(archive.read('export.data'))
        vaults=[v for account in data.get('accounts',[]) for v in account.get('vaults',[])]
        summaries=[{'id':v.get('attrs',{}).get('uuid'),'name':v.get('attrs',{}).get('name',''),'count':len(v.get('items',[]))} for v in vaults]
        if listing: return {'vaults':summaries}
        selected=[v for v in vaults if v.get('attrs',{}).get('uuid')==vault_id]
        if len(selected)!=1: raise ConnectorError('必须选择一个有效的来源保险库。')
        items=[]; warnings=[]
        for source in selected[0].get('items',[]):
            overview=source.get('overview',{}); details=source.get('details',{})
            fields={}; urls=[]
            for entry in details.get('loginFields',[]):
                designation=entry.get('designation')
                if designation in ('username','password'): fields[designation]=str(entry.get('value',''))
            for entry in overview.get('urls',[]):
                if entry.get('url'): urls.append(entry['url'])
            if overview.get('url') and overview['url'] not in urls: urls.append(overview['url'])
            category=str(source.get('categoryUuid',''))
            kind={'001':'login','002':'card','003':'note','004':'identity'}.get(category,'note')
            if category not in ('001','002','003','004'): warnings.append('部分来源类型按安全笔记保存，原始字段完整保留，尚未建立等价行为。')
            for section in details.get('sections',[]):
                for field in section.get('fields',[]):
                    value=field.get('value',{}); label=field.get('title') or field.get('id') or '字段'
                    text=next((str(v) for k,v in value.items() if k!='file' and isinstance(v,(str,int,float))),None)
                    aliases={'ccnum':'number','cardholder':'cardholder','expiry':'expiry','cvv':'cvv'} if kind=='card' else {}
                    if text is not None and field.get('id') in aliases:
                        fields[aliases[field['id']]]=text
                    if text is not None:
                        key='totp' if 'totp' in value else 'custom.'+label
                        if key in fields: key+='.'+str(field.get('id',''))
                        fields[key]=str(text)
            if category=='005':
                kind='login';fields['password']=details.get('password','')
            if source.get('state','active')!='active':
                kind='note';warnings.append('归档条目保留为笔记，不参与自动填充。')
            identity=source.get('uuid')
            if not identity:
                identity='file-only-'+hashlib.sha256(json.dumps(source,sort_keys=True).encode()).hexdigest()
                warnings.append('缺少来源 ID 的条目仅用于文件迁移，内容变化时需人工核对。')
            item=base_item(identity,overview.get('title'),kind,urls,fields,details.get('notesPlain',''),source)
            item['tags']=overview.get('tags',[])
            # 1PUX 文档附件与附属文件均按实际文件 ID 解析，不执行解包到磁盘。
            references=list(details.get('files',[]))
            for section in details.get('sections',[]):
                for field in section.get('fields',[]):
                    ref=field.get('value',{}).get('file')
                    if isinstance(ref,dict): references.append(ref)
            if details.get('documentAttributes'): references.append(details['documentAttributes'])
            for attachment in references:
                file_id=attachment.get('documentId') or attachment.get('fileId')
                name=attachment.get('fileName') or attachment.get('name') or str(file_id)
                if not file_id or '/' in str(file_id) or '/' in name: raise ConnectorError('附件身份或名称无效。')
                candidates=[f'files/{file_id}',f'files/{file_id}__{name}',f'files/{file_id}___{name}']
                actual=next((p for p in candidates if p in archive.namelist()),None)
                if not actual: raise ConnectorError('来源引用的附件缺失，已中止导入。')
                content=archive.read(actual)
                if len(content)>MAX_ATTACHMENT: raise ConnectorError('来源附件超过当前 10 MB 上限，已中止导入。')
                item['attachments'].append({'name':name,'mediaType':'application/octet-stream','data':encode(content)})
            items.append(item)
        return {'schema':1,'source':'1password:'+vault_id,'items':items,'warnings':sorted(set(warnings))}

def keepass(path,keyfile=None):
    from pykeepass import PyKeePass
    return PyKeePass(path,password=secret('PBSYNC_SOURCE_PASSWORD'),keyfile=keyfile)

def read_kdbx(path,keyfile=None):
    from lxml import etree
    baseline=digest(path)
    database=keepass(path,keyfile);items=[]
    recycle=database.recyclebin_group
    for entry in database.entries:
        # 历史和回收站不应作为活动密码重新导入，包括回收站的子目录。
        if entry.is_a_history_entry or (recycle is not None and recycle._element in entry._element.iterancestors()): continue
        fields={'username':entry.username or '', 'password':entry.password or ''}
        for name,value in entry.custom_properties.items(): fields['totp' if name=='otp' else 'custom.'+name]=value or ''
        item=base_item(entry.uuid,entry.title,'login',[entry.url] if entry.url else [],fields,entry.notes,{'entryXML':etree.tostring(entry._element,encoding='unicode'),'groupPath':entry.group.path})
        item['tags']=entry.tags or []
        for attachment in entry.attachments:
            content=attachment.data
            if len(content)>MAX_ATTACHMENT: raise ConnectorError('KDBX 附件超过当前 10 MB 上限。')
            item['attachments'].append({'name':attachment.filename,'mediaType':'application/octet-stream','data':encode(content)})
        items.append(item)
    if digest(path)!=baseline: raise ConnectorError('读取期间来源库已变化，请重试。')
    return {'schema':1,'source':'keepass:'+str(database.root_group.uuid),'items':items,'warnings':['KDBX 原始条目和历史已保留；自动输入、插件与未知字段的行为不由导入成功证明。'],'baseline':baseline}

def write_kdbx(path,patch_path,expected,keyfile=None,apply=False):
    from pykeepass import PyKeePass
    # 外部客户端不保证遵守同一锁；检查后替换不能充当原子版本提交。
    if apply:
        raise ConnectorError('KDBX 原地写回已禁用：外部客户端可能并发保存。请生成并核对候选文件，再在来源客户端合并。')
    original=Path(path)
    if original.is_symlink(): raise ConnectorError('不对符号链接原地写回。')
    if digest(original)!=expected: raise ConnectorError('KDBX 来源已变化，必须重新读取和合并。')
    patches=json.load(sys.stdin) if str(patch_path)=='-' else json.loads(Path(patch_path).read_text())
    if not isinstance(patches,list): raise ConnectorError('写回补丁必须是条目数组。')
    database=keepass(original,keyfile)
    before={str(e.uuid):{'custom':dict(e.custom_properties),'attachments':[(a.filename,hashlib.sha256(a.data).hexdigest()) for a in e.attachments]} for e in database.entries if not e.is_a_history_entry}
    changed=[]
    for patch in patches:
        if not isinstance(patch,dict) or not set(patch)<= {'sourceID','title','username','password','url','notes'}: raise ConnectorError('写回字段范围未获支持。')
        entry=database.find_entries(uuid=uuid.UUID(patch['sourceID']),first=True)
        if entry is None: raise ConnectorError('写回目标不存在，拒绝猜测或批量新增。')
        entry.save_history()
        for field in ('title','username','password','url','notes'):
            if field in patch:
                if not isinstance(patch[field],str): raise ConnectorError('写回字段必须为字符串。')
                setattr(entry,field,patch[field])
        changed.append(str(entry.uuid))
    candidate=original.with_name(original.stem+'.pbsync-candidate-'+uuid.uuid4().hex+'.kdbx')
    # 3.1 在密文 XML 中也保存头部摘要。PyKeePass 4.2.0 轮换种子时未同步这个字段。
    # 沿用依赖自己的种子轮换与序列化，并用同一份头部生成摘要和密文。
    stream=candidate.open('x+b')
    try:
        with stream:
            os.fchmod(stream.fileno(),0o600)
            if database.version == (3,1):
                from pykeepass.kdbx_parsing import KDBX
                from pykeepass.kdbx_parsing.common import rotate_seeds
                from lxml import etree
                meta=database.tree.find('Meta')
                if meta is None: raise ConnectorError('缺少 KDBX 元数据。')
                field=meta.find('HeaderHash')
                if field is None: field=etree.SubElement(meta,'HeaderHash')
                elif field.text!=encode(hashlib.sha256(database.kdbx.header.data).digest()):
                    raise ConnectorError('来源 KDBX 头部摘要校验失败。')
                rotate_seeds(database.kdbx,rotate_kdf_salt=True)
                header=KDBX.header.subcon.build(database.kdbx.header)
                field.text=encode(hashlib.sha256(header).digest())
                KDBX.build_stream(database.kdbx,stream,password=database.password,keyfile=database.keyfile,transformed_key=None,decrypt=True)
            else:
                database.save(stream)
    except Exception:
        if candidate.exists(): candidate.unlink()
        raise
    checked=PyKeePass(candidate,password=secret('PBSYNC_SOURCE_PASSWORD'),keyfile=keyfile)
    after={str(e.uuid):{'custom':dict(e.custom_properties),'attachments':[(a.filename,hashlib.sha256(a.data).hexdigest()) for a in e.attachments]} for e in checked.entries if not e.is_a_history_entry}
    if before!=after: raise ConnectorError('未知字段或附件回读不一致，原文件未修改。')
    for patch in patches:
        entry=checked.find_entries(uuid=uuid.UUID(patch['sourceID']),first=True)
        if any(getattr(entry,k)!=v for k,v in patch.items() if k!='sourceID'): raise ConnectorError('写回候选回读不一致，原文件未修改。')
    return {'changed':len(changed),'candidate':str(candidate),'applied':False,'canApply':False,
            'expectedSHA256':expected,'sourceChanged':digest(original)!=expected,
            'reason':'候选已回读校验，未替换来源文件；请在来源客户端核对与合并。'}


def op_run(arguments,input_data=None):
    executable=os.environ.get('PBSYNC_OP_EXECUTABLE') or shutil.which('op')
    if not executable: raise ConnectorError('未安装 1Password CLI。')
    environment=os.environ.copy();environment['OP_FORMAT']='json'
    if environment.get('PBSYNC_OP_ACCOUNT'):
        arguments=[*arguments,'--account',environment['PBSYNC_OP_ACCOUNT']]
    try: completed=subprocess.run([executable,*arguments],input=input_data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=45,env=environment)
    except subprocess.TimeoutExpired: raise ConnectorError('来源授权或操作超时，请在来源 App 中核对。')
    if completed.returncode: raise ConnectorError('1Password 需要授权或操作被拒绝；没有重复尝试。')
    if len(completed.stdout)>MAX_INPUT: raise ConnectorError('来源响应超过大小上限。')
    return json.loads(completed.stdout)

def op_read(vault):
    summaries=op_run(['item','list','--vault',vault,'--format','json']);items=[]
    for summary in summaries:
        source=op_run(['item','get',summary['id'],'--vault',vault,'--format','json'])
        if source.get('vault',{}).get('id')!=vault: raise ConnectorError('来源返回了未授权的保险库。')
        fields={}
        for field in source.get('fields',[]):
            designation=field.get('purpose','').lower()
            key=designation if designation in ('username','password') else 'custom.'+str(field.get('id','field'))
            fields[key]=str(field.get('value',''))
        item=base_item(source['id'],source.get('title'), 'login' if source.get('category')=='LOGIN' else 'note',[u['href'] for u in source.get('urls',[]) if u.get('href')],fields,raw=source)
        if source.get('files'): raise ConnectorError('此来源含附件；CLI 持续连接尚不能保真，请改用 1PUX 完整迁移。')
        items.append(item)
    return {'schema':1,'source':'1password:'+vault,'items':items,'warnings':['桌面 CLI 连接受来源授权约束；不代表 iPhone 独立访问该来源。']}

def op_write(vault,item_id,patch_path,expected,apply=False):
    source=op_run(['item','get',item_id,'--vault',vault,'--format','json'])
    if str(source.get('version'))!=expected or source.get('vault',{}).get('id')!=vault: raise ConnectorError('来源版本或保险库不匹配。')
    if source.get('files'): raise ConnectorError('含附件的条目暂不写回。')
    patch=json.loads(Path(patch_path).read_text());candidate=copy.deepcopy(source)
    if not set(patch)<= {'title','username','password','notes'}: raise ConnectorError('未支持的 1Password 写回字段。')
    if 'title' in patch:candidate['title']=patch['title']
    for name in ('username','password','notes'):
        if name not in patch:continue
        matches=[f for f in candidate.get('fields',[]) if f.get('purpose','').lower()==name or (name=='notes' and f.get('id')=='notesPlain')]
        if len(matches)!=1: raise ConnectorError('来源字段映射不唯一，拒绝写回。')
        matches[0]['value']=patch[name]
    # CLI 未提供可确认的原子版本条件提交；产生预览，禁止把先读后写当 CAS。
    if apply: raise ConnectorError('当前 CLI 路径缺少可验证的原子版本条件，已拒绝自动覆盖；需在来源中处理候选。')
    return {'candidate':candidate,'canApply':False,'reason':'来源 CLI 原子版本条件尚未验证，持续自动写回保持阻塞。'}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['1pux','kdbx-read','kdbx-write','op-read','op-write'])
    parser.add_argument('--input');parser.add_argument('--vault');parser.add_argument('--list-vaults',action='store_true')
    parser.add_argument('--keyfile');parser.add_argument('--patch');parser.add_argument('--expected');parser.add_argument('--item');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--request-stdin',action='store_true')
    args=parser.parse_args()
    if args.request_stdin:
        request=json.load(sys.stdin)
        if 'password' in request: os.environ['PBSYNC_SOURCE_PASSWORD']=request['password']
        if 'patch' in request:
            import io
            sys.stdin=io.StringIO(json.dumps(request['patch']));args.patch='-' 
    if args.command=='1pux':result=onepux(args.input,args.vault,args.list_vaults)
    elif args.command=='kdbx-read':result=read_kdbx(args.input,args.keyfile)
    elif args.command=='kdbx-write':result=write_kdbx(args.input,args.patch,args.expected,args.keyfile,args.apply)
    elif args.command=='op-read':result=op_read(args.vault)
    else:result=op_write(args.vault,args.item,args.patch,args.expected,args.apply)
    json.dump(result,sys.stdout,ensure_ascii=False,separators=(',',':'))

if __name__=='__main__':
    try:main()
    except ConnectorError as error:print(str(error),file=sys.stderr);sys.exit(2)
    except Exception:print('连接器操作失败，未输出来源内容；请核对格式、解锁材料及来源版本。',file=sys.stderr);sys.exit(2)
