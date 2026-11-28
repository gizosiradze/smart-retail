# Smart Retail

Retail management system: cashier (POS) and dashboard, plus a Super Admin panel for the platform owner.
This repository moves the prototype from the browser's localStorage to **Supabase** (Postgres, Storage,
Edge Functions, Auth for the Super Admin).

```
web/                     the app (static files, deploy anywhere, e.g. Cloudflare Pages)
  index.html             home page (public) with a "Sign in" button
  app/index.html         main app: login → cashier or dashboard (installable on phones: manifest + sw.js)
  superadmin/index.html  platform owner panel
  js/sr.js               data layer of the main app (Supabase instead of localStorage)
  js/sr-platform.js      data layer + sign-in (with authenticator app) of the Super Admin
  config.js              generated: Supabase URL + public key (npm run config / scripts/write-config.mjs)
supabase/
  migrations/            database schema, security rules, API functions (applied in order)
  functions/store-login  Edge Function: shop + username + password → login token
  seed.sql               local demo shop only (never deployed)
  tests/                 SQL tests
scripts/                 dev, deploy, import, Super Admin, tests (Node, no dependencies)
prototype/               the claude.ai prototypes the web pages are built from
```

## Run it on your computer (localhost) — Node only

You need **Node.js 18+**, nothing else (no `npm install`: the scripts have no dependencies; the
Supabase CLI is fetched by `npx` when needed). The app runs on your computer and uses a separate,
free **test project** on Supabase, so production data is never touched.

1. Create a free Supabase project for testing (e.g. `smart-retail-test`, region Europe).
2. Copy `.env.example` to **`.env.test`** and fill it in with the **test** project's values
   (Project Settings → API / Database / JWT Keys) and `ALLOWED_ORIGINS=http://localhost:5173`.
3. Once (and again after pulling new migrations):

   ```bash
   npm run dev:setup
   ```

   It deploys the schema and the login function to the test project, adds the demo shop and creates a
   Super Admin. It refuses to run if `.env.test` points at the same project as `.env`.
4. Every day:

   ```bash
   npm run dev
   ```

| | |
|---|---|
| Home page | http://localhost:5173 |
| App (login) | http://localhost:5173/app/ |
| Super Admin | http://localhost:5173/superadmin/ |
| Database | your test project in the Supabase dashboard |

Demo logins: shop **demo**, users **admin**, **kasa1**, **kasa2**, **sawyobi**, password **1234**.
Super Admin: `npm run dev:setup` creates one only if `SUPERADMIN_EMAIL` and `SUPERADMIN_PASSWORD` (12+ characters)
are set in `.env.test`; there is no built-in default account. Sign in at `/superadmin/` and scan the QR code with an
authenticator app. Never use a shared or published password: whoever signs in first sets up the authenticator.

From Super Admin, **„სრული დეშბორდი ↗"** (store page or the stores list) opens that store's own app in a new
tab as its admin, **read-only**: a 2-hour session marked `read_only` in `app.sessions` (with the Super Admin's
id), handed to the tab by `postMessage`. Every screen and statistic loads; the server refuses saves,
password changes and photo uploads from that session. Allow pop-ups for the site.

## Deploy (one command)

