#!/usr/bin/env python3
"""为指定测试浏览器安装本机通信清单。需明确浏览器及扩展 ID，不接触收藏夹数据。"""
import argparse,json,os,re,shlex
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--browser',choices=['chrome','edge','firefox','aegis'],required=True)
parser.add_argument('--extension-id',required=True);parser.add_argument('--profile',type=Path,required=True)
parser.add_argument('--manifest-dir',type=Path)
parser.add_argument('--bookmark-profile',type=Path,help='日常浏览器配置目录，用于核对书签标识；省略时由扩展写回。')
args=parser.parse_args()
if args.browser!='firefox' and not re.fullmatch('[a-p]{32}',args.extension_id):raise SystemExit('Chromium 扩展 ID 格式无效')
if args.browser=='firefox' and not re.fullmatch(r'[A-Za-z0-9@._{}-]{3,128}',args.extension_id):raise SystemExit('Firefox 扩展 ID 格式无效')
profile=args.profile.resolve()
caller=args.extension_id if args.browser=='firefox' else 'chrome-extension://'+args.extension_id+'/'
launcher=profile/('native-host-'+args.browser+'.sh')
paths={'chrome':'Google/Chrome/NativeMessagingHosts','edge':'Microsoft Edge/NativeMessagingHosts','firefox':'Mozilla/NativeMessagingHosts'}
if args.browser=='aegis' and not args.manifest_dir:raise SystemExit('Aegis 需明确 --manifest-dir，不能猜测其他项目配置路径')
directory=args.manifest_dir or Path.home()/'Library/Application Support'/paths[args.browser]
directory.mkdir(parents=True,exist_ok=True)
manifest={'name':'com.gcsa.pbsync','description':'PBsync 加密本机通信','path':str(launcher),'type':'stdio'}
manifest['allowed_extensions' if args.browser=='firefox' else 'allowed_origins']=[caller]
path=directory/'com.gcsa.pbsync.json'
if path.exists() and json.loads(path.read_text())!=manifest:raise SystemExit('已有不同清单，未覆盖。请另选验收目录或先保留现有配置。')
profile.mkdir(parents=True,exist_ok=True)
allowed_path=profile/'allowed-native-callers.json'
allowed=json.loads(allowed_path.read_text()) if allowed_path.exists() else []
if caller not in allowed:allowed.append(caller)
allowed_path.write_text(json.dumps(allowed));os.chmod(allowed_path,0o600)
argument='${2:-}' if args.browser=='firefox' else '${1:-}'
binding = ' --bookmark-profile '+shlex.quote(str(args.bookmark_profile.resolve())) if args.bookmark_profile and args.browser!='firefox' else ''
launcher.write_text('#!/bin/sh\nexec '+shlex.quote(str(ROOT/'build/pbsync'))+' native-host --profile '+shlex.quote(str(profile))+binding+' --caller "'+argument+'"\n')
os.chmod(launcher,0o700)
path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n');os.chmod(path,0o600)
print(path)
