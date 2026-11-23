/* Smart Retail · შეტყობინებების გვერდი (მართვა → შეტყობინებები)
 *
 * What an admin's phone gets a notification about. The choices belong to the device (each phone picks its own);
 * they are saved on the server (sr_push_prefs_*) so the database knows whom to notify, and mirrored in
 * localStorage so the page can be filled in before the phone is switched on.
 * Event kinds match supabase/migrations/20261123000013_push_preferences.sql.
 * Uses the app's globals (emNav, esc, render, BR, view, emT, toast) at call time.
 */
const NT_GROUPS = [
  ['გაყიდვები', [
    ['sale', 'ყველა გაყიდვა', 'ყოველი ახალი ჩეკი: თანხა, ფილიალი, გადახდის მეთოდი, მოლარე'],
    ['big', 'დიდი გაყიდვა', 'მხოლოდ მაშინ, როცა ჩეკი ამ თანხას აჭარბებს ან ტოლია', 'bigN', '₾'],
    ['ret', 'დაბრუნება', 'ყოველი დაბრუნება ან გადაცვლა']]],
  ['ცვლა და სალარო', [
    ['sho', 'ცვლა გაიხსნა', 'ვინ და რომელ ფილიალში გახსნა სალარო'],
    ['shc', 'ცვლა დაიხურა', 'ცვლის დახურვა, ყოველ შემთხვევაში'],
    ['shd', 'ცვლა დაიხურა სხვაობით', 'ნაღდი ფულის დანაკლისი ან ჭარბი დახურვისას'],
    ['cm', 'ფულის შეტანა და გატანა', 'სალაროდან ფულის გატანა ან სალაროში შეტანა, მიზეზით']]],
  ['მარაგი და გადაზიდვა', [
    ['low', 'მარაგი იწურება', 'ზომის მარაგი ამდენ ცალამდე ან ნაკლებამდე დაეცა', 'lowN', 'ც.'],
    ['trs', 'გადაზიდვა გაიგზავნა', 'ფილიალიდან გზაში ჩადგა ნივთები'],
    ['trr', 'გადაზიდვა მიღებულია', 'ფილიალმა გადაზიდვა მიიღო'],
    ['trd', 'გადაზიდვა დანაკლისით', 'მიღებისას რაოდენობა არ დაემთხვა გაგზავნილს'],
    ['pu', 'შესყიდვა დაემატა', 'ახალი მარაგი მომწოდებლისგან']]]
];
const NT_KINDS = NT_GROUPS.flatMap(g => g[1].map(e => e[0]));
const NT_DEF = { ev: { sale: 1, ret: 1 }, bigN: 500, lowN: 2, br: [] };   // a new phone gets sales and returns, as before
const NT_KEY = 'sr_nt';

let NT = ntNorm(null), ntSt = null, ntBusy = false, ntTimer = 0, ntErr = '';

function ntNorm(p) {
  const ev = {};
  NT_KINDS.forEach(k => { ev[k] = p && p.ev && k in p.ev ? (+p.ev[k] ? 1 : 0) : (NT_DEF.ev[k] || 0) });
  const n = (v, d, mx) => { v = v == null || v === '' ? NaN : Number(v); return isFinite(v) && v >= 0 ? Math.min(v, mx) : d };
  return { ev, bigN: n(p && p.bigN, NT_DEF.bigN, 1e7), lowN: Math.floor(n(p && p.lowN, NT_DEF.lowN, 1000)), br: Array.isArray(p && p.br) ? p.br.map(String).slice(0, 50) : [] };
}
function ntLocal(save) {
  try { if (save) localStorage.setItem(NT_KEY, JSON.stringify(NT)); else { const r = localStorage.getItem(NT_KEY); if (r) NT = ntNorm(JSON.parse(r)) } } catch (_) { }
}
ntLocal();

// what this phone can do right now; loads the saved choices from the server once the page is opened
async function ntLoad() {
  if (ntBusy || ntSt !== null) return;
  ntBusy = true;
  try {
    if (!(window.SR && SR.on)) ntSt = 'demo';
    else {
      ntSt = await SR.pushState();
      if (ntSt === 'on') {
        try { const p = await SR.pushPrefs(); if (p) { NT = ntNorm(p); ntLocal(true) } else ntSave() }   // nothing saved on the server yet: send this phone's choices
        catch (e) { ntErr = SR.msg ? SR.msg(e) : 'არჩევანი ვერ ჩაიტვირთა' }
      }
    }
  } catch (_) { ntSt = 'off' }
  ntBusy = false;
  if (typeof emT !== 'undefined' && emT === 'n' && view === 'emp') render();
}

function ntSave() {
  ntLocal(true);
  if (ntSt !== 'on') return;
  clearTimeout(ntTimer);
  ntTimer = setTimeout(async () => {
    try { await SR.pushSetPrefs(NT); ntErr = '' } catch (e) { ntErr = SR.msg ? SR.msg(e) : 'ვერ შეინახა'; render() }
  }, 350);
}
function ntSet(k, v) { NT.ev[k] = v ? 1 : 0; ntSave(); render() }
function ntNum(k, el) {
  const v = Math.max(0, Math.floor(+el.value || 0));
  NT[k] = Math.min(v, k === 'bigN' ? 1e7 : 1000); ntSave(); render();
}
function ntBr(b) {
  if (b === '') NT.br = [];
  else NT.br = NT.br.includes(b) ? NT.br.filter(x => x !== b) : NT.br.concat(b);
  if (NT.br.length >= BR.length) NT.br = [];
  ntSave(); render();
}
function ntAll(on) { NT_KINDS.forEach(k => NT.ev[k] = on ? 1 : 0); ntSave(); render() }

