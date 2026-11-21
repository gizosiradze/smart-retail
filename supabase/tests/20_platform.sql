-- Super Admin: access rules, store registration, password reset, metrics, pull/push.
begin;
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if c is not true then raise exception 'FAILED: %', msg; end if; end $$;
create function pg_temp.err(q text) returns text language plpgsql as
$$ begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.as_user(j jsonb) returns void language plpgsql as
$$ begin perform set_config('role', 'authenticated', true); perform set_config('request.jwt.claims', j::text, true); end $$;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000001', 'owner@example.com'),
                                          ('aaaaaaaa-0000-0000-0000-000000000002', 'stranger@example.com');
insert into app.platform_admins (user_id, email) values ('aaaaaaaa-0000-0000-0000-000000000001', 'owner@example.com');

-- a signed-in user who is not a platform admin
select pg_temp.as_user('{"role":"authenticated","sub":"aaaaaaaa-0000-0000-0000-000000000002","aal":"aal2"}');
select pg_temp.ok(pg_temp.err('select public.sr_platform_pull()') = 'PLATFORM_ADMIN_REQUIRED', 'non-admin refused');
reset role;

-- the platform admin without the authenticator-app step
select pg_temp.as_user('{"role":"authenticated","sub":"aaaaaaaa-0000-0000-0000-000000000001","aal":"aal1"}');
select pg_temp.ok(pg_temp.err('select public.sr_platform_pull()') = 'MFA_REQUIRED', '2FA required');
select pg_temp.ok((public.sr_platform_whoami())->>'is_admin' = 'true', 'whoami works before 2FA');
reset role;

-- with 2FA
select pg_temp.as_user('{"role":"authenticated","sub":"aaaaaaaa-0000-0000-0000-000000000001","aal":"aal2"}');
create temp table reg as select public.sr_platform_register_store('{"login":"batumipets","name":"ბათუმი ფეთს","owner":"გიზო",
  "plan":"std","status":"trial","branches":["ბათუმი","თბილისი"],"payDay":5,"feeHist":[{"from":"2026-12","fee":89}]}'::jsonb) r;
select pg_temp.ok(jsonb_array_length((select r->'credentials' from reg)) = 1, 'only the admin is created (no cashiers)');
select pg_temp.ok(length((select r->'credentials'->0->>'pw' from reg)) = 10, '10-character temporary password');
select pg_temp.ok(pg_temp.err($q$select public.sr_platform_register_store('{"login":"batumipets","name":"x"}')$q$) = 'SLUG_TAKEN', 'slug unique');
select pg_temp.ok((select jsonb_array_length(r->'store'->'users') from reg) = 1, 'store doc lists real users');
select pg_temp.ok(((public.sr_platform_pull())->'stores'->0->>'login') = 'batumipets', 'pull returns stores');
select pg_temp.ok(jsonb_array_length((public.sr_platform_pull())->'plans') = 3, 'default plans');
select public.sr_platform_push(jsonb_build_object('payments', '[{"id":"p1","store":"x","period":"2026-12","amount":89,"date":"2026-12-05","method":"გადარიცხვა"}]'::jsonb,
  'audit', '[{"id":"a1","t":"2026-11-21 10:00","a":"ტესტი"}]'::jsonb));
select pg_temp.ok(jsonb_array_length((public.sr_platform_pull())->'payments') = 1, 'payment saved');
select pg_temp.ok((public.sr_platform_metrics()) ? (select r->'store'->>'id' from reg), 'metrics per store');
reset role;

-- the temporary admin password works, then the Super Admin resets it
create temp table creds as select (select r->'credentials'->0->>'pw' from reg) pw, (select (r->'store'->>'id')::uuid from reg) sid;
grant select on creds to service_role, authenticated;
set local role service_role; select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select pg_temp.ok((public.sr_login('batumipets', 'admin', (select pw from creds)))->>'ok' = 'true', 'registered admin can log in');
reset role;
grant select on creds to authenticated;
select pg_temp.as_user('{"role":"authenticated","sub":"aaaaaaaa-0000-0000-0000-000000000001","aal":"aal2"}');
create temp table rs as select public.sr_platform_reset_password((select sid from creds), 'admin') r;
reset role;
grant select on rs to service_role;
set local role service_role; select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select pg_temp.ok((public.sr_login('batumipets', 'admin', (select pw from creds)))->>'ok' = 'false', 'old password stops working');
select pg_temp.ok((public.sr_login('batumipets', 'admin', (select r->>'pw' from rs)))->>'ok' = 'true', 'reset password works');
reset role;

-- suspending a store blocks logins
select pg_temp.as_user('{"role":"authenticated","sub":"aaaaaaaa-0000-0000-0000-000000000001","aal":"aal2"}');
select public.sr_platform_push(jsonb_build_object('stores', jsonb_build_array(jsonb_build_object('id', (select sid from creds), 'name', 'ბათუმი ფეთს', 'status', 'suspended'))));
reset role;
set local role service_role; select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select pg_temp.ok((public.sr_login('batumipets', 'admin', (select r->>'pw' from rs)))->>'error' = 'store_suspended', 'suspended store cannot log in');
reset role;
select 'platform tests passed';
rollback;
