// 网页身份只允许精确 HTTPS origin，不使用字符串后缀猜测域名。
export function originOf(value) {
  try { const url = new URL(value); return url.protocol === 'https:' && !url.username && !url.password ? url.origin : null; }
  catch { return null; }
}
export function sameOrigin(a, b) { const origin = originOf(a); return origin !== null && origin === originOf(b); }
export function normalizeUUID(value) { return typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value) ? value.toLowerCase() : null; }
export function canonical(item) {
  return JSON.stringify({kind:item.kind,title:item.title,parentID:item.parentID?.toLowerCase() ?? null,order:item.order,urls:item.urls ?? []});
}
export function delta(current, baseline = {}) {
  const changes = [], deleted = [], currentIDs = new Set();
  for (const item of current) { currentIDs.add(item.id.toLowerCase()); if (baseline[item.id.toLowerCase()] !== canonical(item)) changes.push(item); }
  for (const id of Object.keys(baseline)) if (!currentIDs.has(id)) deleted.push(id);
  return {items:changes, deleted};
}
export function validateRemote(items, deleted) {
  if (!Array.isArray(items) || !Array.isArray(deleted) || items.length > 50000) throw new Error('收藏夹清单无效');
  const ids = new Set();
  for (const item of items) {
    item.id = normalizeUUID(item.id); item.parentID = item.parentID ? normalizeUUID(item.parentID) : null;
    if (!item.id || ids.has(item.id) || !['folder','bookmark'].includes(item.kind) || typeof item.title !== 'string' || !Number.isSafeInteger(item.order)) throw new Error('收藏夹身份或字段无效');
    if (item.kind === 'bookmark' && (!Array.isArray(item.urls) || typeof item.urls[0] !== 'string')) throw new Error('收藏缺少网址');
    ids.add(item.id);
  }
  return items;
}
