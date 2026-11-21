-- The local demo seed imports cleanly and keeps the prototype's numbers.
begin;
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if c is not true then raise exception 'FAILED: %', msg; end if; end $$;
\ir ../seed.sql
select pg_temp.ok((select count(*) from app.sales s join app.stores st on st.id = s.store_id where st.slug = 'demo') = 168, 'all demo receipts imported');
select pg_temp.ok((select count(*) from app.app_users u join app.stores st on st.id = u.store_id where st.slug = 'demo') = 4, 'demo staff');
select pg_temp.ok((select count(*) from app.branches b join app.stores st on st.id = b.store_id where st.slug = 'demo') = 2, 'two branches');
select pg_temp.ok((select round(sum(total), 2) from app.sales) = 25292.6, 'receipt totals unchanged by the import');
rollback;
