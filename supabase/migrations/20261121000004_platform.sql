-- Smart Retail · Super Admin (platform owner)
-- Super Admins are real Supabase Auth users listed in app.platform_admins and must have passed
-- an authenticator-app (TOTP) check in this session (aal2).

create function app.require_platform_admin() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  -- service role (scripts) and direct database sessions (seed.sql, psql) are trusted
  if coalesce(auth.jwt()->>'role', '') = 'service_role' or (nullif(current_setting('request.jwt.claims', true), '') is null
         and session_user in ('postgres', 'supabase_admin')) then
    return null;
  end if;
  if uid is null or not exists (select 1 from app.platform_admins where user_id = uid) then
    raise exception 'PLATFORM_ADMIN_REQUIRED' using errcode = '28000';
  end if;
  if coalesce(auth.jwt()->>'aal', '') <> 'aal2' then
    raise exception 'MFA_REQUIRED' using errcode = '28000';
  end if;
  return uid;
end $$;

create function public.sr_platform_whoami() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('uid', auth.uid(), 'aal', auth.jwt()->>'aal',
    'is_admin', exists (select 1 from app.platform_admins where user_id = auth.uid()))
$$;

-- default permissions per role, same as PDEF in the app
create function app.default_perms(r text) returns jsonb language sql immutable as $$
  select case r
    when 'cashier' then '{"cmv":1,"neg":1,"disc":1,"reg":1,"hold":1,"tx":1,"rx":1,"rcv":1,"stk":1}'::jsonb
    when 'wh' then '{"stk":1,"prod":1,"padd":1,"pdel":0,"buy":1,"sup":1,"inv":1,"invOk":1,"wr":0}'::jsonb
    else '{}'::jsonb end
$$;

-- store record for the Super Admin screen: stored doc + live branches and staff (never passwords)
create function app.store_doc(s app.stores) returns jsonb language sql stable set search_path = '' as $$
  select s.doc || jsonb_build_object(
    'id', s.id::text, 'login', s.slug::text, 'name', s.name, 'status', s.status,
    'branches', coalesce((select jsonb_agg(b.name order by b.sort, b.name) from app.branches b where b.store_id = s.id and b.active), '[]'),
    'users', coalesce((select jsonb_agg(jsonb_build_object('u', u.username::text, 'name', u.name,
                 'role', case u.role when 'admin' then 'ადმინი' when 'cashier' then 'მოლარე' else 'საწყობი' end,
                 'branch', case when u.branch = '' then 'ყველა' else u.branch end,
                 'last', coalesce(to_char(u.last_login_at at time zone 'Asia/Tbilisi', 'YYYY-MM-DD'), ''),
                 'active', u.active) order by u.lid)
               from app.app_users u where u.store_id = s.id and u.removed_at is null), '[]'),
    'lastActive', coalesce((select to_char(max(u.last_login_at) at time zone 'Asia/Tbilisi', 'YYYY-MM-DD')
                              from app.app_users u where u.store_id = s.id), s.doc->>'lastActive', ''),
    'syncPending', 0)
$$;

create function public.sr_platform_pull() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  return jsonb_build_object(
    'v', 1,
    'plans', coalesce((select jsonb_agg(doc || jsonb_build_object('id', id) order by (doc->>'price')::numeric nulls last) from app.plans), '[]'),
    'stores', coalesce((select jsonb_agg(app.store_doc(s) order by s.created_at) from app.stores s), '[]'),
    'payments', coalesce((select jsonb_agg(doc order by doc->>'date') from app.platform_records where coll = 'payments'), '[]'),
    'audit', coalesce((select jsonb_agg(doc order by doc->>'t') from app.platform_records where coll = 'audit'), '[]'),
    'ann', coalesce((select jsonb_agg(doc order by doc->>'t') from app.platform_records where coll = 'ann'), '[]'),
    'settings', coalesce((select doc from app.platform_records where coll = 'settings' and id = 'main'),
                         '{"grace":7,"restrictAfter":30,"remindBefore":3,"email":"","vatNote":"ფასები დღგ-ს ჩათვლით"}'));
end $$;

