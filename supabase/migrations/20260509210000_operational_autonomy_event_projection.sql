-- Operational autonomy:
-- - explicit job event sequencing and state versions
-- - derived job_state_projections table
-- - stale transition rejection by expected state version
-- - cron-safe automation loop for projection sync, retry, escalation, and alerts

create sequence if not exists public.job_events_event_sequence_seq as bigint;

alter table public.job_events
  add column if not exists event_sequence bigint,
  add column if not exists transition_from_version integer,
  add column if not exists transition_to_version integer,
  add column if not exists projected_status public.job_status,
  add column if not exists projected_at timestamptz;

alter sequence public.job_events_event_sequence_seq
  owned by public.job_events.event_sequence;

with ranked as (
  select id, row_number() over (order by created_at, id)::bigint as sequence_value
  from public.job_events
  where event_sequence is null
)
update public.job_events e
set event_sequence = ranked.sequence_value
from ranked
where e.id = ranked.id;

select setval(
  'public.job_events_event_sequence_seq'::regclass,
  greatest((select coalesce(max(event_sequence), 0) + 1 from public.job_events), 1),
  false
);

alter table public.job_events
  alter column event_sequence set default nextval('public.job_events_event_sequence_seq'::regclass),
  alter column event_sequence set not null;

with versioned as (
  select
    e.id,
    coalesce(
      case
        when coalesce(e.metadata ->> 'state_version', '') ~ '^[0-9]+$'
          then (e.metadata ->> 'state_version')::integer
        else null
      end,
      row_number() over (partition by e.job_id order by e.created_at, e.id)::integer
    ) as state_version,
    public.job_status_for_event(e.event_type, e.metadata) as projected_status
  from public.job_events e
  where e.transition_to_version is null
)
update public.job_events e
set transition_to_version = greatest(versioned.state_version, 1),
    transition_from_version = greatest(versioned.state_version - 1, 0),
    projected_status = versioned.projected_status,
    projected_at = coalesce(e.projected_at, now())
from versioned
where e.id = versioned.id;

create unique index if not exists job_events_event_sequence_uidx
  on public.job_events(event_sequence);

create index if not exists job_events_job_version_idx
  on public.job_events(job_id, transition_to_version desc, event_sequence desc);

create table if not exists public.job_state_projections (
  job_id uuid primary key references public.jobs(id) on delete cascade,
  projected_status public.job_status not null,
  event_id uuid references public.job_events(id) on delete set null,
  event_sequence bigint not null,
  state_version integer not null default 0,
  projected_at timestamptz not null default now(),
  snapshot_synced_at timestamptz,
  conflict_count integer not null default 0,
  metadata jsonb not null default '{}'::jsonb
);

alter table public.job_state_projections enable row level security;

drop policy if exists "job state projections admin read" on public.job_state_projections;
create policy "job state projections admin read"
  on public.job_state_projections
  for select
  to authenticated
  using (public.is_admin());

drop policy if exists "job state projections service write" on public.job_state_projections;
create policy "job state projections service write"
  on public.job_state_projections
  for all
  to service_role
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create index if not exists job_state_projections_status_idx
  on public.job_state_projections(projected_status, projected_at desc);

create table if not exists public.operational_automation_runs (
  id uuid primary key default gen_random_uuid(),
  run_type text not null default 'dispatch_heartbeat',
  status text not null default 'running',
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  processed_count integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  error_message text,
  constraint operational_automation_runs_status_check check (status in ('running', 'completed', 'failed'))
);

alter table public.operational_automation_runs enable row level security;

drop policy if exists "automation runs admin read" on public.operational_automation_runs;
create policy "automation runs admin read"
  on public.operational_automation_runs
  for select
  to authenticated
  using (public.is_admin());

drop policy if exists "automation runs service write" on public.operational_automation_runs;
create policy "automation runs service write"
  on public.operational_automation_runs
  for all
  to service_role
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create index if not exists operational_automation_runs_started_idx
  on public.operational_automation_runs(started_at desc);

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

drop trigger if exists prepare_job_event_version_trigger on public.job_events;
create trigger prepare_job_event_version_trigger
  before insert on public.job_events
  for each row
  execute function public.prepare_job_event_version();

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
    jsonb_build_object('event_type', new.event_type, 'source', new.source)
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

  update public.job_events
  set projected_at = coalesce(projected_at, now())
  where id = new.id;

  return new;
