-- Smart Retail · Super Admin metrics also report each store's total receipt count
-- (the dashboard warns when a store gets big enough that its statistics should move from the browser to SQL).
-- The existing function keeps its body; this wraps it and adds one number per store.

alter function public.sr_platform_metrics() set schema app;
alter function app.sr_platform_metrics() rename to platform_metrics_base;

create function public.sr_platform_metrics() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  return coalesce((
    select jsonb_object_agg(e.key, e.value || jsonb_build_object('receipts',
             (select count(*) from app.sales sa where sa.store_id = e.key::uuid)))
      from jsonb_each(app.platform_metrics_base()) e), '{}'::jsonb);
end $$;

revoke execute on all functions in schema app from public, anon, authenticated;
grant execute on all functions in schema app to service_role;
grant execute on function app.storage_can_write(text) to authenticated;
revoke execute on function public.sr_platform_metrics() from public, anon;
grant execute on function public.sr_platform_metrics() to authenticated, service_role;
