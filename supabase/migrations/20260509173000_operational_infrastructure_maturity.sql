-- Operational infrastructure maturity:
-- - event-derived timeline/state projections
-- - idempotent state transition guardrails
-- - richer operational metrics and alerts
-- - upload failure observability
-- - electrician retention/performance scoring
-- - guest dispatch OTP preparation

alter table public.jobs
  add column if not exists state_version integer not null default 0,
  add column if not exists guest_dispatch_verified_at timestamptz;

alter table public.electricians
  add column if not exists acceptance_rate numeric(5,2) not null default 0,
  add column if not exists response_score numeric(5,2) not null default 0,
  add column if not exists acceptance_score numeric(5,2) not null default 0,
  add column if not exists payout_confidence_score numeric(5,2) not null default 100;

create table if not exists public.upload_failures (
  id uuid primary key default gen_random_uuid(),
  job_id uuid references public.jobs(id) on delete cascade,
  uploader_role text not null default 'guest' check (uploader_role in ('guest', 'customer', 'electrician', 'admin', 'system')),
  bucket text,
  file_name text,
  content_type text,
  file_size integer,
  failure_stage text not null,
  error_message text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists upload_failures_created_idx
  on public.upload_failures(created_at desc);
create index if not exists upload_failures_job_idx
  on public.upload_failures(job_id) where job_id is not null;

alter table public.upload_failures enable row level security;

drop policy if exists "upload failures admin read" on public.upload_failures;
create policy "upload failures admin read"
  on public.upload_failures
  for select
  using (public.is_admin());

drop policy if exists "upload failures service write" on public.upload_failures;
create policy "upload failures service write"
  on public.upload_failures
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

alter table public.guest_otps drop constraint if exists guest_otps_action_type_check;
alter table public.guest_otps
  add constraint guest_otps_action_type_check
  check (action_type in ('cancel_job', 'payment_proof', 'dispute', 'customer_confirmed', 'dispatch_confirm'));

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
    'failed_pairing',
    'upload_failure',
    'high_rejection_electrician',
    'electrician_performance'
  ));

create or replace function public.job_status_for_event(
  p_event_type text,
  p_metadata jsonb default '{}'::jsonb
) returns public.job_status
language sql
stable
set search_path = public
as $$
  select case
    when coalesce(p_metadata, '{}'::jsonb) ->> 'next_status' in (
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
    ) then (p_metadata ->> 'next_status')::public.job_status
    when p_event_type = 'JOB_CREATED' then 'requested'::public.job_status
    when p_event_type = 'PAIRING_STARTED' then 'matching'::public.job_status
    when p_event_type = 'ELECTRICIAN_ASSIGNED' then 'assigned'::public.job_status
    when p_event_type = 'ASSIGNMENT_ACCEPTED' then 'accepted'::public.job_status
    when p_event_type = 'ASSIGNMENT_REJECTED' then 'matching'::public.job_status
    when p_event_type = 'ASSIGNMENT_EXPIRED' then 'matching'::public.job_status
    when p_event_type = 'PAYMENT_SUBMITTED' then null::public.job_status
    when p_event_type = 'PAYMENT_VERIFIED' then null::public.job_status
    when p_event_type = 'WORK_STARTED' then 'work_in_progress'::public.job_status
    when p_event_type = 'WORK_COMPLETED' then 'electrician_completed'::public.job_status
    when p_event_type = 'CUSTOMER_CONFIRMED' then 'customer_confirmed'::public.job_status
    when p_event_type = 'DISPUTE_OPENED' then null::public.job_status
    when p_event_type = 'JOB_CANCELLED' then 'cancelled'::public.job_status
    when p_event_type = 'QUOTE_SUBMITTED' then 'quoted'::public.job_status
    when p_event_type = 'PAYOUT_RELEASED' then 'payout_complete'::public.job_status
    when p_event_type = 'RATING_SUBMITTED' then 'rated'::public.job_status
    else null::public.job_status
  end;
$$;

create or replace view public.job_current_state_from_events as
select distinct on (event_state.job_id)
  event_state.job_id,
  event_state.status as event_status,
  event_state.event_type,
  event_state.event_id,
  event_state.created_at,
  event_state.state_version
from (
  select
    e.job_id,
    e.id as event_id,
    e.event_type,
    e.created_at,
    nullif(e.metadata ->> 'state_version', '')::integer as state_version,
    public.job_status_for_event(e.event_type, e.metadata) as status
  from public.job_events e
) event_state
where event_state.status is not null
order by event_state.job_id, event_state.created_at desc, event_state.event_id desc;

create or replace view public.job_timeline_from_events as
select
  e.id as event_id,
  e.job_id,
  coalesce(public.job_status_for_event(e.event_type, e.metadata), j.status) as status,
  e.public_message as note,
  case when exists (select 1 from public.profiles p where p.id = e.actor_id) then e.actor_id else null end as actor_profile_id,
  e.metadata,
  e.created_at
from public.job_events e
join public.jobs j on j.id = e.job_id
where nullif(btrim(coalesce(e.public_message, '')), '') is not null;

create or replace function public.job_event_to_timeline()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  status_value public.job_status;
  actor_profile uuid;
