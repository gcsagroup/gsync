import {originOf} from './policy.mjs';
const api = globalThis.browser ?? chrome;
const el = id => document.getElementById(id);
const config = await api.storage.local.get(['pairingToken','autoOrigins','savePages']);
el('token').value = config.pairingToken ?? '';
el('origins').value = (config.autoOrigins ?? []).join('\n');
let offered;
function display(pages) {
  el('rules').textContent = Object.values(pages ?? {}).join('\n') || '当前逐次确认保存';
}
display(config.savePages);
function action(id, run) {
  el(id).onclick = async () => {
    try { await run(); } catch (error) { el('status').textContent = error.message; }
  };
}
function patterns(origins) {
  // 扩展匹配模式按主机授权，实际处理仍按协议、主机和端口完整核对。
  return [...new Set(origins.map(origin => 'https://' + new URL(origin).hostname + '/*'))];
}
async function allow(origins) {
  if (!origins.length) return;
  const permissions = {origins:patterns(origins)};
  if (await api.permissions.contains(permissions)) return;
  if (!await api.permissions.request(permissions)) throw new Error('需要网站权限');
}
async function register(autoOrigins, savePages) {
  const matches = patterns([...autoOrigins, ...Object.keys(savePages)]);
  const id = 'pbsync-allowed-sites';
  const installed = await api.scripting.getRegisteredContentScripts({ids:[id]});
  if (!matches.length) {
    if (installed.length) await api.scripting.unregisterContentScripts({ids:[id]});
    return;
  }
  const entry = {id,matches,js:['content.js'],runAt:'document_idle',allFrames:false,persistAcrossSessions:true};
  if (installed.length) await api.scripting.updateContentScripts([entry]);
  else await api.scripting.registerContentScripts([entry]);
}
async function reset() {
  await register([], {});
  const removals = Object.keys(await api.storage.local.get(null)).filter(key => key.startsWith('bookmarkRemoval:'));
  await api.storage.local.remove([...removals,'bookmarkIncompleteSnapshot','pairingToken','bookmarkConnected','bookmarkBaseline','savePages','saveVault','autoOrigins']);
  await api.storage.session.clear();
  offered = undefined;
  el('enableSave').disabled = true;
  el('origins').value = '';
  display({});
}
action('pair',async () => {
  const token = el('token').value.trim();
  if (Uint8Array.from(atob(token)).length !== 32) throw new Error('配对密钥格式不正确');
  const old = await api.storage.local.get('pairingToken');
  if (old.pairingToken !== token) await reset();
  await api.storage.local.set({pairingToken:token});
  el('status').textContent = '配对已保存';
});
action('revoke',async () => {
  await reset();
  el('token').value = '';
  el('status').textContent = '已移除配对';
});
action('saveOrigins',async () => {
  const origins = [...new Set(el('origins').value.split(/\r?\n/).map(s=>s.trim()).filter(Boolean).map(originOf))];
  if (origins.includes(null)) throw new Error('请输入 HTTPS 网站地址');
  await allow(origins);
  const {savePages={}} = await api.storage.local.get('savePages');
  await register(origins,savePages);
  await api.storage.local.set({autoOrigins:origins});
  el('status').textContent = '自动填入网站已更新';
});
action('readSave',async () => {
  const result = await api.runtime.sendMessage({action:'saveSites'});
  if (!result.ok) throw new Error(result.error);
  offered = result.payload;
  display(offered.pages);
  el('enableSave').disabled = false;
});
action('enableSave',async () => {
  if (!offered) return;
  const origins = Object.keys(offered.pages);
  await allow(origins);
  const {autoOrigins=[]} = await api.storage.local.get('autoOrigins');
  await register(autoOrigins,offered.pages);
  await api.storage.local.set({savePages:offered.pages,saveVault:offered.vaultID});
  el('status').textContent = origins.length ? '已启用所列成功页的自动保存' : '已恢复逐次确认';
});
action('disableSave',async () => {
  const {autoOrigins=[]} = await api.storage.local.get('autoOrigins');
  await api.storage.local.remove(['savePages','saveVault']);
  await register(autoOrigins,{});
  offered = undefined;
  el('enableSave').disabled = true;
  display({});
  el('status').textContent = '已恢复逐次确认';
});
