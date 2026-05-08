-- Infrastructure-grade reliability hardening:
-- - canonical event metadata aliases: event_version + transition_id
-- - deterministic projection rebuild aliases
-- - direct projection write audit without breaking legacy-safe flows
-- - operational metrics and system health snapshots
-- - electrician reliability cooldown automation
-- - idempotent payment verification

alter table public.job_events
  add column if not exists event_version integer,
  add column if not exists transition_id uuid default gen_random_uuid();

update public.job_events
set event_version = coalesce(event_version, transition_to_version, 0)
where event_version is null;

update public.job_events
set transition_id = gen_random_uuid()
where transition_id is null;

alter table public.job_events
  alter column transition_id set not null;

create unique index if not exists job_events_transition_id_uidx
  on public.job_events(transition_id);

create index if not exists job_events_job_event_version_idx
  on public.job_events(job_id, event_version desc, event_sequence desc);

create table if not exists public.operational_metrics (
  id uuid primary key default gen_random_uuid(),
  metric_name text not null,
  metric_value numeric not null default 0,
  metric_unit text not null default 'count',
  dimensions jsonb not null default '{}'::jsonb,
  source text not null default 'automation',
  captured_at timestamptz not null default now()
);

alter table public.operational_metrics enable row level security;

drop policy if exists "operational metrics admin read" on public.operational_metrics;
create policy "operational metrics admin read"
  on public.operational_metrics
  for select
  to authenticated
  using (public.is_admin());

drop policy if exists "operational metrics service write" on public.operational_metrics;
create policy "operational metrics service write"
  on public.operational_metrics
  for all
  to service_role
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create index if not exists operational_metrics_name_captured_idx
  on public.operational_metrics(metric_name, captured_at desc);

create table if not exists public.system_health_snapshots (
  id uuid primary key default gen_random_uuid(),
  health_score numeric(5,2) not null default 100,
  queues jsonb not null default '{}'::jsonb,
  metrics jsonb not null default '{}'::jsonb,
  predictive_alert_count integer not null default 0,
  critical_alert_count integer not null default 0,
  recovery_action_count integer not null default 0,
  source text not null default 'automation',
  captured_at timestamptz not null default now()
);

alter table public.system_health_snapshots enable row level security;

drop policy if exists "system health snapshots admin read" on public.system_health_snapshots;
create policy "system health snapshots admin read"
  on public.system_health_snapshots
  for select
  to authenticated
  using (public.is_admin());

drop policy if exists "system health snapshots service write" on public.system_health_snapshots;
create policy "system health snapshots service write"
  on public.system_health_snapshots
  for all
  to service_role
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create index if not exists system_health_snapshots_captured_idx
  on public.system_health_snapshots(captured_at desc);

create or replace function public.prepare_job_event_version()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  latest_version integer := 0;
  latest_projected_status public.job_status;
  metadata_state_version integer;
  metadata_previous_version integer;
  expected_state_version integer;
  projected public.job_status;
  metadata_transition_id uuid;
