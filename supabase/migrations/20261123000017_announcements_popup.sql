-- Smart Retail · Super Admin announcements reach the store admins as a pop-up
-- Super Admin writes announcements into app.platform_records (coll = 'ann'); the doc is
--   {id, t:'YYYY-MM-DD HH:MM' (Tbilisi), type, target:'all' | <store uuid>, text}
-- public.sr_announcements() returns the ones this admin has not confirmed yet; public.sr_announcements_read()
-- records the confirmation (per person, so every admin of the store sees it once).
-- Only store admins get them. Cashiers and warehouse staff never see them. The Super Admin's read-only view of a
-- store neither shows nor confirms them.

create table app.announcement_reads (
  user_id uuid not null references app.app_users on delete cascade,
  ann_id text not null,
  read_at timestamptz not null default now(),
  primary key (user_id, ann_id)
);
alter table app.announcement_reads enable row level security;   -- no policies: only the functions below touch it

-- When the announcement was sent, as a point in time. Unparsable text counts as "now" so it is never hidden.
create function app.ann_time(d jsonb) returns timestamptz language sql immutable set search_path = '' as $$
  select case when d->>'t' ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$'
              then ((d->>'t')::timestamp at time zone 'Asia/Tbilisi') else now() end
$$;

create function public.sr_announcements() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx();
begin
  if x.role <> 'admin' or app.read_only() then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 't', r.doc->>'t', 'type', coalesce(r.doc->>'type', ''),
                                        'text', coalesce(r.doc->>'text', '')) order by app.ann_time(r.doc), r.id)
      from app.platform_records r
     where r.coll = 'ann'
       and (r.doc->>'target' = 'all' or r.doc->>'target' = x.store_id::text)
       and btrim(coalesce(r.doc->>'text', '')) <> ''
       and app.ann_time(r.doc) > now() - interval '30 days'                                 -- old news is not a pop-up
       and app.ann_time(r.doc) >= (select u.created_at from app.app_users u where u.id = x.user_id) - interval '1 day'
       and not exists (select 1 from app.announcement_reads a where a.user_id = x.user_id and a.ann_id = r.id)
  ), '[]'::jsonb);
end $$;

create function public.sr_announcements_read(p_ids text[]) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx();
begin
  if app.read_only() then raise exception 'READ_ONLY' using errcode = '42501'; end if;
  if x.role <> 'admin' then return; end if;
  insert into app.announcement_reads (user_id, ann_id)
  select x.user_id, r.id from app.platform_records r
   where r.coll = 'ann' and r.id = any (p_ids)
     and (r.doc->>'target' = 'all' or r.doc->>'target' = x.store_id::text)         -- only what this store could have seen
  on conflict do nothing;
  -- forget confirmations of announcements Super Admin has deleted
  delete from app.announcement_reads a
   where a.user_id = x.user_id and not exists (select 1 from app.platform_records r where r.coll = 'ann' and r.id = a.ann_id);
end $$;

revoke all on app.announcement_reads from public, anon, authenticated;
revoke execute on function public.sr_announcements(), public.sr_announcements_read(text[]) from public, anon;
grant execute on function public.sr_announcements(), public.sr_announcements_read(text[]) to authenticated, service_role;
