/* Smart Retail · Supabase data layer for the main app (web/index.html)
 *
 * The screens keep working on the in-memory object D exactly as in the prototype.
 * This file replaces localStorage with Supabase:
 *   - login: Edge Function "store-login" -> JWT kept in sessionStorage (12 hours)
 *   - load:  core collections at login, heavier ones when their screen opens, then only changes (sr_pull)
 *   - save:  every save() sends what changed since the last confirmed state, in one transaction (sr_push)
 *   - ids:   integer ids (receipt numbers etc.) come from blocks reserved on the server (sr_alloc_ids)
 *   - photos: base64 images are uploaded to Storage and replaced by their public URL
 * Super Admin view: the Super Admin page opens this page at "#sa" in a new tab and hands it a read-only
 *   store-admin token by postMessage (never in the URL). Everything loads as for the store admin;
 *   nothing is saved (the server refuses writes from that session too).
 * Offline: the whole working copy (data, baseline, the batch being sent, id block, session) is kept in
 *   IndexedDB ("sr-offline"). Without internet the till keeps selling; the changes wait in that copy and
 *   are sent when the connection returns, even after the page or the app was closed and reopened.
 *   Every batch carries an id (bid) so a batch whose answer was lost is never applied twice (stock changes
 *   are deltas): the server remembers batch ids (app.push_batches).
 */
