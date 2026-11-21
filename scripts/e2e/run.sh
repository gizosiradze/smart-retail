#!/usr/bin/env bash
# Runs the app end-to-end test against a fresh database: migrations + demo seed, the fake gateway,
# then scripts/e2e/app-e2e.mjs. Needs psql and node (no Docker).
#   E2E_ADMIN_URL=postgresql://postgres@localhost:5432/postgres scripts/e2e/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
ADMIN="${E2E_ADMIN_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
DBN="sr_e2e_$$"; export E2E_DB_URL="${ADMIN%/*}/$DBN"; export PORT="${PORT:-$((54400 + RANDOM % 500))}"; export E2E_API="http://127.0.0.1:$PORT"
psql "$ADMIN" -qc "create database $DBN" >/dev/null
cleanup() { [ -n "${GW:-}" ] && kill "$GW" 2>/dev/null || true; [ -n "${WEBPID:-}" ] && kill "$WEBPID" 2>/dev/null || true; rm -rf "${WEBDIR:-/nonexistent}"; psql "$ADMIN" -qc "drop database if exists $DBN with (force)" >/dev/null 2>&1 || true; }
trap cleanup EXIT
apply() { psql "$E2E_DB_URL" -qv ON_ERROR_STOP=1 -f "$1" >/dev/null 2> >(grep -v NOTICE >&2); }
psql "$E2E_DB_URL" -Atc "select 1 from pg_roles where rolname='authenticated'" | grep -q 1 || apply supabase/tests/00_supabase_stub.sql
psql "$E2E_DB_URL" -Atc "select 1 from pg_namespace where nspname='auth'" | grep -q 1 || apply supabase/tests/00_supabase_stub.sql
for f in supabase/migrations/*.sql supabase/seed.sql; do apply "$f"; done
node scripts/e2e/fake-gateway.mjs > /tmp/sr-fake-gateway.log 2>&1 & GW=$!
sleep 1
node scripts/e2e/app-e2e.mjs

# Real browser, if Chrome/Chromium is installed (a copy of web/ pointing at the fake gateway)
CHROME="${CHROME:-$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)}"
if [ -n "$CHROME" ]; then
  # the browser test gets its own fresh demo database and gateway
  kill "$GW" 2>/dev/null || true
  psql "$ADMIN" -qc "drop database $DBN with (force)" >/dev/null; psql "$ADMIN" -qc "create database $DBN" >/dev/null
  psql "$E2E_DB_URL" -Atc "select 1 from pg_namespace where nspname='auth'" | grep -q 1 || apply supabase/tests/00_supabase_stub.sql
  for f in supabase/migrations/*.sql supabase/seed.sql; do apply "$f"; done
  node scripts/e2e/fake-gateway.mjs > /tmp/sr-fake-gateway.log 2>&1 & GW=$!
  WEBDIR=$(mktemp -d); cp -r web/. "$WEBDIR/"; WEBPORT=$((55000 + RANDOM % 500))
  printf 'window.SR_CONFIG={url:"%s",anonKey:"anon-test-key"};\n' "$E2E_API" > "$WEBDIR/config.js"
  python3 -m http.server "$WEBPORT" --bind 127.0.0.1 -d "$WEBDIR" >/dev/null 2>&1 & WEBPID=$!
  sleep 1
  CHROME="$CHROME" APP_URL="http://127.0.0.1:$WEBPORT" node scripts/e2e/browser-e2e.mjs
else
  echo "(Chrome not found: browser test skipped)"
fi
