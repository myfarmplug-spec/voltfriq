-- Platform resilience engineering:
-- - request ids and replay ledger for idempotent backend operations
-- - stronger event replay protection
-- - rebuildable job state projections
-- - queue prioritization and escalation automation
-- - recovery RPC for service-role operational repair

alter table public.job_events
  add column if not exists request_id text,
  add column if not exists request_hash text,
  add column if not exists replay_of_event_id uuid references public.job_events(id) on delete set null;

create unique index if not exists job_events_request_id_uidx
  on public.job_events(request_id)
  where request_id is not null;

create index if not exists job_events_request_hash_idx
  on public.job_events(request_hash)
  where request_hash is not null;

alter table public.jobs
  add column if not exists dispatch_priority_score numeric(12,2) not null default 0,
  add column if not exists dispatch_priority_reason text,
  add column if not exists dispatch_priority_updated_at timestamptz;

create index if not exists jobs_dispatch_priority_idx
  on public.jobs(dispatch_priority_score desc, created_at asc)
  where status in ('requested', 'matching', 'assigned');

alter table public.operational_alerts
  add column if not exists escalation_level integer not null default 0,
  add column if not exists escalated_at timestamptz,
  add column if not exists next_review_at timestamptz;

create index if not exists operational_alerts_escalation_idx
  on public.operational_alerts(status, escalation_level desc, next_review_at asc);

alter table public.operational_automation_runs
  add column if not exists request_id text,
  add column if not exists request_hash text;

create unique index if not exists operational_automation_runs_request_id_uidx
  on public.operational_automation_runs(request_id)
  where request_id is not null;

create table if not exists public.operation_requests (
  id uuid primary key default gen_random_uuid(),
  request_id text not null,
  operation_name text not null,
  request_hash text not null,
  status text not null default 'running',
  response_payload jsonb,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint operation_requests_status_check check (status in ('running', 'completed', 'failed'))
);

alter table public.operation_requests enable row level security;

drop policy if exists "operation requests admin read" on public.operation_requests;
create policy "operation requests admin read"
  on public.operation_requests
  for select
  to authenticated
  using (public.is_admin());

drop policy if exists "operation requests service write" on public.operation_requests;
create policy "operation requests service write"
  on public.operation_requests
  for all
  to service_role
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create unique index if not exists operation_requests_request_id_uidx
  on public.operation_requests(request_id);

create index if not exists operation_requests_status_updated_idx
  on public.operation_requests(status, updated_at desc);

create or replace function public.sanitize_request_id(p_request_id text)
returns text
language sql
immutable
set search_path = public
as $$
  select nullif(left(regexp_replace(coalesce(p_request_id, ''), '[^a-zA-Z0-9:_\\.-]', '', 'g'), 160), '');
$$;

create or replace function public.claim_operation_request(
  p_request_id text,
  p_operation_name text,
  p_request_hash text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_row public.operation_requests;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  if clean_request_id is null then
    clean_request_id := 'auto:' || replace(gen_random_uuid()::text, '-', '');
  end if;

  select * into request_row
  from public.operation_requests
  where request_id = clean_request_id
  for update;

  if found then
    if request_row.operation_name <> p_operation_name or request_row.request_hash <> p_request_hash then
      raise exception 'Request id % was already used for a different operation', clean_request_id;
    end if;

    return jsonb_build_object(
      'request_id', clean_request_id,
      'claimed', false,
      'status', request_row.status,
      'response_payload', request_row.response_payload
    );
  end if;

  insert into public.operation_requests (request_id, operation_name, request_hash)
  values (clean_request_id, p_operation_name, p_request_hash)
  returning * into request_row;

  return jsonb_build_object(
    'request_id', clean_request_id,
    'claimed', true,
    'status', request_row.status
  );
end;
$$;

create or replace function public.complete_operation_request(
  p_request_id text,
  p_status text,
  p_response_payload jsonb default null,
  p_error_message text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_row public.operation_requests;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  if p_status not in ('completed', 'failed') then
    raise exception 'Unsupported operation request status';
  end if;

  update public.operation_requests
  set status = p_status,
      response_payload = p_response_payload,
      error_message = p_error_message,
      updated_at = now(),
      completed_at = case when p_status = 'completed' then now() else completed_at end
  where request_id = clean_request_id
  returning * into request_row;

  if not found then
    raise exception 'Operation request not found';
  end if;

  return jsonb_build_object(
    'request_id', request_row.request_id,
    'status', request_row.status,
    'response_payload', request_row.response_payload
  );
end;
$$;

create or replace function public.prepare_job_event_version()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  latest_version integer := 0;
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

create or replace function public.log_job_event(
  p_job_id uuid,
  p_event_type text,
  p_actor_role text default null,
  p_actor_id uuid default auth.uid(),
  p_public_message text default null,
  p_internal_note text default null,
  p_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  event_id uuid;
  existing_event public.job_events;
  job_row public.jobs;
  job_status_value public.job_status;
  event_public_message text;
  metadata_value jsonb := coalesce(p_metadata, '{}'::jsonb);
  idempotency text := nullif(btrim(coalesce(p_metadata->>'idempotency_key', '')), '');
  request_id_value text := public.sanitize_request_id(coalesce(p_metadata ->> 'request_id', p_metadata ->> 'requestId', p_metadata ->> 'operation_request_id'));
  request_hash_value text;
  severity_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'severity', '')), ''), 'info');
  visibility_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'visibility', '')), ''), 'public');
  source_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'source', '')), ''), 'app');
  expected_state_version integer;