(function () {
  const CFG = window.SR_CONFIG || {};
  const on = !!(CFG.url && CFG.anonKey) && !window.EMB;
  const COLLS = ['us', 'p', 'dp', 'c', 'sup', 'pu', 's', 'sh', 'cm', 'tr', 'ih', 'ex', 'lg', 'hold', 'padj', 'gln', 'sgl'];
  const NOT_KV = new Set([...COLLS, 'st', 'n', 'csl', 'csd', 'ak', 'kv']);
  // who may read and write what: mirrors app.colls / app.kv_write on the server (the server enforces it)
  const READ = { us: 'acw', p: 'acw', dp: 'aw', c: 'acw', sup: 'aw', pu: 'aw', s: 'acw', sh: 'ac', cm: 'ac', tr: 'acw',
    ih: 'aw', ex: 'a', lg: 'a', hold: 'ac', padj: 'acw', gln: 'a', sgl: 'a' };
  const WRITE = { us: 'a', p: 'aw', dp: 'aw', c: 'ac', sup: 'aw', pu: 'aw', s: 'ac', sh: 'ac', cm: 'ac', tr: 'acw',
    ih: 'aw', ex: 'a', lg: 'acw', hold: 'ac', padj: 'a', gln: 'acw', sgl: 'ac' };
  const KV_WRITE = { fav: 'acw', favu: 'acw', glc: 'acw', trn: 'acw', lgn: 'acw', sgp: 'acw', sgd: 'acw',
    is: 'aw', ic: 'aw', cats: 'aw', wrs: 'aw', wrx: 'aw', wrd: 'aw' };
  const CORE = ['us', 'p', 'dp', 'c', 's', 'sh', 'cm', 'tr', 'hold', 'padj', 'gln', 'st', 'kv'];
  const BY_VIEW = { buy: ['pu', 'sup'], sup: ['sup', 'pu'], prod: ['pu', 'sup'], trf: [], inv: ['ih'],
    stats: ['pu', 'sup', 'ex', 'sgl'], today: ['pu', 'ex'], emp: ['ex', 'lg', 'sgl', 'pu'], wr: ['ex', 'sgl', 'pu'] };
  const REFRESH_MS = 15000;
  const TOKEN_KEY = 'sr_session';

  const roleL = r => r === 'admin' ? 'a' : r === 'cashier' ? 'c' : 'w';
  let token = null, exp = 0, me = null, role = 'c';
  let snap = {}, snapSt = {}, snapKv = {}, loaded = new Set(), cursors = {}, fetchedAt = {};
  let pushing = false, again = false, pending = false, lastErr = '', idRefill = null, pendingExpiry = false, ro = false, roWarned = 0;
  let inflight = null;          // the batch being sent: { bid, sent } (kept until the server answers for sure)
  let netFailAt = 0, pendN = 0, pendS = 0, hadOffline = false, resuming = false;

  // ---------------------------------------------------------------- HTTP
  async function call(fn, args, timeoutMs) {
    const ac = new AbortController(), tm = setTimeout(() => ac.abort(), timeoutMs || 25000);
    let r, txt;
    try {
      r = await fetch(`${CFG.url}/rest/v1/rpc/${fn}`, {
        method: 'POST', signal: ac.signal,
        headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + (token || CFG.anonKey), 'Content-Type': 'application/json' },
        body: JSON.stringify(args || {})
      });
      txt = await r.text();
    } finally { clearTimeout(tm) }
    netFailAt = 0;
    let j = null;
    try { j = txt ? JSON.parse(txt) : null } catch (_) { if (r.ok) throw new TypeError('bad response') }   // a gateway page, not our answer
    if (!r.ok) {
      const e = new Error((j && (j.message || j.error)) || ('HTTP ' + r.status));
      e.status = r.status; e.code = j && j.code;
      if (/SESSION_(EXPIRED|REQUIRED)|JWT expired|invalid JWT/i.test(e.message)) e.session = true;
      throw e;
    }
    return j;
  }
  const MSG = {
    invalid_credentials: 'არასწორი მონაცემები', too_many_attempts: 'ძალიან ბევრი მცდელობა. სცადე 15 წუთში',
    account_disabled: 'ანგარიში გამორთულია. მიმართე ადმინისტრატორს', store_suspended: 'მაღაზია შეჩერებულია. მიმართე მხარდაჭერას',
    STORE_RESTRICTED: 'მაღაზია შეზღუდულია: გაყიდვა დროებით დაბლოკილია', RECEIPTS_ARE_IMMUTABLE: 'ჩეკის შეცვლა შეუძლებელია',
    LAST_ADMIN: 'ბოლო ადმინისტრატორის შეცვლა შეუძლებელია', CANNOT_DEMOTE_SELF: 'საკუთარი როლის შეცვლა შეუძლებელია',
    PASSWORD_TOO_SHORT: 'პაროლი ძალიან მოკლეა', WRONG_PASSWORD: 'მიმდინარე პაროლი არასწორია',
    READ_ONLY: 'სუპერ ადმინის ნახვის რეჟიმი: ცვლილება არ ინახება', STORE_SUSPENDED: 'მაღაზია შეჩერებულია',
    NO_STORE_ADMIN: 'მაღაზიას აქტიური ადმინისტრატორი არ ჰყავს', PLATFORM_ADMIN_REQUIRED: 'საჭიროა სუპერ ადმინის შესვლა',
    MFA_REQUIRED: 'საჭიროა 2FA დადასტურება'
  };
  // no answer from the server (offline, timeout, bad gateway): the request may or may not have been applied
  const isNet = e => !!e && (e.name === 'TypeError' || e.name === 'AbortError' || (e.status >= 502 && e.status <= 504));
  const msg = e => {
    const m = String((e && e.message) || e || '');
    if (isNet(e)) return 'სერვერთან კავშირი ვერ დამყარდა. შეამოწმე ინტერნეტი';
    const k = Object.keys(MSG).find(k => m.includes(k));
    return k ? MSG[k] : m;
  };

  // ---------------------------------------------------------------- session
  function storeToken(t, e) { token = t; exp = e; try { sessionStorage.setItem(TOKEN_KEY, JSON.stringify({ t, e })) } catch (_) {} persistSoon(500); }
  function clearToken() { token = null; exp = 0; try { sessionStorage.removeItem(TOKEN_KEY) } catch (_) {} }

  async function login(shop, username, password) {
    const r = await fetch(`${CFG.url}/functions/v1/store-login`, {
      method: 'POST',
      headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + CFG.anonKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ shop, username, password })
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j.token) throw new Error(j.error || 'invalid_credentials');
    storeToken(j.token, j.exp);
    await start();
    if (me.user.must_change_password) changePassword(true, password);
  }

  async function start() {
    me = await call('sr_me');
    role = roleL(me.user.role);
    ro = !!me.read_only;
    if (Array.isArray(me.branches) && me.branches.length) { BR.length = 0; BR.push(...me.branches); }
    D = {}; snap = {}; snapSt = {}; snapKv = {}; loaded = new Set(); cursors = {}; fetchedAt = {}; inflight = null;
    // the core data and the receipt-number block are independent: ask for both at once
    await Promise.all([pull(CORE.filter(c => c === 'st' || c === 'kv' || READ[c].includes(role)), true), allocIds(true)]);
    window.srNormalize && srNormalize();          // defaults the prototype added on startup
    rebase();                                     // ...but those defaults are not "changes"
    enter();
    annCheck(true);
    // then load every other screen's data in the background, so switching screens never waits
    (ensuring || Promise.resolve()).then(prefetch);
    persistSoon(1500);
  }
  // the signed-in user's screen (after a fresh start and after a restore from the offline copy)
  function enter() {
    const u = me.user;
    U = { store: me.store.name, u: u.u, id: u.id, name: u.name, branch: u.branch || '', role: u.role == 'cashier' ? 'pos' : 'dash',
          type: u.role, perms: u.perms || {} };
    view = 0; skB = null; if (u.branch && u.role != 'cashier') ib = u.branch;
    if (U.role == 'pos') { txp = 1; txq = ''; txm = '' }
    LPG = false;
    if (me.store.status === 'restricted') toast('მაღაზია შეზღუდულია: გაყიდვა დაბლოკილია, ნახვა და ექსპორტი მუშაობს', 1);
    render();
    roBar();
    chip();
  }

  // ---------------------------------------------------------------- Super Admin view (read-only)
  function roBar() {
    let b = document.getElementById('srro');
    if (!ro) { if (b) b.remove(); return }
    if (b) return;
    b = el(`<div id="srro" role="status" style="position:fixed;left:16px;bottom:16px;z-index:9999;display:flex;gap:10px;align-items:center;max-width:calc(100vw - 32px);padding:9px 12px 9px 14px;border-radius:12px;background:#eef3ff;border:1px solid #3b5bdb;color:#2b44a8;font:600 13px Inter,'Noto Sans Georgian',sans-serif;box-shadow:0 10px 28px #2a232633"><span>👁 სუპერ ადმინის ნახვა · ${esc(me.store.name)} · ცვლილებები არ ინახება</span><button style="padding:5px 10px;border:1px solid #3b5bdb;border-radius:8px;background:#fff;color:#2b44a8;font-weight:700;cursor:pointer">დახურვა</button></div>`);
    if (!b) return;
    b.querySelector('button').onclick = () => logout();
    document.body.appendChild(b);
  }
  // the opener (Super Admin tab) answers "sa-ready" with the token
  function receiveViewToken() {
    return new Promise(res => {
      const done = v => { window.removeEventListener('message', h); clearTimeout(t); res(v) };
      const h = e => {
        if (e.source !== window.opener || e.origin !== location.origin || !e.data) return;
        if (e.data.sr === 'sa-token' || e.data.sr === 'sa-error') done(e.data);
      };
      const t = setTimeout(() => done(null), 30000);
      window.addEventListener('message', h);
      try { window.opener.postMessage({ sr: 'sa-ready' }, location.origin) } catch (_) { done(null) }
    });
  }

  async function boot() {
    let s = null;
    try { s = JSON.parse(sessionStorage.getItem(TOKEN_KEY) || 'null') } catch (_) {}
    D = { p: [], dp: [], c: [], s: [], st: {}, us: [], sh: [], cm: [], pu: [], sup: [], cats: [] };
    if (location.hash === '#sa' && on) {
      history.replaceState(null, '', location.pathname + location.search);
      // window.open copies the opener's sessionStorage: drop the Super Admin's own sign-in from this tab
      try { Object.keys(sessionStorage).filter(k => k.startsWith('sb-')).forEach(k => sessionStorage.removeItem(k)) } catch (_) {}
      if (window.opener) {
        document.getElementById('app').innerHTML = loadingHtml();
        const got = await receiveViewToken();
        if (got && got.t) {
          storeToken(got.t, got.e);
          try { await start(); return } catch (e) { clearToken(); render(); toast(msg(e), 1); return }
        }
        render(); toast(got && got.m ? 'ვერ გაიხსნა: ' + got.m : 'მაღაზია ვერ გაიხსნა. სცადე ხელახლა სუპერ ადმინიდან', 1); return;
      }
    }
    // the offline copy from the last session on this device
    let rec = on && idbOk ? await cacheGet() : null;
    if (rec && !rec.pend && Date.now() - rec.savedAt > STALE_MS) { cacheDrop(); rec = null }
    if (rec && (rec.pend || navigator.onLine === false || window.PGO)) {   // PGO: opened by tapping a push notification, show the saved copy at once
      // unsent changes (or no internet): continue from the copy, send/refresh when possible
      try { restore(rec, s); return } catch (e) { console.error('[sr] restore failed', e); if (!rec.pend) rec = null }
    }
    const fromCopy = !(s && s.t) && rec && rec.token ? { t: rec.token, e: rec.exp } : null;   // app reopened: same sign-in, no password
    const tk = s && s.t ? s : fromCopy;
    if (tk && tk.e * 1000 > Date.now() + 60000) {
      token = tk.t; exp = tk.e;
      try { await start(); return } catch (e) { if (isNet(e) && rec) { try { restore(rec, tk); return } catch (_) {} } clearToken() }
    }
    render();
  }

  // ---------------------------------------------------------------- offline copy (IndexedDB)
  // One record "cur": everything needed to carry on without the server. The baseline (snap) is stored as the
  // difference from D, so the copy is about the size of the data itself.
  const STALE_MS = 24 * 3600 * 1000;        // an idle copy with nothing unsent is dropped after a day
  let idbOk = typeof indexedDB !== 'undefined', idbP = null, pTimer = 0, persisting = null;
  const idb = () => idbP || (idbP = new Promise((res, rej) => {
    const r = indexedDB.open('sr-offline', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('sess');
    r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
  }));
  const idbDo = (mode, f) => idb().then(db => new Promise((res, rej) => {
    const tx = db.transaction('sess', mode); let out;
    out = f(tx.objectStore('sess'));
    tx.oncomplete = () => res(out && 'result' in out ? out.result : undefined); tx.onerror = tx.onabort = () => rej(tx.error);
  }));
  const cacheGet = () => idbDo('readonly', s => s.get('cur')).catch(() => null);
  const cacheDrop = () => { clearTimeout(pTimer); idbDo('readwrite', s => s.delete('cur')).catch(() => {}) };

  function snapshot() {
    const over = {}, news = {}, gone = {};
    for (const c of COLLS) {
      const arr = Array.isArray(D[c]) ? D[c] : [], s = snap[c] || new Map(), seen = new Set();
      for (const x of arr) {
        if (!x || typeof x !== 'object' || !x._k) continue;
        seen.add(x._k);
        const sj = s.get(x._k);
        if (sj === undefined) (news[c] = news[c] || []).push(x._k);
        else if (sj !== JSON.stringify(x)) (over[c] = over[c] || {})[x._k] = sj;
      }
      for (const [k, sj] of s) if (!seen.has(k)) (gone[c] = gone[c] || {})[k] = sj;
    }
    return { v: 1, savedAt: Date.now(), token, exp, me, role, D: JSON.stringify(D), over, news, gone, snapSt, snapKv, cursors,
      loaded: [...loaded], blk: { ...blk }, inflight };
  }
  function persistSoon(ms) {
    if (!on || !U || ro || !idbOk) return;
    clearTimeout(pTimer); pTimer = setTimeout(persistNow, ms == null ? 400 : ms);
  }
  // resolves when the copy is written (a sale is "kept on this device" only after that)
  function persistNow() {
    if (!on || !U || !me || ro || !idbOk) return Promise.resolve();
    clearTimeout(pTimer);
    if (persisting) return persisting.then(persistNow);
    const d = diff();
    pendS = ((inflight && inflight.sent.up.s) || []).length + (d.up.s || []).length;
    pendN = pendS + (inflight ? Object.keys(inflight.sent.up).filter(c => c !== 's').length : 0)
      + Object.keys(d.up).filter(c => c !== 's').length + Object.keys(d.rm).length + Object.keys(d.kv).length;
    const rec = snapshot(); rec.pend = !!inflight || !empty(d);
    chip();
    persisting = idbDo('readwrite', s => s.put(rec, 'cur'))
      .catch(e => { idbOk = false; console.error('[sr] offline copy not saved', e); chip() })
      .finally(() => { persisting = null });
    return persisting;
  }

  function restore(rec, s) {
    if (!rec.me || !rec.D || rec.v !== 1) throw new Error('bad copy');
    const t = s && s.t && s.e * 1000 > rec.exp * 1000 ? s : { t: rec.token, e: rec.exp };
    token = t.t; exp = t.e; me = rec.me; role = rec.role; ro = false;
    if (Array.isArray(me.branches) && me.branches.length) { BR.length = 0; BR.push(...me.branches); }
    D = JSON.parse(rec.D); snap = {};
    for (const c of COLLS) {
      if (!Array.isArray(D[c])) continue;
      const m = new Map(), nw = new Set((rec.news || {})[c] || []), ov = (rec.over || {})[c] || {};
      for (const x of D[c]) if (x && x._k && !nw.has(x._k)) m.set(x._k, ov[x._k] !== undefined ? ov[x._k] : JSON.stringify(x));
      for (const [k, sj] of Object.entries((rec.gone || {})[c] || {})) m.set(k, sj);
      snap[c] = m;
    }
    snapSt = rec.snapSt || {}; snapKv = rec.snapKv || {}; cursors = rec.cursors || {}; fetchedAt = {};
    loaded = new Set(rec.loaded || []); blk.next = rec.blk.next; blk.end = rec.blk.end; blk.queued = rec.blk.queued; inflight = rec.inflight || null;
    defineN();
    enter();
    annCheck(true);
    (ensuring || Promise.resolve()).then(prefetch);
    resume();
  }

  // back online (or just opened with unsent changes): send what waits, then catch up with the other devices
  async function resume() {
    if (!on || !U || ro || resuming || navigator.onLine === false) return;
    resuming = true;
    try {
      if (!token || exp * 1000 < Date.now() + 30000) { expired(); return }     // sends and refreshes after the password
      const n = pendS;
      pending = true; if (!pushing) await push();
      if (inflight || dirty()) return;                    // still unsent: keep the copy, try again later
      const fresh = await call('sr_me');
      me = fresh; ro = !!fresh.read_only; role = roleL(fresh.user.role);
      if (blk.queued == null && blk.end - blk.next < REFILL && !idRefill) await allocIds(false);
      await pull([...new Set([...CORE.filter(c => c === 'st' || c === 'kv' || READ[c].includes(role)), ...loaded])], true);
      if (!document.querySelector('#md .box') && !isTyping()) render();
      if (hadOffline) { hadOffline = false; toast(n ? '✓ ინტერნეტი დაბრუნდა, ოფლაინში გაყიდული ჩეკები გაიგზავნა' : '✓ ინტერნეტი დაბრუნდა') }
      persistSoon(1000);
    } catch (e) { if (e && e.session) expired(); else if (!isNet(e)) console.error('[sr] resume', e); else netFailAt = Date.now() }
    finally { resuming = false; chip() }
  }

  // small status mark: offline, and how much waits to be sent
  function chip() {
    if (!on || !U || ro) { const o = document.getElementById('srof'); if (o) o.remove(); return }
    const off = navigator.onLine === false || Date.now() - netFailAt < 15000;
    if (off) hadOffline = true;
    let b = document.getElementById('srof');
    if (!off && !(pendN && !idbOk)) { if (b) b.remove(); return }
    if (!b) { b = el('<div id="srof" role="status" style="position:fixed;left:12px;bottom:12px;z-index:9998;max-width:calc(100vw - 24px);padding:7px 12px;border-radius:999px;background:#fff8e6;border:1px solid #e3c06a;color:#8a600a;font:600 12.5px Inter,\'Noto Sans Georgian\',sans-serif;box-shadow:0 6px 18px #2a232626;pointer-events:none"></div>'); if (!b) return; document.body.appendChild(b) }
    b.textContent = '📴 ინტერნეტი არ არის · მუშაობა გრძელდება' + (pendN ? ` · გასაგზავნი: ${pendS ? pendS + ' ჩეკი' : pendN + ' ცვლილება'}` : '')
      + (idbOk ? '' : ' · ⚠ მოწყობილობაში ვერ ინახება, გვერდი არ დახურო');
  }

  async function logout() {
    if (ro) { try { await call('sr_logout') } catch (_) {} clearToken(); window.close(); location.reload(); return }
    if ((dirty() || inflight) && !await confirmBox('გაუგზავნელი ცვლილებები (ჩეკები) დაიკარგება. მაინც გასვლა?')) return;
    try { await call('sr_logout') } catch (_) {}
    clearToken(); U = null; cart = []; D = { p: [], dp: [], c: [], s: [], st: {}, us: [], sh: [], cm: [], pu: [], sup: [], cats: [] };
    snap = {}; snapSt = {}; snapKv = {}; loaded = new Set(); inflight = null; pendN = pendS = 0;
    cacheDrop(); chip();
    annReset();
    render();
  }

  // ---------------------------------------------------------------- loading
  async function pull(colls, long) {
    let todo = colls.slice();
    while (todo.length) {
      const res = await call('sr_pull', { p_colls: todo, p_cursors: cursors }, long ? 90000 : 40000);
      const more = [];
      for (const c of todo) {
        const r = res[c];
        loaded.add(c); fetchedAt[c] = Date.now();
        if (!r) { if (COLLS.includes(c) && !D[c]) D[c] = []; continue; }
        if (r.cursor) cursors[c] = r.cursor;
        if (c === 'st') {
          D.st = D.st || {};
          for (const [k, q] of Object.entries(r.rows || {})) { D.st[k] = +q; snapSt[k] = +q; }
        } else if (c === 'kv') {
          for (const [k, v] of Object.entries(r.rows || {})) { D[k] = v; snapKv[k] = JSON.stringify(v); }
        } else {
          const arr = D[c] = D[c] || [], idx = new Map(arr.map((x, i) => [x._k, i]));
          snap[c] = snap[c] || new Map();
          for (const doc of r.rows || []) {
            const i = idx.get(doc._k);
            if (i == null) { idx.set(doc._k, arr.length); arr.push(doc) } else Object.keys(arr[i]).forEach(k => delete arr[i][k]), Object.assign(arr[i], doc);
            snap[c].set(doc._k, JSON.stringify(doc));
          }
          if (r.rm && r.rm.length) {
            const gone = new Set(r.rm);
            D[c] = arr.filter(x => !gone.has(x._k)); gone.forEach(k => snap[c].delete(k));
          }
          if (r.more) more.push(c);
        }
      }
      todo = more;
    }
    persistSoon(2500);
  }

  const readable = c => READ[c] && READ[c].includes(role);
  const needFor = v => [...new Set([...(BY_VIEW[v] || [])])].filter(readable);
  function ready(v) { return !on || !U || needFor(v).every(c => loaded.has(c)) }
  // one load at a time; a screen opened meanwhile waits for it (it usually brings that screen's data too)
  let ensuring = null, loadErr = '';
  function load(want) {
    if (ensuring) return ensuring;
    if (!want.length) return Promise.resolve();
    ensuring = pull(want).then(() => { loadErr = '' })
      .catch(e => { loadErr = msg(e) || 'error'; if (e && e.session) onError(e); else console.error('[sr]', e) })
      // only what was loaded now becomes baseline (edits already pending in loaded collections stay pending)
      .finally(() => { ensuring = null; rebaseColls(want.filter(c => loaded.has(c))) });
    return ensuring;
  }
  const ensure = v => load(needFor(v).filter(c => !loaded.has(c)));
  // waits its turn behind a screen's own load, then brings whatever is still missing
  function prefetch() {
    if (!on || !U || !token || loadErr) return;
    if (ensuring) { ensuring.then(prefetch); return }
    load([...new Set(Object.values(BY_VIEW).flat())].filter(c => readable(c) && !loaded.has(c)));
  }
  function retryLoad() { loadErr = ''; render() }
  // background refresh of what the current screen shows (changes made on other devices)
  let refreshing = false;
  function touch(v) {
    if (!on || !U || refreshing || pushing || pending) return;
    const list = [...CORE, ...needFor(v)].filter(c => (c === 'st' || c === 'kv' || READ[c].includes(role)) && loaded.has(c)
      && Date.now() - (fetchedAt[c] || 0) > REFRESH_MS);
    if (!list.length) return;
    refreshing = true;
    const before = JSON.stringify(cursors);
    pull([...new Set(list)]).then(() => {
      if (JSON.stringify(cursors) !== before && !document.querySelector('#md .box') && !isTyping()) render();
    }).catch(() => {}).finally(() => { refreshing = false });
  }
  const isTyping = () => { const a = document.activeElement; return a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA') };
  const mainLoadingHtml = () => loadErr
    ? `<p class="m" style="text-align:center;padding:60px 0">მონაცემები ვერ ჩაიტვირთა: ${esc(loadErr)}<br><button style="margin-top:12px" onclick="SR.retryLoad()">ხელახლა</button></p>`
    : '<p class="m" style="text-align:center;padding:60px 0">მონაცემები იტვირთება…</p>';
  const loadingHtml = () => `<div class="lgp"><section class="lg" style="text-align:center"><h2 class="lgl">${typeof SRL !== 'undefined' ? SRL : 'Smart Retail'}</h2><p class="m">მონაცემები იტვირთება…</p></section></div>`;

  // ---------------------------------------------------------------- id blocks (D.n)
  // a till that sells offline all day must not run out of numbers: big blocks, refilled early
  const BLOCK = 1000, REFILL = 400;
  const blk = { next: 0, end: 0, queued: null };
  async function allocIds(first) {
    const start = await call('sr_alloc_ids', { p_count: BLOCK });
    if (first) { blk.next = start; blk.end = start + BLOCK; blk.queued = null; defineN(); } else { blk.queued = start; blk.warned = 0; persistSoon(); }
  }
  function defineN() {
    Object.defineProperty(D, 'n', {
      configurable: true, enumerable: false,
      get() { return blk.next },
      set(v) {
        blk.next = v;
        if (blk.next >= blk.end && blk.queued != null) { blk.next = blk.queued; blk.end = blk.queued + BLOCK; blk.queued = null; }
        if (blk.end - blk.next < REFILL && blk.queued == null && !idRefill && navigator.onLine !== false)
          idRefill = allocIds(false).catch(() => {}).finally(() => { idRefill = null });
        if (blk.end - blk.next < 30 && blk.queued == null && !blk.warned) { blk.warned = 1; toast('ნომრების მარაგი იწურება. დაუკავშირდი ინტერნეტს', 1) }
      }
    });
  }

  // ---------------------------------------------------------------- saving
  function uuid() { return crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c == 'x' ? r : (r & 3 | 8)).toString(16) }) }
  const r6 = v => Math.round(v * 1e6) / 1e6;

  function diff() {
    const up = {}, upJ = {}, rm = {}, st = {}, kv = {}, local = [];
    for (const c of COLLS) {
      const arr = Array.isArray(D[c]) ? D[c] : [];
      const s = snap[c] || new Map(), seen = new Set();
      for (const x of arr) {
        if (!x || typeof x !== 'object') continue;
        if (!x._k) x._k = uuid();
        seen.add(x._k);
        const j = JSON.stringify(x);
        if (s.get(x._k) !== j) { (up[c] = up[c] || []).push(x); (upJ[c] = upJ[c] || []).push(j); }
      }
      for (const k of s.keys()) if (!seen.has(k)) (rm[c] = rm[c] || []).push(k);
      if ((up[c] || rm[c]) && !WRITE[c].includes(role)) { local.push(c); delete up[c]; delete upJ[c]; delete rm[c]; }
    }
    for (const k of Object.keys(D.st || {})) { const d = r6((+D.st[k] || 0) - (snapSt[k] || 0)); if (d) st[k] = d; }
    const keys = new Set([...Object.keys(D).filter(k => !NOT_KV.has(k)), ...Object.keys(snapKv)]);
    for (const k of keys) {
      if (NOT_KV.has(k)) continue;
      const j = D[k] === undefined ? undefined : JSON.stringify(D[k]);
      if (snapKv[k] !== j) {
        if (role === 'a' || (KV_WRITE[k] || '').includes(role)) kv[k] = D[k] === undefined ? null : D[k];
        else local.push(k);
      }
    }
    return { up, upJ, rm, st, kv, local };
  }
  const empty = d => !Object.keys(d.up).length && !Object.keys(d.rm).length && !Object.keys(d.st).length && !Object.keys(d.kv).length;
  function dirty() { return on && U && !ro && !empty(diff()) }

  // after a confirmed push (or a load), the current state becomes the baseline
  function rebase() { rebaseColls(COLLS); snapSt = Object.fromEntries(Object.entries(D.st || {}).map(([k, v]) => [k, +v || 0]));
    snapKv = {}; Object.keys(D).forEach(k => { if (!NOT_KV.has(k) && D[k] !== undefined) snapKv[k] = JSON.stringify(D[k]) }); }
  function rebaseColls(list) {
    for (const c of list) { if (!Array.isArray(D[c])) continue; const m = snap[c] = new Map();
      for (const x of D[c]) { if (!x._k) x._k = uuid(); m.set(x._k, JSON.stringify(x)); } }
  }

  // Photos are uploaded to Storage before the batch goes out. A photo that cannot be uploaded must not block
  // every other change: that product is sent without the photo, the photo stays on this device, and the
  // reason is reported (the server's own message is included so the cause can be found).
  async function uploadImages(up, upJ) {
    const failed = [];
    for (const c of ['p', 'dp']) {
      const list = up[c] || [];
      for (let i = 0; i < list.length; i++) {
        const x = list[i];
        if (typeof x.img !== 'string' || !x.img.startsWith('data:image/')) continue;
        try {
          const blob = await (await fetch(x.img)).blob();
          const ext = (blob.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg');
          const path = `${me.store.id}/${x._k}-${Date.now().toString(36)}.${ext}`;
          const r = await fetch(`${CFG.url}/storage/v1/object/product-images/${path}`, {
            method: 'POST', headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + token, 'Content-Type': blob.type, 'x-upsert': 'true' }, body: blob
          });
          if (!r.ok) {
            let why = ''; try { why = (await r.text()).slice(0, 160) } catch (_) {}
            const e = new Error('სურათი ვერ აიტვირთა (' + r.status + ')' + (why ? ': ' + why : '')); e.http = r.status; throw e;
          }
          x.img = `${CFG.url}/storage/v1/object/public/product-images/${path}`;
        } catch (e) {
          if (isNet(e) && !e.http) throw e;             // no connection: keep everything pending, retry later
          console.error('[sr] photo upload failed', x.code, e);
          const clone = Object.assign({}, x, { img: '' });
          list[i] = clone; if (upJ && upJ[c]) upJ[c][i] = JSON.stringify(clone);
          failed.push({ c, k: x._k, live: x, msg: e.message });
        }
      }
    }
    return failed;
  }

  function save() {
    if (ro) { if (Date.now() - roWarned > 8000) { roWarned = Date.now(); toast('სუპერ ადმინის ნახვის რეჟიმი: ცვლილება არ შეინახება', 1) } return }
    SVOK = navigator.onLine === false ? 0 : 1;
    pending = true;
    persistSoon(150);                // kept on this device at once, whatever happens to the connection
    if (pushing) { again = true; return }
    push();
  }

  let photoFail = [];
  async function push() {
    if (!U || !token) return;
    pushing = true;
    try {
      do {
        again = false;
        if (navigator.onLine === false) throw new TypeError('offline');
        if (!inflight) {
          const d = diff();
          if (d.local.length) console.info('[sr] kept on this device only (no permission to save):', d.local.join(', '));
          if (empty(d)) { markLocalAsBaseline(d.local); break; }
          photoFail = await uploadImages(d.up, d.upJ);
          // JSON as sent is captured now: edits made while the request is in flight stay pending.
          // The batch (with its id) is written to the offline copy first: if the page dies mid-request,
          // the same batch is sent again with the same id and the server applies it only once.
          inflight = { bid: uuid(), sent: { up: d.up, upJ: d.upJ, rm: d.rm, st: d.st, kv: d.kv } };
          await persistNow();
        }
        const sent = inflight.sent;
        let res;
        try { res = await call('sr_push', { p: { bid: inflight.bid, up: sent.up, rm: sent.rm, st: sent.st, kv: sent.kv } }, 45000) }
        catch (e) { if (!isNet(e)) inflight = null; throw e }      // a real refusal changed nothing; no answer: the same batch is retried
        confirm(sent); inflight = null;
        if (photoFail.length) {                         // the photo stays on this device only; do not keep the batch dirty forever
          for (const f of photoFail) { const m = snap[f.c] = snap[f.c] || new Map(); m.set(f.k, JSON.stringify(f.live)); }
          toast('ფოტო ვერ აიტვირთა და მხოლოდ ამ მოწყობილობაზეა (' + (photoFail[0].live.code || '') + '). ' + photoFail[0].msg, true);
          photoFail = [];
        }
        // server-side corrections (cost of goods on receipts) and sanitized user records
        for (const doc of (res.patched && res.patched.s) || []) {
          const x = (D.s || []).find(y => y._k === doc._k); if (x) { Object.assign(x, doc); (snap.s = snap.s || new Map()).set(x._k, JSON.stringify(x)); }
        }
        for (const u of res.users || []) {
          const x = (D.us || []).find(y => y._k === u._k); if (x) { delete x.pw; Object.assign(x, u); (snap.us = snap.us || new Map()).set(x._k, JSON.stringify(x)); }
        }
        markLocalAsBaseline(diff().local);
        persistSoon(300);
      } while (again || inflight);
      pending = false;
      setSaved(true);
    } catch (e) {
      onError(e);
    } finally {
      pushing = false;
    }
  }
  // move exactly what was sent into the baseline (changes made meanwhile stay pending)
  function confirm(sent) {
    for (const [c, list] of Object.entries(sent.up)) { const m = snap[c] = snap[c] || new Map(); list.forEach((x, i) => m.set(x._k, sent.upJ[c][i])); }
    for (const [c, list] of Object.entries(sent.rm)) { const m = snap[c]; if (m) list.forEach(k => m.delete(k)); }
    for (const [k, d] of Object.entries(sent.st)) snapSt[k] = r6((snapSt[k] || 0) + d);
    for (const [k, v] of Object.entries(sent.kv)) { if (v === null) delete snapKv[k]; else snapKv[k] = JSON.stringify(v); }
  }
  function markLocalAsBaseline(keys) {
    for (const k of keys) {
      if (COLLS.includes(k)) rebaseColls([k]);
      else if (D[k] === undefined) delete snapKv[k]; else snapKv[k] = JSON.stringify(D[k]);
    }
  }

  function setSaved(ok, why, quiet) {
    SVOK = ok ? 1 : 0;
    lastErr = ok ? '' : why || '';
    try {
      if (typeof PSV !== 'undefined' && PSV) { if (ok) { PSV.ok = 1; UNS.clear() } else if (PSV.ok) { PSV.ok = 0; UNS.add(PSV.id) } PSV.t = Date.now(); psvUp() }
    } catch (_) {}
    banner(ok || quiet ? '' : why);
    if (ok) { pendN = pendS = 0; persistSoon(200); }
    chip();
  }
  function onError(e) {
    console.error('[sr]', e);
    if (e && e.session && ro) { clearToken(); toast('ნახვის სესია დასრულდა. გახსენი ხელახლა სუპერ ადმინიდან', 1); return; }
    if (e && e.session) { expired(); setSaved(false, 'სესია დასრულდა'); return; }
    // no connection: nothing is lost, the changes wait in the offline copy and go out when the server answers
    if (isNet(e)) { netFailAt = Date.now(); setSaved(false, msg(e), true); persistSoon(100); return; }
    setSaved(false, msg(e));
  }

  // ---------------------------------------------------------------- UI helpers (no dependency on app code)
  function el(html) { const d = document.createElement('div'); d.innerHTML = html; return d.firstElementChild }
  function banner(text) {
    let b = document.getElementById('srbn');
    if (!text) { if (b) b.remove(); return }
    if (!b) { b = el('<div id="srbn" role="alert" style="position:fixed;left:50%;bottom:18px;transform:translateX(-50%);z-index:10000;display:flex;gap:10px;align-items:center;max-width:calc(100vw - 32px);padding:10px 14px;border-radius:12px;background:#fdeceb;border:1px solid #c23b3b;color:#c23b3b;font:600 14px Inter,\'Noto Sans Georgian\',sans-serif;box-shadow:0 10px 28px #2a232633"></div>'); if (!b) return; document.body.appendChild(b) }
    b.innerHTML = `<span>⚠ ცვლილება სერვერზე ვერ შეინახა: ${esc(text)}</span><button style="padding:6px 12px;border:1px solid #c23b3b;border-radius:8px;background:#fff;color:#c23b3b;font-weight:700;cursor:pointer">ხელახლა</button>`;
    b.querySelector('button').onclick = () => save();
  }
  function toast(text, warn) {
    const t = el(`<div style="position:fixed;right:18px;top:18px;z-index:10001;max-width:360px;padding:11px 16px;border-radius:12px;background:${warn ? '#fff8e6' : '#2a2326'};color:${warn ? '#8a600a' : '#fff'};border:1px solid ${warn ? '#f1dfae' : '#2a2326'};font:500 14px Inter,'Noto Sans Georgian',sans-serif;box-shadow:0 10px 28px #2a232640"></div>`);
    if (!t) return; t.textContent = text; document.body.appendChild(t); setTimeout(() => t.remove(), 5000);
  }
  function confirmBox(text) {
    return new Promise(res => {
      modal(`<div style="min-width:min(360px,84vw);display:flex;flex-direction:column;gap:10px"><p style="margin:0">${esc(text)}</p><button class="dl" id="srcy">დიახ</button></div>`);
      document.getElementById('srcy').onclick = () => { modal(); res(true) };
      const m = document.getElementById('md'); const obs = new MutationObserver(() => { if (m.style.display === 'none') { obs.disconnect(); res(false) } }); obs.observe(m, { attributes: true });
    });
  }

  // session expired while working: sign in again without losing what is on screen
  function expired() {
    if (pendingExpiry) return; pendingExpiry = true;
    clearToken();
    modal(`<div style="min-width:min(360px,84vw);display:flex;flex-direction:column;gap:10px"><h3 style="margin:0">სესია დასრულდა</h3>
      <p style="margin:0" class="m">შეიყვანე პაროლი ხელახლა. შეუნახავი ცვლილებები გაიგზავნება შესვლისთანავე.</p>
      <input id="srrp" type="password" placeholder="პაროლი" autocomplete="current-password"><small id="srre" style="color:#c23b3b"></small>
      <button class="pri" id="srrb">შესვლა</button></div>`);
    const go = async () => {
      const e = document.getElementById('srre');
      try {
        const r = await fetch(`${CFG.url}/functions/v1/store-login`, { method: 'POST',
          headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + CFG.anonKey, 'Content-Type': 'application/json' },
          body: JSON.stringify({ shop: me.store.slug, username: me.user.u, password: document.getElementById('srrp').value }) });
        const j = await r.json().catch(() => ({}));
        if (!r.ok || !j.token) throw new Error(j.error || 'invalid_credentials');
        storeToken(j.token, j.exp); pendingExpiry = false; modal(); resume();
      } catch (x) { e.textContent = msg(x) }
    };
    if (!document.getElementById('srrb')) return;
    document.getElementById('srrb').onclick = go;
    document.getElementById('srrp').onkeydown = ev => { if (ev.key === 'Enter') go() };
  }

  function changePassword(forced, oldPw) {
    modal(`<div style="min-width:min(380px,84vw);display:flex;flex-direction:column;gap:10px"><h3 style="margin:0">${forced ? 'შეცვალე დროებითი პაროლი' : 'პაროლის შეცვლა'}</h3>
      ${forced ? '<p class="m" style="margin:0">ეს პაროლი ადმინისტრატორმა მოგცა. გასაგრძელებლად შექმენი საკუთარი, მინიმუმ 8 სიმბოლო.</p>' : '<input id="srpo" type="password" placeholder="მიმდინარე პაროლი" autocomplete="current-password">'}
      <input id="srp1" type="password" placeholder="ახალი პაროლი (მინ. 8)" autocomplete="new-password"><input id="srp2" type="password" placeholder="გაიმეორე ახალი პაროლი" autocomplete="new-password">
      <small id="srpe" style="color:#c23b3b"></small><button class="pri" id="srpb">შენახვა</button></div>`);
    const btn = document.getElementById('srpb'); if (!btn) return;
    btn.onclick = async () => {
      const a = document.getElementById('srp1').value, b = document.getElementById('srp2').value, e = document.getElementById('srpe');
      if (a.length < 8) { e.textContent = 'მინიმუმ 8 სიმბოლო'; return }
      if (a !== b) { e.textContent = 'პაროლები არ ემთხვევა'; return }
      try { await call('sr_change_password', { p_old: forced ? oldPw : document.getElementById('srpo').value, p_new: a }); modal(); toast('პაროლი შეიცვალა') }
      catch (x) { e.textContent = msg(x) }
    };
    if (forced) { const m = document.querySelector('#md .box>button:last-child'); if (m) m.style.display = 'none' }
  }

  // Some screens change data right after calling save() (e.g. the daily-goal check after a sale);
  // pick those changes up a moment later instead of waiting for the next action.
  setInterval(() => {
    if (!on || !U || !token || pushing || resuming || navigator.onLine === false) return;
    if (Date.now() - netFailAt < 8000) return;          // the server did not answer a moment ago: do not hammer it
    if (inflight || dirty()) save(); else if (netFailAt) resume();
  }, 3000);

  window.addEventListener('beforeunload', e => { if (!idbOk && (dirty() || inflight)) { e.preventDefault(); e.returnValue = '' } });
  window.addEventListener('pagehide', () => { persistNow() });
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') persistNow() });
  window.addEventListener('online', () => { netFailAt = 0; chip(); resume() });
  window.addEventListener('offline', () => chip());

  // ---------------------------------------------------------------- push notifications (admins' phones)
  const pushOk = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  const u8 = b => { const p = '='.repeat((4 - b.length % 4) % 4), r = atob((b + p).replace(/-/g, '+').replace(/_/g, '/')); return Uint8Array.from(r, c => c.charCodeAt(0)) };
  async function pushReg() { return navigator.serviceWorker.ready }
  // 'unsupported' | 'ios-install' (iPhone: only works once added to the Home Screen) | 'denied' | 'on' | 'off'
  async function pushState() {
    if (!pushOk()) return /iphone|ipad/i.test(navigator.userAgent) && !navigator.standalone ? 'ios-install' : 'unsupported';
    if (Notification.permission === 'denied') return 'denied';
    try { return (await (await pushReg()).pushManager.getSubscription()) && Notification.permission === 'granted' ? 'on' : 'off' } catch (_) { return 'off' }
  }
  // must run from a tap (the browser only asks for permission on a user gesture); prefs = the device's chosen events
  async function pushEnable(prefs) {
    const key = await call('sr_push_key');
    if (!key) throw new Error('შეტყობინებები ჯერ არ არის ჩართული სერვერზე');
    if (await Notification.requestPermission() !== 'granted') throw new Error('შეტყობინებები ბრაუზერში დაბლოკილია');
    const reg = await pushReg();
    const sub = (await reg.pushManager.getSubscription()) || await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: u8(key) });
    await call('sr_push_subscribe', { p: { ...sub.toJSON(), ua: navigator.userAgent, ...(prefs ? { prefs } : {}) } });
  }
  async function pushDisable() {
    const sub = await (await pushReg()).pushManager.getSubscription();
    if (!sub) return;
    try { await call('sr_push_unsubscribe', { p_endpoint: sub.endpoint }) } catch (_) { }
    await sub.unsubscribe();
  }
  // this device's saved choices (null = none saved yet) and saving them
  async function pushPrefs() {
    const sub = await (await pushReg()).pushManager.getSubscription();
    return sub ? call('sr_push_prefs_get', { p_endpoint: sub.endpoint }) : null;
  }
  async function pushSetPrefs(p) {
    const sub = await (await pushReg()).pushManager.getSubscription();
    if (sub) await call('sr_push_prefs_set', { p_endpoint: sub.endpoint, p });
  }
  // a local notification, to check that this phone shows them
  async function pushTest() {
    await (await pushReg()).showNotification('Smart Retail', { body: 'შეტყობინებები მუშაობს ✓', tag: 'sr-test', icon: '../icons/icon-192-v2.png', badge: '../icons/icon-192-v2.png' });
  }

  // ---------------------------------------------------------------- announcements from Super Admin (pop-up for store admins)
  // The server decides who sees what (public.sr_announcements): admins only, once per person until confirmed.
  // "გასაგებია" confirms (public.sr_announcements_read); "მოგვიანებით" only hides it until the next sign-in.
  const ANN_TYPES = {
    'ინფორმაცია':        { c: '#2b5fb4', bg: '#eaf1fc', i: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 7.5v.01"/>' },
    'ტექნიკური სამუშაო': { c: '#b36b00', bg: '#fff3dc', i: '<path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L4 17v3h3l5.3-5.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4z"/>' },
    'ახალი ფუნქცია':    { c: '#1f7a4d', bg: '#e6f5ec', i: '<path d="M12 3l1.9 4.6 4.9.4-3.7 3.2 1.1 4.8L12 13.4 7.8 16l1.1-4.8L5.2 8l4.9-.4z"/>' },
    'გაფრთხილება':      { c: '#b3261e', bg: '#fdecea', i: '<path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17.2v.01"/>' }
  };
  let annList = [], annIdx = 0, annSeen = new Set(), annBusy = false, annAt = 0, annEl = null, annPrevFocus = null;

  function annStyle() {
    if (document.getElementById('sr-ann-css')) return;
    const st = document.createElement('style'); st.id = 'sr-ann-css';
    st.textContent = `
#sr-ann{position:fixed;inset:0;z-index:10001;display:flex;align-items:center;justify-content:center;padding:20px;background:rgba(32,22,26,.52);-webkit-backdrop-filter:blur(4px);backdrop-filter:blur(4px);font-family:Inter,'Noto Sans Georgian',system-ui,sans-serif;animation:sra-bg .22s ease-out}
#sr-ann *{box-sizing:border-box}
#sr-ann .sra-card{position:relative;width:100%;max-width:460px;max-height:min(86vh,640px);max-height:min(86dvh,640px);display:flex;flex-direction:column;background:#fff;color:#2a2326;border-radius:22px;box-shadow:0 30px 70px -18px rgba(42,35,38,.5),0 0 0 1px rgba(42,35,38,.05);overflow:hidden;animation:sra-in .3s cubic-bezier(.2,.9,.3,1.1)}
#sr-ann .sra-bar{height:5px;flex:none;background:var(--sra-c)}
#sr-ann .sra-body{padding:26px 26px 8px;overflow-y:auto;overscroll-behavior:contain;-webkit-overflow-scrolling:touch}
#sr-ann .sra-top{display:flex;align-items:center;gap:12px;margin-bottom:16px}
#sr-ann .sra-ic{flex:none;width:44px;height:44px;border-radius:14px;background:var(--sra-bg);color:var(--sra-c);display:flex;align-items:center;justify-content:center}
#sr-ann .sra-ic svg{width:23px;height:23px;fill:none;stroke:currentColor;stroke-width:1.9;stroke-linecap:round;stroke-linejoin:round}
#sr-ann .sra-tt{min-width:0;flex:1}
#sr-ann h2{margin:0;font-size:14px;line-height:1.3;font-weight:700;color:var(--sra-c)}
#sr-ann time{display:block;margin-top:2px;font-size:12.5px;color:#7d7176}
#sr-ann .sra-cnt{flex:none;font-size:12px;font-weight:600;color:#7d7176;background:#f5efed;border-radius:999px;padding:4px 10px}
#sr-ann .sra-tx{margin:0;font-size:16.5px;line-height:1.6;white-space:pre-line;overflow-wrap:anywhere;color:#2a2326}
#sr-ann .sra-ft{flex:none;padding:18px 26px 24px;display:flex;flex-direction:column;gap:10px;background:linear-gradient(#fff0,#fff 14px)}
#sr-ann .sra-dots{display:flex;justify-content:center;gap:6px;margin-bottom:2px}
#sr-ann .sra-dots i{width:6px;height:6px;border-radius:50%;background:#e2d8d5;transition:all .2s}
#sr-ann .sra-dots i.on{width:18px;border-radius:3px;background:var(--sra-c)}
#sr-ann button{font:inherit;cursor:pointer;-webkit-tap-highlight-color:transparent;touch-action:manipulation}
#sr-ann .sra-ok{width:100%;min-height:48px;border:0;border-radius:14px;background:#8c1c3a;color:#fff;font-size:16px;font-weight:700;letter-spacing:.01em;box-shadow:0 8px 18px -8px rgba(140,28,58,.7);transition:background .15s,transform .1s}
#sr-ann .sra-ok:hover{background:#6f1530}#sr-ann .sra-ok:active{transform:scale(.98)}
#sr-ann .sra-ok[disabled]{opacity:.7;cursor:progress}
#sr-ann .sra-later{width:100%;min-height:44px;border:0;border-radius:12px;background:transparent;color:#7d7176;font-size:14.5px;font-weight:600}
#sr-ann .sra-later:hover{background:#f5efed;color:#2a2326}
#sr-ann button:focus-visible{outline:3px solid #8c1c3a55;outline-offset:2px}
#sr-ann .sra-err{margin:0;font-size:13px;color:#b3261e;text-align:center}
@keyframes sra-bg{from{opacity:0}to{opacity:1}}
@keyframes sra-in{from{opacity:0;transform:translateY(14px) scale(.96)}to{opacity:1;transform:none}}
@keyframes sra-up{from{transform:translateY(100%)}to{transform:none}}
@keyframes sra-sw{from{opacity:0;transform:translateX(14px)}to{opacity:1;transform:none}}
#sr-ann .sra-sw{animation:sra-sw .22s ease-out}
@media(max-width:560px){
  #sr-ann{align-items:flex-end;padding:0}
  #sr-ann .sra-card{max-width:none;border-radius:24px 24px 0 0;max-height:88vh;max-height:88dvh;animation:sra-up .32s cubic-bezier(.2,.9,.3,1)}
  #sr-ann .sra-bar{height:0}
  #sr-ann .sra-card::before{content:"";flex:none;width:40px;height:4px;border-radius:2px;background:#e2d8d5;margin:10px auto 0}
  #sr-ann .sra-body{padding:18px 20px 6px}
  #sr-ann .sra-tx{font-size:16px}
  #sr-ann .sra-ft{padding:14px 20px calc(18px + env(safe-area-inset-bottom,0px))}
}
@media(max-height:480px) and (orientation:landscape){#sr-ann{align-items:center;padding:10px}#sr-ann .sra-card{max-width:560px;border-radius:18px;max-height:96vh;max-height:96dvh}#sr-ann .sra-card::before{display:none}}
@media(prefers-reduced-motion:reduce){#sr-ann,#sr-ann .sra-card,#sr-ann .sra-sw{animation:none!important}}
@media(prefers-contrast:more){#sr-ann .sra-card{box-shadow:0 0 0 2px #2a2326}}`;
    document.head.appendChild(st);
  }

  function annWhen(t) {
    const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}:\d{2})$/.exec(t || '');
    if (!m) return '';
    const n = new Date(), pad = x => String(x).padStart(2, '0');
    if (`${n.getFullYear()}-${pad(n.getMonth() + 1)}-${pad(n.getDate())}` === `${m[1]}-${m[2]}-${m[3]}`) return 'დღეს, ' + m[4];
    return `${m[3]}.${m[2]}.${m[1]}, ${m[4]}`;
  }

  function annPaint(first) {
    const a = annList[annIdx];
    if (!a || !annEl) return;
    const k = ANN_TYPES[a.type] || ANN_TYPES['ინფორმაცია'], n = annList.length, last = annIdx === n - 1;
    const card = annEl.querySelector('.sra-card');
    card.style.setProperty('--sra-c', k.c); card.style.setProperty('--sra-bg', k.bg);
    card.querySelector('.sra-ic').innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${k.i}</svg>`;
    card.querySelector('h2').textContent = a.type || 'ინფორმაცია';
    const tm = card.querySelector('time'); tm.textContent = annWhen(a.t);
    card.querySelector('.sra-tx').textContent = a.text;
    card.querySelector('.sra-cnt').hidden = n < 2; card.querySelector('.sra-cnt').textContent = (annIdx + 1) + ' / ' + n;
    const dots = card.querySelector('.sra-dots'); dots.hidden = n < 2;
    dots.innerHTML = n < 2 ? '' : annList.map((_, i) => `<i class="${i === annIdx ? 'on' : ''}"></i>`).join('');
    card.querySelector('.sra-ok').textContent = 'გასაგებია';
    card.querySelector('.sra-later').textContent = last ? 'მოგვიანებით' : 'დანარჩენის გამოტოვება';
    card.querySelector('.sra-err').textContent = '';
    card.querySelector('.sra-body').scrollTop = 0;
    if (!first) { const b = card.querySelector('.sra-body'); b.classList.remove('sra-sw'); void b.offsetWidth; b.classList.add('sra-sw') }
    annEl.setAttribute('aria-label', 'განცხადება: ' + (a.type || ''));
  }

  function annClose() {
    if (!annEl) return;
    const e = annEl; annEl = null; annList = []; annIdx = 0;
    document.removeEventListener('keydown', annKey, true);
    e.style.transition = 'opacity .16s'; e.style.opacity = '0';
    setTimeout(() => e.remove(), 170);
    if (annPrevFocus && annPrevFocus.focus) { try { annPrevFocus.focus() } catch (_) {} } annPrevFocus = null;
  }

  function annKey(ev) {
    if (!annEl) return;
    if (ev.key === 'Escape') { ev.preventDefault(); annLater(); return }
    if (ev.key === 'Tab') {                       // keep the focus inside the dialog
      const bs = [...annEl.querySelectorAll('button:not([disabled])')];
      if (!bs.length) return;
      const f = bs[0], l = bs[bs.length - 1];
      if (ev.shiftKey && document.activeElement === f) { ev.preventDefault(); l.focus() }
      else if (!ev.shiftKey && document.activeElement === l) { ev.preventDefault(); f.focus() }
      else if (!annEl.contains(document.activeElement)) { ev.preventDefault(); f.focus() }
    }
  }

  function annLater() { annList.forEach(a => annSeen.add(a.id)); annClose() }

  async function annOk() {
    const a = annList[annIdx], ok = annEl && annEl.querySelector('.sra-ok');
    if (!a || !ok || ok.disabled) return;
    ok.disabled = true;
    try { await call('sr_announcements_read', { p_ids: [a.id] }, 15000) }
    catch (e) {
      if (!annEl) return;
      // no connection: it stays unconfirmed on the server and comes back at the next sign-in, but not again in this session
      if (!isNet(e)) { ok.disabled = false; annEl.querySelector('.sra-err').textContent = 'ვერ დაფიქსირდა: ' + msg(e); return }
    }
    ok.disabled = false;
    annSeen.add(a.id);
    if (!annEl) return;
    annList.splice(annIdx, 1);
    if (!annList.length) { annClose(); return }
    if (annIdx >= annList.length) annIdx = annList.length - 1;
    annPaint();
    annEl.querySelector('.sra-ok').focus();
  }

  function annShow(list) {
    if (annEl) {                                  // a new one arrived while the pop-up is open: append it
      list.forEach(a => { if (!annList.some(x => x.id === a.id)) annList.push(a) });
      annPaint(true); return;
    }
    annStyle();
    annList = list.slice(); annIdx = 0;
    annPrevFocus = document.activeElement;
    annEl = el(`<div id="sr-ann" role="dialog" aria-modal="true"><div class="sra-card"><div class="sra-bar"></div>
      <div class="sra-body"><div class="sra-top"><span class="sra-ic" aria-hidden="true"></span><div class="sra-tt"><h2></h2><time></time></div><span class="sra-cnt" hidden></span></div><p class="sra-tx"></p></div>
      <div class="sra-ft"><div class="sra-dots" hidden aria-hidden="true"></div><p class="sra-err" role="alert"></p><button type="button" class="sra-ok"></button><button type="button" class="sra-later"></button></div></div></div>`);
    if (!annEl) return;
    annEl.querySelector('.sra-ok').onclick = annOk;
    annEl.querySelector('.sra-later').onclick = annLater;
    document.body.appendChild(annEl);
    document.addEventListener('keydown', annKey, true);
    annPaint(true);
    annEl.querySelector('.sra-ok').focus({ preventScroll: true });
  }

  async function annCheck(force) {
    if (!on || !U || !token || ro || annBusy || me.user.role !== 'admin') return;
    if (!force && Date.now() - annAt < 60000) return;
    annBusy = true; annAt = Date.now();
    try {
      const r = await call('sr_announcements', {}, 15000);
      const fresh = (Array.isArray(r) ? r : []).filter(a => a && a.id && a.text && !annSeen.has(a.id));
      if (fresh.length && U && token) annShow(fresh);
    } catch (_) { /* offline or session ended: nothing to show now */ }
    finally { annBusy = false }
  }

  function annReset() { annSeen = new Set(); annAt = 0; if (annEl) { annEl.remove(); annEl = null } annList = []; document.removeEventListener('keydown', annKey, true) }

  setInterval(() => { if (document.visibilityState === 'visible') annCheck() }, 5 * 60 * 1000);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') annCheck() });
  window.addEventListener('online', () => annCheck());

  window.SR = { on, login, boot, logout, save, ready, ensure, touch, loadingHtml, mainLoadingHtml, retryLoad, loadError: () => loadErr, msg, changePassword, pushState, pushEnable, pushDisable, pushPrefs, pushSetPrefs, pushTest, announcements: annCheck, showAnnouncements: annShow, dirty, safe: () => idbOk, queued: () => pendN > 0 || !!inflight, pendingChanges: () => diff(), get me() { return me }, get readOnly() { return ro } };
})();
