import {NativeWrites} from './native-writes.mjs';
import {encrypt,decrypt} from './crypto.mjs';
import {BookmarkSync} from './bookmarks.mjs';
const api = globalThis.browser ?? chrome;
async function native(payload) {
  const {pairingToken} = await api.storage.local.get('pairingToken');
  if (!pairingToken) throw new Error('请先保存收藏夹配对密钥');
  const request = await encrypt(payload,pairingToken);
  const response = await api.runtime.sendNativeMessage('com.gcsa.pbsync',request);
  if (!response?.sealed) throw new Error(response?.error ?? '本机 PBsync 无响应');
  const result = await decrypt(response,pairingToken,request);
  if (!result.ok) throw new Error(result.error);
  return result.payload;
}
const sync = new BookmarkSync(api,native,api.runtime.getBrowserInfo ? null : new NativeWrites(api));
let timer;
function schedule() {
  if (timer) return;
  timer=setTimeout(async () => {
    timer=null;
    try {
      if ((await api.storage.local.get('bookmarkConnected')).bookmarkConnected) {
        await sync.sync();
        await api.action.setBadgeText({text:''});
      }
    } catch { await api.action.setBadgeText({text:'!'}); }
  }, 1000);
}
for (const name of ['onCreated','onChanged','onMoved','onChildrenReordered','onImportEnded']) api.bookmarks[name]?.addListener(schedule);
api.bookmarks.onRemoved.addListener((id,info)=>sync.recordRemoval(id,info).then(schedule));
api.alarms.create('pbsync-bookmarks',{periodInMinutes:1});
api.alarms.onAlarm.addListener(alarm=>{if(alarm.name==='pbsync-bookmarks') schedule();});
api.runtime.onMessage.addListener((message,sender,respond)=>{
  if(sender.id!==api.runtime.id || sender.url!==api.runtime.getURL('popup.html')) return false;
  const run=async()=>{
    if(message.action==='preview') return sync.preview();
    if(message.action==='merge') return sync.sync({firstConfirmed:true});
    throw new Error('不支持的操作');
  };
  run().then(payload=>respond({payload})).catch(error=>respond({error:error.message}));
  return true;
});
