-- The migration lifts a store's id counter above the old trn/exn counters, and never lowers it.
begin;
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if c is not true then raise exception 'FAILED: %', msg; end if; end $$;

insert into app.stores (id, slug, name, id_counter) values
  ('dddddddd-0000-0000-0000-000000000001', 'cnt-low', 'low counter', 1000),
  ('dddddddd-0000-0000-0000-000000000002', 'cnt-high', 'high counter', 90000),
  ('dddddddd-0000-0000-0000-000000000003', 'cnt-none', 'no old counters', 1500);
insert into app.kv (store_id, key, value) values
  ('dddddddd-0000-0000-0000-000000000001', 'trn', '2500'),
  ('dddddddd-0000-0000-0000-000000000001', 'exn', '40'),
  ('dddddddd-0000-0000-0000-000000000002', 'trn', '12');

\i supabase/migrations/20261128000020_counters_to_id_blocks.sql

select pg_temp.ok((select id_counter from app.stores where slug = 'cnt-low') = 3500, 'lifted above the largest old counter + 1000');
select pg_temp.ok((select id_counter from app.stores where slug = 'cnt-high') = 90000, 'a higher counter is never lowered');
select pg_temp.ok((select id_counter from app.stores where slug = 'cnt-none') = 1500, 'a store without old counters is unchanged');
rollback;
