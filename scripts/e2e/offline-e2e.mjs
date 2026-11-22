// Real-browser test of the offline till: headless Chrome loses the internet, the cashier keeps selling,
// the page is reloaded (and the app "reopened") while still offline, then the connection returns and
// every receipt reaches the server exactly once, with the stock moved exactly once.
//   needs the same setup as browser-e2e.mjs (scripts/e2e/run.sh) and E2E_DB_URL + psql to check the database
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';

const CHROME = process.env.CHROME || 'google-chrome';
const APP = process.env.APP_URL || 'http://127.0.0.1:5173/app/';
const SHOTS = process.env.SHOTS || '/tmp/sr-shots-offline';
const DB = process.env.E2E_DB_URL;
fs.mkdirSync(SHOTS, { recursive: true });
const SIGNED_IN = '(typeof U!=="undefined"&&!!U)';
const sleep = ms => new Promise(r => setTimeout(r, ms));
let failed = 0; const ok = (c, m) => { console.log((c ? '✓ ' : '✗ ') + m); if (!c) failed++ };
const psql = q => execFileSync('psql', [DB, '-qAtX', '-v', 'ON_ERROR_STOP=1', '-c', q], { encoding: 'utf8' }).trim();

const port = 9800 + Math.floor(Math.random() * 500);
const chrome = spawn(CHROME, ['--headless=new', '--no-sandbox', '--disable-gpu', `--remote-debugging-port=${port}`, '--window-size=1366,900',
  '--user-data-dir=/tmp/sr-chrome-off-' + port, 'about:blank'], { stdio: 'ignore' });
let ws, id = 0; const wait = new Map(), errors = [];
for (let i = 0; i < 50; i++) { try { const t = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); const p = t.find(x => x.type === 'page'); if (p) { ws = new WebSocket(p.webSocketDebuggerUrl); break } } catch (_) {} await sleep(200) }
await new Promise(r => ws.onopen = r);
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && wait.has(m.id)) { wait.get(m.id)(m); wait.delete(m.id) }
  if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text) };
const cdp = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })) });
const js = async expr => { const r = await cdp('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.result.exceptionDetails) throw new Error(r.result.exceptionDetails.exception?.description); return r.result.result.value };
const shot = async n => { const r = await cdp('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(`${SHOTS}/${n}.png`, Buffer.from(r.result.data, 'base64')) };
const until = async (expr, ms = 8000) => { for (let t = 0; t < ms; t += 100) { try { if (await js(expr)) return true } catch (_) {} await sleep(100) } return false };

// the page and the service worker both lose the network (the worker has its own network stack)
async function setOffline(off) {
  const cond = { offline: off, latency: 0, downloadThroughput: -1, uploadThroughput: -1 };
  await cdp('Network.emulateNetworkConditions', cond);
  const tg = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  for (const t of tg.filter(x => x.type === 'service_worker')) {
    const w = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => w.onopen = r);
    w.send(JSON.stringify({ id: 1, method: 'Network.enable' }));
    w.send(JSON.stringify({ id: 2, method: 'Network.emulateNetworkConditions', params: cond }));
    await sleep(300); w.close();
  }
}

await cdp('Runtime.enable'); await cdp('Page.enable'); await cdp('Network.enable');
async function open() { await cdp('Page.navigate', { url: APP }); await until('document.readyState=="complete"', 15000); await sleep(300) }
async function loginAs(u, pw) {
  await js('lpLogin()');
  await js(`$('#ls').value='demo';$('#lu').value='${u}';$('#lp').value='${pw}';login()`);
  return until('!!document.querySelector("header nav")');
}
// one item, one sale, through the app's own functions (as in browser-e2e.mjs)
const sell = async () => {
  const n = await js('D.s.length');
  await js(`(()=>{if(!zhCur())zhOpenCore(U.branch,U.u,0,'');
    const p=D.p.find(p=>!p.sz)||D.p[0];const z=p.sz?(p.zs||SZ)[0]:NS;cart=[{pid:p.id,z,q:1,pr:zpr(p,z)}];pm='ნაღდი';view='sale';render()})()`);
  await js('done()');
  return until(`D.s.length>${n}`, 4000);
};
const sold = () => +psql("select count(*) from app.sales");
const stockSum = () => +psql("select coalesce(sum(qty),0) from app.stock_levels");

// ---------------------------------------------------------------- online: sign in, one sale
await open();
ok(await loginAs('kasa1', '1234'), 'cashier logged in');
ok(await until('SR.safe()'), 'offline copy is available in this browser');
ok(await sell(), 'sale 1 (online)');
ok(await until('SVOK===1 && !SR.dirty()', 10000), 'sale 1 reached the server');
const base = { receipts: sold(), stock: stockSum() };
ok(await until('navigator.serviceWorker.controller!==null || navigator.serviceWorker.ready.then(()=>1)', 8000), 'service worker active');
await sleep(1500);            // the app shell is cached on install; let the first copy of D be written too

// ---------------------------------------------------------------- the internet goes away
await setOffline(true);
ok(await until('navigator.onLine===false'), 'browser is offline');
ok(await sell(), 'sale 2 (offline)');
ok(await sell(), 'sale 3 (offline)');
await sleep(800);
ok(await js('SR.queued()'), 'sales are queued');
ok(await js('!document.getElementById("srbn")'), 'no red "not saved" banner while offline');
ok(await js('!!document.getElementById("srof")'), 'offline mark is shown');
ok(sold() === base.receipts, 'nothing reached the server while offline');
await shot('01-offline-after-sales');

// ---------------------------------------------------------------- the page is reloaded while offline
await open();
ok(await until(SIGNED_IN + ' && !!document.querySelector("header nav")', 12000), 'app reopens offline and signs in from the offline copy');
ok(await js(`D.s.length>=${3}`), 'receipts sold offline are still there after the reload');
ok(await js('SR.dirty()||SR.queued()'), 'they are still waiting to be sent');
ok(await sell(), 'sale 4 (offline, after the reload)');
await shot('02-offline-after-reload');

// ---------------------------------------------------------------- the internet comes back
await setOffline(false);
ok(await until('SVOK===1 && !SR.dirty() && !SR.queued()', 25000), 'queued sales are sent when the connection returns');
ok(sold() === base.receipts + 3, `server has exactly 3 new receipts (has ${sold() - base.receipts})`);
ok(Math.round(base.stock - stockSum()) === 3, `stock moved exactly 3 units, once (moved ${Math.round(base.stock - stockSum())})`);
ok(await js('!document.getElementById("srof")'), 'offline mark is gone');
await shot('03-back-online');

// ---------------------------------------------------------------- reopening online starts clean
await open();
ok(await until(SIGNED_IN + ' && !!document.querySelector("header nav")', 12000), 'reopened online: still signed in (same sign-in, no password)');
ok(await until('!SR.dirty()', 6000) && sold() === base.receipts + 3, 'nothing is sent twice');
await js('SR.dirty()||SR.logout()');
await sleep(500);
ok(await js('!(' + SIGNED_IN + ')'), 'logout clears the offline copy');
await open();
ok(await js('!(' + SIGNED_IN + ')'), 'after logout the login screen is shown');

ok(errors.length === 0, 'no uncaught page errors' + (errors.length ? ':\n   ' + errors.slice(0, 5).join('\n   ') : ''));
chrome.kill();
console.log(failed ? `\n${failed} offline check(s) failed (screenshots in ${SHOTS})` : `\nall offline checks passed (screenshots in ${SHOTS})`);
process.exit(failed ? 1 : 0);
