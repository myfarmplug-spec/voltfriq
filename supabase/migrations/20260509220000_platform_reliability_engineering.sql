-- Platform reliability engineering:
-- - event replay audit runs
-- - stronger stale event rejection
-- - predictive operational alerts
-- - automation heartbeat now includes bounded replay work

create table if not exists public.event_replay_runs (
  id uuid primary key default gen_random_uuid(),
  request_id text,
  request_hash text,
  replay_scope text not null default 'single',
  job_id uuid references public.jobs(id) on delete set null,
  status text not null default 'running',
  processed_count integer not null default 0,
  conflict_count integer not null default 0,
  stale_rejected_count integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  error_message text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  constraint event_replay_runs_status_check check (status in ('running', 'completed', 'failed'))
);

alter table public.event_replay_runs enable row level security;

drop policy if exists "event replay runs admin read" on public.event_replay_runs;
create policy "event replay runs admin read"
  on public.event_replay_runs
  for select
  to authenticated
  using (public.is_admin());

drop policy if exists "event replay runs service write" on public.event_replay_runs;
create policy "event replay runs service write"
  on public.event_replay_runs
  for all
  to service_role
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create unique index if not exists event_replay_runs_request_id_uidx
  on public.event_replay_runs(request_id)
  where request_id is not null;

create index if not exists event_replay_runs_status_started_idx
  on public.event_replay_runs(status, started_at desc);

create index if not exists event_replay_runs_job_started_idx
  on public.event_replay_runs(job_id, started_at desc)
  where job_id is not null;

alter table public.job_events
  add column if not exists replay_run_id uuid references public.event_replay_runs(id) on delete set null;

create index if not exists job_events_replay_run_idx
  on public.job_events(replay_run_id)
  where replay_run_id is not null;

