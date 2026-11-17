import {NativeWrites} from './native-writes.mjs';
import {encrypt,decrypt} from './crypto.mjs';
import {originOf,sameOrigin} from './policy.mjs';
import {BookmarkSync} from './bookmarks.mjs';
const api=globalThis.browser??chrome;
async function native(payload) {
  const {pairingToken}=await api.storage.local.get('pairingToken');if(!pairingToken)throw new Error('请先在设置中配对本机 App');
  const request=await encrypt(payload,pairingToken),wire=await api.runtime.sendNativeMessage('com.gcsa.pbsync',request);
  const result=await decrypt(wire,pairingToken,request);if(!result.ok)throw new Error(result.error??'App 操作失败');return result.payload;
}
import {candidateKey, lifetime, committedCandidate, canAutoSave} from './save-policy.mjs';

const tabWork = new Map();
function inTabOrder(id, operation) {
  const running = (tabWork.get(id) ?? Promise.resolve()).catch(() => {}).then(operation);
  tabWork.set(id, running);
  return running.finally(() => { if (tabWork.get(id) === running) tabWork.delete(id); });
}
async function pending(id) {
  const key = candidateKey(id);
  const value = (await api.storage.session.get(key))[key];
  if (value && Date.now() - value.time < lifetime) return value;
  if (value) await api.storage.session.remove(key);
}
api.webNavigation.onCommitted.addListener(event => {
  if (event.frameId !== 0) return;
  inTabOrder(event.tabId, async () => {
    const candidate = await pending(event.tabId);
    if (!candidate) return;
    if (!sameOrigin(event.url, candidate.url)) return api.storage.session.remove(candidateKey(event.tabId));
    await api.storage.session.set({[candidateKey(event.tabId)]:committedCandidate(candidate, event)});
  }).catch(() => {});
});
api.tabs.onRemoved.addListener(id => inTabOrder(id, () => api.storage.session.remove(candidateKey(id))).catch(() => {}));
api.alarms.onAlarm.addListener(async alarm => {
  if (alarm.name !== 'pbsync-reconcile') return;
  for (const key of Object.keys(await api.storage.session.get(null))) {
    if (key.startsWith('pending-login-')) {
      const id = Number(key.slice('pending-login-'.length));
      await inTabOrder(id, () => pending(id));
    }
  }
});
const bookmarks=new BookmarkSync(api,native,globalThis.chrome && !api.runtime.getBrowserInfo ? new NativeWrites(api) : null);
let queued=false;
function schedule(){if(queued)return;queued=true;setTimeout(async()=>{queued=false;try{const {bookmarkConnected}=await api.storage.local.get('bookmarkConnected');if(bookmarkConnected)await bookmarks.sync();}catch{await api.action.setBadgeText({text:'!'});}},1000);}
for(const event of ['onCreated','onChanged','onMoved','onChildrenReordered','onImportEnded'])api.bookmarks[event]?.addListener(schedule);
api.bookmarks.onRemoved.addListener((id, info) => bookmarks.recordRemoval(id, info).then(schedule).catch(() => api.action.setBadgeText({text:'!'})));
api.alarms.create('pbsync-reconcile',{periodInMinutes:1});
api.alarms.onAlarm.addListener(alarm=>{if(alarm.name==='pbsync-reconcile')schedule();});
async function activeTab(){const [tab]=await api.tabs.query({active:true,currentWindow:true});if(!tab?.id||!originOf(tab.url))throw new Error('仅允许当前 HTTPS 网页');return tab;}
async function fill(tab,itemID,auto=false){
  const original=tab.url;
  await api.scripting.executeScript({target:{tabId:tab.id,frameIds:[0]},files:['content.js']});
  const document = await api.tabs.sendMessage(tab.id,{action:'identify',expectedURL:original},{frameId:0});
  if (!document?.key) throw new Error('无法核对网页身份');
  const permit=await native({command:'credential.prepareFill',url:original,itemID,auto});
  const current=await api.tabs.get(tab.id);
  if (!current.active || current.url!==original || !sameOrigin(permit.origin,original)) throw new Error('页面已变化，已取消填充');
  if (!auto) await api.windows.update(tab.windowId,{focused:true});
  const ready = await api.tabs.sendMessage(tab.id,{action:'waitForFocus',documentKey:document.key,expectedURL:original},{frameId:0});
  if (!ready?.ready) throw new Error('请回到原网页后再次填充');
  const active = await api.tabs.get(tab.id);
  if (!active.active || active.url !== original) throw new Error('目标已变化，已取消填充');
  const credential = await native({command:'credential.redeemFill',url:original,permit:permit.permit});
  return api.tabs.sendMessage(tab.id,{action:'fill',credential,documentKey:document.key,expectedURL:original},{frameId:0});
}
api.runtime.onMessage.addListener((message,sender,sendResponse)=>{
  const run=async()=>{
    // 网页内容脚本只能报告当前顶层 HTTPS 页面，不能调用同步、列举或填充接口。
    const extensionPage = sender.id === api.runtime.id && sender.url?.startsWith(api.runtime.getURL(''));
    if(sender.tab && !extensionPage){
      if(sender.frameId!==0||!sameOrigin(sender.url,sender.tab.url))throw new Error('页面身份不匹配');
      if(message.action==='saveCandidate'){
        if(!sameOrigin(message.url,sender.url)||typeof message.username!=='string'||typeof message.password!=='string'||message.password.length>4096)throw new Error('保存请求无效');
        return inTabOrder(sender.tab.id, async () => {
          const key = candidateKey(sender.tab.id);
          await api.storage.session.remove(key);
          const scope = await native({command:'credential.capture',url:sender.url,username:message.username});
          const {savePages={},saveVault=''} = await api.storage.local.get(['savePages','saveVault']);
          const automatic = message.submitted === true && scope.vaultID === saveVault &&
            !!scope.successURL && savePages[originOf(sender.url)] === scope.successURL;
          const candidate = {...scope, url:sender.url, username:message.username, password:message.password,
            tabID:sender.tab.id, documentId:sender.documentId, time:Date.now(), automatic};
          await api.storage.session.set({[key]:candidate});
          await api.action.setBadgeText({text:'存', tabId:sender.tab.id});
          return {pending:true};
        });
      }
      if(message.action==='pageReady'){
        await inTabOrder(sender.tab.id, async () => {
          const candidate = await pending(sender.tab.id);
          if (!canAutoSave(candidate,sender,message)) return;
          const {savePages={},saveVault=''} = await api.storage.local.get(['savePages','saveVault']);
          if (candidate.vaultID !== saveVault || savePages[originOf(sender.url)] !== sender.url) return;
          // 消费一次成功信号；发生并发冲突时转回手动确认。
          await api.storage.session.set({[candidateKey(sender.tab.id)]:{...candidate,automatic:false}});
          await native({...candidate,command:'credential.autoSave',landedURL:sender.url});
          await api.storage.session.remove(candidateKey(sender.tab.id));
          await api.action.setBadgeText({text:'',tabId:sender.tab.id});
        });
        const {autoOrigins=[]}=await api.storage.local.get('autoOrigins');if(!autoOrigins.includes(originOf(sender.url)))return {};
        const candidates=await native({command:'credential.list',url:sender.url});if(candidates.length===1)return fill(sender.tab,candidates[0].id,true);return {};
      }
      throw new Error('网页无权调用此操作');
    }
    if(sender.id!==api.runtime.id||!sender.url?.startsWith(api.runtime.getURL('')))throw new Error('扩展调用来源无效');
    switch(message.action){
      case 'previewBookmarks':return bookmarks.preview();
      case 'syncBookmarks':return bookmarks.sync({firstConfirmed:message.firstConfirmed===true});
      case 'credentials':{const tab=await activeTab();return {items:await native({command:'credential.list',url:tab.url}),origin:originOf(tab.url)};}
      case 'fill':return fill(await activeTab(),message.itemID);
      case 'capture':{const tab=await activeTab();await api.scripting.executeScript({target:{tabId:tab.id,frameIds:[0]},files:['content.js']});return api.tabs.sendMessage(tab.id,{action:'capture',expectedURL:tab.url},{frameId:0});}
      case 'saveSites': return native({command:'credential.saveSites'});
      case 'save': {
        const tab = await activeTab();
        return inTabOrder(tab.id, async () => {
          const candidate = await pending(tab.id);
          if (!candidate || !sameOrigin(candidate.url,tab.url)) throw new Error('请重新读取当前网页表单');
          const result = await native({...candidate,command:'credential.save'});
          await api.storage.session.remove(candidateKey(tab.id));
          await api.action.setBadgeText({text:'',tabId:tab.id});
          return result;
        });
      }
      default:throw new Error('不支持的扩展操作');
    }
  };
  run().then(payload=>sendResponse({ok:true,payload})).catch(error=>sendResponse({ok:false,error:error.message??'操作失败'}));return true;
});
