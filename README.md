# Smart Retail

Retail management system: cashier (POS) and dashboard, plus a Super Admin panel for the platform owner.
This repository moves the prototype from the browser's localStorage to **Supabase** (Postgres, Storage,
Edge Functions, Auth for the Super Admin).

```
web/                     the app (static files, deploy anywhere, e.g. Cloudflare Pages)
  index.html             main app: login → cashier or dashboard
  superadmin/index.html  platform owner panel
  js/sr.js               data layer of the main app (Supabase instead of localStorage)
  js/sr-platform.js      data layer + sign-in (with authenticator app) of the Super Admin
  config.js              generated: Supabase URL + public key (scripts/write-config.sh)
supabase/
  migrations/            database schema, security rules, API functions (applied in order)
  functions/store-login  Edge Function: shop + username + password → login token
  seed.sql               local demo shop only (never deployed)
  tests/                 SQL tests
scripts/                 dev, deploy, import, tests (see below)
prototype/               the claude.ai prototypes the web pages are built from
```

## Run it on your computer (localhost)

Needs **Docker Desktop** (running), **Node.js 18+** and **Python 3**.

```bash
scripts/dev.sh          # or: npm run dev
```

The first run downloads the Supabase containers (a few minutes). Then open:

| | |
|---|---|
| App | http://localhost:5173 |
| Super Admin | http://localhost:5173/superadmin/ |
| Database UI (Studio) | http://127.0.0.1:54323 |

Demo logins: shop **demo**, users **admin**, **kasa1**, **kasa2**, **sawyobi**, password **1234**.
Super Admin: **admin@smartretail.local** / **superadmin-local-1**, then scan the QR code with an
authenticator app (Google Authenticator, Microsoft Authenticator, 1Password, …).

`scripts/dev.sh --reset` rebuilds the database from the migrations and the demo shop;
`scripts/dev.sh --stop` stops the containers.

## Deploy (one command)

1. `cp .env.example .env` and fill it in (Supabase project ref, URL, keys, database password,
   access token, and `APP_JWT_SECRET` = the project's **Legacy JWT secret** from
   *Project Settings → JWT Keys*).
2. Run:

```bash
scripts/deploy.sh       # or: npm run deploy
```

It links the project, shows the pending migrations and asks before applying them, sets the Edge
Function secrets, deploys `store-login`, **checks that the project accepts the login tokens**, and
writes `web/config.js`. Options: `--dry-run`, `--yes` (no question, for CI), `--web` (also publishes
`web/` to Cloudflare Pages with `CLOUDFLARE_*` from `.env`). Seed data is never deployed.

First deploy only:

```bash
node scripts/create-superadmin.mjs --email you@example.com --password '<12+ characters>'
node scripts/import-legacy.mjs --store export/app.json --slug batumipets --name "ბათუმი ფეთს"
node scripts/import-legacy.mjs --superadmin export/superadmin.json
```

How to export the prototype data is described at the top of `scripts/import-legacy.mjs`
(`seed/demo-store.json` is the prototype's own demo data if you have no export).

**Cloudflare Pages** (instead of `--web`): connect this repo, build command `scripts/write-config.sh`,
output directory `web`, environment variables `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Every branch
gets a preview link; set `ALLOWED_ORIGINS` in `.env` to the live and preview addresses.

## Tests

```bash
DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres scripts/test-db.sh   # migrations + SQL tests
E2E_ADMIN_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres scripts/e2e/run.sh  # app end-to-end
```

Both work against the local Supabase database or any empty PostgreSQL 15+ (a stub provides the
Supabase roles). `scripts/e2e/run.sh` runs the real app code against the database through a small
stand-in for the API gateway, then (if Chrome is installed) drives the real UI in headless Chrome:
login errors, a cashier sale, every dashboard screen. GitHub Actions runs both on every pull request.

## How it works

### Login (interim custom auth, kept as before: shop + username + password)

```
browser ──shop, user, password──▶ Edge Function store-login ──▶ public.sr_login (database)
                                                                 bcrypt check, 5 failures → 15 min lock,
                                                                 30 failures per IP, session row
browser ◀──── JWT (8 h): role=authenticated, sub, store_id, app_role, jti ─────┘
browser ──JWT──▶ /rest/v1/rpc/sr_* ──▶ app.ctx(): session not revoked/expired, user active,
                                       store not suspended → store, role, branch for this call
```

* Passwords are bcrypt hashes in `app.app_users`; no function ever returns them.
* Same error for unknown shop, unknown user and wrong password.
* Disabling a user, a password reset or a suspended store ends sessions immediately.
* Temporary passwords (new staff, Super Admin resets) must be changed at first login (8+ characters).
* The signing secret lives only in Edge Function secrets; the browser holds only the public key.

### Data

* All tables are in the private schema **`app`**, which the API does not expose. The browser can only
  call the `public.sr_*` functions; each starts from the verified session, so the store, role and
  branch never come from the request. Internal helpers are not executable by API roles.
* Each collection of the app is a table whose `doc` column keeps the full record (nothing the screens
  use is lost) plus **typed, indexed columns generated from it** (receipt number, branch, time, total,
  product code, price, cost, …). Receipt lines are also written to the typed table `app.sale_lines`
  for SQL reporting.
* **Receipts are immutable** (trigger): no edits, no deletes; only the commission can be stamped once on
  an old receipt. Cash movements, the change log and the suggestions log are append-only.
* **Stock is a ledger**: the app sends deltas (`-2`), the database adds them and logs every movement,
  so two tills selling the same item cannot overwrite each other.
* The **cost of goods sold is stamped by the server** on each receipt line; cashiers never receive
  product costs.
* Permissions per role (admin / cashier / warehouse) and per permission (`reg`, `cmv`, `rcv`, …) are
  checked in the database; cashiers can only sell, move stock and open shifts for their own branch.
* Receipt numbers and other integer ids come from blocks reserved per session on the server, so two
  devices never hand out the same number.
* Product photos go to Storage (`product-images/<store>/…`), not into the database.

### In the browser (`web/js/sr.js`)

The screens still work on the in-memory object `D`; `sr.js` replaces localStorage:
core data loads at login, heavier collections (purchases, suppliers, expenses, change log, inventory
history) load when their screen opens, and every screen visit fetches only what changed since.
Every `save()` sends exactly what changed, in one transaction; failures show the existing red
"not saved · retry" banners. If the session expires mid-work, a password prompt appears and the
pending changes are sent after signing in again.

## Known limits of this phase

* **Online only**: without internet nothing is lost while the page stays open, but nothing is sent either
  (the till shows "not saved"). The offline queue is the next step (ids are already reserved on the
  server, and saves are idempotent).
* **Statistics are still computed in the browser** from the receipts loaded at login. The typed columns
  and `sale_lines` are in place for moving them to SQL functions; until then a store with very many
  receipts will load slowly.
* Transfer and expense numbers (`trn`, `exn`) are still counters in the settings and could repeat if two
  devices create one at the same moment.
* Cashiers receive the cost stamped on old receipt lines (needed to keep return profit correct).

## Moving to Supabase Auth later

Give every staff member a hidden internal email built from shop and username
(`kasa1@batumipets.staff.smartretail.ge`), sign in with `signInWithPassword`, and add the same claims
(`store_id`, `app_role`, `app_uid`, `jti`) with a Custom Access Token Hook. The database rules already
read those claims, so they do not change. Details: the migration plan artifact.
