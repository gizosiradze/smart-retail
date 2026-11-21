-- Smart Retail · interim custom login (shop + username + password)
-- Flow: browser -> Edge Function "store-login" -> public.sr_login (service role only) -> session row
--       -> the function signs a JWT {role:authenticated, sub, store_id, app_uid, app_role, jti, exp}
--       -> every API call carries that JWT; app.ctx() re-checks the session on each call.

-- ---------------------------------------------------------------- session context
create type app.ctx_t as (
  user_id uuid, store_id uuid, lid bigint, username text, role text, branch text,
  perms jsonb, store_status text, jti uuid
);

-- Returns the caller's verified context or raises. Called first by every store API function.
create function app.ctx() returns app.ctx_t
language plpgsql stable security definer set search_path = '' as $$
declare
  c jsonb := auth.jwt();
  r app.ctx_t;
begin
  if c is null or c->>'jti' is null or c->>'store_id' is null then
    raise exception 'SESSION_REQUIRED' using errcode = '28000';
  end if;
  select u.id, u.store_id, u.lid, u.username::text, u.role, u.branch, u.perms, st.status, s.jti
    into r
    from app.sessions s
    join app.app_users u on u.id = s.user_id
    join app.stores st on st.id = u.store_id
   where s.jti = (c->>'jti')::uuid
     and s.revoked_at is null and s.expires_at > now()
     and u.active and u.removed_at is null
     and u.store_id = (c->>'store_id')::uuid
     and st.status <> 'suspended';
  if r.user_id is null then
    raise exception 'SESSION_EXPIRED' using errcode = '28000';
  end if;
  return r;
end $$;

create function app.has_perm(x app.ctx_t, p text) returns boolean language sql immutable as
$$ select x.role = 'admin' or coalesce((x.perms->>p) in ('1','true'), false) $$;

-- ---------------------------------------------------------------- password helpers
create function app.hash_pw(p text) returns text language sql volatile set search_path = '' as
$$ select extensions.crypt(p, extensions.gen_salt('bf', 10)) $$;

create function app.check_pw(p text, h text) returns boolean language sql stable set search_path = '' as
$$ select h is not null and extensions.crypt(p, h) = h $$;

-- 10 characters without look-alike letters (same alphabet as the Super Admin prototype)
create function app.gen_password(n int default 10) returns text language plpgsql volatile set search_path = '' as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'; b bytea := extensions.gen_random_bytes(n); s text := '';
begin
  for i in 0..n-1 loop s := s || substr(a, 1 + (get_byte(b, i) % length(a)), 1); end loop;
  return s;
end $$;

