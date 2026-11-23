-- Smart Retail · notification preferences per admin device, and more events than "a sale was recorded".
--
-- Each subscribed device (phone) keeps its own preferences in app.push_subs.prefs:
--   { "ev": { "<kind>": 0|1, ... }, "bigN": 500, "lowN": 2, "br": ["branch", ...] }      br empty = all branches
-- Event kinds:
--   sale  every sale                         ret  every return                big  a sale of at least bigN ₾
--   sho   shift opened                       shc  shift closed                shd  shift closed with a cash difference
--   cm    cash put in / taken out            pu   a purchase was recorded
--   trs   transfer sent                      trr  transfer received           trd  transfer received with a shortage
--   low   stock of a size fell to lowN or fewer
-- Without saved preferences a device gets sales and returns only (what it got before this migration).
--
-- Every event goes through app.push_event -> Edge Function "push-notify" -> sr_push_targets (who wants it).
-- As before: a notification problem never blocks or rolls back the change that caused it.

alter table app.push_subs add column prefs jsonb not null default '{}'::jsonb;

-- Keeps only known keys and sane values, whatever the browser sends.
create function app.push_clean(p jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'ev', coalesce((select jsonb_object_agg(k, case when p->'ev'->>k in ('1', 'true') then 1 else 0 end)
                      from unnest(array['sale','ret','big','sho','shc','shd','cm','pu','trs','trr','trd','low']) k), '{}'::jsonb),
    'bigN', least(greatest(coalesce(app.to_num(p->>'bigN'), 500), 0), 10000000),
    'lowN', least(greatest(floor(coalesce(app.to_num(p->>'lowN'), 2)), 0), 1000),
    'br', coalesce((select jsonb_agg(b) from (
                      select left(x, 100) b from jsonb_array_elements_text(
                        case when jsonb_typeof(p->'br') = 'array' then p->'br' else '[]'::jsonb end) x limit 50) q), '[]'::jsonb))
$$;

-- Does a device with these preferences want this event?
create function app.push_wants(prefs jsonb, p_kind text, p_branch text, p_amount numeric, p_prev numeric) returns boolean
language sql immutable set search_path = '' as $$
  select (coalesce(jsonb_array_length(case when jsonb_typeof(prefs->'br') = 'array' then prefs->'br' end), 0) = 0
          or p_branch is null or prefs->'br' ? p_branch)
     and case p_kind
           when 'big' then coalesce(prefs->'ev'->>'big', '0') = '1'
                           and coalesce(p_amount, 0) >= coalesce(app.to_num(prefs->>'bigN'), 500)
           when 'low' then coalesce(prefs->'ev'->>'low', '0') = '1'
                           and p_prev > coalesce(app.to_num(prefs->>'lowN'), 2)
                           and p_amount <= coalesce(app.to_num(prefs->>'lowN'), 2)
           when 'sale' then coalesce(prefs->'ev'->>'sale', '1') = '1'
           when 'ret' then coalesce(prefs->'ev'->>'ret', '1') = '1'
           else coalesce(prefs->'ev'->>p_kind, '0') = '1'
         end
$$;

-- Edge Function only: the devices that should get this event (active admins of the store only).
create function public.sr_push_targets(p_store uuid, p_kinds text[], p_branch text, p_amount numeric, p_prev numeric) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', ps.id, 'endpoint', ps.endpoint, 'p256dh', ps.p256dh, 'auth', ps.auth)), '[]'::jsonb)
    from app.push_subs ps
    join app.app_users u on u.id = ps.user_id
   where ps.store_id = p_store and u.role = 'admin' and u.active and u.removed_at is null
     and exists (select 1 from unnest(p_kinds) k where app.push_wants(ps.prefs, k, p_branch, p_amount, p_prev))
$$;

drop function public.sr_push_prepare(uuid);

create function app.push_event(p_store uuid, p_kinds text[], p_title text, p_body text, p_tag text,
                               p_branch text default null, p_amount numeric default null, p_prev numeric default null) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare c app.push_config;
