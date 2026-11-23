-- Notification text for a received transfer: "received 2 / 3 pcs" instead of only the sent quantity.
-- transfers: the received message says how many of the sent pieces arrived
create or replace function app.transfers_push() returns trigger
language plpgsql volatile security definer set search_path = '' as $$
declare d jsonb := new.doc; o jsonb := case when tg_op = 'UPDATE' then old.doc end; n numeric; got numeric; short boolean;
begin
  begin
    if new.removed_at is not null then return new; end if;
    select coalesce(sum(app.to_num(l->>'q')), 0) into n from jsonb_array_elements(coalesce(d->'L', '[]'::jsonb)) l;
    if d->>'st' = 'sent' and coalesce(o->>'st', '') <> 'sent' and coalesce(app.ms_to_ts(d->>'ts'), now()) > now() - interval '1 day' then
      perform app.push_event(new.store_id, array['trs'],
        'გადაზიდვა გაიგზავნა · ' || coalesce(new.from_branch, '') || ' → ' || coalesce(new.to_branch, ''),
        '№' || coalesce(new.number::text, '') || ' · ' || n::text || ' ც.', 'trs-' || new.id, new.from_branch);
    elsif d->>'st' = 'recv' and coalesce(o->>'st', '') <> 'recv' and coalesce(app.ms_to_ts(d->>'tr'), now()) > now() - interval '1 day' then
      select coalesce(sum(app.to_num(l->>'r')), 0) into got from jsonb_array_elements(coalesce(d->'L', '[]'::jsonb)) l;
      select exists (select 1 from jsonb_array_elements(coalesce(d->'L', '[]'::jsonb)) l
                      where app.to_num(l->>'r') < app.to_num(l->>'q')) into short;
      perform app.push_event(new.store_id, case when short then array['trd', 'trr'] else array['trr'] end,
        case when short then 'გადაზიდვა მიღებულია დანაკლისით' else 'გადაზიდვა მიღებულია' end
          || ' · ' || coalesce(new.from_branch, '') || ' → ' || coalesce(new.to_branch, ''),
        '№' || coalesce(new.number::text, '') || ' · მიღებულია ' || got::text || ' / ' || n::text || ' ც.', 'trr-' || new.id, new.to_branch);
    end if;
  exception when others then null;
  end;
  return new;
end $$;
