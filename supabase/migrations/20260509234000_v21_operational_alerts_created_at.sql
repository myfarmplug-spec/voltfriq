-- v21 contract alias for operational alerts.
alter table public.operational_alerts
  add column if not exists created_at timestamptz not null default now();

update public.operational_alerts
set created_at = coalesce(first_seen_at, created_at, now())
where created_at is null
   or (first_seen_at is not null and created_at > first_seen_at);

create index if not exists operational_alerts_created_idx
  on public.operational_alerts(created_at desc);

select pg_notify('pgrst', 'reload schema');
