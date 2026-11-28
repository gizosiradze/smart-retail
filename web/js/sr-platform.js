/* Smart Retail · Super Admin on Supabase (web/superadmin/index.html)
 *
 * Sign-in: Supabase Auth (email + password) and an authenticator app (TOTP). The first sign-in enrols
 * the app by QR code. Every platform function in the database requires an aal2 session of a user
 * listed in app.platform_admins (see scripts/create-superadmin.mjs).
 * Data: the screens keep using D; save() sends what changed (sr_platform_push). Registering a store and
 * resetting passwords run on the server, which creates the real staff accounts with hashed passwords.
 */
(function () {
  const CFG = window.SR_CONFIG || {};
  // With a server configured, never fall back to the prototype's local demo data.
  const on = !!(CFG.url && CFG.anonKey);
  let sb = null, snap = {}, MET = {}, pushing = false, again = false;
  if (on && window.supabase) sb = window.supabase.createClient(CFG.url, CFG.anonKey, { auth: { persistSession: true, storage: window.sessionStorage } });

  const COLLS = ['stores', 'plans', 'payments', 'audit', 'ann'];
  const keyOf = x => String(x.id);
  // crypto.randomUUID exists only on https:// and localhost; over http://<LAN IP> fall back to getRandomValues
  const uuid = () => crypto.randomUUID ? crypto.randomUUID()
    : ([1e7] + -1e3 + -4e3 + -8e3 + -1e11).replace(/[018]/g, c => (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16));

  async function rpc(fn, args) {
    const { data, error } = await sb.rpc(fn, args || {});
    if (error) throw new Error(error.message);
    return data;
  }
  const errBox = t => { const e = document.getElementById('sae'); if (e) e.textContent = t || '' };

  // ---------------------------------------------------------------- sign-in
  function loginView() {
    if (!sb) return '<div class="lg"><h2>სუპერ ადმინი</h2><div class="note" style="color:var(--r)">Supabase-ის ბიბლიოთეკა ვერ ჩაიტვირთა (cdn.jsdelivr.net). შეამოწმეთ ინტერნეტი და განაახლეთ გვერდი.</div></div>';
    return '<div class="lg"><h2>სუპერ ადმინი</h2><small>პლატფორმის მართვა: ყველა მაღაზია, აბონენტი, გადახდები</small>' +
      '<div id="sa1"><input id="lu" type="email" placeholder="ელფოსტა" autocomplete="username">' +
      '<input id="lp" type="password" placeholder="პაროლი" autocomplete="current-password" onkeydown="if(event.key==\'Enter\')login()">' +
      '<button class="pri" style="width:100%;margin-top:6px" onclick="login()">შესვლა</button></div>' +
      '<div id="sa2" hidden></div><div id="sae" style="color:var(--r);min-height:18px;font-size:13px"></div>' +
      '<div class="note">შესვლა ორსაფეხურიანია: პაროლი და ავთენტიფიკატორის აპის 6-ნიშნა კოდი (Google Authenticator, Microsoft Authenticator, 1Password...).</div></div>';
  }

  async function login() {
    errBox('');
    const email = document.getElementById('lu').value.trim(), password = document.getElementById('lp').value;
    if (!email || !password) { errBox('შეავსეთ ელფოსტა და პაროლი'); return }
    const { error } = await sb.auth.signInWithPassword({ email, password });
    if (error) { errBox('არასწორი ელფოსტა ან პაროლი'); return }
    await secondFactor();
  }

  async function secondFactor() {
    const who = await rpc('sr_platform_whoami').catch(() => null);
    if (!who || !who.is_admin) { await sb.auth.signOut(); errBox('ამ ანგარიშს სუპერ ადმინის უფლება არ აქვს'); return }
    const { data: aal } = await sb.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aal && aal.currentLevel === 'aal2') return enter();
    const { data: f } = await sb.auth.mfa.listFactors();
    let factor = f && f.totp && f.totp.find(x => x.status === 'verified');
    const box = document.getElementById('sa2'); document.getElementById('sa1').hidden = true; box.hidden = false;
    if (!factor) {
      // first sign-in: enrol the authenticator app
      (f && f.totp || []).filter(x => x.status !== 'verified').forEach(x => sb.auth.mfa.unenroll({ factorId: x.id }));
      const { data: en, error } = await sb.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'Smart Retail ' + new Date().toISOString().slice(0, 10) });
      if (error) { errBox(error.message); return }
      factor = { id: en.id };
      box.innerHTML = '<p style="margin:0">დაასკანერეთ QR კოდი ავთენტიფიკატორის აპით და ჩაწერეთ 6-ნიშნა კოდი.</p>' +
        '<img alt="QR" style="width:200px;height:200px;align-self:center;background:#fff;border-radius:12px" src="' + en.totp.qr_code + '">' +
        '<small style="word-break:break-all">ან ჩაწერეთ ხელით: <b>' + esc(en.totp.secret) + '</b></small>';
    } else box.innerHTML = '<p style="margin:0">ჩაწერეთ ავთენტიფიკატორის აპის 6-ნიშნა კოდი.</p>';
    box.insertAdjacentHTML('beforeend', '<input id="l2" placeholder="2FA კოდი (6 ციფრი)" inputmode="numeric" maxlength="6" autocomplete="one-time-code">' +
      '<button class="pri" id="l2b" style="width:100%">დადასტურება</button>');
    const go = async () => {
      const code = document.getElementById('l2').value.trim();
      if (!/^\d{6}$/.test(code)) { errBox('კოდი 6 ციფრია'); return }
      const { error } = await sb.auth.mfa.challengeAndVerify({ factorId: factor.id, code });
      if (error) { errBox('კოდი არასწორია'); return }
      enter();
    };
    document.getElementById('l2b').onclick = go;
    document.getElementById('l2').onkeydown = e => { if (e.key === 'Enter') go() };
    document.getElementById('l2').focus();
  }

  async function enter() {
    try {
      await loadAll();
      log('სუპერ ადმინი შევიდა სისტემაში');
      go('overview');
    } catch (e) { errBox(e.message) }
  }

  async function logout() {
    try { await push() } catch (_) {}
    await sb.auth.signOut();
    D = { v: 1, plans: [], stores: [], payments: [], audit: [], ann: [], settings: {} }; snap = {};
    go('login');
  }

  async function boot() {
    D = { v: 1, plans: [], stores: [], payments: [], audit: [], ann: [], settings: {} };
    if (!sb) { go('login'); return }
    const { data } = await sb.auth.getSession();
    if (data && data.session) {
      const { data: aal } = await sb.auth.mfa.getAuthenticatorAssuranceLevel();
      if (aal && aal.currentLevel === 'aal2') { try { await loadAll(); go('overview'); return } catch (_) {} }
    }
    go('login');
  }

  // ---------------------------------------------------------------- data
  async function loadAll() {
    const [data, met, demos, errs] = await Promise.all([rpc('sr_platform_pull'), rpc('sr_platform_metrics'), rpc('sr_platform_demo_list').catch(() => []), rpc('sr_platform_errors_list').catch(() => [])]);
    D = data; MET = met || {}; D.demos = demos || []; D.errs = errs || [];
    rebase();
  }
  function rebase() {
    snap = {};
    for (const c of COLLS) snap[c] = new Map((D[c] || []).map(x => [keyOf(x), JSON.stringify(x)]));
    snap.settings = JSON.stringify(D.settings || {});
  }
  function diff() {
    const p = { rm: {} }; let n = 0;
    for (const c of COLLS) {
      (D[c] || []).forEach(x => { if (x && x.id == null) x.id = uuid() });   // log() entries have no id
      const cur = new Map((D[c] || []).map(x => [keyOf(x), x])), s = snap[c] || new Map();
      const up = [...cur.values()].filter(x => s.get(keyOf(x)) !== JSON.stringify(x));
      if (up.length) { p[c] = up; n += up.length }
      const rm = [...s.keys()].filter(k => !cur.has(k));
      if (rm.length && (c === 'payments' || c === 'ann')) { p.rm[c] = rm; n += rm.length }
    }
    if (JSON.stringify(D.settings || {}) !== snap.settings) { p.settings = D.settings; n++ }
    return n ? p : null;
  }
  function save() { if (pushing) { again = true; return } push().catch(e => toast('ვერ შეინახა: ' + e.message)) }
  async function push() {
    pushing = true;
    try {
      do {
        again = false;
        const p = diff();
        if (!p) break;
        await rpc('sr_platform_push', { p });
        rebase();
      } while (again);
    } finally { pushing = false }
  }

  // ---------------------------------------------------------------- demo requests (home page forms)
  async function demosLoad() { D.demos = (await rpc('sr_platform_demo_list')) || [] }
  const demoSet = (id, st, note) => rpc('sr_platform_demo_set', { p_id: id, p_status: st, p_note: note || '' });
  const demoDel = id => rpc('sr_platform_demo_delete', { p_id: id });

  // ---------------------------------------------------------------- browser errors (sr-errors.js reports them)
  async function errsLoad() { D.errs = (await rpc('sr_platform_errors_list')) || [] }
  const errSet = (id, st) => rpc('sr_platform_error_set', { p_id: id, p_status: st });
  const errDel = id => rpc('sr_platform_error_delete', { p_id: id || null });

  // ---------------------------------------------------------------- server-side actions
  async function register() {
    const g = k => document.getElementById('r_' + k).value.trim();
    const req = [['name', 'დასახელება'], ['login', 'სისტემის სახელი'], ['owner', 'მფლობელი'], ['phone', 'ტელეფონი'], ['email', 'ელფოსტა']];
    for (const [k, l] of req) if (!g(k)) { toast('შეავსეთ: ' + l); document.getElementById('r_' + k).focus(); return }
    if (!/^[a-z0-9][a-z0-9_-]{1,39}$/.test(g('login'))) { toast('სისტემის სახელი: ლათინური პატარა ასოები და ციფრები'); return }
    if (D.stores.some(s => s.login === g('login'))) { toast('სისტემის სახელი დაკავებულია'); return }
    if (!/^\S+@\S+\.\S+$/.test(g('email'))) { toast('ელფოსტა არასწორია'); return }
    if (!document.getElementById('r_terms').checked) { toast('მონიშნეთ პირობებზე თანხმობა'); return }
    const br = g('br').split('\n').map(x => x.trim()).filter(Boolean); if (!br.length) br.push('მთავარი');
    const pl = planOf(REG.plan);
    const trial = +document.getElementById('r_trial').value, fee = +document.getElementById('r_fee').value || pl.price;
    const doc = {
      login: g('login'), name: g('name'), legal: g('legal') || g('name'), idcode: g('idcode'), address: g('address'), owner: g('owner'),
      phone: g('phone'), email: g('email'), plan: pl.id, kind: document.getElementById('r_kind').value, branches: br,
      status: trial ? 'trial' : 'active', statusReason: '', created: iso(TODAY), trialEnd: iso(addD(TODAY, trial)),
      payDay: Math.max(1, Math.min(28, +document.getElementById('r_payday').value || 1)), feeHist: [{ from: ym(addD(TODAY, trial)), fee }], notes: '',
      adminUser: g('au') || 'admin', adminPassword: g('ap')
    };
    let res;
    try { res = await rpc('sr_platform_register_store', { d: doc }) } catch (e) { toast('რეგისტრაცია ვერ მოხერხდა: ' + e.message); return }
    const s = res.store; D.stores.push(s); snap.stores.set(keyOf(s), JSON.stringify(s));
    log('მაღაზია დარეგისტრირდა (' + pl.name + ', ' + fmt(fee) + '/თვე' + (trial ? ', საცდელი ' + trial + ' დღე' : '') + ')', s.id);
    const creds = res.credentials || [];
    window._cred = 'მაღაზია: ' + s.login + '\n' + creds.map(c => c.u + ' / ' + c.pw + (c.branch ? ' (' + c.branch + ')' : '')).join('\n');
    V.store = s.id; V.tab = 'dash'; V.view = 'store'; render();
    const warn = br.length > pl.branches ? '<div class="banner" style="margin:0">ფილიალების რაოდენობა (' + br.length + ') აღემატება ' + pl.name + ' პაკეტის ლიმიტს (' + pl.branches + ').</div>' : '';
    modal('<h3>✓ მაღაზია დარეგისტრირდა</h3><p style="margin:0">გადაეცით ეს მონაცემები მფლობელს (<b>' + esc(s.owner || '') + '</b>):</p>' +
      '<div class="cred">მაღაზია: <b>' + esc(s.login) + '</b><br>' + creds.map(c => esc(c.u) + ': <b>' + esc(c.pw) + '</b>' + (c.branch ? ' · ' + esc(c.branch) : ' · ადმინი')).join('<br>') + '</div>' + warn +
      '<small>პაროლები დროებითია: პირველი შესვლისას თითოეული თანამშრომელი შეცვლის. სერვერზე მხოლოდ დაშიფრული (bcrypt) სახით ინახება, ამიტომ ფანჯრის დახურვის შემდეგ ვეღარ ნახავთ.</small>' +
      '<div class="ft"><button onclick="copyT(window._cred)">კოპირება</button><button class="pri" onclick="closeM()">დახურვა</button></div>');
    REG = { plan: 'std' };
  }

  async function resetPass(id, i) {
    const s = storeOf(id), u = s.users[i];
    let r;
    try { r = await rpc('sr_platform_reset_password', { p_store: id, p_username: u.u }) } catch (e) { toast('ვერ მოხერხდა: ' + e.message); return }
    log('დროებითი პაროლი: ' + u.u, id);
    modal('<h3>დროებითი პაროლი</h3><div class="cred">მაღაზია: ' + esc(s.login) + '<br>მომხმარებელი: ' + esc(u.u) + '<br>პაროლი: <b>' + esc(r.pw) + '</b></div>' +
      '<small>მომხმარებელი პირველივე შესვლისას შეცვლის პაროლს. მისი ძველი სესიები დაიხურა. გადაეცით უსაფრთხოდ (ტელეფონით / პირადად).</small>' +
      '<div class="ft"><button onclick="copyT(\'' + esc(r.pw) + '\')">კოპირება</button><button class="pri" onclick="closeM();render()">დახურვა</button></div>');
  }

  async function addBranch(id) {
    const s = storeOf(id), pl = planOf(s.plan);
    const el = document.getElementById('nb_name'), name = el ? el.value.trim() : '';
    if (!name) { toast('ჩაწერეთ ფილიალის სახელი'); return }
    if (s.branches.some(b => b.toLowerCase() === name.toLowerCase())) { toast('ასეთი ფილიალი უკვე არსებობს'); return }
    if (s.branches.length >= pl.branches && !confirm('პაკეტის ლიმიტი (' + pl.branches + ') შევსებულია. მაინც დაემატოს?')) return;
    let r;
    try { r = await rpc('sr_platform_add_branch', { p_store: id, p_name: name }) }
    catch (e) { toast('ვერ დაემატა: ' + (/BRANCH_EXISTS/.test(e.message) ? 'ასეთი ფილიალი უკვე არსებობს' : e.message)); return }
    s.branches = r.branches; snap.stores.set(keyOf(s), JSON.stringify(s));
    log('ფილიალი დაემატა: ' + name, id);
    render();
  }

  // Opens the store's own app in a new tab as its admin, read-only. The tab is opened first (inside the
  // click, so pop-up blockers allow it); the token goes to it by postMessage once it says it is ready.
  function openAsStore(id) {
    const s = storeOf(id);
    if (!s) return;
    if (s.status === 'suspended') { toast('შეჩერებული მაღაზია ვერ გაიხსნება. ჯერ აღადგინეთ'); return }
    const w = window.open('../#sa', '_blank');
    if (!w) { toast('ბრაუზერმა ახალი ფანჯარა დაბლოკა. დაუშვით pop-up ამ საიტისთვის'); return }
    const tok = (async () => {
      const { data } = await sb.auth.getSession();
      const at = data && data.session && data.session.access_token;
      if (!at) throw new Error('PLATFORM_ADMIN_REQUIRED');
      const r = await fetch(`${CFG.url}/functions/v1/store-login`, {
        method: 'POST',
        headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + at, 'Content-Type': 'application/json' },
        body: JSON.stringify({ platform_store: id })
      });
      const j = await r.json().catch(() => ({}));
      if (!r.ok || !j.token) throw new Error(j.error || ('HTTP ' + r.status));
      return j;
    })();
    tok.catch(() => {});
    const onMsg = async e => {
      if (e.source !== w || e.origin !== location.origin || !e.data || e.data.sr !== 'sa-ready') return;
      window.removeEventListener('message', onMsg);
      try { const j = await tok; w.postMessage({ sr: 'sa-token', t: j.token, e: j.exp }, location.origin) }
      catch (x) { w.postMessage({ sr: 'sa-error', m: x.message }, location.origin); toast('მაღაზია ვერ გაიხსნა: ' + x.message) }
    };
    window.addEventListener('message', onMsg);
    setTimeout(() => window.removeEventListener('message', onMsg), 60000);
    log('მაღაზიის დეშბორდი გაიხსნა ნახვის რეჟიმში', id);
  }

  // same shape as the prototype's metrics(), from real receipts
  function metrics(s) {
    const m = MET[s.id] || {}, days = m.days || [];
    const sum = n => days.slice(-n).reduce((a, x) => a + (+x.v || 0), 0), d30 = sum(30), checks = +m.checks || 0;
    const byB = m.byBranch || {};
    return {
      days, today: sum(1), d7: sum(7), d30, checks, avg: checks ? Math.round(d30 / checks) : 0, profit: +m.profit || 0,
      customers: +m.customers || 0, products: +m.products || 0, stockValue: +m.stockValue || 0,
      branches: (s.branches || []).map(b => ({ b, v: +byB[b] || 0 })), top: m.top || []
    };
  }

  window.SRP = { on, demosLoad, demoSet, demoDel, errsLoad, errSet, errDel, login, logout, boot, loginView, save, register, resetPass, addBranch, metrics, openAsStore };
})();