alter table public.operational_alerts drop constraint if exists operational_alerts_alert_type_check;
alter table public.operational_alerts
  add constraint operational_alerts_alert_type_check
  check (alert_type in (
    'pending_payment',
    'pending_electrician',
    'stuck_pairing',
    'expired_assignment',
    'open_dispute',
    'payment_delay',
    'customer_confirmation_delay',
    'dispatch_conflict',
    'state_conflict',
    'snapshot_drift',
    'failed_pairing',
    'upload_failure',
    'high_rejection_electrician',
    'electrician_performance',
    'predictive_pairing_risk',
    'predictive_payment_backlog',
    'automation_lag',
    'projection_replay_due',
    'projection_replay_failure'
  ));

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
begin
  if new.event_sequence is null then
    new.event_sequence := nextval('public.job_events_event_sequence_seq'::regclass);
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
      'metadata', coalesce(new.metadata, '{}'::jsonb) - 'request_id' - 'requestId'
    )::text);
  end if;

  new.metadata := coalesce(new.metadata, '{}'::jsonb) - 'request_id' - 'requestId';

  select * into job_row
  from public.jobs
  where id = new.job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  select coalesce(max(transition_to_version), 0)
  into latest_version
  from public.job_events
  where job_id = new.job_id;

  select projected_status
  into latest_projected_status
  from public.job_events
  where job_id = new.job_id
    and projected_status is not null
  order by transition_to_version desc, event_sequence desc
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

  if projected is not null
     and latest_version > 0
     and coalesce(new.transition_to_version, 0) <= latest_version
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
        'incoming_version', coalesce(new.transition_to_version, 0),
        'latest_version', latest_version,
        'incoming_status', projected,
        'latest_projected_status', latest_projected_status,
        'source', coalesce(new.source, new.metadata ->> 'source', 'event_insert')
      )
    );
    raise exception 'Stale job event %. Incoming version %, latest version %',
      new.event_type,
      coalesce(new.transition_to_version, 0),
      latest_version;
  end if;

  new.transition_from_version := coalesce(
    new.transition_from_version,
    metadata_previous_version,
    greatest(coalesce(new.transition_to_version, 0) - 1, 0)
  );

  new.metadata := coalesce(new.metadata, '{}'::jsonb)
    || jsonb_build_object(
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
    coalesce(new.transition_to_version, 0),
    now(),
    jsonb_build_object('event_type', new.event_type, 'source', new.source, 'request_id', new.request_id)
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
      state_version = greatest(coalesce(state_version, 0), coalesce(new.transition_to_version, 0)),
      snapshot_reconciled_at = now(),
      updated_at = now()
  where id = new.job_id
    and coalesce(new.transition_to_version, 0) > coalesce(state_version, 0);

  update public.job_events
  set projected_at = coalesce(projected_at, now())
  where id = new.id;

  return new;
end;
$$;

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

    if coalesce(event_row.transition_to_version, 0) < latest_version
       or (
         coalesce(event_row.transition_to_version, 0) = latest_version
         and latest_status is not null
         and event_row.projected_status is distinct from latest_status
       ) then
      stale_count := stale_count + 1;
      continue;
    end if;

    if coalesce(event_row.transition_to_version, 0) = latest_version
       and latest_status is not null
       and event_row.event_sequence < latest_sequence then
      stale_count := stale_count + 1;
      continue;
    end if;

    latest_status := event_row.projected_status;
    latest_event_id := event_row.id;
    latest_sequence := event_row.event_sequence;
    latest_version := coalesce(event_row.transition_to_version, latest_version);

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
        'reason', coalesce(nullif(btrim(p_reason), ''), 'event-replay')
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

create or replace function public.replay_job_events(
  p_job_id uuid,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_hash text := md5('replay_job_events:' || coalesce(p_job_id::text, ''));
  claim jsonb;
  run_id uuid;
  replay_payload jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  claim := public.claim_operation_request(clean_request_id, 'replay_job_events', request_hash);
  clean_request_id := claim ->> 'request_id';

  if coalesce((claim ->> 'claimed')::boolean, false) = false then
    if claim ->> 'status' = 'completed' then
      return coalesce(claim -> 'response_payload', '{}'::jsonb) || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('request_id', clean_request_id, 'processed', 0, 'status', claim ->> 'status', 'replayed', true);
  end if;

  insert into public.event_replay_runs (request_id, request_hash, replay_scope, job_id, status, metadata)
  values (clean_request_id, request_hash, 'single', p_job_id, 'running', jsonb_build_object('request_id', clean_request_id))
  returning id into run_id;

  replay_payload := public.replay_job_events_internal(p_job_id, run_id, 'service-replay');

  update public.event_replay_runs
  set status = 'completed',
      finished_at = now(),
      processed_count = coalesce((replay_payload ->> 'processed_count')::integer, 0),
      conflict_count = coalesce((replay_payload ->> 'conflict_count')::integer, 0),
      stale_rejected_count = coalesce((replay_payload ->> 'stale_rejected_count')::integer, 0),
      metadata = metadata || replay_payload
  where id = run_id;

  replay_payload := replay_payload || jsonb_build_object('request_id', clean_request_id, 'run_id', run_id, 'processed', coalesce((replay_payload ->> 'processed_count')::integer, 0));
  perform public.complete_operation_request(clean_request_id, 'completed', replay_payload, null);
  return replay_payload;
exception
  when others then
    if run_id is not null then
      update public.event_replay_runs
      set status = 'failed',
          finished_at = now(),
          error_message = sqlerrm,
          metadata = metadata || jsonb_build_object('sqlstate', sqlstate)
      where id = run_id;
    end if;
    if clean_request_id is not null then
      perform public.complete_operation_request(clean_request_id, 'failed', jsonb_build_object('request_id', clean_request_id), sqlerrm);
    end if;
    raise;
end;
$$;

create or replace function public.replay_all_job_events(
  p_limit integer default 100,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_hash text := md5('replay_all_job_events:' || coalesce(p_limit, 100)::text);
  claim jsonb;
  run_id uuid;
  item record;
  replay_payload jsonb;
  processed_count integer := 0;
  conflict_count integer := 0;
  stale_count integer := 0;
  job_count integer := 0;
  payload jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  claim := public.claim_operation_request(clean_request_id, 'replay_all_job_events', request_hash);
  clean_request_id := claim ->> 'request_id';

  if coalesce((claim ->> 'claimed')::boolean, false) = false then
    if claim ->> 'status' = 'completed' then
      return coalesce(claim -> 'response_payload', '{}'::jsonb) || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('request_id', clean_request_id, 'processed', 0, 'status', claim ->> 'status', 'replayed', true);
  end if;

  insert into public.event_replay_runs (request_id, request_hash, replay_scope, status, metadata)
  values (clean_request_id, request_hash, 'bulk', 'running', jsonb_build_object('limit', coalesce(p_limit, 100), 'request_id', clean_request_id))
  returning id into run_id;

  for item in
    select j.id
    from public.jobs j
    where exists (
      select 1
      from public.job_events e
      where e.job_id = j.id
        and e.projected_status is not null
    )
    order by coalesce(j.snapshot_reconciled_at, to_timestamp(0)) asc, j.updated_at asc
    limit greatest(coalesce(p_limit, 100), 1)
  loop
    replay_payload := public.replay_job_events_internal(item.id, run_id, 'bulk-event-replay');
    job_count := job_count + 1;
    processed_count := processed_count + coalesce((replay_payload ->> 'processed_count')::integer, 0);
    conflict_count := conflict_count + coalesce((replay_payload ->> 'conflict_count')::integer, 0);
    stale_count := stale_count + coalesce((replay_payload ->> 'stale_rejected_count')::integer, 0);
  end loop;

  payload := jsonb_build_object(
    'request_id', clean_request_id,
    'run_id', run_id,
    'jobs_replayed', job_count,
    'processed_count', processed_count,
    'conflict_count', conflict_count,
    'stale_rejected_count', stale_count,
    'processed', processed_count + stale_count + conflict_count
  );

  update public.event_replay_runs
  set status = 'completed',
      finished_at = now(),
      processed_count = processed_count,
      conflict_count = conflict_count,
      stale_rejected_count = stale_count,
      metadata = metadata || payload
  where id = run_id;

  perform public.complete_operation_request(clean_request_id, 'completed', payload, null);
  return payload;
exception
  when others then
    if run_id is not null then
      update public.event_replay_runs
      set status = 'failed',
          finished_at = now(),
          error_message = sqlerrm,
          metadata = metadata || jsonb_build_object('sqlstate', sqlstate)
      where id = run_id;
    end if;
    if clean_request_id is not null then
      perform public.complete_operation_request(clean_request_id, 'failed', jsonb_build_object('request_id', clean_request_id), sqlerrm);
    end if;
    raise;
end;
$$;

create or replace function public.admin_replay_job_events(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  run_id uuid;
  replay_payload jsonb;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  insert into public.event_replay_runs (replay_scope, job_id, status, metadata)
  values ('admin-single', p_job_id, 'running', jsonb_build_object('admin_id', auth.uid()))
  returning id into run_id;

  replay_payload := public.replay_job_events_internal(p_job_id, run_id, 'admin-replay');

  update public.event_replay_runs
  set status = 'completed',
      finished_at = now(),
      processed_count = coalesce((replay_payload ->> 'processed_count')::integer, 0),
      conflict_count = coalesce((replay_payload ->> 'conflict_count')::integer, 0),
      stale_rejected_count = coalesce((replay_payload ->> 'stale_rejected_count')::integer, 0),
      metadata = metadata || replay_payload
  where id = run_id;

  return replay_payload || jsonb_build_object('run_id', run_id);
exception
  when others then
    if run_id is not null then
      update public.event_replay_runs
      set status = 'failed',
          finished_at = now(),
          error_message = sqlerrm,
          metadata = metadata || jsonb_build_object('sqlstate', sqlstate)
      where id = run_id;
    end if;
    raise;
end;
$$;

create or replace function public.detect_predictive_operational_risks()
returns table (
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
  where latest.completed_at is null
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

create or replace function public.refresh_predictive_operational_alerts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  count_alerts integer := 0;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  for item in select * from public.detect_predictive_operational_risks() loop
    perform public.upsert_operational_alert(
      item.alert_type,
      item.severity,
      item.reason,
      item.job_id,
      item.electrician_id,
      item.payment_id,
      null,
      null,
      item.metadata
    );
    count_alerts := count_alerts + 1;
  end loop;

  update public.operational_alerts a
  set status = 'resolved',
      resolved_at = coalesce(resolved_at, now()),
      metadata = metadata || jsonb_build_object('predictive_resolved_at', now())
  where status = 'open'
    and alert_type in ('predictive_pairing_risk', 'predictive_payment_backlog', 'automation_lag', 'projection_replay_due')
    and not exists (
      select 1
      from public.detect_predictive_operational_risks() risk
      where risk.alert_type = a.alert_type
        and risk.job_id is not distinct from a.job_id
        and risk.electrician_id is not distinct from a.electrician_id
        and risk.payment_id is not distinct from a.payment_id
    );

  return count_alerts;
end;
$$;

create or replace function public.refresh_operational_alerts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  count_alerts integer := 0;
begin
  for item in select * from public.detect_stuck_jobs() loop
    perform public.upsert_operational_alert(
      item.stuck_type,
      item.severity,
      item.reason,
      item.job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object('stuck_since', item.stuck_since)
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in select * from public.detect_snapshot_drift() loop
    perform public.upsert_operational_alert(
      'snapshot_drift',
      'warning',
      'Job snapshot differs from canonical event projection.',
      item.job_id,
      null,
      null,
      null,
      item.latest_event_id,
      jsonb_build_object(
        'ticket', item.ticket,
        'snapshot_status', item.snapshot_status,
        'event_status', item.event_status,
        'snapshot_version', item.snapshot_version,
        'event_version', item.event_version
      )
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select id, ticket, dispatch_attempts, last_dispatch_at
    from public.jobs
    where status = 'matching'
      and dispatch_attempts >= 3
  loop
    perform public.upsert_operational_alert(
      'failed_pairing',
      'critical',
      'Dispatch has retried this job multiple times.',
      item.id,
      null,
      null,
      null,
      null,
      jsonb_build_object(
        'ticket', item.ticket,
        'dispatch_attempts', item.dispatch_attempts,
        'last_dispatch_at', item.last_dispatch_at
      )
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select id, ticket, assigned_electrician_id, assignment_expires_at
    from public.jobs
    where status = 'assigned'
      and assignment_expires_at is not null
      and assignment_expires_at <= now()
  loop
    perform public.upsert_operational_alert(
      'expired_assignment',
      'warning',
      'An assignment expired before acceptance.',
      item.id,
      item.assigned_electrician_id,
      null,
      null,
      null,
      jsonb_build_object('ticket', item.ticket, 'assignment_expires_at', item.assignment_expires_at)
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select e.id, e.acceptance_score, e.response_score, e.quality_tier, latest.rejection_rate
    from public.electricians e
    join lateral (
      select s.rejection_rate
      from public.electrician_performance_snapshots s
      where s.electrician_id = e.id
      order by s.snapshot_at desc
      limit 1
    ) latest on true
    where latest.rejection_rate >= 50
       or e.quality_tier in ('Watch', 'Recovery')
       or (e.quality_penalty_until is not null and e.quality_penalty_until > now())
  loop
    perform public.upsert_operational_alert(
      'high_rejection_electrician',
      'warning',
      'VoltFriq quality signals need review.',
      null,
      item.id,
      null,
      null,
      null,
      jsonb_build_object(
        'rejection_rate', item.rejection_rate,
        'acceptance_score', item.acceptance_score,
        'response_score', item.response_score,
        'quality_tier', item.quality_tier
      )
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select id, job_id, failure_stage, created_at
    from public.upload_failures
    where created_at > now() - interval '24 hours'
  loop
    perform public.upsert_operational_alert(
      'upload_failure',
      'warning',
      'Recent upload failure needs review.',
      item.job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object('failure_id', item.id, 'failure_stage', item.failure_stage)
    );
    count_alerts := count_alerts + 1;
  end loop;

  count_alerts := count_alerts + public.refresh_predictive_operational_alerts();

  update public.operational_alerts
  set severity = 'critical',
      metadata = metadata || jsonb_build_object('auto_escalated_at', now())
  where status = 'open'
    and severity = 'warning'
    and alert_type in ('stuck_pairing', 'expired_assignment', 'failed_pairing', 'snapshot_drift', 'predictive_pairing_risk', 'predictive_payment_backlog', 'automation_lag')
    and last_seen_at < now() - interval '10 minutes';

  update public.operational_alerts a
  set status = 'resolved',
      resolved_at = coalesce(resolved_at, now())
  where status = 'open'
    and alert_type in ('stuck_pairing', 'expired_assignment', 'failed_pairing')
    and job_id is not null
    and exists (
      select 1
      from public.jobs j
      where j.id = a.job_id
        and (
          j.status in ('accepted', 'assessment_fee_pending', 'assessment_confirmed', 'en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated', 'cancelled')
          or (a.alert_type = 'expired_assignment' and not (j.status = 'assigned' and j.assignment_expires_at <= now()))
        )
    );

  update public.operational_alerts a
  set status = 'resolved',
      resolved_at = coalesce(resolved_at, now())
  where status = 'open'
    and alert_type = 'snapshot_drift'
    and job_id is not null
    and not exists (
      select 1 from public.detect_snapshot_drift() drift where drift.job_id = a.job_id
    );

  return count_alerts;
end;
$$;

create or replace function public.admin_operational_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  perform public.refresh_operational_alerts();

  with queue_counts as (
    select
      (select count(*) from public.job_payments where status = 'submitted') as pending_payments,
      (select count(*) from public.electricians where status = 'pending') as pending_electricians,
      (select count(*) from public.disputes where status = 'open') as open_disputes,
      (
        select count(*)
        from public.jobs
        where status = 'assigned'
          and assignment_expires_at is not null
          and assignment_expires_at <= now()
      ) as expired_assignments,
      (select count(*) from public.detect_stuck_jobs()) as stuck_jobs,
      (select count(*) from public.detect_snapshot_drift()) as snapshot_drift_jobs,
      (select count(*) from public.detect_predictive_operational_risks()) as predictive_alerts,
      (
        select count(*)
        from public.jobs
        where status = 'matching'
          and dispatch_attempts >= 3
      ) as failed_pairing_jobs,
      (
        select count(*)
        from public.operational_alerts
        where status = 'open'
          and severity = 'critical'
      ) as critical_alerts,
      (
        select count(*)
        from public.upload_failures
        where created_at > now() - interval '24 hours'
      ) as upload_failures_24h,
      (
        select coalesce(sum(greatest(dispatch_attempts - 1, 0)), 0)
        from public.jobs
        where created_at > now() - interval '7 days'
      ) as dispatch_retries_7d,
      (
        select count(*)
        from public.disputes
        where created_at > now() - interval '30 days'
      ) as disputes_30d,
      (
        select count(*)
        from public.jobs
        where created_at > now() - interval '30 days'
      ) as jobs_30d,
      (
        select count(*)
        from public.operational_automation_runs
        where status = 'failed'
          and started_at > now() - interval '24 hours'
      ) as automation_failures_24h,
      (
        select extract(epoch from (now() - max(finished_at)))
        from public.operational_automation_runs
        where status = 'completed'
      ) as automation_last_run_age_seconds,
      (
        select extract(epoch from (now() - max(finished_at)))
        from public.event_replay_runs
        where status = 'completed'
      ) as event_replay_last_run_age_seconds,
      (
        select count(*)
        from public.event_replay_runs
        where status = 'failed'
          and started_at > now() - interval '24 hours'
      ) as event_replay_failures_24h
  ),
  created_events as (
    select job_id, min(created_at) as created_at
    from public.job_events
    where event_type = 'JOB_CREATED'
    group by job_id
  ),
  assigned_events as (
    select job_id, min(created_at) as assigned_at
    from public.job_events
    where event_type = 'ELECTRICIAN_ASSIGNED'
    group by job_id
  ),
  accepted_events as (
    select job_id, min(created_at) as accepted_at
    from public.job_events
    where event_type = 'ASSIGNMENT_ACCEPTED'
    group by job_id
  ),
  rejected_events as (
    select count(*)::numeric as rejected_count
    from public.job_events
    where event_type = 'ASSIGNMENT_REJECTED'
      and created_at > now() - interval '30 days'
  ),
  assignment_events as (
    select count(*)::numeric as assigned_count
    from public.job_events
    where event_type = 'ELECTRICIAN_ASSIGNED'
      and created_at > now() - interval '30 days'
  ),
  payment_delays as (
    select avg(extract(epoch from (verified_at - created_at))) as avg_delay
    from public.job_payments
    where status = 'verified'
      and verified_at is not null
      and created_at > now() - interval '30 days'
  ),
  response_quality as (
    select avg(coalesce(response_score, response_rate, 100)) as average_response_score
    from public.electricians
  )
  select jsonb_build_object(
    'queues', jsonb_build_object(
      'pending_payments', coalesce(q.pending_payments, 0),
      'pending_electricians', coalesce(q.pending_electricians, 0),
      'stuck_pairing_jobs', coalesce(q.stuck_jobs, 0),
      'failed_pairing_jobs', coalesce(q.failed_pairing_jobs, 0),
      'open_disputes', coalesce(q.open_disputes, 0),
      'expired_assignments', coalesce(q.expired_assignments, 0),
      'snapshot_drift_jobs', coalesce(q.snapshot_drift_jobs, 0),
      'predictive_alerts', coalesce(q.predictive_alerts, 0),
      'critical_alerts', coalesce(q.critical_alerts, 0)
    ),
    'metrics', jsonb_build_object(
      'average_time_to_assign_seconds', coalesce(round(avg(extract(epoch from (a.assigned_at - c.created_at)))::numeric, 2), 0),
      'average_time_to_accept_seconds', coalesce(round(avg(extract(epoch from (ac.accepted_at - a.assigned_at)))::numeric, 2), 0),
      'rejection_rate', case when assign.assigned_count > 0 then round((rejects.rejected_count / assign.assigned_count) * 100, 2) else 0 end,
      'payment_verification_delay_seconds', coalesce(round(pay.avg_delay::numeric, 2), 0),
      'stuck_jobs_count', coalesce(q.stuck_jobs, 0),
      'dispatch_retries_7d', coalesce(q.dispatch_retries_7d, 0),
      'upload_failures_24h', coalesce(q.upload_failures_24h, 0),
      'dispute_rate_30d', case when q.jobs_30d > 0 then round((q.disputes_30d::numeric / q.jobs_30d::numeric) * 100, 2) else 0 end,
      'electrician_response_quality', coalesce(round(resp.average_response_score::numeric, 2), 100),
      'snapshot_drift_jobs', coalesce(q.snapshot_drift_jobs, 0),
      'predictive_alerts', coalesce(q.predictive_alerts, 0),
      'automation_failures_24h', coalesce(q.automation_failures_24h, 0),
      'automation_last_run_age_seconds', coalesce(round(q.automation_last_run_age_seconds::numeric, 2), 0),
      'event_replay_last_run_age_seconds', coalesce(round(q.event_replay_last_run_age_seconds::numeric, 2), 0),
      'event_replay_failures_24h', coalesce(q.event_replay_failures_24h, 0),
      'system_health_score', greatest(
        0,
        100
        - least(coalesce(q.critical_alerts, 0) * 10, 40)
        - least(coalesce(q.stuck_jobs, 0) * 6, 30)
        - least(coalesce(q.failed_pairing_jobs, 0) * 8, 24)
        - least(coalesce(q.predictive_alerts, 0) * 3, 18)
        - least(coalesce(q.upload_failures_24h, 0) * 2, 12)
        - least(coalesce(q.automation_failures_24h, 0) * 8, 24)
        - least(coalesce(q.event_replay_failures_24h, 0) * 8, 24)
      )
    )
  )
  into result
  from queue_counts q
  left join created_events c on true
  left join assigned_events a on a.job_id = c.job_id
  left join accepted_events ac on ac.job_id = c.job_id
  cross join rejected_events rejects
  cross join assignment_events assign
  cross join payment_delays pay
  cross join response_quality resp
  group by q.pending_payments, q.pending_electricians, q.open_disputes, q.expired_assignments, q.stuck_jobs,
    q.snapshot_drift_jobs, q.predictive_alerts, q.failed_pairing_jobs, q.critical_alerts, q.upload_failures_24h,
    q.dispatch_retries_7d, q.disputes_30d, q.jobs_30d, q.automation_failures_24h, q.automation_last_run_age_seconds,
    q.event_replay_last_run_age_seconds, q.event_replay_failures_24h,
    rejects.rejected_count, assign.assigned_count, pay.avg_delay, resp.average_response_score;

  return coalesce(result, jsonb_build_object('queues', '{}'::jsonb, 'metrics', '{}'::jsonb));
end;
$$;

create or replace function public.admin_operational_queues()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  perform public.refresh_operational_alerts();

  select jsonb_build_object(
    'pending_payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'job_id', p.job_id,
        'ticket', j.ticket,
        'payment_type', p.payment_type,
        'amount', p.amount,
        'created_at', p.created_at,
        'age_seconds', extract(epoch from (now() - p.created_at))
      ) order by p.created_at asc)
      from public.job_payments p
      join public.jobs j on j.id = p.job_id
      where p.status = 'submitted'
    ), '[]'::jsonb),
    'pending_electricians', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'profile_id', e.profile_id,
        'display_name', coalesce(nullif(p.full_name, ''), p.email, 'VoltFriq applicant'),
        'created_at', e.created_at,
        'service_areas', e.service_areas,
        'onboarding_completed', e.onboarding_completed
      ) order by e.created_at asc)
      from public.electricians e
      join public.profiles p on p.id = e.profile_id
      where e.status = 'pending'
    ), '[]'::jsonb),
    'stuck_jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job_id', s.job_id,
        'ticket', j.ticket,
        'status', j.status,
        'stuck_type', s.stuck_type,
        'severity', s.severity,
        'reason', s.reason,
        'stuck_since', s.stuck_since,
        'action', 'retry_dispatch'
      ) order by s.stuck_since asc)
      from public.detect_stuck_jobs() s
      join public.jobs j on j.id = s.job_id
    ), '[]'::jsonb),
    'failed_pairing_jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job_id', j.id,
        'ticket', j.ticket,
        'status', j.status,
        'dispatch_attempts', j.dispatch_attempts,
        'last_dispatch_at', j.last_dispatch_at,
        'action', 'retry_dispatch'
      ) order by j.dispatch_attempts desc, j.last_dispatch_at asc)
      from public.jobs j
      where j.status = 'matching'
        and j.dispatch_attempts >= 3
    ), '[]'::jsonb),
    'snapshot_drift_jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job_id', s.job_id,
        'ticket', s.ticket,
        'snapshot_status', s.snapshot_status,
        'event_status', s.event_status,
        'latest_event_id', s.latest_event_id,
        'latest_event_at', s.latest_event_at,
        'action', 'reconcile_state'
      ) order by s.latest_event_at asc)
      from public.detect_snapshot_drift() s
    ), '[]'::jsonb),
    'predictive_alerts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'alert_type', risk.alert_type,
        'severity', risk.severity,
        'reason', risk.reason,
        'job_id', risk.job_id,
        'electrician_id', risk.electrician_id,
        'payment_id', risk.payment_id,
        'metadata', risk.metadata,
        'action', case
          when risk.alert_type in ('predictive_pairing_risk', 'projection_replay_due') and risk.job_id is not null then 'review_dispatch'
          when risk.alert_type = 'predictive_payment_backlog' then 'review_payment'
          else 'review'
        end
      ) order by case risk.severity when 'critical' then 0 when 'warning' then 1 else 2 end)
      from public.detect_predictive_operational_risks() risk
    ), '[]'::jsonb),
    'payment_backlog', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'job_id', p.job_id,
        'ticket', j.ticket,
        'created_at', p.created_at,
        'age_seconds', extract(epoch from (now() - p.created_at))
      ) order by p.created_at asc)
      from public.job_payments p
      join public.jobs j on j.id = p.job_id
      where p.status = 'submitted'
        and p.created_at < now() - interval '30 minutes'
    ), '[]'::jsonb),
    'open_disputes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id,
        'job_id', d.job_id,
        'ticket', j.ticket,
        'issue_type', d.issue_type,
        'created_at', d.created_at
      ) order by d.created_at asc)
      from public.disputes d
      left join public.jobs j on j.id = d.job_id
      where d.status = 'open'
    ), '[]'::jsonb),
    'expired_assignments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job_id', j.id,
        'ticket', j.ticket,
        'assigned_electrician_id', j.assigned_electrician_id,
        'assignment_expires_at', j.assignment_expires_at,
        'action', 'retry_dispatch'
      ) order by j.assignment_expires_at asc)
      from public.jobs j
      where j.status = 'assigned'
        and j.assignment_expires_at is not null
        and j.assignment_expires_at <= now()
    ), '[]'::jsonb),
    'high_rejection_electricians', coalesce((
      select jsonb_agg(jsonb_build_object(
        'electrician_id', e.id,
        'profile_id', e.profile_id,
        'display_name', coalesce(nullif(p.full_name, ''), p.email, 'VoltFriq'),
        'acceptance_score', e.acceptance_score,
        'response_score', e.response_score,
        'completion_score', e.completion_score,
        'dispute_score', e.dispute_score,
        'payout_confidence_score', e.payout_confidence_score,
        'quality_tier', e.quality_tier,
        'quality_penalty_until', e.quality_penalty_until,
        'rejection_rate', latest.rejection_rate
      ) order by latest.rejection_rate desc)
      from public.electricians e
      join public.profiles p on p.id = e.profile_id
      join lateral (
        select s.rejection_rate
        from public.electrician_performance_snapshots s
        where s.electrician_id = e.id
        order by s.snapshot_at desc
        limit 1
      ) latest on true
      where latest.rejection_rate >= 50
         or e.quality_tier in ('Watch', 'Recovery')
         or (e.quality_penalty_until is not null and e.quality_penalty_until > now())
    ), '[]'::jsonb),
    'upload_failures', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', f.id,
        'job_id', f.job_id,
        'failure_stage', f.failure_stage,
        'error_message', f.error_message,
        'created_at', f.created_at
      ) order by f.created_at desc)
      from public.upload_failures f
      where f.created_at > now() - interval '24 hours'
    ), '[]'::jsonb),
    'event_replay_runs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id,
        'request_id', r.request_id,
        'replay_scope', r.replay_scope,
        'job_id', r.job_id,
        'status', r.status,
        'processed_count', r.processed_count,
        'stale_rejected_count', r.stale_rejected_count,
        'started_at', r.started_at,
        'finished_at', r.finished_at
      ) order by r.started_at desc)
      from public.event_replay_runs r
      where r.started_at > now() - interval '24 hours'
      limit 20
    ), '[]'::jsonb),
    'alerts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'alert_type', a.alert_type,
        'severity', a.severity,
        'job_id', a.job_id,
        'electrician_id', a.electrician_id,
        'payment_id', a.payment_id,
        'dispute_id', a.dispute_id,
        'message', a.message,
        'last_seen_at', a.last_seen_at,
        'age_seconds', extract(epoch from (now() - a.last_seen_at)),
        'action', case
          when a.alert_type in ('stuck_pairing', 'failed_pairing', 'expired_assignment', 'predictive_pairing_risk') and a.job_id is not null then 'retry_dispatch'
          when a.alert_type in ('snapshot_drift', 'projection_replay_due') and a.job_id is not null then 'reconcile_state'
          when a.alert_type = 'predictive_payment_backlog' then 'review_payment'
          else 'review'
        end
      ) order by case a.severity when 'critical' then 0 when 'warning' then 1 else 2 end, a.last_seen_at asc)
      from public.operational_alerts a
      where a.status = 'open'
    ), '[]'::jsonb)
  ) into payload;

  return payload;
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
  resolved_count integer := 0;
  total_count integer := 0;
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
  prioritized_count := public.prioritize_dispatch_queue(greatest(least(coalesce(p_limit, 100) * 2, 500), 1));
  synced_count := public.sync_all_job_state_projections(greatest(coalesce(p_limit, 100), 1));
  dispatch_count := public.process_dispatch_queue();
  alert_count := public.refresh_operational_alerts();
  escalated_count := public.apply_operational_escalations();

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

  total_count := replay_count + rebuilt_count + prioritized_count + synced_count + dispatch_count + alert_count + escalated_count + resolved_count;

  payload := jsonb_build_object(
    'request_id', clean_request_id,
    'run_id', run_id,
    'event_replay', replay_payload,
    'event_replay_processed', replay_count,
    'projection_rebuilds', rebuilt_count,
    'queue_prioritized', prioritized_count,
    'projection_syncs', synced_count,
    'dispatch_actions', dispatch_count,
    'alerts_refreshed', alert_count,
    'alerts_escalated', escalated_count,
    'alerts_resolved', resolved_count,
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

create or replace function public.run_operational_recovery(
  p_limit integer default 500,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_hash text := md5('run_operational_recovery:' || coalesce(p_limit, 500)::text);
  claim jsonb;
  replay_payload jsonb := '{}'::jsonb;
  rebuilt_count integer := 0;
  automation_payload jsonb;
  payload jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  claim := public.claim_operation_request(clean_request_id, 'run_operational_recovery', request_hash);
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

  update public.operation_requests
  set status = 'failed',
      updated_at = now(),
      error_message = 'Recovered stale running request'
  where status = 'running'
    and request_id <> clean_request_id
    and updated_at < now() - interval '10 minutes';

  replay_payload := public.replay_all_job_events(
    least(greatest(coalesce(p_limit, 500), 1), 250),
    clean_request_id || ':event-replay'
  );
  rebuilt_count := public.rebuild_all_job_state_projections(greatest(coalesce(p_limit, 500), 1));
  automation_payload := public.run_operational_automation(
    least(greatest(coalesce(p_limit, 500), 1), 500),
    clean_request_id || ':automation'
  );

  payload := jsonb_build_object(
    'request_id', clean_request_id,
    'event_replay', replay_payload,
    'projection_rebuilds', rebuilt_count,
    'automation', automation_payload,
    'processed',
      rebuilt_count
      + coalesce((replay_payload ->> 'processed')::integer, 0)
      + coalesce((automation_payload ->> 'processed')::integer, 0)
  );

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
    raise;
end;
$$;

revoke all on table public.event_replay_runs from public, anon, authenticated;
grant select on table public.event_replay_runs to authenticated;
grant all on table public.event_replay_runs to service_role;

revoke all on function public.replay_job_events_internal(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.replay_job_events_internal(uuid,uuid,text) to service_role;

revoke all on function public.replay_job_events(uuid,text) from public, anon, authenticated;
grant execute on function public.replay_job_events(uuid,text) to service_role;

revoke all on function public.replay_all_job_events(integer,text) from public, anon, authenticated;
grant execute on function public.replay_all_job_events(integer,text) to service_role;

revoke all on function public.admin_replay_job_events(uuid) from public, anon, authenticated;
grant execute on function public.admin_replay_job_events(uuid) to authenticated, service_role;

revoke all on function public.detect_predictive_operational_risks() from public, anon, authenticated;
grant execute on function public.detect_predictive_operational_risks() to service_role;

revoke all on function public.refresh_predictive_operational_alerts() from public, anon, authenticated;
grant execute on function public.refresh_predictive_operational_alerts() to service_role;

revoke all on function public.prepare_job_event_version() from public, anon, authenticated;
grant execute on function public.prepare_job_event_version() to service_role;

revoke all on function public.project_job_event_state() from public, anon, authenticated;
grant execute on function public.project_job_event_state() to service_role;

revoke all on function public.refresh_operational_alerts() from public, anon, authenticated;
grant execute on function public.refresh_operational_alerts() to service_role;

revoke all on function public.admin_operational_summary() from public, anon, authenticated;
grant execute on function public.admin_operational_summary() to authenticated, service_role;

revoke all on function public.admin_operational_queues() from public, anon, authenticated;
grant execute on function public.admin_operational_queues() to authenticated, service_role;

revoke all on function public.run_operational_automation(integer,text) from public, anon, authenticated;
grant execute on function public.run_operational_automation(integer,text) to service_role;

revoke all on function public.run_operational_recovery(integer,text) from public, anon, authenticated;
grant execute on function public.run_operational_recovery(integer,text) to service_role;

select pg_notify('pgrst', 'reload schema');