begin
  if coalesce(new.metadata, '{}'::jsonb) ? 'skip_timeline'
     or coalesce(new.metadata, '{}'::jsonb) ? 'timeline_id' then
    return new;
  end if;

  if nullif(btrim(coalesce(new.public_message, '')), '') is null then
    return new;
  end if;

  status_value := public.job_status_for_event(new.event_type, new.metadata);
  if status_value is null then
    select status into status_value from public.jobs where id = new.job_id;
  end if;

  if status_value is null then
    return new;
  end if;

  select id into actor_profile
  from public.profiles
  where id = new.actor_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (
    new.job_id,
    status_value,
    new.public_message,
    actor_profile,
    jsonb_build_object(
      'skip_job_event_log', true,
      'derived_from', 'job_events',
      'event_id', new.id
    )
  )
  on conflict do nothing;

  return new;
end;
$$;

drop trigger if exists job_event_to_timeline_trigger on public.job_events;
create trigger job_event_to_timeline_trigger
after insert on public.job_events
for each row
execute function public.job_event_to_timeline();

create or replace function public.append_job_timeline(
  p_job_id uuid,
  p_status public.job_status,
  p_note text default null,
  p_actor_profile_id uuid default auth.uid()
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  event_type_value text;
  safe_note text;
begin
  event_type_value := public.job_event_type_for_status(p_status);
  safe_note := public.public_message_for_job_event(event_type_value, p_status, p_note);

  perform public.log_job_event(
    p_job_id,
    event_type_value,
    public.actor_role_for_profile(p_actor_profile_id),
    p_actor_profile_id,
    safe_note,
    p_note,
    jsonb_build_object('next_status', p_status::text, 'source', 'append_job_timeline')
  );
end;
$$;

create or replace function public.is_valid_job_transition(
  p_current_status public.job_status,
  p_next_status public.job_status,
  p_actor_role text,
  p_is_admin boolean default false,
  p_metadata jsonb default '{}'::jsonb
) returns boolean
language plpgsql
stable
set search_path = public
as $$
declare
  actor_role_value text := lower(coalesce(p_actor_role, 'system'));
  admin_override boolean := lower(coalesce(p_metadata ->> 'admin_override', 'false')) in ('true', '1', 'yes');
begin
  if p_current_status is null or p_next_status is null then
    return false;
  end if;

  if p_current_status = p_next_status then
    return true;
  end if;

  if p_current_status in ('payout_complete', 'rated', 'cancelled') then
    return false;
  end if;

  if p_is_admin and admin_override then
    return p_next_status not in ('requested', 'matching', 'assigned')
      or p_current_status in ('requested', 'matching', 'assigned');
  end if;

  if actor_role_value in ('customer', 'guest') then
    return (p_current_status = 'quoted' and p_next_status = 'quote_accepted')
      or (p_current_status = 'electrician_completed' and p_next_status = 'customer_confirmed')
      or (
        p_next_status = 'cancelled'
        and p_current_status in ('requested', 'matching', 'assigned', 'accepted', 'assessment_fee_pending', 'quoted')
      );
  end if;

  if actor_role_value = 'electrician' then
    return (p_current_status = 'assigned' and p_next_status in ('accepted', 'assessment_fee_pending'))
      or (p_current_status = 'assessment_confirmed' and p_next_status = 'en_route')
      or (p_current_status = 'en_route' and p_next_status = 'on_site')
      or (p_current_status = 'payment_confirmed' and p_next_status = 'work_in_progress')
      or (p_current_status = 'work_in_progress' and p_next_status = 'electrician_completed');
  end if;

  if actor_role_value in ('admin', 'system') then
    return (p_current_status = 'requested' and p_next_status in ('matching', 'assigned', 'cancelled'))
      or (p_current_status = 'matching' and p_next_status in ('assigned', 'cancelled'))
      or (p_current_status = 'assigned' and p_next_status in ('matching', 'accepted', 'assessment_fee_pending', 'cancelled'))
      or (p_current_status = 'accepted' and p_next_status in ('assessment_fee_pending', 'quoted', 'cancelled'))
      or (p_current_status = 'assessment_fee_pending' and p_next_status in ('assessment_payment_pending_verification', 'cancelled'))
      or (p_current_status = 'assessment_payment_pending_verification' and p_next_status in ('assessment_confirmed', 'assessment_fee_pending', 'cancelled'))
      or (p_current_status = 'assessment_confirmed' and p_next_status in ('en_route', 'on_site', 'quoted', 'cancelled'))
      or (p_current_status = 'en_route' and p_next_status in ('on_site', 'cancelled'))
      or (p_current_status = 'on_site' and p_next_status in ('quoted', 'cancelled'))
      or (p_current_status = 'quoted' and p_next_status in ('quote_accepted', 'cancelled'))
      or (p_current_status = 'quote_accepted' and p_next_status in ('work_payment_pending_verification', 'cancelled'))
      or (p_current_status = 'work_payment_pending_verification' and p_next_status in ('payment_confirmed', 'quote_accepted', 'cancelled'))
      or (p_current_status = 'payment_confirmed' and p_next_status in ('work_in_progress', 'cancelled'))
      or (p_current_status = 'work_in_progress' and p_next_status in ('electrician_completed', 'cancelled'))
      or (p_current_status = 'electrician_completed' and p_next_status in ('customer_confirmed', 'cancelled'))
      or (p_current_status = 'customer_confirmed' and p_next_status in ('payout_pending', 'payout_complete'))
      or (p_current_status = 'payout_pending' and p_next_status = 'payout_complete')
      or (p_current_status = 'payout_complete' and p_next_status = 'rated');
  end if;

  return false;
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

  event_key := nullif(btrim(coalesce(p_idempotency_key, metadata_value ->> 'idempotency_key', '')), '');
  if event_key is not null then
    select id into existing_event
    from public.job_events
    where idempotency_key = event_key;

    if existing_event is not null then
      return job_row;
    end if;
  end if;

  update public.jobs
  set status = p_next_status,
      state_version = coalesce(state_version, 0) + 1,
      accepted_at = case when p_next_status in ('accepted', 'assessment_fee_pending') then coalesce(accepted_at, now()) else accepted_at end,
      assignment_expires_at = case when p_next_status in ('accepted', 'assessment_fee_pending', 'matching', 'cancelled') then null else assignment_expires_at end,
      customer_confirmed_at = case when p_next_status = 'customer_confirmed' then coalesce(customer_confirmed_at, now()) else customer_confirmed_at end,
      electrician_completed_at = case when p_next_status = 'electrician_completed' then coalesce(electrician_completed_at, now()) else electrician_completed_at end,
      payout_released_at = case when p_next_status = 'payout_complete' then coalesce(payout_released_at, now()) else payout_released_at end
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
    (metadata_value - 'expected_status' - 'idempotency_key') ||
      jsonb_build_object(
        'previous_status', job_row.status,
        'next_status', p_next_status,
        'state_version', updated_row.state_version,
        'source', coalesce(nullif(metadata_value ->> 'source', ''), 'state_transition'),
        'idempotency_key', coalesce(event_key, 'state:' || p_job_id::text || ':' || updated_row.state_version::text || ':' || p_next_status::text)
      )
  );

  return updated_row;