begin
  if new.event_sequence is null then
    new.event_sequence := nextval('public.job_events_event_sequence_seq'::regclass);
  end if;

  if new.transition_id is null
     and coalesce(new.metadata, '{}'::jsonb) ->> 'transition_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    metadata_transition_id := (new.metadata ->> 'transition_id')::uuid;
    new.transition_id := metadata_transition_id;
  end if;

  if new.transition_id is null then
    new.transition_id := gen_random_uuid();
  end if;

  if new.request_id is null then
    new.request_id := public.sanitize_request_id(coalesce(new.metadata ->> 'request_id', new.metadata ->> 'requestId'));
  else
    new.request_id := public.sanitize_request_id(new.request_id);
  end if;

  if new.request_hash is null and new.request_id is not null then
    new.request_hash := md5(jsonb_build_object(
      'job_id', new.job_id,
      'event_type', new.event_type,
      'transition_id', new.transition_id,
      'metadata', coalesce(new.metadata, '{}'::jsonb) - 'request_id' - 'requestId' - 'transition_id'
    )::text);
  end if;

  new.metadata := coalesce(new.metadata, '{}'::jsonb) - 'request_id' - 'requestId' - 'transition_id';

  select * into job_row
  from public.jobs
  where id = new.job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  select coalesce(max(coalesce(event_version, transition_to_version)), 0)
  into latest_version
  from public.job_events
  where job_id = new.job_id;

  select projected_status
  into latest_projected_status
  from public.job_events
  where job_id = new.job_id
    and projected_status is not null
  order by coalesce(event_version, transition_to_version) desc, event_sequence desc
  limit 1;

  if coalesce(new.metadata, '{}'::jsonb) ->> 'state_version' ~ '^[0-9]+$' then
    metadata_state_version := (new.metadata ->> 'state_version')::integer;
  end if;

  if coalesce(new.metadata, '{}'::jsonb) ->> 'previous_state_version' ~ '^[0-9]+$' then
    metadata_previous_version := (new.metadata ->> 'previous_state_version')::integer;
  end if;

  if coalesce(new.metadata, '{}'::jsonb) ->> 'expected_state_version' ~ '^[0-9]+$' then
    expected_state_version := (new.metadata ->> 'expected_state_version')::integer;
    if expected_state_version <> coalesce(job_row.state_version, 0) then
      perform public.upsert_operational_alert(
        'state_conflict',
        'warning',
        'Stale event write blocked by state version guard.',
        new.job_id,
        null,
        null,
        null,
        null,
        jsonb_build_object(
          'expected_state_version', expected_state_version,
          'actual_state_version', coalesce(job_row.state_version, 0),
          'event_type', new.event_type,
          'transition_id', new.transition_id,
          'source', coalesce(new.source, new.metadata ->> 'source', 'event_insert')
        )
      );
      raise exception 'Stale job event for %. Expected version %, actual version %',
        new.job_id,
        expected_state_version,
        coalesce(job_row.state_version, 0);
    end if;
  end if;

  projected := public.job_status_for_event(new.event_type, new.metadata);
  new.projected_status := projected;

  if new.transition_to_version is null then
    if metadata_state_version is not null then
      new.transition_to_version := metadata_state_version;
    elsif projected is null then
      new.transition_to_version := greatest(coalesce(job_row.state_version, 0), latest_version, 0);
    elsif projected = job_row.status then
      new.transition_to_version := greatest(coalesce(job_row.state_version, 0), latest_version, 1);
    else
      new.transition_to_version := greatest(coalesce(job_row.state_version, 0), latest_version) + 1;
    end if;
  end if;

  new.event_version := coalesce(new.event_version, new.transition_to_version, latest_version);

  if projected is not null
     and latest_version > 0
     and coalesce(new.event_version, new.transition_to_version, 0) <= latest_version
     and projected is distinct from latest_projected_status then
    perform public.upsert_operational_alert(
      'state_conflict',
      'warning',
      'Stale projected event write blocked before snapshot mutation.',
      new.job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object(
        'event_type', new.event_type,
        'incoming_version', coalesce(new.event_version, new.transition_to_version, 0),
        'latest_version', latest_version,
        'incoming_status', projected,
        'latest_projected_status', latest_projected_status,
        'transition_id', new.transition_id,
        'source', coalesce(new.source, new.metadata ->> 'source', 'event_insert')
      )
    );
    raise exception 'Stale job event %. Incoming version %, latest version %',
      new.event_type,
      coalesce(new.event_version, new.transition_to_version, 0),
      latest_version;
  end if;

  new.transition_from_version := coalesce(
    new.transition_from_version,
    metadata_previous_version,
    greatest(coalesce(new.transition_to_version, 0) - 1, 0)
  );

  new.metadata := coalesce(new.metadata, '{}'::jsonb)
    || jsonb_build_object(
      'event_version', new.event_version,
      'transition_id', new.transition_id,
      'state_version', new.transition_to_version,
      'transition_from_version', new.transition_from_version
    );

  return new;
end;
$$;