end;
$$;

drop trigger if exists project_job_event_state_trigger on public.job_events;
create trigger project_job_event_state_trigger
  after insert on public.job_events
  for each row
  execute function public.project_job_event_state();

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
select distinct on (e.job_id)
  e.job_id,
  coalesce(e.projected_status, public.job_status_for_event(e.event_type, e.metadata)),
  e.id,
  e.event_sequence,
  coalesce(e.transition_to_version, 0),
  coalesce(e.projected_at, e.created_at),
  null,
  jsonb_build_object('backfilled', true, 'event_type', e.event_type)
from public.job_events e
where coalesce(e.projected_status, public.job_status_for_event(e.event_type, e.metadata)) is not null
order by e.job_id, coalesce(e.transition_to_version, 0) desc, e.event_sequence desc
on conflict (job_id) do update
set projected_status = excluded.projected_status,
    event_id = excluded.event_id,
    event_sequence = excluded.event_sequence,
    state_version = excluded.state_version,
    projected_at = excluded.projected_at,
    metadata = public.job_state_projections.metadata || excluded.metadata;

create or replace view public.job_current_state_from_events as
select
  p.job_id,
  p.projected_status as event_status,
  e.event_type,
  p.event_id,
  e.created_at,
  p.state_version
from public.job_state_projections p
left join public.job_events e on e.id = p.event_id;

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
  job_row public.jobs;
  job_status_value public.job_status;
  event_public_message text;
  metadata_value jsonb := coalesce(p_metadata, '{}'::jsonb);
  idempotency text := nullif(btrim(coalesce(p_metadata->>'idempotency_key', '')), '');
  severity_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'severity', '')), ''), 'info');
  visibility_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'visibility', '')), ''), 'public');
  source_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'source', '')), ''), 'app');
  expected_state_version integer;
begin
  if idempotency is not null then
    select id into event_id from public.job_events where idempotency_key = idempotency;
    if event_id is not null then
      return event_id;
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
          'source', source_value
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
    case when severity_value in ('info', 'warning', 'critical') then severity_value else 'info' end,
    case when visibility_value in ('public', 'internal') then visibility_value else 'public' end,
    source_value
  )
  returning id into event_id;

  return event_id;
exception
  when unique_violation then
    if idempotency is not null then
      select id into event_id from public.job_events where idempotency_key = idempotency;
      return event_id;
    end if;
    raise;
end;
$$;

create or replace function public.transition_job_state(
  p_job_id uuid,
  p_next_status public.job_status,
  p_actor_role text,
  p_actor_id uuid default auth.uid(),
  p_public_note text default null,
  p_internal_note text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_expected_status public.job_status default null,
  p_idempotency_key text default null
) returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  updated_row public.jobs;
  expected_status_value public.job_status;
  expected_state_version integer;
  metadata_value jsonb := coalesce(p_metadata, '{}'::jsonb);
  event_type_value text;
  event_key text;
  existing_event uuid;
  admin_actor boolean := lower(coalesce(p_actor_role, '')) = 'admin' or public.is_admin() or auth.role() = 'service_role';
