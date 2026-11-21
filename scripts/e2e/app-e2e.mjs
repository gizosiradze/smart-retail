// End-to-end test of the real app code (web/index.html + web/js/sr.js) against the database.
// Runs the page's scripts in a Node VM with a tiny DOM stand-in, logs in as cashier and admin,
// makes changes the way the screens do (mutate D, call save()) and checks what landed in Postgres.
//
//   E2E_DB_URL=postgres://...  E2E_API=http://127.0.0.1:54399  node scripts/e2e/app-e2e.mjs
import fs from 'node:fs';
import vm from 'node:vm';
import { execFileSync } from 'node:child_process';

const API = process.env.E2E_API || 'http://127.0.0.1:54399';
const DB = process.env.E2E_DB_URL;
const PSQL = (process.env.PSQL || 'psql').split(' ');
const q = s => execFileSync(PSQL[0], [...PSQL.slice(1), DB, '-qAtX', '-c', s], { encoding: 'utf8' }).trim();
let failed = 0;
const ok = (c, m) => { console.log((c ? '✓ ' : '✗ ') + m); if (!c) failed++ };
const sleep = ms => new Promise(r => setTimeout(r, ms));

function makeContext() {
  const store = {}, el = () => new Proxy({ style: {}, dataset: {}, classList: { add() {}, remove() {}, toggle() {}, contains() { return false } },
    innerHTML: '', value: '', children: [], appendChild() {}, append() {}, insertAdjacentHTML() {}, querySelector() { return null }, querySelectorAll() { return [] },
    addEventListener() {}, setAttribute() {}, getAttribute() { return null }, remove() {}, focus() {}, closest() { return null },
    getContext() { return {} }, getBoundingClientRect() { return { left: 0, top: 0, width: 0, height: 0 } }, scrollBy() {} }, {});
  const document = { querySelector: () => el(), querySelectorAll: () => [], getElementById: () => null, addEventListener() {},
    createElement: () => el(), body: el(), documentElement: el(), activeElement: null };
  const ctx = { document, sessionStorage: { getItem: k => store[k] ?? null, setItem: (k, v) => { store[k] = String(v) }, removeItem: k => { delete store[k] } },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} }, navigator: { onLine: true }, matchMedia: () => ({ matches: false }),
    addEventListener() {}, innerWidth: 1280, innerHeight: 800, location: { hash: '' }, parent: { postMessage() {} },
    setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {}, requestAnimationFrame: () => 0, console, fetch, crypto: globalThis.crypto,
    URL, Blob, Intl, scrollTo() {}, ResizeObserver: class { observe() {} }, MutationObserver: class { observe() {} disconnect() {} },
    Image: class {}, FileReader: class {}, TextEncoder, performance, SR_CONFIG: { url: API, anonKey: 'anon-test-key' } };
  ctx.window = ctx; ctx.self = ctx;
  vm.createContext(ctx);
  const html = fs.readFileSync(new URL('../../web/index.html', import.meta.url), 'utf8');
  const main = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]).find(s => s.includes('function render('));
  vm.runInContext(fs.readFileSync(new URL('../../web/js/sr.js', import.meta.url), 'utf8'), ctx, { filename: 'sr.js' });
  // the screens are not under test here: keep render() from touching the DOM stand-in
  vm.runInContext(main.replace(/\nfunction render\(\)\{/, '\nfunction render(){return;'), ctx, { filename: 'index.html' });
  return ctx;
}
const run = (ctx, code) => vm.runInContext(code, ctx);
async function settle(ctx) { for (let i = 0; i < 100; i++) { await sleep(30); if (!run(ctx, 'SR.dirty()') && run(ctx, 'SVOK') === 1) return true } return false }

