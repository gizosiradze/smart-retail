-- Smart Retail · final privilege lock-down
-- Internal helpers in schema "app" must never be callable from the API: some of them take a session
-- context as an argument and would let a caller act as anyone. Only the public.sr_* entry points
-- (which build that context themselves from the verified token) are exposed.

alter default privileges in schema app revoke execute on functions from public;
revoke execute on all functions in schema app from public, anon, authenticated;
grant execute on function app.storage_can_write(text) to authenticated;
grant execute on all functions in schema app to service_role;

-- No direct table access for API roles, even if someone later grants schema usage.
revoke all on all tables in schema app from public, anon, authenticated;
revoke all on all sequences in schema app from public, anon, authenticated;

-- Exposed API (public schema): keep the explicit list in one place.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'sr\_%' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname in ('sr_login', 'sr_platform_add_admin') then
      execute format('revoke execute on function %s from authenticated', f.sig);
      execute format('grant execute on function %s to service_role', f.sig);
    else
      execute format('grant execute on function %s to authenticated, service_role', f.sig);
    end if;
  end loop;
end $$;