1. Copy `.env.example` to **`.env`** and fill it in with the **production** project's values
   (`APP_JWT_SECRET` = the project's **Legacy JWT secret** from *Project Settings → JWT Keys*).
2. Run:

```bash
npm run deploy
```

It links the project, shows the pending migrations and asks before applying them, sets the Edge
Function secrets, deploys `store-login`, **checks that the project accepts the login tokens**, and
writes `web/config.js`. Options after `--`: `--dry-run`, `--yes` (no question, for CI), `--web` (also
publishes `web/` to Cloudflare Pages with `CLOUDFLARE_*` from `.env`), `--env <file>`.
Seed data is never deployed. No Docker is needed.

First deploy only:

```bash
npm run superadmin -- --email you@example.com --password '<12+ characters>'
npm run import -- --store export/app.json --slug batumipets --name "ბათუმი ფეთს"
npm run import -- --superadmin export/superadmin.json
```

How to export the prototype data is described at the top of `scripts/import-legacy.mjs`
(`seed/demo-store.json` is the prototype's own demo data if you have no export).

**Cloudflare Pages** (instead of `--web`): connect this repo, build command
`node scripts/write-config.mjs`, output directory `web`, environment variables `SUPABASE_URL` and
`SUPABASE_ANON_KEY`. Every branch gets a preview link; add the live and preview addresses to
`ALLOWED_ORIGINS` and run `npm run deploy` again.

**GitHub Pages** (automatic): every push to `main` runs `.github/workflows/pages.yml`, which writes
`web/config.js` and publishes `web/` to `https://<owner>.github.io/<repo>/` (app login at `.../app/`, Super Admin at `.../superadmin/`).
Once: repo *Settings → Pages → Source: GitHub Actions*. The Supabase URL and public key can be overridden
with repository variables `SUPABASE_URL` / `SUPABASE_ANON_KEY`. Only the web pages are deployed; the
database and `store-login` still go through `npm run deploy`. Add the Pages address to `ALLOWED_ORIGINS`
if you restrict it.

## Tests

```bash
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres scripts/test-db.sh   # migrations + SQL tests
E2E_ADMIN_URL=postgresql://postgres:postgres@localhost:5432/postgres scripts/e2e/run.sh  # app end-to-end
```

Both need only `psql` and an empty PostgreSQL 15+ you can create databases in (a stub provides the
Supabase roles); GitHub Actions runs them on every pull request, so you don't have to run them locally. `scripts/e2e/run.sh` runs the real app code against the database through a small
stand-in for the API gateway, then (if Chrome is installed) drives the real UI in headless Chrome:
login errors, a cashier sale, every dashboard screen. GitHub Actions runs both on every pull request.

## How it works

### Login (interim custom auth, kept as before: shop + username + password)

```
browser ──shop, user, password──▶ Edge Function store-login ──▶ public.sr_login (database)
                                                                 bcrypt check, 5 failures → 15 min lock,
                                                                 30 failures per IP, session row
browser ◀──── JWT (12 h): role=authenticated, sub, store_id, app_role, jti ─────┘
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

## Offline till (`web/js/sr.js`, `web/app/sw.js`)

* The service worker keeps the app shell and product photos, so the app opens without internet.
* The browser keeps a working copy in IndexedDB (`sr-offline`): data, the baseline, the batch being sent, the id
  block and the sign-in. It is written after every `save()` (and when the page is hidden), so closing the page
  or the app loses nothing. Opening the app again continues from it; the sign-in is kept for its 12 hours, and
  after that the password is asked only when the connection is back (the unsent changes go out right after).
* Every push carries a batch id; `app.push_batches` remembers it, so a batch whose answer was lost (stock changes
  are deltas) is applied once. Logging out deletes the copy (it asks first if something is unsent).
* A small mark at the bottom left shows "no internet" and how many receipts wait; the red "not saved" banner
  now appears only for real refusals from the server.
* Tests: `scripts/e2e/offline-e2e.mjs` (headless Chrome goes offline, sells, reloads, reconnects) and the
  re-send test in `supabase/tests/10_auth_sync.sql`.

## Known limits of this phase

* **Offline till** (see below): sales and other changes made without internet wait in the browser and are
  sent when the connection returns. Not covered: signing in for the first time (or after logging out)
  needs internet; reports and screens whose data was never loaded on this device stay empty offline;
  ids come from reserved blocks of 1000 (refilled early), so one device can sell about that many receipts
  offline before it must reconnect (a warning appears 30 numbers before).
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

## Backups

The free Supabase plan has no automatic backups, so `.github/workflows/backup.yml` saves the database every night
(05:00 Tbilisi) as an **encrypted** file and keeps it **30 days**: repo → *Actions* → *nightly-backup* → open a run →
*Artifacts*. It saves the shop data (`app`), the API functions (`public`) and the Super Admin accounts (`auth`), not the
product photos in Storage. If a run fails, GitHub emails the repo owner. GitHub pauses scheduled runs after 60 days
without any repository activity, so look at the Actions tab now and then.

Two repository secrets are needed (*Settings → Secrets and variables → Actions*): `BACKUP_DB_URL` (Supabase → Connect →
*Session pooler* string, with the real database password) and `BACKUP_PASSPHRASE` (long random text; keep a copy in a
password manager, **without it a backup cannot be opened**).

**Restore** (to a fresh, empty database, never over live data unless you mean to):

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in smart-retail-YYYY-MM-DD.dump.enc -out backup.dump   # asks for the passphrase
pg_restore --no-owner --no-privileges -d "<connection string of the empty database>" backup.dump
```

Restored shops, receipts and customers were checked against the live database (4 shops, 204 receipts, 9 customers).
