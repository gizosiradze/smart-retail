-- Smart Retail · data API used by the app (web/js/sr.js)
--   sr_pull(colls, cursors)  -> rows changed since each cursor, filtered by role
--   sr_push(changes)         -> one transaction: removals, upserts, stock deltas, settings
-- Both run as security definer and start with app.ctx(), so the store, role and session are
-- always taken from the verified token, never from the request body.

-- ---------------------------------------------------------------- receipts are never edited
create function app.sales_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'RECEIPTS_ARE_IMMUTABLE'; end if;
  -- the only allowed change: stamping the commission ("fee") on an old receipt that has none
  if (old.doc - 'fee') is distinct from (new.doc - 'fee')
     or (old.doc ? 'fee' and old.doc->'fee' is distinct from new.doc->'fee')
     or new.removed_at is distinct from old.removed_at or new.store_id <> old.store_id then
    raise exception 'RECEIPTS_ARE_IMMUTABLE';
  end if;
  return new;
end $$;
create trigger sales_guard before update or delete on app.sales
  for each row execute function app.sales_guard();

create function app.sales_lines_fill() returns trigger language plpgsql as $$
begin
  insert into app.sale_lines (store_id, sale_id, line_no, branch, sold_at, product_lid, variant, qty, price,
                              line_total, cost_at_sale, vat_rate, vat_amount, net, suggested)
  select new.store_id, new.id, l.ord::int, new.branch, new.sold_at,
         app.to_big(l.x->>'pid'), l.x->>'z', app.to_num(l.x->>'q'), app.to_num(l.x->>'pr'),
         coalesce(app.to_num(l.x->>'lt'), round(app.to_num(l.x->>'q') * app.to_num(l.x->>'pr'), 2)),
         app.to_num(l.x->>'cg'), app.to_num(l.x->>'vr'), app.to_num(l.x->>'vt'), app.to_num(l.x->>'nt'),
         coalesce((l.x->>'sg') in ('1','true'), false)
    from jsonb_array_elements(coalesce(new.doc->'it', '[]')) with ordinality as l(x, ord);
  return new;
end $$;
create trigger sales_lines_fill after insert on app.sales
  for each row execute function app.sales_lines_fill();

-- cash movements and the change log are append-only at table level too
create function app.append_only_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' or old.doc is distinct from new.doc or new.removed_at is distinct from old.removed_at then
    raise exception 'APPEND_ONLY: %', tg_table_name;
  end if;
  return new;
end $$;
create trigger append_only before update or delete on app.cash_movements for each row execute function app.append_only_guard();
create trigger append_only before update or delete on app.audit_log for each row execute function app.append_only_guard();
create trigger append_only before update or delete on app.suggestion_log for each row execute function app.append_only_guard();

-- ---------------------------------------------------------------- user record as the app sees it (no hash)
create function app.user_doc(u app.app_users) returns jsonb language sql stable as $$
  select jsonb_build_object('_k', u.id::text, 'id', u.lid, 'u', u.username::text, 'name', u.name, 'phone', u.phone,
    'role', u.role, 'branch', u.branch, 'active', case when u.active then 1 else 0 end, 'perms', u.perms,
    'created', (extract(epoch from u.created_at) * 1000)::bigint,
    'last', coalesce((extract(epoch from u.last_login_at) * 1000)::bigint, 0))
$$;

-- ---------------------------------------------------------------- pull
-- p_cursors: {"s": {"t": "2026-11-21T10:00:00Z", "id": "uuid"}, ...}; a missing cursor = full load
create function public.sr_pull(p_colls text[], p_cursors jsonb default '{}', p_limit int default 2000)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  x app.ctx_t := app.ctx();
  out jsonb := '{}';
  c text; meta app.colls; cur jsonb; t timestamptz; cid uuid;
  rows jsonb; rm jsonb; last_t timestamptz; last_id uuid; n int; strip text[];