create or replace function public.project_job_event_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.projected_status is null then
    return new;
  end if;

  insert into public.job_state_projections (
    job_id,
    projected_status,
    event_id,
    event_sequence,
    state_version,
    projected_at,
    metadata
  )
  values (
    new.job_id,
    new.projected_status,
    new.id,
    new.event_sequence,
    coalesce(new.event_version, new.transition_to_version, 0),
    now(),
    jsonb_build_object('event_type', new.event_type, 'source', new.source, 'request_id', new.request_id, 'transition_id', new.transition_id)
  )
  on conflict (job_id) do update
  set projected_status = excluded.projected_status,
      event_id = excluded.event_id,
      event_sequence = excluded.event_sequence,
      state_version = excluded.state_version,
      projected_at = now(),
      metadata = public.job_state_projections.metadata || excluded.metadata
  where excluded.state_version > public.job_state_projections.state_version
     or (
       excluded.state_version = public.job_state_projections.state_version
       and excluded.projected_status = public.job_state_projections.projected_status
       and excluded.event_sequence >= public.job_state_projections.event_sequence
     );

  update public.jobs
  set status = new.projected_status,
      state_version = greatest(coalesce(state_version, 0), coalesce(new.event_version, new.transition_to_version, 0)),
      snapshot_reconciled_at = now(),
      updated_at = now()
  where id = new.job_id
    and coalesce(new.event_version, new.transition_to_version, 0) > coalesce(state_version, 0);

  update public.job_events
  set projected_at = coalesce(projected_at, now())
  where id = new.id;

  return new;
end;
$$;

create or replace function public.audit_direct_job_status_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status is distinct from new.status and pg_trigger_depth() <= 1 then
    perform public.upsert_operational_alert(
      'state_conflict',
      'warning',
      'Legacy projection write observed outside canonical event projection.',
      new.id,
      new.assigned_electrician_id,
      null,
      null,
      null,
      jsonb_build_object(
        'previous_status', old.status,
        'next_status', new.status,
        'previous_state_version', old.state_version,
        'next_state_version', new.state_version,
        'source', 'jobs_status_update_trigger'
      )
    );
  end if;
  return new;
end;
$$;

drop trigger if exists audit_direct_job_status_write_trigger on public.jobs;
create trigger audit_direct_job_status_write_trigger
  after update of status on public.jobs
  for each row
  execute function public.audit_direct_job_status_write();