begin
  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  event_key := nullif(btrim(coalesce(p_idempotency_key, metadata_value ->> 'idempotency_key', '')), '');
  if event_key is not null then
    select id into existing_event
    from public.job_events
    where idempotency_key = event_key;

    if existing_event is not null then
      return job_row;
    end if;
  end if;

  if metadata_value ->> 'expected_state_version' ~ '^[0-9]+$' then
    expected_state_version := (metadata_value ->> 'expected_state_version')::integer;
    if expected_state_version <> coalesce(job_row.state_version, 0) then
      perform public.upsert_operational_alert(
        'state_conflict',
        'warning',
        'Stale job state transition blocked by version guard.',
        p_job_id,
        null,
        null,
        null,
        null,
        jsonb_build_object(
          'expected_state_version', expected_state_version,
          'actual_state_version', coalesce(job_row.state_version, 0),
          'next_status', p_next_status,
          'actor_role', p_actor_role
        )
      );
      raise exception 'This job changed from version % to %. Refresh and try again.',
        expected_state_version,
        coalesce(job_row.state_version, 0);
    end if;
  end if;

  if p_next_status = job_row.status then
    return job_row;
  end if;

  expected_status_value := p_expected_status;
  if expected_status_value is null and metadata_value ->> 'expected_status' in (
    'requested',
    'matching',
    'assigned',
    'accepted',
    'assessment_fee_pending',
    'assessment_payment_pending_verification',
    'assessment_confirmed',
    'en_route',
    'on_site',
    'quoted',
    'quote_accepted',
    'work_payment_pending_verification',
    'payment_confirmed',
    'work_in_progress',
    'electrician_completed',
    'customer_confirmed',
    'payout_pending',
    'payout_complete',
    'rated',
    'cancelled'
  ) then
    expected_status_value := (metadata_value ->> 'expected_status')::public.job_status;
  end if;

  if expected_status_value is not null and job_row.status <> expected_status_value then
    perform public.upsert_operational_alert(
      'state_conflict',
      'warning',
      'Stale job status write blocked.',
      p_job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object(
        'expected_status', expected_status_value,
        'actual_status', job_row.status,
        'next_status', p_next_status,
        'actor_role', p_actor_role
      )
    );
    raise exception 'This job changed from % to %. Refresh and try again.', expected_status_value, job_row.status;
  end if;

  if not public.is_valid_job_transition(job_row.status, p_next_status, p_actor_role, admin_actor, metadata_value) then
    perform public.upsert_operational_alert(
      'state_conflict',
      'critical',
      'Invalid job status transition blocked.',
      p_job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object(
        'current_status', job_row.status,
        'next_status', p_next_status,
        'actor_role', p_actor_role
      )
    );
    raise exception 'Invalid job transition from % to %', job_row.status, p_next_status;
  end if;

  update public.jobs
  set status = p_next_status,
      state_version = coalesce(state_version, 0) + 1,
      accepted_at = case when p_next_status in ('accepted', 'assessment_fee_pending') then coalesce(accepted_at, now()) else accepted_at end,
      assignment_expires_at = case when p_next_status in ('accepted', 'assessment_fee_pending', 'matching', 'cancelled') then null else assignment_expires_at end,
      customer_confirmed_at = case when p_next_status = 'customer_confirmed' then coalesce(customer_confirmed_at, now()) else customer_confirmed_at end,
      electrician_completed_at = case when p_next_status = 'electrician_completed' then coalesce(electrician_completed_at, now()) else electrician_completed_at end,
      payout_released_at = case when p_next_status = 'payout_complete' then coalesce(payout_released_at, now()) else payout_released_at end,
      updated_at = now()
  where id = p_job_id
  returning * into updated_row;

  event_type_value := public.job_event_type_for_status(p_next_status);

  perform public.log_job_event(
    p_job_id,
    event_type_value,
    p_actor_role,
    p_actor_id,
    public.public_message_for_job_event(event_type_value, p_next_status, p_public_note),
    p_internal_note,
    (metadata_value - 'expected_status' - 'expected_state_version' - 'idempotency_key') ||
      jsonb_build_object(
        'previous_status', job_row.status,
        'next_status', p_next_status,
        'previous_state_version', coalesce(job_row.state_version, 0),
        'state_version', updated_row.state_version,
        'source', coalesce(nullif(metadata_value ->> 'source', ''), 'state_transition'),
        'idempotency_key', coalesce(event_key, 'state:' || p_job_id::text || ':' || updated_row.state_version::text || ':' || p_next_status::text)
      )
  );

  return updated_row;
end;
$$;

create or replace function public.sync_job_state_projection(
  p_job_id uuid,
  p_reason text default 'projection-sync'
) returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  projection_row public.job_state_projections;
  synced_row public.jobs;