end;
$$;

create or replace function public.set_job_status(
  p_job_id uuid,
  p_next_status public.job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb
) returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  actor_metadata jsonb := coalesce(p_metadata, '{}'::jsonb);
  actor_customer_id uuid := public.current_customer_id();
  actor_electrician_id uuid := public.current_electrician_id();
  is_admin_actor boolean := public.is_admin();
  actor_role_value text;
begin
  select * into job_row from public.jobs where id = p_job_id;
  if not found then
    raise exception 'Job not found';
  end if;

  if is_admin_actor then
    actor_role_value := 'admin';
    actor_metadata := actor_metadata || jsonb_build_object('admin_override', true);
  elsif job_row.customer_id = actor_customer_id then
    actor_role_value := 'customer';
  elsif job_row.assigned_electrician_id = actor_electrician_id then
    actor_role_value := 'electrician';
  else
    raise exception 'You do not have permission to update this job';
  end if;

  return public.transition_job_state(
    p_job_id,
    p_next_status,
    actor_role_value,
    auth.uid(),
    p_note,
    p_note,
    actor_metadata,
    null,
    null
  );
end;
$$;

create or replace function public.update_guest_job_status(
  p_job_id uuid,
  p_access_token text,
  p_next_status public.job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_action_token text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  safe_metadata jsonb;
begin
  select * into job_row
  from public.jobs
  where id = p_job_id
    and customer_access_token = p_access_token
    and guest_customer_id is not null;

  if not found then
    raise exception 'Guest job not found';
  end if;

  if job_row.created_at < now() - interval '30 days' then
    raise exception 'This guest action link has expired. Contact VoltFriq support to continue.';
  end if;

  if p_next_status = 'cancelled' then
    perform public.consume_guest_action_token(p_job_id, 'cancel_job', p_action_token);
  elsif p_next_status = 'customer_confirmed' then
    perform public.consume_guest_action_token(p_job_id, 'customer_confirmed', p_action_token);
  end if;

  safe_metadata := coalesce(p_metadata, '{}'::jsonb) - 'phone_confirmation';

  perform public.transition_job_state(
    p_job_id,
    p_next_status,
    'guest',
    null,
    p_note,
    p_note,
    safe_metadata || jsonb_build_object('guest_access', true),
    null,
    null
  );

  return public.guest_job_payload(p_job_id, p_access_token);
end;
$$;

create or replace function public.electrician_accept_job(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  electrician_row public.electricians;
  customer_profile uuid;
  next_status public.job_status;
begin
  select * into electrician_row from public.electricians where profile_id = auth.uid();
  if not found then
    raise exception 'Electrician profile not found';
  end if;

  select * into job_row from public.jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.assigned_electrician_id is distinct from electrician_row.id then
    raise exception 'Job is not assigned to this electrician';
  end if;

  if job_row.status <> 'assigned' then
    raise exception 'Only assigned jobs can be accepted';
  end if;

  if job_row.assignment_expires_at is not null and job_row.assignment_expires_at <= now() then
    perform public.log_job_event(
      p_job_id,
      'ASSIGNMENT_EXPIRED',
      'electrician',
      auth.uid(),
      'Still finding a verified VoltFriq near you.',
      'Electrician attempted to accept after assignment expiry.',
      jsonb_build_object(
        'electrician_id', electrician_row.id,
        'severity', 'warning',
        'source', 'electrician_accept_job',
        'idempotency_key', 'late-accept:' || p_job_id::text || ':' || electrician_row.id::text
      )
    );
    perform public.upsert_operational_alert(
      'expired_assignment',
      'warning',
      'Expired assignment acceptance was blocked.',
      p_job_id,
      electrician_row.id,
      null,
      null,
      null,
      jsonb_build_object('assignment_expires_at', job_row.assignment_expires_at)
    );
    raise exception 'This assignment has expired and can no longer be accepted.';
  end if;

  next_status := case
    when job_row.requires_assessment then 'assessment_fee_pending'::public.job_status
    else 'accepted'::public.job_status
  end;

  job_row := public.transition_job_state(
    p_job_id,
    next_status,
    'electrician',
    auth.uid(),
    'VoltFriq accepted the booking.',
    'VoltFriq accepted the booking.',
    jsonb_build_object(
      'electrician_id', electrician_row.id,
      'expected_status', 'assigned',
      'source', 'electrician_accept_job'
    ),
    'assigned',
    'assignment-accepted:' || p_job_id::text || ':' || electrician_row.id::text
  );

  select c.profile_id into customer_profile from public.customers c where c.id = job_row.customer_id;
  perform public.create_notification(customer_profile, p_job_id, 'electrician_accepted', 'VoltFriq accepted', 'Your assigned VoltFriq accepted the booking.', '{}'::jsonb);
  perform public.refresh_electrician_performance_snapshot(electrician_row.id);
  return job_row;
end;
$$;

create or replace function public.electrician_reject_job(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  electrician_row public.electricians;
  job_row public.jobs;
begin
  select * into electrician_row from public.electricians where profile_id = auth.uid();
  if not found then
    raise exception 'Electrician profile not found';
  end if;

  select * into job_row from public.jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.assigned_electrician_id is distinct from electrician_row.id then
    raise exception 'Job is not assigned to this electrician';
  end if;

  if job_row.status <> 'assigned' then
    raise exception 'Only pending assignments can be rejected';
  end if;

  if job_row.assignment_expires_at is not null and job_row.assignment_expires_at <= now() then
    raise exception 'This assignment has already expired.';
  end if;

  perform public.log_job_event(
    p_job_id,
    'ASSIGNMENT_REJECTED',
    'electrician',
    auth.uid(),
    'Pairing you with a VoltFriq.',
    'Assigned VoltFriq declined the booking. Re-dispatch started.',
    jsonb_build_object(
      'electrician_id', electrician_row.id,
      'previous_status', job_row.status,
      'next_status', 'matching',
      'source', 'electrician_reject_job',
      'idempotency_key', 'assignment-rejected:' || p_job_id::text || ':' || electrician_row.id::text
    )
  );

  update public.jobs
  set status = 'matching',
      assigned_electrician_id = null,
      assignment_expires_at = null,
      state_version = state_version + 1
  where id = p_job_id
    and status = 'assigned'
    and assigned_electrician_id = electrician_row.id
  returning * into job_row;

  if job_row.id is null then
    raise exception 'This assignment is no longer available.';
  end if;

  perform public.refresh_electrician_performance_snapshot(electrician_row.id);
  select * into job_row from public.dispatch_job_internal(p_job_id, null);
  return job_row;
end;
$$;

create or replace function public.record_upload_failure(
  p_job_id uuid default null,
  p_uploader_role text default 'guest',
  p_bucket text default null,
  p_file_name text default null,
  p_content_type text default null,
  p_file_size integer default null,
  p_failure_stage text default 'upload',
  p_error_message text default 'Upload failed',
  p_metadata jsonb default '{}'::jsonb
) returns public.upload_failures
language plpgsql
security definer
set search_path = public
as $$
declare
  failure_row public.upload_failures;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  insert into public.upload_failures (
    job_id,
    uploader_role,
    bucket,
    file_name,
    content_type,
    file_size,
    failure_stage,
    error_message,
    metadata
  )
  values (
    p_job_id,
    case when p_uploader_role in ('guest', 'customer', 'electrician', 'admin', 'system') then p_uploader_role else 'system' end,
    nullif(btrim(coalesce(p_bucket, '')), ''),
    nullif(btrim(coalesce(p_file_name, '')), ''),
    nullif(btrim(coalesce(p_content_type, '')), ''),
    p_file_size,
    coalesce(nullif(btrim(p_failure_stage), ''), 'upload'),
    left(coalesce(nullif(btrim(p_error_message), ''), 'Upload failed'), 500),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into failure_row;

  perform public.upsert_operational_alert(
    'upload_failure',
    'warning',
    'Recent upload failure needs review.',
    p_job_id,
    null,
    null,
    null,
    null,
    jsonb_build_object('failure_id', failure_row.id, 'failure_stage', failure_row.failure_stage)
  );

  return failure_row;
end;
$$;

create or replace function public.request_guest_otp(
  p_job_id uuid,
  p_access_token text,
  p_action_type text,
  p_phone_confirmation text,
  p_client_fingerprint text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  guest_phone text;
  expected_last4 text;
  provided_last4 text;
  raw_code text;
  challenge_id uuid;
  expires timestamptz;
begin
  if p_action_type not in ('cancel_job', 'payment_proof', 'dispute', 'customer_confirmed', 'dispatch_confirm') then
    raise exception 'Unsupported guest action';
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
    and customer_access_token = p_access_token
    and guest_customer_id is not null
  for update;

  if not found then
    raise exception 'Guest job not found';
  end if;

  if job_row.created_at < now() - interval '30 days' then
    raise exception 'This guest action link has expired. Contact VoltFriq support to continue.';
  end if;

  select phone into guest_phone from public.guest_customers where id = job_row.guest_customer_id;
  expected_last4 := right(regexp_replace(coalesce(guest_phone, ''), '\D', '', 'g'), 4);
  provided_last4 := right(regexp_replace(coalesce(p_phone_confirmation, ''), '\D', '', 'g'), 4);

  if expected_last4 = '' or expected_last4 <> provided_last4 then
    raise exception 'Confirm the phone number used for this booking.';
  end if;

  if (
    select count(*)
    from public.guest_otps
    where job_id = p_job_id
      and action_type = p_action_type
      and created_at > now() - interval '10 minutes'
  ) >= 3 then
    raise exception 'Too many OTP requests. Please wait a few minutes before trying again.';
  end if;

  raw_code := lpad((floor(random() * 1000000))::integer::text, 6, '0');
  expires := now() + interval '10 minutes';

  insert into public.guest_otps (
    job_id,
    action_type,
    phone_last4,
    code_hash,
    request_fingerprint,
    delivery_status,
    expires_at,
    metadata
  )
  values (
    p_job_id,
    p_action_type,
    expected_last4,
    md5('voltfriq-otp:' || raw_code || ':' || p_job_id::text || ':' || p_action_type),
    nullif(btrim(coalesce(p_client_fingerprint, '')), ''),
    'pending',
    expires,
    jsonb_build_object('masked_phone', '***' || expected_last4)
  )
  returning id into challenge_id;

  return jsonb_strip_nulls(jsonb_build_object(
    'challenge_id', challenge_id,
    'expires_at', expires,
    'masked_phone', '***' || expected_last4,
    'delivery_status', 'pending',
    'otp_code', case when auth.role() = 'service_role' then raw_code else null end
  ));
end;
$$;

create or replace function public.verify_guest_otp(
  p_job_id uuid,
  p_access_token text,
  p_action_type text,
  p_challenge_id uuid,
  p_otp_code text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  otp_row public.guest_otps;
begin
  if p_action_type not in ('cancel_job', 'payment_proof', 'dispute', 'customer_confirmed', 'dispatch_confirm') then
    raise exception 'Unsupported guest action';
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
    and customer_access_token = p_access_token
    and guest_customer_id is not null;

  if not found then
    raise exception 'Guest job not found';
  end if;

  select * into otp_row
  from public.guest_otps
  where id = p_challenge_id
    and job_id = p_job_id
    and action_type = p_action_type
  for update;

  if not found then
    raise exception 'OTP challenge not found';
  end if;

  if otp_row.consumed_at is not null or otp_row.expires_at <= now() then
    raise exception 'OTP has expired. Request a new code.';
  end if;

  if otp_row.attempts >= 5 then
    raise exception 'Too many OTP attempts. Request a new code.';
  end if;

  if otp_row.code_hash <> md5('voltfriq-otp:' || regexp_replace(coalesce(p_otp_code, ''), '\D', '', 'g') || ':' || p_job_id::text || ':' || p_action_type) then
    update public.guest_otps
    set attempts = attempts + 1
    where id = p_challenge_id;
    raise exception 'Invalid OTP code.';
  end if;

  update public.guest_otps
  set verified_at = coalesce(verified_at, now()),
      delivery_status = 'verified'
  where id = p_challenge_id;

  if p_action_type = 'dispatch_confirm' then
    update public.jobs
    set guest_dispatch_verified_at = coalesce(guest_dispatch_verified_at, now())
    where id = p_job_id;
  end if;

  return jsonb_build_object('verified', true, 'challenge_id', p_challenge_id);
end;
$$;

create or replace function public.prepare_guest_dispatch_otp(
  p_job_id uuid,
  p_access_token text,
  p_phone_confirmation text,
  p_client_fingerprint text default null
) returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.request_guest_otp(
    p_job_id,
    p_access_token,
    'dispatch_confirm',
    p_phone_confirmation,
    p_client_fingerprint
  );
$$;

create or replace function public.refresh_electrician_performance_snapshot(p_electrician_id uuid)
returns public.electrician_performance_snapshots
language plpgsql
security definer
set search_path = public
as $$
declare
  snapshot_row public.electrician_performance_snapshots;
  offer_count numeric := 0;
  accepted_count numeric := 0;
  rejection_count numeric := 0;
  payment_total numeric := 0;
  rejected_payment_count numeric := 0;
  response_value numeric := 0;
  acceptance_value numeric := 0;
  rejection_value numeric := 0;
  payout_confidence_value numeric := 100;
begin
  if not (public.is_admin() or auth.role() = 'service_role' or exists (
    select 1 from public.electricians e where e.id = p_electrician_id and e.profile_id = auth.uid()
  )) then
    raise exception 'Electrician performance access required';
  end if;

  select count(*)::numeric
  into offer_count
  from public.jobs j
  where p_electrician_id = any(coalesce(j.attempted_electrician_ids, '{}'::uuid[]))
    or j.assigned_electrician_id = p_electrician_id;

  select count(*)::numeric
  into accepted_count
  from public.jobs j
  where j.assigned_electrician_id = p_electrician_id
    and (
      j.accepted_at is not null
      or j.status in (
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
        'rated'
      )
    );

  select count(*)::numeric
  into rejection_count
  from public.job_events e
  where e.event_type = 'ASSIGNMENT_REJECTED'
    and e.metadata ->> 'electrician_id' = p_electrician_id::text;

  select count(*)::numeric,
         count(*) filter (where p.status = 'rejected')::numeric
  into payment_total, rejected_payment_count
  from public.job_payments p
  join public.jobs j on j.id = p.job_id
  where j.assigned_electrician_id = p_electrician_id;

  response_value := case when offer_count = 0 then 100 else round(greatest(0, least(100, (accepted_count / offer_count) * 100))::numeric, 2) end;
  acceptance_value := response_value;
  rejection_value := case when offer_count = 0 then 0 else round(greatest(0, least(100, (rejection_count / offer_count) * 100))::numeric, 2) end;
  payout_confidence_value := case
    when payment_total = 0 then 100
    else round(greatest(0, least(100, 100 - ((rejected_payment_count / payment_total) * 100)))::numeric, 2)
  end;

  update public.electricians
  set response_rate = response_value,
      acceptance_rate = acceptance_value,
      response_score = response_value,
      acceptance_score = acceptance_value,
      payout_confidence_score = payout_confidence_value,
      level_badge = public.calculate_electrician_level(
        completed_jobs,
        average_rating,
        total_ratings,
        response_value,
        watchlist
      )
  where id = p_electrician_id;

  insert into public.electrician_performance_snapshots (
    electrician_id,
    response_rate,
    acceptance_rate,
    rejection_rate,
    average_accept_seconds,
    completed_jobs,
    average_rating,
    negative_rating_count,
    score,
    metadata
  )
  select
    e.id,
    response_value,
    acceptance_value,
    rejection_value,
    coalesce((
      select round(avg(extract(epoch from (accepted.created_at - assigned.created_at)))::numeric, 2)
      from public.job_events assigned
      join public.job_events accepted on accepted.job_id = assigned.job_id
      where assigned.event_type = 'ELECTRICIAN_ASSIGNED'
        and accepted.event_type = 'ASSIGNMENT_ACCEPTED'
        and (
          assigned.metadata ->> 'electrician_id' = e.id::text
          or exists (
            select 1 from public.jobs j
            where j.id = assigned.job_id
              and j.assigned_electrician_id = e.id
          )
        )
        and accepted.created_at >= assigned.created_at
    ), 0),
    coalesce(e.completed_jobs, 0),
    coalesce(e.average_rating, 0),
    coalesce(e.negative_rating_count, 0),
    round((
      response_value * 0.25
      + acceptance_value * 0.25
      + payout_confidence_value * 0.15
      + coalesce(e.average_rating, 0) * 20 * 0.25
      + least(coalesce(e.completed_jobs, 0), 100) * 0.1
      - coalesce(e.negative_rating_count, 0) * 4
    )::numeric, 2),
    jsonb_build_object(
      'level_badge', e.level_badge,
      'watchlist', e.watchlist,
      'offers', offer_count,
      'accepted', accepted_count,
      'rejected', rejection_count,
      'payout_confidence_score', payout_confidence_value
    )
  from public.electricians e
  where e.id = p_electrician_id
  returning * into snapshot_row;

  if snapshot_row.score < 45 then
    perform public.upsert_operational_alert(
      'electrician_performance',
      'warning',
      'VoltFriq performance score needs review.',
      null,
      p_electrician_id,
      null,
      null,
      null,
      jsonb_build_object('score', snapshot_row.score)
    );
  end if;

  if rejection_value >= 50 and offer_count >= 4 then
    perform public.upsert_operational_alert(
      'high_rejection_electrician',
      'warning',
      'VoltFriq rejection rate is above target.',
      null,
      p_electrician_id,
      null,
      null,
      null,
      jsonb_build_object('rejection_rate', rejection_value, 'offers', offer_count)
    );
  end if;

  return snapshot_row;
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

  for item in
    select id, ticket, dispatch_attempts, last_dispatch_at
    from public.jobs
    where status = 'matching'
      and dispatch_attempts >= 3
  loop
    perform public.upsert_operational_alert(
      'failed_pairing',
      case when item.dispatch_attempts >= 5 then 'critical' else 'warning' end,
      'Pairing has retried multiple times without acceptance.',
      item.id,
      null,
      null,
      null,
      null,
      jsonb_build_object('ticket', item.ticket, 'dispatch_attempts', item.dispatch_attempts, 'last_dispatch_at', item.last_dispatch_at)
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select p.id as payment_id, p.job_id, p.created_at
    from public.job_payments p
    where p.status = 'submitted'
      and p.created_at < now() - interval '30 minutes'
  loop
    perform public.upsert_operational_alert(
      'pending_payment',
      case when item.created_at < now() - interval '2 hours' then 'critical' else 'warning' end,
      'Payment proof is waiting for admin verification.',
      item.job_id,
      null,
      item.payment_id,
      null,
      null,
      jsonb_build_object('submitted_at', item.created_at)
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select id, created_at
    from public.disputes
    where status = 'open'
  loop
    perform public.upsert_operational_alert(
      'open_dispute',
      'critical',
      'Open dispute needs admin review.',
      null,
      null,
      null,
      item.id,
      null,
      jsonb_build_object('opened_at', item.created_at)
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select id, job_id, created_at, failure_stage
    from public.upload_failures
    where created_at > now() - interval '1 hour'
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
      jsonb_build_object('failure_id', item.id, 'failure_stage', item.failure_stage, 'created_at', item.created_at)
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select e.id, e.acceptance_score, latest.rejection_rate
    from public.electricians e
    left join lateral (
      select s.rejection_rate
      from public.electrician_performance_snapshots s
      where s.electrician_id = e.id
      order by s.snapshot_at desc
      limit 1
    ) latest on true
    where e.status = 'approved'
      and coalesce(latest.rejection_rate, 0) >= 50
  loop
    perform public.upsert_operational_alert(
      'high_rejection_electrician',
      'warning',
      'VoltFriq rejection rate is above target.',
      null,
      item.id,
      null,
      null,
      null,
      jsonb_build_object('rejection_rate', item.rejection_rate, 'acceptance_score', item.acceptance_score)
    );
    count_alerts := count_alerts + 1;
  end loop;

  update public.operational_alerts a
  set status = 'resolved',
      resolved_at = now()
  where status = 'open'
    and (
      (alert_type in ('stuck_pairing', 'expired_assignment', 'payment_delay', 'customer_confirmation_delay') and not exists (
        select 1 from public.detect_stuck_jobs() stuck
        where stuck.job_id = a.job_id
          and stuck.stuck_type = a.alert_type
      ))
      or (alert_type = 'failed_pairing' and not exists (
        select 1 from public.jobs j
        where j.id = a.job_id
          and j.status = 'matching'
          and j.dispatch_attempts >= 3
      ))
      or (alert_type = 'pending_payment' and not exists (
        select 1 from public.job_payments p
        where p.id = a.payment_id
          and p.status = 'submitted'
      ))
      or (alert_type = 'open_dispute' and not exists (
        select 1 from public.disputes d
        where d.id = a.dispute_id
          and d.status = 'open'
      ))
      or (alert_type = 'upload_failure' and not exists (
        select 1 from public.upload_failures f
        where f.job_id is not distinct from a.job_id
          and f.created_at > now() - interval '1 hour'
      ))
      or (alert_type = 'high_rejection_electrician' and not exists (
        select 1 from public.electrician_performance_snapshots s
        where s.electrician_id = a.electrician_id
          and s.rejection_rate >= 50
          and s.snapshot_at > now() - interval '24 hours'
      ))
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
      ) as dispatch_retries_7d
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
  payment_submitted as (
    select job_id, min(created_at) as submitted_at
    from public.job_events
    where event_type = 'PAYMENT_SUBMITTED'
    group by job_id
  ),
  payment_verified as (
    select job_id, min(created_at) as verified_at
    from public.job_events
    where event_type = 'PAYMENT_VERIFIED'
    group by job_id
  ),
  metric_counts as (
    select
      (
        select avg(extract(epoch from (a.assigned_at - c.created_at)))
        from created_events c
        join assigned_events a on a.job_id = c.job_id
        where a.assigned_at >= c.created_at
      ) as avg_time_to_assign_seconds,
      (
        select avg(extract(epoch from (ac.accepted_at - a.assigned_at)))
        from assigned_events a
        join accepted_events ac on ac.job_id = a.job_id
        where ac.accepted_at >= a.assigned_at
      ) as avg_time_to_accept_seconds,
      (
        select case
          when count(*) = 0 then 0
          else (
            select count(*)
            from public.job_events e
            where e.event_type = 'ASSIGNMENT_REJECTED'
          )::numeric / nullif(count(*) filter (where array_length(coalesce(j.attempted_electrician_ids, '{}'::uuid[]), 1) > 0), 0)::numeric * 100
        end
        from public.jobs j
        cross join lateral unnest(coalesce(j.attempted_electrician_ids, '{}'::uuid[])) as attempted(electrician_id)
      ) as rejection_rate,
      (
        select avg(extract(epoch from (v.verified_at - s.submitted_at)))
        from payment_submitted s
        join payment_verified v on v.job_id = s.job_id
        where v.verified_at >= s.submitted_at
      ) as payment_verification_delay_seconds
  )
  select jsonb_build_object(
    'queues', jsonb_build_object(
      'pending_payments', coalesce(q.pending_payments, 0),
      'pending_electricians', coalesce(q.pending_electricians, 0),
      'stuck_pairing_jobs', coalesce(q.stuck_jobs, 0),
      'failed_pairing_jobs', coalesce(q.failed_pairing_jobs, 0),
      'open_disputes', coalesce(q.open_disputes, 0),
      'expired_assignments', coalesce(q.expired_assignments, 0),
      'critical_alerts', coalesce(q.critical_alerts, 0)
    ),
    'metrics', jsonb_build_object(
      'average_time_to_assign_seconds', coalesce(round(m.avg_time_to_assign_seconds::numeric, 1), 0),
      'average_time_to_accept_seconds', coalesce(round(m.avg_time_to_accept_seconds::numeric, 1), 0),
      'rejection_rate', coalesce(round(m.rejection_rate::numeric, 1), 0),
      'payment_verification_delay_seconds', coalesce(round(m.payment_verification_delay_seconds::numeric, 1), 0),
      'stuck_jobs_count', coalesce(q.stuck_jobs, 0),
      'dispatch_retries_7d', coalesce(q.dispatch_retries_7d, 0),
      'upload_failures_24h', coalesce(q.upload_failures_24h, 0)
    )
  )
  into result
  from queue_counts q
  cross join metric_counts m;

  return coalesce(result, jsonb_build_object(
    'queues', '{}'::jsonb,
    'metrics', '{}'::jsonb
  ));
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
        'stuck_since', s.stuck_since
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
        'last_dispatch_at', j.last_dispatch_at
      ) order by j.dispatch_attempts desc, j.last_dispatch_at asc)
      from public.jobs j
      where j.status = 'matching'
        and j.dispatch_attempts >= 3
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
        'assignment_expires_at', j.assignment_expires_at
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
        'payout_confidence_score', e.payout_confidence_score,
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
        'last_seen_at', a.last_seen_at
      ) order by case a.severity when 'critical' then 0 when 'warning' then 1 else 2 end, a.last_seen_at asc)
      from public.operational_alerts a
      where a.status = 'open'
    ), '[]'::jsonb)
  ) into payload;

  return payload;
end;
$$;

revoke all on table public.upload_failures from public, anon, authenticated;
grant select on table public.upload_failures to authenticated;
grant all on table public.upload_failures to service_role;

revoke all on function public.job_status_for_event(text,jsonb) from public, anon, authenticated;
grant execute on function public.job_status_for_event(text,jsonb) to authenticated, service_role;

revoke all on function public.job_event_to_timeline() from public, anon, authenticated;
grant execute on function public.job_event_to_timeline() to service_role;

revoke all on function public.is_valid_job_transition(public.job_status,public.job_status,text,boolean,jsonb) from public, anon, authenticated;
grant execute on function public.is_valid_job_transition(public.job_status,public.job_status,text,boolean,jsonb) to service_role;

revoke all on function public.transition_job_state(uuid,public.job_status,text,uuid,text,text,jsonb,public.job_status,text) from public, anon, authenticated;
grant execute on function public.transition_job_state(uuid,public.job_status,text,uuid,text,text,jsonb,public.job_status,text) to service_role;

revoke all on function public.record_upload_failure(uuid,text,text,text,text,integer,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.record_upload_failure(uuid,text,text,text,text,integer,text,text,jsonb) to service_role;

revoke all on function public.prepare_guest_dispatch_otp(uuid,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.prepare_guest_dispatch_otp(uuid,text,text,text) to anon, authenticated, service_role;

revoke all on function public.request_guest_otp(uuid,text,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.request_guest_otp(uuid,text,text,text,text) to anon, authenticated, service_role;

revoke all on function public.verify_guest_otp(uuid,text,text,uuid,text) from public, anon, authenticated, service_role;
grant execute on function public.verify_guest_otp(uuid,text,text,uuid,text) to anon, authenticated, service_role;

revoke all on function public.append_job_timeline(uuid,public.job_status,text,uuid) from public, anon, authenticated;
grant execute on function public.append_job_timeline(uuid,public.job_status,text,uuid) to service_role;

revoke all on function public.set_job_status(uuid,public.job_status,text,jsonb) from public, anon, authenticated, service_role;
grant execute on function public.set_job_status(uuid,public.job_status,text,jsonb) to authenticated, service_role;

revoke all on function public.update_guest_job_status(uuid,text,public.job_status,text,jsonb,text) from public, anon, authenticated, service_role;
grant execute on function public.update_guest_job_status(uuid,text,public.job_status,text,jsonb,text) to anon, authenticated, service_role;

revoke all on function public.electrician_accept_job(uuid) from public, anon, authenticated, service_role;
grant execute on function public.electrician_accept_job(uuid) to authenticated, service_role;

revoke all on function public.electrician_reject_job(uuid) from public, anon, authenticated, service_role;
grant execute on function public.electrician_reject_job(uuid) to authenticated, service_role;

revoke all on function public.refresh_electrician_performance_snapshot(uuid) from public, anon, authenticated;
grant execute on function public.refresh_electrician_performance_snapshot(uuid) to authenticated, service_role;

revoke all on function public.admin_operational_summary() from public, anon, authenticated;
grant execute on function public.admin_operational_summary() to authenticated, service_role;

revoke all on function public.admin_operational_queues() from public, anon, authenticated;
grant execute on function public.admin_operational_queues() to authenticated, service_role;

notify pgrst, 'reload schema';
