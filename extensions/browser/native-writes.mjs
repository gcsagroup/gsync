// 扩展保留事件监听和逐项回读；宿主只向自己所属的浏览器进程发送书签数据指令。
export class NativeWrites {
  constructor(api) { this.api = api; this.available = undefined; }
  async supports() {
    if (this.available !== undefined) return this.available;
    try {
      const response = await this.api.runtime.sendNativeMessage('com.gcsa.pbsync',{nativeBookmarkRoute:'available'});
      this.available = response?.outcome === 'available';
      if (this.available) {
        const {nativeAccessRequested} = await this.api.storage.local.get('nativeAccessRequested');
        if (!nativeAccessRequested) {
          await this.api.storage.local.set({nativeAccessRequested:true});
          // 首次系统授权独立于同步；等待确认期间走扩展。
          this.api.runtime.sendNativeMessage('com.gcsa.pbsync',{nativeBookmarkRoute:'authorize'}).catch(()=>{});
        }
      }
    } catch { this.available = false; }
    return this.available;
  }
  async attempt(operation, parent, index, item, siblings) {
    if (!siblings.length || index < 0 || index >= siblings.length || siblings.length > 3000 ||
        siblings.some(n => !n.url || n.unmodifiable) || !(await this.supports())) return 'fallback';
    // 浏览器更新下载到磁盘时，正在运行的引擎可能仍是旧版。缺少实际版本证据时保守回退。
    const hints = await globalThis.navigator?.userAgentData?.getHighEntropyValues(['fullVersionList']).catch(()=>null);
    const runtimeVersions = (hints?.fullVersionList ?? []).map(entry=>entry.version);
    const request = {operation,parent,index,title:item.title,url:item.urls?.[0],runtimeVersions,
      children:siblings.map(n => ({id:n.id,title:n.title,url:n.url}))};
    if (new TextEncoder().encode(JSON.stringify(request)).length > 900000) return 'fallback';
    const result = await this.api.runtime.sendNativeMessage('com.gcsa.pbsync',{nativeBookmarkRoute:'write',request});
    return result?.outcome ?? 'uncertain';
  }
  async recoverCreate() {
    const {pendingNativeCreate:pending} = await this.api.storage.local.get('pendingNativeCreate');
    if (!pending) return null;
    const seen = new Set(pending.before);
    const current = await this.api.bookmarks.getChildren(pending.parent);
    const added = current.filter(n => !seen.has(n.id) && n.title === pending.title && n.url === pending.url);
    if (added.length !== 1) throw new Error('原生新增的结果待核对，已暂停重复写入');
    const {bookmarkMapping={}} = await this.api.storage.local.get('bookmarkMapping');
    bookmarkMapping[added[0].id] = pending.uuid;
    await this.api.storage.local.set({bookmarkMapping});
    await this.api.storage.local.remove('pendingNativeCreate');
    return added[0];
  }
  async create(parent,index,item,siblings) {
    if (item.kind !== 'bookmark' || index >= siblings.length || !siblings.length ||
        siblings.some(n => !n.url || n.unmodifiable) || !(await this.supports())) return null;
    await this.api.storage.local.set({pendingNativeCreate:{uuid:item.id,parent,title:item.title,url:item.urls[0],before:siblings.map(n=>n.id)}});
    const outcome = await this.attempt('create',parent,index,item,siblings);
    if (outcome !== 'fallback') return this.recoverCreate();
    await this.api.storage.local.remove('pendingNativeCreate');
    return null;
  }
  async existing(operation, node, item) {
    // 删除由拥有当前节点身份的浏览器 API 完成，避免宿主读取配置或系统自动化
    // 等待拖住整轮同步。目录是否为空、并发内容保护仍由书签引擎逐项核对。
    if (operation === 'delete') return false;
    if (!node.url || node.unmodifiable || (operation === 'rename' && node.url !== item.urls[0]) || !(await this.supports())) return false;
    const siblings = await this.api.bookmarks.getChildren(node.parentId);
    const index = siblings.findIndex(n => n.id === node.id);
    if (index < 0 || siblings[index].title !== node.title || siblings[index].url !== node.url) throw new Error('待写书签已变化');
    if (await this.attempt(operation,node.parentId,index,item,siblings) === 'fallback') return false;
    const latest = (await this.api.bookmarks.getChildren(node.parentId)).find(n=>n.id===node.id);
    if (operation === 'delete' ? !latest : latest?.title === item.title && latest?.url === node.url) return true;
    throw new Error('原生操作结果待核对，已暂停本轮写回');
  }
}
