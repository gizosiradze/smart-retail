-- Smart Retail · built-in error log + health check
-- The app, the Super Admin page and the home page report browser errors to public.sr_report_error
-- (anonymous, rate limited, no personal data: message, first stack lines, page path, browser).
-- The same error repeated is counted on one row instead of piling up. Super Admin reads and clears the list.
-- public.sr_health() is what the uptime check calls (through the Edge Function "health").

create table app.client_errors (
  id uuid primary key default gen_random_uuid(),
  fingerprint text not null unique,
  source text not null default 'app',
  message text not null,
  stack text not null default '',
  path text not null default '',
  ua text not null default '',
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  cnt integer not null default 1,
  status text not null default 'new' check (status in ('new', 'done'))
);
create index on app.client_errors (last_at desc);
alter table app.client_errors enable row level security;   -- no policies: only the functions below touch it

create function public.sr_report_error(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  src text := case when p->>'source' in ('app', 'superadmin', 'home') then p->>'source' else 'app' end;
  msg text := left(btrim(coalesce(p->>'message', '')), 500);
  stk text := left(coalesce(p->>'stack', ''), 1500);
  pth text := left(regexp_replace(coalesce(p->>'path', ''), '[?#].*$', ''), 200);
  fp text;
begin
  if msg = '' then return jsonb_build_object('ok', true); end if;
  fp := md5(src || '|' || msg || '|' || split_part(stk, E'\n', 2));
  update app.client_errors set cnt = cnt + 1, last_at = now(), status = 'new' where fingerprint = fp;
  if found then return jsonb_build_object('ok', true); end if;
  -- new kinds of error: at most 100 per hour overall, so a broken page cannot flood the table
  if (select count(*) from app.client_errors where first_at > now() - interval '1 hour') >= 100 then
    return jsonb_build_object('ok', true);
  end if;
  insert into app.client_errors (fingerprint, source, message, stack, path, ua)
  values (fp, src, msg, stk, pth, left(coalesce(p->>'ua', ''), 200))
  on conflict (fingerprint) do update set cnt = app.client_errors.cnt + 1, last_at = now();
  return jsonb_build_object('ok', true);
end $$;

create function public.sr_platform_errors_list() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', e.id, 'source', e.source, 'message', e.message, 'stack', e.stack, 'path', e.path, 'ua', e.ua,
      'first', to_char(e.first_at at time zone 'Asia/Tbilisi', 'YYYY-MM-DD HH24:MI'),
      'last', to_char(e.last_at at time zone 'Asia/Tbilisi', 'YYYY-MM-DD HH24:MI'),
      'cnt', e.cnt, 'status', e.status) order by e.last_at desc)
    from (select * from app.client_errors order by last_at desc limit 200) e), '[]'::jsonb);
end $$;

create function public.sr_platform_error_set(p_id uuid, p_status text) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  if p_status not in ('new', 'done') then raise exception 'BAD_STATUS'; end if;
  update app.client_errors set status = p_status where id = p_id;
end $$;

-- removes one error, or all handled ones when p_id is null
create function public.sr_platform_error_delete(p_id uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  if p_id is null then delete from app.client_errors where status = 'done';
  else delete from app.client_errors where id = p_id; end if;
end $$;

-- Health: touches the database, reveals nothing
create function public.sr_health() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'db', (select count(*) >= 0 from app.plans));
$$;

revoke all on app.client_errors from public, anon, authenticated;
revoke execute on function public.sr_report_error(jsonb), public.sr_platform_errors_list(),
  public.sr_platform_error_set(uuid, text), public.sr_platform_error_delete(uuid), public.sr_health() from public, anon;
grant execute on function public.sr_report_error(jsonb), public.sr_health() to anon, authenticated, service_role;
grant execute on function public.sr_platform_errors_list(), public.sr_platform_error_set(uuid, text),
  public.sr_platform_error_delete(uuid) to authenticated, service_role;
