#!/usr/bin/env node
// Creates (or updates) a Super Admin: a Supabase Auth user + a row in app.platform_admins.
// The authenticator app (TOTP) is enrolled by the person on their first sign-in at /superadmin/.
//
//   node scripts/create-superadmin.mjs --url https://xxxx.supabase.co --service-key <service role key> \
//        --email you@example.com --password '<at least 12 characters>'
// Values can also come from SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPERADMIN_EMAIL, SUPERADMIN_PASSWORD.
const arg = n => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : undefined };
const url = (arg('url') || process.env.SUPABASE_URL || '').replace(/\/$/, '');
const key = arg('service-key') || process.env.SUPABASE_SERVICE_ROLE_KEY;
const email = arg('email') || process.env.SUPERADMIN_EMAIL;
const password = arg('password') || process.env.SUPERADMIN_PASSWORD;
if (!url || !key || !email || !password) {
  console.error('usage: create-superadmin.mjs --url <SUPABASE_URL> --service-key <key> --email <email> --password <password>');
  process.exit(2);
}
if (password.length < 12 && !/127\.0\.0\.1|localhost/.test(url)) { console.error('Use a password of at least 12 characters.'); process.exit(2); }

const H = { apikey: key, 'Content-Type': 'application/json', ...(key.startsWith('eyJ') ? { Authorization: 'Bearer ' + key } : {}) };
async function req(path, opt = {}) {
  const r = await fetch(url + path, { ...opt, headers: { ...H, ...(opt.headers || {}) } });
  const t = await r.text(); const j = t ? JSON.parse(t) : null;
  if (!r.ok) throw new Error(`${r.status} ${t}`);
  return j;
}

let user;
try {
  user = await req('/auth/v1/admin/users', { method: 'POST', body: JSON.stringify({ email, password, email_confirm: true }) });
} catch (e) {
  if (!/already|exists|registered/i.test(e.message)) throw e;
  const list = await req('/auth/v1/admin/users?per_page=1000');
  user = (list.users || []).find(u => (u.email || '').toLowerCase() === email.toLowerCase());
  if (!user) throw e;
  await req('/auth/v1/admin/users/' + user.id, { method: 'PUT', body: JSON.stringify({ password }) });
}
await req('/rest/v1/rpc/sr_platform_add_admin', { method: 'POST', body: JSON.stringify({ p_user: user.id, p_email: email }) });
console.log(`✓ Super Admin ready: ${email} (sign in at /superadmin/, the first sign-in sets up the authenticator app)`);
