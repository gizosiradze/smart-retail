-- Smart Retail · Super Admin opens a store's own dashboard (read-only)
-- The Super Admin (aal2) gets a short session as the store's admin, marked read_only. The store app
-- then loads exactly what the store admin sees: every screen, every statistic. Nothing can be saved:
-- the store-side write entry points refuse read-only sessions.
-- Flow: Super Admin -> Edge Function store-login {"platform_store": id} with the Super Admin's own token
--       -> public.sr_platform_open_store (checks the Super Admin) -> session row -> signed store JWT.

alter table app.sessions add column read_only boolean not null default false,
                         add column platform_uid uuid;

-- true when the caller's session is a Super Admin view
create function app.read_only() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.read_only from app.sessions s where s.jti = nullif(auth.jwt()->>'jti', '')::uuid), false)
$$;

create function public.sr_platform_open_store(p_store uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := app.require_platform_admin();
  s app.stores; u app.app_users; v_jti uuid;
  v_exp timestamptz := now() + interval '2 hours';
begin
  select * into s from app.stores where id = p_store;
  if s.id is null then raise exception 'STORE_NOT_FOUND'; end if;
  if s.status = 'suspended' then raise exception 'STORE_SUSPENDED'; end if;
  select * into u from app.app_users
   where store_id = s.id and role = 'admin' and active and removed_at is null order by lid limit 1;
  if u.id is null then raise exception 'NO_STORE_ADMIN'; end if;
  insert into app.sessions (user_id, store_id, expires_at, user_agent, read_only, platform_uid)
       values (u.id, s.id, v_exp, 'super-admin view', true, uid)
    returning jti into v_jti;
  return jsonb_build_object('ok', true, 'jti', v_jti, 'exp', extract(epoch from v_exp)::bigint,
    'user_id', u.id, 'store_id', s.id, 'role', u.role);
end $$;

-- sr_me tells the app it is a Super Admin view
create or replace function public.sr_me() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx(); u app.app_users; s app.stores;
begin
  select * into u from app.app_users where id = x.user_id;
  select * into s from app.stores where id = x.store_id;
  return jsonb_build_object(
    'user', jsonb_build_object('id', u.lid, 'uid', u.id, 'u', u.username::text, 'name', u.name, 'role', u.role,
                               'branch', u.branch, 'perms', u.perms, 'must_change_password', u.must_change_password),
    'store', jsonb_build_object('id', s.id, 'slug', s.slug::text, 'name', s.name, 'status', s.status),
    'branches', coalesce((select jsonb_agg(b.name order by b.sort, b.name) from app.branches b
                           where b.store_id = s.id and b.active), '[]'::jsonb),
    'read_only', app.read_only());
end $$;

-- ---------------------------------------------------------------- write entry points refuse read-only sessions
-- The original functions move to schema app unchanged; the public names check first, then call them.
alter function public.sr_push(jsonb) set schema app;
alter function app.sr_push(jsonb) rename to push_rw;
create function public.sr_push(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  if app.read_only() then raise exception 'READ_ONLY' using errcode = '42501'; end if;
  return app.push_rw(p);
end $$;

alter function public.sr_change_password(text, text) set schema app;
alter function app.sr_change_password(text, text) rename to change_password_rw;
create function public.sr_change_password(p_old text, p_new text) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if app.read_only() then raise exception 'READ_ONLY' using errcode = '42501'; end if;
  perform app.change_password_rw(p_old, p_new);
end $$;

-- the app reserves an id block at start-up; a read-only view gets the current counter without reserving
alter function public.sr_alloc_ids(int) set schema app;
alter function app.sr_alloc_ids(int) rename to alloc_ids_rw;
create function public.sr_alloc_ids(p_count int default 200) returns bigint
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t;
begin
  if app.read_only() then
    x := app.ctx();
    return (select id_counter from app.stores where id = x.store_id);
  end if;
  return app.alloc_ids_rw(p_count);
end $$;

create or replace function app.storage_can_write(p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare x app.ctx_t;
begin
  begin
    x := app.ctx();
  exception when others then
    return false;
  end;
  return not app.read_only() and x.role in ('admin', 'wh') and (storage.foldername(p_name))[1] = x.store_id::text;
end $$;

-- ---------------------------------------------------------------- grants (same rules as 0006 lockdown)
revoke execute on all functions in schema app from public, anon, authenticated;
grant execute on function app.storage_can_write(text) to authenticated;
grant execute on all functions in schema app to service_role;
revoke execute on function public.sr_push(jsonb), public.sr_change_password(text, text), public.sr_alloc_ids(int),
                           public.sr_me(), public.sr_platform_open_store(uuid) from public, anon;
grant execute on function public.sr_push(jsonb), public.sr_change_password(text, text), public.sr_alloc_ids(int),
                          public.sr_me(), public.sr_platform_open_store(uuid) to authenticated, service_role;
