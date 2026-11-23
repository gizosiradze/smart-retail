-- Demo requests from the home page: anonymous insert with limits, Super Admin read/handle/delete only.
begin;
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if c is not true then raise exception 'FAILED: %', msg; end if; end $$;
create function pg_temp.err(q text) returns text language plpgsql as
$$ begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.as_user(j jsonb) returns void language plpgsql as
$$ begin perform set_config('role', 'authenticated', true); perform set_config('request.jwt.claims', j::text, true); end $$;

insert into auth.users (id, email) values ('bbbbbbbb-0000-0000-0000-000000000001', 'owner@example.com'),
                                          ('bbbbbbbb-0000-0000-0000-000000000002', 'stranger@example.com');
insert into app.platform_admins (user_id, email) values ('bbbbbbbb-0000-0000-0000-000000000001', 'owner@example.com');

-- anonymous visitor
select set_config('role', 'anon', true), set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.ok((public.sr_demo_request('{"name":"გიო","phone":"555 12 34 56","kind":"ფეხსაცმელი","branches":"2–3","comment":"გამარჯობა"}'))->>'ok' = 'true', 'anon can request a demo');
select pg_temp.ok(pg_temp.err($$select public.sr_demo_request('{"name":"","phone":"555123456"}')$$) = 'NAME_REQUIRED', 'name required');
select pg_temp.ok(pg_temp.err($$select public.sr_demo_request('{"name":"x","phone":"12345"}')$$) = 'PHONE_INVALID', 'short phone refused');
select pg_temp.ok(pg_temp.err($$select public.sr_platform_demo_list()$$) <> '', 'anon cannot read the list');
select pg_temp.ok(pg_temp.err($$select count(*) from app.demo_requests$$) <> '', 'anon cannot read the table');
-- 5 per phone per day: 1 made above, 4 more fit, the next is refused
select public.sr_demo_request('{"name":"გიო","phone":"555123456"}') from generate_series(1, 4);
select pg_temp.ok(pg_temp.err($$select public.sr_demo_request('{"name":"გიო","phone":"555123456"}')$$) = 'TOO_MANY_REQUESTS', 'per-phone limit');
reset role;

-- signed-in user who is not a platform admin
select pg_temp.as_user('{"role":"authenticated","sub":"bbbbbbbb-0000-0000-0000-000000000002","aal":"aal2"}');
select pg_temp.ok(pg_temp.err($$select public.sr_platform_demo_list()$$) = 'PLATFORM_ADMIN_REQUIRED', 'non-admin refused');
reset role;

-- platform admin
create temp table first_req as select id from app.demo_requests order by created_at, id limit 1;
grant select on first_req to authenticated;
select pg_temp.as_user('{"role":"authenticated","sub":"bbbbbbbb-0000-0000-0000-000000000001","aal":"aal2"}');
select pg_temp.ok(jsonb_array_length(public.sr_platform_demo_list()) = 5, 'admin sees the requests');
select pg_temp.ok((public.sr_platform_demo_list())->0->>'status' = 'new', 'new by default');
select public.sr_platform_demo_set((select id from first_req), 'done', 'დავურეკე');
select pg_temp.ok((select (x->>'status') = 'done' and (x->>'note') = 'დავურეკე' from jsonb_array_elements(public.sr_platform_demo_list()) x where x->>'id' = (select id::text from first_req)), 'marked as handled');
select pg_temp.ok(pg_temp.err($$select public.sr_platform_demo_set(gen_random_uuid(), 'x', '')$$) = 'BAD_STATUS', 'bad status refused');
select public.sr_platform_demo_delete((select id from first_req));
select pg_temp.ok(jsonb_array_length(public.sr_platform_demo_list()) = 4, 'deleted');
reset role;
rollback;