begin
  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  select * into projection_row
  from public.job_state_projections
  where job_id = p_job_id;

  if not found then
    update public.jobs
    set snapshot_reconciled_at = now()
    where id = p_job_id
    returning * into synced_row;
    return synced_row;
  end if;

  if job_row.status is distinct from projection_row.projected_status
     or coalesce(job_row.state_version, 0) < coalesce(projection_row.state_version, 0) then
    update public.jobs
    set status = projection_row.projected_status,
        state_version = greatest(coalesce(state_version, 0), coalesce(projection_row.state_version, 0)),
        snapshot_reconciled_at = now(),
        updated_at = now()
    where id = p_job_id
    returning * into synced_row;

    update public.job_state_projections
    set snapshot_synced_at = now(),
        conflict_count = conflict_count + case when job_row.status is distinct from projection_row.projected_status then 1 else 0 end,
        metadata = metadata || jsonb_build_object(
          'last_sync_reason', coalesce(nullif(btrim(p_reason), ''), 'projection-sync'),
          'previous_snapshot_status', job_row.status,
          'synced_at', now()
        )
    where job_id = p_job_id;

    perform public.upsert_operational_alert(
      'snapshot_drift',
      'warning',
      'Job snapshot was synced from canonical event projection.',
      p_job_id,
      null,
      null,
      null,
      projection_row.event_id,
      jsonb_build_object(
        'snapshot_status', job_row.status,
        'projected_status', projection_row.projected_status,
        'snapshot_version', job_row.state_version,
        'projection_version', projection_row.state_version,
        'reason', coalesce(nullif(btrim(p_reason), ''), 'projection-sync')
      )
    );

    return synced_row;
  end if;

  update public.jobs
  set snapshot_reconciled_at = now()
  where id = p_job_id
  returning * into synced_row;

  update public.job_state_projections
  set snapshot_synced_at = now()
  where job_id = p_job_id;

  return synced_row;
end;
$$;

create or replace function public.sync_all_job_state_projections(p_limit integer default 100)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  synced_count integer := 0;
begin
  for item in
    select j.id
    from public.jobs j
    left join public.job_state_projections p on p.job_id = j.id
    where j.status not in ('rated', 'cancelled')
       or p.snapshot_synced_at is null
       or p.snapshot_synced_at < p.projected_at
    order by coalesce(p.snapshot_synced_at, to_timestamp(0)) asc, j.updated_at asc
    limit greatest(coalesce(p_limit, 100), 1)
  loop
    perform public.sync_job_state_projection(item.id, 'automation-projection-sync');
    synced_count := synced_count + 1;
  end loop;

  return synced_count;
end;
$$;