async function ntDev(on) {
  ntErr = '';
  try { on ? await SR.pushEnable(NT) : await SR.pushDisable(); ntSt = null; await ntLoad(); if (typeof toast === 'function') toast(on ? 'შეტყობინებები ჩაირთო' : 'შეტყობინებები გამოირთო') }
  catch (e) { ntErr = SR.msg ? SR.msg(e) : String(e.message || e); ntSt = null; await ntLoad(); render() }
}
async function ntTest() {
  try { await SR.pushTest() } catch (e) { ntErr = SR.msg ? SR.msg(e) : 'ვერ გაიგზავნა'; render() }
}

function ntPage() {
  ntLoad();
  const st = ntSt, on = st === 'on', n = NT_KINDS.filter(k => NT.ev[k]).length;
  const msg = {
    demo: 'დემო რეჟიმში შეტყობინებები არ მუშაობს. რეალურ სისტემაში აქ ჩართავ ტელეფონზე შეტყობინებებს.',
    unsupported: 'ეს ბრაუზერი შეტყობინებებს არ უჭერს მხარს.',
    'ios-install': 'iPhone-ზე შეტყობინებები მუშაობს მხოლოდ მაშინ, როცა აპი საწყის ეკრანზეა დამატებული: Safari → გაზიარება → „საწყის ეკრანზე დამატება“, შემდეგ გახსენი იქიდან.',
    denied: 'შეტყობინებები ამ მოწყობილობაზე დაბლოკილია. ჩართე ბრაუზერის ან ტელეფონის პარამეტრებში.'
  }[st];
  const dev = st === null ? '<p class="m" style="margin:0">მოწყობილობის შემოწმება…</p>'
    : msg ? `<p class="m" style="margin:0">${msg}</p>`
    : `<label class="pr"><span><b>შეტყობინებები ამ მოწყობილობაზე</b><small>${on ? 'ჩართულია: ქვემოთ მონიშნული მოვლენები ამ ტელეფონზე მოვა, აპი დახურულიც რომ იყოს' : 'გამორთულია. ჩართვისას ბრაუზერი ნებართვას მოგთხოვს'}</small></span><span class="sw"><input type="checkbox" ${on ? 'checked' : ''} onchange="ntDev(this.checked)"><i></i></span></label>`;
  const row = e => {
    const [k, t, d, num, unit] = e;
    return `<label class="pr" for="nt_${k}"><span><b>${t}</b><small>${d}</small>${num ? `<span onclick="event.preventDefault()" style="display:flex;align-items:center;gap:8px;margin-top:8px;white-space:nowrap;font-size:13px">${k === 'big' ? 'ჩეკი ≥' : 'დარჩა ≤'}<input type="number" min="0" step="${k === 'big' ? 50 : 1}" inputmode="numeric" value="${NT[num]}" style="width:84px;min-width:0;padding:5px 8px" onchange="ntNum('${num}',this)">${unit}</span>` : ''}</span><span class="sw"><input type="checkbox" id="nt_${k}" ${NT.ev[k] ? 'checked' : ''} onchange="ntSet('${k}',this.checked)"><i></i></span></label>`;
  };
  return `<section><div class="hd">${emNav()}</div>
<div class="sgs">${dev}${ntErr ? `<small style="color:#c23b3b;display:block;margin-top:6px">${esc(ntErr)}</small>` : ''}
<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:10px">${on ? '<button onclick="ntTest()">სატესტო შეტყობინება</button>' : ''}</div>
<small class="m" style="display:block;margin-top:8px">არჩევანი ეკუთვნის ამ ტელეფონს: თითოეული ადმინისტრატორი თავის ტელეფონზე თავად ირჩევს, რა მოუვიდეს.${!on && st && st !== 'demo' && !msg ? ' ჩართვამდეც შეგიძლია მონიშვნა, შენახული არჩევანი ჩართვისას გამოიყენება.' : ''}</small></div></section>
<section><div class="hd" style="gap:8px"><h3 style="margin:0">ფილიალები</h3></div>
<span class="sg2" style="max-width:100%;overflow-x:auto"><button class="${NT.br.length ? '' : 'on'}" onclick="ntBr('')">ყველა ფილიალი</button>${BR.map(b => `<button class="${NT.br.includes(b) ? 'on' : ''}" onclick="ntBr(${esc(JSON.stringify(b))})">${esc(b)}</button>`).join('')}</span>
<small class="m" style="display:block;margin-top:8px">${NT.br.length ? 'შეტყობინება მოვა მხოლოდ მონიშნული ფილიალებიდან' : 'შეტყობინება მოვა ყველა ფილიალიდან'}</small></section>
<section><div class="hd" style="gap:8px"><h3 style="margin:0">რა მოვიდეს შეტყობინებად <small class="m" style="font-weight:400">· მონიშნულია ${n} / ${NT_KINDS.length}</small></h3><span class="f"><button onclick="ntAll(1)">ყველას მონიშვნა</button><button onclick="ntAll(0)">გასუფთავება</button></span></div>
${NT_GROUPS.map(g => `<h4 style="margin:14px 0 8px">${g[0]}</h4><div class="sgs">${g[1].map(row).join('')}</div>`).join('')}</section>`;
}
