-- Error log + health: anonymous reporting with dedupe and limits, Super Admin read/handle/delete only.
begin;
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if c is not true then raise exception 'FAILED: %', msg; end if; end $$;
create function pg_temp.err(q text) returns text language plpgsql as
$$ begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.as_user(j jsonb) returns void language plpgsql as
$$ begin perform set_config('role', 'authenticated', true); perform set_config('request.jwt.claims', j::text, true); end $$;

insert into auth.users (id, email) values ('cccccccc-0000-0000-0000-000000000001', 'owner@example.com'),
                                          ('cccccccc-0000-0000-0000-000000000002', 'stranger@example.com');
insert into app.platform_admins (user_id, email) values ('cccccccc-0000-0000-0000-000000000001', 'owner@example.com');

select set_config('role', 'anon', true), set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.ok((public.sr_health())->>'ok' = 'true', 'health answers for anon');
select public.sr_report_error('{"source":"app","message":"x is not a function","stack":"TypeError\n at a (app.js:1)","path":"/app/?token=SECRET#x","ua":"test"}');
select public.sr_report_error('{"source":"app","message":"x is not a function","stack":"TypeError\n at a (app.js:1)","path":"/app/","ua":"test"}');
select public.sr_report_error('{"source":"bogus","message":"other"}');
select pg_temp.ok((public.sr_report_error('{"message":""}'))->>'ok' = 'true', 'empty message is ignored quietly');
select pg_temp.ok(pg_temp.err($$select count(*) from app.client_errors$$) <> '', 'anon cannot read the table');
select pg_temp.ok(pg_temp.err($$select public.sr_platform_errors_list()$$) <> '', 'anon cannot read the list');
reset role;
select pg_temp.ok((select count(*) from app.client_errors) = 2, 'same error is one row');
select pg_temp.ok((select cnt from app.client_errors where message = 'x is not a function') = 2, 'repeat is counted');
select pg_temp.ok((select path from app.client_errors where message = 'x is not a function') = '/app/', 'query string and hash are dropped');
select pg_temp.ok((select source from app.client_errors where message = 'other') = 'app', 'unknown source falls back to app');

-- flood: new kinds are capped at 100 per hour
select set_config('role', 'anon', true), set_config('request.jwt.claims', '{"role":"anon"}', true);
select public.sr_report_error(jsonb_build_object('message', 'flood ' || g)) from generate_series(1, 150) g;
reset role;
select pg_temp.ok((select count(*) from app.client_errors) <= 100, 'hourly cap on new error kinds');

select pg_temp.as_user('{"role":"authenticated","sub":"cccccccc-0000-0000-0000-000000000002","aal":"aal2"}');
select pg_temp.ok(pg_temp.err($$select public.sr_platform_errors_list()$$) = 'PLATFORM_ADMIN_REQUIRED', 'non-admin refused');
reset role;

create temp table first_err as select id from app.client_errors where message = 'x is not a function';
grant select on first_err to authenticated;
select pg_temp.as_user('{"role":"authenticated","sub":"cccccccc-0000-0000-0000-000000000001","aal":"aal2"}');
select pg_temp.ok(jsonb_array_length(public.sr_platform_errors_list()) > 0, 'admin sees the errors');
select public.sr_platform_error_set((select id from first_err), 'done');
select pg_temp.ok((select x->>'status' = 'done' from jsonb_array_elements(public.sr_platform_errors_list()) x where x->>'id' = (select id::text from first_err)), 'marked handled');
select pg_temp.ok(pg_temp.err($$select public.sr_platform_error_set(gen_random_uuid(), 'x')$$) = 'BAD_STATUS', 'bad status refused');
select public.sr_platform_error_delete(null);
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(public.sr_platform_errors_list()) x where x->>'status' = 'done'), 'handled ones deleted in bulk');
reset role;

-- a handled error that happens again is opened again
select set_config('role', 'anon', true), set_config('request.jwt.claims', '{"role":"anon"}', true);
select public.sr_report_error('{"source":"app","message":"again"}');
reset role;
update app.client_errors set status = 'done' where message = 'again';
select set_config('role', 'anon', true), set_config('request.jwt.claims', '{"role":"anon"}', true);
select public.sr_report_error('{"source":"app","message":"again"}');
reset role;
select pg_temp.ok((select status = 'new' and cnt = 2 from app.client_errors where message = 'again'), 'recurring error reopens');
rollback;
