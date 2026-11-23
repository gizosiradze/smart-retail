-- Smart Retail · push notifications to the admins' phones (PWA, Web Push)
-- Flow: a new sale row -> trigger -> pg_net POST to the Edge Function "push-notify" (with a shared secret)
--       -> the function reads the sale and the store admins' subscriptions (public.sr_push_prepare)
--       -> sends a Web Push to each admin device. Dead subscriptions are removed (public.sr_push_prune).
-- A failed notification never blocks or rolls back a sale: the trigger swallows every error.

do $$ begin
  create extension if not exists pg_net with schema extensions;
exception when others then
  raise notice 'pg_net is not available here: push notifications stay off until it is enabled';
end $$;

create table app.push_subs (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references app.stores on delete cascade,
  user_id uuid not null references app.app_users on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now()
);
create index on app.push_subs (store_id);
create index on app.push_subs (user_id);
alter table app.push_subs enable row level security;       -- no policies: only the security-definer functions touch it

-- One row: where the Edge Function lives, the shared secret, the public VAPID key (set by npm run deploy).
create table app.push_config (
  id boolean primary key default true check (id),
  url text not null,
  secret text not null,
  vapid_public text not null
);
alter table app.push_config enable row level security;

create function public.sr_push_config(p_url text, p_secret text, p_vapid_public text) returns void
language sql volatile security definer set search_path = '' as $$
  insert into app.push_config (id, url, secret, vapid_public) values (true, p_url, p_secret, p_vapid_public)
  on conflict (id) do update set url = excluded.url, secret = excluded.secret, vapid_public = excluded.vapid_public
$$;

-- Public key the browser needs to subscribe; null while push is not configured.
create function public.sr_push_key() returns text
language plpgsql stable security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx();
begin
  return (select vapid_public from app.push_config);
end $$;

create function public.sr_push_subscribe(p jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx(); e text := p->>'endpoint';
begin
  if app.read_only() then raise exception 'READ_ONLY' using errcode = '42501'; end if;
  if x.role <> 'admin' then raise exception 'ADMIN_ONLY' using errcode = '42501'; end if;
  if e is null or e !~ '^https://' or coalesce(p->'keys'->>'p256dh', '') = '' or coalesce(p->'keys'->>'auth', '') = ''
    then raise exception 'BAD_SUBSCRIPTION'; end if;
  insert into app.push_subs (store_id, user_id, endpoint, p256dh, auth, user_agent)
  values (x.store_id, x.user_id, e, p->'keys'->>'p256dh', p->'keys'->>'auth', left(p->>'ua', 300))
  on conflict (endpoint) do update
    set store_id = excluded.store_id, user_id = excluded.user_id, p256dh = excluded.p256dh,
        auth = excluded.auth, user_agent = excluded.user_agent;
  -- at most 10 devices per admin: the oldest go first
  delete from app.push_subs where id in (
    select id from app.push_subs where user_id = x.user_id order by created_at desc offset 10);
end $$;

create function public.sr_push_unsubscribe(p_endpoint text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx();
begin
  delete from app.push_subs where endpoint = p_endpoint and user_id = x.user_id;
end $$;

-- Edge Function only: what to say and to whom. Only admins who are still active get a message.
create function public.sr_push_prepare(p_sale uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'sale', jsonb_build_object('id', s.lid, 'branch', s.branch, 'user', s.username, 'total', s.total,
                               'method', s.method, 'ret', s.return_of, 'store', st.name),
    'subs', coalesce((select jsonb_agg(jsonb_build_object('id', ps.id, 'endpoint', ps.endpoint, 'p256dh', ps.p256dh, 'auth', ps.auth))
                        from app.push_subs ps
                        join app.app_users u on u.id = ps.user_id
                       where ps.store_id = s.store_id and u.role = 'admin' and u.active and u.removed_at is null), '[]'))
    from app.sales s join app.stores st on st.id = s.store_id
   where s.id = p_sale and s.removed_at is null
$$;

create function public.sr_push_prune(p_ids uuid[]) returns void
language sql volatile security definer set search_path = '' as $$
  delete from app.push_subs where id = any(p_ids)
$$;

create function app.sales_push() returns trigger
language plpgsql volatile security definer set search_path = '' as $$
declare c app.push_config;
begin
  begin
    -- an old receipt arriving late (offline sync, import) is not news
    if new.sold_at is null or new.sold_at < now() - interval '1 day' then return new; end if;
    if not exists (select 1 from app.push_subs where store_id = new.store_id) then return new; end if;
    select * into c from app.push_config;
    if c.url is null then return new; end if;
    perform net.http_post(url => c.url,
      headers => jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', c.secret),
      body => jsonb_build_object('sale_id', new.id),
      timeout_milliseconds => 5000);
  exception when others then
    null;   -- never let a notification problem touch the sale
  end;
  return new;
end $$;

create trigger sales_push after insert on app.sales
  for each row execute function app.sales_push();

-- grants (same rules as 20261121000006_lockdown.sql, which has already run)
revoke execute on function public.sr_push_config(text,text,text), public.sr_push_prepare(uuid), public.sr_push_prune(uuid[])
  from public, anon, authenticated;
grant execute on function public.sr_push_config(text,text,text), public.sr_push_prepare(uuid), public.sr_push_prune(uuid[])
  to service_role;
revoke execute on function public.sr_push_key(), public.sr_push_subscribe(jsonb), public.sr_push_unsubscribe(text)
  from public, anon;
grant execute on function public.sr_push_key(), public.sr_push_subscribe(jsonb), public.sr_push_unsubscribe(text)
  to authenticated, service_role;
revoke execute on function app.sales_push() from public, anon, authenticated;
grant execute on function app.sales_push() to service_role;
revoke all on app.push_subs, app.push_config from public, anon, authenticated;