-- p: {"stores":[doc], "plans":[doc], "payments":[doc], "audit":[doc], "ann":[doc], "settings": doc,
--     "rm": {"payments":[id], "ann":[id]}}
create function public.sr_platform_push(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare d jsonb; c text; k text; st text;
begin
  perform app.require_platform_admin();
  for d in select jsonb_array_elements(coalesce(p->'stores', '[]')) loop
    st := coalesce(d->>'status', 'active');
    if st not in ('trial','active','restricted','suspended') then raise exception 'BAD_STATUS %', st; end if;
    -- login (slug), branches and users are not edited from here
    update app.stores set name = coalesce(d->>'name', name), status = st,
           doc = d - 'id' - 'login' - 'branches' - 'users' - 'lastActive' - 'syncPending' - 'name' - 'status'
     where id = (d->>'id')::uuid;
    if st = 'suspended' then
      update app.sessions set revoked_at = now() where store_id = (d->>'id')::uuid and revoked_at is null;
    end if;
  end loop;
  for d in select jsonb_array_elements(coalesce(p->'plans', '[]')) loop
    insert into app.plans (id, doc) values (d->>'id', d - 'id')
    on conflict (id) do update set doc = excluded.doc;
  end loop;
  foreach c in array array['payments','audit','ann'] loop
    for d in select jsonb_array_elements(coalesce(p->c, '[]')) loop
      if c = 'audit' and exists (select 1 from app.platform_records where coll = 'audit' and id = d->>'id') then continue; end if;
      insert into app.platform_records (coll, id, doc) values (c, d->>'id', d)
      on conflict (coll, id) do update set doc = excluded.doc;
    end loop;
  end loop;
  if p ? 'settings' then
    insert into app.platform_records (coll, id, doc) values ('settings', 'main', p->'settings')
    on conflict (coll, id) do update set doc = excluded.doc;
  end if;
  foreach c in array array['payments','ann'] loop
    for k in select jsonb_array_elements_text(coalesce(p->'rm'->c, '[]')) loop
      delete from app.platform_records where coll = c and id = k;
    end loop;
  end loop;
  return jsonb_build_object('ok', true);
end $$;

-- Registers a store with its branches, one admin and one cashier per branch.
-- Returns the temporary passwords once; only bcrypt hashes are stored.
create function public.sr_platform_register_store(d jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  s app.stores; b text; i int := 0; creds jsonb := '[]'; pw text;
  au text := lower(coalesce(nullif(btrim(d->>'adminUser'), ''), 'admin'));
  br text[] := coalesce((select array_agg(btrim(x)) from jsonb_array_elements_text(d->'branches') x where btrim(x) <> ''),
                        array['მთავარი']);
begin
  perform app.require_platform_admin();
  if exists (select 1 from app.stores where slug = lower(d->>'login')::extensions.citext) then
    raise exception 'SLUG_TAKEN';
  end if;
  insert into app.stores (slug, name, status, doc)
  values (lower(d->>'login'), d->>'name', coalesce(d->>'status', 'active'),
          d - 'id' - 'login' - 'name' - 'status' - 'branches' - 'users' - 'adminUser' - 'adminPassword')
  returning * into s;
  foreach b in array br loop
    i := i + 1;
    insert into app.branches (store_id, name, sort) values (s.id, b, i);
  end loop;

  pw := coalesce(nullif(d->>'adminPassword', ''), app.gen_password());
  insert into app.app_users (store_id, lid, username, password_hash, name, role, branch, perms, must_change_password)
  values (s.id, 1, au, app.hash_pw(pw), coalesce(d->>'owner', 'ადმინისტრატორი'), 'admin', '', '{}', true);
  creds := creds || jsonb_build_object('u', au, 'pw', pw, 'role', 'admin', 'branch', '');
  i := 0;
  foreach b in array br loop
    i := i + 1; pw := app.gen_password();
    insert into app.app_users (store_id, lid, username, password_hash, name, role, branch, perms, must_change_password)
    values (s.id, 1 + i, 'kasa' || i, app.hash_pw(pw), 'მოლარე ' || i, 'cashier', b, app.default_perms('cashier'), true);
    creds := creds || jsonb_build_object('u', 'kasa' || i, 'pw', pw, 'role', 'cashier', 'branch', b);
  end loop;
  update app.stores set id_counter = 100 where id = s.id;
  select * into s from app.stores where id = s.id;
  return jsonb_build_object('store', app.store_doc(s), 'credentials', creds);
end $$;

create function public.sr_platform_reset_password(p_store uuid, p_username text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare pw text := app.gen_password(); n int;
begin
  perform app.require_platform_admin();
  update app.app_users set password_hash = app.hash_pw(pw), must_change_password = true, failed_count = 0, locked_until = null
   where store_id = p_store and username = p_username::extensions.citext and removed_at is null;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'USER_NOT_FOUND'; end if;
  update app.sessions s set revoked_at = now() from app.app_users u
   where u.id = s.user_id and u.store_id = p_store and u.username = p_username::extensions.citext and s.revoked_at is null;
  return jsonb_build_object('u', p_username, 'pw', pw);
end $$;

-- Real numbers for the read-only store dashboard in Super Admin (replaces the random demo metrics)
create function public.sr_platform_metrics() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  return coalesce((
    select jsonb_object_agg(s.id::text, jsonb_build_object(
      'days', (select jsonb_agg(jsonb_build_object('d', to_char(g.d, 'YYYY-MM-DD'), 'v',
                 coalesce((select round(sum(sa.total)) from app.sales sa where sa.store_id = s.id
                            and (sa.sold_at at time zone 'Asia/Tbilisi')::date = g.d), 0)) order by g.d)
               from generate_series((now() at time zone 'Asia/Tbilisi')::date - 29, (now() at time zone 'Asia/Tbilisi')::date, '1 day') g(d)),
      'checks', (select count(*) from app.sales sa where sa.store_id = s.id and sa.sold_at > now() - interval '30 days' and sa.return_of is null),
      'profit', (select coalesce(round(sum(l.line_total - coalesce(l.cost_at_sale, 0) * l.qty)), 0) from app.sale_lines l
                  where l.store_id = s.id and l.sold_at > now() - interval '30 days'),
      'customers', (select count(*) from app.customers c where c.store_id = s.id and c.removed_at is null),
      'products', (select count(*) from app.products p where p.store_id = s.id and p.coll = 'p' and p.removed_at is null),
      'stockValue', (select coalesce(round(sum(greatest(sl.qty, 0) * coalesce(p.cost, 0))), 0) from app.stock_levels sl
                      join app.products p on p.store_id = sl.store_id and p.lid = sl.product_lid and p.coll = 'p' and p.removed_at is null
                     where sl.store_id = s.id),
      'byBranch', (select coalesce(jsonb_object_agg(x.branch, x.v), '{}') from (select sa.branch, round(sum(sa.total)) v
                    from app.sales sa where sa.store_id = s.id and sa.sold_at > now() - interval '30 days' group by sa.branch) x),
      'top', (select coalesce(jsonb_agg(jsonb_build_object('n', t.name, 'q', t.q)), '[]') from (
                select p.name, sum(l.qty) q from app.sale_lines l
                  join app.products p on p.store_id = l.store_id and p.lid = l.product_lid
                 where l.store_id = s.id and l.sold_at > now() - interval '30 days' and l.qty > 0
                 group by p.name order by 2 desc limit 5) t)
    )) from app.stores s), '{}');
end $$;

-- Grants Super Admin rights to an existing Supabase Auth user (scripts/create-superadmin.mjs, service role only)
create function public.sr_platform_add_admin(p_user uuid, p_email text) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role'
     and not (nullif(current_setting('request.jwt.claims', true), '') is null and session_user in ('postgres', 'supabase_admin')) then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;
  insert into app.platform_admins (user_id, email) values (p_user, p_email)
  on conflict (user_id) do update set email = excluded.email;
end $$;

-- ---------------------------------------------------------------- one-time import of prototype data
-- p_data = the JSON the prototype kept in localStorage['rms1'].
-- Callable by the service role (scripts/import-legacy.mjs, seed) or a Super Admin.
create function public.sr_platform_import_store(p_slug text, p_name text, p_data jsonb,
                                                p_branches text[] default null,
                                                p_force_password_change boolean default true)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  s app.stores; c text; tbl text; d jsonb; k uuid; n int; counts jsonb := '{}';
  br text[]; b text; i int := 0; sk text; v jsonb; maxid bigint;
begin
  perform app.require_platform_admin();
  if exists (select 1 from app.stores where slug = lower(p_slug)::extensions.citext) then raise exception 'SLUG_TAKEN'; end if;
  insert into app.stores (slug, name) values (lower(p_slug), coalesce(p_name, p_slug)) returning * into s;

  br := coalesce(p_branches, (select array_agg(distinct x) from (
          select split_part(key, '|', 1) x from jsonb_each(coalesce(p_data->'st', '{}'))
          union select e->>'b' from jsonb_array_elements(coalesce(p_data->'s', '[]')) e
          union select e->>'branch' from jsonb_array_elements(coalesce(p_data->'us', '[]')) e) q where coalesce(x, '') <> ''));
  foreach b in array coalesce(br, array['მთავარი']) loop
    i := i + 1; insert into app.branches (store_id, name, sort) values (s.id, b, i);
  end loop;

  for d in select jsonb_array_elements(coalesce(p_data->'us', '[]')) loop
    insert into app.app_users (id, store_id, lid, username, password_hash, name, phone, role, branch, active, perms,
                               must_change_password, created_at, last_login_at)
    values (coalesce((d->>'_k')::uuid, gen_random_uuid()), s.id, (d->>'id')::bigint, d->>'u', app.hash_pw(coalesce(d->>'pw', app.gen_password())),
            coalesce(d->>'name', ''), coalesce(d->>'phone', ''), coalesce(d->>'role', 'cashier'), coalesce(d->>'branch', ''),
            coalesce((d->>'active') in ('1','true'), true), coalesce(d->'perms', '{}'), p_force_password_change,
            coalesce(app.ms_to_ts(d->>'created'), now()), case when app.to_num(d->>'last') > 0 then app.ms_to_ts(d->>'last') end);
  end loop;
  counts := counts || jsonb_build_object('us', jsonb_array_length(coalesce(p_data->'us', '[]')));

  for c, tbl in select coll, t.tbl from app.colls t where coll <> 'us' order by sort loop
    n := 0;
    for d in select jsonb_array_elements(case when jsonb_typeof(p_data->c) = 'array' then p_data->c else '[]' end) loop
      k := coalesce((d->>'_k')::uuid, gen_random_uuid());
      if tbl = 'products' then
        insert into app.products (id, store_id, coll, doc) values (k, s.id, c, d - '_k');
      else
        execute format('insert into app.%I (id, store_id, doc) values ($1, $2, $3)', tbl) using k, s.id, d - '_k';
      end if;
      n := n + 1;
    end loop;
    counts := counts || jsonb_build_object(c, n);
  end loop;

  for sk, v in select * from jsonb_each(coalesce(p_data->'st', '{}')) loop
    if app.to_num(v #>> '{}') is null then continue; end if;
    insert into app.stock_levels (store_id, skey, qty) values (s.id, sk, app.to_num(v #>> '{}'));
    insert into app.stock_movements (store_id, skey, delta, qty_after) values (s.id, sk, app.to_num(v #>> '{}'), app.to_num(v #>> '{}'));
  end loop;

  -- everything else is a setting or a small object
  for sk, v in select key, value from jsonb_each(p_data)
                where key not in (select coll from app.colls) and key not in ('st', 'n', 'csl', 'csd', 'ak') loop
    insert into app.kv (store_id, key, value) values (s.id, sk, v);
  end loop;

  select greatest(coalesce(app.to_big(p_data->>'n'), 0),
                  coalesce((select max(lid) from app.sales where store_id = s.id), 0),
                  coalesce((select max(lid) from app.app_users where store_id = s.id), 0),
                  coalesce((select max(lid) from app.products where store_id = s.id), 0),
                  coalesce((select max(lid) from app.customers where store_id = s.id), 0)) + 1 into maxid;
  update app.stores set id_counter = maxid where id = s.id;
  return jsonb_build_object('store_id', s.id, 'counts', counts, 'id_counter', maxid, 'branches', to_jsonb(br));
end $$;

revoke execute on function public.sr_platform_whoami(), public.sr_platform_pull(), public.sr_platform_push(jsonb),
  public.sr_platform_register_store(jsonb), public.sr_platform_reset_password(uuid, text), public.sr_platform_metrics(),
  public.sr_platform_import_store(text, text, jsonb, text[], boolean) from public, anon;
grant execute on function public.sr_platform_whoami(), public.sr_platform_pull(), public.sr_platform_push(jsonb),
  public.sr_platform_register_store(jsonb), public.sr_platform_reset_password(uuid, text), public.sr_platform_metrics(),
  public.sr_platform_import_store(text, text, jsonb, text[], boolean) to authenticated, service_role;

-- default plans (same as the prototype)
insert into app.plans (id, doc) values
  ('basic', '{"name":"Basic","price":49,"branches":1,"users":3,"desc":"1 ფილიალი, სალარო + დეშბორდი"}'),
  ('std',   '{"name":"Standard","price":89,"branches":3,"users":10,"desc":"3-მდე ფილიალი, ინვენტარიზაცია, ლოიალობა"}'),
  ('pro',   '{"name":"Pro","price":149,"branches":10,"users":40,"desc":"10-მდე ფილიალი, ყველა ფუნქცია, პრიორიტეტული მხარდაჭერა"}')
on conflict do nothing;
