-- Smart Retail · customer data requests (GDPR / personal data law)
--   sr_customer_export(lid)  everything stored about one customer, as JSON (store admin only)
--   sr_customer_erase(lid)   removes the personal data of one customer (store admin only)
-- Erasing keeps the customer's number, so receipts and loyalty history stay consistent (receipts are
-- immutable and carry only that number); name, personal ID, phone, pet data and free-text notes are gone.
-- Every request is written to app.privacy_log (no personal data in it).

create table app.privacy_log (
  id bigserial primary key,
  store_id uuid not null references app.stores,
  at timestamptz not null default now(),
  action text not null check (action in ('export', 'erase')),
  customer_lid bigint not null,
  by_user uuid
);
create index on app.privacy_log (store_id, at desc);
alter table app.privacy_log enable row level security;   -- no policies: only the functions below touch it

create function public.sr_customer_export(p_lid bigint) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx(); c app.customers%rowtype; out jsonb;
begin
  if x.role <> 'admin' then raise exception 'FORBIDDEN'; end if;
  select * into c from app.customers where store_id = x.store_id and lid = p_lid and removed_at is null;
  if not found then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  out := jsonb_build_object(
    'exported_at', now(),
    'customer', c.doc,
    'receipts', coalesce((select jsonb_agg(s.doc order by s.sold_at) from app.sales s
                           where s.store_id = x.store_id and s.customer_lid = p_lid and s.removed_at is null), '[]'::jsonb),
    'points_adjustments', coalesce((select jsonb_agg(a.doc order by a.created_at) from app.points_adjustments a
                           where a.store_id = x.store_id and a.removed_at is null
                             and app.to_big(a.doc->>'c') = p_lid), '[]'::jsonb));
  insert into app.privacy_log (store_id, action, customer_lid, by_user) values (x.store_id, 'export', p_lid, x.user_id);
  return out;
end $$;

create function public.sr_customer_erase(p_lid bigint) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t := app.ctx(); c app.customers%rowtype;
begin
  if app.read_only() then raise exception 'READ_ONLY' using errcode = '42501'; end if;
  if x.role <> 'admin' then raise exception 'FORBIDDEN'; end if;
  select * into c from app.customers where store_id = x.store_id and lid = p_lid and removed_at is null for update;
  if not found then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  -- keep only what is not personal: the number, when/where registered, and a marker
  update app.customers
     set doc = jsonb_strip_nulls(jsonb_build_object(
           'id', doc->'id', 'name', 'წაშლილი მომხმარებელი', 'last', '', 'del', (extract(epoch from now()) * 1000)::bigint,
           'created', doc->'created', 'rb', doc->'rb')),
         updated_by = x.user_id
   where id = c.id;
  -- free-text notes of point corrections can contain names
  update app.points_adjustments
     set doc = doc - 'note', updated_by = x.user_id
   where store_id = x.store_id and removed_at is null and app.to_big(doc->>'c') = p_lid and doc ? 'note';
  insert into app.privacy_log (store_id, action, customer_lid, by_user) values (x.store_id, 'erase', p_lid, x.user_id);
end $$;

revoke all on app.privacy_log from public, anon, authenticated;
revoke execute on function public.sr_customer_export(bigint), public.sr_customer_erase(bigint) from public, anon;
grant execute on function public.sr_customer_export(bigint), public.sr_customer_erase(bigint) to authenticated, service_role;
