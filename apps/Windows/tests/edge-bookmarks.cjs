// 使用远程机实际安装的 Edge、独立 profile、原版扩展及已解锁的 PBsync.exe。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { chromium } = require('./playwright');
const { webcrypto, randomUUID, pbkdf2Sync, createDecipheriv, createHmac } = require('node:crypto');

const root = process.env.PBSYNC_QA_ROOT;
const processId = Number(process.env.PBSYNC_QA_APP_ID);
// 仅用合成备份计算测试密钥。Windows 服务会话无法把桌面剪贴板交给测试驱动。
const { header } = JSON.parse(fs.readFileSync(path.join(root, 'bookmarks.pbsync')));
const master = fs.readFileSync(path.join(root, 'bookmark-master'), 'utf8').trim();
const local = path.join(process.env.LOCALAPPDATA, 'PBsync');
const contextPrefix = 'PBsync|1|' + header.spaceID.toLowerCase() + '|' + header.keyEpoch + '|';
const slot = Buffer.from(header.passwordSlot, 'base64');
const wrapping = pbkdf2Sync(master, Buffer.from(header.salt,'base64'), header.iterations, 32, 'sha256');
const decipher = createDecipheriv('aes-256-gcm',wrapping,slot.subarray(0,12));
decipher.setAAD(Buffer.from(contextPrefix + 'password'));
decipher.setAuthTag(slot.subarray(-16));
const vaultKey = Buffer.concat([decipher.update(slot.subarray(12,-16)),decipher.final()]);
const device = fs.readFileSync(path.join(local, 'device-id'),'utf8').toLowerCase();
const material = label => createHmac('sha256',vaultKey).update(contextPrefix + label + '|' + device).digest();
const token = material('browser-pairing').toString('base64');
assert.deepEqual(fs.readFileSync(path.join(local, 'bookmarks-pairing.grant')),material('browser-grant'));
vaultKey.fill(0);
wrapping.fill(0);
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const profile = path.join(root, 'browser-profile');
const extension = path.join(root, 'extension');
const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const credentials = Buffer.from(token, 'base64');
let context;
let installed = false;

function powershell(file, body) {
    const script = '$ErrorActionPreference="Stop"; $f=' + JSON.stringify(path.join(root, file)).replace(/\\\\/g,'\\') +
        '; & ([ScriptBlock]::Create([IO.File]::ReadAllText($f))) ' + body;
    const result = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')],
        { encoding: 'utf8', windowsHide: true, timeout: 35_000 });
    if (result.status !== 0) throw new Error('Windows step failed: ' + (result.stderr || result.error?.message || result.stdout));
    return result.stdout.trim();
}
const quote = text => "'" + text.replaceAll("'", "''") + "'";
function app(action) {
    return powershell('edge-ui-actions.ps1', '-Root ' + quote(root) + ' -ProcessId ' + processId + ' -Action ' + action);
}

async function browser() {
    const context = await chromium.launchPersistentContext(profile, {
        executablePath: edge,
        headless: true,
        ignoreDefaultArgs: ['--disable-extensions'],
        args: ['--disable-gpu','--no-first-run','--disable-sync','--no-default-browser-check',
            '--disable-background-networking','--disable-extensions-except=' + extension,'--load-extension=' + extension]
    });
    let worker = context.serviceWorkers().find(worker => worker.url().endsWith('/background.mjs'));
    while (!worker) {
        await context.waitForEvent('serviceworker', {timeout: 18000});
        worker = context.serviceWorkers().find(item => item.url().endsWith('/background.mjs'));
    }
    return {context, extensionId: new URL(worker.url()).hostname};
}

async function authenticated(page, request) {
    const id = randomUUID(), issuedAt = Math.floor(Date.now() / 1000);
    const key = await webcrypto.subtle.importKey('raw', credentials, 'AES-GCM', false, ['encrypt','decrypt']);
    const nonce = webcrypto.getRandomValues(new Uint8Array(12));
    const aad = direction => Buffer.from('PBsync-bridge|1|' + direction + '|' + id + '|' + issuedAt);
    const cipher = await webcrypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:aad('req')}, key,
        Buffer.from(JSON.stringify(request)));
    const message = {id,issuedAt,sealed:Buffer.concat([nonce,Buffer.from(cipher)]).toString('base64')};
    const send = () => page.evaluate(wire => chrome.runtime.sendNativeMessage('com.gcsa.pbsync', wire), message);
    const open = async wire => {
        if (!wire?.sealed) throw new Error(wire?.error || 'Missing authenticated response');
        assert.equal(wire.id, id);
        assert.equal(wire.issuedAt, issuedAt);
        const raw = Buffer.from(wire.sealed, 'base64');
        return JSON.parse(Buffer.from(await webcrypto.subtle.decrypt({name:'AES-GCM',iv:raw.subarray(0,12),
            additionalData:aad('resp')}, key, raw.subarray(12))).toString('utf8'));
    };
    return {response:await open(await send()), replay:async () => open(await send())};
}