-- ---------------------------------------------------------------- login (service role only)
create function public.sr_login(p_shop text, p_username text, p_password text,
                                p_ip text default null, p_user_agent text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_store app.stores;
  v_user app.app_users;
  v_fail_user int; v_fail_ip int;
  v_ok boolean := false;
  v_jti uuid;
  v_exp timestamptz := now() + interval '8 hours';
  dummy constant text := 'CREATE EXTENSION
$2a$10$aJx.S1ZlTJZSSZihWp714.0zkY2dOYP1Y8fD.FXaVn3yI7whtKVCa';
begin
  p_shop := lower(btrim(coalesce(p_shop, ''))); p_username := lower(btrim(coalesce(p_username, '')));
  if p_shop = '' or p_username = '' or coalesce(p_password, '') = '' then
    return jsonb_build_object('ok', false, 'error', 'invalid_credentials');
  end if;

  -- rate limits: 5 failures per shop+user and 30 per IP in 15 minutes
  select count(*) into v_fail_user from app.login_attempts
   where lower(slug) = p_shop and lower(username) = p_username and not ok and at > now() - interval '15 minutes';
  select count(*) into v_fail_ip from app.login_attempts
   where p_ip is not null and ip = p_ip and not ok and at > now() - interval '15 minutes';
  if v_fail_user >= 5 or v_fail_ip >= 30 then
    insert into app.login_attempts (slug, username, ip, ok) values (p_shop, p_username, p_ip, false);
    return jsonb_build_object('ok', false, 'error', 'too_many_attempts');
  end if;

  select * into v_store from app.stores where slug = p_shop::extensions.citext;
  if found then
    select * into v_user from app.app_users
     where store_id = v_store.id and username = p_username::extensions.citext and removed_at is null;
  end if;

  if v_user.id is null then
    perform app.check_pw(p_password, dummy);                    -- same cost as a real check
  elsif v_user.locked_until is not null and v_user.locked_until > now() then
    insert into app.login_attempts (slug, username, ip, ok) values (p_shop, p_username, p_ip, false);
    return jsonb_build_object('ok', false, 'error', 'too_many_attempts');
  else
    v_ok := app.check_pw(p_password, v_user.password_hash);
  end if;

  if not v_ok then
    insert into app.login_attempts (slug, username, ip, ok) values (p_shop, p_username, p_ip, false);
    if v_user.id is not null then
      update app.app_users set failed_count = failed_count + 1,
             locked_until = case when failed_count + 1 >= 5 then now() + interval '15 minutes' end
       where id = v_user.id;
    end if;
    return jsonb_build_object('ok', false, 'error', 'invalid_credentials');
  end if;

  if v_store.status = 'suspended' then
    return jsonb_build_object('ok', false, 'error', 'store_suspended');
  end if;
  if not v_user.active then
    return jsonb_build_object('ok', false, 'error', 'account_disabled');
  end if;

  insert into app.login_attempts (slug, username, ip, ok) values (p_shop, p_username, p_ip, true);
  update app.app_users set failed_count = 0, locked_until = null, last_login_at = now() where id = v_user.id;
  insert into app.sessions (user_id, store_id, expires_at, ip, user_agent)
       values (v_user.id, v_store.id, v_exp, p_ip, left(p_user_agent, 300))
    returning jti into v_jti;

  return jsonb_build_object('ok', true, 'jti', v_jti, 'exp', extract(epoch from v_exp)::bigint,
    'user_id', v_user.id, 'store_id', v_store.id, 'role', v_user.role);
end $$;

-- ---------------------------------------------------------------- session functions (logged-in users)
create function public.sr_me() returns jsonb
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
                           where b.store_id = s.id and b.active), '[]'::jsonb));
end $$;

create function public.sr_logout() returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  update app.sessions set revoked_at = now()
   where jti = nullif(auth.jwt()->>'jti', '')::uuid and revoked_at is null;
end $$;

create function public.sr_change_password(p_old text, p_new text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx(); h text;
begin
  select password_hash into h from app.app_users where id = x.user_id;
  if not app.check_pw(coalesce(p_old, ''), h) then raise exception 'WRONG_PASSWORD' using errcode = '28P01'; end if;
  if length(coalesce(p_new, '')) < 8 then raise exception 'PASSWORD_TOO_SHORT'; end if;
  update app.app_users set password_hash = app.hash_pw(p_new), must_change_password = false where id = x.user_id;
  -- sign out every other session of this user
  update app.sessions set revoked_at = now() where user_id = x.user_id and jti <> x.jti and revoked_at is null;
end $$;

-- Reserve a block of integer ids (receipt numbers, customer ids, ...) for this browser session.
create function public.sr_alloc_ids(p_count int default 200) returns bigint
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx(); v bigint;
begin
  p_count := least(greatest(coalesce(p_count, 200), 1), 5000);
  update app.stores set id_counter = id_counter + p_count where id = x.store_id
  returning id_counter - p_count into v;
  return v;
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on all functions in schema app from public;
revoke execute on function public.sr_login(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.sr_login(text,text,text,text,text) to service_role;
revoke execute on function public.sr_me(), public.sr_logout(), public.sr_change_password(text,text),
                           public.sr_alloc_ids(int) from public, anon;
grant execute on function public.sr_me(), public.sr_logout(), public.sr_change_password(text,text),
                          public.sr_alloc_ids(int) to authenticated;
