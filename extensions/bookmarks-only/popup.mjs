const api=globalThis.browser??chrome;
const element=id=>document.getElementById(id);
async function call(action) {
  const result=await api.runtime.sendMessage({action});
  if(result.error) throw new Error(result.error);
  return result.payload;
}
element('preview').onclick=async()=>{
  element('merge').disabled=true;
  try {
    const token=element('token').value.trim();
    if(token){
      if(atob(token).length!==32) throw new Error('配对密钥长度无效');
      const {pairingToken}=await api.storage.local.get('pairingToken');
      if(pairingToken && token!==pairingToken) throw new Error('已有其他配对，请先检查');
      await api.storage.local.set({pairingToken:token});element('token').value='';
    }
    const p=await call('preview');
    element('status').textContent='本浏览器 '+p.localCount+' 条，共享收藏夹 '+p.remoteCount+' 条';
    element('merge').disabled=false;
  } catch(e){element('status').textContent=e.message;}
};
element('merge').onclick=async()=>{
  element('merge').disabled=true;
  try {const r=await call('merge');element('status').textContent=r.message??'同步中';}
  catch(e){element('status').textContent=e.message;}
};
