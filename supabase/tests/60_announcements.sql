-- Announcements: who gets the pop-up, once per person, never in the Super Admin's read-only view.
-- Runs inside one transaction and rolls back.
begin;

create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if c is not true then raise exception 'FAILED: %', msg; end if; end $$;
create function pg_temp.err(q text) returns text language plpgsql as
$$ begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.as_service() returns void language plpgsql as
$$ begin perform set_config('role', 'service_role', true); perform set_config('request.jwt.claims', '{"role":"service_role"}', true); end $$;
create function pg_temp.as_user(j jsonb) returns void language plpgsql as
$$ begin perform set_config('role', 'authenticated', true); perform set_config('request.jwt.claims', j::text, true); end $$;

select pg_temp.as_service();
select public.sr_platform_import_store('an1', 'Shop one', '{"n":50,"us":[
  {"id":1,"u":"admin","name":"A","pw":"1234","role":"admin","branch":"","active":1,"perms":{}},
  {"id":2,"u":"boss2","name":"B","pw":"1234","role":"admin","branch":"","active":1,"perms":{}},
  {"id":3,"u":"kasa","name":"C","pw":"1234","role":"cashier","branch":"","active":1,"perms":{}}]}'::jsonb, null, false);
select public.sr_platform_import_store('an2', 'Shop two', '{"n":50,"us":[
  {"id":1,"u":"admin","name":"A","pw":"1234","role":"admin","branch":"","active":1,"perms":{}}]}'::jsonb, null, false);
create temp table s_a1 as select public.sr_login('an1', 'admin', '1234') j;
create temp table s_a2 as select public.sr_login('an1', 'boss2', '1234') j;
create temp table s_c as select public.sr_login('an1', 'kasa', '1234') j;
create temp table s_b as select public.sr_login('an2', 'admin', '1234') j;
reset role;
grant select on s_a1, s_a2, s_c, s_b to authenticated;

create function pg_temp.claims(t text) returns jsonb language plpgsql as $$
declare j jsonb; begin execute format('select j from %I', t) into j;
  return jsonb_build_object('role','authenticated','sub',j->>'user_id','store_id',j->>'store_id','jti',j->>'jti'); end $$;
create temp table cl as select pg_temp.claims('s_a1') a1, pg_temp.claims('s_a2') a2, pg_temp.claims('s_c') c, pg_temp.claims('s_b') b;
grant select on cl to authenticated;
create temp table st as select id, slug::text slug from app.stores; grant select on st to authenticated;

-- Super Admin records (as the push function stores them): to everyone, to shop one, to shop two, empty, old
create temp table now_t as select to_char(now() at time zone 'Asia/Tbilisi', 'YYYY-MM-DD HH24:MI') n,
       to_char((now() - interval '60 days') at time zone 'Asia/Tbilisi', 'YYYY-MM-DD HH24:MI') old;
insert into app.platform_records (coll, id, doc)
select 'ann', 'all1', jsonb_build_object('id','all1','t',n,'type','ინფორმაცია','target','all','text','ყველას') from now_t union all
select 'ann', 'one1', jsonb_build_object('id','one1','t',n,'type','გაფრთხილება','target',(select id::text from st where slug='an1'),'text','პირველს') from now_t union all
select 'ann', 'two1', jsonb_build_object('id','two1','t',n,'type','ინფორმაცია','target',(select id::text from st where slug='an2'),'text','მეორეს') from now_t union all
select 'ann', 'emp1', jsonb_build_object('id','emp1','t',n,'type','ინფორმაცია','target','all','text','   ') from now_t union all
select 'ann', 'old1', jsonb_build_object('id','old1','t',old,'type','ინფორმაცია','target','all','text','ძველი') from now_t;

create function pg_temp.ids() returns text language sql as
$$ select coalesce(string_agg(e->>'id', ',' order by e->>'id'), '') from jsonb_array_elements(public.sr_announcements()) e $$;

-- admin of shop one: the one for everyone and the one for this shop (not shop two's, not blank, not 60 days old)
select pg_temp.as_user((select a1 from cl));
select pg_temp.ok(pg_temp.ids() = 'all1,one1', 'admin sees own and global announcements: ' || pg_temp.ids());
select pg_temp.ok((public.sr_announcements())->0->>'text' is not null, 'text is returned');
reset role;

-- confirming hides it for this admin only
select pg_temp.as_user((select a1 from cl));
select public.sr_announcements_read(array['all1']);
select pg_temp.ok(pg_temp.ids() = 'one1', 'confirmed one disappears');
select public.sr_announcements_read(array['all1']);                       -- twice is harmless
select public.sr_announcements_read(array['two1']);                       -- another shop's: ignored
reset role;
select pg_temp.ok((select count(*) from app.announcement_reads) = 1, 'only what the shop could see is stored');
select pg_temp.as_user((select a2 from cl));
select pg_temp.ok(pg_temp.ids() = 'all1,one1', 'a second admin of the shop still sees it');
reset role;

-- another shop
select pg_temp.as_user((select b from cl));
select pg_temp.ok(pg_temp.ids() = 'all1,two1', 'shop two sees its own and the global one');
reset role;

-- cashier gets nothing and confirms nothing
select pg_temp.as_user((select c from cl));
select pg_temp.ok(pg_temp.ids() = '', 'cashier sees no announcements');
select public.sr_announcements_read(array['one1']);
reset role;
select pg_temp.ok((select count(*) from app.announcement_reads) = 1, 'cashier cannot confirm');

-- anonymous and forged sessions
set local role anon;
select pg_temp.ok(pg_temp.err('select public.sr_announcements()') like '%permission denied%', 'anon refused');
reset role;
select pg_temp.as_user(jsonb_build_object('role','authenticated','store_id',(select id from st limit 1),'jti',gen_random_uuid()));
select pg_temp.ok(pg_temp.err('select public.sr_announcements()') = 'SESSION_EXPIRED', 'unknown session refused');
select pg_temp.ok(pg_temp.err('select count(*) from app.announcement_reads') like '%permission denied%', 'table is closed');
reset role;

-- Super Admin's read-only view of the store: nothing shown, nothing confirmed
update app.sessions set read_only = true where jti = (select (j->>'jti')::uuid from s_a2);
select pg_temp.as_user((select a2 from cl));
select pg_temp.ok(pg_temp.ids() = '', 'read-only view sees none');
select pg_temp.ok(pg_temp.err($$select public.sr_announcements_read(array['all1'])$$) = 'READ_ONLY', 'read-only view cannot confirm');
reset role;

-- deleting an announcement forgets its confirmations
delete from app.platform_records where coll = 'ann' and id = 'all1';
select pg_temp.as_user((select a1 from cl));
select public.sr_announcements_read(array['one1']);
reset role;
select pg_temp.ok((select count(*) from app.announcement_reads where ann_id = 'all1') = 0, 'stale confirmations removed');

rollback;
