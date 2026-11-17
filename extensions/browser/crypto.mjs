const encoder = new TextEncoder(), decoder = new TextDecoder();
const from64 = value => Uint8Array.from(atob(value), c => c.charCodeAt(0));
const to64 = value => btoa(Array.from(value, c => String.fromCharCode(c)).join(''));
function context(wire, response) { return encoder.encode(`PBsync-bridge|1|${response ? 'resp' : 'req'}|${wire.id.toLowerCase()}|${wire.issuedAt}`); }
export async function encrypt(payload, token, responseTo = null) {
  const raw = from64(token); if (raw.length !== 32) throw new Error('配对密钥需要重新生成');
  const key = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt']);
  const wire = {id:responseTo?.id ?? crypto.randomUUID(), issuedAt:responseTo?.issuedAt ?? Math.floor(Date.now()/1000)};
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const body = new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:context(wire,!!responseTo),tagLength:128},key,encoder.encode(JSON.stringify(payload))));
  const combined = new Uint8Array(12+body.length); combined.set(nonce); combined.set(body,12); wire.sealed=to64(combined); return wire;
}
export async function decrypt(wire, token, request) {
  if (!wire?.sealed || wire.id?.toLowerCase() !== request.id.toLowerCase() || wire.issuedAt !== request.issuedAt || Math.abs(Date.now()/1000-wire.issuedAt)>120) throw new Error('App 响应身份或时效校验失败');
  const bytes=from64(wire.sealed), key=await crypto.subtle.importKey('raw',from64(token),'AES-GCM',false,['decrypt']);
  return JSON.parse(decoder.decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes.slice(0,12),additionalData:context(wire,true),tagLength:128},key,bytes.slice(12))));
}