begin
  metadata_value := metadata_value - 'request_id' - 'requestId' - 'operation_request_id';
  request_hash_value := md5(jsonb_build_object(
    'job_id', p_job_id,
    'event_type', p_event_type,
    'metadata', metadata_value - 'idempotency_key' - 'severity' - 'visibility' - 'source'
  )::text);

  if request_id_value is not null then
    select * into existing_event from public.job_events where request_id = request_id_value;
    if existing_event.id is not null then
      if existing_event.request_hash is distinct from request_hash_value then
        raise exception 'Request id % was already used for a different event', request_id_value;
      end if;
      return existing_event.id;
    end if;
  end if;

  if idempotency is not null then
    select * into existing_event from public.job_events where idempotency_key = idempotency;
    if existing_event.id is not null then
      return existing_event.id;
    end if;
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  job_status_value := job_row.status;

  if metadata_value ->> 'expected_state_version' ~ '^[0-9]+$' then
    expected_state_version := (metadata_value ->> 'expected_state_version')::integer;
    if expected_state_version <> coalesce(job_row.state_version, 0) then
      perform public.upsert_operational_alert(
        'state_conflict',
        'warning',
        'Stale job event write blocked.',
        p_job_id,
        null,
        null,
        null,
        null,
        jsonb_build_object(
          'expected_state_version', expected_state_version,
          'actual_state_version', coalesce(job_row.state_version, 0),
          'event_type', p_event_type,
          'source', source_value,
          'request_id', request_id_value
        )
      );
      raise exception 'This job changed from version % to %. Refresh and try again.',
        expected_state_version,
        coalesce(job_row.state_version, 0);
    end if;
  end if;

  event_public_message := coalesce(
    nullif(btrim(p_public_message), ''),
    public.public_message_for_job_event(p_event_type, job_status_value, p_internal_note)
  );
  event_public_message := public.public_message_for_job_event(p_event_type, job_status_value, event_public_message);

  metadata_value := metadata_value - 'idempotency_key' - 'severity' - 'visibility' - 'source';

  insert into public.job_events (
    job_id,
    event_type,
    actor_role,
    actor_id,
    public_message,
    internal_note,
    metadata,
    idempotency_key,
    request_id,
    request_hash,
    severity,
    visibility,
    source
  )
  values (
    p_job_id,
    p_event_type,
    coalesce(nullif(p_actor_role, ''), public.actor_role_for_profile(p_actor_id)),
    p_actor_id,
    event_public_message,
    nullif(btrim(p_internal_note), ''),
    metadata_value,
    idempotency,
    request_id_value,
    request_hash_value,
    case when severity_value in ('info', 'warning', 'critical') then severity_value else 'info' end,
    case when visibility_value in ('public', 'internal') then visibility_value else 'public' end,
    source_value
  )
  returning id into event_id;

  return event_id;
exception
  when unique_violation then
    if request_id_value is not null then
      select * into existing_event from public.job_events where request_id = request_id_value;
      if existing_event.id is not null then
        if existing_event.request_hash is distinct from request_hash_value then
          raise exception 'Request id % was already used for a different event', request_id_value;
        end if;
        return existing_event.id;
      end if;
    end if;
    if idempotency is not null then
      select id into event_id from public.job_events where idempotency_key = idempotency;
      return event_id;
    end if;
    raise;
end;
$$;