// ---------------------------------------------------------------- cashier
{
  const ctx = makeContext();
  await run(ctx, 'SR.boot()');
  await run(ctx, "SR.login('demo','kasa1','1234')");
  ok(run(ctx, 'U.type') === 'cashier' && run(ctx, 'U.branch') === 'თბილისი', 'cashier logged in with branch from the server');
  ok(run(ctx, 'BR.join(",")').split(',').length === 2, 'branches come from the database');
  ok(run(ctx, 'D.s.length') === 168, 'receipts loaded');
  ok(run(ctx, 'D.p.every(p=>!("kv" in p))') && q("select count(*) from app.products where doc ? 'cost'") > 0, 'cashier receives products without cost data');
  const n0 = run(ctx, 'D.n');
  ok(n0 >= 243, 'id block reserved on the server (' + n0 + ')');

  // a sale the way done() records it: new receipt, stock down, save()
  run(ctx, `(()=>{const p=D.p[0],z=p.sz?(p.zs||SZ)[0]:NS,s={id:D.n++,t:Date.now(),b:U.branch,u:U.u,it:[{pid:p.id,z,q:2,pr:p.price,cg:0}],tot:2*p.price,m:'ნაღდი'};
    D.st[s.b+'|'+p.id+'|'+z]=st(s.b,p.id,z)-2;D.s.push(s);window.__sale=s;window.__sk=s.b+'|'+p.id+'|'+z;save()})()`);
  ok(await settle(ctx), 'sale saved (SVOK=1, nothing pending)');
  const lid = run(ctx, '__sale.id'), sk = run(ctx, '__sk');
  ok(q(`select count(*) from app.sales where lid=${lid}`) === '1', 'receipt #' + lid + ' is in the database');
  ok(+q(`select (doc->'it'->0->>'cg')::numeric from app.sales where lid=${lid}`) > 0, 'cost of goods stamped by the server');
  ok(run(ctx, '__sale.it[0].cg') > 0, '...and copied back to the screen');
  ok(q(`select count(*) from app.sale_lines l join app.sales s on s.id=l.sale_id where s.lid=${lid}`) === '1', 'typed sale line written');
  ok(q(`select delta from app.stock_movements where skey='${sk}' order by id desc limit 1`) === '-2', 'stock movement recorded as a delta');

  // register a customer
  run(ctx, "D.c.push({id:D.n++,name:'ტესტ',last:'კლიენტი',pid:'',phone:'500000001',rb:U.branch,created:Date.now()});save()");
  ok(await settle(ctx), 'customer saved');
  ok(q("select count(*) from app.customers where phone='500000001'") === '1', 'customer is in the database');

  // something a cashier may not change stays on the device and does not block other saves
  const pid = run(ctx, 'D.p[0].id'), price = q(`select price from app.products where lid=${pid}`);
  run(ctx, 'D.p[0].price=1;D.fav=D.fav||{};D.fav[U.id]=[D.p[0].id];save()');
  ok(await settle(ctx), 'save finished');
  ok(q(`select price from app.products where lid=${pid}`) === price, 'cashier price edit not saved');
  ok(q("select count(*) from app.kv where key='fav'") === '1', 'favourites saved');

  // receipts cannot be edited, even by crafting a change
  run(ctx, '__sale.tot=0;save()');
  await sleep(400);
  ok(run(ctx, 'SVOK') === 0, 'editing a receipt is refused and shown as not saved');
  run(ctx, `__sale.tot=${q(`select total from app.sales where lid=${lid}`)};save()`);
  ok(await settle(ctx), 'reverting the edit clears the error');
  await run(ctx, 'SR.logout()');
  ok(run(ctx, 'U') === null, 'logged out');
}

// ---------------------------------------------------------------- admin
{
  const ctx = makeContext();
  await run(ctx, 'SR.boot()');
  await run(ctx, "SR.login('demo','admin','1234')");
  ok(run(ctx, 'U.type') === 'admin', 'admin logged in');
  ok(run(ctx, 'typeof D.p[0].cost') === 'number', 'admin receives product cost');
  ok(run(ctx, 'D.s.some(s=>s.id==' + q('select max(lid) from app.sales') + ')'), "admin sees the cashier's new receipt");
  run(ctx, 'D.p[0].price=99;save()');
  ok(await settle(ctx), 'price change saved');
  ok(q(`select price from app.products where lid=${run(ctx, 'D.p[0].id')}`) === '99', 'price is in the database');
  run(ctx, "D.us.push({id:D.n++,created:Date.now(),last:0,pw:'secret1',name:'ახალი',u:'kasa9',phone:'',role:'cashier',branch:'ბათუმი',active:1,perms:rdef('cashier')});save()");
  ok(await settle(ctx), 'new staff member saved');
  ok(q("select password_hash like '$2a$%' and must_change_password from app.app_users where username='kasa9'") === 't', 'password stored as bcrypt and must be changed');
  ok(run(ctx, "!('pw' in D.us.find(u=>u.u=='kasa9'))"), 'plain password removed from memory after saving');
  run(ctx, 'vD().on=1;save()');
  ok(await settle(ctx), 'VAT setting saved');
  ok(q("select value->>'on' from app.kv where key='vat'") === '1', 'VAT setting is in the database');
  await run(ctx, "SR.ensure('emp')");
  ok(run(ctx, 'Array.isArray(D.lg)'), 'change log loaded when its screen opens');
  // a product moved to the archive (p -> dp) in one save
  run(ctx, 'const x=D.p.pop();(D.dp=D.dp||[]).push(x);save()');
  ok(await settle(ctx), 'product archived');
  ok(q("select count(*) from app.products where coll='dp' and removed_at is null") === '1', 'archived product stored in dp');
  await run(ctx, 'SR.logout()');
}

// ---------------------------------------------------------------- the new staff member must change the temporary password
{
  const ctx = makeContext();
  await run(ctx, 'SR.boot()');
  await run(ctx, "SR.login('demo','kasa9','secret1')");
  ok(run(ctx, 'SR.me.user.must_change_password') === true, 'temporary password flagged at login');
  await run(ctx, "fetch(SR_CONFIG.url+'/rest/v1/rpc/sr_change_password',{method:'POST',headers:{Authorization:'Bearer '+JSON.parse(sessionStorage.getItem('sr_session')).t,'Content-Type':'application/json'},body:JSON.stringify({p_old:'secret1',p_new:'new-password-1'})})");
  ok(q("select must_change_password from app.app_users where username='kasa9'") === 'f', 'password changed');
  const ctx2 = makeContext();
  await run(ctx2, 'SR.boot()');
  let err = '';
  try { await run(ctx2, "SR.login('demo','kasa9','secret1')") } catch (e) { err = e.message }
  ok(err === 'invalid_credentials', 'old password no longer works');
}

console.log(failed ? `\n${failed} check(s) failed` : '\nall app e2e checks passed');
process.exit(failed ? 1 : 0);
