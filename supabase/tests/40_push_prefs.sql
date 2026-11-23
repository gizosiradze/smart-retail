-- Notification preferences: who wants which event, and that the triggers raise the right events.
-- Runs inside one transaction and rolls back. pg_net is replaced by a stub that records the calls.
begin;

create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if c is not true then raise exception 'FAILED: %', msg; end if; end $$;

create schema if not exists net;
create table net.calls (n serial, body jsonb);
create or replace function net.http_post(url text, headers jsonb, body jsonb, timeout_milliseconds int default 1000) returns bigint
language plpgsql as $$ begin insert into net.calls (body) values (body); return 1; end $$;

select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.sr_platform_import_store('pp', 'Push shop', '{"n":50,"us":[{"id":1,"u":"admin","name":"Admin","pw":"1234","role":"admin","branch":"","active":1,"perms":{}}],
  "p":[{"id":10,"code":"1001","name":"მაისური","price":25,"cost":15,"sz":1}],"st":{"თბილისი|10|M":5,"ბათუმი|10|M":3}}'::jsonb, null, false);
reset role;

insert into app.push_config (id, url, secret, vapid_public) values (true, 'https://x.test/push', 's', 'k');
create temp table ctx as select id as store_id, (select id from app.app_users where username = 'admin') as uid from app.stores where slug = 'pp';
insert into app.push_subs (store_id, user_id, endpoint, p256dh, auth, prefs)
select store_id, uid, 'https://push.test/a', 'p', 'a', '{}' from ctx;              -- no saved choices
insert into app.push_subs (store_id, user_id, endpoint, p256dh, auth, prefs)
select store_id, uid, 'https://push.test/b', 'p', 'a',
  app.push_clean('{"ev":{"sale":0,"ret":0,"big":1,"shd":1,"trr":1,"low":1,"cm":1},"bigN":100,"lowN":3,"br":["ბათუმი"]}') from ctx;

-- ---------------------------------------------------------------- who wants what
create function pg_temp.who(kinds text[], br text, amt numeric, prev numeric) returns text language sql as
$$ select coalesce(string_agg(substr(e->>'endpoint', 19), ',' order by e->>'endpoint'), '')
     from jsonb_array_elements(public.sr_push_targets((select store_id from ctx), kinds, br, amt, prev)) e $$;

select pg_temp.ok(pg_temp.who(array['sale','big'], 'თბილისი', 50, null) = 'a', 'default device gets sales; b is limited to Batumi and wants only big sales');
select pg_temp.ok(pg_temp.who(array['sale','big'], 'ბათუმი', 50, null) = 'a', 'a sale below the big-sale limit does not reach b');
select pg_temp.ok(pg_temp.who(array['sale','big'], 'ბათუმი', 100, null) = 'a,b', 'a sale at the limit reaches b');
select pg_temp.ok(pg_temp.who(array['sale','big'], 'თბილისი', 500, null) = 'a', 'branch filter: b ignores Tbilisi');
select pg_temp.ok(pg_temp.who(array['ret'], 'ბათუმი', 10, null) = 'a', 'returns: default on, b turned them off');
select pg_temp.ok(pg_temp.who(array['sho'], 'ბათუმი', null, null) = '', 'shift opened: off by default');
select pg_temp.ok(pg_temp.who(array['shd','shc'], 'ბათუმი', null, null) = 'b', 'a difference reaches b through shd');
select pg_temp.ok(pg_temp.who(array['low'], 'ბათუმი', 3, 4) = 'b', 'low stock: crossing the limit (4 -> 3)');
select pg_temp.ok(pg_temp.who(array['low'], 'ბათუმი', 2, 3) = '', 'low stock: already below the limit, no repeat');
select pg_temp.ok(pg_temp.who(array['low'], 'ბათუმი', 5, 8) = '', 'low stock: still above the limit');
select pg_temp.ok(app.push_clean('{"ev":{"sale":"true","x":1},"bigN":-5,"lowN":"abc","br":"nope"}')
  = '{"ev":{"big":0,"cm":0,"low":0,"pu":0,"ret":0,"sale":1,"shc":0,"shd":0,"sho":0,"trd":0,"trr":0,"trs":0},"bigN":0,"lowN":2,"br":[]}'::jsonb, 'preferences are sanitised');

-- ---------------------------------------------------------------- the triggers
delete from net.calls;
insert into app.sales (id, store_id, doc)
select gen_random_uuid(), store_id, jsonb_build_object('id', 901, 'b', 'ბათუმი', 'u', 'kasa2', 'm', 'ბარათი', 'tot', 120,
  't', (extract(epoch from now()) * 1000)::bigint) from ctx;
