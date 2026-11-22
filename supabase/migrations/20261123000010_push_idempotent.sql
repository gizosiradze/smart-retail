-- Offline queue: a batch of changes may be sent more than once (the answer got lost on a bad connection).
-- The app puts a batch id "bid" into every push. A batch that was already applied is not applied again
-- (stock changes are deltas, so a second run would subtract the sold goods twice); the stored answer is returned.
create table app.push_batches (
  store_id uuid not null references app.stores on delete cascade,
  bid uuid not null,
  result jsonb not null,
  at timestamptz not null default now(),
  primary key (store_id, bid)
);
create index on app.push_batches (at);
alter table app.push_batches enable row level security;   -- no policies: only the security-definer functions touch it

create or replace function public.sr_push(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare x app.ctx_t; b uuid; r jsonb;
begin
  if app.read_only() then raise exception 'READ_ONLY' using errcode = '42501'; end if;
  if p ? 'bid' then
    x := app.ctx();
    b := (p->>'bid')::uuid;
    -- two sends of the same batch at the same moment wait for each other
    perform pg_advisory_xact_lock(hashtextextended(x.store_id::text || b::text, 0));
    select result into r from app.push_batches where store_id = x.store_id and bid = b;
    if r is not null then return r || jsonb_build_object('replayed', true); end if;
    r := app.push_rw(p - 'bid');
    insert into app.push_batches (store_id, bid, result) values (x.store_id, b, r);
    delete from app.push_batches where store_id = x.store_id and at < now() - interval '30 days';
    return r;
  end if;
  return app.push_rw(p);
end $$;

revoke execute on function public.sr_push(jsonb) from public, anon;
grant execute on function public.sr_push(jsonb) to authenticated, service_role;
