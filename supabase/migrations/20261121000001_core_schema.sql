-- Smart Retail · core schema
-- All business tables live in the private schema "app", which is NOT exposed through the REST API.
-- The browser reaches data only through the security-definer functions in "public" (see later migrations),
-- which check the caller's session, role and store on every call.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;

create schema if not exists app;
revoke all on schema app from public;
grant usage on schema app to service_role;

-- ---------------------------------------------------------------- platform
create table app.plans (
  id text primary key,
  doc jsonb not null default '{}',
  updated_at timestamptz not null default now()
);

create table app.stores (
  id uuid primary key default gen_random_uuid(),
  slug extensions.citext not null unique check (slug ~ '^[a-z0-9][a-z0-9_-]{1,39}$'),
  name text not null,
  status text not null default 'active' check (status in ('trial','active','restricted','suspended')),
  doc jsonb not null default '{}',            -- the Super Admin record (legal name, owner, plan, fee history, ...)
  id_counter bigint not null default 1000,    -- source of the integer ids the app uses (receipt numbers etc.)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app.branches (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references app.stores on delete restrict,
  name text not null,
  sort int not null default 0,
  active boolean not null default true,
  unique (store_id, name)
);

create table app.platform_admins (
  user_id uuid primary key references auth.users on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

-- Super Admin collections other than stores and plans (payments, audit, announcements, settings)
create table app.platform_records (
  coll text not null check (coll in ('payments','audit','ann','settings')),
  id text not null,
  doc jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (coll, id)
);

-- ---------------------------------------------------------------- staff accounts and sessions
create table app.app_users (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references app.stores on delete restrict,
  lid bigint not null,                        -- the integer id the app uses (D.us[].id)
  username extensions.citext not null check (username ~ '^[A-Za-z0-9._-]{3,20}$'),
  password_hash text not null,                -- bcrypt; never returned by any function
  name text not null default '',
  phone text not null default '',
  role text not null check (role in ('admin','cashier','wh')),
  branch text not null default '',
  active boolean not null default true,
  perms jsonb not null default '{}',
  must_change_password boolean not null default false,
  failed_count int not null default 0,
  locked_until timestamptz,
  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  removed_at timestamptz,
  unique (store_id, username),
  unique (store_id, lid)
);

create table app.sessions (
  jti uuid primary key default gen_random_uuid(),
  user_id uuid not null references app.app_users on delete cascade,
  store_id uuid not null references app.stores on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  ip text,
  user_agent text
);
create index on app.sessions (user_id);

create table app.login_attempts (
  id bigserial primary key,
  slug text not null,
  username text not null,
  ip text,
  ok boolean not null,
  at timestamptz not null default now()
);
create index on app.login_attempts (lower(slug), lower(username), at desc);
create index on app.login_attempts (ip, at desc);

-- ---------------------------------------------------------------- store collections
-- Each collection of the app keeps the complete record in "doc" (so nothing the screens use is lost)
-- plus typed columns generated from it, which are indexed and used for reporting and validation.
-- id = the record's stable key (_k on the client). removed_at = soft delete.

create function app.ms_to_ts(v text) returns timestamptz language sql immutable as
$$ select case when v ~ '^-?[0-9]+(\.[0-9]+)?$' then to_timestamp(v::double precision / 1000) end $$;
create function app.to_num(v text) returns numeric language sql immutable as
$$ select case when v ~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$' then v::numeric end $$;
create function app.to_big(v text) returns bigint language sql immutable as
$$ select case when v ~ '^-?[0-9]{1,18}$' then v::bigint end $$;

create table app.products (
  id uuid primary key, store_id uuid not null references app.stores,
  coll text not null default 'p' check (coll in ('p','dp')),      -- p = active, dp = deleted (archive)
  doc jsonb not null,
  lid bigint generated always as (app.to_big(doc->>'id')) stored,
  code text generated always as (doc->>'code') stored,
  name text generated always as (doc->>'name') stored,
  category text generated always as (doc->>'cat') stored,
  price numeric generated always as (app.to_num(doc->>'price')) stored,
  cost numeric generated always as (app.to_num(doc->>'cost')) stored,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  updated_by uuid, removed_at timestamptz
);
create index on app.products (store_id, updated_at);
create index on app.products (store_id, code);
create index on app.products (store_id, lid);

create table app.customers (
  id uuid primary key, store_id uuid not null references app.stores, doc jsonb not null,
  lid bigint generated always as (app.to_big(doc->>'id')) stored,
  phone text generated always as (doc->>'phone') stored,
  name text generated always as (btrim(coalesce(doc->>'name', '') || ' ' || coalesce(doc->>'last', ''))) stored,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  updated_by uuid, removed_at timestamptz
);
create index on app.customers (store_id, updated_at);
create index on app.customers (store_id, phone);

create table app.suppliers (
  id uuid primary key, store_id uuid not null references app.stores, doc jsonb not null,
  name text generated always as (doc->>'name') stored,
  vat_payer boolean generated always as (coalesce((doc->>'vat') in ('1','true'), false)) stored,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  updated_by uuid, removed_at timestamptz
);
create index on app.suppliers (store_id, updated_at);

create table app.sales (
  id uuid primary key, store_id uuid not null references app.stores, doc jsonb not null,
  lid bigint generated always as (app.to_big(doc->>'id')) stored,        -- receipt number shown on screen
  branch text generated always as (doc->>'b') stored,
  username text generated always as (doc->>'u') stored,
  sold_at timestamptz generated always as (app.ms_to_ts(doc->>'t')) stored,
  total numeric generated always as (app.to_num(doc->>'tot')) stored,
  method text generated always as (doc->>'m') stored,
  return_of bigint generated always as (app.to_big(doc->>'ret')) stored,
  customer_lid bigint generated always as (app.to_big(doc->>'c')) stored,
  shift_id text generated always as (doc->>'sh') stored,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  updated_by uuid, removed_at timestamptz
);
create index on app.sales (store_id, updated_at);
create index on app.sales (store_id, sold_at desc);
create index on app.sales (store_id, branch, sold_at desc);
create unique index on app.sales (store_id, lid);

-- Typed copy of every receipt line, filled by trigger, for SQL reporting (phase 2 statistics).
create table app.sale_lines (
  id bigserial primary key,
  store_id uuid not null, sale_id uuid not null references app.sales on delete cascade,
  line_no int not null, branch text, sold_at timestamptz,
  product_lid bigint, variant text, qty numeric, price numeric, line_total numeric,
  cost_at_sale numeric, vat_rate numeric, vat_amount numeric, net numeric, suggested boolean
);
create index on app.sale_lines (store_id, sold_at);
create index on app.sale_lines (store_id, product_lid);

create table app.purchases (
  id uuid primary key, store_id uuid not null references app.stores, doc jsonb not null,
  branch text generated always as (doc->>'b') stored,
  supplier text generated always as (doc->>'sp') stored,
  product_lid bigint generated always as (app.to_big(doc->>'pid')) stored,
  qty numeric generated always as (app.to_num(doc->>'q')) stored,
  unit_cost numeric generated always as (app.to_num(doc->>'c')) stored,
  bought_at timestamptz generated always as (app.ms_to_ts(doc->>'t')) stored,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  updated_by uuid, removed_at timestamptz
);
create index on app.purchases (store_id, updated_at);

create table app.shifts (
  id uuid primary key, store_id uuid not null references app.stores, doc jsonb not null,
  branch text generated always as (doc->>'b') stored,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  updated_by uuid, removed_at timestamptz
);
create index on app.shifts (store_id, updated_at);

create table app.cash_movements (
  id uuid primary key, store_id uuid not null references app.stores, doc jsonb not null,
  shift_id text generated always as (doc->>'sh') stored,
  amount numeric generated always as (app.to_num(doc->>'a')) stored,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  updated_by uuid, removed_at timestamptz
);
create index on app.cash_movements (store_id, updated_at);

create table app.transfers (
  id uuid primary key, store_id uuid not null references app.stores, doc jsonb not null,
  number bigint generated always as (app.to_big(doc->>'id')) stored,
  from_branch text generated always as (doc->>'f') stored,
  to_branch text generated always as (doc->>'to') stored,
  status text generated always as (doc->>'st') stored,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  updated_by uuid, removed_at timestamptz
);
create index on app.transfers (store_id, updated_at);

-- Smaller collections share one shape: typed columns are not needed for them yet.
do $$
declare t text;
begin
  foreach t in array array['inventory_history','expenses','audit_log','held_carts','points_adjustments',
                           'goal_notes','suggestion_log'] loop
    execute format($f$
      create table app.%I (
        id uuid primary key, store_id uuid not null references app.stores, doc jsonb not null,
        created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
        updated_by uuid, removed_at timestamptz)$f$, t);
    execute format('create index on app.%I (store_id, updated_at)', t);
  end loop;
end $$;

-- Settings and small objects (VAT, commissions, goals, loyalty, inventory sessions, favourites, ...)
create table app.kv (
  store_id uuid not null references app.stores,
  key text not null,
  value jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (store_id, key)
);

-- ---------------------------------------------------------------- stock as a ledger
-- skey = 'branch|productId|variant', exactly as the app keys D.st.
create table app.stock_levels (
  store_id uuid not null references app.stores,
  skey text not null,
  branch text generated always as (split_part(skey, '|', 1)) stored,
  product_lid bigint generated always as (app.to_big(split_part(skey, '|', 2))) stored,
  variant text generated always as (substr(skey, length(split_part(skey,'|',1)) + length(split_part(skey,'|',2)) + 3)) stored,
  qty numeric not null default 0,
  updated_at timestamptz not null default now(),
  primary key (store_id, skey)
);
create index on app.stock_levels (store_id, updated_at);

create table app.stock_movements (
  id bigserial primary key,
  store_id uuid not null references app.stores,
  skey text not null,
  delta numeric not null,
  qty_after numeric not null,
  user_id uuid,
  at timestamptz not null default now()
);
create index on app.stock_movements (store_id, skey, at);

-- ---------------------------------------------------------------- registry of collections
-- Drives the generic pull/push functions: which table, who may read, who may write.
create table app.colls (
  coll text primary key,
  tbl text not null,
  read_roles text[] not null,
  write_roles text[] not null,
  append_only boolean not null default false,   -- existing rows may not be changed or removed
  sort int not null default 100
);
insert into app.colls (coll, tbl, read_roles, write_roles, append_only, sort) values
  ('us',   'app_users',          '{admin,cashier,wh}', '{admin}',              false, 10),
  ('p',    'products',           '{admin,cashier,wh}', '{admin,wh}',           false, 20),
  ('dp',   'products',           '{admin,wh}',         '{admin,wh}',           false, 21),
  ('c',    'customers',          '{admin,cashier,wh}', '{admin,cashier}',      false, 30),
  ('sup',  'suppliers',          '{admin,wh}',         '{admin,wh}',           false, 40),
  ('pu',   'purchases',          '{admin,wh}',         '{admin,wh}',           false, 50),
  ('s',    'sales',              '{admin,cashier,wh}', '{admin,cashier}',      true,  60),
  ('sh',   'shifts',             '{admin,cashier}',    '{admin,cashier}',      false, 70),
  ('cm',   'cash_movements',     '{admin,cashier}',    '{admin,cashier}',      true,  71),
  ('tr',   'transfers',          '{admin,cashier,wh}', '{admin,cashier,wh}',   false, 80),
  ('ih',   'inventory_history',  '{admin,wh}',         '{admin,wh}',           false, 90),
  ('ex',   'expenses',           '{admin}',            '{admin}',              false, 100),
  ('lg',   'audit_log',          '{admin}',            '{admin,cashier,wh}',   true,  110),
  ('hold', 'held_carts',         '{admin,cashier}',    '{admin,cashier}',      false, 120),
  ('padj', 'points_adjustments', '{admin,cashier,wh}', '{admin}',              false, 130),
  ('gln',  'goal_notes',         '{admin}',            '{admin,cashier,wh}',   false, 140),
  ('sgl',  'suggestion_log',     '{admin}',            '{admin,cashier}',      true,  150);

-- kv keys that non-admins may write (everything else is admin-only)
create table app.kv_write (
  key text primary key,
  roles text[] not null
);
insert into app.kv_write values
  -- per-user conveniences and counters every role updates while working
  ('fav',  '{cashier,wh,admin}'), ('favu', '{cashier,wh,admin}'),
  ('glc',  '{cashier,wh,admin}'), ('trn',  '{cashier,wh,admin}'), ('lgn', '{cashier,wh,admin}'),
  -- "frequently bought together" cache, recomputed at the till every 50 receipts
  ('sgp',  '{cashier,wh,admin}'), ('sgd',  '{cashier,wh,admin}'),
  -- warehouse work: inventory sessions, categories, monthly summary "seen" flags
  ('is',   '{wh,admin}'), ('ic', '{wh,admin}'), ('cats', '{wh,admin}'),
  ('wrs',  '{wh,admin}'), ('wrx', '{wh,admin}'), ('wrd', '{wh,admin}');
-- kv keys never sent to non-admins
create table app.kv_admin_read (key text primary key);
insert into app.kv_admin_read values ('ex'), ('exn'), ('ak');

-- updated_at maintenance
create function app.touch() returns trigger language plpgsql as
$$ begin new.updated_at := now(); return new; end $$;
do $$
declare t text;
begin
  foreach t in array array['stores','app_users','products','customers','suppliers','sales','purchases','shifts',
    'cash_movements','transfers','inventory_history','expenses','audit_log','held_carts','points_adjustments',
    'goal_notes','suggestion_log','kv','stock_levels','plans','platform_records'] loop
    execute format('create trigger touch before update on app.%I for each row execute function app.touch()', t);
  end loop;
end $$;

-- Defence in depth: RLS on, no policies for anon/authenticated. Only security-definer functions
-- (owned by postgres) and the service role reach these tables.
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'app' loop
    execute format('alter table app.%I enable row level security', r.tablename);
    execute format('grant all on app.%I to service_role', r.tablename);
  end loop;
end $$;
grant usage, select on all sequences in schema app to service_role;
