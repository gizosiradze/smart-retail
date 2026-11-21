-- Smart Retail · product photos in Supabase Storage
-- Public-read bucket (product photos are not secret); files live under "<store_id>/..." and only
-- signed-in staff of that store (admin or warehouse manager) may upload, replace or delete them.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 1048576, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create function app.storage_can_write(p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare x app.ctx_t;
begin
  begin
    x := app.ctx();
  exception when others then
    return false;
  end;
  return x.role in ('admin', 'wh') and (storage.foldername(p_name))[1] = x.store_id::text;
end $$;
grant execute on function app.storage_can_write(text) to authenticated;
grant usage on schema app to authenticated;

create policy "staff upload product images" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and app.storage_can_write(name));
create policy "staff update product images" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and app.storage_can_write(name));
create policy "staff delete product images" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and app.storage_can_write(name));