select pg_temp.ok((select body->'kinds' = '["sale","big"]'::jsonb and body->>'branch' = 'ბათუმი' and (body->>'amount')::numeric = 120 from net.calls order by n desc limit 1), 'sale event');
insert into app.sales (id, store_id, doc)
select gen_random_uuid(), store_id, jsonb_build_object('id', 902, 'b', 'ბათუმი', 'u', 'kasa2', 'm', 'ნაღდი', 'tot', -30, 'ret', 901,
  't', (extract(epoch from now()) * 1000)::bigint) from ctx;
select pg_temp.ok((select body->'kinds' = '["ret"]'::jsonb from net.calls order by n desc limit 1), 'return event');
select pg_temp.ok((select count(*) from net.calls) = 2, 'one event per sale');
insert into app.sales (id, store_id, doc)
select gen_random_uuid(), store_id, jsonb_build_object('id', 903, 'b', 'ბათუმი', 'tot', 10, 't', 1600000000000) from ctx;
select pg_temp.ok((select count(*) from net.calls) = 2, 'an old receipt arriving late is not news');

delete from net.calls;
insert into app.shifts (id, store_id, doc)
select '00000000-0000-0000-0000-0000000000a1', store_id, jsonb_build_object('id', 's1', 'b', 'ბათუმი', 'ou', 'kasa2', 'oc', 50, 'st', 'open',
  'ot', (extract(epoch from now()) * 1000)::bigint) from ctx;
select pg_temp.ok((select body->'kinds' = '["sho"]'::jsonb from net.calls order by n desc limit 1), 'shift opened');
update app.shifts set doc = doc || '{"note":"x"}' where id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.ok((select count(*) from net.calls) = 1, 'an edit of an open shift is silent');
update app.shifts set doc = doc || jsonb_build_object('st', 'closed', 'cu', 'kasa2', 'res', jsonb_build_object('diff', -5),
  'ct', (extract(epoch from now()) * 1000)::bigint) where id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.ok((select body->'kinds' = '["shd","shc"]'::jsonb and body->>'body' like '%დანაკლისი 5.00 ₾%' from net.calls order by n desc limit 1), 'shift closed with a shortage');
update app.shifts set doc = doc || '{"note":"y"}' where id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.ok((select count(*) from net.calls) = 2, 'a closed shift notifies once');

delete from net.calls;
insert into app.transfers (id, store_id, doc)
select '00000000-0000-0000-0000-0000000000b1', store_id, jsonb_build_object('id', 7, 'f', 'თბილისი', 'to', 'ბათუმი', 'st', 'sent',
  'L', jsonb_build_array(jsonb_build_object('q', 4)), 'ts', (extract(epoch from now()) * 1000)::bigint) from ctx;
select pg_temp.ok((select body->'kinds' = '["trs"]'::jsonb from net.calls order by n desc limit 1), 'transfer sent');
update app.transfers set doc = doc || jsonb_build_object('st', 'recv', 'L', jsonb_build_array(jsonb_build_object('q', 4, 'r', 3)),
  'tr', (extract(epoch from now()) * 1000)::bigint) where id = '00000000-0000-0000-0000-0000000000b1';
select pg_temp.ok((select body->'kinds' = '["trd","trr"]'::jsonb and body->>'branch' = 'ბათუმი' from net.calls order by n desc limit 1), 'transfer received with a shortage');

delete from net.calls;
insert into app.cash_movements (id, store_id, doc)
select gen_random_uuid(), store_id, jsonb_build_object('id', 'c1', 'sh', 's1', 'k', 'out', 'a', 20, 'why', 'ტაქსი', 'u', 'kasa2',
  't', (extract(epoch from now()) * 1000)::bigint) from ctx;
select pg_temp.ok((select body->'kinds' = '["cm"]'::jsonb and body->>'branch' = 'ბათუმი' from net.calls order by n desc limit 1), 'cash taken out, branch from the shift');

delete from net.calls;
update app.stock_levels set qty = 9 where skey = 'ბათუმი|10|M' and store_id = (select store_id from ctx);
select pg_temp.ok((select count(*) from net.calls) = 0, 'raising stock is silent');
update app.stock_levels set qty = 3 where skey = 'ბათუმი|10|M' and store_id = (select store_id from ctx);
select pg_temp.ok((select body->'kinds' = '["low"]'::jsonb and body->>'body' like 'მაისური (M) · დარჩა 3%' and (body->>'prev')::numeric = 9 from net.calls order by n desc limit 1), 'low stock event with product name');

rollback;
