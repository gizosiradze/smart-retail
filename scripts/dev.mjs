#!/usr/bin/env node
// Local development with Node only (no Docker): the app runs on http://localhost:5173 and uses a
// separate, free Supabase TEST project configured in .env.test (never the production project).
//
//   npm run dev:setup     first time (and after new migrations): deploy the schema and the login function
//                         to the test project, add the demo shop, and a Super Admin only if SUPERADMIN_EMAIL/PASSWORD are set
//   npm run dev           serve the app on http://localhost:5173
//   npm run dev:lan       same, also reachable from phones/tablets/PCs on the same Wi-Fi
//
// Options: --env <file> (default .env.test), --port <n> (default 5173), --lan (listen on all network interfaces)
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { arg, flag, loadEnv, need, die, step, writeConfig, ROOT, projectRef } from './lib.mjs';

const envFile = arg('env', '.env.test');
const port = +(arg('port', process.env.PORT || 5173));
const lan = flag('lan');
const lanIps = () => Object.values(os.networkInterfaces()).flat()
  .filter(i => i && i.family === 'IPv4' && !i.internal).map(i => i.address);

// never point the development setup at the production project
const prodRef = (() => { const s = process.env; const saved = { ...s }; loadEnv('.env'); const r = s.SUPABASE_PROJECT_REF;
  for (const k of Object.keys(s)) if (!(k in saved)) delete s[k]; Object.assign(s, saved); return r })();
if (!loadEnv(envFile)) die(`${envFile} not found. Create a free Supabase project for testing, then:
    copy .env.example to ${envFile} and fill it in with THAT project's values
    npm run dev:setup`);
need('SUPABASE_URL', 'SUPABASE_ANON_KEY');
const ref = process.env.SUPABASE_PROJECT_REF || projectRef(process.env.SUPABASE_URL);
if (prodRef && ref === prodRef) die(`${envFile} points at the production project (${ref}). Use a separate test project.`);

const node = (script, args) => spawnSync(process.execPath, [path.join(ROOT, 'scripts', script), '--env', envFile, ...args],
  { cwd: ROOT, stdio: 'inherit' }).status;

if (flag('setup')) {
  need('SUPABASE_SERVICE_ROLE_KEY');
  if (node('deploy.mjs', ['--yes']) !== 0) die('deploy to the test project failed');
  step('Demo shop "demo" (users admin, kasa1, kasa2, sawyobi · password 1234)');
  const r = spawnSync(process.execPath, [path.join(ROOT, 'scripts', 'import-legacy.mjs'), '--env', envFile, '--store', 'seed/demo-store.json',
    '--slug', 'demo', '--name', 'Smart Retail დემო', '--keep-passwords'], { cwd: ROOT, encoding: 'utf8' });
  if (r.status === 0) process.stdout.write(r.stdout);
  else if (/SLUG_TAKEN/.test(r.stderr + r.stdout)) console.log('already there');
  else die('demo import failed:\n' + r.stderr);
  step('Super Admin');
  // No built-in default account: a known password on a database that holds real data is a hole
  // (the first sign-in sets up the authenticator, so whoever signs in first owns the platform).
  const email = process.env.SUPERADMIN_EMAIL, pass = process.env.SUPERADMIN_PASSWORD;
  if (!email || !pass) console.log(`skipped: set SUPERADMIN_EMAIL and SUPERADMIN_PASSWORD (12+ characters) in ${envFile} to create one`);
  else {
    if (node('create-superadmin.mjs', ['--email', email, '--password', pass]) !== 0) die('could not create the Super Admin');
    console.log(`  ${email} (password from ${envFile})`);
  }
}

if (!/localhost|\*/.test(process.env.ALLOWED_ORIGINS || '*'))
  console.warn(`! ALLOWED_ORIGINS in ${envFile} does not include http://localhost:${port}: login will be blocked. Add it and run npm run dev:setup.`);
writeConfig({ url: process.env.SUPABASE_URL, anonKey: process.env.SUPABASE_ANON_KEY,
  demoHint: process.env.DEMO_HINT ?? 'სატესტო: მაღაზია demo · admin / kasa1 / kasa2 / sawyobi · პაროლი 1234' });

// ---------------------------------------------------------------- static web server
const WEB = path.join(ROOT, 'web');
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };
http.createServer((req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (p === '/superadmin' || p === '/app') { res.writeHead(301, { Location: p + '/' }); return res.end() }
  let file = path.normalize(path.join(WEB, p));
  if (!file.startsWith(WEB)) { res.writeHead(403); return res.end() }
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
  if (!fs.existsSync(file)) { res.writeHead(404, { 'Content-Type': 'text/plain' }); return res.end('not found') }
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
  fs.createReadStream(file).pipe(res);
}).listen(port, lan ? '0.0.0.0' : '127.0.0.1', () => console.log(`
  Smart Retail (test project ${ref})
  ─────────────────────────────────────────
  Home page    http://localhost:${port}
  App (login)  http://localhost:${port}/app/
  Super Admin  http://localhost:${port}/superadmin/
${lan ? lanIps().map(ip => `  Network      http://${ip}:${port}   (other devices on this Wi-Fi)\n`).join('') || '  Network      no Wi-Fi/LAN address found\n' : ''}  Database     https://supabase.com/dashboard/project/${ref}

  Shop: demo · admin / kasa1 / kasa2 / sawyobi · password 1234
  Ctrl+C to stop.
`));
