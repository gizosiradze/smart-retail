#!/usr/bin/env bash
# One command to deploy the database and the API to your Supabase project.
#
#   scripts/deploy.sh            migrations + Edge Function + secrets + web/config.js (asks before changing the database)
#   scripts/deploy.sh --yes      same, without the question (CI)
#   scripts/deploy.sh --dry-run  only shows which migrations would run
#   scripts/deploy.sh --web      also publishes web/ to Cloudflare Pages (needs CLOUDFLARE_* in .env)
#
# Settings come from .env (copy .env.example). Never deploys seed data: production starts empty;
# use scripts/import-legacy.mjs for the one-time import.
set -euo pipefail
cd "$(dirname "$0")/.."

YES=0; DRY=0; WEB=0
for a in "$@"; do case "$a" in --yes|-y) YES=1;; --dry-run) DRY=1;; --web) WEB=1;; *) echo "unknown option $a" >&2; exit 2;; esac; done

[[ -f .env ]] && { set -a; . ./.env; set +a; }
need() { [[ -n "${!1:-}" ]] || { echo "✗ $1 is not set (see .env.example)" >&2; exit 1; }; }
need SUPABASE_PROJECT_REF; need SUPABASE_ACCESS_TOKEN; need SUPABASE_DB_PASSWORD
need SUPABASE_URL; need SUPABASE_ANON_KEY; need APP_JWT_SECRET
export SUPABASE_ACCESS_TOKEN

SB=(npx --yes supabase@2)
command -v supabase >/dev/null 2>&1 && SB=(supabase)
step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }

step "Linking project $SUPABASE_PROJECT_REF"
"${SB[@]}" link --project-ref "$SUPABASE_PROJECT_REF" --password "$SUPABASE_DB_PASSWORD" >/dev/null

step "Database migrations"
"${SB[@]}" db push --dry-run --password "$SUPABASE_DB_PASSWORD"
if [[ $DRY == 1 ]]; then echo "(dry run: nothing changed)"; exit 0; fi
if [[ $YES != 1 ]]; then
  read -r -p "Apply these migrations to $SUPABASE_PROJECT_REF? [y/N] " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { echo "Stopped. Nothing was changed."; exit 1; }
fi
"${SB[@]}" db push --password "$SUPABASE_DB_PASSWORD"

step "Edge Function secrets"
"${SB[@]}" secrets set --project-ref "$SUPABASE_PROJECT_REF" \
  APP_JWT_SECRET="$APP_JWT_SECRET" ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-*}" >/dev/null
echo "APP_JWT_SECRET, ALLOWED_ORIGINS set"

step "Edge Function store-login"
"${SB[@]}" functions deploy store-login --project-ref "$SUPABASE_PROJECT_REF" --no-verify-jwt

step "Checking that the project accepts our login tokens"
# A token signed with APP_JWT_SECRET but without a session must reach the database and be refused
# there with SESSION_REQUIRED. "invalid JWT" means APP_JWT_SECRET is not the project's JWT secret.
TOKEN=$(node --input-type=module -e "
import crypto from 'node:crypto';
const b=o=>Buffer.from(JSON.stringify(o)).toString('base64url');
const h=b({alg:'HS256',typ:'JWT'}),p=b({role:'authenticated',aud:'authenticated',exp:Math.floor(Date.now()/1000)+60});
process.stdout.write(h+'.'+p+'.'+crypto.createHmac('sha256',process.env.APP_JWT_SECRET).update(h+'.'+p).digest('base64url'));")
RES=$(curl -sS -X POST "${SUPABASE_URL%/}/rest/v1/rpc/sr_me" -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}' || true)
if grep -q "SESSION_REQUIRED" <<<"$RES"; then echo "✓ tokens accepted"
else
  echo "✗ Supabase did not accept a token signed with APP_JWT_SECRET: $RES" >&2
  echo "  Use the project's legacy JWT secret: Dashboard → Project Settings → JWT Keys → Legacy JWT secret." >&2
  exit 1
fi

step "web/config.js"
scripts/write-config.sh

if [[ $WEB == 1 ]]; then
  need CLOUDFLARE_API_TOKEN; need CLOUDFLARE_ACCOUNT_ID; need CLOUDFLARE_PAGES_PROJECT
  step "Publishing web/ to Cloudflare Pages ($CLOUDFLARE_PAGES_PROJECT)"
  npx --yes wrangler@3 pages deploy web --project-name "$CLOUDFLARE_PAGES_PROJECT" --branch "${CLOUDFLARE_BRANCH:-main}"
fi

cat <<EOF

✓ Deployed to $SUPABASE_URL
  Next (first deploy only):
   • Super Admin:  node scripts/create-superadmin.mjs --email you@example.com --password '…'   (needs SUPABASE_SERVICE_ROLE_KEY)
   • Import data:  node scripts/import-legacy.mjs --store export/app.json --slug <shop> --name "<name>"
   • Set ALLOWED_ORIGINS in .env to your site address (e.g. https://app.smartretail.ge) and run this again.
EOF