create or replace function public.rebuild_job_state_projection(
  p_job_id uuid,
  p_reason text default 'projection-rebuild'
) returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  event_row public.job_events;
  job_row public.jobs;
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

  select * into event_row
  from public.job_events
  where job_id = p_job_id
    and projected_status is not null
  order by transition_to_version desc, event_sequence desc
  limit 1;

  if not found then
    update public.jobs
    set snapshot_reconciled_at = now()
    where id = p_job_id
    returning * into job_row;
    return job_row;
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
    p_job_id,
    event_row.projected_status,
    event_row.id,
    event_row.event_sequence,
    coalesce(event_row.transition_to_version, 0),
    now(),
    jsonb_build_object('rebuilt', true, 'reason', coalesce(nullif(btrim(p_reason), ''), 'projection-rebuild'))
  )
  on conflict (job_id) do update
  set projected_status = excluded.projected_status,
      event_id = excluded.event_id,
      event_sequence = excluded.event_sequence,
      state_version = excluded.state_version,
      projected_at = excluded.projected_at,
      metadata = public.job_state_projections.metadata || excluded.metadata;

  return public.sync_job_state_projection(p_job_id, p_reason);
end;
$$;

create or replace function public.rebuild_all_job_state_projections(p_limit integer default 500)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  rebuilt_count integer := 0;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  for item in
    select j.id
    from public.jobs j
    left join public.job_state_projections p on p.job_id = j.id
    where exists (
      select 1 from public.job_events e
      where e.job_id = j.id
        and e.projected_status is not null
    )
    order by coalesce(p.snapshot_synced_at, to_timestamp(0)) asc, j.updated_at asc
    limit greatest(coalesce(p_limit, 500), 1)
  loop
    perform public.rebuild_job_state_projection(item.id, 'bulk-projection-rebuild');
    rebuilt_count := rebuilt_count + 1;
  end loop;

  return rebuilt_count;
end;
$$;

