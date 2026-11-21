#!/usr/bin/env node
// Writes web/config.js, the only place the web pages learn where Supabase is.
// Both values are public by design (the anon/publishable key can do nothing without a login token).
//
//   node scripts/write-config.mjs                 values from the environment (SUPABASE_URL, SUPABASE_ANON_KEY)
//   node scripts/write-config.mjs --env .env.test values from an env file
//
// Cloudflare Pages: build command "node scripts/write-config.mjs", output directory "web",
// and SUPABASE_URL / SUPABASE_ANON_KEY as environment variables of the Pages project.
import { arg, loadEnv, need, writeConfig } from './lib.mjs';
if (arg('env')) loadEnv(arg('env'));
need('SUPABASE_URL', 'SUPABASE_ANON_KEY');
writeConfig({ url: process.env.SUPABASE_URL, anonKey: process.env.SUPABASE_ANON_KEY, demoHint: process.env.DEMO_HINT || '' });
