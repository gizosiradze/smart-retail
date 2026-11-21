// Minimal stand-in for the Supabase API gateway, used only by scripts/e2e/app-e2e.mjs when Docker
// (and therefore the real local Supabase stack) is not available, e.g. in CI.
// It implements exactly what the app uses: POST /functions/v1/store-login and POST /rest/v1/rpc/<fn>,
// verifying the HS256 JWT and calling the real database functions through psql.
import http from 'node:http';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

const PSQL = (process.env.PSQL || 'psql').split(' ');
const DB = process.env.E2E_DB_URL;
const SECRET = process.env.APP_JWT_SECRET || 'super-secret-jwt-token-with-at-least-32-characters-long';
const PORT = +(process.env.PORT || 54399);

const b64u = b => Buffer.from(b).toString('base64url');
function sign(p) {
  const h = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' })), b = b64u(JSON.stringify(p));
  return `${h}.${b}.${crypto.createHmac('sha256', SECRET).update(`${h}.${b}`).digest('base64url')}`;
}
function verify(t) {
  const [h, b, s] = String(t || '').split('.');
  if (!s || crypto.createHmac('sha256', SECRET).update(`${h}.${b}`).digest('base64url') !== s) return null;
  const c = JSON.parse(Buffer.from(b, 'base64url').toString());
  return c.exp && c.exp * 1000 < Date.now() ? null : c;
}
function sql(q) {
  try {
    return { out: execFileSync(PSQL[0], [...PSQL.slice(1), DB, '-qAtX', '-v', 'ON_ERROR_STOP=1'], { input: q, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }) };
  } catch (e) {
    const m = String(e.stderr || '').match(/ERROR:\s+(.*)/);
    return { err: m ? m[1].trim() : String(e.stderr || e.message) };
  }
}
const lit = v => '$q$' + JSON.stringify(v) + '$q$::jsonb';
const CALLS = {
  sr_me: () => 'public.sr_me()',
  sr_logout: () => `(select 'null'::jsonb from (select public.sr_logout()) z)`,
  sr_alloc_ids: a => `public.sr_alloc_ids((${lit(a)}->>'p_count')::int)`,
  sr_pull: a => `public.sr_pull(array(select jsonb_array_elements_text(${lit(a)}->'p_colls')), coalesce(${lit(a)}->'p_cursors','{}'))`,
  sr_push: a => `public.sr_push(${lit(a)}->'p')`,
  sr_platform_import_store: a => `public.sr_platform_import_store(${lit(a)}->>'p_slug', ${lit(a)}->>'p_name', ${lit(a)}->'p_data',
     case when jsonb_typeof(${lit(a)}->'p_branches') = 'array' then array(select jsonb_array_elements_text(${lit(a)}->'p_branches')) end,
     coalesce((${lit(a)}->>'p_force_password_change')::boolean, true))`,
  sr_platform_register_store: a => `public.sr_platform_register_store(${lit(a)}->'d')`,
  sr_platform_push: a => `public.sr_platform_push(${lit(a)}->'p')`,
  sr_platform_add_admin: a => `(select 'null'::jsonb from (select public.sr_platform_add_admin((${lit(a)}->>'p_user')::uuid, ${lit(a)}->>'p_email')) z)`,
  sr_change_password: a => `(select 'null'::jsonb from (select public.sr_change_password(${lit(a)}->>'p_old', ${lit(a)}->>'p_new')) z)`,
};

http.createServer((req, res) => {
  let body = '';
  req.on('data', d => body += d);
  req.on('end', () => {
    const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info, x-upsert', 'access-control-allow-methods': 'POST, OPTIONS' };
    const send = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json', ...cors }); res.end(JSON.stringify(obj)) };
    if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end() }
    const args = body ? JSON.parse(body) : {};
    if (req.url === '/functions/v1/store-login') {
      const r = sql(`begin; set local role service_role; select set_config('request.jwt.claims','{"role":"service_role"}',true);
        select public.sr_login(${lit(args)}->>'shop', ${lit(args)}->>'username', ${lit(args)}->>'password', '127.0.0.1', 'e2e'); commit;`);
      if (r.err) return send(500, { error: r.err });
      const j = JSON.parse(r.out.trim().split('\n').pop());
      if (!j.ok) return send(401, { error: j.error });
      return send(200, { token: sign({ role: 'authenticated', aud: 'authenticated', sub: j.user_id, app_uid: j.user_id, store_id: j.store_id, app_role: j.role, jti: j.jti, exp: j.exp }), exp: j.exp });
    }
    if (req.url === '/auth/v1/admin/users' && req.headers.apikey === 'service-test-key') {
      const r = sql(`insert into auth.users (email) values (${lit(args)}->>'email') returning json_build_object('id', id, 'email', email);`);
      return r.err ? send(422, { msg: r.err }) : send(200, JSON.parse(r.out.trim().split('\n').pop()));
    }
    const m = req.url.match(/^\/rest\/v1\/rpc\/(\w+)$/);
    if (!m || !CALLS[m[1]]) return send(404, { message: 'not found' });
    const service = req.headers.apikey === 'service-test-key';
    const claims = service ? { role: 'service_role' } : verify((req.headers.authorization || '').replace(/^Bearer /, ''));
    if (!claims) return send(401, { message: 'JWT expired' });
    const r = sql(`begin; set local role ${service ? 'service_role' : 'authenticated'}; select set_config('request.jwt.claims', ${lit(claims)}::text, true);
      select coalesce(to_jsonb(${CALLS[m[1]](args)}), 'null'::jsonb); commit;`);
    if (r.err) return send(/SESSION|28000/.test(r.err) ? 401 : 400, { message: r.err });
    send(200, JSON.parse(r.out.trim().split('\n').pop()));
  });
}).listen(PORT, () => console.log('fake gateway on', PORT));
