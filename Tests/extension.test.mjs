import test from 'node:test';import assert from 'node:assert/strict';import {webcrypto} from 'node:crypto';
import {originOf,sameOrigin,delta,canonical,validateRemote} from '../extensions/browser/policy.mjs';
import {encrypt,decrypt} from '../extensions/browser/crypto.mjs';
import {BookmarkSync} from '../extensions/browser/bookmarks.mjs';
if(!globalThis.crypto)globalThis.crypto=webcrypto;
test('HTTPS 精确匹配拒绝伪装、明文和用户信息',()=>{assert.equal(originOf('http://example.com'),null);assert.equal(originOf('https://user@example.com'),null);assert.ok(sameOrigin('https://example.com/a','https://example.com:443/b'));assert.ok(!sameOrigin('https://example.com','https://example.com.evil.test'));assert.ok(!sameOrigin('https://example.com','https://example.com:444'));});
test('只传播相对基线的真实变化与显式删除',()=>{const a={id:'a',kind:'bookmark',title:'A',urls:['https://example.com'],order:0};const b={...a,id:'b',title:'B'};const baseline={a:canonical(a),b:canonical(b)};assert.deepEqual(delta([a],baseline),{items:[],deleted:['b']});assert.deepEqual(delta([a,b],baseline),{items:[],deleted:[]});});
test('加密原生消息校验身份、方向和篡改',async()=>{const token=Buffer.alloc(32,7).toString('base64'),request=await encrypt({command:'test'},token),response=await encrypt({ok:true},token,request);assert.deepEqual(await decrypt(response,token,request),{ok:true});await assert.rejects(decrypt(request,token,request));await assert.rejects(decrypt({...response,id:crypto.randomUUID()},token,request));const bytes=Buffer.from(response.sealed,'base64');bytes[20]^=1;await assert.rejects(decrypt({...response,sealed:bytes.toString('base64')},token,request));});
test('远端重复身份与非法条目被拒绝',()=>{const item={id:crypto.randomUUID(),kind:'bookmark',title:'A',urls:['https://example.com'],order:0};assert.throws(()=>validateRemote([item,{...item}],[]));assert.throws(()=>validateRemote([{...item,kind:'login'}],[]));});
function mock(){
  let next=10;const saved={},nodes=new Map([['0',{id:'0',title:'',children:[]}],['1',{id:'1',parentId:'0',title:'书签栏',index:0}],['2',{id:'2',parentId:'0',title:'其他书签',index:1}],['3',{id:'3',parentId:'1',title:'本地收藏',url:'https://example.com/local',index:0}]]);
  const children=id=>[...nodes.values()].filter(n=>n.parentId===id).sort((a,b)=>a.index-b.index);
  const tree=id=>({...nodes.get(id),...(!nodes.get(id).url?{children:children(id).map(n=>tree(n.id))}:{})});
  const api={storage:{local:{async get(keys){return Object.fromEntries((Array.isArray(keys)?keys:[keys]).map(k=>[k,saved[k]]));},async set(values){Object.assign(saved,structuredClone(values));},async remove(keys){for(const key of keys)delete saved[key];}}},bookmarks:{
    async getTree(){return [tree('0')];},async get(id){if(!nodes.has(id))throw Error();return [{...nodes.get(id)}];},async getChildren(id){return children(id).map(n=>({...n}));},
    async create(value){const node={...value,id:String(next++),index:children(value.parentId).length};nodes.set(node.id,node);return {...node};},
    async update(id,value){Object.assign(nodes.get(id),value);return {...nodes.get(id)};},async move(id,value){nodes.get(id).parentId=value.parentId;nodes.get(id).index=value.index;return {...nodes.get(id)};},
    async remove(id){if(children(id).length)throw Error('nonempty');nodes.delete(id);}
  }};return {api,saved,nodes};
}
test('首次未确认不修改浏览器，确认后合并且保留原收藏',async()=>{const {api,saved,nodes}=mock();const remote=new Map();const native=async request=>{if(request.command==='bookmarks.apply'){for(const item of request.items)remote.set(item.id,item);for(const id of request.deleted)remote.delete(id);}return {items:[...remote.values()],deleted:[]};};const sync=new BookmarkSync(api,native);await assert.rejects(sync.sync(),/首次合并/);assert.equal(nodes.size,4);await sync.sync({firstConfirmed:true});assert.ok(saved.bookmarkRecoverySnapshot);assert.ok(saved.bookmarkConnected);assert.equal([...nodes.values()].filter(n=>n.url).length,1);await sync.sync();assert.equal([...nodes.values()].filter(n=>n.url).length,1);});

