#!/usr/bin/env node
// One command to deploy the database and the API to a Supabase project. No Docker needed.
//
//   npm run deploy                         production, settings from .env (asks before changing the database)
//   npm run deploy -- --env .env.test      the test project used for local development
//   npm run deploy -- --yes                no question (CI)
//   npm run deploy -- --dry-run            only list the migrations that would run
//   npm run deploy -- --web                also publish web/ to Cloudflare Pages (CLOUDFLARE_* in the env file)
//
// Steps: link project → migrations → Edge Function secrets → store-login → token check → web/config.js.
// Seed data is never deployed.
import readline from 'node:readline/promises';
import { spawnSync } from 'node:child_process';
import { arg, flag, loadEnv, need, die, step, supabase, writeConfig, checkTokens, ROOT } from './lib.mjs';

const envFile = arg('env', '.env');
if (!loadEnv(envFile)) die(`${envFile} not found: copy .env.example to ${envFile} and fill it in`);
need('SUPABASE_PROJECT_REF', 'SUPABASE_ACCESS_TOKEN', 'SUPABASE_DB_PASSWORD', 'SUPABASE_URL', 'SUPABASE_ANON_KEY', 'APP_JWT_SECRET');
const ref = process.env.SUPABASE_PROJECT_REF, pw = process.env.SUPABASE_DB_PASSWORD;
if (!process.env.SUPABASE_URL.includes(ref)) die(`SUPABASE_URL does not belong to project ${ref}`);
console.log(`Deploying to ${ref} (${envFile})`);

step(`Linking project ${ref}`);
supabase(['link', '--project-ref', ref, '--password', pw], { quiet: true });

step('Database migrations');
supabase(['db', 'push', '--dry-run', '--password', pw]);
if (flag('dry-run')) { console.log('(dry run: nothing changed)'); process.exit(0) }
if (!flag('yes')) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const a = await rl.question(`Apply these migrations to ${ref}? [y/N] `); rl.close();
  if (!/^y(es)?$/i.test(a.trim())) die('stopped, nothing was changed');
}
supabase(['db', 'push', '--password', pw], { input: 'y\n' });

step('Edge Function secrets');
supabase(['secrets', 'set', '--project-ref', ref, `APP_JWT_SECRET=${process.env.APP_JWT_SECRET}`,
  `ALLOWED_ORIGINS=${process.env.ALLOWED_ORIGINS || '*'}`], { quiet: true });
console.log('APP_JWT_SECRET, ALLOWED_ORIGINS set');

step('Edge Function store-login');
supabase(['functions', 'deploy', 'store-login', '--project-ref', ref, '--no-verify-jwt', '--use-api']);

step('Checking that the project accepts our login tokens');
const t = await checkTokens();
if (!t.ok) die(`Supabase did not accept a token signed with APP_JWT_SECRET: ${t.body}
  Use the project's legacy JWT secret: Dashboard → Project Settings → JWT Keys → Legacy JWT secret.`);
console.log('✓ tokens accepted');

step('web/config.js');
writeConfig({ url: process.env.SUPABASE_URL, anonKey: process.env.SUPABASE_ANON_KEY, demoHint: process.env.DEMO_HINT || '' });

if (flag('web')) {
  need('CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID', 'CLOUDFLARE_PAGES_PROJECT');
  step(`Publishing web/ to Cloudflare Pages (${process.env.CLOUDFLARE_PAGES_PROJECT})`);
  const r = spawnSync('npx', ['--yes', 'wrangler@3', 'pages', 'deploy', 'web', '--project-name', process.env.CLOUDFLARE_PAGES_PROJECT,
    '--branch', process.env.CLOUDFLARE_BRANCH || 'main'], { cwd: ROOT, stdio: 'inherit', shell: process.platform === 'win32' });
  if (r.status !== 0) die('Cloudflare Pages deploy failed');
}

console.log(`
✓ Deployed to ${process.env.SUPABASE_URL}
  First deploy only:
   • Super Admin:  npm run superadmin -- --env ${envFile} --email you@example.com --password '…'
   • Import data:  npm run import -- --env ${envFile} --store export/app.json --slug <shop> --name "<name>"
   • Set ALLOWED_ORIGINS in ${envFile} to your site address and run this again.`);