begin
  begin
    if not exists (select 1 from app.push_subs where store_id = p_store) then return; end if;
    select * into c from app.push_config;
    if c.url is null then return; end if;
    perform net.http_post(url => c.url,
      headers => jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', c.secret),
      body => jsonb_build_object('store_id', p_store, 'kinds', to_jsonb(p_kinds), 'title', p_title, 'body', p_body,
                                 'tag', p_tag, 'branch', p_branch, 'amount', p_amount, 'prev', p_prev),
      timeout_milliseconds => 5000);
  exception when others then
    null;
  end;
end $$;

-- ---------------------------------------------------------------- the device's own preferences
create or replace function public.sr_push_subscribe(p jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx(); e text := p->>'endpoint';
begin
  if app.read_only() then raise exception 'READ_ONLY' using errcode = '42501'; end if;
  if x.role <> 'admin' then raise exception 'ADMIN_ONLY' using errcode = '42501'; end if;
  if e is null or e !~ '^https://' or coalesce(p->'keys'->>'p256dh', '') = '' or coalesce(p->'keys'->>'auth', '') = ''
    then raise exception 'BAD_SUBSCRIPTION'; end if;
  insert into app.push_subs as ps (store_id, user_id, endpoint, p256dh, auth, user_agent, prefs)
  values (x.store_id, x.user_id, e, p->'keys'->>'p256dh', p->'keys'->>'auth', left(p->>'ua', 300),
          app.push_clean(coalesce(p->'prefs', '{}'::jsonb)))
  on conflict (endpoint) do update
    set store_id = excluded.store_id, user_id = excluded.user_id, p256dh = excluded.p256dh,
        auth = excluded.auth, user_agent = excluded.user_agent,
        prefs = case when p ? 'prefs' then excluded.prefs else ps.prefs end;
  delete from app.push_subs where id in (
    select id from app.push_subs where user_id = x.user_id order by created_at desc offset 10);
end $$;

create function public.sr_push_prefs_get(p_endpoint text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx();
begin
  if x.role <> 'admin' then raise exception 'ADMIN_ONLY' using errcode = '42501'; end if;
  return (select case when ps.prefs = '{}'::jsonb then null else app.push_clean(ps.prefs) end
            from app.push_subs ps where ps.endpoint = p_endpoint and ps.user_id = x.user_id);
end $$;

create function public.sr_push_prefs_set(p_endpoint text, p jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx();
begin
  if x.role <> 'admin' then raise exception 'ADMIN_ONLY' using errcode = '42501'; end if;
  update app.push_subs set prefs = app.push_clean(p) where endpoint = p_endpoint and user_id = x.user_id;
end $$;

-- ---------------------------------------------------------------- events
-- sales and returns
create or replace function app.sales_push() returns trigger
language plpgsql volatile security definer set search_path = '' as $$
declare isr boolean;
begin
  begin
    -- an old receipt arriving late (offline sync, import) is not news
    if new.sold_at is null or new.sold_at < now() - interval '1 day' then return new; end if;
    isr := new.return_of is not null or coalesce(new.total, 0) < 0;
    perform app.push_event(new.store_id,
      case when isr then array['ret'] else array['sale', 'big'] end,
      case when isr then 'დაბრუნება' else 'გაყიდვა' end || ' · ' || coalesce(new.branch, ''),
      to_char(abs(coalesce(new.total, 0)), 'FM9999999990.00') || ' ₾' || case when isr then ' (დაბრუნება)' else '' end
        || coalesce(' · ' || new.method, '') || coalesce(' · ' || new.username, ''),
      'sale-' || coalesce(new.lid::text, new.id::text), new.branch, abs(coalesce(new.total, 0)));
  exception when others then null;
  end;
  return new;
end $$;

-- shifts: opened / closed / closed with a difference
create function app.shifts_push() returns trigger
language plpgsql volatile security definer set search_path = '' as $$
declare d jsonb := new.doc; o jsonb := case when tg_op = 'UPDATE' then old.doc end; df numeric;
begin
  begin
    if new.removed_at is not null then return new; end if;
    if d->>'st' = 'open' and o is null then
      if coalesce(app.ms_to_ts(d->>'ot'), now()) > now() - interval '1 day' then
        perform app.push_event(new.store_id, array['sho'], 'ცვლა გაიხსნა · ' || coalesce(new.branch, ''),
          coalesce(d->>'ou', '') || coalesce(' · საწყისი ნაღდი ' || to_char(app.to_num(d->>'oc'), 'FM9999999990.00') || ' ₾', ''),
          'sho-' || new.id, new.branch);
      end if;
    elsif d->>'st' = 'closed' and coalesce(o->>'st', '') <> 'closed' then
      if coalesce(app.ms_to_ts(d->>'ct'), now()) > now() - interval '1 day' then
        df := app.to_num(d->'res'->>'diff');
        perform app.push_event(new.store_id,
          case when coalesce(df, 0) <> 0 then array['shd', 'shc'] else array['shc'] end,
          case when coalesce(df, 0) <> 0 then 'ცვლა დაიხურა სხვაობით' else 'ცვლა დაიხურა' end || ' · ' || coalesce(new.branch, ''),
          coalesce(d->>'cu', d->>'ou', '')
            || case when coalesce(df, 0) <> 0 then ' · ' || case when df < 0 then 'დანაკლისი ' else 'ჭარბი ' end
                                                  || to_char(abs(df), 'FM9999999990.00') || ' ₾' else '' end,
          'shc-' || new.id, new.branch);
      end if;
    end if;
  exception when others then null;
  end;
  return new;
end $$;
create trigger shifts_push after insert or update on app.shifts for each row execute function app.shifts_push();

-- cash put in / taken out
create function app.cash_push() returns trigger
language plpgsql volatile security definer set search_path = '' as $$
declare d jsonb := new.doc; br text;
begin
  begin
    if coalesce(app.ms_to_ts(d->>'t'), now()) < now() - interval '1 day' then return new; end if;
    select s.branch into br from app.shifts s where s.store_id = new.store_id and s.doc->>'id' = new.shift_id limit 1;
    perform app.push_event(new.store_id, array['cm'],
      case when d->>'k' = 'in' then 'ფულის შეტანა' else 'ფულის გატანა' end || ' · ' || coalesce(br, ''),
      to_char(abs(coalesce(new.amount, 0)), 'FM9999999990.00') || ' ₾' || coalesce(' · ' || nullif(d->>'why', ''), '')
        || coalesce(' · ' || (d->>'u'), ''),
      'cm-' || new.id, br);
  exception when others then null;
  end;
  return new;
end $$;
create trigger cash_push after insert on app.cash_movements for each row execute function app.cash_push();

-- transfers: sent / received / received with a shortage
create function app.transfers_push() returns trigger
language plpgsql volatile security definer set search_path = '' as $$
declare d jsonb := new.doc; o jsonb := case when tg_op = 'UPDATE' then old.doc end; n numeric; short boolean;
begin
  begin
    if new.removed_at is not null then return new; end if;
    select coalesce(sum(app.to_num(l->>'q')), 0) into n from jsonb_array_elements(coalesce(d->'L', '[]'::jsonb)) l;
    if d->>'st' = 'sent' and coalesce(o->>'st', '') <> 'sent' and coalesce(app.ms_to_ts(d->>'ts'), now()) > now() - interval '1 day' then
      perform app.push_event(new.store_id, array['trs'],
        'გადაზიდვა გაიგზავნა · ' || coalesce(new.from_branch, '') || ' → ' || coalesce(new.to_branch, ''),
        '№' || coalesce(new.number::text, '') || ' · ' || n::text || ' ც.', 'trs-' || new.id, new.from_branch);
    elsif d->>'st' = 'recv' and coalesce(o->>'st', '') <> 'recv' and coalesce(app.ms_to_ts(d->>'tr'), now()) > now() - interval '1 day' then
      select exists (select 1 from jsonb_array_elements(coalesce(d->'L', '[]'::jsonb)) l
                      where app.to_num(l->>'r') < app.to_num(l->>'q')) into short;
      perform app.push_event(new.store_id, case when short then array['trd', 'trr'] else array['trr'] end,
        case when short then 'გადაზიდვა მიღებულია დანაკლისით' else 'გადაზიდვა მიღებულია' end
          || ' · ' || coalesce(new.from_branch, '') || ' → ' || coalesce(new.to_branch, ''),
        '№' || coalesce(new.number::text, '') || ' · ' || n::text || ' ც.', 'trr-' || new.id, new.to_branch);
    end if;
  exception when others then null;
  end;
  return new;
end $$;
create trigger transfers_push after insert or update on app.transfers for each row execute function app.transfers_push();

-- purchases (one row per size: the shared tag makes the phone show one notification per supplier and minute)
create function app.purchases_push() returns trigger
language plpgsql volatile security definer set search_path = '' as $$
begin
  begin
    if new.bought_at is null or new.bought_at < now() - interval '1 day' then return new; end if;
    perform app.push_event(new.store_id, array['pu'], 'შესყიდვა · ' || coalesce(new.branch, ''),
      coalesce(nullif(new.supplier, ''), 'მომწოდებელი') || ' · ახალი მარაგი დაემატა',
      'pu-' || coalesce(new.branch, '') || '-' || coalesce(new.supplier, '') || '-' || (extract(epoch from new.bought_at)::bigint / 60)::text,
      new.branch);
  exception when others then null;
  end;
  return new;
end $$;
create trigger purchases_push after insert on app.purchases for each row execute function app.purchases_push();

-- low stock: only when the quantity goes down (the check per device happens in sr_push_targets)
create function app.stock_push() returns trigger
language plpgsql volatile security definer set search_path = '' as $$
declare nm text;
begin
  begin
    if tg_op <> 'UPDATE' or new.qty >= old.qty then return new; end if;
    if not exists (select 1 from app.push_subs where store_id = new.store_id and prefs->'ev'->>'low' = '1') then return new; end if;
    select p.name into nm from app.products p where p.store_id = new.store_id and p.lid = new.product_lid and p.coll = 'p' limit 1;
    perform app.push_event(new.store_id, array['low'], 'მარაგი იწურება · ' || coalesce(new.branch, ''),
      coalesce(nm, 'პროდუქტი') || coalesce(' (' || nullif(new.variant, '') || ')', '') || ' · დარჩა ' || new.qty::text || ' ც.',
      'low-' || new.skey, new.branch, new.qty, old.qty);
  exception when others then null;
  end;
  return new;
end $$;
create trigger stock_push after update of qty on app.stock_levels for each row execute function app.stock_push();

-- ---------------------------------------------------------------- grants (same rules as 20261121000006_lockdown.sql)
revoke execute on function public.sr_push_targets(uuid, text[], text, numeric, numeric) from public, anon, authenticated;
grant execute on function public.sr_push_targets(uuid, text[], text, numeric, numeric) to service_role;
revoke execute on function public.sr_push_prefs_get(text), public.sr_push_prefs_set(text, jsonb) from public, anon;
grant execute on function public.sr_push_prefs_get(text), public.sr_push_prefs_set(text, jsonb) to authenticated, service_role;
revoke execute on function app.push_clean(jsonb), app.push_wants(jsonb, text, text, numeric, numeric),
  app.push_event(uuid, text[], text, text, text, text, numeric, numeric),
  app.shifts_push(), app.cash_push(), app.transfers_push(), app.purchases_push(), app.stock_push()
  from public, anon, authenticated;
grant execute on function app.push_clean(jsonb), app.push_wants(jsonb, text, text, numeric, numeric),
  app.push_event(uuid, text[], text, text, text, text, numeric, numeric),
  app.shifts_push(), app.cash_push(), app.transfers_push(), app.purchases_push(), app.stock_push()
  to service_role;
