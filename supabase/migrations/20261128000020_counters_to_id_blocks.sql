-- Smart Retail · transfer and expense numbers now come from the per-device id blocks (sr_alloc_ids)
-- instead of the shared kv counters "trn" and "exn" (two devices could read the same value and hand out
-- the same number). New ids are always >= the store's id_counter. Old records keep their small numbers, so
-- the counter must be above every number the old counters ever gave out; this lifts it where needed.
update app.stores s
   set id_counter = greatest(
         s.id_counter,
         coalesce((select max(case when jsonb_typeof(k.value) = 'number' then (k.value #>> '{}')::numeric end)
                     from app.kv k where k.store_id = s.id and k.key in ('trn', 'exn')), 0)::bigint + 1000);