begin
  p_limit := least(greatest(coalesce(p_limit, 2000), 50), 5000);
  foreach c in array p_colls loop
    cur := p_cursors->c;
    t := coalesce((cur->>'t')::timestamptz, '-infinity');
    cid := coalesce((cur->>'id')::uuid, '00000000-0000-0000-0000-000000000000');

    if c = 'st' then
      select coalesce(jsonb_object_agg(skey, qty), '{}'), max(updated_at) into rows, last_t
        from app.stock_levels where store_id = x.store_id and updated_at > t
         and (x.role = 'admin' or x.branch = '' or branch = x.branch or x.role = 'cashier');
      out := out || jsonb_build_object('st', jsonb_build_object('rows', rows,
                     'cursor', jsonb_build_object('t', coalesce(last_t, nullif(t, '-infinity'))), 'more', false));
      continue;
    elsif c = 'kv' then
      select coalesce(jsonb_object_agg(key, value), '{}'), max(updated_at) into rows, last_t
        from app.kv where store_id = x.store_id and updated_at > t
         and (x.role = 'admin' or key not in (select key from app.kv_admin_read));
      out := out || jsonb_build_object('kv', jsonb_build_object('rows', rows,
                     'cursor', jsonb_build_object('t', coalesce(last_t, nullif(t, '-infinity'))), 'more', false));
      continue;
    end if;

    select * into meta from app.colls where coll = c;
    if meta.coll is null then raise exception 'UNKNOWN_COLLECTION %', c; end if;
    if not (x.role = any (meta.read_roles)) then continue; end if;

    if c = 'us' then
      select coalesce(jsonb_agg(app.user_doc(u) order by u.updated_at, u.id) filter (where u.removed_at is null), '[]'),
             coalesce(jsonb_agg(u.id) filter (where u.removed_at is not null), '[]'),
             max(u.updated_at), count(*)
        into rows, rm, last_t, n
        from (select * from app.app_users where store_id = x.store_id and (updated_at, id) > (t, cid)
               order by updated_at, id limit p_limit) u;
      last_id := null;
    else
      strip := case when c in ('p','dp') and x.role = 'cashier' then array['cost','kv','kr'] else array[]::text[] end;
      execute format($q$
        select coalesce(jsonb_agg((r.doc - $5) || jsonb_build_object('_k', r.id::text) order by r.updated_at, r.id)
                          filter (where r.removed_at is null %s), '[]'),
               coalesce(jsonb_agg(r.id) filter (where r.removed_at is not null %s), '[]'),
               max(r.updated_at), count(*), (array_agg(r.id order by r.updated_at desc, r.id desc))[1]
          from (select * from app.%I where store_id = $1 and (updated_at, id) > ($2, $3) %s
                 order by updated_at, id limit $4) r$q$,
        case when meta.tbl = 'products' then 'and r.coll = ' || quote_literal(c) else '' end,
        case when meta.tbl = 'products' then 'or (r.removed_at is null and r.coll <> ' || quote_literal(c) || ')' else '' end,
        meta.tbl,
        case when t = '-infinity' then 'and removed_at is null' else '' end)
      into rows, rm, last_t, n, last_id
      using x.store_id, t, cid, p_limit, strip;
      if meta.tbl = 'products' and t = '-infinity' then
        -- first load: only rows that currently belong to this collection
        rows := coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) e), '[]');
      end if;
    end if;

    out := out || jsonb_build_object(c, jsonb_build_object('rows', rows, 'rm', rm, 'more', n >= p_limit,
      'cursor', case when last_t is null then cur
                     else jsonb_build_object('t', last_t, 'id', coalesce(last_id::text, cid::text)) end));
  end loop;
  return out;
end $$;

-- ---------------------------------------------------------------- push helpers
create function app.can_write(x app.ctx_t, c text) returns boolean language sql stable set search_path = '' as $$
  select exists (select 1 from app.colls where coll = c and x.role = any (write_roles))
$$;