import {committedCandidate,canAutoSave} from '../extensions/browser/save-policy.mjs';
test('只有同标签首个新文档的成功响应允许自动保存',()=>{
  const successURL='https://example.com/signed-in', time=Date.now();
  const pending={automatic:true,url:'https://example.com/login',successURL,documentId:'original',username:'synthetic',time,tabID:9};
  const event={url:successURL,frameId:0,documentId:'landing',transitionType:'form_submit'};
  const sender={tab:{id:9},...event};
  const evidence={navigation:'navigate',status:200,loginFormAbsent:true};
  const committed=committedCandidate(pending,event);
  assert.ok(canAutoSave(committed,sender,evidence,time));
  for(const override of [{status:401},{loginFormAbsent:false},{navigation:'back_forward'}])
    assert.equal(canAutoSave(committed,sender,{...evidence,...override},time),false);
  for(const override of [{tab:{id:10}},{url:'https://example.com/error'},{documentId:'late'},{frameId:2}])
    assert.equal(canAutoSave(committed,{...sender,...override},evidence,time),false);
  assert.equal(canAutoSave(committed,sender,evidence,time+120001),false);
  for (const transitionType of ['link','typed','reload','auto_bookmark'])
    assert.equal(committedCandidate(pending,{...event,transitionType}).automatic,false);
  const failed=committedCandidate(pending,{...event,url:pending.url});
  assert.equal(canAutoSave(committedCandidate(failed,event),sender,evidence,time),false);
  assert.equal(canAutoSave(committedCandidate(committed,event),sender,evidence,time),false);
});

test('浏览器在写回末尾新建的收藏会进入下一轮上传',async()=>{
  const {api,nodes}=mock(),items=new Map();
  const native=async req=>{
    for (const item of req.items??[]) items.set(item.id.toLowerCase(),structuredClone(item));
    return {items:[...items.values()].map(x=>({...x,id:x.id.toUpperCase()})),deleted:[]};
  };
  const sync=new BookmarkSync(api,native);
  const getTree=api.bookmarks.getTree;
  let reads=0;
  api.bookmarks.getTree=async()=>{
    if(++reads===3) nodes.set('88',{id:'88',parentId:'1',title:'同步中新增',url:'https://example.invalid/race',index:1});
    return getTree();
  };
  await sync.sync({firstConfirmed:true});
  assert.equal([...items.values()].filter(x=>x.title==='同步中新增').length,0);
  await sync.sync();
  assert.equal([...items.values()].filter(x=>x.title==='同步中新增').length,1);
  await sync.sync();
  assert.equal([...nodes.values()].filter(x=>x.title==='同步中新增').length,1);
});

test('意外退出丢失的书签从远端补回，只有收到删除事件才传播删除', async () => {
  const {api,nodes,saved}=mock(), remote=new Map();
  const native=async ({items=[],deleted=[]})=>{
    for(const item of items)remote.set(item.id,item);
    for(const id of deleted)remote.delete(id);
    return {items:[...remote.values()],deleted};
  };
  nodes.set('4',{id:'4',parentId:'1',title:'已同步的标题',url:'https://example.invalid/keep',index:1});
  const sync=new BookmarkSync(api,native);
  await sync.sync({firstConfirmed:true});
  const uuid=saved.bookmarkMapping['3'];
  nodes.delete('3');
  nodes.get('4').title='旧磁盘标题';
  await new BookmarkSync(api,native).sync();
  assert.ok(remote.has(uuid));
  assert.equal(remote.get(saved.bookmarkMapping['4']).title,'已同步的标题');
  const restored=[...nodes.values()].find(n=>n.url==='https://example.com/local');
  assert.ok(restored);
  await sync.recordRemoval(restored.id,{node:restored});
  nodes.delete(restored.id);
  await new BookmarkSync(api,native).sync();
  assert.equal(remote.has(uuid),false);
  assert.equal(saved['bookmarkRemoval:'+uuid],undefined);
});

test('两个日常配置首次合并时保留同目录重复数量并复用已对齐条目', async () => {
  const space = new Map();
  const native = async ({items=[]}) => {
    for (const item of items) space.set(item.id,structuredClone(item));
    return {items:structuredClone([...space.values()]),deleted:[]};
  };
  for (const id of ['100','200']) {
    const {api,nodes}=mock();
    nodes.set(id,{id,parentId:'1',title:'文件夹',index:1});
    for (const n of ['1','2']) {
      const child=id+n;
      nodes.set(child,{id:child,parentId:id,title:'同一网址',url:'https://example.invalid/a',index:Number(n)-1});
    }
    await new BookmarkSync(api,native).sync({firstConfirmed:true});
    assert.equal([...nodes.values()].filter(item=>item.url).length,3);
    assert.equal([...space.values()].filter(item=>item.kind==='bookmark').length,3);
    assert.equal([...space.values()].filter(item=>item.title==='文件夹').length,1);
  }
});