create or replace function public.admin_rebuild_job_projection(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;
  return public.rebuild_job_state_projection(p_job_id, 'admin-rebuild');
end;
$$;

create or replace function public.prioritize_dispatch_queue(p_limit integer default 200)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_count integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  with ranked as (
    select
      j.id,
      (
        case j.urgency
          when 'emergency' then 120
          when 'today' then 70
          else 35
        end
        + least(extract(epoch from (now() - j.created_at)) / 60, 240)
        + coalesce(j.dispatch_attempts, 0) * 18
        + case when j.status = 'assigned' and j.assignment_expires_at <= now() then 80 else 0 end
        + case when exists (
          select 1 from public.disputes d where d.job_id = j.id and d.status = 'open'
        ) then 35 else 0 end
      )::numeric(12,2) as score,
      case
        when j.status = 'assigned' and j.assignment_expires_at <= now() then 'expired_assignment'
        when coalesce(j.dispatch_attempts, 0) >= 3 then 'dispatch_retry'
        when j.urgency = 'emergency' then 'emergency'
        else 'standard'
      end as reason
    from public.jobs j
    where j.status in ('requested', 'matching', 'assigned')
    order by j.created_at asc
    limit greatest(coalesce(p_limit, 200), 1)
  )
  update public.jobs j
  set dispatch_priority_score = ranked.score,
      dispatch_priority_reason = ranked.reason,
      dispatch_priority_updated_at = now()
  from ranked
  where j.id = ranked.id;

  get diagnostics updated_count = row_count;
  return updated_count;
end;
$$;

create or replace function public.apply_operational_escalations()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_count integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  update public.operational_alerts
  set escalation_level = case
        when severity = 'critical' and last_seen_at < now() - interval '30 minutes' then greatest(escalation_level, 3)
        when severity = 'critical' then greatest(escalation_level, 2)
        when last_seen_at < now() - interval '15 minutes' then greatest(escalation_level, 1)
        else escalation_level
      end,
      escalated_at = case
        when escalation_level = 0
          and (
            severity = 'critical'
            or last_seen_at < now() - interval '15 minutes'
          ) then now()
        else escalated_at
      end,
      next_review_at = case
        when severity = 'critical' then now() + interval '5 minutes'
        when last_seen_at < now() - interval '15 minutes' then now() + interval '10 minutes'
        else now() + interval '30 minutes'
      end,
      metadata = metadata || jsonb_build_object('last_escalation_scan_at', now())
  where status = 'open';

  get diagnostics updated_count = row_count;
  return updated_count;
end;
$$;

drop function if exists public.run_operational_automation(integer);

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

  total_count := rebuilt_count + prioritized_count + synced_count + dispatch_count + alert_count + escalated_count + resolved_count;

  payload := jsonb_build_object(
    'request_id', clean_request_id,
    'run_id', run_id,
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

  rebuilt_count := public.rebuild_all_job_state_projections(greatest(coalesce(p_limit, 500), 1));
  automation_payload := public.run_operational_automation(
    least(greatest(coalesce(p_limit, 500), 1), 500),
    clean_request_id || ':automation'
  );

  payload := jsonb_build_object(
    'request_id', clean_request_id,
    'projection_rebuilds', rebuilt_count,
    'automation', automation_payload,
    'processed', rebuilt_count + coalesce((automation_payload ->> 'processed')::integer, 0)
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

create or replace function public.process_dispatch_queue()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  expired_job record;
  matching_job record;
  processed_count integer := 0;
begin
  perform public.sync_all_job_state_projections(100);
  perform public.prioritize_dispatch_queue(200);
  perform public.refresh_operational_alerts();

  for expired_job in
    select id, assigned_electrician_id, current_assignment_event_id, current_assignment_token
    from public.jobs
    where status = 'assigned'
      and assignment_expires_at is not null
      and assignment_expires_at <= now()
    order by dispatch_priority_score desc, assignment_expires_at asc
    for update skip locked
  loop
    update public.jobs
    set status = 'matching',
        assigned_electrician_id = null,
        assignment_expires_at = null,
        current_assignment_event_id = null,
        current_assignment_token = null,
        state_version = coalesce(state_version, 0) + 1,
        updated_at = now()
    where id = expired_job.id
      and status = 'assigned'
      and assignment_expires_at is not null
      and assignment_expires_at <= now();

    perform public.log_job_event(
      expired_job.id,
      'ASSIGNMENT_EXPIRED',
      'system',
      auth.uid(),
      'Still finding a verified VoltFriq near you.',
      'Assigned VoltFriq did not respond within 5 minutes. Re-dispatch started.',
      jsonb_build_object(
        'electrician_id', expired_job.assigned_electrician_id,
        'assignment_event_id', expired_job.current_assignment_event_id,
        'assignment_token', expired_job.current_assignment_token,
        'next_status', 'matching',
        'source', 'dispatch_queue',
        'severity', 'warning',
        'idempotency_key', 'assignment-expired:' || expired_job.id::text || ':' || coalesce(expired_job.current_assignment_event_id::text, coalesce(expired_job.assigned_electrician_id::text, 'none'))
      )
    );

    perform public.dispatch_job_internal(expired_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  for matching_job in
    select id
    from public.jobs
    where status = 'matching'
      and assigned_electrician_id is null
      and (
        coalesce(array_length(candidate_queue, 1), 0) > 0
        or coalesce(last_dispatch_at, updated_at, created_at) < now() - interval '5 minutes'
      )
    order by dispatch_priority_score desc, created_at asc
    for update skip locked
  loop
    perform public.dispatch_job_internal(matching_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  perform public.refresh_operational_alerts();
  return processed_count;
end;
$$;

revoke all on table public.operation_requests from public, anon, authenticated;
grant select on table public.operation_requests to authenticated;
grant all on table public.operation_requests to service_role;

revoke all on function public.sanitize_request_id(text) from public, anon, authenticated;
grant execute on function public.sanitize_request_id(text) to service_role;

revoke all on function public.claim_operation_request(text,text,text) from public, anon, authenticated;
grant execute on function public.claim_operation_request(text,text,text) to service_role;

revoke all on function public.complete_operation_request(text,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.complete_operation_request(text,text,jsonb,text) to service_role;

revoke all on function public.rebuild_job_state_projection(uuid,text) from public, anon, authenticated;
grant execute on function public.rebuild_job_state_projection(uuid,text) to authenticated, service_role;

revoke all on function public.rebuild_all_job_state_projections(integer) from public, anon, authenticated;
grant execute on function public.rebuild_all_job_state_projections(integer) to authenticated, service_role;

revoke all on function public.admin_rebuild_job_projection(uuid) from public, anon, authenticated;
grant execute on function public.admin_rebuild_job_projection(uuid) to authenticated, service_role;

revoke all on function public.prioritize_dispatch_queue(integer) from public, anon, authenticated;
grant execute on function public.prioritize_dispatch_queue(integer) to service_role;

revoke all on function public.apply_operational_escalations() from public, anon, authenticated;
grant execute on function public.apply_operational_escalations() to service_role;

revoke all on function public.run_operational_automation(integer,text) from public, anon, authenticated;
grant execute on function public.run_operational_automation(integer,text) to service_role;

revoke all on function public.run_operational_recovery(integer,text) from public, anon, authenticated;
grant execute on function public.run_operational_recovery(integer,text) to service_role;

revoke all on function public.prepare_job_event_version() from public, anon, authenticated;
grant execute on function public.prepare_job_event_version() to service_role;

revoke all on function public.project_job_event_state() from public, anon, authenticated;
grant execute on function public.project_job_event_state() to service_role;

revoke all on function public.log_job_event(uuid,text,text,uuid,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.log_job_event(uuid,text,text,uuid,text,text,jsonb) to service_role;

revoke all on function public.process_dispatch_queue() from public, anon, authenticated;
grant execute on function public.process_dispatch_queue() to service_role;

select pg_notify('pgrst', 'reload schema');
