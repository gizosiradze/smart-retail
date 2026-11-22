-- Sign-in lasts 12 hours (was 8). Only the interval changes; the rest of sr_login is as in 20261121000002.
-- ---------------------------------------------------------------- login (service role only)
create or replace function public.sr_login(p_shop text, p_username text, p_password text,
                                p_ip text default null, p_user_agent text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_store app.stores;
  v_user app.app_users;
  v_fail_user int; v_fail_ip int;
  v_ok boolean := false;
  v_jti uuid;
  v_exp timestamptz := now() + interval '12 hours';
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
