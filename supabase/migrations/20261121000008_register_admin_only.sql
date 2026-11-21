-- Smart Retail · registering a store creates only its admin
-- sr_platform_register_store used to also create one cashier ("kasa1", "kasa2", ...) per branch.
-- Now only the store admin is created; the admin adds cashiers and warehouse users from the
-- store's own admin panel.

create or replace function public.sr_platform_register_store(d jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  s app.stores; b text; i int := 0; creds jsonb := '[]'; pw text;
  au text := lower(coalesce(nullif(btrim(d->>'adminUser'), ''), 'admin'));
  br text[] := coalesce((select array_agg(btrim(x)) from jsonb_array_elements_text(d->'branches') x where btrim(x) <> ''),
                        array['მთავარი']);
begin
  perform app.require_platform_admin();
  if exists (select 1 from app.stores where slug = lower(d->>'login')::extensions.citext) then
    raise exception 'SLUG_TAKEN';
  end if;
  insert into app.stores (slug, name, status, doc)
  values (lower(d->>'login'), d->>'name', coalesce(d->>'status', 'active'),
          d - 'id' - 'login' - 'name' - 'status' - 'branches' - 'users' - 'adminUser' - 'adminPassword')
  returning * into s;
  foreach b in array br loop
    i := i + 1;
    insert into app.branches (store_id, name, sort) values (s.id, b, i);
  end loop;

  pw := coalesce(nullif(d->>'adminPassword', ''), app.gen_password());
  insert into app.app_users (store_id, lid, username, password_hash, name, role, branch, perms, must_change_password)
  values (s.id, 1, au, app.hash_pw(pw), coalesce(d->>'owner', 'ადმინისტრატორი'), 'admin', '', '{}', true);
  creds := creds || jsonb_build_object('u', au, 'pw', pw, 'role', 'admin', 'branch', '');
  update app.stores set id_counter = 100 where id = s.id;
  select * into s from app.stores where id = s.id;
  return jsonb_build_object('store', app.store_doc(s), 'credentials', creds);
end $$;