create or replace function public.replay_job_events_internal(
  p_job_id uuid,
  p_replay_run_id uuid default null,
  p_reason text default 'event-replay'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  event_row public.job_events;
  latest_status public.job_status;
  latest_event_id uuid;
  latest_sequence bigint := 0;
  latest_version integer := 0;
  processed_count integer := 0;
  conflict_count integer := 0;
  stale_count integer := 0;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  delete from public.job_state_projections
  where job_id = p_job_id;

  for event_row in
    select *
    from public.job_events
    where job_id = p_job_id
    order by event_sequence asc, created_at asc
  loop
    processed_count := processed_count + 1;

    if event_row.projected_status is null then
      continue;
    end if;

    if coalesce(event_row.event_version, event_row.transition_to_version, 0) < latest_version
       or (
         coalesce(event_row.event_version, event_row.transition_to_version, 0) = latest_version
         and latest_status is not null
         and event_row.projected_status is distinct from latest_status
       ) then
      stale_count := stale_count + 1;
      continue;
    end if;

    if coalesce(event_row.event_version, event_row.transition_to_version, 0) = latest_version
       and latest_status is not null
       and event_row.event_sequence < latest_sequence then
      stale_count := stale_count + 1;
      continue;
    end if;

    latest_status := event_row.projected_status;
    latest_event_id := event_row.id;
    latest_sequence := event_row.event_sequence;
    latest_version := coalesce(event_row.event_version, event_row.transition_to_version, latest_version);

    insert into public.job_state_projections (
      job_id,
      projected_status,
      event_id,
      event_sequence,
      state_version,
      projected_at,
      snapshot_synced_at,
      metadata
    )
    values (
      p_job_id,
      event_row.projected_status,
      event_row.id,
      event_row.event_sequence,
      latest_version,
      now(),
      null,
      jsonb_build_object(
        'replayed', true,
        'replay_run_id', p_replay_run_id,
        'reason', coalesce(nullif(btrim(p_reason), ''), 'event-replay'),
        'transition_id', event_row.transition_id
      )
    )
    on conflict (job_id) do update
    set projected_status = excluded.projected_status,
        event_id = excluded.event_id,
        event_sequence = excluded.event_sequence,
        state_version = excluded.state_version,
        projected_at = excluded.projected_at,
        metadata = public.job_state_projections.metadata || excluded.metadata;

    update public.job_events
    set projected_at = coalesce(projected_at, now()),
        replay_run_id = coalesce(p_replay_run_id, replay_run_id)
    where id = event_row.id;
  end loop;

  if latest_status is null then
    update public.jobs
    set snapshot_reconciled_at = now()
    where id = p_job_id;
  else
    update public.jobs
    set status = latest_status,
        state_version = greatest(coalesce(state_version, 0), latest_version),
        snapshot_reconciled_at = now(),
        updated_at = now()
    where id = p_job_id;
  end if;

  if stale_count > 0 then
    perform public.upsert_operational_alert(
      'state_conflict',
      'warning',
      'Replay skipped stale projected events.',
      p_job_id,
      null,
      null,
      null,
      latest_event_id,
      jsonb_build_object(
        'stale_rejected_count', stale_count,
        'processed_count', processed_count,
        'replay_run_id', p_replay_run_id
      )
    );
  end if;

  return jsonb_build_object(
    'job_id', p_job_id,
    'latest_event_id', latest_event_id,
    'latest_status', latest_status,
    'latest_version', latest_version,
    'processed_count', processed_count,
    'conflict_count', conflict_count,
    'stale_rejected_count', stale_count
  );
end;
$$;

create or replace function public.rebuild_job_projection(
  p_job_id uuid,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() = 'service_role' then
    return public.replay_job_events(p_job_id, p_request_id);
  end if;
  if public.is_admin() then
    return public.admin_replay_job_events(p_job_id);
  end if;
  raise exception 'Admin or service role required';
end;
$$;

create or replace function public.rebuild_all_projections(
  p_limit integer default 500,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;
  return public.replay_all_job_events(p_limit, p_request_id);
end;
$$;

create or replace function public.apply_electrician_reliability_cooldowns(p_limit integer default 200)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  snapshot_row public.electrician_performance_snapshots;
  updated_count integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  for item in
    select e.id
    from public.electricians e
    where e.status = 'approved'
    order by coalesce(e.last_offered_at, to_timestamp(0)) asc, e.updated_at asc nulls last
    limit greatest(coalesce(p_limit, 200), 1)
  loop
    snapshot_row := public.refresh_electrician_performance_snapshot(item.id);

    if snapshot_row.quality_tier in ('Watch', 'Recovery')
       or snapshot_row.rejection_rate >= 50
       or snapshot_row.completion_score < 70
       or snapshot_row.dispute_score < 75 then
      update public.electricians
      set quality_penalty_until = greatest(coalesce(quality_penalty_until, now()), now() + interval '12 hours'),
          quality_penalty_reason = case
            when snapshot_row.rejection_rate >= 50 then 'Automatic cooldown: rejection rate above target'
            when snapshot_row.completion_score < 70 then 'Automatic cooldown: completion reliability below target'
            when snapshot_row.dispute_score < 75 then 'Automatic cooldown: dispute score below target'
            else 'Automatic cooldown: reliability review'
          end
      where id = item.id;
      updated_count := updated_count + 1;
    elsif exists (
      select 1 from public.electricians e
      where e.id = item.id
        and e.quality_penalty_until is not null
        and e.quality_penalty_until <= now()
    ) then
      update public.electricians
      set quality_penalty_until = null,
          quality_penalty_reason = null
      where id = item.id;
      updated_count := updated_count + 1;
    end if;
  end loop;

  return updated_count;
end;
$$;

create or replace function public.capture_system_health_snapshot(p_source text default 'automation')
returns public.system_health_snapshots
language plpgsql
security definer
set search_path = public
as $$
declare
  summary jsonb;
  metric record;
  snapshot_row public.system_health_snapshots;
  metric_value numeric;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  summary := public.admin_operational_summary();

  insert into public.system_health_snapshots (
    health_score,
    queues,
    metrics,
    predictive_alert_count,
    critical_alert_count,
    recovery_action_count,
    source
  )
  values (
    coalesce((summary #>> '{metrics,system_health_score}')::numeric, 100),
    coalesce(summary -> 'queues', '{}'::jsonb),
    coalesce(summary -> 'metrics', '{}'::jsonb),
    coalesce((summary #>> '{metrics,predictive_alerts}')::integer, 0),
    coalesce((summary #>> '{queues,critical_alerts}')::integer, 0),
    coalesce((summary #>> '{metrics,dispatch_retries_7d}')::integer, 0),
    coalesce(nullif(btrim(p_source), ''), 'automation')
  )
  returning * into snapshot_row;

  for metric in
    select key, value
    from jsonb_each_text(coalesce(summary -> 'metrics', '{}'::jsonb))
  loop
    if metric.value ~ '^-?[0-9]+(\\.[0-9]+)?$' then
      metric_value := metric.value::numeric;
      insert into public.operational_metrics (metric_name, metric_value, metric_unit, dimensions, source, captured_at)
      values (
        metric.key,
        metric_value,
        case
          when metric.key like '%seconds%' then 'seconds'
          when metric.key like '%rate%' or metric.key like '%score%' or metric.key like '%quality%' then 'percent'
          else 'count'
        end,
        jsonb_build_object('snapshot_id', snapshot_row.id),
        coalesce(nullif(btrim(p_source), ''), 'automation'),
        snapshot_row.captured_at
      );
    end if;
  end loop;

  return snapshot_row;
end;
$$;

create or replace function public.verify_job_payment(
  p_payment_id uuid,
  p_approved boolean,
  p_admin_note text default null
) returns public.job_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  payment_row public.job_payments;
  job_row public.jobs;
  next_status public.job_status;
  customer_profile uuid;
  electrician_profile uuid;
  event_type_value text;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  select * into payment_row from public.job_payments where id = p_payment_id for update;
  if not found then
    raise exception 'Payment not found';
  end if;

  select * into job_row from public.jobs where id = payment_row.job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if payment_row.status = 'verified' and p_approved then
    return payment_row;
  end if;

  if payment_row.status in ('verified', 'rejected')
     and payment_row.status <> (case when p_approved then 'verified'::public.payment_status else 'rejected'::public.payment_status end) then
    raise exception 'Payment has already been resolved. Refresh before changing it.';
  end if;

  if job_row.status = 'cancelled' then
    raise exception 'Cancelled jobs cannot receive payment verification.';
  end if;

  update public.job_payments
  set status = case when p_approved then 'verified'::public.payment_status else 'rejected'::public.payment_status end,
      admin_note = p_admin_note,
      verified_by = auth.uid(),
      verified_at = now()
  where id = p_payment_id
  returning * into payment_row;

  if p_approved then
    next_status := case
      when payment_row.payment_type = 'assessment_fee' then 'assessment_confirmed'::public.job_status
      else 'payment_confirmed'::public.job_status
    end;
  else
    next_status := case
      when payment_row.payment_type = 'assessment_fee' then 'assessment_fee_pending'::public.job_status
      else 'quote_accepted'::public.job_status
    end;
  end if;

  job_row := public.transition_job_state(
    payment_row.job_id,
    next_status,
    'admin',
    auth.uid(),
    case when p_approved then 'Payment verified.' else 'Payment needs to be resubmitted.' end,
    case when p_approved then 'Payment verified by admin.' else 'Payment rejected by admin.' end,
    jsonb_build_object(
      'payment_id', payment_row.id,
      'payment_type', payment_row.payment_type,
      'approved', p_approved,
      'source', 'verify_job_payment',
      'expected_state_version', job_row.state_version
    ),
    job_row.status,
    'payment-verification:' || payment_row.id::text || ':' || case when p_approved then 'approved' else 'rejected' end
  );

  event_type_value := case when p_approved then 'PAYMENT_VERIFIED' else 'JOB_UPDATED' end;
  perform public.log_job_event(
    payment_row.job_id,
    event_type_value,
    'admin',
    auth.uid(),
    case when p_approved then 'Payment verified.' else 'Payment needs to be resubmitted.' end,
    case when p_approved then 'Payment verified by admin.' else 'Payment rejected by admin.' end,
    jsonb_build_object(
      'payment_id', payment_row.id,
      'payment_type', payment_row.payment_type,
      'source', 'verify_job_payment',
      'idempotency_key', 'payment-event:' || payment_row.id::text || ':' || case when p_approved then 'approved' else 'rejected' end
    )
  );

  select c.profile_id into customer_profile
  from public.jobs j
  join public.customers c on c.id = j.customer_id
  where j.id = payment_row.job_id;

  select e.profile_id into electrician_profile
  from public.jobs j
  join public.electricians e on e.id = j.assigned_electrician_id
  where j.id = payment_row.job_id;

  if p_approved then
    perform public.create_notification(customer_profile, payment_row.job_id, 'payment_verified', 'Payment verified', 'Your payment was verified and the job can move forward.', jsonb_build_object('payment_id', payment_row.id));
    perform public.create_notification(electrician_profile, payment_row.job_id, 'payment_verified', 'Payment confirmed', 'Admin verified customer payment for this job.', jsonb_build_object('payment_id', payment_row.id));
  else
    perform public.create_notification(customer_profile, payment_row.job_id, 'payment_rejected', 'Payment review needed', 'VoltFriq could not verify that proof. Please resubmit clearly.', jsonb_build_object('payment_id', payment_row.id));
  end if;

  return payment_row;
end;
$$;

create or replace function public.run_operational_automation(
  p_limit integer default 100,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_hash text := md5('run_operational_automation:' || coalesce(p_limit, 100)::text);
  claim jsonb;
  run_id uuid;
  replay_payload jsonb := '{}'::jsonb;
  replay_count integer := 0;
  rebuilt_count integer := 0;
  prioritized_count integer := 0;
  synced_count integer := 0;
  dispatch_count integer := 0;
  alert_count integer := 0;
  escalated_count integer := 0;
  cooldown_count integer := 0;
  resolved_count integer := 0;
  total_count integer := 0;
  health_snapshot public.system_health_snapshots;
  payload jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  claim := public.claim_operation_request(clean_request_id, 'run_operational_automation', request_hash);
  clean_request_id := claim ->> 'request_id';

  if coalesce((claim ->> 'claimed')::boolean, false) = false then
    if claim ->> 'status' = 'completed' then
      return coalesce(claim -> 'response_payload', '{}'::jsonb) || jsonb_build_object('replayed', true);
    end if;

    return jsonb_build_object(
      'request_id', clean_request_id,
      'processed', 0,
      'status', claim ->> 'status',
      'replayed', true
    );
  end if;

  insert into public.operational_automation_runs (run_type, status, request_id, request_hash, metadata)
  values (
    'dispatch_heartbeat',
    'running',
    clean_request_id,
    request_hash,
    jsonb_build_object('limit', coalesce(p_limit, 100), 'request_id', clean_request_id)
  )
  returning id into run_id;

  replay_payload := public.replay_all_job_events(
    least(greatest(coalesce(p_limit, 100), 1), 25),
    clean_request_id || ':event-replay'
  );
  replay_count := coalesce((replay_payload ->> 'processed')::integer, 0);

  rebuilt_count := public.rebuild_all_job_state_projections(greatest(least(coalesce(p_limit, 100), 500), 1));
  cooldown_count := public.apply_electrician_reliability_cooldowns(greatest(least(coalesce(p_limit, 100), 200), 1));
  prioritized_count := public.prioritize_dispatch_queue(greatest(least(coalesce(p_limit, 100) * 2, 500), 1));
  synced_count := public.sync_all_job_state_projections(greatest(coalesce(p_limit, 100), 1));
  dispatch_count := public.process_dispatch_queue();
  alert_count := public.refresh_operational_alerts();
  escalated_count := public.apply_operational_escalations();
  health_snapshot := public.capture_system_health_snapshot('automation');

  update public.operational_alerts a
  set status = 'resolved',
      resolved_at = coalesce(resolved_at, now()),
      metadata = metadata || jsonb_build_object('automation_resolved_at', now())
  where status = 'open'
    and alert_type = 'snapshot_drift'
    and not exists (
      select 1 from public.detect_snapshot_drift() drift where drift.job_id = a.job_id
    );
  get diagnostics resolved_count = row_count;

  total_count := replay_count + rebuilt_count + cooldown_count + prioritized_count + synced_count + dispatch_count + alert_count + escalated_count + resolved_count;

  payload := jsonb_build_object(
    'request_id', clean_request_id,
    'run_id', run_id,
    'event_replay', replay_payload,
    'event_replay_processed', replay_count,
    'projection_rebuilds', rebuilt_count,
    'electrician_cooldowns', cooldown_count,
    'queue_prioritized', prioritized_count,
    'projection_syncs', synced_count,
    'dispatch_actions', dispatch_count,
    'alerts_refreshed', alert_count,
    'alerts_escalated', escalated_count,
    'alerts_resolved', resolved_count,
    'health_snapshot_id', health_snapshot.id,
    'processed', total_count
  );

  update public.operational_automation_runs
  set status = 'completed',
      finished_at = now(),
      processed_count = total_count,
      metadata = metadata || payload
  where id = run_id;

  perform public.complete_operation_request(clean_request_id, 'completed', payload, null);
  return payload;
exception
  when others then
    if clean_request_id is not null then
      perform public.complete_operation_request(
        clean_request_id,
        'failed',
        jsonb_build_object('request_id', clean_request_id),
        sqlerrm
      );
    end if;
    if run_id is not null then
      update public.operational_automation_runs
      set status = 'failed',
          finished_at = now(),
          error_message = sqlerrm,
          metadata = metadata || jsonb_build_object('sqlstate', sqlstate)
      where id = run_id;
    end if;
    raise;
end;
$$;

revoke all on table public.operational_metrics from public, anon, authenticated;
grant select on table public.operational_metrics to authenticated;
grant all on table public.operational_metrics to service_role;

revoke all on table public.system_health_snapshots from public, anon, authenticated;
grant select on table public.system_health_snapshots to authenticated;
grant all on table public.system_health_snapshots to service_role;

revoke all on function public.audit_direct_job_status_write() from public, anon, authenticated;
grant execute on function public.audit_direct_job_status_write() to service_role;

revoke all on function public.rebuild_job_projection(uuid,text) from public, anon, authenticated;
grant execute on function public.rebuild_job_projection(uuid,text) to authenticated, service_role;

revoke all on function public.rebuild_all_projections(integer,text) from public, anon, authenticated;
grant execute on function public.rebuild_all_projections(integer,text) to service_role;

revoke all on function public.apply_electrician_reliability_cooldowns(integer) from public, anon, authenticated;
grant execute on function public.apply_electrician_reliability_cooldowns(integer) to service_role;

revoke all on function public.capture_system_health_snapshot(text) from public, anon, authenticated;
grant execute on function public.capture_system_health_snapshot(text) to authenticated, service_role;

revoke all on function public.prepare_job_event_version() from public, anon, authenticated;
grant execute on function public.prepare_job_event_version() to service_role;

revoke all on function public.project_job_event_state() from public, anon, authenticated;
grant execute on function public.project_job_event_state() to service_role;

revoke all on function public.replay_job_events_internal(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.replay_job_events_internal(uuid,uuid,text) to service_role;

revoke all on function public.verify_job_payment(uuid,boolean,text) from public, anon, authenticated;
grant execute on function public.verify_job_payment(uuid,boolean,text) to authenticated, service_role;

revoke all on function public.run_operational_automation(integer,text) from public, anon, authenticated;
grant execute on function public.run_operational_automation(integer,text) to service_role;

select pg_notify('pgrst', 'reload schema');