create or replace function public.detect_snapshot_drift()
returns table (
  job_id uuid,
  ticket text,
  snapshot_status public.job_status,
  event_status public.job_status,
  latest_event_id uuid,
  latest_event_at timestamptz,
  snapshot_version integer,
  event_version integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    j.id,
    j.ticket,
    j.status,
    p.projected_status,
    p.event_id,
    coalesce(e.created_at, p.projected_at),
    coalesce(j.state_version, 0),
    coalesce(p.state_version, 0)
  from public.jobs j
  join public.job_state_projections p on p.job_id = j.id
  left join public.job_events e on e.id = p.event_id
  where (
      j.status is distinct from p.projected_status
      or coalesce(j.state_version, 0) < coalesce(p.state_version, 0)
    )
    and j.status <> 'rated'
$$;

create or replace function public.reconcile_job_snapshot_from_events(
  p_job_id uuid,
  p_reason text default 'reconcile'
) returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.sync_job_state_projection(p_job_id, p_reason);
end;
$$;

create or replace function public.reconcile_active_job_snapshots(p_limit integer default 100)
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.sync_all_job_state_projections(p_limit);
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

  update public.operational_alerts
  set severity = 'critical',
      metadata = metadata || jsonb_build_object('auto_escalated_at', now())
  where status = 'open'
    and severity = 'warning'
    and alert_type in ('stuck_pairing', 'expired_assignment', 'failed_pairing', 'snapshot_drift')
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

create or replace function public.run_operational_automation(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  run_id uuid;
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

  insert into public.operational_automation_runs (run_type, status, metadata)
  values ('dispatch_heartbeat', 'running', jsonb_build_object('limit', coalesce(p_limit, 100)))
  returning id into run_id;

  synced_count := public.sync_all_job_state_projections(greatest(coalesce(p_limit, 100), 1));
  dispatch_count := public.process_dispatch_queue();
  alert_count := public.refresh_operational_alerts();

  update public.operational_alerts
  set severity = 'critical',
      metadata = metadata || jsonb_build_object('automation_escalated_at', now())
  where status = 'open'
    and severity = 'warning'
    and alert_type in ('stuck_pairing', 'expired_assignment', 'failed_pairing', 'payment_delay', 'snapshot_drift')
    and last_seen_at < now() - interval '10 minutes';
  get diagnostics escalated_count = row_count;

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

  total_count := synced_count + dispatch_count + alert_count + escalated_count + resolved_count;

  payload := jsonb_build_object(
    'run_id', run_id,
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

  return payload;
exception
  when others then
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
  perform public.refresh_operational_alerts();

  for expired_job in
    select id, assigned_electrician_id, current_assignment_event_id, current_assignment_token
    from public.jobs
    where status = 'assigned'
      and assignment_expires_at is not null
      and assignment_expires_at <= now()
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
    order by
      case urgency
        when 'emergency' then 0
        when 'today' then 1
        else 2
      end,
      dispatch_attempts desc,
      created_at asc
    for update skip locked
  loop
    perform public.dispatch_job_internal(matching_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  perform public.refresh_operational_alerts();
  return processed_count;
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
        select extract(epoch from (now() - max(started_at)))
        from public.operational_automation_runs
        where status = 'completed'
      ) as automation_last_run_age_seconds
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
      'automation_failures_24h', coalesce(q.automation_failures_24h, 0),
      'automation_last_run_age_seconds', coalesce(round(q.automation_last_run_age_seconds::numeric, 2), 0),
      'system_health_score', greatest(
        0,
        100
        - least(coalesce(q.critical_alerts, 0) * 10, 40)
        - least(coalesce(q.stuck_jobs, 0) * 6, 30)
        - least(coalesce(q.failed_pairing_jobs, 0) * 8, 24)
        - least(coalesce(q.upload_failures_24h, 0) * 2, 12)
        - least(coalesce(q.automation_failures_24h, 0) * 8, 24)
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
    q.snapshot_drift_jobs, q.failed_pairing_jobs, q.critical_alerts, q.upload_failures_24h, q.dispatch_retries_7d,
    q.disputes_30d, q.jobs_30d, q.automation_failures_24h, q.automation_last_run_age_seconds,
    rejects.rejected_count, assign.assigned_count, pay.avg_delay, resp.average_response_score;

  return coalesce(result, jsonb_build_object('queues', '{}'::jsonb, 'metrics', '{}'::jsonb));
end;
$$;

revoke all on table public.job_state_projections from public, anon, authenticated;
grant select on table public.job_state_projections to authenticated;
grant all on table public.job_state_projections to service_role;

revoke all on table public.operational_automation_runs from public, anon, authenticated;
grant select on table public.operational_automation_runs to authenticated;
grant all on table public.operational_automation_runs to service_role;

revoke all on function public.prepare_job_event_version() from public, anon, authenticated;
grant execute on function public.prepare_job_event_version() to service_role;

revoke all on function public.project_job_event_state() from public, anon, authenticated;
grant execute on function public.project_job_event_state() to service_role;

revoke all on function public.sync_job_state_projection(uuid,text) from public, anon, authenticated;
grant execute on function public.sync_job_state_projection(uuid,text) to service_role;

revoke all on function public.sync_all_job_state_projections(integer) from public, anon, authenticated;
grant execute on function public.sync_all_job_state_projections(integer) to service_role;

revoke all on function public.run_operational_automation(integer) from public, anon, authenticated;
grant execute on function public.run_operational_automation(integer) to service_role;

revoke all on function public.log_job_event(uuid,text,text,uuid,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.log_job_event(uuid,text,text,uuid,text,text,jsonb) to service_role;

revoke all on function public.transition_job_state(uuid,public.job_status,text,uuid,text,text,jsonb,public.job_status,text) from public, anon, authenticated;
grant execute on function public.transition_job_state(uuid,public.job_status,text,uuid,text,text,jsonb,public.job_status,text) to service_role;

revoke all on function public.process_dispatch_queue() from public, anon, authenticated;
grant execute on function public.process_dispatch_queue() to service_role;

select pg_notify('pgrst', 'reload schema');
