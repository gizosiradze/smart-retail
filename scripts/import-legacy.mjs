#!/usr/bin/env node
// One-time import of the prototype's data into Supabase.
//
// 1. Export from the prototype (in the browser, on the artifact page):
//      open DevTools → Console → pick the artifact's frame in the context menu → run
//      copy(localStorage.getItem('rms1'))              (main app)
//      copy(localStorage.getItem('rms_superadmin_v1')) (Super Admin)
//    and paste each into a file, e.g. export/app.json and export/superadmin.json.
//    No export yet? seed/demo-store.json is the prototype's own demo data.
// 2. Import:
//      node scripts/import-legacy.mjs --store export/app.json --slug batumipets --name "ბათუმი ფეთს"
//      node scripts/import-legacy.mjs --superadmin export/superadmin.json
//    Connection: --env <file> (default .env) or --url/--service-key.
//
// Store import: staff passwords are bcrypt-hashed and everyone must choose a new one at first login
// (add --keep-passwords to skip that, e.g. for a demo). Base64 product photos are uploaded to Storage.
// Super Admin import: plans, settings and announcements are copied; every store in the file is
// registered as a real store (admin + cashier accounts with new temporary passwords, printed once);
// payments and the audit log follow their store.
import fs from 'node:fs';
import { loadEnv as loadEnvFile } from './lib.mjs';

const arg = n => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : undefined };
const flag = n => process.argv.includes('--' + n);
loadEnvFile(arg('env') || '.env');
const url = (arg('url') || process.env.SUPABASE_URL || '').replace(/\/$/, '');
const key = arg('service-key') || process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key || (!arg('store') && !arg('superadmin'))) {
  console.error('usage: import-legacy.mjs --store <file.json> --slug <shop> [--name <name>] [--branches a,b] [--keep-passwords]\n' +
                '       import-legacy.mjs --superadmin <file.json>\n       (plus --url/--service-key or .env)');
  process.exit(2);
}
const H = { apikey: key, 'Content-Type': 'application/json', ...(key.startsWith('eyJ') ? { Authorization: 'Bearer ' + key } : {}) };
async function rpc(fn, body) {
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, { method: 'POST', headers: H, body: JSON.stringify(body) });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${t}`);
  return t ? JSON.parse(t) : null;
}
const read = f => { const t = fs.readFileSync(f, 'utf8').trim(); return JSON.parse(t.startsWith('"') ? JSON.parse(t) : t) };

if (arg('store')) {
  const data = read(arg('store')), slug = (arg('slug') || '').toLowerCase();
  if (!/^[a-z0-9][a-z0-9_-]{1,39}$/.test(slug)) { console.error('--slug: Latin lowercase letters, digits, - or _'); process.exit(2) }
  const name = arg('name') || slug, branches = arg('branches') ? arg('branches').split(',').map(s => s.trim()) : null;

  // photos: upload base64 images first (the store id is not known yet, so they go under a temporary folder)
  const folder = 'import-' + slug + '-' + Date.now().toString(36);
  let n = 0;
  for (const c of ['p', 'dp']) for (const p of data[c] || []) {
    if (typeof p.img !== 'string' || !p.img.startsWith('data:image/')) continue;
    const [, type, b64] = p.img.match(/^data:(image\/[a-z+]+);base64,(.*)$/) || [];
    if (!b64) continue;
    const path = `${folder}/${c}-${p.id}.${type.split('/')[1].replace('jpeg', 'jpg')}`;
    const r = await fetch(`${url}/storage/v1/object/product-images/${path}`, { method: 'POST',
      headers: { ...H, 'Content-Type': type, 'x-upsert': 'true' }, body: Buffer.from(b64, 'base64') });
    if (!r.ok) throw new Error(`photo upload failed for product ${p.id}: ${r.status} ${await r.text()}`);
    p.img = `${url}/storage/v1/object/public/product-images/${path}`; n++;
  }
  if (n) console.log(`✓ ${n} product photo(s) uploaded`);
  const res = await rpc('sr_platform_import_store', { p_slug: slug, p_name: name, p_data: data, p_branches: branches,
    p_force_password_change: !flag('keep-passwords') });
  console.log(`✓ store "${slug}" imported (${res.store_id})`);
  console.log('  branches:', (res.branches || []).join(', '));
  console.log('  records: ', Object.entries(res.counts).filter(([, v]) => v).map(([k, v]) => `${k}=${v}`).join(' '));
  console.log('  next receipt number:', res.id_counter);
}

if (arg('superadmin')) {
  const S = read(arg('superadmin'));
  const ids = {};
  for (const s of S.stores || []) {
    const doc = { ...s, login: String(s.login || '').toLowerCase() };
    delete doc.users; delete doc.id;
    try {
      const r = await rpc('sr_platform_register_store', { d: doc });
      ids[s.id] = r.store.id;
      console.log(`✓ ${doc.login}: ` + r.credentials.map(c => `${c.u} / ${c.pw}`).join(', '));
    } catch (e) {
      if (/SLUG_TAKEN/.test(e.message)) { console.log(`• ${doc.login}: already exists, skipped`); continue }
      throw e;
    }
  }
  const fix = x => ({ ...x, store: ids[x.store] || x.store, s: ids[x.s] || x.s });
  await rpc('sr_platform_push', { p: {
    plans: S.plans || [], ann: (S.ann || []).map(fix), settings: S.settings || undefined,
    payments: (S.payments || []).filter(p => ids[p.store]).map(fix),
    audit: (S.audit || []).map((a, i) => ({ id: a.id || 'imp-' + i, ...fix(a) }))
  } });
  console.log(`✓ Super Admin data imported: ${Object.keys(ids).length} store(s), ${(S.payments || []).length} payment(s)`);
  console.log('  Keep the passwords above safe: they are stored only as hashes and cannot be shown again.');
}
