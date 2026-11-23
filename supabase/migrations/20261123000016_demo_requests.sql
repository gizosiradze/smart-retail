-- Smart Retail · demo requests from the public home page
-- The two forms on the home page call public.sr_demo_request (anonymous, rate limited). Super Admin reads
-- the list and marks requests as handled (public.sr_platform_demo_*).

create table app.demo_requests (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text not null,
  phone text not null,
  kind text not null default '',
  branches text not null default '',
  comment text not null default '',
  status text not null default 'new' check (status in ('new', 'done')),
  note text not null default '',
  handled_at timestamptz
);
create index on app.demo_requests (created_at desc);
alter table app.demo_requests enable row level security;   -- no policies: only the functions below touch it

-- Anonymous entry point. Never reveals anything; limits: 5 per phone per day, 60 in total per hour.
create function public.sr_demo_request(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  n text := left(btrim(coalesce(p->>'name', '')), 100);
  ph text := regexp_replace(coalesce(p->>'phone', ''), '\D', '', 'g');
begin
  if n = '' then raise exception 'NAME_REQUIRED'; end if;
  if length(ph) < 9 or length(ph) > 15 then raise exception 'PHONE_INVALID'; end if;
  if (select count(*) from app.demo_requests where phone = ph and created_at > now() - interval '1 day') >= 5
     or (select count(*) from app.demo_requests where created_at > now() - interval '1 hour') >= 60 then
    raise exception 'TOO_MANY_REQUESTS';
  end if;
  insert into app.demo_requests (name, phone, kind, branches, comment)
  values (n, ph, left(btrim(coalesce(p->>'kind', '')), 60), left(btrim(coalesce(p->>'branches', '')), 20),
          left(btrim(coalesce(p->>'comment', '')), 1000));
  return jsonb_build_object('ok', true);
end $$;

create function public.sr_platform_demo_list() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', r.id, 't', to_char(r.created_at at time zone 'Asia/Tbilisi', 'YYYY-MM-DD HH24:MI'),
      'name', r.name, 'phone', r.phone, 'kind', r.kind, 'branches', r.branches, 'comment', r.comment,
      'status', r.status, 'note', r.note) order by r.created_at desc)
    from (select * from app.demo_requests order by created_at desc limit 500) r), '[]');
end $$;

create function public.sr_platform_demo_set(p_id uuid, p_status text, p_note text) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  if p_status not in ('new', 'done') then raise exception 'BAD_STATUS'; end if;
  update app.demo_requests set status = p_status, note = left(coalesce(p_note, ''), 1000),
         handled_at = case when p_status = 'done' then coalesce(handled_at, now()) else null end
   where id = p_id;
end $$;

create function public.sr_platform_demo_delete(p_id uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  delete from app.demo_requests where id = p_id;
end $$;

-- grants (same rules as 20261121000006_lockdown.sql, which has already run)
revoke all on app.demo_requests from public, anon, authenticated;
revoke execute on function public.sr_demo_request(jsonb), public.sr_platform_demo_list(),
  public.sr_platform_demo_set(uuid, text, text), public.sr_platform_demo_delete(uuid) from public, anon;
grant execute on function public.sr_demo_request(jsonb) to anon, authenticated, service_role;
grant execute on function public.sr_platform_demo_list(), public.sr_platform_demo_set(uuid, text, text),
  public.sr_platform_demo_delete(uuid) to authenticated, service_role;