async function until(label, predicate, timeout=24000) {
    const end = Date.now() + timeout;
    while (Date.now() < end) {
        if (await predicate()) return;
        await pause(450);
    }
    throw new Error('Timed out: ' + label);
}

async function main() {
    let launch = await browser();
    context = launch.context;
    const id = launch.extensionId;
    const registration = '-Browser Edge -Exe ' + quote(path.join(root, 'PBsync.exe')) + ' -ExtensionId ' + id;
    powershell('install-native-host-windows.ps1', registration);
    installed = true;

    let page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('chrome-extension://' + id + '/popup.html');
    assert.equal(await page.title(), 'PBsync 书签');
    assert(await page.locator('main').isVisible());
    app('app-seed');

    const fixture = await page.evaluate(async () => {
        const root = (await chrome.bookmarks.getTree())[0].children[0];
        const folder = await chrome.bookmarks.create({parentId:root.id,title:'PBsync QA Folder'});
        const a = await chrome.bookmarks.create({parentId:folder.id,title:'PBsync QA A',url:'https://a.example.invalid/'});
        const b = await chrome.bookmarks.create({parentId:folder.id,title:'PBsync QA B',url:'https://b.example.invalid/'});
        return {folder:folder.id,a:a.id,b:b.id};
    });
    await page.locator('#token').fill(token);
    await page.locator('#preview').click();
    const status = () => page.locator('#status').innerText();
    await until('preview counts', async () => /2 条.*1 条/.test(await status()));
    assert(!(await page.evaluate(() => chrome.storage.local.get('bookmarkConnected'))).bookmarkConnected);
    await page.locator('#merge').click();
    await until('confirmed merge', async () => (await status()).includes('已与本机 App 合并'));
    assert((await page.evaluate(() => chrome.bookmarks.search({title:'PBsync App Seed'}))).some(item => item.url === 'https://app.example.invalid/'));
    await page.screenshot({path:path.join(root,'edge-popup.png')});

    const limited = await authenticated(page, {command:'credential.list',url:'https://example.invalid'});
    assert.equal(limited.response.ok, false);
    assert.match((await limited.replay()).error, /已经处理/);

    await page.evaluate(({id,parentId}) => chrome.bookmarks.move(id,{parentId,index:0}),{id:fixture.b,parentId:fixture.folder});
    assert.equal(app('ordered'),'["PBsync QA B","PBsync QA A"]');
    assert.equal(app('edit'),'["PBsync QA A from App","PBsync QA B"]');
    const tree = () => page.evaluate(id => chrome.bookmarks.getChildren(id).then(nodes => nodes.map(({title,url}) => ({title,url}))),fixture.folder);
    await until('browser pulls App editing and reorder on its regular alarm', async () =>
        JSON.stringify(await tree()) === JSON.stringify([
          {title:'PBsync QA A from App',url:'https://a.example.invalid/'},
          {title:'PBsync QA B',url:'https://b.example.invalid/'}]), 77000);
    await page.evaluate(id => chrome.bookmarks.remove(id),fixture.b);
    assert.equal(app('remaining'),'["PBsync QA A from App"]');
    const result = await authenticated(page,{command:'bookmarks.pull'});
    assert(result.response.ok && result.response.payload.deleted.length > 0);

    await context.close();
    launch = await browser();
    context = launch.context;
    assert.equal(launch.extensionId,id);
    page = await context.newPage();
    await page.goto('chrome-extension://' + id + '/popup.html');
    assert((await page.evaluate(() => chrome.storage.local.get('bookmarkConnected'))).bookmarkConnected);
    assert.deepEqual(await tree(), [{title:'PBsync QA A from App',url:'https://a.example.invalid/'}]);
    assert.deepEqual(errors,[]);
    fs.writeFileSync(path.join(root,'edge-receipt.json'),JSON.stringify({browser:'Edge 157', extensionId:id,
        popup:await page.title(),firstMerge:true,reorderBothWays:true,renameFromApp:true,backgroundAlarm:true,
        explicitDelete:true,restartReadback:true,noCredentialAccess:true,orderedResult:await tree()}));
}

main().then(() => console.log('Edge native bookmark round trip passed')).catch(error => {
    console.error(error.message);
    process.exitCode = 1;
}).finally(async () => {
    if (context) await context.close().catch(()=>{});
    if (installed) powershell('install-native-host-windows.ps1','-Browser Edge -Remove');
    credentials.fill(0);
});
