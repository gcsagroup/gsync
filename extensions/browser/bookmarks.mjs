import {canonical,delta,validateRemote} from './policy.mjs';
const ROOTS={toolbar:'62b3a4bb-4826-4856-8fb2-cff155b7d801',other:'62b3a4bb-4826-4856-8fb2-cff155b7d802',mobile:'62b3a4bb-4826-4856-8fb2-cff155b7d803',menu:'62b3a4bb-4826-4856-8fb2-cff155b7d804'};
function rootKind(node,index) {
  if (node.folderType==='bookmarks-bar') return 'toolbar';
  if (['other','mobile'].includes(node.folderType)) return node.folderType;
  if (node.id==='1'||node.id==='toolbar_____') return 'toolbar';
  if (node.id==='2'||node.id==='unfiled_____') return 'other';
  if (node.id==='3'||node.id==='mobile______') return 'mobile';
  if (node.id==='menu________') return 'menu';
  return index===0?'toolbar':'other';
}
export class BookmarkSync {
  constructor(api,native,writer=null) {this.api=api;this.native=native;this.writer=writer;this.running=false;}
  async snapshot() {
    const saved=await this.api.storage.local.get(['bookmarkMapping','bookmarkBaseline','bookmarkConnected']);
    const mapping=saved.bookmarkMapping??{}, trees=await this.api.bookmarks.getTree(), roots=trees[0]?.children??[];
    const nodes=[], local={}, rootMap={};
    const walk=(node,parentID,index,root=false,rootID=null)=>{
      if(node.unmodifiable || node.type==='separator') return;
      const id=rootID??mapping[node.id]??crypto.randomUUID();mapping[node.id]=id;local[id]=node.id;
      const item={id,kind:node.url?'bookmark':'folder',title:node.title??'',parentID:parentID??null,order:index,urls:node.url?[node.url]:[],fields:{},notes:'',tags:[],attachments:[],sourceData:{}};
      if(root) {item.fields.browserRoot=Object.keys(ROOTS).find(key=>ROOTS[key]===id);rootMap[id]=node.id;}
      nodes.push(item);(node.children??[]).forEach((child,i)=>walk(child,id,i));
    };
    roots.forEach((root,i)=>walk(root,null,i,true,ROOTS[rootKind(root,i)]));
    await this.api.storage.local.set({bookmarkMapping:mapping});
    return {nodes,mapping,local,rootMap,baseline:saved.bookmarkBaseline??{},connected:saved.bookmarkConnected===true};
  }
  // 书签树与扩展存储分别落盘。浏览器异常退出后，两者缺一条记录不能作为删除凭据。
  async recordRemoval(browserID, info) {
    const {bookmarkConnected,bookmarkMapping={}} = await this.api.storage.local.get(['bookmarkConnected','bookmarkMapping']);
    if (!bookmarkConnected) return;
    const records = {};
    const visit = (id, node) => {
      const uuid = bookmarkMapping[id];
      if (uuid) records['bookmarkRemoval:'+uuid] = true;
      for (const child of node?.children ?? []) visit(child.id, child);
    };
    visit(browserID, info.node);
    if (Object.keys(records).length) await this.api.storage.local.set(records);
  }
  async confirmedDelta(nodes, baseline) {
    const change = delta(nodes, baseline);
    if (change.deleted.length) {
      const records = await this.api.storage.local.get(change.deleted.map(id => 'bookmarkRemoval:'+id));
      const confirmed = change.deleted.filter(id => records['bookmarkRemoval:'+id] === true);
      if (confirmed.length < change.deleted.length) {
        // 缺少删除事件时，整棵树可能来自较早的磁盘快照。避免把旧标题与旧顺序写回。
        // 保留此次本地状态以供核对；新建条目与已确认的删除仍可上传。
        await this.api.storage.local.set({bookmarkIncompleteSnapshot:nodes});
        change.items = change.items.filter(item => !Object.hasOwn(baseline,item.id));
      }
      change.deleted = confirmed;
    }
    // 连同旧字段发送，App 只提交真正改变的字段，保留另一端更新的标题或备注。
    change.baselines = Object.fromEntries(change.items.flatMap(item => {
      const value = baseline[item.id.toLowerCase()];
      return typeof value === 'string' ? [[item.id.toLowerCase(), JSON.parse(value)]] : [];
    }));
    return change;
  }
  // 首次接入时，已通过文件交换对齐的书签可以共用身份。相同条目按出现次数逐个匹配。
  async matchFirstSnapshot(snapshot) {
    const remote = await this.native({command:'bookmarks.pull'});
    validateRemote(remote.items, remote.deleted);
    const signature = (item, parent) => JSON.stringify([parent,item.kind,item.title,item.urls?.[0] ?? '']);
    const reserved = new Set(snapshot.nodes.map(item => item.id));
    const remoteIDs = new Set(remote.items.map(item => item.id));
    const candidates = new Map();
    for (const item of [...remote.items].sort((a,b) => b.order-a.order || b.id.localeCompare(a.id))) {
      // 内置根即使被旧版写回到普通父目录下，也不能认领用户的同名目录。
      if (reserved.has(item.id) || Object.values(ROOTS).includes(item.id) || !item.parentID) continue;
      const key = signature(item,item.parentID);
      if (!candidates.has(key)) candidates.set(key,[]);
      candidates.get(key).push(item.id);
    }
    const parents = new Map();
    for (const item of snapshot.nodes) {
      if (!item.parentID) continue;
      const browserID = snapshot.local[item.id];
      item.parentID = parents.get(item.parentID) ?? item.parentID;
      if (remoteIDs.has(item.id)) continue;
      const match = candidates.get(signature(item,item.parentID))?.pop();
      if (!match) continue;
      parents.set(item.id,match);
      item.id = match;
      snapshot.mapping[browserID] = match;
    }
    await this.api.storage.local.set({bookmarkMapping:snapshot.mapping});
  }
  async preview() {
    const local=await this.snapshot(), remote=await this.native({command:'bookmarks.pull'});
    return {localCount:local.nodes.filter(n=>n.kind==='bookmark').length,remoteCount:remote.items.filter(n=>n.kind==='bookmark').length,connected:local.connected};
  }
  async sync({firstConfirmed=false}={}) {
    if(this.running) return {busy:true};this.running=true;
    try {
      await this.writer?.recoverCreate();
      const before=await this.snapshot();if(!before.connected&&!firstConfirmed) throw new Error('首次合并需要在弹窗预览并确认');
      // 保存浏览器完整合并前快照，未获得确认时绝不写回。
      if(!before.connected) {
        const saved = await this.api.storage.local.get('bookmarkRecoverySnapshot');
        if (!saved.bookmarkRecoverySnapshot) await this.api.storage.local.set({bookmarkRecoverySnapshot:before.nodes});
        await this.matchFirstSnapshot(before);
      }
      const change=await this.confirmedDelta(before.nodes,before.baseline);
      const remote=await this.native({command:'bookmarks.apply',...change});
      validateRemote(remote.items,remote.deleted);
      // 下载期间的用户编辑先补交，再次读取，避免用过期快照覆盖。
      const now=await this.snapshot(), arrived=await this.confirmedDelta(now.nodes,Object.fromEntries(before.nodes.map(n=>[n.id,canonical(n)])));
      if(arrived.items.length||arrived.deleted.length) {
        const latest=await this.native({command:'bookmarks.apply',...arrived});remote.items=latest.items;remote.deleted=latest.deleted;
        validateRemote(remote.items,remote.deleted);
      }
      const expected = {};
      const mapping=now.mapping, local=now.local, roots=now.rootMap;
      const parentIDs = new Set(remote.items.map(item=>item.parentID));
      // 未知浏览器根映射到“其他书签”中的普通目录，保留全部内容。
      let remaining=[...remote.items].sort((a,b)=>a.order-b.order||a.id.localeCompare(b.id)),passes=0;
      while(remaining.length&&passes++<=64) {
        const next=[];
        for(const item of remaining) {
          if(roots[item.id]) {local[item.id]=roots[item.id];expected[item.id]=canonical(now.nodes.find(n=>n.id===item.id));continue;}
          // Firefox 的空“移动书签”等内置根不是用户新增目录。
          // 当前浏览器没有这个根且尚未接收过内容时，不额外生成同名空目录。
          // 已有映射或真实子项仍正常同步，保留用户原有的普通同名目录。
          if(Object.values(ROOTS).includes(item.id) && !local[item.id] && !parentIDs.has(item.id)) continue;
          const parentID=item.parentID?(local[item.parentID]):Object.values(roots)[1]??Object.values(roots)[0];
          if(!parentID){next.push(item);continue;}
          const parentUUID = mapping[parentID] ?? null;
          expected[item.id] = canonical({...item,parentID:parentUUID});
          let browserID=local[item.id];
          if(browserID) {
            let actual;try{actual=(await this.api.bookmarks.get(browserID))[0];}catch{delete local[item.id];browserID=null;}
            if(actual) {
              const baseline=now.nodes.find(n=>n.id===item.id);
              if(baseline&&(actual.title!==baseline.title||(actual.url??'')!==(baseline.urls[0]??''))) continue;
              if(actual.title!==item.title||(actual.url??'')!==(item.urls[0]??'')) {
                if (!await this.writer?.existing('rename',actual,item)) await this.api.bookmarks.update(browserID,{title:item.title,...(item.kind==='bookmark'?{url:item.urls[0]}:{})});
              }
              // 索引由浏览器实际节点数限制；移动保留浏览器身份。
              if(actual.parentId!==parentID||actual.index!==item.order) {
                const children=await this.api.bookmarks.getChildren(parentID),max=Math.max(0,children.length-(actual.parentId===parentID?1:0));
                await this.api.bookmarks.move(browserID,{parentId:parentID,index:Math.min(Math.max(0,item.order),max)});
              }
            }
          }
          if(!browserID) {
            const siblings = await this.api.bookmarks.getChildren(parentID);
            const index = Math.min(Math.max(0,item.order),siblings.length);
            const nativeNode = await this.writer?.create(parentID,index,item,siblings);
            const node = nativeNode ?? await this.api.bookmarks.create({parentId:parentID,index,title:item.title,...(item.kind==='bookmark'?{url:item.urls[0]}:{})});
            browserID=node.id;mapping[browserID]=item.id;local[item.id]=browserID;
          }
        }
        if(next.length===remaining.length) {
          // 环或缺失父目录落到可访问根，不删除内容。
          for(const item of next)item.parentID=null;
        }
        remaining=next;
      }
      if(remaining.length)throw new Error('部分目录关系无法整理，已保留原内容');
      const parentByID = new Map(now.nodes.map(item=>[item.id,item.parentID]));
      const depth = id => {
        const seen = new Set();
        while(parentByID.get(id) && !seen.has(id)) {seen.add(id);id=parentByID.get(id);}
        return seen.size;
      };
      // 先删叶子再删父目录；不能依赖远端墓碑顺序或每分钟多轮重试。
      for(const id of [...remote.deleted].sort((a,b)=>depth(b)-depth(a))) {
        const browserID=local[id];if(!browserID||roots[id])continue;
        const old=now.nodes.find(n=>n.id===id);if(!old)continue;
        expected[id]=canonical(old);
        let current;try{current=(await this.api.bookmarks.get(browserID))[0];}catch{continue;}
        if(current.title!==old.title||(current.url??'')!==(old.urls[0]??''))continue;
        // 逐节点删除；目录仍有子项则保留，避免吞掉并发新收藏。
        try{if (!await this.writer?.existing('delete',current,old)) await this.api.bookmarks.remove(browserID);delete mapping[browserID];delete expected[id];}catch{/* 下一轮再处理非空目录。 */}
      }
      await this.api.storage.local.set({bookmarkMapping:mapping});
      const after=await this.snapshot();
      await this.api.storage.local.set({bookmarkBaseline:expected,bookmarkConnected:true,lastSync:new Date().toISOString(),bookmarkLastError:''});
      const acknowledged = [...change.deleted,...arrived.deleted,...remote.deleted].map(id => 'bookmarkRemoval:'+id);
      if (acknowledged.length) await this.api.storage.local.remove(acknowledged);
      return {count:after.nodes.length,message:'已与本机 App 合并；跨设备状态请在 App 查看'};
    } catch(error) {
      await this.api.storage.local.set({bookmarkLastError:String(error?.message??'同步未完成').slice(0,2000)}).catch(()=>{});
      throw error;
    } finally {this.running=false;}
  }
}
