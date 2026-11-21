/* Smart Retail · Supabase data layer for the main app (web/index.html)
 *
 * The screens keep working on the in-memory object D exactly as in the prototype.
 * This file replaces localStorage with Supabase:
 *   - login: Edge Function "store-login" -> JWT kept in sessionStorage (8 hours)
 *   - load:  core collections at login, heavier ones when their screen opens, then only changes (sr_pull)
 *   - save:  every save() sends what changed since the last confirmed state, in one transaction (sr_push)
 *   - ids:   integer ids (receipt numbers etc.) come from blocks reserved on the server (sr_alloc_ids)
 *   - photos: base64 images are uploaded to Storage and replaced by their public URL
 * Online only (phase 1): without internet nothing is lost while the page stays open, but nothing is sent
 * either; the existing red "not saved · retry" banners show it.
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
  const BY_VIEW = { buy: ['pu', 'sup'], sup: ['sup', 'pu'], prod: ['pu', 'sup'], trf: ['pu', 'sup'], inv: ['ih'],
    stats: ['pu', 'sup', 'ex', 'sgl'], today: ['pu', 'ex'], emp: ['ex', 'lg', 'sgl', 'pu'], wr: ['ex', 'sgl', 'pu'] };
  const REFRESH_MS = 15000;
  const TOKEN_KEY = 'sr_session';

  const roleL = r => r === 'admin' ? 'a' : r === 'cashier' ? 'c' : 'w';
  let token = null, exp = 0, me = null, role = 'c';
  let snap = {}, snapSt = {}, snapKv = {}, loaded = new Set(), cursors = {}, fetchedAt = {};
  let pushing = false, again = false, pending = false, lastErr = '', idRefill = null, pendingExpiry = false;

  // ---------------------------------------------------------------- HTTP
  async function call(fn, args) {
    const r = await fetch(`${CFG.url}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + (token || CFG.anonKey), 'Content-Type': 'application/json' },
      body: JSON.stringify(args || {})
    });
    const txt = await r.text();
    const j = txt ? JSON.parse(txt) : null;
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
    PASSWORD_TOO_SHORT: 'პაროლი ძალიან მოკლეა', WRONG_PASSWORD: 'მიმდინარე პაროლი არასწორია'
  };
  const msg = e => {
    const m = String((e && e.message) || e || '');
    if (e && e.name === 'TypeError') return 'სერვერთან კავშირი ვერ დამყარდა. შეამოწმე ინტერნეტი';
    const k = Object.keys(MSG).find(k => m.includes(k));
    return k ? MSG[k] : m;
  };

  // ---------------------------------------------------------------- session
  function storeToken(t, e) { token = t; exp = e; try { sessionStorage.setItem(TOKEN_KEY, JSON.stringify({ t, e })) } catch (_) {} }
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
    if (Array.isArray(me.branches) && me.branches.length) { BR.length = 0; BR.push(...me.branches); }
    D = {}; snap = {}; snapSt = {}; snapKv = {}; loaded = new Set(); cursors = {}; fetchedAt = {};
    await pull(CORE.filter(c => c === 'st' || c === 'kv' || READ[c].includes(role)));
    await allocIds(true);
    window.srNormalize && srNormalize();          // defaults the prototype added on startup
    rebase();                                     // ...but those defaults are not "changes"
    const u = me.user;
    U = { store: me.store.name, u: u.u, id: u.id, name: u.name, branch: u.branch || '', role: u.role == 'cashier' ? 'pos' : 'dash',
          type: u.role, perms: u.perms || {} };
    view = 0; skB = null; if (u.branch && u.role != 'cashier') ib = u.branch;
    if (U.role == 'pos') { txp = 1; txq = ''; txm = '' }
    LPG = false;
    if (me.store.status === 'restricted') toast('მაღაზია შეზღუდულია: გაყიდვა დაბლოკილია, ნახვა და ექსპორტი მუშაობს', 1);
    render();
  }

  async function boot() {
    let s = null;
    try { s = JSON.parse(sessionStorage.getItem(TOKEN_KEY) || 'null') } catch (_) {}
    D = { p: [], dp: [], c: [], s: [], st: {}, us: [], sh: [], cm: [], pu: [], sup: [], cats: [] };
    if (s && s.t && s.e * 1000 > Date.now() + 60000) {
      token = s.t; exp = s.e;
      try { await start(); return } catch (e) { clearToken() }
    }
    render();
  }

  async function logout() {
    if (dirty() && !await confirmBox('შეუნახავი ცვლილებები დაიკარგება. მაინც გასვლა?')) return;
    try { await call('sr_logout') } catch (_) {}
    clearToken(); U = null; cart = []; D = { p: [], dp: [], c: [], s: [], st: {}, us: [], sh: [], cm: [], pu: [], sup: [], cats: [] };
    snap = {}; snapSt = {}; snapKv = {}; loaded = new Set();
    render();
  }

  // ---------------------------------------------------------------- loading
  async function pull(colls) {
    let todo = colls.slice();
    while (todo.length) {
      const res = await call('sr_pull', { p_colls: todo, p_cursors: cursors });
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
  }

  const needFor = v => [...new Set([...(BY_VIEW[v] || [])])].filter(c => READ[c] && READ[c].includes(role));
  function ready(v) { return !on || !U || needFor(v).every(c => loaded.has(c)) }
  let ensuring = null;
  function ensure(v) {
    if (ensuring) return ensuring;
    ensuring = pull(needFor(v).filter(c => !loaded.has(c))).catch(onError).finally(() => { ensuring = null; rebaseColls(needFor(v)) });
    return ensuring;
  }
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
  const loadingHtml = () => `<div class="lgp"><section class="lg" style="text-align:center"><h2 class="lgl">${typeof SRL !== 'undefined' ? SRL : 'Smart Retail'}</h2><p class="m">მონაცემები იტვირთება…</p></section></div>`;

  // ---------------------------------------------------------------- id blocks (D.n)
  const BLOCK = 300;
  const blk = { next: 0, end: 0, queued: null };
  async function allocIds(first) {
    const start = await call('sr_alloc_ids', { p_count: BLOCK });
    if (first) { blk.next = start; blk.end = start + BLOCK; blk.queued = null; defineN(); } else blk.queued = start;
  }
  function defineN() {
    Object.defineProperty(D, 'n', {
      configurable: true, enumerable: false,
      get() { return blk.next },
      set(v) {
        blk.next = v;
        if (blk.next >= blk.end && blk.queued != null) { blk.next = blk.queued; blk.end = blk.queued + BLOCK; blk.queued = null; }
        if (blk.end - blk.next < 60 && blk.queued == null && !idRefill)
          idRefill = allocIds(false).catch(() => {}).finally(() => { idRefill = null });
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
  function dirty() { return on && U && !empty(diff()) }

  // after a confirmed push (or a load), the current state becomes the baseline
  function rebase() { rebaseColls(COLLS); snapSt = Object.fromEntries(Object.entries(D.st || {}).map(([k, v]) => [k, +v || 0]));
    snapKv = {}; Object.keys(D).forEach(k => { if (!NOT_KV.has(k) && D[k] !== undefined) snapKv[k] = JSON.stringify(D[k]) }); }
  function rebaseColls(list) {
    for (const c of list) { if (!Array.isArray(D[c])) continue; const m = snap[c] = new Map();
      for (const x of D[c]) { if (!x._k) x._k = uuid(); m.set(x._k, JSON.stringify(x)); } }
  }

  async function uploadImages(up) {
    for (const c of ['p', 'dp']) for (const x of up[c] || []) {
      if (typeof x.img !== 'string' || !x.img.startsWith('data:image/')) continue;
      const blob = await (await fetch(x.img)).blob();
      const ext = (blob.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg');
      const path = `${me.store.id}/${x._k}-${Date.now().toString(36)}.${ext}`;
      const r = await fetch(`${CFG.url}/storage/v1/object/product-images/${path}`, {
        method: 'POST', headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + token, 'Content-Type': blob.type, 'x-upsert': 'true' }, body: blob
      });
      if (!r.ok) throw new Error('სურათი ვერ აიტვირთა (' + r.status + ')');
      x.img = `${CFG.url}/storage/v1/object/public/product-images/${path}`;
    }
  }

  function save() {
    SVOK = navigator.onLine === false ? 0 : 1;
    pending = true;
    if (pushing) { again = true; return }
    push();
  }

  async function push() {
    if (!U || !token) return;
    pushing = true;
    try {
      do {
        again = false;
        if (navigator.onLine === false) throw new TypeError('offline');
        const d = diff();
        if (d.local.length) console.info('[sr] kept on this device only (no permission to save):', d.local.join(', '));
        if (empty(d)) { markLocalAsBaseline(d.local); break; }
        await uploadImages(d.up);
        // JSON as sent is captured now: edits made while the request is in flight stay pending
        const sent = { up: d.up, upJ: d.upJ, rm: d.rm, st: d.st, kv: d.kv };
        const res = await call('sr_push', { p: { up: sent.up, rm: sent.rm, st: sent.st, kv: sent.kv } });
        confirm(sent);
        // server-side corrections (cost of goods on receipts) and sanitized user records
        for (const doc of (res.patched && res.patched.s) || []) {
          const x = (D.s || []).find(y => y._k === doc._k); if (x) { Object.assign(x, doc); (snap.s = snap.s || new Map()).set(x._k, JSON.stringify(x)); }
        }
        for (const u of res.users || []) {
          const x = (D.us || []).find(y => y._k === u._k); if (x) { delete x.pw; Object.assign(x, u); (snap.us = snap.us || new Map()).set(x._k, JSON.stringify(x)); }
        }
        markLocalAsBaseline(d.local);
      } while (again);
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

  function setSaved(ok, why) {
    SVOK = ok ? 1 : 0;
    lastErr = ok ? '' : why || '';
    try {
      if (typeof PSV !== 'undefined' && PSV) { if (ok) { PSV.ok = 1; UNS.clear() } else if (PSV.ok) { PSV.ok = 0; UNS.add(PSV.id) } PSV.t = Date.now(); psvUp() }
    } catch (_) {}
    banner(ok ? '' : why);
  }
  function onError(e) {
    console.error('[sr]', e);
    if (e && e.session) { expired(); setSaved(false, 'სესია დასრულდა'); return; }
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
        storeToken(j.token, j.exp); pendingExpiry = false; modal(); save();
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
  setInterval(() => { if (on && U && token && !pushing && navigator.onLine !== false && dirty()) save() }, 3000);

  window.addEventListener('beforeunload', e => { if (dirty()) { e.preventDefault(); e.returnValue = '' } });
  window.addEventListener('online', () => { if (dirty()) save() });

  window.SR = { on, login, boot, logout, save, ready, ensure, touch, loadingHtml, msg, changePassword, dirty, pendingChanges: () => diff(), get me() { return me } };
})();
