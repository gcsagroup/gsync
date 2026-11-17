import test from 'node:test';
import assert from 'node:assert/strict';
import {NativeWrites} from '../extensions/browser/native-writes.mjs';

const original = {id:'8',title:'原有',url:'https://example.invalid/old',parentId:'1'};
const item = {id:'用于测试的书签身份',kind:'bookmark',title:'新增',urls:['https://example.invalid/new']};
function fixture(outcome) {
  const nodes=[{...original}], store={}, calls=[];
  const api={
    storage:{local:{async get(key){return {[key]:store[key]};},async set(obj){Object.assign(store,structuredClone(obj));},async remove(key){delete store[key];}}},
    bookmarks:{async getChildren(){return structuredClone(nodes);}},
    runtime:{async sendNativeMessage(_,message){
      calls.push(message);
      if (message.nativeBookmarkRoute!=='write') return {outcome:'available'};
      return {outcome:await outcome(nodes,message.request)};
    }}
  };
  return {writer:new NativeWrites(api),nodes,store,calls};
}
test('空目录、文件夹和末尾插入直接交给扩展',async()=>{
  const f=fixture(()=>assert.fail());
  assert.equal(await f.writer.create('1',0,item,[]),null);
  assert.equal(await f.writer.create('1',1,item,f.nodes),null);
  assert.equal(await f.writer.create('1',0,item,[{id:'9',title:'目录'}]),null);
  assert.equal(f.calls.length,0);
});
test('原生新增回读浏览器身份；未发送写入时才返回备用通道',async()=>{
  const f=fixture(nodes=>{nodes.unshift({id:'9',title:item.title,url:item.urls[0]});return 'sent';});
  assert.equal((await f.writer.create('1',0,item,f.nodes)).id,'9');
  assert.equal(f.store.bookmarkMapping['9'],item.id);
  const unavailable=fixture(()=>'fallback');
  assert.equal(await unavailable.writer.create('1',0,item,unavailable.nodes),null);
  assert.equal(unavailable.store.pendingNativeCreate,undefined);
});
test('原生新增丢失回执后先恢复映射，绝不再次创建',async()=>{
  const f=fixture(()=>{throw Error('回执丢失');});
  await assert.rejects(f.writer.create('1',0,item,f.nodes));
  await assert.rejects(f.writer.recoverCreate(),/暂停重复写入/);
  f.nodes.push({id:'10',title:item.title,url:item.urls[0]});
  assert.equal((await f.writer.recoverCreate()).id,'10');
  assert.equal(f.calls.filter(x=>x.nativeBookmarkRoute==='write').length,1);
});
test('原生改名从同一浏览器节点回读，删除直接交给浏览器 API',async()=>{
  const f=fixture((nodes,request)=>{if(request.operation==='rename')nodes[0].title=request.title;else nodes.splice(0,1);return 'sent';});
  assert.equal(await f.writer.existing('rename',{...original},{title:'已改',urls:[original.url]}),true);
  const calls=f.calls.length;
  assert.equal(await f.writer.existing('delete',{...f.nodes[0]},{}),false);
  assert.equal(f.calls.length,calls,'删除不得进入可能等待的原生宿主');
  assert.equal(f.nodes.length,1,'原生路由没有发送删除');
});
