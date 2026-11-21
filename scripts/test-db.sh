#!/usr/bin/env bash
# Runs every migration and the SQL test-suite against a throw-away PostgreSQL database.
#
#   scripts/test-db.sh                       # uses the local Supabase stack (supabase start) if it is running
#   DATABASE_URL=postgres://... scripts/test-db.sh   # any empty PostgreSQL 15+ database you can drop
#
# On a plain PostgreSQL (no Supabase), the stub in supabase/tests/00_supabase_stub.sql provides the
# roles and the auth/storage objects that Supabase normally creates.
set -euo pipefail
cd "$(dirname "$0")/.."

URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
DB="sr_test_$$"
ADMIN_URL="$URL"
TEST_URL="${URL%/*}/$DB"

psql "$ADMIN_URL" -qv ON_ERROR_STOP=1 -c "create database $DB" >/dev/null
trap 'psql "$ADMIN_URL" -qc "drop database if exists $DB with (force)" >/dev/null 2>&1 || true' EXIT

run() { psql "$TEST_URL" -qv ON_ERROR_STOP=1 -f "$1" >/dev/null 2> >(grep -v NOTICE >&2); }

# Supabase stack already has these objects; a plain server needs the stub.
if ! psql "$TEST_URL" -Atc "select 1 from pg_roles where rolname='authenticated'" | grep -q 1 \
   || ! psql "$TEST_URL" -Atc "select 1 from pg_namespace where nspname='auth'" | grep -q 1; then
  run supabase/tests/00_supabase_stub.sql
fi
for f in supabase/migrations/*.sql; do run "$f"; done
echo "✓ migrations applied ($(ls supabase/migrations/*.sql | wc -l) files)"

fail=0
for f in supabase/tests/[1-9]*.sql; do
  if out=$(psql "$TEST_URL" -qAt -v ON_ERROR_STOP=1 -o /dev/null -f "$f" 2>&1 | grep -v NOTICE); [ -z "$out" ]; then
    echo "✓ $(basename "$f")"
  else
    echo "✗ $(basename "$f")"; echo "$out" | sed 's/^/    /'; fail=1
  fi
done
exit $fail