test('其他浏览器的空内置根不会生成第二个同名空目录', async () => {
  const {api,nodes}=mock(), remote=new Map();
  nodes.set('8',{id:'8',parentId:'2',title:'移动设备上的书签',index:0});
  const native=async ({items=[]})=>{
    for(const item of items)remote.set(item.id,structuredClone(item));
    return {items:structuredClone([...remote.values()]),deleted:[]};
  };
  const sync=new BookmarkSync(api,native);
  await sync.sync({firstConfirmed:true});
  const before=await api.bookmarks.getTree();
  remote.set('62b3a4bb-4826-4856-8fb2-cff155b7d803',{
    id:'62b3a4bb-4826-4856-8fb2-cff155b7d803',kind:'folder',title:'移动设备上的书签',
    parentID:null,order:3,urls:[],fields:{browserRoot:'mobile'}
  });
  for(let i=0;i<3;i++)await sync.sync();
  assert.deepEqual(await api.bookmarks.getTree(),before);
  // 根目录一旦有真实内容仍须接收，不能为了消除空目录而漏同步。
  remote.set('53140aad-1e80-4311-8eb8-155273e77d11',{
    id:'53140aad-1e80-4311-8eb8-155273e77d11',kind:'bookmark',title:'手机新增',
    parentID:'62b3a4bb-4826-4856-8fb2-cff155b7d803',order:0,urls:['https://example.invalid/mobile']
  });
  await sync.sync();
  assert.equal([...nodes.values()].filter(n=>n.url==='https://example.invalid/mobile').length,1);
  assert.ok(nodes.has('8'),'原有同名目录必须保留');
});

test('首次重连不会把普通同名目录匹配为旧版错误挂载的内置根', async () => {
  const {api,nodes,saved}=mock(),remote=new Map();
  const mobile='62b3a4bb-4826-4856-8fb2-cff155b7d803';
  nodes.set('8',{id:'8',parentId:'2',title:'移动设备上的书签',index:0});
  // 旧版跨浏览器写回曾把内置根挂在 other 下，不能仅凭标题和父目录认领它。
  remote.set(mobile,{id:mobile,kind:'folder',title:'移动设备上的书签',
    parentID:'62b3a4bb-4826-4856-8fb2-cff155b7d802',order:0,urls:[],fields:{}});
  const native=async ({items=[]})=>{
    for(const item of items)remote.set(item.id,structuredClone(item));
    return {items:structuredClone([...remote.values()]),deleted:[]};
  };
  await new BookmarkSync(api,native).sync({firstConfirmed:true});
  assert.notEqual(saved.bookmarkMapping['8'],mobile);
  assert.equal([...nodes.values()].filter(n=>n.title==='移动设备上的书签').length,1);
  assert.ok(remote.has(saved.bookmarkMapping['8']));
});

test('远端整棵目录删除在同一轮按子到父完成，并保留并发新增内容', async () => {
  for(const concurrent of [false,true]) {
    const {api,nodes,saved}=mock(),remote=new Map();let deleted=[];
    nodes.set('8',{id:'8',parentId:'2',title:'测试根',index:0});
    nodes.set('9',{id:'9',parentId:'8',title:'子目录',index:0});
    nodes.set('7',{id:'7',parentId:'9',title:'测试网址',url:'https://example.invalid/delete',index:0});
    const native=async ({items=[]})=>{
      for(const item of items)if(!deleted.includes(item.id))remote.set(item.id,structuredClone(item));
      return {items:structuredClone([...remote.values()]),deleted};
    };
    const sync=new BookmarkSync(api,native);await sync.sync({firstConfirmed:true});
    deleted=['8','9','7'].map(id=>saved.bookmarkMapping[id]);
    for(const id of deleted)remote.delete(id);
    if(concurrent)nodes.set('6',{id:'6',parentId:'9',title:'用户并发新增',url:'https://example.invalid/keep',index:1});
    await sync.sync();
    assert.equal(nodes.has('7'),false);
    assert.equal(nodes.has('8'),concurrent);
    assert.equal(nodes.has('9'),concurrent);
    assert.ok(nodes.has('3'),'原有网址必须保留');
    if(concurrent)assert.ok(nodes.has('6'));
  }
});
