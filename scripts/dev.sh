#!/usr/bin/env bash
# Local development: the whole stack on your computer, app on http://localhost:5173
#
#   scripts/dev.sh           start (first run downloads the Supabase containers, a few minutes)
#   scripts/dev.sh --reset   start from a clean database: migrations + demo shop again
#   scripts/dev.sh --stop    stop the containers
#
# Needs: Docker Desktop (running), Node.js 18+, Python 3 (for the static web server).
# Demo logins:  shop "demo" · admin / kasa1 / kasa2 / sawyobi · password 1234
#               Super Admin: http://localhost:5173/superadmin/ · admin@smartretail.local / superadmin-local-1
set -euo pipefail
cd "$(dirname "$0")/.."

SB=(npx --yes supabase@2)
command -v supabase >/dev/null 2>&1 && SB=(supabase)
WEB_PORT="${WEB_PORT:-5173}"

if [[ "${1:-}" == "--stop" ]]; then "${SB[@]}" stop; exit 0; fi
docker info >/dev/null 2>&1 || { echo "Docker is not running. Start Docker Desktop and try again." >&2; exit 1; }

echo "▶ Starting Supabase (database, auth, storage, API)…"
"${SB[@]}" start
if [[ "${1:-}" == "--reset" ]]; then
  echo "▶ Resetting the database (migrations + demo shop)…"
  "${SB[@]}" db reset
fi

# read the local keys
eval "$("${SB[@]}" status -o env | sed -n 's/^\([A-Z_]*\)=\(.*\)$/export LOCAL_\1=\2/p')"
API_URL="${LOCAL_API_URL:-http://127.0.0.1:54321}"
ANON="${LOCAL_ANON_KEY:-${LOCAL_PUBLISHABLE_KEY:-}}"
SERVICE="${LOCAL_SERVICE_ROLE_KEY:-${LOCAL_SECRET_KEY:-}}"
JWT="${LOCAL_JWT_SECRET:-super-secret-jwt-token-with-at-least-32-characters-long}"
[[ -n "$ANON" && -n "$SERVICE" ]] || { echo "Could not read the local API keys from 'supabase status'." >&2; exit 1; }

cat > supabase/functions/.env <<EOF
APP_JWT_SECRET=$JWT
ALLOWED_ORIGINS=*
EOF

SUPABASE_URL="$API_URL" SUPABASE_ANON_KEY="$ANON" \
  DEMO_HINT="ლოკალური დემო: მაღაზია demo · admin / kasa1 / kasa2 / sawyobi · პაროლი 1234" scripts/write-config.sh

echo "▶ Super Admin account (local only)…"
node scripts/create-superadmin.mjs --url "$API_URL" --service-key "$SERVICE" \
  --email admin@smartretail.local --password superadmin-local-1 || true

echo "▶ Edge Functions…"
"${SB[@]}" functions serve --env-file supabase/functions/.env --no-verify-jwt > /tmp/smart-retail-functions.log 2>&1 &
FN=$!
trap 'kill $FN 2>/dev/null || true' EXIT

cat <<EOF

  Smart Retail is running
  ─────────────────────────────────────────────
  App          http://localhost:$WEB_PORT
  Super Admin  http://localhost:$WEB_PORT/superadmin/
  Studio (DB)  ${LOCAL_STUDIO_URL:-http://127.0.0.1:54323}
  API          $API_URL
  Functions log /tmp/smart-retail-functions.log

  Shop: demo · users admin, kasa1, kasa2, sawyobi · password 1234
  Super Admin: admin@smartretail.local / superadmin-local-1 (then scan the QR code with an authenticator app)

  Ctrl+C stops the web server and functions; 'scripts/dev.sh --stop' stops the database.
EOF
python3 -m http.server "$WEB_PORT" --bind 127.0.0.1 -d web
