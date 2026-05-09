-- Do not raise a critical automation heartbeat alert on a clean launch/reset
-- where no operational workload exists yet. Once automation has run, stale
-- heartbeats are still detected normally.

create or replace function public.detect_predictive_operational_risks()
returns table(
  alert_type text,
  severity text,
  reason text,
  job_id uuid,
  electrician_id uuid,
  payment_id uuid,
  metadata jsonb
)
language sql
security definer
set search_path = public
as $$
  select
    'predictive_pairing_risk'::text,
    case
      when coalesce(j.dispatch_attempts, 0) >= 2 or coalesce(j.last_dispatch_at, j.updated_at, j.created_at) < now() - interval '4 minutes' then 'critical'
      else 'warning'
    end,
    'Pairing is likely to breach target soon.',
    j.id,
    null::uuid,
    null::uuid,
    jsonb_build_object(
      'ticket', j.ticket,
      'status', j.status,
      'dispatch_attempts', coalesce(j.dispatch_attempts, 0),
      'age_seconds', extract(epoch from (now() - coalesce(j.last_dispatch_at, j.updated_at, j.created_at))),
      'prediction_window', 'pairing_5_min_target'
    )
  from public.jobs j
  where j.status in ('requested', 'matching')
    and coalesce(j.last_dispatch_at, j.updated_at, j.created_at) < now() - interval '3 minutes'
    and not exists (
      select 1 from public.detect_stuck_jobs() stuck
      where stuck.job_id = j.id
    )

  union all

  select
    'predictive_payment_backlog'::text,
    case when p.created_at < now() - interval '25 minutes' then 'critical' else 'warning' end,
    'Payment proof is approaching verification target.',
    p.job_id,
    null::uuid,
    p.id,
    jsonb_build_object(
      'ticket', j.ticket,
      'payment_type', p.payment_type,
      'age_seconds', extract(epoch from (now() - p.created_at)),
      'prediction_window', 'payment_30_min_target'
    )
  from public.job_payments p
  join public.jobs j on j.id = p.job_id
  where p.status = 'submitted'
    and p.created_at < now() - interval '20 minutes'

  union all

  select
    'automation_lag'::text,
    case
      when latest.completed_at is null or latest.completed_at < now() - interval '20 minutes' then 'critical'
      else 'warning'
    end,
    'Operational automation heartbeat is behind target.',
    null::uuid,
    null::uuid,
    null::uuid,
    jsonb_build_object(
      'last_completed_at', latest.completed_at,
      'age_seconds', case when latest.completed_at is null then null else extract(epoch from (now() - latest.completed_at)) end,
      'prediction_window', 'heartbeat_10_min_target'
    )
  from (
    select max(finished_at) as completed_at
    from public.operational_automation_runs
    where status = 'completed'
  ) latest
  where (
      latest.completed_at is null
      and exists (
        select 1
        from public.jobs j
        where j.status not in ('rated', 'cancelled')
        limit 1
      )
    )
     or latest.completed_at < now() - interval '10 minutes'

  union all

  select
    'projection_replay_due'::text,
    'warning'::text,
    'Job projection has not been replayed recently.',
    j.id,
    null::uuid,
    null::uuid,
    jsonb_build_object(
      'ticket', j.ticket,
      'status', j.status,
      'snapshot_reconciled_at', j.snapshot_reconciled_at,
      'state_version', j.state_version
    )
  from public.jobs j
  where j.status not in ('rated', 'cancelled')
    and exists (select 1 from public.job_events e where e.job_id = j.id and e.projected_status is not null)
    and coalesce(j.snapshot_reconciled_at, to_timestamp(0)) < now() - interval '30 minutes'
$$;

revoke all on function public.detect_predictive_operational_risks() from public, anon, authenticated;
grant execute on function public.detect_predictive_operational_risks() to service_role;
