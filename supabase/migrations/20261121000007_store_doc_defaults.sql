-- Smart Retail · default Super Admin record for every store
-- Stores created by sr_platform_import_store (scripts/import-legacy.mjs, the demo shop) had an empty doc,
-- but the Super Admin screens need the billing fields (plan, feeHist, trialEnd, payDay, ...) and failed with
-- "Cannot read properties of undefined (reading '0')". Missing fields are now filled on insert; fields the
-- caller sends (sr_platform_register_store sends all of them) always win.

create function app.store_doc_defaults(p_doc jsonb, p_name text) returns jsonb
language sql stable set search_path = '' as $$
  with t as (select (now() at time zone 'Asia/Tbilisi')::date as d),
       pl as (select coalesce(p_doc->>'plan', 'std') as id)
  select jsonb_build_object(
    'plan', pl.id,
    'kind', '',
    'legal', coalesce(p_name, ''), 'idcode', '', 'address', '', 'owner', '', 'phone', '', 'email', '',
    'statusReason', '', 'notes', '',
    'created', to_char(t.d, 'YYYY-MM-DD'),
    'trialEnd', to_char(t.d, 'YYYY-MM-DD'),
    'payDay', 1,                                  -- first invoice: the 1st of next month
    'feeHist', jsonb_build_array(jsonb_build_object('from', to_char(t.d, 'YYYY-MM'),
                 'fee', coalesce((select (p.doc->>'price')::numeric from app.plans p where p.id = pl.id), 0)))
  ) || coalesce(p_doc, '{}')
  from t, pl
$$;

create function app.stores_fill_doc() returns trigger language plpgsql set search_path = '' as $$
begin
  new.doc := app.store_doc_defaults(new.doc, new.name);
  return new;
end $$;
create trigger fill_doc before insert on app.stores for each row execute function app.stores_fill_doc();

-- backfill stores imported before this migration
update app.stores set doc = app.store_doc_defaults(doc, name) where not (doc ? 'feeHist');

revoke execute on function app.store_doc_defaults(jsonb, text), app.stores_fill_doc() from public, anon, authenticated;
