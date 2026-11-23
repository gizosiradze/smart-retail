-- Super Admin can add a branch to an existing store.
-- Returns the store's updated list of active branch names.
create function public.sr_platform_add_branch(p_store uuid, p_name text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare n text := btrim(coalesce(p_name, ''));
begin
  perform app.require_platform_admin();
  if n = '' then raise exception 'BRANCH_NAME_REQUIRED'; end if;
  if not exists (select 1 from app.stores where id = p_store) then raise exception 'STORE_NOT_FOUND'; end if;
  if exists (select 1 from app.branches where store_id = p_store and lower(name) = lower(n)) then
    raise exception 'BRANCH_EXISTS';
  end if;
  insert into app.branches (store_id, name, sort)
  values (p_store, n, coalesce((select max(sort) from app.branches where store_id = p_store), 0) + 1);
  return jsonb_build_object('branches', (select jsonb_agg(b.name order by b.sort, b.name)
                                           from app.branches b where b.store_id = p_store and b.active));
end $$;

revoke execute on function public.sr_platform_add_branch(uuid, text) from public, anon;
grant execute on function public.sr_platform_add_branch(uuid, text) to authenticated, service_role;