-- users collection (admin only): hashes passwords, protects the last admin and the caller's own account
create function app.push_user(x app.ctx_t, d jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  k uuid := (d->>'_k')::uuid; u app.app_users; pw text := nullif(d->>'pw', '');
  v_role text := coalesce(d->>'role', 'cashier'); v_active boolean := coalesce((d->>'active') in ('1','true'), false);
  admins int;
begin
  select * into u from app.app_users where id = k;
  if u.id is not null and u.store_id <> x.store_id then raise exception 'FORBIDDEN'; end if;
  if pw is not null and length(pw) < 4 then raise exception 'PASSWORD_TOO_SHORT'; end if;
  if u.id is null and pw is null then raise exception 'PASSWORD_REQUIRED'; end if;
  if u.id = x.user_id and (v_role <> 'admin' or not v_active) then raise exception 'CANNOT_DEMOTE_SELF'; end if;
  if u.id is not null and u.role = 'admin' and u.active and (v_role <> 'admin' or not v_active) then
    select count(*) into admins from app.app_users where store_id = x.store_id and role = 'admin' and active and removed_at is null;
    if admins <= 1 then raise exception 'LAST_ADMIN'; end if;
  end if;
  insert into app.app_users as a (id, store_id, lid, username, password_hash, name, phone, role, branch, active, perms,
                                   must_change_password, created_at)
  values (k, x.store_id, (d->>'id')::bigint, d->>'u', coalesce(app.hash_pw(pw), ''), coalesce(d->>'name', ''),
          coalesce(d->>'phone', ''), v_role, coalesce(d->>'branch', ''), v_active, coalesce(d->'perms', '{}'),
          pw is not null and k <> x.user_id, now())
  on conflict (id) do update set
    username = excluded.username, name = excluded.name, phone = excluded.phone, role = excluded.role,
    branch = excluded.branch, active = excluded.active, perms = excluded.perms, removed_at = null,
    password_hash = case when pw is null then a.password_hash else excluded.password_hash end,
    must_change_password = case when pw is null then a.must_change_password else (a.id <> x.user_id) end
  returning * into u;
  if not u.active then update app.sessions set revoked_at = now() where user_id = u.id and revoked_at is null; end if;
  return app.user_doc(u);
end $$;

create function app.remove_user(x app.ctx_t, k uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare u app.app_users; admins int;
begin
  select * into u from app.app_users where id = k and store_id = x.store_id;
  if u.id is null then return; end if;
  if u.id = x.user_id then raise exception 'CANNOT_REMOVE_SELF'; end if;
  if u.role = 'admin' then
    select count(*) into admins from app.app_users where store_id = x.store_id and role = 'admin' and active and removed_at is null;
    if admins <= 1 then raise exception 'LAST_ADMIN'; end if;
  end if;
  update app.app_users set removed_at = now(), active = false where id = k;
  update app.sessions set revoked_at = now() where user_id = k and revoked_at is null;
end $$;

-- role checks for a single record written by a non-admin
create function app.check_record(x app.ctx_t, c text, d jsonb, existing jsonb) returns void
language plpgsql stable set search_path = '' as $$
begin
  if x.role = 'admin' then return; end if;
  if x.role = 'cashier' then
    if c = 's' then
      if existing is null and x.branch <> '' and coalesce(d->>'b', '') <> x.branch then raise exception 'WRONG_BRANCH'; end if;
      if existing is null and coalesce(d->>'u', '') <> x.username then raise exception 'WRONG_USER'; end if;
    elsif c = 'c' then
      if not app.has_perm(x, 'reg') and existing is null then raise exception 'NO_PERMISSION reg'; end if;
    elsif c = 'cm' then
      if not app.has_perm(x, 'cmv') then raise exception 'NO_PERMISSION cmv'; end if;
    elsif c = 'tr' then
      -- cashiers only confirm receipt of transfers addressed to their branch
      if existing is null or not app.has_perm(x, 'rcv') or coalesce(d->>'to', '') <> x.branch then
        raise exception 'NO_PERMISSION rcv';
      end if;
    elsif c = 'hold' then
      if coalesce(d->>'u', '') <> x.username then raise exception 'WRONG_USER'; end if;
    elsif c = 'sh' then
      if x.branch <> '' and coalesce(d->>'b', x.branch) <> x.branch then raise exception 'WRONG_BRANCH'; end if;
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------- push
-- p: {"rm": {"coll": ["k", ...]}, "up": {"coll": [doc, ...]}, "st": {"skey": delta}, "kv": {"key": value}}
create function public.sr_push(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  x app.ctx_t := app.ctx();
  meta app.colls; c text; k text; d jsonb; old jsonb; old_coll text; i int;
  patched jsonb := '{}'; users jsonb := '[]';
  sk text; dv numeric; q numeric; kvk text; kvv jsonb; roles text[];
begin
  if x.store_status = 'restricted' and jsonb_array_length(coalesce(p->'up'->'s', '[]')) > 0 then
    raise exception 'STORE_RESTRICTED';
  end if;

  -- 1. removals (all collections first, so that moving a product p -> dp works in one push)
  for c in select jsonb_object_keys(coalesce(p->'rm', '{}')) loop
    select * into meta from app.colls where coll = c;
    if meta.coll is null then raise exception 'UNKNOWN_COLLECTION %', c; end if;
    if not app.can_write(x, c) then raise exception 'NO_PERMISSION %', c; end if;
    if meta.append_only then raise exception 'APPEND_ONLY %', c; end if;
    for k in select jsonb_array_elements_text(p->'rm'->c) loop
      if c = 'us' then perform app.remove_user(x, k::uuid); continue; end if;
      if x.role = 'cashier' and c = 'hold' then
        if exists (select 1 from app.held_carts where id = k::uuid and doc->>'u' <> x.username) then
          raise exception 'WRONG_USER';
        end if;
      elsif x.role <> 'admin' and c not in ('hold') and not (x.role = 'wh' and c in ('p','dp','sup','pu','ih')) then
        raise exception 'NO_PERMISSION remove %', c;
      end if;
      execute format('update app.%I set removed_at = now(), updated_by = $3 where id = $1 and store_id = $2 and removed_at is null %s',
                     meta.tbl, case when meta.tbl = 'products' then 'and coll = ' || quote_literal(c) else '' end)
        using k::uuid, x.store_id, x.user_id;
    end loop;
  end loop;

  -- 2. upserts, in registry order
  for meta in select * from app.colls where coll in (select jsonb_object_keys(coalesce(p->'up', '{}'))) order by sort loop
    c := meta.coll;
    if not app.can_write(x, c) then raise exception 'NO_PERMISSION %', c; end if;
    for d in select jsonb_array_elements(p->'up'->c) loop
      k := d->>'_k';
      if k is null then raise exception 'MISSING_KEY in %', c; end if;
      if c = 'us' then users := users || app.push_user(x, d); continue; end if;
      d := d - '_k';

      old := null; old_coll := null; i := null;
      execute format('select doc, %s from app.%I where id = $1 and store_id = $2',
                     case when meta.tbl = 'products' then 'coll' else 'null::text' end, meta.tbl)
        into old, old_coll using k::uuid, x.store_id;
      if old is null then
        execute format('select 1 from app.%I where id = $1', meta.tbl) into i using k::uuid;
        if i = 1 then raise exception 'FORBIDDEN'; end if;     -- key belongs to another store
      end if;
      if old is not null and old = d and old_coll is not distinct from (case when meta.tbl = 'products' then c end) then
        continue;                                               -- identical re-send: nothing to do
      end if;
      perform app.check_record(x, c, d, old);

      if c = 's' and old is null then
        -- the server stamps the cost of goods sold (cashiers never receive product costs)
        d := jsonb_set(d, '{it}', coalesce((
          select jsonb_agg(case when app.to_num(l->>'q') > 0 and pr.id is not null then
                   (l - 'ck' - 'cr') || jsonb_build_object('cg', coalesce(pr.cost, 0))
                   || case when app.to_num(pr.doc->>'kv') > 0
                           then jsonb_build_object('ck', pr.doc->'kv', 'cr', pr.doc->'kr') else '{}' end
                 else l end order by o)
            from jsonb_array_elements(d->'it') with ordinality as e(l, o)
            left join app.products pr on pr.store_id = x.store_id and pr.lid = app.to_big(l->>'pid')
                  and pr.coll = 'p' and pr.removed_at is null), '[]'));
        patched := jsonb_set(patched, '{s}', coalesce(patched->'s', '[]') || jsonb_build_array(d || jsonb_build_object('_k', k)));
      end if;
      if meta.append_only and old is not null and c <> 's' then raise exception 'APPEND_ONLY %', c; end if;

      if meta.tbl = 'products' then
        insert into app.products as t (id, store_id, coll, doc, updated_by) values (k::uuid, x.store_id, c, d, x.user_id)
        on conflict (id) do update set doc = excluded.doc, coll = excluded.coll, removed_at = null, updated_by = excluded.updated_by;
      else
        execute format('insert into app.%I as t (id, store_id, doc, updated_by) values ($1, $2, $3, $4)
                        on conflict (id) do update set doc = excluded.doc, removed_at = null, updated_by = excluded.updated_by',
                       meta.tbl) using k::uuid, x.store_id, d, x.user_id;
      end if;
    end loop;
  end loop;

  -- 3. stock: deltas, never absolute values, so two tills selling the same item cannot overwrite each other
  for sk, d in select * from jsonb_each(coalesce(p->'st', '{}')) loop
    dv := app.to_num(d #>> '{}');
    if dv is null or dv = 0 then continue; end if;
    if x.role <> 'admin' and x.branch <> '' and split_part(sk, '|', 1) <> x.branch then
      raise exception 'WRONG_BRANCH stock %', sk;
    end if;
    insert into app.stock_levels as s (store_id, skey, qty) values (x.store_id, sk, dv)
    on conflict (store_id, skey) do update set qty = s.qty + excluded.qty
    returning qty into q;
    insert into app.stock_movements (store_id, skey, delta, qty_after, user_id) values (x.store_id, sk, dv, q, x.user_id);
  end loop;

  -- 4. settings and small objects
  for kvk, kvv in select * from jsonb_each(coalesce(p->'kv', '{}')) loop
    if x.role <> 'admin' then
      select r.roles into roles from app.kv_write r where r.key = kvk;
      if roles is null or not (x.role = any (roles)) then raise exception 'NO_PERMISSION setting %', kvk; end if;
    end if;
    if kvv is null or kvv = 'null'::jsonb then
      delete from app.kv where store_id = x.store_id and key = kvk;
    else
      insert into app.kv as t (store_id, key, value, updated_by) values (x.store_id, kvk, kvv, x.user_id)
      on conflict (store_id, key) do update set value = excluded.value, updated_by = excluded.updated_by;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'patched', patched, 'users', users);
end $$;

revoke execute on function public.sr_pull(text[], jsonb, int), public.sr_push(jsonb) from public, anon;
grant execute on function public.sr_pull(text[], jsonb, int), public.sr_push(jsonb) to authenticated;
