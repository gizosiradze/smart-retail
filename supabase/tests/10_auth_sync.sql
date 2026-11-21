-- End-to-end checks of login, sessions, pull/push and the security rules.
-- Runs inside one transaction and rolls back.
begin;

create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if c is not true then raise exception 'FAILED: %', msg; end if; end $$;
-- run a statement and return the error message ('' when it succeeds)
create function pg_temp.err(q text) returns text language plpgsql as
$$ begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.as_service() returns void language plpgsql as
$$ begin perform set_config('role', 'service_role', true); perform set_config('request.jwt.claims', '{"role":"service_role"}', true); end $$;
create function pg_temp.as_user(j jsonb) returns void language plpgsql as
$$ begin perform set_config('role', 'authenticated', true); perform set_config('request.jwt.claims', j::text, true); end $$;

-- ---------------------------------------------------------------- import a small prototype dataset
select pg_temp.as_service();
select pg_temp.ok((public.sr_platform_import_store('demo', 'Demo shop', '{
  "n": 50,
  "us": [
    {"id":1,"u":"admin","name":"Admin","pw":"1234","role":"admin","branch":"","active":1,"perms":{}},
    {"id":2,"u":"kasa1","name":"Ana","pw":"1234","role":"cashier","branch":"თბილისი","active":1,"perms":{"reg":1,"cmv":1,"rcv":1}},
    {"id":3,"u":"kasa2","name":"Dato","pw":"1234","role":"cashier","branch":"ბათუმი","active":1,"perms":{}}
  ],
  "p": [{"id":10,"code":"1001","name":"მაისური","price":25,"cost":15,"sz":1}],
  "c": [{"id":20,"name":"ნინო","phone":"555111222"}],
  "s": [{"id":30,"t":1763700000000,"b":"თბილისი","u":"kasa1","it":[{"pid":10,"z":"M","q":1,"pr":25,"cg":15}],"tot":25,"m":"ნაღდი"}],
  "st": {"თბილისი|10|M": 5, "ბათუმი|10|M": 3},
  "vat": {"on":0,"rate":18}
}'::jsonb, null, false))->'counts'->>'s' = '1', 'import counts');
reset role;

select pg_temp.ok((select count(*) from app.branches) = 2, 'branches derived from data');
select pg_temp.ok((select password_hash like '$2a$%' from app.app_users where username = 'admin'), 'passwords are bcrypt hashed');
select pg_temp.ok((select count(*) from app.sale_lines) = 1, 'sale lines extracted');
select pg_temp.ok((select id_counter from app.stores where slug = 'demo') = 51, 'id counter starts after the largest id');

-- ---------------------------------------------------------------- login
select pg_temp.as_service();
select pg_temp.ok((public.sr_login('demo', 'admin', 'wrong'))->>'error' = 'invalid_credentials', 'wrong password refused');
select pg_temp.ok((public.sr_login('nope', 'admin', '1234'))->>'error' = 'invalid_credentials', 'unknown shop gives the same error');
select pg_temp.ok((public.sr_login('DEMO', 'Admin', '1234'))->>'ok' = 'true', 'shop and username are case-insensitive');
create temp table s_admin as select public.sr_login('demo', 'admin', '1234') j;
create temp table s_cash as select public.sr_login('demo', 'kasa1', '1234') j;
create temp table s_cash2 as select public.sr_login('demo', 'kasa2', '1234') j;
reset role;
grant select on s_admin, s_cash, s_cash2 to authenticated;

create function pg_temp.claims(t text) returns jsonb language plpgsql as $$
declare j jsonb; begin execute format('select j from %I', t) into j;
  return jsonb_build_object('role','authenticated','sub',j->>'user_id','store_id',j->>'store_id','jti',j->>'jti'); end $$;
create temp table cl as select pg_temp.claims('s_admin') a, pg_temp.claims('s_cash') c, pg_temp.claims('s_cash2') c2;
grant select on cl to authenticated;

-- no token, anon cannot reach anything
set local role anon;
select pg_temp.ok(pg_temp.err('select public.sr_pull(array[''p''])') like '%permission denied%', 'anon cannot call the API');
select pg_temp.ok(pg_temp.err('select public.sr_login(''demo'',''admin'',''1234'')') like '%permission denied%', 'anon cannot call sr_login directly');
reset role;

-- forged token with a random session id
create temp table st1 as select id from app.stores; grant select on st1 to authenticated;
select pg_temp.as_user(jsonb_build_object('role','authenticated','store_id',(select id from st1),'jti',gen_random_uuid()));
select pg_temp.ok(pg_temp.err('select public.sr_me()') = 'SESSION_EXPIRED', 'unknown session refused');
select pg_temp.ok(pg_temp.err('select app.user_doc(null::app.app_users)') like '%permission denied%', 'internal helpers are not callable');
reset role;

-- ---------------------------------------------------------------- admin pull
select pg_temp.as_user((select a from cl));
select pg_temp.ok((public.sr_me())->'user'->>'u' = 'admin', 'sr_me');
select pg_temp.ok(jsonb_array_length((public.sr_pull(array['us']))->'us'->'rows') = 3, 'admin sees staff');
select pg_temp.ok(not ((public.sr_pull(array['us']))->'us'->'rows'->0 ? 'pw'), 'no password in user rows');
select pg_temp.ok(((public.sr_pull(array['p']))->'p'->'rows'->0->>'cost') = '15', 'admin sees cost');
select pg_temp.ok(((public.sr_pull(array['st']))->'st'->'rows'->>'თბილისი|10|M') = '5', 'stock pulled');
select pg_temp.ok(((public.sr_pull(array['kv']))->'kv'->'rows'->'vat'->>'rate') = '18', 'settings pulled');
reset role;

-- ---------------------------------------------------------------- cashier
select pg_temp.as_user((select c from cl));
select pg_temp.ok(((public.sr_pull(array['p']))->'p'->'rows'->0) ? 'cost' = false, 'cashier never receives product cost');
select pg_temp.ok(((public.sr_pull(array['pu','ex','lg']))) = '{}'::jsonb, 'cashier cannot read purchases, expenses, log');
select pg_temp.ok((public.sr_alloc_ids(100)) = 51, 'id block allocated');

-- a sale: line cost is stamped by the server, stock is moved by delta
select pg_temp.ok((public.sr_push(jsonb_build_object(
  'up', jsonb_build_object('s', jsonb_build_array(jsonb_build_object('_k','11111111-1111-1111-1111-111111111111',
        'id',51,'t',1763710000000,'b','თბილისი','u','kasa1','tot',50,'m','ბარათი',
        'it', jsonb_build_array(jsonb_build_object('pid',10,'z','M','q',2,'pr',25,'cg',0))))),
  'st', jsonb_build_object('თბილისი|10|M', -2))))->'patched'->'s'->0->'it'->0->>'cg' = '15', 'server stamps cost of goods');
reset role;
select pg_temp.ok((select qty from app.stock_levels where skey = 'თბილისი|10|M') = 3, 'stock decreased by delta');
create temp table sale51 as select doc || jsonb_build_object('_k', id::text) d from app.sales where lid = 51;
grant select on sale51 to authenticated;
select pg_temp.as_user((select c from cl));

-- re-sending the same receipt is harmless (idempotent)
select pg_temp.ok((public.sr_push(jsonb_build_object('up', jsonb_build_object('s', jsonb_build_array(
  (select d from sale51))))))->>'ok' = 'true', 'identical re-send accepted');
reset role;
select pg_temp.ok((select count(*) from app.sales) = 2, 'no duplicate receipt');
select pg_temp.as_user((select c from cl));

-- receipts cannot be changed or removed
select pg_temp.ok(pg_temp.err($q$select public.sr_push('{"up":{"s":[{"_k":"11111111-1111-1111-1111-111111111111","id":51,"tot":1}]}}')$q$)
  like '%RECEIPTS_ARE_IMMUTABLE%', 'receipt edit refused');
select pg_temp.ok(pg_temp.err($q$select public.sr_push('{"rm":{"s":["11111111-1111-1111-1111-111111111111"]}}')$q$)
  like '%APPEND_ONLY%', 'receipt removal refused');

-- role and branch rules
select pg_temp.ok(pg_temp.err($q$select public.sr_push('{"up":{"p":[{"_k":"22222222-2222-2222-2222-222222222222","id":99,"code":"X","name":"x","price":1}]}}')$q$)
  like '%NO_PERMISSION p%', 'cashier cannot edit products');
select pg_temp.ok(pg_temp.err($q$select public.sr_push('{"st":{"ბათუმი|10|M":-1}}')$q$)
  like '%WRONG_BRANCH%', 'cashier cannot move stock of another branch');
select pg_temp.ok(pg_temp.err($q$select public.sr_push('{"up":{"s":[{"_k":"33333333-3333-3333-3333-333333333333","id":52,"b":"ბათუმი","u":"kasa1","it":[],"tot":0}]}}')$q$)
  like '%WRONG_BRANCH%', 'cashier cannot sell for another branch');
select pg_temp.ok(pg_temp.err($q$select public.sr_push('{"kv":{"vat":{"on":1}}}')$q$)
  like '%NO_PERMISSION setting vat%', 'cashier cannot change VAT settings');
select pg_temp.ok((public.sr_push('{"kv":{"fav":{"2":[10]}}}'))->>'ok' = 'true', 'cashier may save favourites');
select pg_temp.ok((public.sr_push('{"up":{"c":[{"_k":"44444444-4444-4444-4444-444444444444","id":53,"name":"ლევანი","phone":"599000000"}]}}'))->>'ok' = 'true',
  'cashier with "reg" registers a customer');
reset role;

-- the second cashier has no "reg" permission
select pg_temp.as_user((select c2 from cl));
select pg_temp.ok(pg_temp.err($q$select public.sr_push('{"up":{"c":[{"_k":"55555555-5555-5555-5555-555555555555","id":54,"name":"x"}]}}')$q$)
  like '%NO_PERMISSION reg%', 'customer registration needs permission');
reset role;

-- ---------------------------------------------------------------- admin manages staff
select pg_temp.as_user((select a from cl));
select pg_temp.ok((public.sr_push(jsonb_build_object('up', jsonb_build_object('us', jsonb_build_array(jsonb_build_object(
  '_k','66666666-6666-6666-6666-666666666666','id',60,'u','kasa3','name','New','pw','abcd','role','cashier','branch','თბილისი','active',1,'perms','{}'::jsonb))))))
  ->'users'->0->>'u' = 'kasa3', 'admin adds a user');
reset role;
select pg_temp.ok((select password_hash <> 'abcd' and must_change_password from app.app_users where username = 'kasa3'), 'new user password hashed and must be changed');
create temp table ids as select (select id from app.app_users where username = 'admin') admin_id,
  (select app.user_doc(u) || '{"active":0}' from app.app_users u where username = 'kasa2') kasa2_off;
grant select on ids to authenticated;
select pg_temp.as_user((select a from cl));
select pg_temp.ok(pg_temp.err(format($q$select public.sr_push('{"up":{"us":[{"_k":"%s","id":1,"u":"admin","role":"cashier","active":1}]}}')$q$,
  (select admin_id from ids))) like '%CANNOT_DEMOTE_SELF%', 'admin cannot demote themselves');
-- disabling a user ends their session immediately
select public.sr_push(jsonb_build_object('up', jsonb_build_object('us', jsonb_build_array((select kasa2_off from ids)))));
reset role;
select pg_temp.as_user((select c2 from cl));
select pg_temp.ok(pg_temp.err('select public.sr_me()') = 'SESSION_EXPIRED', 'disabled user is signed out');
reset role;

-- logout revokes the session
select pg_temp.as_user((select c from cl));
select public.sr_logout();
select pg_temp.ok(pg_temp.err('select public.sr_me()') = 'SESSION_EXPIRED', 'logout revokes the session');
reset role;

-- ---------------------------------------------------------------- tenant isolation
select pg_temp.as_service();
select public.sr_platform_import_store('other', 'Other shop', '{"us":[{"id":1,"u":"admin","pw":"9999","role":"admin","active":1}],
  "p":[{"id":10,"code":"1","name":"სხვა","price":1,"cost":1}]}'::jsonb, null, false);
create temp table s_other as select public.sr_login('other', 'admin', '9999') j;
reset role;
grant select on s_other to authenticated;
select pg_temp.as_user(pg_temp.claims('s_other'));
select pg_temp.ok(jsonb_array_length((public.sr_pull(array['p','s']))->'s'->'rows') = 0, 'other store sees none of demo''s receipts');
select pg_temp.ok(((public.sr_pull(array['p']))->'p'->'rows'->0->>'name') = 'სხვა', 'other store sees only its own products');
select pg_temp.ok(pg_temp.err($q$select public.sr_push('{"up":{"s":[{"_k":"11111111-1111-1111-1111-111111111111","id":51,"tot":0}]}}')$q$)
  like '%FORBIDDEN%', 'cannot overwrite another store''s record by key');
reset role;

-- token claims for the wrong store are refused even with a valid session id
create temp table st2 as select id from app.stores where slug='other'; grant select on st2 to authenticated;
select pg_temp.as_user(jsonb_build_object('role','authenticated','store_id',(select id from st2),
  'jti', (select j->>'jti' from s_admin)));
select pg_temp.ok(pg_temp.err('select public.sr_me()') = 'SESSION_EXPIRED', 'session bound to its store');
reset role;

-- ---------------------------------------------------------------- brute force protection
select pg_temp.as_service();
select public.sr_login('demo', 'admin', 'x' || g) from generate_series(1, 5) g;
select pg_temp.ok((public.sr_login('demo', 'admin', '1234'))->>'error' = 'too_many_attempts', 'locked after 5 failures');
reset role;

select 'all auth/sync tests passed';
rollback;
