// Real-browser smoke test: headless Chrome opens the app, logs in through the login screen,
// opens screens and makes a sale through the cashier UI. Fails on any uncaught page error.
//   CHROME=/usr/bin/google-chrome APP_URL=http://127.0.0.1:5173/app/ node scripts/e2e/browser-e2e.mjs
import { spawn } from 'node:child_process';
import fs from 'node:fs';

const CHROME = process.env.CHROME || 'google-chrome';
const APP = process.env.APP_URL || 'http://127.0.0.1:5173/app/';
const SHOTS = process.env.SHOTS || '/tmp/sr-shots';
fs.mkdirSync(SHOTS, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let failed = 0; const ok = (c, m) => { console.log((c ? '✓ ' : '✗ ') + m); if (!c) failed++ };

const port = 9300 + Math.floor(Math.random() * 500);
const chrome = spawn(CHROME, ['--headless=new', '--no-sandbox', '--disable-gpu', `--remote-debugging-port=${port}`, '--window-size=1366,900',
  '--user-data-dir=/tmp/sr-chrome-' + port, 'about:blank'], { stdio: 'ignore' });
let ws, id = 0; const wait = new Map(), errors = [];
for (let i = 0; i < 50; i++) { try { const t = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); const p = t.find(x => x.type === 'page'); if (p) { ws = new WebSocket(p.webSocketDebuggerUrl); break } } catch (_) {} await sleep(200) }
await new Promise(r => ws.onopen = r);
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && wait.has(m.id)) { wait.get(m.id)(m); wait.delete(m.id) }
  if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text) };
const cdp = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })) });
const js = async expr => { const r = await cdp('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.result.exceptionDetails) throw new Error(r.result.exceptionDetails.exception?.description); return r.result.result.value };
const shot = async n => { const r = await cdp('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(`${SHOTS}/${n}.png`, Buffer.from(r.result.data, 'base64')) };
const until = async (expr, ms = 8000) => { for (let t = 0; t < ms; t += 100) { if (await js(expr)) return true; await sleep(100) } return false };

await cdp('Runtime.enable'); await cdp('Page.enable');
async function open() { await cdp('Page.navigate', { url: APP }); await until('document.readyState=="complete"'); await sleep(300) }
async function loginAs(u, pw) {
  await js('lpLogin()');
  await js(`$('#ls').value='demo';$('#lu').value='${u}';$('#lp').value='${pw}';login()`);
  return until('!!document.querySelector("header nav")');
}

// ---------------------------------------------------------------- cashier sells through the UI
await open();
ok(await js('!!window.SR && SR.on'), 'page runs in Supabase mode');
await js('lpLogin()'); await js(`$('#ls').value='demo';$('#lu').value='kasa1';$('#lp').value='wrong';login()`);
ok(await until(`$('#le').textContent.includes('არასწორი')`), 'wrong password shows an error');
await shot('01-login-error');
ok(await loginAs('kasa1', '1234'), 'cashier logged in through the login screen');
await shot('02-cashier');
// open a shift if needed, then sell one item
ok(await js('!!zhCur() || document.querySelector("#app").innerHTML.includes("ცვლ")'), 'shift panel or open shift shown');
await shot('03-shift');
const before = await js('D.s.length');
// put a product in the cart and pay via the app's own functions
await js(`(()=>{if(!zhCur())zhOpenCore(U.branch,U.u,0,'');
  const p=D.p.find(p=>!p.sz)||D.p[0];const z=p.sz?(p.zs||SZ)[0]:NS;cart=[{pid:p.id,z,q:1,pr:zpr(p,z)}];pm='ნაღდი';view='sale';render()})()`);
await shot('04-cart');
let sold = false;
try { await js('done()'); sold = await until(`D.s.length>${before}`, 4000) } catch (e) { console.log('  done():', e.message) }
ok(sold, 'sale completed through done()');
ok(await until('SVOK===1 && !SR.dirty()', 10000), 'sale confirmed by the server');
if (await js('SR.dirty()')) console.log('  pending:', await js('JSON.stringify((d=>({up:Object.fromEntries(Object.entries(d.up).map(([k,v])=>[k,v.length])),rm:d.rm,st:d.st,kv:Object.keys(d.kv)}))(SR.pendingChanges()))'), 'SVOK', await js('SVOK'), await js('document.getElementById("srbn")?.textContent||""'));
await shot('05-receipt');
for (const v of ['tx', 'rx', 'stk', 'shift']) { await js(`modal();view='${v}';render()`); await sleep(250) }
await shot('06-cashier-screens');
ok(await until('!SR.dirty()', 6000), 'nothing left unsaved before logout');
await js('SR.logout()'); await sleep(500);

// ---------------------------------------------------------------- admin opens every dashboard screen
await open();
ok(await loginAs('admin', '1234'), 'admin logged in');
ok(await js(`D.s.length>=${before + 1}`), "admin sees the cashier's receipt");
for (const v of ['today', 'stats', 'prod', 'tx', 'shl', 'buy', 'trf', 'sup', 'cu', 'inv', 'emp']) {
  await js(`modal();view='${v}';render()`);
  ok(await until(`!document.querySelector('#app').innerHTML.includes('მონაცემები იტვირთება')`, 8000), `screen "${v}" rendered`);
  await shot('10-admin-' + v);
}
await js('SR.dirty()||SR.logout()');

ok(errors.length === 0, 'no uncaught page errors' + (errors.length ? ':\n   ' + errors.slice(0, 5).join('\n   ') : ''));
chrome.kill();
console.log(failed ? `\n${failed} browser check(s) failed (screenshots in ${SHOTS})` : `\nall browser checks passed (screenshots in ${SHOTS})`);
process.exit(failed ? 1 : 0);
