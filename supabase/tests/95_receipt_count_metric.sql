-- Super Admin metrics include the receipt count per store.
begin;
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if c is not true then raise exception 'FAILED: %', msg; end if; end $$;
create function pg_temp.err(q text) returns text language plpgsql as
$$ begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.as_service() returns void language plpgsql as
$$ begin perform set_config('role', 'service_role', true); perform set_config('request.jwt.claims', '{"role":"service_role"}', true); end $$;
create function pg_temp.as_user(j jsonb) returns void language plpgsql as
$$ begin perform set_config('role', 'authenticated', true); perform set_config('request.jwt.claims', j::text, true); end $$;

insert into auth.users (id, email) values ('eeeeeeee-0000-0000-0000-000000000001', 'owner@example.com'),
                                          ('eeeeeeee-0000-0000-0000-000000000002', 'stranger@example.com');
insert into app.platform_admins (user_id, email) values ('eeeeeeee-0000-0000-0000-000000000001', 'owner@example.com');

select pg_temp.as_service();
select public.sr_platform_import_store('cntm', 'Count shop', '{
  "n": 100,
  "us": [{"id":1,"u":"admin","name":"Admin","pw":"1234","role":"admin","branch":"","active":1,"perms":{}}],
  "p": [{"id":10,"code":"1001","name":"მაისური","price":25,"cost":15,"sz":1}],
  "s": [{"id":30,"t":1763700000000,"b":"თბილისი","u":"admin","it":[{"pid":10,"z":"M","q":1,"pr":25,"cg":15}],"tot":25,"m":"ნაღდი"},
        {"id":31,"t":1763700100000,"b":"თბილისი","u":"admin","it":[{"pid":10,"z":"M","q":1,"pr":25,"cg":15}],"tot":25,"m":"ნაღდი"}],
  "st": {"თბილისი|10|M": 5}, "vat": {"on":0,"rate":18}
}'::jsonb, null, false);
reset role;

select pg_temp.as_user('{"role":"authenticated","sub":"eeeeeeee-0000-0000-0000-000000000002","aal":"aal2"}');
select pg_temp.ok(pg_temp.err($$select public.sr_platform_metrics()$$) = 'PLATFORM_ADMIN_REQUIRED', 'non-admin refused');
reset role;

select pg_temp.as_user('{"role":"authenticated","sub":"eeeeeeee-0000-0000-0000-000000000001","aal":"aal2"}');
create temp table m as select public.sr_platform_metrics() j;
reset role;
select pg_temp.ok((select (j->(select id::text from app.stores where slug = 'cntm')->>'receipts')::int = 2 from m), 'receipt count per store');
select pg_temp.ok((select j->(select id::text from app.stores where slug = 'cntm') ? 'days' from m), 'existing metrics are still there');
rollback;
