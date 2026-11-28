-- Customer data requests: export and erase are store-admin only, erase keeps receipts intact.
begin;
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if c is not true then raise exception 'FAILED: %', msg; end if; end $$;
create function pg_temp.err(q text) returns text language plpgsql as
$$ begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.as_service() returns void language plpgsql as
$$ begin perform set_config('role', 'service_role', true); perform set_config('request.jwt.claims', '{"role":"service_role"}', true); end $$;

select pg_temp.as_service();
select public.sr_platform_import_store('priv', 'Privacy shop', '{
  "n": 100,
  "us": [
    {"id":1,"u":"admin","name":"Admin","pw":"1234","role":"admin","branch":"","active":1,"perms":{}},
    {"id":2,"u":"kasa1","name":"Ana","pw":"1234","role":"cashier","branch":"თბილისი","active":1,"perms":{"reg":1}}
  ],
  "p": [{"id":10,"code":"1001","name":"მაისური","price":25,"cost":15,"sz":1}],
  "c": [{"id":20,"name":"ნინო","last":"ბერიძე","pid":"01234567890","phone":"555111222","pet":"ძაღლი","breed":"ლაბრადორი","kg":"30","created":1763000000000,"rb":"თბილისი"},
        {"id":21,"name":"გიო","last":"კაპანაძე","pid":"09876543210","phone":"555333444"}],
  "s": [{"id":30,"t":1763700000000,"b":"თბილისი","u":"kasa1","c":20,"it":[{"pid":10,"z":"M","q":1,"pr":25,"cg":15}],"tot":25,"m":"ნაღდი"}],
  "padj": [{"id":40,"c":20,"n":50,"t":1763800000000,"note":"ბონუსი ნინოსთვის"}],
  "st": {"თბილისი|10|M": 5},
  "vat": {"on":0,"rate":18}
}'::jsonb, null, false);
create temp table s_admin as select public.sr_login('priv', 'admin', '1234') j;
create temp table s_cash as select public.sr_login('priv', 'kasa1', '1234') j;
reset role;
grant select on s_admin, s_cash to authenticated;

create function pg_temp.as_session(t text) returns void language plpgsql as $$
declare j jsonb; begin execute format('select j from %I', t) into j;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object('role','authenticated','sub',j->>'user_id','store_id',j->>'store_id','jti',j->>'jti')::text, true); end $$;

-- a cashier may not export or erase
select pg_temp.as_session('s_cash');
select pg_temp.ok(pg_temp.err('select public.sr_customer_export(20)') = 'FORBIDDEN', 'cashier cannot export');
select pg_temp.ok(pg_temp.err('select public.sr_customer_erase(20)') = 'FORBIDDEN', 'cashier cannot erase');
reset role;

-- admin export
select pg_temp.as_session('s_admin');
create temp table ex as select public.sr_customer_export(20) j;
reset role;
select pg_temp.ok((select j->'customer'->>'phone' = '555111222' and j->'customer'->>'pid' = '01234567890' from ex), 'export has the customer');
select pg_temp.ok((select jsonb_array_length(j->'receipts') = 1 from ex), 'export has the receipts');
select pg_temp.ok((select jsonb_array_length(j->'points_adjustments') = 1 from ex), 'export has the point corrections');
select pg_temp.ok((select count(*) from app.privacy_log where action = 'export' and customer_lid = 20) = 1, 'export is logged');

select pg_temp.as_session('s_admin');
select pg_temp.ok(pg_temp.err('select public.sr_customer_export(999)') = 'CUSTOMER_NOT_FOUND', 'unknown customer');
select public.sr_customer_erase(20);
reset role;

select pg_temp.ok((select doc->>'name' = 'წაშლილი მომხმარებელი' and not (doc ? 'phone') and not (doc ? 'pid') and not (doc ? 'pet') and not (doc ? 'breed') and not (doc ? 'kg') and doc->>'last' = '' from app.customers where lid = 20), 'personal fields removed');
select pg_temp.ok((select (doc->>'id')::int = 20 and doc ? 'del' and doc->>'rb' = 'თბილისი' from app.customers where lid = 20), 'number and marker kept');
select pg_temp.ok((select count(*) from app.sales where customer_lid = 20) = 1, 'receipt untouched');
select pg_temp.ok((select not (doc ? 'note') and (doc->>'n')::int = 50 from app.points_adjustments where app.to_big(doc->>'c') = 20), 'note removed, points kept');
select pg_temp.ok((select phone is null and name = 'წაშლილი მომხმარებელი' from app.customers where lid = 20), 'typed columns follow');
select pg_temp.ok((select doc->>'phone' = '555333444' from app.customers where lid = 21), 'other customers untouched');
select pg_temp.ok((select count(*) from app.privacy_log where action = 'erase' and customer_lid = 20) = 1, 'erase is logged');

rollback;
